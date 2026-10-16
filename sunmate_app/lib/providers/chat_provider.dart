import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ai/agent_client.dart';
import '../core/ai/asr_service.dart';
import 'server_config_provider.dart';

class ChatMessage {
  final String id;
  final bool isUser;
  final String text;
  final DateTime timestamp;
  final bool isDivider; // 是否为跨日/新会话的系统分割线

  ChatMessage({
    required this.id,
    required this.isUser,
    required this.text,
    required this.timestamp,
    this.isDivider = false,
  });
}

class ChatState {
  final List<ChatMessage> messages;
  final bool isListening; // 是否正在接收语音输入中
  final bool isGenerating; // 智能体是否正在流式回答中
  final DateTime? lastMessageTime; // 上一次有效交互时间

  const ChatState({
    this.messages = const [],
    this.isListening = false,
    this.isGenerating = false,
    this.lastMessageTime,
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isListening,
    bool? isGenerating,
    DateTime? lastMessageTime,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isListening: isListening ?? this.isListening,
      isGenerating: isGenerating ?? this.isGenerating,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
    );
  }
}

class ChatNotifier extends StateNotifier<ChatState> {
  final Ref _ref;

  ChatNotifier(this._ref)
      : super(
          ChatState(
            messages: [
              ChatMessage(
                id: "welcome",
                isUser: false,
                text: "你好！我是你的第二大脑与成长伴侣 SunMate（阳光智伴），由你的私有 Hermes 智能体驱动。\n你可以随时长按设备物理键或下方按键直接说话，我将实时倾听、深度思考并为你解答。",
                timestamp: DateTime.now(),
              )
            ],
            lastMessageTime: DateTime.now(),
          ),
        );

  AgentClient get _agentClient => _ref.read(agentClientProvider);
  AsrService get _asrService => _ref.read(asrServiceProvider);

  /// 辅助算法：计算时间的逻辑日编号 (以每日凌晨 04:00 为分界基准)
  int _getLogicalDay(DateTime time) {
    final logical = time.hour < 4
        ? time.subtract(const Duration(days: 1))
        : time;
    return logical.year * 10000 + logical.month * 100 + logical.day;
  }

  /// 检查是否触发新一轮会话 (跨过凌晨 4 点且持续静默超过 30 分钟)
  bool _shouldRotateSession(DateTime now, DateTime? lastTime) {
    if (lastTime == null) return false;
    final lastDay = _getLogicalDay(lastTime);
    final curDay = _getLogicalDay(now);

    // 跨越了凌晨 4:00 分界线
    if (curDay > lastDay) {
      // 检查防打断静默期：是否距离上一句已经超过 30 分钟？
      final silence = now.difference(lastTime);
      return silence >= const Duration(minutes: 30);
    }
    return false;
  }

  void setListeningState(bool listening) {
    state = state.copyWith(isListening: listening);
  }

  /// 发送文本消息 (支持凌晨 4 点跨日自动轮转与防打断保护)
  Future<void> sendUserMessage(String content) async {
    final now = DateTime.now();
    final needRotate = _shouldRotateSession(now, state.lastMessageTime);

    final List<ChatMessage> prefixMessages = [...state.messages];
    if (needRotate) {
      prefixMessages.add(ChatMessage(
        id: "divider_${now.millisecondsSinceEpoch}",
        isUser: false,
        text: "——— 🌅 开启新一轮随身会话 (凌晨 04:00+ 自动轮转) ———",
        timestamp: now,
        isDivider: true,
      ));
    }

    final userMsg = ChatMessage(
      id: now.millisecondsSinceEpoch.toString(),
      isUser: true,
      text: content,
      timestamp: now,
    );

    state = state.copyWith(
      messages: [...prefixMessages, userMsg],
      isGenerating: true,
      lastMessageTime: now,
    );

    final assistantMsgId = (now.millisecondsSinceEpoch + 1).toString();
    final assistantMsg = ChatMessage(
      id: assistantMsgId,
      isUser: false,
      text: "Hermes 思考中...",
      timestamp: now,
    );
    state = state.copyWith(messages: [...state.messages, assistantMsg]);

    // 提取当前轮次会话的多轮上下文 (找到最近一个 divider 之后的消息，最多保留 8 轮)
    final List<Map<String, String>> historyList = [];
    final currentSessionMessages = <ChatMessage>[];

    // 从后往前找，只提取当前逻辑会话段
    for (int i = state.messages.length - 1; i >= 0; i--) {
      final m = state.messages[i];
      if (m.isDivider) break; // 遇到分割线即停止，上一天历史不传入 Prompt
      if (m.id != "welcome" && m.id != userMsg.id && m.id != assistantMsgId) {
        currentSessionMessages.insert(0, m);
      }
    }

    final startIdx = currentSessionMessages.length > 8 ? currentSessionMessages.length - 8 : 0;
    for (int i = startIdx; i < currentSessionMessages.length; i++) {
      final msg = currentSessionMessages[i];
      if (msg.text.isNotEmpty && !msg.text.contains("Hermes 思考中...")) {
        historyList.add({
          "role": msg.isUser ? "user" : "assistant",
          "content": msg.text,
        });
      }
    }

    // 流式响应 (携带当前轮次专属上下文)
    String accumulated = "";
    await for (final delta in _agentClient.chatStream(content, history: historyList)) {
      accumulated += delta;
      state = state.copyWith(
        messages: [
          for (final m in state.messages)
            if (m.id == assistantMsgId)
              ChatMessage(id: m.id, isUser: false, text: accumulated, timestamp: m.timestamp)
            else
              m
        ],
      );
    }
    state = state.copyWith(isGenerating: false);
  }

  /// 收到长按说话语音流并进行 MOSS-ASR 同步转写与 Hermes 对话
  Future<void> handleVoiceInput(Uint8List audioBytes) async {
    if (audioBytes.isEmpty) return;

    // 1. 调用 MOSS-ASR 同步短语音转写
    final transcript = await _asrService.transcribeShortAudio(audioBytes);
    // 2. 提交 Hermes 智能体
    if (transcript.isNotEmpty) {
      await sendUserMessage(transcript);
    }
  }

  /// 清空会话历史
  void clearMessages() {
    state = state.copyWith(messages: []);
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier(ref);
});

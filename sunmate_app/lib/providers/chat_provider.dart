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
  final bool isFailed;
  final bool isDivider; // 是否为跨日/新会话的系统分割线

  ChatMessage({
    required this.id,
    required this.isUser,
    required this.text,
    required this.timestamp,
    this.isDivider = false,
    this.isFailed = false,
  });
}

class ChatState {
  final List<ChatMessage> messages;
  final bool isListening; // 是否正在接收语音输入中
  final bool isGenerating; // 智能体是否正在流式回答中
  final String generationStatus;
  final DateTime? lastMessageTime; // 上一次有效交互时间

  const ChatState({
    this.messages = const [],
    this.isListening = false,
    this.isGenerating = false,
    this.generationStatus = '',
    this.lastMessageTime,
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isListening,
    bool? isGenerating,
    DateTime? lastMessageTime,
    String? generationStatus,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isListening: isListening ?? this.isListening,
      isGenerating: isGenerating ?? this.isGenerating,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      generationStatus: generationStatus ?? this.generationStatus,
    );
  }
}

class ChatNotifier extends StateNotifier<ChatState> {
  final Ref _ref;
  Future<void> _sendQueue = Future<void>.value();
  int _sessionEpoch = 0;
  int _messageSequence = 0;

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
  Future<void> sendUserMessage(String content) {
    if (content.trim().isEmpty) return Future<void>.value();
    final epoch = _sessionEpoch;
    final operation = _sendQueue.then((_) async {
      if (!mounted || epoch != _sessionEpoch) return;
      await _sendUserMessage(content, epoch);
    });
    _sendQueue = operation.catchError((Object _, StackTrace __) {});
    return operation;
  }

  Future<void> _sendUserMessage(String content, int epoch) async {
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
      id: '${now.millisecondsSinceEpoch}_${++_messageSequence}',
      isUser: true,
      text: content,
      timestamp: now,
    );

    state = state.copyWith(
      messages: [...prefixMessages, userMsg],
      isGenerating: true,
      generationStatus: '正在等待 Hermes 回复…',
      lastMessageTime: now,
    );

    final assistantMsgId = '${userMsg.id}_reply';
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
      if (!msg.isFailed && msg.text.isNotEmpty && !msg.text.contains("Hermes 思考中...")) {
        historyList.add({
          "role": msg.isUser ? "user" : "assistant",
          "content": msg.text,
        });
      }
    }

    // 一次请求等待整个流；工具进度仅更新状态，不当作最终文本。
    String accumulated = '';
    void updateReply(String text, {bool failed = false}) {
      if (!mounted || epoch != _sessionEpoch) return;
      state = state.copyWith(messages: [
        for (final m in state.messages)
          if (m.id == assistantMsgId)
            ChatMessage(id: m.id, isUser: false, text: text,
                timestamp: m.timestamp, isFailed: failed)
          else m,
      ]);
    }
    try {
      await for (final delta in _agentClient.chatStream(content, history: historyList,
          onProgress: (status) {
            if (mounted && epoch == _sessionEpoch) {
              state = state.copyWith(generationStatus: status);
            }
          })) {
        if (!mounted || epoch != _sessionEpoch) return;
        accumulated += delta;
        updateReply(accumulated);
      }
    } catch (error) {
      final message = error is AgentResponseException
          ? error.message : '连接异常，当前回复未完成。';
      updateReply('${accumulated.isEmpty ? '' : '$accumulated\n\n'}[回复未完成] $message',
          failed: true);
    } finally {
      if (mounted && epoch == _sessionEpoch) {
        state = state.copyWith(isGenerating: false, generationStatus: '');
      }
    }
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
    ++_sessionEpoch;
    state = state.copyWith(messages: [], isGenerating: false, generationStatus: '');
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier(ref);
});

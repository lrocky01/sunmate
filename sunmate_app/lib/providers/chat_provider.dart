import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ai/agent_client.dart';
import '../core/ai/asr_service.dart';
import 'server_config_provider.dart';

enum VoiceInputPhase {
  recording,
  preparing,
  queued,
  transcribing,
  ready,
  failed,
  cancelled
}

class ChatMessage {
  final String id;
  final bool isUser;
  final String text;
  final DateTime timestamp;
  final bool isFailed;
  final bool isDivider; // 是否为跨日/新会话的系统分割线
  final VoiceInputPhase? voicePhase;
  final Duration? voiceDuration;

  ChatMessage({
    required this.id,
    required this.isUser,
    required this.text,
    required this.timestamp,
    this.isDivider = false,
    this.isFailed = false,
    this.voicePhase,
    this.voiceDuration,
  });

  ChatMessage withVoice(VoiceInputPhase phase,
          {String? text, Duration? duration}) =>
      ChatMessage(
          id: id,
          isUser: true,
          text: text ?? this.text,
          timestamp: timestamp,
          voicePhase: phase,
          voiceDuration: duration ?? voiceDuration,
          isFailed: phase == VoiceInputPhase.failed ||
              phase == VoiceInputPhase.cancelled);
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
  String? _activeVoiceMessageId;

  ChatNotifier(this._ref)
      : super(
          ChatState(
            messages: [
              ChatMessage(
                id: "welcome",
                isUser: false,
                text:
                    "你好！我是你的第二大脑与成长伴侣 SunMate（阳光智伴），由你的私有 Hermes 智能体驱动。\n你可以随时长按设备物理键或下方按键直接说话，我将实时倾听、深度思考并为你解答。",
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
    final logical =
        time.hour < 4 ? time.subtract(const Duration(days: 1)) : time;
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

  ChatMessage? _voice(String? id) {
    if (id == null) return null;
    for (final message in state.messages) {
      if (message.id == id && message.voicePhase != null) return message;
    }
    return null;
  }

  String? beginVoiceInput() {
    if (!mounted) return null;
    final active = _voice(_activeVoiceMessageId);
    if (active?.voicePhase == VoiceInputPhase.recording) return active!.id;
    final now = DateTime.now();
    final messages = [...state.messages];
    if (_shouldRotateSession(now, state.lastMessageTime)) {
      messages.add(ChatMessage(
          id: 'divider_${now.millisecondsSinceEpoch}_${++_messageSequence}',
          isUser: false,
          text: '——— 开启新一轮随身会话 ———',
          timestamp: now,
          isDivider: true));
    }
    final id = 'voice_${now.millisecondsSinceEpoch}_${++_messageSequence}';
    messages.add(ChatMessage(
        id: id,
        isUser: true,
        text: '',
        timestamp: now,
        voicePhase: VoiceInputPhase.recording));
    _activeVoiceMessageId = id;
    state = state.copyWith(
        messages: messages, isListening: true, lastMessageTime: now);
    return id;
  }

  void _replaceVoice(String id, VoiceInputPhase phase,
      {String? text, Duration? duration}) {
    if (!mounted) return;
    state = state.copyWith(messages: [
      for (final message in state.messages)
        if (message.id == id)
          message.withVoice(phase, text: text, duration: duration)
        else
          message
    ]);
  }

  String? finishVoiceInput() {
    if (!mounted) return null;
    final message = _voice(_activeVoiceMessageId);
    if (message?.voicePhase != VoiceInputPhase.recording) return null;
    _activeVoiceMessageId = null;
    final elapsed = DateTime.now().difference(message!.timestamp);
    _replaceVoice(message.id, VoiceInputPhase.preparing,
        duration: elapsed.isNegative ? Duration.zero : elapsed);
    state = state.copyWith(isListening: false);
    return message.id;
  }

  void cancelVoiceInput([String? id]) {
    if (!mounted) return;
    final message = _voice(id ?? _activeVoiceMessageId);
    if (message == null ||
        message.voicePhase != VoiceInputPhase.recording &&
            message.voicePhase != VoiceInputPhase.preparing) return;
    if (_activeVoiceMessageId == message.id) {
      _activeVoiceMessageId = null;
      state = state.copyWith(isListening: false);
    }
    final elapsed = DateTime.now().difference(message.timestamp);
    _replaceVoice(message.id, VoiceInputPhase.cancelled,
        text: '本次录音已取消，未发送。',
        duration: elapsed.isNegative ? Duration.zero : elapsed);
  }

  /// 兼容已有调用；硬件取消使用独立cancel，避免把截断音频提交给ASR。
  void setListeningState(bool listening) {
    if (listening) {
      beginVoiceInput();
    } else {
      finishVoiceInput();
    }
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

  Future<void> _sendUserMessage(String content, int epoch,
      {String? voiceMessageId}) async {
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

    final voice = _voice(voiceMessageId);
    if (voiceMessageId != null && voice == null) return;
    final userMsg = voice?.withVoice(VoiceInputPhase.ready, text: content) ??
        ChatMessage(
            id: '${now.millisecondsSinceEpoch}_${++_messageSequence}',
            isUser: true,
            text: content,
            timestamp: now);
    final updatedMessages = voice == null
        ? [...prefixMessages, userMsg]
        : [
            for (final message in prefixMessages)
              if (message.id == userMsg.id) userMsg else message
          ];

    state = state.copyWith(
      messages: updatedMessages,
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
    final userIndex = state.messages.indexWhere((m) => m.id == userMsg.id);
    final withReply = [...state.messages]..insert(userIndex + 1, assistantMsg);
    state = state.copyWith(messages: withReply);

    // 提取当前轮次会话的多轮上下文 (找到最近一个 divider 之后的消息，最多保留 8 轮)
    final List<Map<String, String>> historyList = [];
    final currentSessionMessages = <ChatMessage>[];

    // 从后往前找，只提取当前逻辑会话段
    for (int i = userIndex - 1; i >= 0; i--) {
      final m = state.messages[i];
      if (m.isDivider) break; // 遇到分割线即停止，上一天历史不传入 Prompt
      if (m.id != "welcome" && m.id != userMsg.id && m.id != assistantMsgId) {
        currentSessionMessages.insert(0, m);
      }
    }

    final startIdx = currentSessionMessages.length > 8
        ? currentSessionMessages.length - 8
        : 0;
    for (int i = startIdx; i < currentSessionMessages.length; i++) {
      final msg = currentSessionMessages[i];
      if (!msg.isFailed &&
          (msg.voicePhase == null || msg.voicePhase == VoiceInputPhase.ready) &&
          msg.text.isNotEmpty &&
          !msg.text.contains("Hermes 思考中...")) {
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
            ChatMessage(
                id: m.id,
                isUser: false,
                text: text,
                timestamp: m.timestamp,
                isFailed: failed)
          else
            m,
      ]);
    }

    try {
      await for (final delta in _agentClient
          .chatStream(content, history: historyList, onProgress: (status) {
        if (mounted && epoch == _sessionEpoch) {
          state = state.copyWith(generationStatus: status);
        }
      })) {
        if (!mounted || epoch != _sessionEpoch) return;
        accumulated += delta;
        updateReply(accumulated);
      }
    } catch (error) {
      final message =
          error is AgentResponseException ? error.message : '连接异常，当前回复未完成。';
      updateReply(
          '${accumulated.isEmpty ? '' : '$accumulated\n\n'}[回复未完成] $message',
          failed: true);
    } finally {
      if (mounted && epoch == _sessionEpoch) {
        state = state.copyWith(isGenerating: false, generationStatus: '');
      }
    }
  }

  /// 与文字请求共用队列，保证多段语音按松开顺序转写和回复。
  Future<void> handleVoiceInput(Uint8List audioBytes,
      {String? voiceMessageId}) {
    if (!mounted) return Future<void>.value();
    final id = voiceMessageId ?? finishVoiceInput() ?? beginVoiceInput();
    if (id == null || _voice(id) == null) return Future<void>.value();
    if (_voice(id)!.voicePhase == VoiceInputPhase.recording) finishVoiceInput();
    final phase = _voice(id)!.voicePhase;
    if (phase != VoiceInputPhase.preparing) return Future<void>.value();
    if (audioBytes.isEmpty) {
      _replaceVoice(id, VoiceInputPhase.failed, text: '未收到有效音频，请重新按住录音卡说话。');
      return Future<void>.value();
    }
    final epoch = _sessionEpoch;
    // 独立持有本次完成音频；下一次按下清缓冲不会影响当前请求。
    final bytes = Uint8List.fromList(audioBytes);
    _replaceVoice(id, VoiceInputPhase.queued);
    final operation = _sendQueue.then((_) async {
      if (!mounted || epoch != _sessionEpoch || _voice(id) == null) return;
      _replaceVoice(id, VoiceInputPhase.transcribing);
      try {
        final transcript = await _asrService.transcribeShortAudio(bytes);
        if (!mounted || epoch != _sessionEpoch || _voice(id) == null) return;
        if (transcript.trim().isEmpty)
          throw const AsrTranscriptionException('未识别到清晰语音，请重新说话。');
        await _sendUserMessage(transcript, epoch, voiceMessageId: id);
      } catch (error) {
        if (!mounted || epoch != _sessionEpoch) return;
        _replaceVoice(id, VoiceInputPhase.failed,
            text: error is AsrTranscriptionException
                ? error.message
                : '语音转写未完成，请检查 ASR 节点后重新说话。');
      }
    });
    _sendQueue = operation.catchError((Object _, StackTrace __) {});
    return operation;
  }

  /// 清空会话历史
  void clearMessages() {
    ++_sessionEpoch;
    // 旧网络回调由epoch隔离；新会话无需等待旧ASR或工具请求超时。
    _sendQueue = Future<void>.value();
    _activeVoiceMessageId = null;
    state = state.copyWith(
        messages: [],
        isListening: false,
        isGenerating: false,
        generationStatus: '');
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier(ref);
});

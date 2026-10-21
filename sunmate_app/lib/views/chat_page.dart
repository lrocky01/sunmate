import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/chat_provider.dart';
import '../providers/button_action_provider.dart';
import 'voice_input_bubble.dart';
import '../providers/device_provider.dart';
import '../core/hardware/hardware_device_driver.dart';
import '../core/hardware/phone_mic_driver.dart';
import '../core/hardware/ainote_6095_driver.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isPressingSoftButton = false;

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(buttonActionProvider); // 此页独立打开时也订阅真实硬件事件。
    final scheme = Theme.of(context).colorScheme;
    final chatState = ref.watch(chatProvider);
    final deviceState = ref.watch(deviceProvider);
    final factory = ref.read(deviceFactoryProvider);
    _scrollToBottom();
    final pendingVoice = chatState.messages
        .where((m) =>
            m.voicePhase != null &&
            m.voicePhase != VoiceInputPhase.ready &&
            m.voicePhase != VoiceInputPhase.failed &&
            m.voicePhase != VoiceInputPhase.cancelled)
        .toList();
    final voiceStatus = pendingVoice.isEmpty
        ? null
        : switch (pendingVoice.last.voicePhase) {
            VoiceInputPhase.recording => '正在录音，松开按键后转写',
            VoiceInputPhase.preparing => '正在整理录音…',
            VoiceInputPhase.transcribing => '正在将语音转成文字…',
            _ => '语音等待处理…',
          };
    final pressing = _isPressingSoftButton || chatState.isListening;

    return Scaffold(
      appBar: AppBar(
        title: const Text("SunMate 智能体对讲"),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: "清空对话",
            onPressed: () => ref.read(chatProvider.notifier).clearMessages(),
          ),
        ],
      ),
      body: Column(
        children: [
          // 顶部状态与收音状态条
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color:
                chatState.isListening ? scheme.error : scheme.primaryContainer,
            child: Row(
              children: [
                Icon(
                  chatState.isListening ? Icons.mic : Icons.sensors,
                  color: chatState.isListening
                      ? scheme.onError
                      : scheme.onPrimaryContainer,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    voiceStatus ??
                        (chatState.isGenerating
                            ? chatState.generationStatus
                            : "支持长按对讲：按住录音卡或屏幕底部按钮直接交流"),
                    style: TextStyle(
                      color: chatState.isListening
                          ? scheme.onError
                          : scheme.onPrimaryContainer,
                      fontSize: 12,
                      fontWeight: chatState.isListening
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ),
                if (!deviceState.isConnected)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade200,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text("手机麦克风模式",
                        style: TextStyle(fontSize: 10, color: Colors.brown)),
                  ),
              ],
            ),
          ),

          // 消息流列表
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount:
                  chatState.messages.length + (chatState.isGenerating ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == chatState.messages.length) {
                  return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(children: [
                        SizedBox(
                            width: 18,
                            height: 18,
                            child: MediaQuery.disableAnimationsOf(context)
                                ? Icon(Icons.hourglass_top,
                                    size: 18, color: scheme.primary)
                                : const CircularProgressIndicator(
                                    strokeWidth: 2)),
                        const SizedBox(width: 10),
                        Expanded(
                            child: Semantics(
                                liveRegion: true,
                                child: Text(chatState.generationStatus,
                                    style: TextStyle(
                                        color: scheme.onSurfaceVariant)))),
                      ]));
                }
                final msg = chatState.messages[index];
                return _MessageBubble(key: ValueKey(msg.id), message: msg);
              },
            ),
          ),

          // 底部控制与输入区
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.surface,
              border: Border(top: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        decoration: const InputDecoration(
                          hintText: "文字提问或长按下方按钮对讲...",
                          border: InputBorder.none,
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        onSubmitted: (val) {
                          if (val.trim().isNotEmpty) {
                            ref
                                .read(chatProvider.notifier)
                                .sendUserMessage(val.trim());
                            _textController.clear();
                          }
                        },
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.send, color: scheme.primary),
                      onPressed: () {
                        final val = _textController.text.trim();
                        if (val.isNotEmpty) {
                          ref.read(chatProvider.notifier).sendUserMessage(val);
                          _textController.clear();
                        }
                      },
                    ),
                  ],
                ),
                const Divider(height: 1),
                const SizedBox(height: 8),
                // 大按钮 Push-to-Talk 软按键
                GestureDetector(
                  onLongPressStart: (_) {
                    if (chatState.isListening) return;
                    setState(() => _isPressingSoftButton = true);
                    final activeDriver = factory.activeDriver;
                    if (activeDriver is PhoneMicDriver) {
                      activeDriver.triggerPressDown();
                    } else if (activeDriver is AiNote6095Driver) {
                      activeDriver
                          .simulateButtonEvent(ButtonActionType.pressDown);
                    } else {
                      ref.read(chatProvider.notifier).setListeningState(true);
                    }
                  },
                  onLongPressEnd: (_) {
                    if (!_isPressingSoftButton) return;
                    setState(() => _isPressingSoftButton = false);
                    final activeDriver = factory.activeDriver;
                    if (activeDriver is PhoneMicDriver) {
                      activeDriver.triggerRelease();
                    } else if (activeDriver is AiNote6095Driver) {
                      activeDriver
                          .simulateButtonEvent(ButtonActionType.release);
                    } else {
                      ref.read(chatProvider.notifier).cancelVoiceInput();
                    }
                  },
                  onLongPressCancel: () {
                    if (!_isPressingSoftButton) return;
                    setState(() => _isPressingSoftButton = false);
                    ref
                        .read(buttonActionProvider.notifier)
                        .cancelVoiceCapture();
                    ref.read(chatProvider.notifier).cancelVoiceInput();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: pressing ? scheme.error : scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: pressing ? scheme.error : scheme.primary,
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          pressing ? Icons.mic : Icons.mic_none,
                          color: pressing
                              ? scheme.onError
                              : scheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                            child: Text(
                          pressing ? "正在录音，松开发送" : "按住说话",
                          style: TextStyle(
                            color: pressing
                                ? scheme.onError
                                : scheme.onPrimaryContainer,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        )),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const _MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    if (message.voicePhase != null)
      return VoiceInputBubble(key: ValueKey(message.id), message: message);
    // 1. 如果是系统新会话分割线，居中优雅展示
    if (message.isDivider) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            Expanded(child: Divider(color: Colors.orange.withOpacity(0.3))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.orange.withOpacity(0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.wb_twilight,
                      size: 14, color: Color(0xFFE65100)),
                  const SizedBox(width: 4),
                  Text(
                    message.text.replaceAll("———", "").trim(),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFE65100),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: Divider(color: Colors.orange.withOpacity(0.3))),
          ],
        ),
      );
    }

    // 2. 正常对话气泡
    final scheme = Theme.of(context).colorScheme;
    final isUser = message.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: isUser ? scheme.primary : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Text(
          message.text,
          style: TextStyle(
            color: isUser ? scheme.onPrimary : scheme.onSurface,
            fontSize: 15,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

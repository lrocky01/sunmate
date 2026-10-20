import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/chat_provider.dart';
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
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatProvider);
    final deviceState = ref.watch(deviceProvider);
    final factory = ref.read(deviceFactoryProvider);
    _scrollToBottom();

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
            color: chatState.isListening
                ? Colors.red.shade600
                : const Color(0xFFFFF3E0),
            child: Row(
              children: [
                Icon(
                  chatState.isListening ? Icons.mic : Icons.sensors,
                  color: chatState.isListening ? Colors.white : Colors.orange.shade900,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    chatState.isListening
                        ? "正在收音中... 松开设备按键或屏幕按钮即可发送"
                        : chatState.isGenerating
                            ? chatState.generationStatus
                            : "支持长按对讲：按住录音卡或屏幕底部按钮直接交流",
                    style: TextStyle(
                      color: chatState.isListening ? Colors.white : Colors.orange.shade900,
                      fontSize: 12,
                      fontWeight: chatState.isListening ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
                if (!deviceState.isConnected)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade200,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text("手机麦克风模式", style: TextStyle(fontSize: 10, color: Colors.brown)),
                  ),
              ],
            ),
          ),

          // 消息流列表
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: chatState.messages.length,
              itemBuilder: (context, index) {
                final msg = chatState.messages[index];
                return _MessageBubble(message: msg);
              },
            ),
          ),

          // 底部控制与输入区
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Colors.grey.shade200)),
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
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        onSubmitted: (val) {
                          if (val.trim().isNotEmpty) {
                            ref.read(chatProvider.notifier).sendUserMessage(val.trim());
                            _textController.clear();
                          }
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send, color: Color(0xFFFF8C00)),
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
                    setState(() => _isPressingSoftButton = true);
                    final activeDriver = factory.activeDriver;
                    if (activeDriver is PhoneMicDriver) {
                      activeDriver.triggerPressDown();
                    } else if (activeDriver is AiNote6095Driver) {
                      activeDriver.simulateButtonEvent(ButtonActionType.pressDown);
                    } else {
                      ref.read(chatProvider.notifier).setListeningState(true);
                    }
                  },
                  onLongPressEnd: (_) {
                    setState(() => _isPressingSoftButton = false);
                    final activeDriver = factory.activeDriver;
                    if (activeDriver is PhoneMicDriver) {
                      activeDriver.triggerRelease();
                    } else if (activeDriver is AiNote6095Driver) {
                      activeDriver.simulateButtonEvent(ButtonActionType.release);
                    } else {
                      ref.read(chatProvider.notifier).setListeningState(false);
                    }
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: _isPressingSoftButton
                          ? Colors.red.shade600
                          : const Color(0xFFFF8C00).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _isPressingSoftButton ? Colors.red : const Color(0xFFFF8C00),
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isPressingSoftButton ? Icons.mic : Icons.mic_none,
                          color: _isPressingSoftButton ? Colors.white : const Color(0xFFD35400),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _isPressingSoftButton ? "正在聆听中... (松开发送)" : "按住 对讲说话 (Push-to-Talk)",
                          style: TextStyle(
                            color: _isPressingSoftButton ? Colors.white : const Color(0xFFD35400),
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
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

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
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
                  const Icon(Icons.wb_twilight, size: 14, color: Color(0xFFE65100)),
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
    final isUser = message.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFFFF8C00) : Colors.grey.shade100,
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
            color: isUser ? Colors.white : Colors.black87,
            fontSize: 15,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

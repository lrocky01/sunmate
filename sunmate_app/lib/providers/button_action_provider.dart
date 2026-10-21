import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/hardware/hardware_device_driver.dart';
import '../models/button_action_config.dart';
import 'chat_provider.dart';
import 'device_provider.dart';
import 'timeline_provider.dart';

class ButtonActionNotifier extends StateNotifier<ButtonActionConfig> {
  final Ref _ref;
  StreamSubscription? _buttonSub;
  StreamSubscription? _audioSub;
  final List<int> _recordedBuffer = [];
  bool _isCollectingVoice = false;
  String? _voiceMessageId;
  ChatNotifier? _voiceChat;

  ButtonActionNotifier(this._ref) : super(const ButtonActionConfig()) {
    _bindDriverEvents();
  }

  void _bindDriverEvents() {
    _buttonSub?.cancel();
    _audioSub?.cancel();
    cancelVoiceCapture();

    final factory = _ref.read(deviceFactoryProvider);
    final driver = factory.activeDriver;

    // 监听按键事件流
    _buttonSub = driver.buttonEvents.listen(_handleDeviceButtonEvent);

    // 监听音频数据包流
    _audioSub = driver.audioStream.listen((packet) {
      if (_isCollectingVoice) {
        _recordedBuffer.addAll(packet.bytes);
      }
    });
  }

  /// 当驱动切换时重新绑定事件
  void rebindDriver() {
    _bindDriverEvents();
  }

  void updateConfig(ButtonActionConfig newConfig) {
    state = newConfig;
  }

  void _handleDeviceButtonEvent(DeviceButtonEvent event) {
    switch (event.action) {
      case ButtonActionType.singleClick:
        _executeAction(state.singleClick);
        break;
      case ButtonActionType.doubleClick:
        _executeAction(state.doubleClick);
        break;
      case ButtonActionType.tripleClick:
        _executeAction(state.tripleClick);
        break;
      case ButtonActionType.pressDown:
        if (state.longPress == CustomActionBehavior.pushToTalk &&
            !_isCollectingVoice) {
          _isCollectingVoice = true;
          _recordedBuffer.clear();
          _voiceChat = _ref.read(chatProvider.notifier);
          _voiceMessageId = _voiceChat!.beginVoiceInput();
        }
        break;
      case ButtonActionType.release:
        if (_isCollectingVoice) {
          _isCollectingVoice = false;
          final chat = _voiceChat;
          final id = _voiceMessageId;
          _voiceMessageId = null;
          chat?.finishVoiceInput();
          final audioBytes = Uint8List.fromList(_recordedBuffer);
          _recordedBuffer.clear();
          if (chat != null && id != null)
            unawaited(chat.handleVoiceInput(audioBytes, voiceMessageId: id));
        }
        break;
      case ButtonActionType.longPress:
        if (state.longPress != CustomActionBehavior.pushToTalk) {
          _executeAction(state.longPress);
        }
        break;
      case ButtonActionType.cancel:
        cancelVoiceCapture();
        break;
    }
  }

  void cancelVoiceCapture() {
    _isCollectingVoice = false;
    _recordedBuffer.clear();
    final id = _voiceMessageId;
    _voiceMessageId = null;
    if (id != null) _voiceChat?.cancelVoiceInput(id);
  }

  void _executeAction(CustomActionBehavior behavior) {
    final devNotifier = _ref.read(deviceProvider.notifier);
    final devState = _ref.read(deviceProvider);
    final timelineNotifier = _ref.read(timelineProvider.notifier);

    switch (behavior) {
      case CustomActionBehavior.toggleRecording:
        if (devState.isRecording) {
          devNotifier.stopRecording();
        } else {
          devNotifier.startRecording();
        }
        break;
      case CustomActionBehavior.bookmark:
        // 在随身时间线打标记
        timelineNotifier.addBookmark("灵感重点标记");
        break;
      case CustomActionBehavior.queryBattery:
        devNotifier.refreshStatus();
        break;
      case CustomActionBehavior.toggleLifeLog:
        timelineNotifier.toggleLifeLog();
        break;
      case CustomActionBehavior.pushToTalk:
      case CustomActionBehavior.none:
        break;
    }
  }

  @override
  void dispose() {
    cancelVoiceCapture();
    _buttonSub?.cancel();
    _audioSub?.cancel();
    super.dispose();
  }
}

final buttonActionProvider =
    StateNotifierProvider<ButtonActionNotifier, ButtonActionConfig>((ref) {
  return ButtonActionNotifier(ref);
});

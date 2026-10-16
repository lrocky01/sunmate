import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'hardware_device_driver.dart';

/// 手机内置麦克风与软按键驱动 (无外设兜底方案)
class PhoneMicDriver implements HardwareDeviceDriver {
  final _buttonEventController = StreamController<DeviceButtonEvent>.broadcast();
  final _audioPacketController = StreamController<AudioDataPacket>.broadcast();
  final _stateChangeController = StreamController<void>.broadcast();

  bool _isConnected = true; // 手机本机麦克风永远可用
  final int _batteryLevel = 100;
  bool _isRecording = false;
  bool _isPaused = false;
  Timer? _mockAudioTimer;

  // 软按键状态
  int _clickCount = 0;
  Timer? _clickTimer;
  DateTime? _pressDownTime;

  @override
  HardwareDeviceType get deviceType => HardwareDeviceType.phoneInternalMic;

  @override
  String get displayName => "手机内置麦克风 (无外设模式)";

  @override
  bool get isConnected => _isConnected;

  @override
  int get batteryLevel => _batteryLevel;

  @override
  bool get isRecording => _isRecording;

  @override
  bool get isPaused => _isPaused;

  @override
  Stream<DeviceButtonEvent> get buttonEvents => _buttonEventController.stream;

  @override
  Stream<AudioDataPacket> get audioStream => _audioPacketController.stream;

  @override
  Stream<void> get stateChanges => _stateChangeController.stream;

  @override
  Future<bool> connect() async {
    _isConnected = true;
    _stateChangeController.add(null);
    return true;
  }

  @override
  Future<void> disconnect() async {
    _isConnected = false;
    _isRecording = false;
    _isPaused = false;
    _mockAudioTimer?.cancel();
    _stateChangeController.add(null);
  }

  @override
  Future<bool> startRecording() async {
    _isRecording = true;
    _isPaused = false;
    _stateChangeController.add(null);

    // 启动音频流生成 (每 40ms 生成一个 16kHz PCM 数据包)
    _mockAudioTimer?.cancel();
    final random = Random();
    _mockAudioTimer = Timer.periodic(const Duration(milliseconds: 40), (timer) {
      if (!_isRecording || _isPaused) return;

      // 模拟 40ms 16kHz 16bit 单声道 PCM 数据 (1280 字节)
      final pcmBytes = Uint8List(1280);
      final amp = 0.2 + random.nextDouble() * 0.5; // 模拟波动振幅
      _audioPacketController.add(
        AudioDataPacket(
          bytes: pcmBytes,
          format: AudioEncodingFormat.pcm16Bit,
          sampleRate: 16000,
          channels: 1,
          amplitude: amp,
          timestamp: DateTime.now(),
        ),
      );
    });

    return true;
  }

  @override
  Future<bool> pauseRecording() async {
    _isRecording = false;
    _isPaused = true;
    _stateChangeController.add(null);
    return true;
  }

  @override
  Future<bool> resumeRecording() async {
    _isRecording = true;
    _isPaused = false;
    _stateChangeController.add(null);
    return true;
  }

  @override
  Future<bool> stopRecording() async {
    _isRecording = false;
    _isPaused = false;
    _mockAudioTimer?.cancel();
    _mockAudioTimer = null;
    _stateChangeController.add(null);
    return true;
  }

  @override
  Future<bool> syncTime() async {
    return true;
  }

  /// 软按键：按下
  void triggerPressDown() {
    _pressDownTime = DateTime.now();
    _buttonEventController.add(
      DeviceButtonEvent(buttonId: 1, action: ButtonActionType.pressDown),
    );
  }

  /// 软按键：松开
  void triggerRelease() {
    final now = DateTime.now();
    final duration = _pressDownTime != null
        ? now.difference(_pressDownTime!).inMilliseconds
        : 0;

    _buttonEventController.add(
      DeviceButtonEvent(buttonId: 1, action: ButtonActionType.release),
    );

    if (duration >= 600) {
      _buttonEventController.add(
        DeviceButtonEvent(buttonId: 1, action: ButtonActionType.longPress),
      );
    } else {
      _registerClick();
    }
    _pressDownTime = null;
  }

  void _registerClick() {
    _clickCount++;
    _clickTimer?.cancel();
    _clickTimer = Timer(const Duration(milliseconds: 280), () {
      if (_clickCount == 1) {
        _buttonEventController.add(
          DeviceButtonEvent(buttonId: 1, action: ButtonActionType.singleClick),
        );
      } else if (_clickCount == 2) {
        _buttonEventController.add(
          DeviceButtonEvent(buttonId: 1, action: ButtonActionType.doubleClick),
        );
      } else if (_clickCount >= 3) {
        _buttonEventController.add(
          DeviceButtonEvent(buttonId: 1, action: ButtonActionType.tripleClick),
        );
      }
      _clickCount = 0;
    });
  }

  @override
  Future<bool> sendAncsConfig({required bool enable, int mode = 3}) async => true;

  @override
  Future<void> dispose() async {
    _mockAudioTimer?.cancel();
    _buttonEventController.close();
    _audioPacketController.close();
    _stateChangeController.close();
  }
}

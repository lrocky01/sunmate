import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../ble/ble_constants.dart';
import '../ble/ble_json_rpc.dart';
import '../audio/opus_stream_receiver.dart';
import '../notifications/mobile_notification_manager.dart';
import 'hardware_device_driver.dart';

/// AiNote 6095 (Telink 芯片方案) 蓝牙硬件录音卡驱动
class AiNote6095Driver implements HardwareDeviceDriver {
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _cmdChar;
  BluetoothCharacteristic? _eventChar;
  BluetoothCharacteristic? _audioChar;

  final OpusStreamReceiver _audioReceiver = OpusStreamReceiver();

  final _buttonEventController = StreamController<DeviceButtonEvent>.broadcast();
  final _audioPacketController = StreamController<AudioDataPacket>.broadcast();
  final _stateChangeController = StreamController<void>.broadcast();

  bool _isConnected = false;
  int _batteryLevel = 85;
  bool _isRecording = false;
  bool _isPaused = false;
  String _deviceName = "AiNote 6095";

  // 按键多击判定
  int _clickCount = 0;
  Timer? _clickTimer;
  bool _isLongPressing = false;
  DateTime? _pressDownTime;

  AiNote6095Driver() {
    // 监听底层 OpusStreamReceiver，封装为通用的 AudioDataPacket
    _audioReceiver.audioStream.listen((opusPacket) {
      // 估算振幅能量 (基于 payload 数据能量估算，用于 UI 波形指示)
      double amp = 0.0;
      if (opusPacket.opusData.isNotEmpty) {
        int sum = 0;
        for (int i = 0; i < opusPacket.opusData.length; i++) {
          sum += (opusPacket.opusData[i] - 128).abs();
        }
        amp = min(1.0, (sum / opusPacket.opusData.length) / 64.0);
      }

      _audioPacketController.add(
        AudioDataPacket(
          bytes: opusPacket.opusData,
          format: AudioEncodingFormat.rawOpus,
          sampleRate: 16000,
          channels: 1,
          amplitude: amp,
          timestamp: DateTime.now(),
        ),
      );
    });
  }

  @override
  HardwareDeviceType get deviceType => HardwareDeviceType.ainote6095Ble;

  @override
  String get displayName => _deviceName;

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

  /// 扫描附近 6095 录音卡
  Stream<List<ScanResult>> scanNearbyDevices() {
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    return FlutterBluePlus.scanResults;
  }

  /// 连接特定蓝牙外设
  Future<bool> connectDevice(BluetoothDevice device) async {
    try {
      await device.connect(autoConnect: false);
      _connectedDevice = device;
      _deviceName = device.platformName.isNotEmpty ? device.platformName : "AiNote 6095";

      final services = await device.discoverServices();
      for (final service in services) {
        if (service.uuid.toString().toLowerCase() == BleConstants.serviceOpus.toLowerCase()) {
          for (final char in service.characteristics) {
            final uuid = char.uuid.toString().toLowerCase();
            if (uuid == BleConstants.charAppCmdWrite.toLowerCase()) {
              _cmdChar = char;
            } else if (uuid == BleConstants.charDeviceEvent.toLowerCase()) {
              _eventChar = char;
              await char.setNotifyValue(true);
              char.onValueReceived.listen(_handleEventNotify);
            } else if (uuid == BleConstants.charOpusAudioData.toLowerCase()) {
              _audioChar = char;
              await char.setNotifyValue(true);
              char.onValueReceived.listen((raw) {
                _audioReceiver.feedBlePacket(Uint8List.fromList(raw));
              });
            }
          }
        }
      }

      _isConnected = true;
      _stateChangeController.add(null);

      // 同步时钟与查询硬件状态
      await syncTime();
      await _sendCommand(BleJsonRpc.getStatus());
      return true;
    } catch (e) {
      _isConnected = false;
      _stateChangeController.add(null);
      return false;
    }
  }

  @override
  Future<bool> connect() async {
    // 默认自动扫描并连接首个匹配设备，若已有设备则连接
    if (_connectedDevice != null) {
      return connectDevice(_connectedDevice!);
    }
    _isConnected = true; // 占位连接状态
    _stateChangeController.add(null);
    return true;
  }

  @override
  Future<void> disconnect() async {
    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
      _connectedDevice = null;
    }
    _isConnected = false;
    _isRecording = false;
    _isPaused = false;
    _stateChangeController.add(null);
  }

  @override
  Future<bool> startRecording() async {
    if (!_isConnected) return false;
    _audioReceiver.startCollecting();
    await _sendCommand(BleJsonRpc.startRecord(scene: "meeting"));
    _isRecording = true;
    _isPaused = false;
    _stateChangeController.add(null);
    return true;
  }

  @override
  Future<bool> pauseRecording() async {
    if (!_isConnected || !_isRecording) return false;
    await _sendCommand(BleJsonRpc.pauseRecord());
    _isRecording = false;
    _isPaused = true;
    _stateChangeController.add(null);
    return true;
  }

  @override
  Future<bool> resumeRecording() async {
    if (!_isConnected || !_isPaused) return false;
    await _sendCommand(BleJsonRpc.resumeRecord());
    _isRecording = true;
    _isPaused = false;
    _stateChangeController.add(null);
    return true;
  }

  @override
  Future<bool> stopRecording() async {
    if (!_isConnected) return false;
    await _sendCommand(BleJsonRpc.stopRecord());
    _isRecording = false;
    _isPaused = false;
    _stateChangeController.add(null);
    return true;
  }

  @override
  Future<bool> syncTime() async {
    if (_cmdChar == null) return false;
    await _sendCommand(BleJsonRpc.syncTime());
    return true;
  }

  @override
  Future<bool> sendAncsConfig({required bool enable, int mode = 3}) async {
    if (_cmdChar == null) return false;
    await _sendCommand(BleJsonRpc.setAncsConfig(enable: enable, mode: mode));
    return true;
  }

  Future<void> _sendCommand(Uint8List bytes) async {
    if (_cmdChar != null) {
      await _cmdChar!.write(bytes, withoutResponse: false);
    }
  }

  /// 处理 2B30 特征值上报
  void _handleEventNotify(List<int> bytes) {
    if (bytes.isEmpty) return;
    final eventId = bytes[0];

    // 按键按下
    if (eventId == 0x01 || eventId == 0x10) {
      _pressDownTime = DateTime.now();
      _isLongPressing = true;
      _buttonEventController.add(
        DeviceButtonEvent(buttonId: 1, action: ButtonActionType.pressDown),
      );
    }
    // 按键松开
    else if (eventId == 0x02 || eventId == 0x11) {
      final now = DateTime.now();
      final pressDuration = _pressDownTime != null
          ? now.difference(_pressDownTime!).inMilliseconds
          : 0;

      _buttonEventController.add(
        DeviceButtonEvent(buttonId: 1, action: ButtonActionType.release),
      );

      if (pressDuration >= 600) {
        // 长按判定
        _buttonEventController.add(
          DeviceButtonEvent(buttonId: 1, action: ButtonActionType.longPress),
        );
      } else {
        // 单击 / 多击
        _registerClick();
      }
      _isLongPressing = false;
      _pressDownTime = null;
    }
    // 状态与电量通知
    else if (eventId == 0x05 && bytes.length >= 3) {
      _batteryLevel = bytes[1];
      final recState = bytes[2];
      _isRecording = (recState == 1);
      _isPaused = (recState == 2);
      _stateChangeController.add(null);
    }
    // 硬件 ANCS 系统通知透传
    else if (eventId == BleConstants.eventAncsNotification && bytes.length > 2) {
      _handleAncsPayload(bytes.sublist(1));
    }
  }

  void _handleAncsPayload(List<int> payload) {
    try {
      final text = utf8.decode(payload, allowMalformed: true);
      if (text.startsWith("{") && text.endsWith("}")) {
        final map = jsonDecode(text) as Map<String, dynamic>;
        final app = map["app"]?.toString() ?? map["pkg"]?.toString() ?? "unknown";
        final title = map["title"]?.toString() ?? "";
        final body = map["body"]?.toString() ?? map["content"]?.toString() ?? "";
        final ts = map["timestamp"] != null
            ? DateTime.fromMillisecondsSinceEpoch((map["timestamp"] as int) * 1000)
            : DateTime.now();

        MobileNotificationManager().onIosAncsNotificationPosted(
          appIdentifier: app,
          title: title,
          message: body,
          timestamp: ts,
        );
      }
    } catch (_) {}
  }

  void _registerClick() {
    _clickCount++;
    _clickTimer?.cancel();
    _clickTimer = Timer(const Duration(milliseconds: 300), () {
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

  /// 允许模拟注入按键事件 (便于开发测试与调试)
  void simulateButtonEvent(ButtonActionType action) {
    _buttonEventController.add(DeviceButtonEvent(buttonId: 1, action: action));
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    _buttonEventController.close();
    _audioPacketController.close();
    _stateChangeController.close();
    _audioReceiver.dispose();
  }
}

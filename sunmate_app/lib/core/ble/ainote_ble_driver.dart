import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../../models/device_status.dart';
import '../audio/opus_stream_receiver.dart';
import 'ble_constants.dart';
import 'ble_json_rpc.dart';

/// 按键交互原始事件类型
enum HardwareButtonEvent {
  singleClick,
  doubleClick,
  tripleClick,
  longPressStart,
  longPressEnd,
}

/// 录音卡核心蓝牙驱动
class AiNoteBleDriver {
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _cmdChar;
  BluetoothCharacteristic? _eventChar;
  BluetoothCharacteristic? _audioChar;

  final OpusStreamReceiver audioReceiver = OpusStreamReceiver();

  final _statusController = StreamController<DeviceStatus>.broadcast();
  Stream<DeviceStatus> get statusStream => _statusController.stream;

  final _buttonEventController = StreamController<HardwareButtonEvent>.broadcast();
  Stream<HardwareButtonEvent> get buttonEventStream => _buttonEventController.stream;

  DeviceStatus _currentStatus = const DeviceStatus();
  DeviceStatus get currentStatus => _currentStatus;

  // 按键点击判定定时器与计数器
  int _clickCount = 0;
  Timer? _clickTimer;
  bool _isLongPressing = false;

  /// 1. 扫描附近的录音卡设备
  Stream<List<ScanResult>> scanDevices() {
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    return FlutterBluePlus.scanResults;
  }

  /// 2. 连接目标设备
  Future<bool> connect(BluetoothDevice device) async {
    try {
      await device.connect(autoConnect: false);
      _connectedDevice = device;

      // 发现服务
      final services = await device.discoverServices();
      for (final service in services) {
        if (service.uuid.toString().toLowerCase() == BleConstants.serviceOpus.toLowerCase()) {
          for (final char in service.characteristics) {
            final uuidStr = char.uuid.toString().toLowerCase();
            if (uuidStr == BleConstants.charAppCmdWrite.toLowerCase()) {
              _cmdChar = char;
            } else if (uuidStr == BleConstants.charDeviceEvent.toLowerCase()) {
              _eventChar = char;
              await char.setNotifyValue(true);
              char.onValueReceived.listen(_handleDeviceEventNotify);
            } else if (uuidStr == BleConstants.charOpusAudioData.toLowerCase()) {
              _audioChar = char;
              await char.setNotifyValue(true);
              char.onValueReceived.listen((data) {
                audioReceiver.feedBlePacket(Uint8List.fromList(data));
              });
            }
          }
        }
      }

      _currentStatus = _currentStatus.copyWith(
        isConnected: true,
        deviceName: device.platformName.isNotEmpty ? device.platformName : "AiNote 6095",
        deviceId: device.remoteId.str,
      );
      _statusController.add(_currentStatus);

      // 连接建立后自动同步时钟并查询状态
      await sendCommand(BleJsonRpc.syncTime());
      await sendCommand(BleJsonRpc.getStatus());
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 3. 断开连接
  Future<void> disconnect() async {
    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
      _connectedDevice = null;
    }
    _currentStatus = const DeviceStatus();
    _statusController.add(_currentStatus);
  }

  /// 4. 向硬件下发命令
  Future<void> sendCommand(Uint8List bytes) async {
    if (_cmdChar != null) {
      await _cmdChar!.write(bytes, withoutResponse: false);
    }
  }

  /// 5. 处理硬件 2B30 上报的设备状态与按键通知
  void _handleDeviceEventNotify(List<int> bytes) {
    if (bytes.isEmpty) return;

    // 解析事件字节 (根据逆向分析，第一字节为 Event ID)
    final eventId = bytes[0];

    // 事件: 按键按下
    if (eventId == 0x01 || eventId == 0x10) {
      // 开启长按判定检测
      _isLongPressing = true;
      _buttonEventController.add(HardwareButtonEvent.longPressStart);
    }
    // 事件: 按键释放
    else if (eventId == 0x02 || eventId == 0x11) {
      if (_isLongPressing) {
        _isLongPressing = false;
        _buttonEventController.add(HardwareButtonEvent.longPressEnd);
      } else {
        _registerClick();
      }
    }
    // 事件: 状态更新 (电量/录音状态)
    else if (eventId == 0x05 && bytes.length >= 4) {
      final battery = bytes[1];
      final recState = bytes[2];
      _currentStatus = _currentStatus.copyWith(
        batteryLevel: battery,
        recordingState: recState,
      );
      _statusController.add(_currentStatus);
    }
    // 事件: 硬件 ANCS (Apple Notification Center Service) 透传 iOS 系统通知
    else if (eventId == BleConstants.eventAncsNotification && bytes.length > 2) {
      _handleAncsNotificationPayload(bytes.sublist(1));
    }
  }

  /// 解析硬件上报的 ANCS 系统通知数据包
  void _handleAncsNotificationPayload(List<int> payload) {
    try {
      // 1. 尝试作为 UTF-8 JSON 解析
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
        return;
      }

      // 2. 备用 TLV / 零终止字符串解析
      // 结构: [appId\0][title\0][body]
      final parts = <String>[];
      var start = 0;
      for (var i = 0; i < payload.length; i++) {
        if (payload[i] == 0) {
          parts.add(utf8.decode(payload.sublist(start, i), allowMalformed: true));
          start = i + 1;
        }
      }
      if (start < payload.length) {
        parts.add(utf8.decode(payload.sublist(start), allowMalformed: true));
      }

      if (parts.isNotEmpty) {
        final app = parts[0];
        final title = parts.length > 1 ? parts[1] : "";
        final body = parts.length > 2 ? parts[2] : "";
        MobileNotificationManager().onIosAncsNotificationPosted(
          appIdentifier: app,
          title: title,
          message: body,
          timestamp: DateTime.now(),
        );
      }
    } catch (_) {
      // 容错处理
    }
  }

  /// 本地判定单击、双击、三击
  void _registerClick() {
    _clickCount++;
    _clickTimer?.cancel();
    _clickTimer = Timer(const Duration(milliseconds: 280), () {
      if (_clickCount == 1) {
        _buttonEventController.add(HardwareButtonEvent.singleClick);
      } else if (_clickCount == 2) {
        _buttonEventController.add(HardwareButtonEvent.doubleClick);
      } else if (_clickCount >= 3) {
        _buttonEventController.add(HardwareButtonEvent.tripleClick);
      }
      _clickCount = 0;
    });
  }

  void dispose() {
    _statusController.close();
    _buttonEventController.close();
    audioReceiver.dispose();
  }
}

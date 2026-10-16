import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../ble/ble_constants.dart';
import '../ble/ble_json_rpc.dart';
import '../audio/opus_stream_receiver.dart';
import '../notifications/mobile_notification_manager.dart';
import 'hardware_device_driver.dart';

/// AiNote 6095 (Telink 芯片方案) 蓝牙硬件录音卡驱动
class AiNote6095Driver implements HardwareDeviceDriver {
  static const String _prefKeyLastDeviceId = "sunmate_last_ble_device_id";
  static const String _prefKeyLastDeviceName = "sunmate_last_ble_device_name";

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _cmdChar;
  BluetoothCharacteristic? _eventChar;
  BluetoothCharacteristic? _audioChar;

  final OpusStreamReceiver _audioReceiver = OpusStreamReceiver();

  final _buttonEventController = StreamController<DeviceButtonEvent>.broadcast();
  final _audioPacketController = StreamController<AudioDataPacket>.broadcast();
  final _stateChangeController = StreamController<void>.broadcast();

  bool _isConnected = false;
  int _batteryLevel = 0;
  bool _isRecording = false;
  bool _isPaused = false;
  String _deviceName = "未连接设备";
  Uint8List? _lastRecordedBytes;
  Uint8List? get lastRecordedBytes => _lastRecordedBytes;
  String? lastErrorMessage;

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

    // 启动时自动尝试静默重连上次绑定的设备 (对齐官方 BleScanReconnectController)
    autoReconnectLastDevice();
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
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    return FlutterBluePlus.scanResults;
  }

  /// 自动尝试重连上次配对绑定的设备
  Future<bool> autoReconnectLastDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastId = prefs.getString(_prefKeyLastDeviceId);
      if (lastId == null || lastId.isEmpty) return false;

      final savedName = prefs.getString(_prefKeyLastDeviceName);
      if (savedName != null && savedName.isNotEmpty) {
        _deviceName = savedName;
      }

      // 快速通过已存 remoteId 构造设备并重连
      final device = BluetoothDevice.fromId(lastId);
      return await connectDevice(device, isAutoReconnect: true);
    } catch (_) {
      return false;
    }
  }

  /// 连接特定蓝牙外设并执行官方标准的 bindRequest 与 verifyIdentity 鉴权握手
  Future<bool> connectDevice(BluetoothDevice device, {bool isAutoReconnect = false}) async {
    lastErrorMessage = null;
    try {
      // 1. 核心关键防冲突：先停止正在运行的全局扫描，独占 iOS CoreBluetooth 通道
      await FlutterBluePlus.stopScan();

      // 2. 若此前曾连过该设备，先安全断开
      try {
        await device.disconnect();
      } catch (_) {}

      // 3. 发起 GATT 物理连接
      await device.connect(autoConnect: false, timeout: const Duration(seconds: 15));
      _connectedDevice = device;
      _deviceName = device.platformName.isNotEmpty ? device.platformName : "AiNote 录音卡";

      // 4. iOS 关键时序：等待 300ms 让蓝牙底层 MTU 与连接间隔握手稳定
      await Future.delayed(const Duration(milliseconds: 300));

      // 5. 发现所有 GATT 服务
      final services = await device.discoverServices();
      
      // 策略一：查找私有主服务 (匹配 1913)
      BluetoothService? opusService;
      for (final service in services) {
        final cleanUuid = service.uuid.str.replaceAll("-", "").toLowerCase();
        if (cleanUuid.contains("1913") || cleanUuid == "000102030405060708090a0b0c0d1913") {
          opusService = service;
          break;
        }
      }

      // 策略二：若未严格匹配 1913，查找具备可写与通知特性的非系统通用私有服务 (兼容各种 CONE/OEM 固件)
      if (opusService == null) {
        for (final s in services) {
          final isStandardGatt = s.uuid.str.toLowerCase().startsWith("000018");
          if (!isStandardGatt) {
            final hasWrite = s.characteristics.any((c) => c.properties.write || c.properties.writeWithoutResponse);
            final hasNotify = s.characteristics.any((c) => c.properties.notify || c.properties.indicate);
            if (hasWrite && hasNotify) {
              opusService = s;
              break;
            }
          }
        }
      }

      if (opusService != null) {
        for (final char in opusService.characteristics) {
          final cleanUuid = char.uuid.str.replaceAll("-", "").toLowerCase();
          if (cleanUuid.contains("2b15") || char.properties.write) {
            _cmdChar = char;
          } else if (cleanUuid.contains("2b30") || (char.properties.notify && _eventChar == null)) {
            _eventChar = char;
          } else if (cleanUuid.contains("2b31") || (char.properties.notify && _eventChar != null)) {
            _audioChar = char;
          }
        }
      }

      // 6. 安全开启特征值 Notify 监听 (带微延迟防抖)
      if (_eventChar != null) {
        try {
          await _eventChar!.setNotifyValue(true);
          _eventChar!.onValueReceived.listen(_handleEventNotify);
        } catch (e) {
          print("开启事件通道监听提示: $e");
        }
      }

      if (_audioChar != null) {
        try {
          await Future.delayed(const Duration(milliseconds: 150));
          await _audioChar!.setNotifyValue(true);
          _audioChar!.onValueReceived.listen((raw) {
            _audioReceiver.feedBlePacket(Uint8List.fromList(raw));
          });
        } catch (e) {
          print("开启音频流通道监听提示: $e");
        }
      }

      // 7. 发送初始化握手与认证指令 (带异常容错)
      try {
        await _sendCommand(BleJsonRpc.bindRequest());
        await Future.delayed(const Duration(milliseconds: 100));
        await _sendCommand(BleJsonRpc.verifyIdentity());
        await Future.delayed(const Duration(milliseconds: 100));
        await syncTime();
        await _sendCommand(BleJsonRpc.getStatus());
      } catch (e) {
        print("握手指令下发提示: $e");
      }

      // 8. 持久化记录设备 ID，实现下次启动无感秒连
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyLastDeviceId, device.remoteId.str);
      await prefs.setString(_prefKeyLastDeviceName, _deviceName);

      _isConnected = true;
      _stateChangeController.add(null);
      return true;
    } catch (e) {
      lastErrorMessage = e.toString();
      print("连接蓝牙设备出现异常: $e");
      if (!isAutoReconnect) {
        _isConnected = false;
        _stateChangeController.add(null);
      }
      return false;
    }
  }

  @override
  Future<bool> connect() async {
    if (_connectedDevice != null) {
      return connectDevice(_connectedDevice!);
    }
    return await autoReconnectLastDevice();
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

  /// 解除当前设备绑定，清除本地持久化缓存
  Future<void> unpairDevice() async {
    await disconnect();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKeyLastDeviceId);
    await prefs.remove(_prefKeyLastDeviceName);
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
    _lastRecordedBytes = _audioReceiver.stopAndExport();
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

    // 检查是否为 JSON-RPC 事件或主动身份验证请求 (例如 verifyIdentityRequest)
    if (bytes.length > 4) {
      try {
        final text = utf8.decode(bytes, allowMalformed: true);
        if (text.contains("verifyIdentityRequest")) {
          _sendCommand(BleJsonRpc.verifyIdentity());
        }
      } catch (_) {}
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

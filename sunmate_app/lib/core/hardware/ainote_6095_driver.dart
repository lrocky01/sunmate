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
  BluetoothCharacteristic? _batteryChar;

  StreamSubscription? _connectionStateSub;
  StreamSubscription? _eventSub;
  StreamSubscription? _audioSub;
  StreamSubscription? _batterySub;

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

      // 2. 若此前曾连过该设备，先安全断开并取消所有老监听
      await _cleanConnection();
      try {
        await device.disconnect();
      } catch (_) {}

      // 3. 发起 GATT 物理连接
      await device.connect(autoConnect: false, timeout: const Duration(seconds: 15));
      _connectedDevice = device;
      _deviceName = device.platformName.isNotEmpty ? device.platformName : "AiNote 录音卡";

      // 4. 监听底层连接状态变化，外设一旦断开立即感知并更新状态
      _connectionStateSub = device.connectionState.listen((connState) {
        if (connState == BluetoothConnectionState.disconnected) {
          print("BLE 硬件已断开连接");
          _isConnected = false;
          _isRecording = false;
          _isPaused = false;
          _stateChangeController.add(null);
        }
      });

      // 5. iOS 关键时序：等待 400ms 让蓝牙底层链路与 MTU 协商稳定
      await Future.delayed(const Duration(milliseconds: 400));

      // 6. 发现所有 GATT 服务
      final services = await device.discoverServices();
      await Future.delayed(const Duration(milliseconds: 150));

      // 7. 全局精准扫描特征值 (标准电池 2A19、私有命令 2B15、事件 2B30、音频 2B31)
      _cmdChar = null;
      _eventChar = null;
      _audioChar = null;
      _batteryChar = null;

      for (final service in services) {
        for (final char in service.characteristics) {
          final cleanUuid = char.uuid.str.replaceAll("-", "").toLowerCase();

          // (1) 标准电池服务特征值 (0x2A19)
          if (cleanUuid.contains("2a19")) {
            _batteryChar = char;
          }
          // (2) 录音卡命令下发特征值 (0x2B15)
          else if (cleanUuid.contains("2b15")) {
            _cmdChar = char;
          }
          // (3) 录音卡状态/按键/ANCS 事件上报特征值 (0x2B30)
          else if (cleanUuid.contains("2b30")) {
            _eventChar = char;
          }
          // (4) 录音卡实时 Opus 音频流数据特征值 (0x2B31)
          else if (cleanUuid.contains("2b31")) {
            _audioChar = char;
          }
        }
      }

      // 兜底策略：若部分 OEM 固件未暴露精确 2B15/2B30 UUID，定位非标准私有服务中具备 Write/Notify 特征的通道
      if (_cmdChar == null || _eventChar == null) {
        for (final service in services) {
          final isStandard = service.uuid.str.toLowerCase().startsWith("000018");
          if (!isStandard) {
            for (final char in service.characteristics) {
              if (_cmdChar == null && (char.properties.write || char.properties.writeWithoutResponse)) {
                _cmdChar = char;
              } else if (_eventChar == null && (char.properties.notify || char.properties.indicate)) {
                _eventChar = char;
              } else if (_audioChar == null && (char.properties.notify || char.properties.indicate)) {
                _audioChar = char;
              }
            }
          }
        }
      }

      // 8. 严格校验核心通道：若未发现命令与事件通道，决不误报连接成功
      if (_cmdChar == null || _eventChar == null) {
        throw Exception("未能检测到录音卡核心通道 (2B15/2B30)。请确认硬件已开机并处于可配对状态。");
      }

      // 9. 读取标准电池服务 (0x2A19)
      // 【关键机制】：在 iOS 上，主动向外设读取受保护的标准电池特征值，是诱发系统弹出【蓝牙配对请求】弹窗的黄金契机！
      if (_batteryChar != null) {
        try {
          final batteryBytes = await _batteryChar!.read();
          if (batteryBytes.isNotEmpty && batteryBytes[0] > 0 && batteryBytes[0] <= 100) {
            _batteryLevel = batteryBytes[0];
            print("成功读取到硬件标准电量: $_batteryLevel%");
            _stateChangeController.add(null);
          }
        } catch (e) {
          print("读取电池特征值提示 (iOS 可能正弹出配对弹窗，或需握手后读取): $e");
        }

        try {
          await _batteryChar!.setNotifyValue(true);
          _batterySub = _batteryChar!.onValueReceived.listen((data) {
            if (data.isNotEmpty && data[0] > 0 && data[0] <= 100) {
              _batteryLevel = data[0];
              _stateChangeController.add(null);
            }
          });
        } catch (_) {}
      }

      // 10. 在 Android 平台尝试主动发起系统级配对 (iOS 系统会自动由特征值访问挑战驱动)
      try {
        await device.createBond();
      } catch (_) {}

      // 11. 开启事件上报通道 Notify (带延时防抖)
      try {
        await _eventChar!.setNotifyValue(true);
        _eventSub = _eventChar!.onValueReceived.listen(_handleEventNotify);
      } catch (e) {
        print("开启事件通道监听提示: $e");
      }

      // 12. 开启实时音频流通道 Notify
      if (_audioChar != null) {
        try {
          await Future.delayed(const Duration(milliseconds: 150));
          await _audioChar!.setNotifyValue(true);
          _audioSub = _audioChar!.onValueReceived.listen((raw) {
            _audioReceiver.feedBlePacket(Uint8List.fromList(raw));
          });
        } catch (e) {
          print("开启音频流通道监听提示: $e");
        }
      }

      // 13. 发送官方鉴权与状态机握手指令 (bindRequest + verifyIdentity + syncTime + getStatus)
      try {
        await Future.delayed(const Duration(milliseconds: 150));
        await _sendCommand(BleJsonRpc.bindRequest());

        await Future.delayed(const Duration(milliseconds: 150));
        await _sendCommand(BleJsonRpc.verifyIdentity());

        await Future.delayed(const Duration(milliseconds: 150));
        await syncTime();

        await Future.delayed(const Duration(milliseconds: 150));
        await _sendCommand(BleJsonRpc.getStatus());
      } catch (e) {
        print("握手指令序列下发提示: $e");
      }

      // 14. 标记就绪并持久化记录设备 ID，实现下次启动无感秒连
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyLastDeviceId, device.remoteId.str);
      await prefs.setString(_prefKeyLastDeviceName, _deviceName);

      _isConnected = true;
      _stateChangeController.add(null);
      return true;
    } catch (e) {
      lastErrorMessage = e.toString();
      print("连接蓝牙设备出现异常: $e");
      await _cleanConnection();
      _isConnected = false;
      _stateChangeController.add(null);
      return false;
    }
  }

  Future<void> _cleanConnection() async {
    await _connectionStateSub?.cancel();
    _connectionStateSub = null;
    await _eventSub?.cancel();
    _eventSub = null;
    await _audioSub?.cancel();
    _audioSub = null;
    await _batterySub?.cancel();
    _batterySub = null;
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
    await _cleanConnection();
    if (_connectedDevice != null) {
      try {
        await _connectedDevice!.disconnect();
      } catch (_) {}
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
      try {
        final withoutResp = _cmdChar!.properties.writeWithoutResponse && !_cmdChar!.properties.write;
        await _cmdChar!.write(bytes, withoutResponse: withoutResp);
      } catch (e) {
        try {
          await _cmdChar!.write(bytes, withoutResponse: true);
        } catch (_) {}
      }
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
    // 状态与电量通知 (0x05 二进制包)
    else if (eventId == 0x05 && bytes.length >= 3) {
      final bat = bytes[1];
      if (bat > 0 && bat <= 100) {
        _batteryLevel = bat;
      }
      final recState = bytes[2];
      _isRecording = (recState == 1);
      _isPaused = (recState == 2);
      _stateChangeController.add(null);
    }
    // 硬件 ANCS 系统通知透传
    else if (eventId == BleConstants.eventAncsNotification && bytes.length > 2) {
      _handleAncsPayload(bytes.sublist(1));
    }

    // 检查是否为 JSON-RPC 事件或主动身份验证请求 (例如 verifyIdentityRequest 或 getStatus 响应)
    if (bytes.length > 4) {
      try {
        final text = utf8.decode(bytes, allowMalformed: true);
        if (text.contains("verifyIdentityRequest")) {
          _sendCommand(BleJsonRpc.verifyIdentity());
        }
        if (text.contains('"battery"') || text.contains('"recording_state"')) {
          final startIdx = text.indexOf('{');
          final endIdx = text.lastIndexOf('}');
          if (startIdx != -1 && endIdx > startIdx) {
            final jsonSub = text.substring(startIdx, endIdx + 1);
            final map = jsonDecode(jsonSub) as Map<String, dynamic>;
            final res = map["result"] ?? map;
            if (res is Map<String, dynamic>) {
              final bat = res["battery"];
              if (bat is int && bat > 0 && bat <= 100) {
                _batteryLevel = bat;
              }
              final rec = res["recording_state"];
              if (rec is int) {
                _isRecording = (rec == 1);
                _isPaused = (rec == 2);
              }
              _stateChangeController.add(null);
            }
          }
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

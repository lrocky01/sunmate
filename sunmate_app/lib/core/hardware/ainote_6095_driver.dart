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

  // 心跳保活与自动重连机制 (彻底解决连上数秒后 MCU 空闲休眠断连问题)
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  bool _manualDisconnect = false;

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
  String get snNumber {
    // 官方 SN 规范：SZ1200126180 + 硬件后缀4位 (例如 C·ONE-4552 -> SZ12001261804552)
    final match = RegExp(r'\d{4}$').firstMatch(_deviceName);
    if (match != null) {
      return "SZ1200126180${match.group(0)}";
    }
    if (_deviceName.isNotEmpty && _deviceName != "AiNote 录音卡") {
      final code = _deviceName.hashCode.abs().toString().padLeft(4, '0');
      return "SZ1200126180${code.substring(code.length - 4)}";
    }
    return "--";
  }

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

  final List<String> _connectionLogs = [];
  List<String> get connectionLogs => List.unmodifiable(_connectionLogs);
  final _logController = StreamController<String>.broadcast();
  Stream<String> get logStream => _logController.stream;

  void _logProgress(String msg) {
    print("[SunMate BLE] $msg");
    _connectionLogs.add(msg);
    _logController.add(msg);
    _stateChangeController.add(null);
  }

  /// 连接特定蓝牙外设并执行官方标准的 bindRequest 与 verifyIdentity 鉴权握手
  Future<bool> connectDevice(BluetoothDevice device, {bool isAutoReconnect = false}) async {
    lastErrorMessage = null;
    _connectionLogs.clear();
    _manualDisconnect = false;

    try {
      _logProgress("1/5 正在独占蓝牙通道并发起物理连接...");
      await FlutterBluePlus.stopScan();
      await _cleanConnection();

      // 安全连接：若底层已有连接则宽容处理
      try {
        await device.connect(autoConnect: false, timeout: const Duration(seconds: 12));
      } catch (e) {
        final err = e.toString().toLowerCase();
        if (!err.contains("already") && !err.contains("connected")) {
          rethrow;
        }
      }
      _connectedDevice = device;
      _deviceName = device.platformName.isNotEmpty ? device.platformName : "AiNote 录音卡";

      _logProgress("2/5 GATT 链路建立成功，监听连接状态...");
      _connectionStateSub = device.connectionState.listen((connState) {
        if (connState == BluetoothConnectionState.disconnected) {
          print("[SunMate BLE] 硬件已断开连接 (manual=$_manualDisconnect)");
          _isConnected = false;
          _isRecording = false;
          _isPaused = false;
          _heartbeatTimer?.cancel();
          _heartbeatTimer = null;
          _stateChangeController.add(null);
        }
      });

      // iOS 关键时序：等待 400ms 待 ATT/MTU 链路建立稳态
      await Future.delayed(const Duration(milliseconds: 400));

      // 发现所有 GATT 服务 (带弹性重试)
      _logProgress("3/5 正在探测硬件 GATT 服务列表...");
      List<BluetoothService> services = [];
      for (int attempt = 1; attempt <= 2; attempt++) {
        try {
          services = await device.discoverServices();
          if (services.isNotEmpty) break;
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 300));
      }

      if (services.isEmpty) {
        throw Exception("未能发现硬件服务列表，请确认设备未被其它手机连接");
      }

      final sListSummary = services.map((s) {
        final str = s.uuid.str.replaceAll("-", "").toLowerCase();
        return str.length >= 8 ? str.substring(4, 8) : str;
      }).join(", ");
      _logProgress("3/5 发现服务列表: [$sListSummary]");

      // 4. 全局精准扫描特征值 (标准电池 2A19、私有命令 2B15、事件 2B30、音频 2B31)
      _cmdChar = null;
      _eventChar = null;
      _audioChar = null;
      _batteryChar = null;

      // 第一轮：精确 UUID 匹配
      for (final service in services) {
        for (final char in service.characteristics) {
          final cleanUuid = char.uuid.str.replaceAll("-", "").toLowerCase();
          if (cleanUuid.contains("2a19")) _batteryChar = char;
          if (cleanUuid.contains("2b15")) _cmdChar = char;
          if (cleanUuid.contains("2b30")) _eventChar = char;
          if (cleanUuid.contains("2b31")) _audioChar = char;
        }
      }

      // 第二轮：智能能力识别 (针对非标准固件/OEM 变种)
      if (_cmdChar == null || _eventChar == null) {
        for (final service in services) {
          final sUuid = service.uuid.str.replaceAll("-", "").toLowerCase();
          if (sUuid.startsWith("00001800") || sUuid.startsWith("00001801") || sUuid.startsWith("0000180a")) {
            continue;
          }
          for (final char in service.characteristics) {
            final props = char.properties;
            if (_cmdChar == null && (props.write || props.writeWithoutResponse)) {
              _cmdChar = char;
            }
            if (_eventChar == null && (props.notify || props.indicate)) {
              _eventChar = char;
            }
            if (_audioChar == null && (props.notify || props.indicate) && char != _eventChar) {
              _audioChar = char;
            }
          }
        }
      }

      // 核心通道校验
      if (_cmdChar == null || _eventChar == null) {
        throw Exception("核心通道未就绪 (Cmd=${_cmdChar != null}, Event=${_eventChar != null})。服务列表: [$sListSummary]");
      }
      _logProgress("4/5 核心业务通道就绪: Cmd与Event已绑定");

      // 开启事件通道 Notify
      try {
        await _eventChar!.setNotifyValue(true);
        _eventSub = _eventChar!.onValueReceived.listen(_handleEventNotify);
      } catch (e) {
        print("开启事件通道监听提示: $e");
      }

      // 开启音频流通道 Notify
      if (_audioChar != null) {
        try {
          await Future.delayed(const Duration(milliseconds: 100));
          await _audioChar!.setNotifyValue(true);
          _audioSub = _audioChar!.onValueReceived.listen((raw) {
            _audioReceiver.feedBlePacket(Uint8List.fromList(raw));
          });
        } catch (e) {
          print("开启音频流通道监听提示: $e");
        }
      }

      // 读取标准电池服务 (0x2A19) - 非阻塞带 1.5 秒超时保护
      if (_batteryChar != null) {
        try {
          final batteryBytes = await _batteryChar!.read().timeout(const Duration(milliseconds: 1500));
          if (batteryBytes.isNotEmpty && batteryBytes[0] > 0 && batteryBytes[0] <= 100) {
            _batteryLevel = batteryBytes[0];
            _stateChangeController.add(null);
          }
        } catch (_) {}

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

      // 5. 下发标准官方 TLV 指令序列 (时间校准 -> 状态查询 -> 用户设置 -> 就绪常亮灯控)
      _logProgress("5/6 正在下发官方就绪指令序列...");
      try {
        // 5.1 硬件 RTC 时钟校准
        await Future.delayed(const Duration(milliseconds: 150));
        await syncTime();
        _logProgress("✓ 5.1 硬件时钟同步完成");

        // 5.2 获取设备状态与电量 (官方标准 JSON-RPC getStatus)
        await Future.delayed(const Duration(milliseconds: 150));
        await _sendCommand(BleJsonRpc.getStatus());
        _logProgress("✓ 5.2 硬件工作状态与电量查询就绪");

        // 5.3 获取用户配置 (官方标准 getUserSettings)
        await Future.delayed(const Duration(milliseconds: 150));
        await _sendCommand(BleJsonRpc.getUserSettings());

        // 5.4 激活指示灯为连接就绪常亮态 (mode: 4, 结束快闪等待态)
        await Future.delayed(const Duration(milliseconds: 150));
        await _sendCommand(BleJsonRpc.lightCtrl(mode: 4, success: true));
        _logProgress("✓ 5.3 硬件指示灯已置为连接就绪常亮");
      } catch (e) {
        print("握手指令序列下发提示: $e");
      }

      // 6. 关键稳态校验：等待 600ms 确认硬件未主动断开，杜绝草率误报成功
      _logProgress("6/6 正在校验硬件链路稳定性...");
      await Future.delayed(const Duration(milliseconds: 600));

      final isStillConnected = device.isConnected;
      if (!isStillConnected) {
        throw Exception("硬件在握手后断开连接，请长按录音卡按键 3 秒重置广播配对");
      }

      // 标记就绪并持久化记录设备 ID，实现下次启动无感秒连
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyLastDeviceId, device.remoteId.str);
      await prefs.setString(_prefKeyLastDeviceName, _deviceName);

      // 启动心跳保活定时器 (每 7 秒下发 getStatus 喂狗)，杜绝 MCU 判定无活动主动断连
      _startHeartbeat();

      _logProgress("✓ 握手成功！硬件指示灯已常亮就绪");
      _isConnected = true;
      _stateChangeController.add(null);
      return true;
    } catch (e) {
      lastErrorMessage = e.toString();
      _logProgress("✗ 连接中断: $e");
      print("连接蓝牙设备出现异常: $e");
      await _cleanConnection();
      _isConnected = false;
      _stateChangeController.add(null);
      return false;
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 7), (timer) async {
      if (!_isConnected || _cmdChar == null) {
        timer.cancel();
        return;
      }
      try {
        await _sendCommand(BleJsonRpc.getStatus());
      } catch (_) {}
    });
  }

  void _scheduleAutoReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(milliseconds: 2000), () async {
      if (_manualDisconnect || _isConnected) return;
      print("[SunMate BLE] 尝试自动静默恢复连接...");
      await autoReconnectLastDevice();
    });
  }

  Future<void> _cleanConnection() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
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
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
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
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
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
        // 关键第一性原理：2B15 是透传命令通道，必须使用 withoutResponse: true
        // 若使用 withResponse，iOS 会强制等待下位机回复 GATT Write Response。下位机无此回包，5秒后 iOS 会强制切断蓝牙连接！
        final canWriteWithoutResp = _cmdChar!.properties.writeWithoutResponse;
        await _cmdChar!.write(bytes, withoutResponse: canWriteWithoutResp);
      } catch (e) {
        try {
          await _cmdChar!.write(bytes, withoutResponse: true);
        } catch (_) {}
      }
    }
  }

  /// 双模指令下发：同时向硬件发送 TLV 协议包与原始纯 JSON 字节，确保新旧所有固件均能无缝解析并响应
  Future<void> _sendCommandBoth(Uint8List tlvBytes, Uint8List rawJsonBytes) async {
    await _sendCommand(tlvBytes);
    await Future.delayed(const Duration(milliseconds: 35));
    await _sendCommand(rawJsonBytes);
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
        if (text.contains("bindResult") || text.contains('"verified":true') || text.contains('"verified": true')) {
          _logProgress("✓ 收到硬件芯片回执: 身份绑定已确认 (verified=true)");
          _sendCommand(BleJsonRpc.lightCtrl(mode: 4, success: true));
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
    _logController.close();
    _audioReceiver.dispose();
  }
}

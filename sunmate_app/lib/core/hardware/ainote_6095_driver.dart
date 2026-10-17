import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../ble/ble_constants.dart';
import '../ble/ble_json_rpc.dart';
import '../ble/ble_protocol.dart';
import '../ble/ios_ble_connection.dart';
import '../audio/opus_stream_receiver.dart';
import 'hardware_device_driver.dart';

/// 保留 HAL 驱动入口，在完整 GATT 匹配后选择官方协议。
class AiNote6095Driver implements HardwareDeviceDriver {
  static const _lastIdKey = 'sunmate_verified_ble_device_id_v2';
  static const _lastNameKey = 'sunmate_verified_ble_device_name_v2';
  static const _diagnosticsKey = 'sunmate_ble_diagnostics_v1';
  static const _ancsKey = 'sunmate_ble_requires_ancs';
  final _ios = IosBleConnection();
  final _audioReceiver = OpusStreamReceiver();
  final _buttonEvents = StreamController<DeviceButtonEvent>.broadcast();
  final _audioPackets = StreamController<AudioDataPacket>.broadcast();
  final _stateChanges = StreamController<void>.broadcast();
  final _logs = StreamController<String>.broadcast();
  final List<String> _connectionLogs = [];
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  late final Future<void> _initialization;
  late final StreamSubscription<OpusAudioPacket> _receiverSub;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _command;
  RecorderProfile? _profile;
  RecorderEventDecoder? _decoder;
  Future<bool>? _connectionOperation;
  String? _connectingId;
  Completer<bool>? _ready;
  Timer? _saveTimer;
  Stopwatch _clock = Stopwatch();
  int _generation = 0;
  bool _disposed = false;
  bool _manualDisconnect = false;
  bool _linkEstablished = false;
  bool _isConnected = false;
  bool _isRecording = false;
  bool _isPaused = false;
  bool _requiresAncs = true;
  bool? _ancsAuthorized;
  int _batteryLevel = 0;
  String _deviceName = '未连接设备';
  String _serialNumber = '--';
  String _phase = '未连接';
  Uint8List? _lastRecordedBytes;
  String? lastErrorMessage;

  AiNote6095Driver() {
    _initialization = _loadPreferences();
    _receiverSub = _audioReceiver.audioStream.listen((packet) {
      if (!_isConnected || _disposed) return;
      _audioPackets.add(AudioDataPacket(
        bytes: packet.opusData,
        format: AudioEncodingFormat.rawOpus,
        timestamp: DateTime.now(),
      ));
    });
    // 旧版本保存的 ID 并未通过业务鉴权，不在启动时静默复用或弹授权框。
  }

  @override
  HardwareDeviceType get deviceType => HardwareDeviceType.ainote6095Ble;
  @override
  String get displayName => _deviceName;
  @override
  String get snNumber => _serialNumber;
  @override
  bool get isConnected => _isConnected;
  bool get isLinkConnected =>
      _linkEstablished && (_device?.isConnected ?? false);
  bool get isConnecting => _connectionOperation != null;
  bool get requiresAncs => _requiresAncs;
  bool? get ancsAuthorized => _ancsAuthorized;
  String get connectionSummary => _phase;
  @override
  int get batteryLevel => _batteryLevel;
  @override
  bool get isRecording => _isRecording;
  @override
  bool get isPaused => _isPaused;
  Uint8List? get lastRecordedBytes => _lastRecordedBytes;
  @override
  Stream<DeviceButtonEvent> get buttonEvents => _buttonEvents.stream;
  @override
  Stream<AudioDataPacket> get audioStream => _audioPackets.stream;
  @override
  Stream<void> get stateChanges => _stateChanges.stream;
  Stream<String> get logStream => _logs.stream;
  List<String> get connectionLogs => List.unmodifiable(_connectionLogs);
  String get diagnosticText => [
        'SunMate 1.0.11+12',
        '当前阶段: $_phase',
        '设备: $_deviceName',
        '协议: ${_profile?.protocol.name ?? "未识别"}',
        '链路: $isLinkConnected; 业务就绪: $_isConnected; ANCS: ${_ancsAuthorized ?? "未知"}',
        ..._connectionLogs,
      ].join('\n');

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _requiresAncs = prefs.getBool(_ancsKey) ?? true;
    _connectionLogs.addAll(prefs.getStringList(_diagnosticsKey) ?? []);
    if (!_disposed) _stateChanges.add(null);
  }

  void _log(String message) {
    if (_disposed) return;
    final line =
        '${DateTime.now().toIso8601String()} +${_clock.elapsedMilliseconds}ms [$_phase] $message';
    _connectionLogs.add(line);
    if (_connectionLogs.length > 300) _connectionLogs.removeAt(0);
    _logs.add(line);
    _stateChanges.add(null);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_saveLogs());
    });
  }

  Future<void> _saveLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_diagnosticsKey, List.of(_connectionLogs));
  }

  Stream<List<ScanResult>> scanNearbyDevices() {
    unawaited(FlutterBluePlus.startScan(timeout: const Duration(seconds: 12)));
    return FlutterBluePlus.scanResults;
  }

  Future<bool> autoReconnectLastDevice() async {
    await _initialization;
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_lastIdKey);
    if (id == null || _disposed) return false;
    _deviceName = prefs.getString(_lastNameKey) ?? '录音卡';
    return connectDevice(BluetoothDevice.fromId(id), isAutoReconnect: true);
  }

  /// 同一次连接只允许一个流程；自动重连与点击连接不能互相覆盖。
  Future<bool> connectDevice(BluetoothDevice device,
      {bool isAutoReconnect = false}) {
    if (_disposed) return Future.value(false);
    if (_connectionOperation != null) {
      if (_connectingId == device.remoteId.str) return _connectionOperation!;
      _log('另一个连接正在进行，请先取消');
      return Future.value(false);
    }
    _connectingId = device.remoteId.str;
    final operation = _connectDevice(device, isAutoReconnect);
    _connectionOperation = operation;
    unawaited(operation.whenComplete(() {
      if (_connectionOperation == operation) {
        _connectionOperation = null;
        _connectingId = null;
        if (!_disposed) _stateChanges.add(null);
      }
    }));
    return operation;
  }

  Future<bool> _connectDevice(BluetoothDevice device, bool automatic) async {
    final generation = ++_generation;
    try {
      await _initialization;
      _checkGeneration(generation);
      _clock = Stopwatch()..start();
      _connectionLogs.clear();
      lastErrorMessage = null;
      _manualDisconnect = false;
      _isConnected = false;
      _ancsAuthorized = null;
      _serialNumber = '--';
      _batteryLevel = 0;
      _phase = '准备连接';
      _ready = Completer<bool>();
      await FlutterBluePlus.stopScan();
      await _clearSubscriptions();
      if (_device?.isConnected ?? false)
        await _device!.disconnect(queue: false);
      _checkGeneration(generation);
      _linkEstablished = false;
      _profile = null;
      _command = null;
      _device = device;
      _deviceName =
          device.platformName.isNotEmpty ? device.platformName : '录音卡';
      _log('${automatic ? "恢复已验证设备" : "用户选择设备"}: ${device.remoteId.str}');
      for (final result in FlutterBluePlus.lastScanResults
          .where((r) => r.device.remoteId == device.remoteId)) {
        final adv = result.advertisementData;
        _log('广播 name=${adv.advName} services=${adv.serviceUuids} '
            'manufacturer=${adv.manufacturerData.map((k, v) => MapEntry(k, v.map((b) => b.toRadixString(16).padLeft(2, "0")).join()))}');
      }
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 15));
      _checkGeneration(generation);
      if (_ios.isSupported) {
        _subscriptions.add(_ios.events.listen((event) {
          if (generation == _generation &&
              event['remote_id'].toString().toLowerCase() ==
                  device.remoteId.str.toLowerCase()) {
            _handleNativeEvent(event);
          }
        }, onError: (Object error) => _log('原生诊断订阅失败: $error')));
        await _ios.configure(device.remoteId.str, requiresAncs: _requiresAncs);
        _log('原生连接选项 RequiresANCS=$_requiresAncs；请处理系统配对/通知授权');
      }
      _checkGeneration(generation);
      _phase = '系统连接与授权';
      _subscriptions.add(device.connectionState.listen((state) {
        if (generation != _generation || _disposed) return;
        if (state == BluetoothConnectionState.connected) {
          _linkEstablished = true;
          _log('CoreBluetooth/GATT 链路已建立，业务尚未就绪');
        } else if (_linkEstablished) {
          final previousPhase = _phase;
          _linkEstablished = false;
          _isConnected = false;
          _isRecording = false;
          _isPaused = false;
          _decoder?.reset();
          _phase = '已断开';
          final reason = device.disconnectReason;
          lastErrorMessage =
              '连接在「$previousPhase」断开：${reason?.code} ${reason?.description ?? "无系统说明"}';
          _log(
              'manual=$_manualDisconnect；$lastErrorMessage（CoreBluetooth 码，不等同于 HCI 原因）');
          _finishWaiting(false);
          unawaited(_readNativeDiagnostics(device, generation));
        }
      }));
      await device.connect(
          autoConnect: false, timeout: const Duration(seconds: 90));
      _checkGeneration(generation);
      _linkEstablished = device.isConnected;
      if (!_linkEstablished) throw StateError('连接调用完成后链路已断开');
      await _readNativeDiagnostics(device, generation);
      _checkGeneration(generation);
      _phase = '发现 GATT';
      final services = await device.discoverServices(timeout: 60);
      _checkGeneration(generation);
      final inventory = <String, Set<String>>{};
      for (final service in services) {
        final serviceId = BleConstants.normalize(service.uuid.str);
        inventory[serviceId] = {};
        _log('GATT service=$serviceId');
        for (final char in service.characteristics) {
          final id = BleConstants.normalize(char.uuid.str);
          inventory[serviceId]!.add(id);
          final p = char.properties;
          _log(
              '  char=$id read=${p.read} write=${p.write} writeNR=${p.writeWithoutResponse} notify=${p.notify} indicate=${p.indicate}');
        }
      }
      final profile = RecorderProfile.identify(inventory);
      if (profile == null)
        throw StateError('未找到唯一完整的已知业务 profile；保留 GATT 日志，不向未知或 OTA 特征写入');
      _profile = profile;
      _decoder = RecorderEventDecoder(profile.protocol);
      BluetoothCharacteristic find(String serviceId, String charId) => services
          .firstWhere((s) => BleConstants.normalize(s.uuid.str) == serviceId)
          .characteristics
          .firstWhere((c) => BleConstants.normalize(c.uuid.str) == charId);
      _command = find(profile.service, profile.command);
      final event = find(profile.service, profile.event);
      final audio = find(profile.service, profile.audio);
      if (profile.withoutResponse
          ? !_command!.properties.writeWithoutResponse
          : !_command!.properties.write) {
        throw StateError('业务命令属性与官方 profile 不符，不尝试降级写入');
      }
      if (!(event.properties.notify || event.properties.indicate) ||
          !(audio.properties.notify || audio.properties.indicate)) {
        throw StateError('业务事件或音频通道不支持订阅');
      }
      _log(
          '识别 ${profile.protocol.name}；命令=${profile.command} withoutResponse=${profile.withoutResponse}；OTA 排除');
      _phase = '订阅设备事件';
      // 先监听再启用 CCCD，避免遗漏订阅瞬间的身份挑战。
      _subscriptions.add(event.onValueReceived.listen((bytes) {
        if (generation == _generation) _handleEvent(bytes);
      }));
      await event.setNotifyValue(true, timeout: 90);
      _checkGeneration(generation);
      _log('设备事件 CCCD 已确认');
      _subscriptions.add(audio.onValueReceived.listen((bytes) {
        if (generation != _generation || !_isConnected) return;
        // 本版先验证连接；不再把任意事件/音频帧套用旧版自拟四字节头。
        if (bytes.isNotEmpty) _log('音频通知 ${bytes.length} 字节；帧格式待独立验证');
      }));
      await audio.setNotifyValue(true, timeout: 90);
      _checkGeneration(generation);
      _log('音频 CCCD 已确认');
      _phase = _isConnected ? '设备业务已验证' : '业务待鉴权';
      // 仅发送已确认的能力/状态查询，不能把写入队列成功当设备验证成功。
      await _sendJson(BleJsonRpc.getCapabilities(), 'getCapabilities');
      _checkGeneration(generation);
      if (!_ready!.isCompleted) {
        if (profile.protocol == RecorderProtocol.telink) {
          await _sendJson(
              BleJsonRpc.bindRequest(
                  DateTime.now().millisecondsSinceEpoch ~/ 1000),
              'bindRequest（无假凭证）');
        } else {
          _log('AiNote6095 首次业务绑定需要合法 user_id 和验证材料；本版不伪造');
        }
      }
      _checkGeneration(generation);
      await _sendJson(BleJsonRpc.getStatus(), 'getStatus');
      final ready = await _ready!.future
          .timeout(const Duration(seconds: 12), onTimeout: () => false);
      _checkGeneration(generation);
      if (!ready) {
        if (isLinkConnected) {
          if (_phase == '业务待鉴权') _phase = '链路已连接，业务待鉴权';
          lastErrorMessage ??= '尚未收到有效的业务鉴权成功回执；请复制诊断日志';
          _log(lastErrorMessage!);
        }
        return false;
      }
      return _isConnected && isLinkConnected;
    } catch (error) {
      if (generation != _generation || _disposed) return false;
      lastErrorMessage = '$error';
      _phase = '连接未完成';
      _log('连接错误: $error');
      // 未知 profile/订阅失败不能留下可继续操作的半初始化连接。
      if (device.isConnected) {
        try {
          await device.disconnect(queue: false);
        } catch (disconnectError) {
          _log('断开失败: $disconnectError');
        }
      }
      await _readNativeDiagnostics(device, generation);
      _isConnected = false;
      _linkEstablished = false;
      _finishWaiting(false);
      return false;
    }
  }

  void _checkGeneration(int generation) {
    if (generation != _generation || _disposed) throw StateError('连接已取消');
  }

  void _finishWaiting(bool ready) {
    if (_ready != null && !_ready!.isCompleted) _ready!.complete(ready);
  }

  void _handleNativeEvent(Map<String, dynamic> event) {
    if (event['ancs_authorized'] is bool)
      _ancsAuthorized = event['ancs_authorized'] as bool;
    _log('iOS event=${event["event"]} nativeTime=${event["timestamp_ms"]} '
        'ANCS=${event["ancs_authorized"]} domain=${event["error_domain"]} '
        'code=${event["error_code"]} description=${event["error_description"]}');
  }

  Future<void> _readNativeDiagnostics(
      BluetoothDevice device, int generation) async {
    if (!_ios.isSupported) return;
    try {
      final snapshot = await _ios.diagnostics(device.remoteId.str);
      if (generation == _generation && !_disposed) _handleNativeEvent(snapshot);
    } catch (error) {
      if (generation == _generation) _log('读取原生诊断失败: $error');
    }
  }

  Future<void> _sendJson(Uint8List payload, String method) async {
    final profile = _profile;
    if (profile == null || _device == null) throw StateError('业务通道未初始化');
    final maxLength = (_device!.mtuNow - 3).clamp(20, 512);
    for (final frame in profile.encodeJson(payload, maxLength)) {
      await _write(frame, method);
    }
  }

  Future<void> _write(Uint8List frame, String label) async {
    final command = _command;
    final profile = _profile;
    if (command == null || profile == null || !isLinkConnected)
      throw StateError('业务链路不可用');
    if (BleConstants.normalize(command.uuid.str) != profile.command ||
        BleConstants.normalize(command.serviceUuid.str) != profile.service ||
        BleConstants.normalize(command.uuid.str) == BleConstants.charOta) {
      throw StateError('拒绝向非业务命令特征写入');
    }
    await command.write(frame,
        withoutResponse: profile.withoutResponse, timeout: 30);
    _log('TX $label bytes=${frame.length}（写入完成，尚非业务回执）');
  }

  void _handleEvent(List<int> bytes) {
    if (_disposed) return;
    _log('RX 设备事件 bytes=${bytes.length}');
    try {
      final message = _decoder?.feed(bytes);
      if (message == null) return;
      final method = message['method'] as String;
      final safeMethod =
          RegExp(r'^[A-Za-z0-9_]{1,64}$').hasMatch(method) ? method : '未知方法';
      final params = message['params'] is Map
          ? Map<String, dynamic>.from(message['params'] as Map)
          : <String, dynamic>{};
      _log(
          '设备事件 method=$safeMethod success=${params["success"] is bool ? params["success"] : "未提供"}');
      // 只接受设备上报 SN，不再从广告名或 hash 拼造序列号。
      if (params['sn'] is String &&
          RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(params['sn'] as String)) {
        _serialNumber = params['sn'] as String;
      }
      if (method == 'verifyRequest' || method == 'verifyIdentityRequest') {
        lastErrorMessage = method == 'verifyRequest'
            ? '设备请求厂商业务验证；尚无合法签发材料，未发送伪造签名'
            : '设备请求共享密钥挑战验证；尚无合法密钥，未发送假 token';
        _phase = '等待合法业务鉴权';
        _log(lastErrorMessage!);
        _finishWaiting(false);
      } else if (method == 'verifyIdentityResult' &&
          params['success'] == true) {
        _isConnected = isLinkConnected;
        if (_isConnected) {
          _phase = '设备业务已验证';
          lastErrorMessage = null;
          _log('收到明确的 verifyIdentityResult success=true');
          _finishWaiting(true);
          unawaited(_rememberVerifiedDevice());
        }
      } else if (method == 'bindError' ||
          (['bindResult', 'pairingResult', 'verifyIdentityResult']
                  .contains(method) &&
              params['success'] == false)) {
        _isConnected = false;
        lastErrorMessage = '设备报告 $safeMethod 失败；请保留日志，不自动清除绑定';
        _phase = '业务验证失败';
        _log(lastErrorMessage!);
        _finishWaiting(false);
      } else if (method == 'bindResult' || method == 'pairingResult') {
        _log('绑定阶段回执不等同于身份验证成功；仍等待完整业务鉴权');
      } else if (method == 'reportStatus') {
        final battery = params['battery'];
        final level = battery is Map ? battery['level'] : battery;
        if (level is int && level >= 0 && level <= 100) _batteryLevel = level;
      }
      _stateChanges.add(null);
    } on FormatException {
      _log('设备事件帧无效或格式不支持；未将内容当作鉴权回执');
    }
  }

  Future<void> _rememberVerifiedDevice() async {
    final device = _device;
    if (device == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastIdKey, device.remoteId.str);
    await prefs.setString(_lastNameKey, _deviceName);
  }

  Future<void> _clearSubscriptions() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _decoder?.reset();
  }

  @override
  Future<bool> connect() =>
      _device != null ? connectDevice(_device!) : autoReconnectLastDevice();

  @override
  Future<void> disconnect() async {
    _manualDisconnect = true;
    ++_generation;
    _finishWaiting(false);
    _phase = '用户取消连接';
    _log('已请求断开；不会清除系统 bond 或恢复出厂');
    final device = _device;
    if (device != null) {
      try {
        await device.disconnect(queue: false);
      } catch (error) {
        _log('断开提示: $error');
      }
      await _readNativeDiagnostics(device, _generation);
    }
    await _clearSubscriptions();
    _linkEstablished = false;
    _isConnected = false;
    _isRecording = false;
    _isPaused = false;
    _command = null;
    _profile = null;
    _phase = '已断开';
    _log('连接已结束');
  }

  Future<void> unpairDevice() async {
    await disconnect();
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      _lastIdKey,
      _lastNameKey,
      'sunmate_last_ble_device_id',
      'sunmate_last_ble_device_name'
    ]) {
      await prefs.remove(key);
    }
    _log('已清除 App 保存的设备 ID；系统配对请在 iPhone 设置中管理');
  }

  // 本轮只验证连接与鉴权；不沿用未经证实的录音 JSON 或音频帧格式。
  bool _recordingUnavailable() {
    lastErrorMessage = '录音需业务鉴权和音频帧验证完成后启用；当前 $_phase';
    _log(lastErrorMessage!);
    return false;
  }

  @override
  Future<bool> startRecording() async => _recordingUnavailable();
  @override
  Future<bool> pauseRecording() async => _recordingUnavailable();
  @override
  Future<bool> resumeRecording() async => _recordingUnavailable();
  @override
  Future<bool> stopRecording() async => _recordingUnavailable();

  @override
  Future<bool> syncTime() async {
    if (!_isConnected || _profile == null) return false;
    try {
      await _write(_profile!.encodeTime(DateTime.now()), '同步 RTC');
      return true;
    } catch (error) {
      lastErrorMessage = '$error';
      _log('RTC 同步失败: $error');
      return false;
    }
  }

  /// HAL 保留入口：保存下次连接选项，不向外设发送自造 setAncsConfig。
  @override
  Future<bool> sendAncsConfig({required bool enable, int mode = 3}) async {
    if (!_ios.isSupported) return false;
    await _initialization;
    _requiresAncs = enable;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ancsKey, enable);
    _log('ANCS 连接请求=$enable，下次连接生效；已授予的系统通知权限需在 iPhone 蓝牙设置管理');
    return true;
  }

  void simulateButtonEvent(ButtonActionType action) {
    if (!_disposed)
      _buttonEvents.add(DeviceButtonEvent(buttonId: 1, action: action));
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _initialization;
    _saveTimer?.cancel();
    await _saveLogs();
    _disposed = true;
    await _receiverSub.cancel();
    _audioReceiver.dispose();
    await _buttonEvents.close();
    await _audioPackets.close();
    await _stateChanges.close();
    await _logs.close();
  }
}

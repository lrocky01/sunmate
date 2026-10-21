import 'dart:async';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../ble/ble_constants.dart';
import '../ble/ble_json_rpc.dart';
import '../ble/ble_protocol.dart';
import '../ble/telink_notification.dart';
import '../ble/telink_long_files.dart';
import '../audio/recorder_local_audio.dart';
import '../notifications/mobile_notification_manager.dart';
import '../ble/ios_ble_connection.dart';
import '../ble/recorder_connection_details.dart';
import '../ble/recorder_authentication.dart';
import '../ble/recorder_saved_identity.dart';
import '../ble/recorder_portable_backup.dart';
import '../ble/recorder_credential_vault.dart';
import '../ble/yoooclaw_account.dart';
import '../audio/opus_stream_receiver.dart';
import 'hardware_device_driver.dart';
import 'recorder_hardware_settings.dart';
import 'recorder_long_recordings.dart';
import 'recorder_long_file_models.dart';
import 'recorder_long_file_store.dart';
import '../recordings/recording_processing_models.dart';
import 'recorder_long_file_sync.dart';

/// 保留 HAL 驱动入口，在完整 GATT 匹配后选择官方协议。
class AiNote6095Driver implements HardwareDeviceDriver, RecorderSettingsDevice {
  static const _lastIdKey = 'sunmate_verified_ble_device_id_v2';
  static const _lastNameKey = 'sunmate_verified_ble_device_name_v2';
  static const _lastSnKey = 'sunmate_verified_ble_device_sn_v2';
  static const _diagnosticsKey = 'sunmate_ble_diagnostics_v1';
  static const _ancsKey = 'sunmate_ble_requires_ancs';
  final _ios = IosBleConnection();
  final _audioReceiver = OpusStreamReceiver();
  final RecorderKeyStore _keyStore;
  final RecorderIdentityStore _identityStore = RecorderIdentityStore();
  late final RecorderBackupService backupService = RecorderBackupService(
      keys: _keyStore, identities: _identityStore);
  final Future<List<BluetoothDevice>> Function() _systemDevices;
  RecorderSavedIdentity? _recoveryIdentity;
  final ManufacturerVerifier? _verifier;
  final Duration connectionTimeout;
  final Duration cancellationTimeout;
  final Duration authenticationTimeout;
  final Duration settingsTimeout;
  late final RecorderLongRecordingController _longRecordings =
      RecorderLongRecordingController(
          store: _longSessionStore,
          isCardRecording: () =>
              _isRecording || _settings.snapshot.recording == true,
          onChanged: () {
            if (!_disposed) _stateChanges.add(null);
          });
  final RecorderLongSessionStore _longSessionStore;
  final RecorderLongFileStore _longFileStore;
  final RecorderLocalAudio _localAudio;
  bool _fileChannelReady = false;
  late final RecorderLongFileSync _longFiles = RecorderLongFileSync(
      store: _longFileStore, audio: _localAudio,
      onSegmentSignal: (signal) {
        if (!_disposed) _segmentSignals.add(signal);
      },
      requestStatus: () => _sendJson(BleJsonRpc.getStatus(), '长录只读状态查询'),
      send: (bytes) async {
        if (!_canReceiveNotification || !_fileChannelReady ||
            _profile?.protocol != RecorderProtocol.telink) {
          throw StateError('文件读取需要当前真实AES和文件通道');
        }
        await _write(Uint8List.fromList(bytes), '长录只读文件命令');
      },
      isReady: () => _canReceiveNotification && _fileChannelReady &&
          _profile?.protocol == RecorderProtocol.telink,
      isIdle: () => !_isRecording && _settings.snapshot.recording == false,
      serialNumber: () => _serialNumber,
      purpose: (session) {
        for (final saved in _longRecordings.snapshot.sessions) {
          if (saved.serialNumber == _serialNumber && saved.sessionId == session) {
            return saved.purpose;
          }
        }
        return null;
      },
      onChanged: () { if (!_disposed) _stateChanges.add(null); });
  late final RecorderSettingsController _settings = RecorderSettingsController(
      isReady: () => !_disposed && _isConnected && _identityVerified &&
          _channelsReady && isLinkConnected &&
          _profile?.protocol == RecorderProtocol.telink,
      send: (method, params) async {
        if (!_isConnected || !_identityVerified || !_channelsReady ||
            _profile?.protocol != RecorderProtocol.telink) {
          throw StateError('设备设置需要当前连接真实身份验证');
        }
        await _sendJson(BleJsonRpc.request(method, params), method);
      },
      onChanged: () { if (!_disposed) _stateChanges.add(null); },
      timeout: settingsTimeout);
  RecorderAuthentication? _authentication;
  RecorderAccountSession? _activeAccountSession;
  RecorderCandidateKeyStore? _candidateStore;
  RecorderCredentialSelection? _credentialSelection;
  int? _nativePeripheralState;
  bool? _systemConnectedMatch;
  bool? _advertisementConnectable;
  Future<void> _eventWork = Future.value();
  final _notificationDecoder = TelinkNotificationDecoder();
  final Map<int, List<int>> _notificationDigests = {};
  final MobileNotificationManager _notificationManager;
  bool _notificationAllowed = false;
  int _notificationsDelivered = 0;
  int _notificationsIgnored = 0;
  int _notificationsInvalid = 0;
  bool _hasSharedKey = false;
  bool _hasVerifiedDevice = false;
  bool _channelsReady = false;
  bool _identityVerified = false;
  bool _sawAuthenticationEvent = false;
  bool _sawManufacturerChallenge = false;
  bool _restoringIdentity = false;
  bool _needsIdentityReconnect = false;
  bool _cancelReconnect = false;
  int? _voiceSession;
  int? _binaryRecordingSession;
  TelinkRecordingKind? _binaryRecordingKind;
  int _audioNotificationCount = 0;
  int _audioReceivedBytes = 0;
  int _audioOutsideSession = 0;
  int _lastAudioFrameCount = 0;
  final _segmentSignals = StreamController<RecordingSegmentSignal>.broadcast();
  Stream<RecordingSegmentSignal> get segmentSignals => _segmentSignals.stream;
  final _buttonEvents = StreamController<DeviceButtonEvent>.broadcast();
  final _audioPackets = StreamController<AudioDataPacket>.broadcast();
  final _stateChanges = StreamController<void>.broadcast();
  final _logs = StreamController<String>.broadcast();
  final List<String> _connectionLogs = [];
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<String, String> _reportedSerials = {};
  late final Future<void> _initialization;
  late final StreamSubscription<Uint8List> _receiverSub;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _command;
  RecorderProfile? _profile;
  RecorderEventDecoder? _decoder;
  Future<bool>? _connectionOperation;
  Future<void>? _disconnectOperation;
  Completer<void>? _connectCancellation;
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
  String _serialSource = '未取得';
  String? _advertisedSerial;
  String _phase = '未连接';
  Uint8List? _lastRecordedBytes;
  String? lastErrorMessage;

  AiNote6095Driver({
    RecorderKeyStore? keyStore,
    ManufacturerVerifier? verifier,
    Future<List<BluetoothDevice>> Function()? systemDevices,
    this.connectionTimeout = const Duration(seconds: 90),
    this.cancellationTimeout = const Duration(seconds: 5),
    this.authenticationTimeout = const Duration(seconds: 120),
    this.settingsTimeout = const Duration(seconds: 5),
    RecorderLongSessionStore? longSessionStore,
    MobileNotificationManager? notificationManager,
    RecorderLongFileStore? longFileStore,
    RecorderLocalAudio? localAudio,
  })  : _keyStore = keyStore ?? RecorderCredentialVault(),
        _longFileStore = longFileStore ?? RecorderLongFileStore(),
        _localAudio = localAudio ?? MethodChannelRecorderLocalAudio(),
        _notificationManager = notificationManager ?? MobileNotificationManager(),
        _longSessionStore = longSessionStore ?? PreferenceLongSessionStore(),
        _systemDevices = systemDevices ?? (() => FlutterBluePlus.systemDevices([
          Guid('1812'), Guid(BleConstants.serviceOpus), Guid(BleConstants.serviceAiNote)
        ])),
        _verifier = verifier {
    _initialization = _loadPreferences();
    unawaited(_longRecordings.initialize());
    _receiverSub = _audioReceiver.audioStream.listen((packet) {
      if (!_isConnected || _disposed) return;
      _audioPackets.add(AudioDataPacket(
        bytes: packet,
        format: AudioEncodingFormat.oggOpus,
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
  bool get isConnecting =>
      _connectionOperation != null ||
      _disconnectOperation != null ||
      _restoringIdentity;
  bool get requiresAncs => _requiresAncs;
  bool get hasVerifiedDevice => _hasVerifiedDevice;
  bool get supportsAncsRequestConfiguration => _ios.isSupported;
  bool? get ancsAuthorized => _ancsAuthorized;
  RecorderConnectionDetails get connectionDetails => RecorderConnectionDetails(
        linkConnected: isLinkConnected,
        gattDiscovered: _profile != null,
        identityVerified: _identityVerified,
        authenticationStarted: _sawAuthenticationEvent,
        channelsReady: _channelsReady,
        businessReady: _isConnected,
        localIdentityLoaded: _hasSharedKey,
        nativeState: _nativePeripheralState,
        systemConnectedMatch: _systemConnectedMatch,
        advertisementConnectable: _advertisementConnectable,
        requiresAncs: _requiresAncs,
        ancsAuthorized: _ancsAuthorized,
        protocol: _profile?.protocol.name ?? '未识别',
      );
  String get connectionSummary => _phase;
  @override
  int get batteryLevel => _batteryLevel;
  @override
  bool get isRecording => _isRecording;
  @override
  bool get isPaused => _isPaused;
  @override
  RecorderHardwareSettings get hardwareSettings => _settings.snapshot;
  @override
  Future<bool> refreshHardwareSettings() => _settings.refresh();
  @override
  Future<bool> setMeetingRecordingClicks(int count) => _settings.setClicks(count);
  @override
  Future<bool> setMeetingRecordingLed(bool enabled) => _settings.setLed(enabled);
  RecorderLongRecordings get longRecordings => _longRecordings.snapshot;
  Future<bool> chooseLongRecordingPurpose(LongRecordingPurpose purpose) =>
      _longRecordings.choose(purpose);
  Future<void> reloadLongRecordingSessions() => _longRecordings.initialize();
  Future<bool> retryLongRecordingSessionSave() => _longRecordings.retrySave();
  RecorderLongFileLibrary get longFileLibrary => _longFiles.snapshot;
  Future<void> reloadLocalLongFiles() => _longFiles.initialize();
  Future<bool> refreshLongFiles() => _longFiles.refresh();
  Future<bool> syncLongRecording(int sessionId) => _longFiles.sync(sessionId);
  Uint8List? get lastRecordedBytes => _lastRecordedBytes;
  @override
  Stream<DeviceButtonEvent> get buttonEvents => _buttonEvents.stream;
  @override
  Stream<AudioDataPacket> get audioStream => _audioPackets.stream;
  @override
  Stream<void> get stateChanges => _stateChanges.stream;
  Stream<String> get logStream => _logs.stream;
  List<String> get connectionLogs => List.unmodifiable(_connectionLogs);
  String get audioStatistics =>
      '通知=$_audioNotificationCount；接收字节=$_audioReceivedBytes；会话外忽略=$_audioOutsideSession；最近完整录音帧=$_lastAudioFrameCount';
  String get diagnosticText => [
        'SunMate 1.0.32+33',
        '通知回传: 已接收=$_notificationsDelivered；已忽略=$_notificationsIgnored；无效=$_notificationsInvalid',
        '长录文件通道: $_fileChannelReady；同步中=${longFileLibrary.busy}；待重连=${longFileLibrary.needsReconnect}；本机可播放=${longFileLibrary.recordings.where((r) => r.canPlay).length}',
        '长录目录: ${_longFiles.catalogDiagnostics}',
        '长录同步提示: ${longFileLibrary.message ?? "无"}',
        '当前阶段: $_phase',
        '设备: $_deviceName',
        '设备匹配 SN: $_serialNumber；来源: $_serialSource',
        '协议: ${_profile?.protocol.name ?? "未识别"}',
        '链路: $isLinkConnected; 业务就绪: $_isConnected; 通知授权属性: ${_ancsAuthorized ?? "未知"}',
        '原生状态: ${connectionDetails.nativeStateLabel}; 系统已连接服务匹配: ${_systemConnectedMatch ?? "未查询"}; 广播可连接: ${_advertisementConnectable ?? "未知"}',
        '最近错误: ${lastErrorMessage ?? "无"}',
        '音频统计: $audioStatistics',
        '会议录音设置: 点击=${hardwareSettings.meetingClicks ?? "未读取"}；灯=${hardwareSettings.meetingLed ?? "未读取"}；回读确认=${hardwareSettings.confirmed}；状态=${hardwareSettings.message ?? "未读取"}',
        '长录用途: 下次=${longRecordings.loaded ? longRecordings.preferred.label : "未读取"}；最近活动=${longRecordings.active?.purposeLabel ?? "无"}；本地提示=${longRecordings.message ?? "无"}；不代表音频已同步',
        ..._connectionLogs,
      ].join('\n');

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _requiresAncs = prefs.getBool(_ancsKey) ?? true;
    _hasVerifiedDevice = prefs.getString(_lastIdKey) != null;
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
    final sn = prefs.getString(_lastSnKey);
    if (sn != null && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(sn)) {
      _reportedSerials[id] = sn;
    }
    return connectDevice(BluetoothDevice.fromId(id), isAutoReconnect: true);
  }

  Future<RecorderSavedIdentity?> _verifiedSavedIdentity() async {
    await _initialization;
    if (_disposed) return null;
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_lastIdKey);
    final sn = prefs.getString(_lastSnKey);
    if (id == null || sn == null) return null;
    final matches = (await _identityStore.readAll()).where((r) =>
        r.remoteId.toLowerCase() == id.toLowerCase() &&
        r.serialNumber == sn && r.previouslyVerified).toList();
    if (matches.length != 1) return null;
    final identity = matches.single;
    final key = await _keyStore.read(identity.remoteId, identity.protocol);
    if (key == null) return null;
    final decoded = RecorderCryptography.decode32(key);
    decoded.fillRange(0, decoded.length, 0);
    return _disposed ? null : identity;
  }

  /// 启动自动连接仅使用已经过AES的身份和本机key，不恢复账号或首次绑定。
  Future<bool> hasAutomaticReconnectMaterial() async =>
      await _verifiedSavedIdentity() != null;

  Future<bool> reconnectVerifiedDeviceAutomatically(
      {required bool Function() shouldConnect}) async {
    final identity = await _verifiedSavedIdentity();
    if (identity == null || !shouldConnect()) return false;
    return connectDevice(BluetoothDevice.fromId(identity.remoteId),
        isAutoReconnect: true,
        recoveryCandidate: RecorderRecoveryCandidate(identity,
            systemConnected: false));
  }

  /// 系统已连接/本机保存的身份仅作为候选；仍须建立本App连接并验证AES。
  Future<List<RecorderRecoveryCandidate>> recoveryCandidates({
    RecorderAccountSession? accountSession,
    bool includeSystemDevices = true,
  }) async {
    await _initialization;
    if (_disposed || accountSession?.newDeviceIdentity != null) return [];
    accountSession?.validateCurrent?.call();
    final saved = await _identityStore.readAll();
    var system = <BluetoothDevice>[];
    if (includeSystemDevices) {
      try {
        system = await _systemDevices().timeout(const Duration(seconds: 5));
      } catch (_) {
        if (saved.isEmpty) throw StateError('暂时无法读取系统已连接设备，请重新读取；无需解绑');
      }
    }
    if (_disposed) return [];
    accountSession?.validateCurrent?.call();
    final systemById = {
      for (final d in system) d.remoteId.str.toLowerCase(): d,
    };
    if (systemById.length > 64) throw StateError('系统设备候选过多，未自动匹配');
    final found = <String, RecorderRecoveryCandidate>{};
    for (final identity in saved) {
      if (accountSession != null &&
          identity.serialNumber != accountSession.serialNumber)
        continue;
      final key = await _keyStore.read(identity.remoteId, identity.protocol);
      if (key == null) continue;
      await _authorizeRecovery(identity, accountSession);
      found[identity.remoteId.toLowerCase()] = RecorderRecoveryCandidate(
        identity,
        systemConnected: systemById.containsKey(
          identity.remoteId.toLowerCase(),
        ),
      );
    }
    // 兼容旧版仅保存了Keychain key的情况：必须与所选账号key唯一匹配。
    if (accountSession != null &&
        accountSession.hasRecoverableKey &&
        accountSession.matchesExistingKey != null) {
      for (final device in systemById.values) {
        final id = device.remoteId.str;
        if (found.containsKey(id.toLowerCase())) continue;
        for (final protocol in RecorderProtocol.values) {
          if (!await accountSession.matchesExistingKey!(
            id,
            protocol,
            _keyStore,
          ))
            continue;
          final identity = RecorderSavedIdentity(
            remoteId: id,
            serialNumber: accountSession.serialNumber,
            protocol: protocol,
            deviceName:
                device.platformName.isNotEmpty &&
                    device.platformName.length <= 64
                ? device.platformName
                : '录音卡',
          );
          final known = saved.where(
            (s) => s.remoteId.toLowerCase() == id.toLowerCase(),
          );
          if (known.isNotEmpty && !known.single.sameDevice(identity)) {
            throw StateError('系统设备与本机已存身份冲突，未继续匹配');
          }
          if (found.containsKey(id.toLowerCase()))
            throw StateError('同一系统设备的协议匹配不唯一');
          found[id.toLowerCase()] = RecorderRecoveryCandidate(
            identity,
            systemConnected: true,
          );
        }
      }
    }
    accountSession?.validateCurrent?.call();
    final grouped = <String, int>{};
    for (final candidate in found.values) {
      final sn = candidate.identity.serialNumber;
      grouped[sn] = (grouped[sn] ?? 0) + 1;
    }
    if (grouped.values.any((n) => n > 1)) throw StateError('同一SN有多个恢复候选，未自动选择');
    return _disposed ? [] : List.unmodifiable(found.values);
  }

  Future<void> _authorizeRecovery(
    RecorderSavedIdentity identity,
    RecorderAccountSession? session,
  ) async {
    session?.validateCurrent?.call();
    if (session?.newDeviceIdentity != null ||
        (session != null && session.serialNumber != identity.serialNumber)) {
      throw StateError('恢复身份与所选账号设备不匹配');
    }
    final key = await _keyStore.read(identity.remoteId, identity.protocol);
    if (key == null) throw StateError('该设备没有本机密钥，未作为已存身份接入');
    final decoded = RecorderCryptography.decode32(key);
    decoded.fillRange(0, decoded.length, 0);
    final saved = (await _identityStore.readAll())
        .where(
          (r) => r.remoteId.toLowerCase() == identity.remoteId.toLowerCase(),
        )
        .toList();
    if (saved.isNotEmpty && !saved.single.sameDevice(identity)) {
      throw StateError('已保存的设备身份不匹配，未覆盖');
    }
    if (saved.isEmpty || (session?.hasRecoverableKey ?? false)) {
      final match = session?.matchesExistingKey;
      if (match == null ||
          !await match(identity.remoteId, identity.protocol, _keyStore)) {
        throw StateError('本机密钥与所选账号恢复资料不匹配，未覆盖或重新绑定');
      }
    }
    session?.validateCurrent?.call();
  }

  /// 同一次连接只允许一个流程；自动重连与点击连接不能互相覆盖。
  Future<bool> connectDevice(BluetoothDevice device,
      {bool isAutoReconnect = false, RecorderAccountSession? accountSession,
      RecorderRecoveryCandidate? recoveryCandidate}) {
    if (_disposed) return Future.value(false);
    if (accountSession?.reestablishBinding ?? false) {
      if (isAutoReconnect || isLinkConnected || _isRecording ||
          recoveryCandidate != null || accountSession!.newDeviceIdentity == null ||
          accountSession.claimRebinding == null || accountSession.credentialCandidate ||
          accountSession.isOfflineBackup || _keyStore is! RecorderCredentialVault) {
        lastErrorMessage = '请从独立重新绑定入口核对并确认；未启动协商或改动活动密钥';
        return Future.value(false);
      }
    }
    if (accountSession?.credentialCandidate ?? false) {
      if (isLinkConnected || recoveryCandidate != null ||
          accountSession!.newDeviceIdentity != null || accountSession.isOfflineBackup ||
          !accountSession.hasRecoverableKey || _keyStore is! RecorderCredentialVault) {
        lastErrorMessage='请先断开当前连接，再从凭据候选入口验证；未改动活动密钥';
        return Future.value(false);
      }
    }
    if (_restoringIdentity || _disconnectOperation != null)
      return Future.value(false);
    if (_connectionOperation != null) {
      if (_connectingId == device.remoteId.str) return _connectionOperation!;
      _log('另一个连接正在进行，请先取消');
      return Future.value(false);
    }
    _connectingId = device.remoteId.str;
    _cancelReconnect = false;
    final operation =
        _connectAccountDevice(device, isAutoReconnect, accountSession, recoveryCandidate);
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

  Future<bool> _connectAccountDevice(BluetoothDevice device, bool automatic,
      RecorderAccountSession? session, RecorderRecoveryCandidate? recovery) async {
    final expectedGeneration = _generation + 1;
    RecorderRebindingKeyStore? negotiated;
    final connected =
        await _connectDevice(device, automatic, accountSession: session, recovery: recovery,
            onRebindingPrepared: (store) => negotiated = store);
    if (connected ||
        session == null ||
        _cancelReconnect ||
        expectedGeneration != _generation ||
        _disposed) return connected;
    if (!_needsIdentityReconnect) {
      final error = lastErrorMessage;
      await _startDisconnect();
      if (_generation == expectedGeneration + 1 && !_cancelReconnect) {
        lastErrorMessage = error;
      }
      return false;
    }
    _log('真实密钥已保存且账号已同步；断开一次，用新挑战验证后才报告连接成功');
    RecorderAccountSession? verification;
    RecorderSavedIdentity? completingRebinding;
    if (session.reestablishBinding) {
      final saved = negotiated;
      final selection = saved?.selection;
      if (saved == null || selection == null) {
        lastErrorMessage = '新绑定材料未能安全保存，未切换旧凭据；请保留诊断';
        await _startDisconnect();
        return false;
      }
      final vault = _keyStore as RecorderCredentialVault;
      completingRebinding = saved.identity;
      verification = RecorderAccountSession(saved.identity.serialNumber,
          ({required checkContent, required mac, required sn}) async =>
              throw StateError('新绑定验证阶段不重复验机'),
          ({required sn, required mac, required sharedSecret}) async =>
              throw StateError('新绑定验证阶段不重复云绑定'),
          credentialCandidate: true, credentialOrigin: '重新建立业务绑定',
          hasRecoverableKey: true, validateCurrent: session.validateCurrent,
          restoreKey: (id, protocol, sn, store) async {
            session.validateCurrent?.call();
            if (id.toLowerCase() != saved.identity.remoteId.toLowerCase() ||
                protocol != saved.identity.protocol || sn != saved.identity.serialNumber ||
                store is! RecorderCandidateKeyStore) throw StateError('新绑定验证身份不匹配');
            await vault.loadPrepared(saved.identity, selection, store);
            session.validateCurrent?.call();
            return true;
          });
    }
    await _startDisconnect(reconnecting: true);
    if (_cancelReconnect || _generation != expectedGeneration + 1 || _disposed)
      return false;
    return _connectDevice(device, true, retainDiagnostics: true,
        accountSession: verification, completingRebinding: completingRebinding);
  }

  Future<bool> _connectDevice(BluetoothDevice device, bool automatic,
      {RecorderAccountSession? accountSession,
      RecorderRecoveryCandidate? recovery,
      bool retainDiagnostics = false,
      void Function(RecorderRebindingKeyStore)? onRebindingPrepared,
      RecorderSavedIdentity? completingRebinding}) async {
    final generation = ++_generation;
    final cancellation = Completer<void>();
    _connectCancellation = cancellation;
    Timer? progress;
    // 在提交系统连接前固定本次扫描身份；系统配对等待不应使已选广播过期。
    final selectedAt = DateTime.now();
    final scannedSerials = <String>{};
    for (final result in FlutterBluePlus.lastScanResults
        .where((r) => r.device.remoteId == device.remoteId)) {
      final age = selectedAt.difference(result.timeStamp);
      if (age.isNegative || age > RecorderScanIdentity.maximumAge) continue;
      final serial = RecorderAdvertisementSerial.telink(
          result.advertisementData.manufacturerData);
      if (serial != null) scannedSerials.add(serial);
    }
    final newIdentity = accountSession?.newDeviceIdentity;
    try {
      await _initialization;
      _checkGeneration(generation);
      if (!retainDiagnostics) {
        _clock = Stopwatch()..start();
        _connectionLogs.clear();
      }
      lastErrorMessage = null;
      _manualDisconnect = false;
      _isConnected = false;
      _channelsReady = false;
      _identityVerified = false;
      _fileChannelReady = false;
      _longFiles.connectionLost();
      _resetNotifications();
      _notificationsDelivered = 0;
      _notificationsIgnored = 0;
      _notificationsInvalid = 0;
      _settings.reset();
      _hasSharedKey = false;
      _sawAuthenticationEvent = false;
      _sawManufacturerChallenge = false;
      _needsIdentityReconnect = false;
      _activeAccountSession = accountSession;
      _discardCandidate();
      _recoveryIdentity = recovery?.identity;
      _authentication?.cancel();
      _eventWork = Future.value();
      _voiceSession = null;
      _binaryRecordingSession = null;
      _binaryRecordingKind = null;
      _audioNotificationCount = 0;
      _audioReceivedBytes = 0;
      _audioOutsideSession = 0;
      _lastAudioFrameCount = 0;
      _audioReceiver.cancel();
      _ancsAuthorized = null;
      _nativePeripheralState = null;
      _systemConnectedMatch = null;
      _advertisementConnectable = null;
      _serialNumber = _reportedSerials[device.remoteId.str] ?? '--';
      _serialSource = _serialNumber == '--' ? '未取得' : '先前设备记录';
      _advertisedSerial = null;
      _batteryLevel = 0;
      _phase = '准备连接';
      _ready = Completer<bool>();
      if (recovery != null) {
        if (device.remoteId.str.toLowerCase() != recovery.identity.remoteId.toLowerCase()) {
          throw StateError('恢复候选UUID不匹配');
        }
        await Future.any<void>([
          _authorizeRecovery(recovery.identity, accountSession),
          cancellation.future.then<void>((_) => throw StateError('连接已取消')),
        ]).timeout(connectionTimeout);
        _checkGeneration(generation);
        _serialNumber = recovery.identity.serialNumber;
        _serialSource = '本机密钥身份候选（待身份挑战验证）';
      }
      if (newIdentity != null &&
          (newIdentity.remoteId.toLowerCase() != device.remoteId.str.toLowerCase() ||
              !newIdentity.isFresh(selectedAt) ||
              scannedSerials.length != 1 ||
              scannedSerials.single != newIdentity.serialNumber)) {
        throw const OfficialAccountException('首次绑定的扫描身份不匹配或已过期，请重新搜索');
      }
      if (accountSession?.reestablishBinding ?? false) {
        accountSession!.validateCurrent?.call();
        accountSession.claimRebinding!();
      }
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
      _log('${automatic ? "按已保存的身份重连" : "用户选择设备"}: ${device.remoteId.str}');
      for (final result in FlutterBluePlus.lastScanResults
          .where((r) => r.device.remoteId == device.remoteId)) {
        final adv = result.advertisementData;
        _advertisementConnectable = adv.connectable;
        _log('广播 name=${adv.advName} services=${adv.serviceUuids} '
            'connectable=${adv.connectable} rssi=${result.rssi} scanAgeMs=${DateTime.now().difference(result.timeStamp).inMilliseconds} '
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
        _log('原生连接选项 RequiresANCS=$_requiresAncs（仅请求选项，不代表系统弹窗已出现）');
      }
      _checkGeneration(generation);
      _phase = '系统连接与授权';
      _log(
          '等待系统连接回调，最长 ${connectionTimeout.inSeconds} 秒；请确保 Android 等其它设备已断开这张卡');
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
          _channelsReady = false;
          _identityVerified = false;
          _fileChannelReady = false;
          _longFiles.connectionLost();
          _resetNotifications();
          _settings.reset();
          unawaited(_longRecordings.connectionLost());
          _authentication?.cancel();
          _discardCandidate();
          _cancelVoice();
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
      final waiting = Stopwatch()..start();
      progress = Timer.periodic(const Duration(seconds: 10), (_) {
        if (generation != _generation || _disposed || _linkEstablished) return;
        _log('仍在等待系统连接：${waiting.elapsed.inSeconds} 秒；尚未收到 connected 回调');
        unawaited(_readNativeDiagnostics(device, generation));
      });
      try {
        // 插件的计时从原生 connect 调用返回后开始；外层同时覆盖队列和平台调用。
        await Future.any<void>([
          device.connect(autoConnect: false, timeout: connectionTimeout),
          cancellation.future.then<void>((_) => throw StateError('连接已取消')),
        ]).timeout(connectionTimeout);
      } finally {
        progress.cancel();
      }
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
      if (recovery != null && profile.protocol != recovery.identity.protocol) {
        throw StateError('实际GATT与恢复候选协议不匹配');
      }
      if (newIdentity != null && profile.protocol != newIdentity.protocol) {
        throw const OfficialAccountException('实际 GATT 与首次绑定的广播协议不一致');
      }
      if (profile.protocol == RecorderProtocol.telink) {
        final serials = scannedSerials;
        if (serials.length > 1) throw StateError('同一设备的广播 SN 冲突，未加载账号密钥');
        if (serials.isNotEmpty) {
          final serial = serials.single;
          if ((_serialNumber != '--' && _serialNumber != serial) ||
              (accountSession != null &&
                  accountSession.serialNumber != serial)) {
            throw const OfficialAccountException('广播 SN 与设备记录或所选账号设备不一致，未继续鉴权');
          }
          _advertisedSerial = serial;
          _serialNumber = serial;
          _serialSource = '本次设备广播（待身份挑战验证）';
          _log('已从真实厂商广播取得完整 SN，并匹配 Telink GATT；仍需身份挑战验证');
        }
      }
      if (_serialNumber != '--' &&
          accountSession != null &&
          _serialNumber != accountSession.serialNumber) {
        throw const OfficialAccountException('设备 SN 与所选账号设备不一致，未继续鉴权');
      }
      if (accountSession?.isOfflineBackup ?? false) {
        // 真实广播SN和完整GATT先匹配，再映射新手机UUID；不复用旧手机UUID。
        if (_advertisedSerial == null || scannedSerials.length != 1 ||
            accountSession!.restoreKey == null ||
            !await accountSession.restoreKey!(device.remoteId.str, profile.protocol,
                _advertisedSerial!, _keyStore)) {
          throw StateError('备份未能匹配当前广播SN及GATT，未继续鉴权');
        }
        _checkGeneration(generation);
        await _identityStore.save(RecorderSavedIdentity(remoteId: device.remoteId.str,
            serialNumber: _advertisedSerial!, protocol: profile.protocol,
            deviceName: _deviceName.length <= 64 ? _deviceName : '录音卡'));
        _checkGeneration(generation);
        _log('加密备份已匹配本次广播SN和GATT；本机材料已保存，仍待真实AES验证');
      }
      RecorderKeyStore authenticationStore = _keyStore;
      if (completingRebinding != null) {
        if (completingRebinding.remoteId.toLowerCase() != device.remoteId.str.toLowerCase() ||
            completingRebinding.protocol != profile.protocol ||
            !(accountSession?.credentialCandidate ?? false) ||
            accountSession?.serialNumber != completingRebinding.serialNumber ||
            (_advertisedSerial != null && _advertisedSerial != completingRebinding.serialNumber)) {
          throw StateError('新绑定验证回执与当前连接不匹配');
        }
        _serialNumber = completingRebinding.serialNumber;
        _advertisedSerial = completingRebinding.serialNumber;
        _serialSource = '本次重绑已匹配身份（待AES验证）';
      }
      if (accountSession?.reestablishBinding ?? false) {
        if (newIdentity == null || profile.protocol != RecorderProtocol.telink ||
            _advertisedSerial != newIdentity.serialNumber || scannedSerials.length != 1) {
          throw StateError('重新绑定需要本次真实广播SN与完整Telink GATT匹配');
        }
        final identity = RecorderSavedIdentity(remoteId: device.remoteId.str,
            serialNumber: newIdentity.serialNumber, protocol: profile.protocol,
            deviceName: _deviceName.length <= 64 ? _deviceName : '录音卡');
        final known = (await _identityStore.readAll()).where(
            (r) => r.remoteId.toLowerCase() == identity.remoteId.toLowerCase());
        if (known.any((r) => !r.sameDevice(identity))) throw StateError('旧身份记录不匹配，未重新协商');
        _checkGeneration(generation);
        accountSession!.validateCurrent?.call();
        final vault = _keyStore as RecorderCredentialVault;
        await vault.preserveForRebinding(identity);
        _checkGeneration(generation);
        accountSession.validateCurrent?.call();
        final candidate = RecorderRebindingKeyStore(vault, identity);
        _candidateStore = candidate;
        authenticationStore = candidate;
        onRebindingPrepared?.call(candidate);
        _log('显式重新绑定：旧凭据已安全归档，使用独立空候选；不清卡、不覆盖旧密钥');
      }
      if (accountSession?.credentialCandidate ?? false) {
        if (profile.protocol != RecorderProtocol.telink ||
            _advertisedSerial == null ||
            (completingRebinding == null && scannedSerials.length != 1) ||
            accountSession!.restoreKey == null ||
            accountSession.serialNumber != _advertisedSerial) {
          throw StateError('候选验证需要当前新鲜广播SN与完整Telink GATT匹配');
        }
        final identity = RecorderSavedIdentity(
            remoteId: device.remoteId.str,
            serialNumber: _advertisedSerial!,
            protocol: profile.protocol,
            deviceName: _deviceName.length <= 64 ? _deviceName : '录音卡');
        final known = (await _identityStore.readAll()).where(
            (r) => r.remoteId.toLowerCase() == identity.remoteId.toLowerCase());
        if (known.any((r) => !r.sameDevice(identity)))
          throw StateError('本机设备身份冲突；未装载候选');
        _checkGeneration(generation);
        accountSession.validateCurrent?.call();
        final candidate =
            RecorderCandidateKeyStore(device.remoteId.str, profile.protocol);
        _candidateStore = candidate;
        if (!await accountSession.restoreKey!(
            device.remoteId.str,
            profile.protocol,
            _advertisedSerial!,
            candidate)) throw StateError('候选资料不完整；未切换');
        _checkGeneration(generation);
        accountSession.validateCurrent?.call();
        final value =
            await candidate.read(device.remoteId.str, profile.protocol);
        if (value == null) throw StateError('候选没有可用密钥；未切换');
        _checkGeneration(generation);
        accountSession.validateCurrent?.call();
        final prepared = await (_keyStore as RecorderCredentialVault)
            .prepare(identity, value, source: accountSession.credentialOrigin);
        _checkGeneration(generation);
        accountSession.validateCurrent?.call();
        _credentialSelection = prepared;
        authenticationStore = candidate;
        _serialSource = '本次广播与显式凭据候选（待身份挑战验证）';
        _log('候选已隔离保存；旧活动凭据保留，等待本次真实AES挑战');
      }
      _decoder = RecorderEventDecoder(profile.protocol);
      _authentication = RecorderAuthentication(
        protocol: profile.protocol,
        deviceId: device.remoteId.str,
        store: authenticationStore,
        onNegotiatedKey: authenticationStore is RecorderRebindingKeyStore
            ? authenticationStore.preserveNegotiatedKey : null,
        onKeySaved: (serial) async {
          _checkGeneration(generation);
          if (serial != _serialNumber) throw StateError('密钥已保存但SN不匹配，未记录恢复身份');
          await _identityStore.save(RecorderSavedIdentity(remoteId: device.remoteId.str,
              serialNumber: serial, protocol: profile.protocol,
              deviceName: _deviceName.length <= 64 ? _deviceName : '录音卡'));
          _checkGeneration(generation);
        },
        verifier: (accountSession?.credentialCandidate ?? false) ? null : accountSession == null
            ? _verifier
            : ({required checkContent, required mac, required sn}) async {
                _checkGeneration(generation);
                _log('使用已登录的自有账号请求真实验机答复');
                final hmac = await accountSession.verifier(
                    checkContent: checkContent, mac: mac, sn: sn);
                _checkGeneration(generation);
                _log('官方验机答复已通过响应检查；内容不进入日志');
                return hmac;
              },
        committer: accountSession == null || accountSession.credentialCandidate
            ? null
            : ({required sn, required mac, required sharedSecret}) async {
                _checkGeneration(generation);
                _phase = '同步官方账号绑定';
                _log('正在同步当前设备的新绑定资料；密钥不进入日志');
                await accountSession.committer(
                    sn: sn, mac: mac, sharedSecret: sharedSecret);
                _checkGeneration(generation);
                _log('新绑定资料已同步到自己的官方账号');
              },
      );
      _hasSharedKey = await _authentication!.loadKey();
      _checkGeneration(generation);
      if (recovery != null) {
        await _authorizeRecovery(recovery.identity, accountSession);
        _checkGeneration(generation);
        await _identityStore.save(recovery.identity);
        _checkGeneration(generation);
        _log('恢复候选与本机密钥、SN及GATT协议匹配；仍等待当前真实身份挑战');
      }
      if (newIdentity != null && _hasSharedKey) {
        throw const OfficialAccountException('本机已有业务密钥，请返回使用本机已验证身份重连；未重新协商');
      }
      _log('本机合法共享密钥=${_hasSharedKey ? "已保存" : "尚无"}（不输出内容）');
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
          '识别 ${profile.protocol.name}；命令=${profile.command} withoutResponse=${profile.withoutResponse}；MTU=${device.mtuNow}；OTA 排除');
      _phase = '订阅设备事件';
      final authenticationClock = Stopwatch()..start();
      Duration remainingAuthenticationTime() {
        final remaining = authenticationTimeout - authenticationClock.elapsed;
        return remaining.isNegative ? Duration.zero : remaining;
      }

      // 先监听再启用 CCCD，避免遗漏订阅瞬间的身份挑战。
      _subscriptions.add(event.onValueReceived.listen((bytes) {
        if (generation == _generation) _handleEvent(bytes);
      }));
      await event.setNotifyValue(true, timeout: 90);
      _checkGeneration(generation);
      _log('设备事件 CCCD 已确认');
      _subscriptions.add(audio.onValueReceived.listen((bytes) {
        if (generation != _generation) return;
        final packet = Uint8List.fromList(bytes);
        // 与事件共用队列，开始事件、首包和结束事件即使同一轮到达也不乱序。
        _queueDeviceWork(generation, () {
          if (!_isConnected || _profile?.protocol != RecorderProtocol.telink) return;
          _audioNotificationCount++;
          _audioReceivedBytes += packet.length;
          if (_voiceSession == null) {
            _audioOutsideSession++;
            return;
          }
          try {
            _audioReceiver.feedBlePacket(packet);
          } on FormatException {
            _cancelVoice();
            _log('实时音频分帧失败，已取消该段转写');
          }
        });
      }));
      await audio.setNotifyValue(true, timeout: 90);
      _checkGeneration(generation);
      _log('音频 CCCD 已确认');
      // 文件通道可选；失败不破坏既有实时音频和真实AES路径。
      if (profile.protocol == RecorderProtocol.telink) {
        final fileCandidates = services
            .where((s) => BleConstants.normalize(s.uuid.str) == profile.service)
            .expand((s) => s.characteristics)
            .where((c) => BleConstants.normalize(c.uuid.str) == BleConstants.charFileData)
            .toList();
        if (fileCandidates.length == 1 &&
            (fileCandidates.single.properties.notify || fileCandidates.single.properties.indicate)) {
          final file = fileCandidates.single;
          _subscriptions.add(file.onValueReceived.listen((bytes) {
            if (generation != _generation) return;
            _queueDeviceWork(generation, () {
              try { _longFiles.acceptData(bytes); }
              catch (_) { _longFiles.transferError(); }
            });
          }));
          try {
            await file.setNotifyValue(true, timeout: 5);
            _checkGeneration(generation);
            _fileChannelReady = true;
            _log('长录文件 CCCD 已确认；不会自动删除卡片录音');
          } catch (_) {
            _checkGeneration(generation);
            _log('长录文件通道尚未就绪；实时音频和身份验证保持');
          }
        }
      }
      _channelsReady = true;
      // 订阅瞬间可能已收到身份挑战。先处理它，避免在恢复账号密钥时误发新绑定，
      // 也避免在已知鉴权失败后继续发送初始化命令。取消不能被迟到结果阻塞。
      await Future.any<void>([
        _eventWork,
        cancellation.future.then<void>((_) => throw StateError('连接已取消')),
      ]).timeout(remainingAuthenticationTime());
      _checkGeneration(generation);
      if (_ready!.isCompleted && !_isConnected) return false;
      await _completeAuthenticatedConnection();
      if (_isConnected) {
        _phase = '设备业务已验证';
      } else if (!_sawAuthenticationEvent) {
        _phase = '业务待鉴权';
      }
      if (!_ready!.isCompleted) {
        if (profile.protocol == RecorderProtocol.telink &&
            !_hasSharedKey &&
            !(accountSession?.hasRecoverableKey ?? false) &&
            !_sawManufacturerChallenge) {
          _phase = '等待真实首次验机';
          _log('本机尚无可用密钥；通道已就绪，按官方流程发送一次正常绑定请求');
          await _sendJson(
              BleJsonRpc.bindRequest(
                  DateTime.now().millisecondsSinceEpoch ~/ 1000),
              'bindRequest（无假凭证）');
        } else if (profile.protocol == RecorderProtocol.aiNote6095 &&
            !_hasSharedKey) {
          _log('AiNote6095 首次业务绑定需要合法 user_id 和验证材料；本版不伪造');
        }
      }
      // 写入完成不等于业务验证成功；仍需本轮设备身份挑战。
      _checkGeneration(generation);
      if (_ready!.isCompleted && !_isConnected) return false;
      await _sendJson(BleJsonRpc.getCapabilities(), 'getCapabilities');
      _checkGeneration(generation);
      await _sendJson(BleJsonRpc.getStatus(), 'getStatus');
      final ready = await _ready!.future
          .timeout(remainingAuthenticationTime(), onTimeout: () => false);
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
      final connectionError = error is TimeoutException && _phase == '系统连接与授权'
          ? '系统连接在 ${connectionTimeout.inSeconds} 秒内未完成，已请求取消；请关闭其它设备的蓝牙后重试'
          : '$error';
      lastErrorMessage = connectionError;
      _phase = '连接未完成';
      _log('连接错误: $lastErrorMessage');
      // pending 连接即使 isConnected=false 也必须请求取消。
      await _cancelNativeConnection(device);
      if (generation != _generation || _disposed) return false;
      await _readNativeDiagnostics(device, generation);
      if (generation != _generation || _disposed) return false;
      await _clearSubscriptions();
      if (generation != _generation || _disposed) return false;
      lastErrorMessage = connectionError;
      _isConnected = false;
      _linkEstablished = false;
      _finishWaiting(false);
      return false;
    } finally {
      progress?.cancel();
      if(generation==_generation && !_isConnected) _discardCandidate();
      if (identical(_connectCancellation, cancellation)) {
        _connectCancellation = null;
      }
    }
  }

  void _checkGeneration(int generation) {
    if (generation != _generation || _disposed) throw StateError('连接已取消');
  }

  void _discardCandidate() {
    _candidateStore?.close();
    _candidateStore = null;
    _credentialSelection = null;
  }

  void _finishWaiting(bool ready) {
    if (_ready != null && !_ready!.isCompleted) _ready!.complete(ready);
  }

  void _handleNativeEvent(Map<String, dynamic> event, {bool snapshot = false}) {
    if (event['state'] is int) _nativePeripheralState = event['state'] as int;
    if (event['system_connected_match'] is bool) {
      _systemConnectedMatch = event['system_connected_match'] as bool;
    }
    if (event['ancs_authorized'] is bool)
      _ancsAuthorized = event['ancs_authorized'] as bool;
    const states = {
      0: 'disconnected',
      1: 'connecting',
      2: 'connected',
      3: 'disconnecting'
    };
    _log(
        'iOS ${snapshot ? "snapshot lastEvent" : "event"}=${event["event"]} state=${states[event["state"]] ?? "unknown"} nativeTime=${event["timestamp_ms"]} '
        'central=${event["central_state"]} systemConnectedMatch=${event["system_connected_match"]} pending=${event["connection_pending"]} '
        'ANCS=${event["ancs_authorized"]} domain=${event["error_domain"]} '
        'code=${event["error_code"]} description=${event["error_description"]}');
  }

  Future<void> _readNativeDiagnostics(
      BluetoothDevice device, int generation) async {
    if (!_ios.isSupported) return;
    try {
      final snapshot = await _ios.diagnostics(device.remoteId.str);
      if (generation == _generation && !_disposed)
        _handleNativeEvent(snapshot, snapshot: true);
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
    if (_profile?.protocol == RecorderProtocol.telink &&
        TelinkLongFileEvent.isFileEvent(bytes)) {
      _notificationDecoder.accepts(bytes); // 新帧中止未完成通知，避免混入文件事件。
      _queueDeviceWork(_generation, () {
        try { _longFiles.acceptEvent(bytes); }
        catch (_) { _longFiles.transferError(); }
      });
      return;
    }
    if (_profile?.protocol == RecorderProtocol.telink &&
        _notificationDecoder.accepts(bytes)) {
      _handleNotificationBytes(bytes);
      return;
    }
    try {
      final recording = _profile?.protocol == RecorderProtocol.telink
          ? TelinkRecordingEvent.decode(bytes) : null;
      if (recording != null) {
        _queueDeviceWork(_generation, () => _handleBinaryRecording(recording));
        return;
      }
      final message = _decoder?.feed(bytes);
      if (message == null) return;
      final method = message['method'] as String;
      if (method == 'verifyRequest' || method == 'verifyIdentityRequest') {
        _sawAuthenticationEvent = true;
      }
      if (method == 'verifyRequest') _sawManufacturerChallenge = true;
      final safeMethod =
          RegExp(r'^[A-Za-z0-9_]{1,64}$').hasMatch(method) ? method : '未知方法';
      final params = message['params'] is Map
          ? Map<String, dynamic>.from(message['params'] as Map)
          : <String, dynamic>{};
      final generation = _generation;
      _queueDeviceWork(generation,
          () => _handleMessage(method, safeMethod, params, generation));
    } on FormatException {
      _log('设备事件帧无效或格式不支持；未将内容当作鉴权回执');
    }
  }

  bool get _canReceiveNotification => !_disposed && _isConnected &&
      _identityVerified && _channelsReady && _linkEstablished &&
      _authentication?.state == RecorderAuthenticationState.verified;

  void _resetNotifications() {
    _notificationDecoder.reset();
    _notificationDigests.clear();
    _notificationAllowed = false;
  }

  void _handleNotificationBytes(List<int> bytes) {
    if (TelinkNotificationDecoder.isStart(bytes)) {
      // 不缓存鉴权前的正文等到鉴权完成后重放。
      _notificationAllowed = _canReceiveNotification;
    }
    try {
      final frame = _notificationDecoder.feed(bytes);
      if (frame == null) return;
      if (!_notificationAllowed || !_canReceiveNotification || frame.eventId != 0 ||
          (frame.title.trim().isEmpty && frame.subtitle.trim().isEmpty &&
              frame.message.trim().isEmpty)) {
        _notificationsIgnored++;
        _log('通知帧已忽略：未通过当前身份验证、非新增或内容为空');
        return;
      }
      final generation = _generation;
      final receivedAt = DateTime.now();
      _queueDeviceWork(generation, () async {
        // 通知错误只影响这条通知，不进入鉴权失败处理。
        try {
          if (!_canReceiveNotification) return;
          final digest = (await Sha256().hash(frame.deduplicationBytes)).bytes;
          if (generation != _generation || !_canReceiveNotification) return;
          final previous = _notificationDigests[frame.uid];
          if (previous != null && _sameBytes(previous, digest)) {
            _notificationsIgnored++;
            return;
          }
          _notificationManager.onIosAncsNotificationPosted(
              appIdentifier: frame.appIdentifier,
              title: frame.title,
              subtitle: frame.subtitle,
              message: frame.message,
              notificationIdentity: '${_serialNumber == '--' ? _device?.remoteId.str ?? 'unknown' : _serialNumber}:${frame.uid}',
              timestamp: frame.timestamp ?? receivedAt);
          _notificationDigests.remove(frame.uid);
          _notificationDigests[frame.uid] = digest;
          if (_notificationDigests.length > 256) {
            _notificationDigests.remove(_notificationDigests.keys.first);
          }
          _notificationsDelivered++;
          _log('通知正文已交给本地通知管理器（不记录正文/标题/UID）');
        } catch (_) {
          _notificationsInvalid++;
          _log('本地通知接收失败；未改变设备鉴权状态');
        }
      });
    } on FormatException {
      _notificationsInvalid++;
      _notificationAllowed = false;
      _log('通知帧无效；已丢弃，不记录帧内容');
    }
  }

  static bool _sameBytes(List<int> a, List<int> b) => a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

  void _queueDeviceWork(int generation, FutureOr<void> Function() work) {
    _eventWork = _eventWork.then((_) async {
      if (generation != _generation || _disposed) return;
      await work();
    }).catchError((Object error) {
      if (generation != _generation || _disposed) return;
      _isConnected = false;
      _identityVerified = false;
      _longFiles.connectionLost();
      _resetNotifications();
      _settings.reset();
      _authentication?.cancel();
      unawaited(_longRecordings.connectionLost());
      _cancelVoice();
      _phase = '业务鉴权未完成';
      lastErrorMessage = _authentication?.verifier == null && !_hasSharedKey
          ? '需要自己的官方账号绑定材料或合法厂商验机接口；未发送假凭证'
          : error is OfficialAccountException
              ? error.message
              : '业务鉴权失败或设备材料无效；未报告连接成功';
      if (_activeAccountSession?.reestablishBinding ?? false) {
        lastErrorMessage = '$lastErrorMessage；旧活动凭据保留。卡片密钥可能已改变，请检查本机待验证版本；未自动重试';
      }
      _log(lastErrorMessage!);
      _finishWaiting(false);
    });
  }

  Future<void> _handleMessage(String method, String safeMethod,
      Map<String, dynamic> params, int generation) async {
    _log(
        '设备事件 method=$safeMethod success=${params["success"] is bool ? params["success"] : "未提供"}');
    // 设备事件 SN 必须与本次广播一致；不从广告名或 hash 拼造序列号。
    if (params['sn'] is String &&
        RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(params['sn'] as String)) {
      final reported = (params['sn'] as String).toUpperCase();
      if (_recoveryIdentity != null && reported != _recoveryIdentity!.serialNumber) {
        throw const OfficialAccountException('设备事件SN与恢复身份不一致');
      }
      if (_advertisedSerial != null && reported != _advertisedSerial) {
        throw const OfficialAccountException('设备事件 SN 与本次广播 SN 不一致，未继续鉴权');
      }
      _serialNumber = reported;
      _serialSource = '本次设备事件';
      final id = _device?.remoteId.str;
      if (id != null) _reportedSerials[id] = _serialNumber;
      if (_activeAccountSession != null &&
          _serialNumber != _activeAccountSession!.serialNumber) {
        throw const OfficialAccountException('卡片上报的 SN 与所选账号设备不一致，未继续鉴权');
      }
    }
    if (method == 'verifyRequest') {
      if (_activeAccountSession?.hasRecoverableKey ?? false) {
        throw const OfficialAccountException(
            '账号已有共享密钥，但设备请求首次验机；未重新协商，请保留当前绑定和诊断');
      }
      _phase = '厂商验机';
      final reply = await _authentication!.answerManufacturer(params);
      _checkGeneration(generation);
      await _sendJson(reply, 'verifyResult（合法验机答复）');
    } else if (method == 'verifyIdentityRequest') {
      _phase = '本地共享密钥验证';
      final restore = _activeAccountSession?.restoreKey;
      if (!_hasSharedKey && restore != null && _serialNumber != '--') {
        if (await restore(_device!.remoteId.str, _profile!.protocol,
            _serialNumber, _keyStore)) {
          _checkGeneration(generation);
          _hasSharedKey = await _authentication!.loadKey();
          _checkGeneration(generation);
          _log('已恢复与实际 SN 和协议匹配的账号密钥；仍需本次挑战验证');
        }
      }
      if (!_hasSharedKey) {
        if (_activeAccountSession?.hasRecoverableKey ?? false) {
          throw const OfficialAccountException(
              '账号已有可恢复密钥，但当前 SN / GATT 协议未能匹配；请重新扫描，不发送新的绑定请求');
        }
        if (_profile?.protocol == RecorderProtocol.telink &&
            _authentication?.verifier != null) {
          _phase = '等待真实首次验机';
          _log('已有身份挑战需要共享密钥；当前未取得可用密钥，未伪造应答，继续正常首次绑定流程');
          return;
        }
        _phase = '业务鉴权未完成';
        lastErrorMessage = '本机没有可用共享密钥，且当前没有可执行真实首次验机的账号会话；请登录自己的官方账号';
        _log(lastErrorMessage!);
        _authentication?.cancel();
        _finishWaiting(false);
        return;
      }
      final reply = await _authentication!.answerIdentity(params,
          timestampSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000);
      _checkGeneration(generation);
      await _sendJson(reply, 'verifyIdentity（本地挑战应答）');
    } else if (method == 'verifyIdentityResult' && params['success'] == true) {
      if (_isConnected &&
          _authentication?.state == RecorderAuthenticationState.verified) {
        _log('忽略本次鉴权的重复成功事件');
        return;
      }
      if (!_authentication!.acceptIdentityResult(params['success'])) {
        _log('忽略未经本次挑战应答的鉴权成功事件');
        _authentication?.cancel();
        lastErrorMessage = '缺少本次身份挑战，不能确认设备已通过鉴权';
        _finishWaiting(false);
        return;
      }
      _identityVerified = true;
      await _completeAuthenticatedConnection();
    } else if (method == 'bindError' ||
        (['bindResult', 'pairingResult', 'verifyIdentityResult']
                .contains(method) &&
            params['success'] == false)) {
      _isConnected = false;
      _identityVerified = false;
      _longFiles.connectionLost();
      _resetNotifications();
      _authentication?.cancel();
      _cancelVoice();
      final details = RecorderFailureSummary.describe(params);
      lastErrorMessage = '设备报告 $safeMethod 失败；拒绝详情（安全摘要）：$details；不自动清除绑定';
      _phase = '业务验证失败';
      _settings.reset();
      unawaited(_longRecordings.connectionLost());
      _log(lastErrorMessage!);
      _finishWaiting(false);
    } else if (method == 'pairingResult' && params['success'] == true) {
      await _authentication!.acceptPairing(params);
      _checkGeneration(generation);
      _hasSharedKey = true;
      _phase = '共享密钥已保存，等待身份挑战';
      _log('X25519 协商完成并已安全保存；若设备未再发挑战，请重连验证');
      _needsIdentityReconnect = _authentication!.committer != null;
      if (_needsIdentityReconnect) _finishWaiting(false);
    } else if (method == 'bindResult') {
      _log('绑定阶段回执不等同于身份验证成功；仍等待完整业务鉴权');
    } else if (method == 'voiceCmd' &&
        _isConnected &&
        _profile?.protocol == RecorderProtocol.telink) {
      _handleVoiceCommand(params);
    } else if (method == 'reportStatus') {
      final battery = params['battery'];
      final level = battery is Map ? battery['level'] : battery;
      if (level is int && level >= 0 && level <= 100) _batteryLevel = level;
      _settings.acceptStatus(params);
      final fileRecording = params['recording'];
      final fileSession = (fileRecording is Map ? fileRecording['long_session'] : null) ??
          params['long_session'] ?? params['longSession'];
      final filePart = (fileRecording is Map ? fileRecording['long_part'] : null) ??
          params['long_part'] ?? params['longPart'];
      if (fileSession is int && filePart is int) _longFiles.observePart(fileSession, filePart);
      if (_voiceSession != null || _binaryRecordingSession != null) {
        _settings.acceptRecording(true);
      }
      if (_isConnected &&
          _identityVerified &&
          _profile?.protocol == RecorderProtocol.telink) {
        final recording = params['recording'];
        final long = recording is Map ? recording['is_long_recording'] : null;
        final active =
            long ?? params['is_long_recording'] ?? params['isLongRecording'];
        final session = (recording is Map ? recording['long_session'] : null) ??
            params['long_session'] ?? params['longSession'];
        if (active == true && session is int && _longFiles.wasStopped(session)) {
          // 本连接已见stop的同一会话，不被迟到的状态回报重新激活。
          if (_voiceSession == null && _binaryRecordingSession == null) {
            _settings.acceptRecording(false);
          }
        } else if (active == true && session is int && session > 0) {
          if (_binaryRecordingKind == TelinkRecordingKind.long &&
              _binaryRecordingSession != session) {
            _longFiles.recordingStateUnknown();
            _binaryRecordingSession = null;
            _binaryRecordingKind = null;
          }
          // 状态恢复的长录必须能接收后续停止事件；不能伪装成实时收流。
          if (_voiceSession == null && _binaryRecordingSession == null) {
            _binaryRecordingSession = session;
            _binaryRecordingKind = TelinkRecordingKind.long;
            _isRecording = true;
          }
          if (_binaryRecordingKind == TelinkRecordingKind.long &&
              _binaryRecordingSession == session) {
            final preparation = _longRecordings.started(_serialNumber, session,
                observedStart: false).then<void>((_) {});
            _longFiles.recordingStarted(session,
                activePart: filePart is int ? filePart : null, preparation: preparation);
          }
        } else if (active == false && session is int &&
            _binaryRecordingKind == TelinkRecordingKind.long &&
            _binaryRecordingSession == session) {
          // 带相同session的明确停止状态可修复丢失的二进制stop；无session不猜测。
          _binaryRecordingSession = null;
          _binaryRecordingKind = null;
          _isRecording = false;
          _settings.acceptRecording(false);
          unawaited(_longRecordings.stopped(_serialNumber, session));
          _longFiles.recordingStopped(session);
        } else if (active == true) {
          // 缺少可验证会话身份时，不能沿用旧段关闭依据。
          _longFiles.recordingStateUnknown();
        }
      }
    } else if (method == 'reportLongOpsSegmentClosed') {
      final session = params['session'] ?? params['session_ms'] ??
          params['sessionMs'] ?? params['long_session'];
      final part = params['part'] ?? params['long_part'];
      if (session is int && part is int) _longFiles.segmentClosed(session, part);
    } else if (method == 'reportCapabilities') {
      _settings.acceptCapabilities(params);
    } else if (method == 'reportUserSettings') {
      _settings.acceptSettings(params);
    }
    _stateChanges.add(null);
  }

  Future<void> _completeAuthenticatedConnection() async {
    if (!_identityVerified ||
        !_channelsReady ||
        !isLinkConnected ||
        _isConnected) return;
    if (_activeAccountSession?.reestablishBinding ?? false) {
      // 协商回执和云同步不是AES验收；使用持久化候选断开后验证一次。
      return;
    }
    final generation = _generation;
    final selection = _credentialSelection;
    if (selection != null) {
      final session = _activeAccountSession;
      await (_keyStore as RecorderCredentialVault).activateVerified(selection,
          ensureCurrent: () {
        _checkGeneration(generation);
        session?.validateCurrent?.call();
        if (!isLinkConnected ||
            !_linkEstablished ||
            !_channelsReady ||
            !_identityVerified ||
            _candidateStore == null ||
            !identical(_credentialSelection, selection) ||
            _authentication?.state != RecorderAuthenticationState.verified) {
          throw StateError('候选验证连接已结束；未切换');
        }
      });
      _checkGeneration(generation);
      _credentialSelection = null;
      _serialSource = '显式凭据候选（身份挑战已验证）';
      _log('本次AES和业务通道均已确认，活动凭据已切换；旧版本保留可恢复');
    }
    _isConnected = true;
    _longFiles.connected();
    if (_advertisedSerial != null && _serialSource == '本次设备广播（待身份挑战验证）') {
      _serialSource = '本次设备广播（身份挑战已验证）';
    } else if (_recoveryIdentity != null) {
      _serialSource = '本机密钥身份（身份挑战已验证）';
    }
    _phase = '设备业务已验证';
    lastErrorMessage = null;
    _log('本次身份挑战验证成功，事件和音频通道均已确认');
    _finishWaiting(true);
    unawaited(_rememberVerifiedDevice());
    unawaited(syncTime());
    // 设置读取失败不影响已完成的AES连接；只读，不自动改卡片配置。
    if (_profile?.protocol == RecorderProtocol.telink) {
      unawaited(_settings.refresh());
    }
  }

  void _handleBinaryRecording(TelinkRecordingEvent event) {
    if (!_isConnected || !_identityVerified || !_channelsReady) return;
    if (event.started) {
      if (event.kind == TelinkRecordingKind.long &&
          _longFiles.wasStopped(event.sessionId!)) return;
      if (_binaryRecordingSession == event.sessionId &&
          _binaryRecordingKind != event.kind) {
        _log('忽略同一会话的冲突录音类型');
        return;
      }
      if (_binaryRecordingSession == event.sessionId) return;
      if (event.kind == TelinkRecordingKind.long) {
        _cancelVoice();
        _lastRecordedBytes = null;
        _log('收到二进制长录音开始；已关闭分段独立同步，不混入实时会话');
        final preparation = _longRecordings.started(_serialNumber, event.sessionId!)
            .then<void>((_) {});
        _longFiles.recordingStarted(event.sessionId!, preparation: preparation, newRecording:true);
      } else {
        _longFiles.recordingStateUnknown();
        _handleVoiceCommand({'event': 'start', 'session_id': event.sessionId});
        _log('已识别二进制实时录音开始');
      }
      _binaryRecordingSession = event.sessionId;
      _binaryRecordingKind = event.kind;
      _isRecording = true;
      _settings.acceptRecording(true);
    } else {
      final session = _binaryRecordingSession;
      if (session == null ||
          (event.kind != null && event.kind != _binaryRecordingKind)) {
        _log('忽略无匹配活动会话的二进制录音结束');
        return;
      }
      final stoppedLong = _binaryRecordingKind == TelinkRecordingKind.long;
      if (!stoppedLong) {
        _handleVoiceCommand({'event': 'release', 'session_id': session});
      } else {
        _log('收到二进制长录音结束；未作为实时音频提交');
        unawaited(_longRecordings.stopped(_serialNumber, session));
      }
      _binaryRecordingSession = null;
      _binaryRecordingKind = null;
      _isRecording = false;
      _settings.acceptRecording(false);
      if (stoppedLong) _longFiles.recordingStopped(session);
    }
    _stateChanges.add(null);
  }

  void _handleVoiceCommand(Map<String, dynamic> params) {
    final session = params['session_id'];
    if (session is! int || session <= 0) return;
    if (params['event'] == 'start') {
      if (_voiceSession == session) return;
      _longFiles.recordingStateUnknown();
      _cancelVoice();
      _voiceSession = session;
      _isRecording = true;
      _settings.acceptRecording(true);
      _lastRecordedBytes = null;
      _lastAudioFrameCount = 0;
      _buttonEvents.add(
          DeviceButtonEvent(buttonId: 1, action: ButtonActionType.pressDown));
      _audioReceiver.startCollecting(sessionId: session);
      _log('硬件实时录音开始 session=$session');
    } else if (_voiceSession == session && params['event'] == 'release') {
      try {
        final frameCount = _audioReceiver.packetCount;
        _lastRecordedBytes = _audioReceiver.stopAndExport();
        _lastAudioFrameCount = frameCount;
        _isRecording = false;
        _settings.acceptRecording(false);
        _voiceSession = null;
        _binaryRecordingSession = null;
        _binaryRecordingKind = null;
        _buttonEvents.add(
            DeviceButtonEvent(buttonId: 1, action: ButtonActionType.release));
        _log('实时录音封装完成 bytes=${_lastRecordedBytes!.length} frames=$frameCount');
      } on FormatException {
        _cancelVoice();
        _log('音频为空或截断，已取消转写');
      }
    } else if (_voiceSession == session && params['event'] == 'abort') {
      _cancelVoice();
      _settings.acceptRecording(false);
      _log('设备取消了本段实时录音');
    }
  }

  void _cancelVoice() {
    if (_voiceSession != null && !_disposed) {
      _buttonEvents
          .add(DeviceButtonEvent(buttonId: 1, action: ButtonActionType.cancel));
    }
    _audioReceiver.cancel();
    _voiceSession = null;
    _binaryRecordingSession = null;
    _binaryRecordingKind = null;
    _isRecording = false;
  }

  Future<void> _rememberVerifiedDevice() async {
    final device = _device;
    if (device == null) return;
    final generation = _generation;
    final serial = _serialNumber;
    final name = _deviceName;
    final protocol = _profile?.protocol;
    final prefs = await SharedPreferences.getInstance();
    if (generation != _generation || _disposed) return;
    await prefs.setString(_lastIdKey, device.remoteId.str);
    if (generation != _generation || _disposed) return;
    await prefs.setString(_lastNameKey, name);
    if (generation != _generation || _disposed) return;
    if (serial != '--') await prefs.setString(_lastSnKey, serial);
    if (generation != _generation || _disposed) return;
    _hasVerifiedDevice = true;
    if (protocol != null && RegExp(r'^[A-Z]{2}[0-9]{14}$').hasMatch(serial)) {
      try {
        await _identityStore.save(RecorderSavedIdentity(remoteId: device.remoteId.str,
            serialNumber: serial, deviceName: name.length <= 64 ? name : '录音卡',
            protocol: protocol, previouslyVerified: true));
      } catch (_) {
        _log('设备已验证，但保存重连路由未完成；业务密钥保持');
      }
    }
  }

  bool canRestoreBinding(OwnedRecorderBinding binding) =>
      !_disposed &&
      !isConnecting &&
      !_isRecording &&
      _device != null &&
      _profile != null &&
      binding.matches(_serialNumber, _profile!.protocol);

  Future<bool> restoreOwnedBinding(OwnedRecorderBinding binding) async {
    if (!canRestoreBinding(binding)) {
      lastErrorMessage = '请先连接目标录音卡取得真实 SN；仅能恢复 SN 和协议均匹配的设备，且需结束录音';
      return false;
    }
    final id = _device!.remoteId.str;
    final generation = _generation;
    _restoringIdentity = true;
    _log('开始恢复与当前卡 SN/协议匹配的自有账号绑定资料');
    try {
      await disconnect();
      _checkGeneration(generation + 1);
      await binding.saveForDevice(_keyStore, id);
      _checkGeneration(generation + 1);
      _hasSharedKey = true;
      lastErrorMessage = null;
      _phase = '账号绑定材料已保存，等待设备验证';
      _log('共享密钥已进入安全存储；尚未报告鉴权成功，下一步重连挑战验证');
      return true;
    } catch (error) {
      lastErrorMessage =
          error is StateError ? '${error.message}' : '恢复设备绑定资料失败；未报告鉴权成功';
      _log(lastErrorMessage!);
      return false;
    } finally {
      _restoringIdentity = false;
      if (!_disposed) _stateChanges.add(null);
    }
  }

  Future<void> _clearSubscriptions() async {
    final subscriptions = List<StreamSubscription<dynamic>>.of(_subscriptions);
    _subscriptions.clear();
    await Future.wait(subscriptions.map((sub) async {
      try {
        await sub.cancel().timeout(cancellationTimeout);
      } catch (_) {
        _log('订阅清理未收到确认；旧回调受连接代次限制，不能完成新连接');
      }
    }));
    _decoder?.reset();
  }

  @override
  Future<bool> connect() =>
      _device != null ? connectDevice(_device!) : autoReconnectLastDevice();

  @override
  Future<void> disconnect() {
    _cancelReconnect = true;
    return _startDisconnect();
  }

  Future<void> _startDisconnect({bool reconnecting = false}) {
    final pending = _disconnectOperation;
    if (pending != null) return pending;
    final operation = _disconnect(reconnecting: reconnecting);
    _disconnectOperation = operation;
    unawaited(operation.whenComplete(() {
      if (_disconnectOperation == operation) {
        _disconnectOperation = null;
        if (!_disposed) _stateChanges.add(null);
      }
    }));
    return operation;
  }

  Future<bool> _cancelNativeConnection(BluetoothDevice device) async {
    try {
      await device
          .disconnect(
              queue: false, timeout: cancellationTimeout.inSeconds.clamp(1, 35))
          .timeout(cancellationTimeout);
      return true;
    } catch (_) {
      _log('取消已请求，但系统尚未确认断开；本次操作不再等待，不等同于已释放物理链路');
      return false;
    }
  }

  Future<void> _disconnect({bool reconnecting = false}) async {
    _manualDisconnect = true;
    ++_generation;
    _fileChannelReady = false;
    _longFiles.connectionLost();
    _resetNotifications();
    _settings.reset();
    unawaited(_longRecordings.connectionLost());
    final cancellation = _connectCancellation;
    if (cancellation != null && !cancellation.isCompleted)
      cancellation.complete();
    _authentication?.cancel();
    _discardCandidate();
    _cancelVoice();
    _finishWaiting(false);
    _phase = reconnecting ? '重连验证共享密钥' : 'App 请求断开连接';
    _log('已请求断开；不会清除系统 bond 或恢复出厂');
    final device = _device;
    var acknowledged = true;
    if (device != null) {
      acknowledged = await _cancelNativeConnection(device);
      await _readNativeDiagnostics(device, _generation);
    }
    await _clearSubscriptions();
    _linkEstablished = false;
    _isConnected = false;
    _isRecording = false;
    _isPaused = false;
    _command = null;
    _profile = null;
    _phase = acknowledged ? '已断开' : '已取消本次操作，等待系统断开';
    _log(acknowledged ? '连接已结束' : '操作等待已结束，未报告连接成功');
  }

  Future<void> unpairDevice() async {
    await disconnect();
    _hasVerifiedDevice = false;
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      _lastIdKey,
      _lastNameKey,
      _lastSnKey,
      'sunmate_last_ble_device_id',
      'sunmate_last_ble_device_name'
    ]) {
      await prefs.remove(key);
    }
    _log('已清除 App 保存的设备 ID；系统配对请在 iPhone 设置中管理');
  }

  // Telink 实时录音由硬件 voiceCmd 启停，不捏造 App 录音命令。
  bool _recordingUnavailable() {
    lastErrorMessage = !_isConnected
        ? '录音需要先完成设备业务鉴权；当前 $_phase'
        : '请使用录音卡物理按键开始和结束实时录音；尚未核实该设备的 App 主动录音控制';
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
    await _longFiles.dispose();
    await _longRecordings.dispose();
    await _initialization;
    _saveTimer?.cancel();
    await _saveLogs();
    _disposed = true;
    await _receiverSub.cancel();
    _audioReceiver.dispose();
    await _segmentSignals.close();
    await _buttonEvents.close();
    await _audioPackets.close();
    await _stateChanges.close();
    await _logs.close();
  }
}

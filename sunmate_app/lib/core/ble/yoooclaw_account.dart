import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'ble_protocol.dart';
import 'recorder_authentication.dart';
import 'official_account_session_store.dart';
import 'recorder_binding_backup_store.dart';

/// 仅使用用户自己登录后取得的绑定资料；不负责录音、转写或代理 AI 请求。
class OwnedRecorderBinding {
  final String serialNumber;
  final String deviceName;
  final RecorderProtocol protocol;
  Uint8List? _secret;

  OwnedRecorderBinding._(
      this.serialNumber, this.deviceName, this.protocol, this._secret);

  static OwnedRecorderBinding? fromAccountRecord(Map<String, dynamic> record) {
    final serial = record['externalDeviceId'];
    final info = record['extInfo'];
    if (serial is! String ||
        !RegExp(r'^[A-Za-z]{2}[0-9]{14}$').hasMatch(serial.trim()) ||
        info is! Map ||
        info['sharedSecret'] is! String) return null;
    final type = '${record['deviceType'] ?? ''}'.trim().toUpperCase();
    final RecorderProtocol protocol;
    if (['TELINK', 'BLE_TELINK', 'FIRST_GENERATION', 'GEN1', '1']
        .contains(type)) {
      protocol = RecorderProtocol.telink;
    } else if ([
      'AI_NOTE_6095',
      'AINOTE6095',
      'AI_NOTE6095',
      '6095',
      'GEN2',
      'SECOND_GENERATION',
      '2'
    ].contains(type)) {
      protocol = RecorderProtocol.aiNote6095;
    } else {
      return null;
    }
    try {
      final secret =
          RecorderCryptography.decode32(info['sharedSecret'] as String);
      final name = record['externalDeviceName'];
      return OwnedRecorderBinding._(
          serial.trim().toUpperCase(),
          name is String && name.length <= 64 ? name : '官方账号录音卡',
          protocol,
          secret);
    } on FormatException {
      return null;
    }
  }

  bool matches(String detectedSerial, RecorderProtocol detectedProtocol) =>
      _secret != null &&
      protocol == detectedProtocol &&
      serialNumber == detectedSerial.trim().toUpperCase();

  Future<void> saveForDevice(RecorderKeyStore store, String remoteId) async {
    final secret = _secret;
    if (secret == null) throw StateError('账号资料已关闭，请重新登录读取');
    final encoded = base64Encode(secret);
    final current = await store.read(remoteId, protocol);
    if (current != null) {
      final previous = RecorderCryptography.decode32(current);
      var difference = 0;
      for (var i = 0; i < 32; i++) difference |= previous[i] ^ secret[i];
      if (difference != 0) {
        throw StateError('本机已有不同的业务密钥，未覆盖；请保留诊断日志');
      }
      return;
    }
    await store.write(remoteId, protocol, encoded);
  }

  void clear() {
    _secret?.fillRange(0, _secret!.length, 0);
    _secret = null;
  }
}

class OfficialAccountException implements Exception {
  final String message;
  const OfficialAccountException(this.message);
  @override
  String toString() => message;
}

class AccountRecorderDevice {
  final String serialNumber;
  final String deviceName;
  final String? uuid;
  final String protocolLabel;
  final String? _mac;
  bool get hasMac => _mac != null;
  final bool hasSharedSecretField;
  final bool hasRecoverableKey;
  final bool hasStructuredBindingInfo;
  AccountRecorderDevice._(
      this.serialNumber,
      this.deviceName,
      this.uuid,
      this.protocolLabel,
      this._mac,
      this.hasSharedSecretField,
      this.hasRecoverableKey,
      this.hasStructuredBindingInfo);

  String get keyMaterialSummary => !hasStructuredBindingInfo
      ? '绑定资料格式待核对'
      : hasRecoverableKey
          ? '可恢复，仍需卡片验证'
          : hasSharedSecretField
              ? '字段已返回，格式或设备类型不匹配'
              : '账号未返回共享密钥';

  static AccountRecorderDevice? fromRecord(Map<String, dynamic> record) {
    final serial = record['externalDeviceId'];
    if (serial is! String ||
        !RegExp(r'^[A-Za-z]{2}[0-9]{14}$').hasMatch(serial.trim())) return null;
    final name = record['externalDeviceName'];
    final info = record['extInfo'];
    final uuid = info is Map ? info['uuid'] : null;
    final binding = OwnedRecorderBinding.fromAccountRecord(record);
    final recoverable = binding != null;
    final protocol = binding?.protocol.name;
    binding?.clear();
    final mac = info is Map ? info['mac'] : null;
    final type = record['deviceType'];
    final safeType =
        type is String && RegExp(r'^[A-Za-z0-9_]{1,32}$').hasMatch(type)
            ? type
            : type is num
                ? '$type'
                : '未提供或未识别';
    return AccountRecorderDevice._(
        serial.trim().toUpperCase(),
        name is String && name.isNotEmpty && name.length <= 64 ? name : '我的录音卡',
        uuid is String &&
                RegExp(r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$')
                    .hasMatch(uuid)
            ? uuid
            : null,
        protocol ?? safeType,
        mac is String && mac.trim().isNotEmpty && mac.length <= 128
            ? mac.trim()
            : null,
        info is Map && info.containsKey('sharedSecret'),
        recoverable,
        info is Map);
  }
}

enum OfficialAccountStage {
  sms('获取验证码'),
  login('验证码登录'),
  devices('读取设备列表'),
  verification('官方验机'),
  binding('同步账号绑定'),
  unbinding('解绑账号设备');

  final String label;
  const OfficialAccountStage(this.label);
}

/// App 同源渠道 3 的短信、登录与设备列表已由用户正常验证码登录验证。
/// 登录字段最初由静态线索组合，已被真实服务接受；不等同于捕获了 APK 请求。
/// 登录会话保存在系统安全存储，验证码不保存；打开后由正常账号接口核验有效性。
class YoooClawAccount {
  static const deviceService = 'https://openclaw-service.yoooclaw.com';
  final Dio _http;
  final OfficialAccountSessionStore _sessionStore;
  final RecorderBindingBackupStore _backupStore;
  bool _unbinding = false;
  // true 为服务器已接受；false 为请求结果不确定。均不自动重发。
  final Map<String, bool> _pendingUnbind = {};
  final Set<String> _confirmedUnbound = {};
  bool get hasPendingUnbind => _pendingUnbind.isNotEmpty;
  String? get unbindNotice => _pendingUnbind.isNotEmpty
      ? _pendingUnbind.values.any((accepted) => !accepted)
          ? '解绑请求结果尚未确认，请重新读取设备列表；不会自动重发请求。'
          : '服务器已接受解绑请求，尚未确认列表移除；请重新读取我的设备。'
      : _confirmedUnbound.isNotEmpty
          ? '已确认账号列表移除目标 SN。可添加新录音卡；若系统仍保留配对，请在 iPhone 设置中手动处理。旧密钥和恢复归档已保留，卡片侧状态仍需实际验证。'
          : null;
  static Future<void> _sessionStorageQueue = Future.value();
  bool _sessionSaved = false;
  bool get isSessionSaved => _sessionSaved;
  String? _token;
  String? _userId;
  bool _closed = false;
  List<OwnedRecorderBinding> _bindings = [];
  List<AccountRecorderDevice> _devices = [];
  Set<String> _listedSerials = {};
  bool _hasDeviceSnapshot = false;
  List<AccountRecorderDevice> get devices => List.unmodifiable(_devices);
  int _revision = 0;
  final List<String> _diagnostics = [];
  List<String> get diagnostics => List.unmodifiable(_diagnostics);
  int totalDevices = 0;
  int missingSharedSecretDevices = 0;
  bool get isLoggedIn => !_closed && _token != null;

  YoooClawAccount(
      {Dio? http,
      OfficialAccountSessionStore? sessionStore,
      RecorderBindingBackupStore? backupStore})
      : _backupStore = backupStore ?? SecureRecorderBindingBackupStore(),
        _sessionStore = sessionStore ?? SecureOfficialAccountSessionStore(),
        _http = http ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 15),
            ));

  Future<T> _withSessionStore<T>(Future<T> Function() action) {
    final operation = _sessionStorageQueue.then((_) => action());
    _sessionStorageQueue = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Map<String, String>? _decodeSession(String value) {
    if (value.length > 12000) return null;
    try {
      final data = jsonDecode(value);
      if (data is! Map || data['version'] != 1) return null;
      final token = data['token'], userId = data['userId'];
      if (token is! String || userId is! String || !_validSession(token, userId)) {
        return null;
      }
      return {'token': token, 'userId': userId};
    } on FormatException {
      return null;
    }
  }

  bool _validSession(String token, String userId) => token.isNotEmpty &&
      token.length <= 8192 &&
      RegExp(r'^[A-Za-z0-9._~+/-]+=*$').hasMatch(token) &&
      RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(userId);

  Future<bool> restoreSession() async {
    if (_closed) throw const OfficialAccountException('账号页面已关闭');
    if (isLoggedIn) return true;
    final revision = _revision;
    final Map<String, String>? saved;
    try {
      saved = await _withSessionStore(() async {
        final value = await _sessionStore.read();
        if (value == null) return null;
        final decoded = _decodeSession(value);
        if (decoded == null) await _sessionStore.delete();
        return decoded;
      });
    } catch (_) {
      throw const OfficialAccountException('暂时无法读取本机保存的登录，可稍后重试或手动登录');
    }
    if (_closed || revision != _revision || saved == null) return false;
    _token = saved['token'];
    _userId = saved['userId'];
    _sessionSaved = true;
    _revision++;
    _appendDiagnostic('已恢复本机安全保存的登录；仍需服务器确认有效性');
    return true;
  }

  Future<void> logout() async {
    if (_closed) throw const OfficialAccountException('账号页面已关闭');
    final revision = ++_revision;
    _pendingUnbind.clear();
    _confirmedUnbound.clear();
    _clearBindings();
    try {
      await _withSessionStore(() => _sessionStore.delete());
    } catch (_) {
      throw const OfficialAccountException('本机保存的登录未能清除，请重试退出账号');
    }
    if (revision != _revision) return;
    _token = null;
    _userId = null;
    _sessionSaved = false;
    _appendDiagnostic('已退出官方账号；录音卡业务密钥保留');
  }

  Future<void> _invalidateSession(String token, int revision) async {
    if (_closed || _token != token || _revision != revision) return;
    _revision++;
    _pendingUnbind.clear();
    _confirmedUnbound.clear();
    _token = null;
    _userId = null;
    _sessionSaved = false;
    _clearBindings();
    try {
      await _withSessionStore(() async {
        final value = await _sessionStore.read();
        if (value != null && _decodeSession(value)?['token'] == token) {
          await _sessionStore.delete();
        }
      });
    } catch (_) {
      _appendDiagnostic('登录已失效，本机缓存清理未完成；请重新登录');
    }
  }

  void _record(OfficialAccountStage stage, int? status,
      {String? code, String? scheme}) {
    if (_closed) return;
    _appendDiagnostic('${stage.label}：HTTP ${status ?? "无响应"}'
        '${code == null ? "" : "；业务码 $code"}'
        '${scheme == null ? "" : "；服务端认证方式 $scheme"}');
  }

  void _appendDiagnostic(String message) {
    if (_closed) return;
    _diagnostics.add(message);
    if (_diagnostics.length > 20) _diagnostics.removeAt(0);
  }

  String? _safeCode(Object? value) {
    final code = '$value';
    return RegExp(r'^[0-9]{1,6}$').hasMatch(code) ? code : null;
  }

  Future<Map<String, dynamic>> _post(String origin, String path,
      {required OfficialAccountStage stage,
      Object? data,
      bool authenticated = false}) async {
    if (_closed) throw const OfficialAccountException('账号页面已关闭');
    if (authenticated && !isLoggedIn) {
      throw const OfficialAccountException('请先通过自己的手机号验证码登录');
    }
    final requestToken = _token;
    final requestRevision = _revision;
    try {
      final response = await _http.post<String>('$origin$path',
          data: data,
          options: Options(
            followRedirects: false,
            responseType: ResponseType.plain,
            headers: {
              'Content-Type': 'application/json',
              // APK 中的公开产品标识，不是厂商密钥。
              'app_key': 'yoooclaw',
              if (authenticated) ...{
                // 接口的 WWW-Authenticate 要求 Bearer；Raw 只表示原样发送，
                // 不能据此把官网会话中的认证前缀删掉后直接下发。
                'Authorization': 'Bearer $_token',
                'UserId': _userId,
                'user_id': _userId,
              },
            },
          ));
      if (_closed) throw const OfficialAccountException('账号页面已关闭');
      if (authenticated && requestRevision != _revision) {
        throw const OfficialAccountException('账号会话已变化，请重新读取设备');
      }
      final text = response.data;
      if (response.statusCode != 200 ||
          text == null ||
          text.length > 2 * 1024 * 1024) {
        throw const OfficialAccountException('官方接口没有返回有效的响应');
      }
      final result = jsonDecode(text);
      if (result is! Map<String, dynamic>) {
        throw const OfficialAccountException('官方接口响应格式不兼容');
      }
      _record(stage, response.statusCode, code: _safeCode(result['code']));
      return result;
    } on DioException catch (error) {
      // 不向 UI/日志传播 Dio 请求体、Authorization、验证码或响应正文。
      final status = error.response?.statusCode;
      final challenges =
          error.response?.headers['www-authenticate'] ?? const <String>[];
      final scheme = challenges.any((challenge) =>
              RegExp(r'^Bearer\b', caseSensitive: false)
                  .hasMatch(challenge.trim()))
          ? 'Bearer'
          : null;
      String? code;
      try {
        final body = error.response?.data;
        final parsed = body is String && body.length <= 2 * 1024 * 1024
            ? jsonDecode(body)
            : null;
        if (parsed is Map) code = _safeCode(parsed['code']);
      } on FormatException {
        // HTML/纯文本错误页不显示正文，其中可能有凭据或追踪信息。
      }
      _record(stage, status, code: code, scheme: scheme);
      if (authenticated && status == 401 && requestToken != null) {
        await _invalidateSession(requestToken, requestRevision);
      }
      final reason = status == 401
          ? '登录凭证未被接受，请重新登录；尚不能据此判断 SDK 授权要求'
          : status == 403
              ? '服务器拒绝访问，尚不能确定是账号权限还是请求限制'
              : status == 429
                  ? '请求过于频繁，请稍后再试'
                  : '官方接口暂时不可用';
      throw OfficialAccountException('${stage.label}失败'
          '（${status == null ? "未收到 HTTP 响应" : "HTTP $status"}'
          '${code == null ? "" : "；业务码 $code"}）：$reason');
    } on FormatException {
      throw const OfficialAccountException('官方接口响应格式不兼容');
    }
  }

  void _requireSuccess(Map<String, dynamic> result,
      {required OfficialAccountStage stage, bool sms = false}) {
    final code = '${result['code']}';
    if (code == '200' || code == '000000' || (sms && code == '0')) return;
    final safeCode = _safeCode(code) ?? '未知';
    if (stage == OfficialAccountStage.unbinding) {
      throw OfficialAccountException('服务器未接受账号解绑（业务码 $safeCode）；未清除本机密钥，请重新读取设备核对');
    }
    throw OfficialAccountException(
        '${stage.label}未通过（业务码 $safeCode）；请检查验证码或账号权限');
  }

  Future<void> sendSms(String phone) async {
    if (!RegExp(r'^1[3-9][0-9]{9}$').hasMatch(phone)) {
      throw const OfficialAccountException('请输入正确的手机号');
    }
    _requireSuccess(
        await _post(deviceService, '/api/account/auth/open/sendLoginSms',
            stage: OfficialAccountStage.sms,
            data: {'phone': phone, 'channel': '3', 'deviceId': 'deviceId'}),
        stage: OfficialAccountStage.sms,
        sms: true);
  }

  Future<void> login(String phone, String smsCode) async {
    if (!RegExp(r'^1[3-9][0-9]{9}$').hasMatch(phone) ||
        !RegExp(r'^[0-9]{4}$').hasMatch(smsCode)) {
      throw const OfficialAccountException('请输入正确的手机号和 4 位验证码');
    }
    _token = null;
    _sessionSaved = false;
    final loginRevision = ++_revision;
    _pendingUnbind.clear();
    _confirmedUnbound.clear();
    _userId = null;
    _clearBindings();
    final result = await _post(
        deviceService, '/api/account/auth/login/open/loginOrRegister',
        stage: OfficialAccountStage.login,
        data: {
          'phone': phone,
          'smsCode': smsCode,
          'channel': '3',
          'deviceId': 'deviceId'
        });
    _requireSuccess(result, stage: OfficialAccountStage.login);
    if (_closed || loginRevision != _revision) {
      throw const OfficialAccountException('登录请求已失效，请使用当前登录结果');
    }
    final user = result['data'];
    final token = user is Map ? user['jwtToken'] : null;
    final id = user is Map ? user['id'] : null;
    if (token is! String || id == null) {
      throw const OfficialAccountException('官方 App 账号接口未返回有效会话');
    }
    final normalized = token
        .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '')
        .trim();
    final userId = '$id';
    if (!_validSession(normalized, userId)) {
      throw const OfficialAccountException('官方 App 账号接口返回的会话格式不兼容');
    }
    _token = normalized;
    _userId = userId;
    final revision = _revision;
    try {
      await _withSessionStore(() async {
        if (_closed || revision != _revision) return;
        await _sessionStore.write(jsonEncode({
          'version': 1, 'token': normalized, 'userId': userId
        }));
        if (!_closed && revision == _revision) _sessionSaved = true;
      });
    } catch (_) {
      _appendDiagnostic('本次登录可用，但系统安全存储未能保存，关闭后需重新登录');
    }
    if (_closed || revision != _revision) {
      throw const OfficialAccountException('登录会话已变化，请重新打开账号页面');
    }
  }

  Future<List<OwnedRecorderBinding>> loadBindings() async {
    if (_unbinding) {
      throw const OfficialAccountException('解绑操作进行中，请等待后重新读取');
    }
    final result = await _post(
        deviceService, '/api/device/toc/homePage/pub/index',
        stage: OfficialAccountStage.devices, authenticated: true);
    _requireSuccess(result, stage: OfficialAccountStage.devices);
    final data = result['data'];
    final records = data is Map ? data['deviceList'] : null;
    if (records is! List || records.length > 1000) {
      throw const OfficialAccountException('账号设备列表缺失或格式不兼容');
    }
    _appendDiagnostic('设备响应结构：顶层 ${result.length} 字段；data ${data.length} 字段；'
        '设备记录 ${records.length} 条（仅记录数量和已知字段类型，不输出原始内容）');
    _clearBindings();
    _revision++;
    totalDevices = records.length;
    final counts = <String, int>{};
    for (var index = 0; index < records.length; index++) {
      final record = records[index];
      if (record is Map<String, dynamic>) {
        if (index < 5) _appendDiagnostic(_recordShape(index + 1, record));
        final serial = record['externalDeviceId'];
        if (serial is String &&
            RegExp(r'^[A-Za-z]{2}[0-9]{14}$').hasMatch(serial.trim())) {
          final id = serial.trim().toUpperCase();
          counts[id] = (counts[id] ?? 0) + 1;
        }
        final info = record['extInfo'];
        if (info is Map && !info.containsKey('sharedSecret')) {
          missingSharedSecretDevices++;
        }
        final binding = OwnedRecorderBinding.fromAccountRecord(record);
        if (binding != null) _bindings.add(binding);
      }
    }
    // 同一 SN 有重复记录时不选取其中一条，即使另一条缺少密钥或协议不同。
    _bindings.removeWhere((b) {
      final ambiguous = counts[b.serialNumber] != 1;
      if (ambiguous) b.clear();
      return ambiguous;
    });
    _devices = records
        .whereType<Map<String, dynamic>>()
        .map(AccountRecorderDevice.fromRecord)
        .whereType<AccountRecorderDevice>()
        .where((device) => counts[device.serialNumber] == 1)
        .toList();
    _listedSerials = counts.keys.toSet();
    _hasDeviceSnapshot = true;
    _confirmedUnbound.removeWhere(_listedSerials.contains);
    for (final serial in _pendingUnbind.keys.toList()) {
      if (!_listedSerials.contains(serial)) {
        _confirmedUnbound.add(serial);
        _pendingUnbind.remove(serial);
      } else if (_pendingUnbind[serial] == false) {
        // 不确定请求经正常列表对照后仍有记录，允许再次手动确认。
        _pendingUnbind.remove(serial);
      }
    }
    _appendDiagnostic('设备资料：记录 $totalDevices；可恢复 ${_bindings.length}；'
        'sharedSecret 字段缺失 $missingSharedSecretDevices');
    return List.unmodifiable(_bindings);
  }

  bool canUnbindDevice(AccountRecorderDevice selected) =>
      isLoggedIn &&
      !_unbinding &&
      _hasDeviceSnapshot &&
      _devices.any((device) => identical(device, selected)) &&
      !_pendingUnbind.containsKey(selected.serialNumber) &&
      selected.hasMac &&
      selected.hasRecoverableKey;

  /// 仅账号解绑；不调用 HAL、不清卡、不删除活动密钥或系统配对。
  Future<void> unbindDevice(AccountRecorderDevice selected,
      {required bool Function() canProceed}) async {
    if (!canUnbindDevice(selected) || !canProceed()) {
      throw const OfficialAccountException('请重新读取并选择资料完整的设备，且先结束录音和蓝牙连接');
    }
    _unbinding = true;
    final revision = ++_revision; // 立即使既有验机/绑定会话失效。
    final serial = selected.serialNumber;
    void ensureCurrent() {
      if (!isLoggedIn ||
          revision != _revision ||
          !_devices.any((device) => identical(device, selected)) ||
          !canProceed()) {
        throw const OfficialAccountException('账号、设备资料或蓝牙状态已变化，请重新读取列表核对解绑结果');
      }
    }

    try {
      final candidates =
          _bindings.where((b) => b.serialNumber == serial).toList();
      if (candidates.length != 1 || candidates.single._secret == null) {
        throw const OfficialAccountException('缺少唯一可恢复资料，未发送解绑请求');
      }
      final binding = candidates.single;
      final archive = jsonEncode({
        'version': 1,
        'userId': _userId,
        'serialNumber': serial,
        'deviceName': selected.deviceName,
        'protocol': binding.protocol.name,
        'mac': selected._mac,
        if (selected.uuid != null) 'uuid': selected.uuid,
        'sharedSecret': base64Encode(binding._secret!),
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'purpose': 'pre-account-unbind-unverified-recovery',
      });
      try {
        await _backupStore.saveVerified(archive);
      } catch (_) {
        throw const OfficialAccountException('恢复资料安全备份或读回校验失败，未发送解绑请求');
      }
      ensureCurrent();
      _appendDiagnostic('解绑前恢复资料已独立安全归档并读回确认；活动密钥保留');
      _pendingUnbind[serial] = false;
      final result = await _post(
          deviceService, '/api/device/toc/externalDeviceBind/unbind',
          stage: OfficialAccountStage.unbinding,
          authenticated: true,
          data: {'deviceId': serial, 'mac': selected._mac});
      ensureCurrent();
      try {
        _requireSuccess(result, stage: OfficialAccountStage.unbinding);
      } on OfficialAccountException {
        _pendingUnbind.remove(serial);
        rethrow;
      }
      _pendingUnbind[serial] = true;
      _revision++;
      _clearBindings();
      _appendDiagnostic('服务器已接受账号解绑；须重新读取列表确认移除，未清卡或系统配对');
    } finally {
      _unbinding = false;
    }
  }

  String _recordShape(int index, Map<String, dynamic> record) {
    String shape(Object? value) => value == null
        ? 'null'
        : value is String
            ? (value.isEmpty ? '空字符串' : '非空字符串')
            : value is Map
                ? '对象'
                : value is List
                    ? '数组'
                    : '其它类型';
    String fields(Map map, List<String> names) => names
        .map((name) =>
            '$name=${map.containsKey(name) ? shape(map[name]) : "缺失"}')
        .join(', ');
    const names = [
      'externalDeviceId',
      'externalDeviceName',
      'deviceType',
      'extInfo'
    ];
    const extNames = ['mac', 'sharedSecret', 'uuid'];
    final info = record['extInfo'];
    final extra = record.keys.where((key) => !names.contains(key)).length;
    final ext = info is Map
        ? '扩展 ${info.length} 字段（额外 ${info.keys.where((key) => !extNames.contains(key)).length}）：${fields(info, extNames)}'
        : '扩展不是对象';
    return '设备记录 #$index：${record.length} 字段（额外 $extra）；${fields(record, names)}；$ext';
  }

  RecorderAccountSession sessionForDevice(AccountRecorderDevice selected) {
    final serial = selected.serialNumber;
    final revision = _revision;
    void ensureCurrent(String sn) {
      if (!isLoggedIn ||
          _unbinding ||
          !_hasDeviceSnapshot ||
          _pendingUnbind.containsKey(serial) ||
          revision != _revision ||
          sn != serial ||
          !_devices.any((device) => device.serialNumber == serial)) {
        throw const OfficialAccountException('账号已关闭、资料已更新或设备不匹配，请重新选择');
      }
    }

    ensureCurrent(serial);
    return _sessionForSelection(serial, selected.deviceName, ensureCurrent,
        uuid: selected.uuid, hasRecoverableKey: selected.hasRecoverableKey);
  }

  RecorderAccountSession sessionForNewDevice(RecorderScanIdentity identity) {
    final serial = identity.serialNumber;
    final revision = _revision;
    void ensureCurrent(String sn) {
      if (!isLoggedIn ||
          _unbinding ||
          _pendingUnbind.containsKey(serial) ||
          revision != _revision ||
          !_hasDeviceSnapshot ||
          sn != serial) {
        throw const OfficialAccountException('账号资料已变化，请返回重新读取设备后再添加');
      }
      // 包括重复记录：不能绕过已有设备恢复或歧义检查进入首次协商。
      if (_listedSerials.contains(serial)) {
        throw const OfficialAccountException('该 SN 已在账号设备列表中，请返回选择已有设备');
      }
    }

    ensureCurrent(serial);
    if (!identity.isFresh(DateTime.now())) {
      throw const OfficialAccountException('扫描记录已过期，请重新搜索录音卡');
    }
    return _sessionForSelection(serial, identity.deviceName, ensureCurrent,
        newDeviceIdentity: identity);
  }

  RecorderAccountSession _sessionForSelection(String serial, String deviceName,
      void Function(String) ensureCurrent,
      {String? uuid,
      bool hasRecoverableKey = false,
      RecorderScanIdentity? newDeviceIdentity}) {
    String? checkedMac;
    return RecorderAccountSession(
        serial,
        ({required checkContent, required mac, required sn}) async {
          ensureCurrent(sn);
          if (checkContent.isEmpty ||
              checkContent.length > 2048 ||
              mac.isEmpty ||
              mac.length > 128) {
            throw const OfficialAccountException('设备挑战格式无效');
          }
          final result = await _post(
              deviceService, '/api/device/toc/externalDeviceBind/check',
              stage: OfficialAccountStage.verification,
              authenticated: true,
              data: {'checkContent': checkContent, 'mac': mac, 'sn': sn});
          ensureCurrent(sn);
          _requireSuccess(result, stage: OfficialAccountStage.verification);
          final data = result['data'];
          final hmac = data is Map ? data['hmac'] : null;
          if (hmac is! String || hmac.trim().isEmpty || hmac.length > 2048) {
            throw const OfficialAccountException('官方验机未返回有效答复');
          }
          checkedMac = mac;
          return hmac.trim();
        },
        ({required sn, required mac, required sharedSecret}) async {
          ensureCurrent(sn);
          if (checkedMac != mac) {
            throw const OfficialAccountException('缺少同一设备的真实验机结果，未同步绑定');
          }
          RecorderCryptography.decode32(sharedSecret);
          if (mac.isEmpty || mac.length > 128) {
            throw const OfficialAccountException('设备未提供有效 MAC，未同步绑定');
          }
          final result = await _post(
              deviceService, '/api/device/toc/externalDeviceBind/bind',
              stage: OfficialAccountStage.binding,
              authenticated: true,
              data: {
                'deviceId': serial,
                'deviceName': deviceName,
                'extInfo': {
                  'mac': mac,
                  'sharedSecret': sharedSecret,
                  if (uuid != null) 'uuid': uuid
                }
              });
          ensureCurrent(sn);
          _requireSuccess(result, stage: OfficialAccountStage.binding);
        },
        hasRecoverableKey: hasRecoverableKey,
        newDeviceIdentity: newDeviceIdentity,
        restoreKey: newDeviceIdentity != null
            ? null
            : (deviceId, protocol, detectedSerial, store) async {
                ensureCurrent(detectedSerial);
                final candidates = _bindings
                    .where((binding) => binding.matches(detectedSerial, protocol))
                    .toList();
                if (candidates.length != 1) return false;
                await candidates.single.saveForDevice(store, deviceId);
                ensureCurrent(detectedSerial);
                return true;
              });
  }

  void _clearBindings() {
    for (final binding in _bindings) binding.clear();
    _bindings = [];
    _devices = [];
    _listedSerials = {};
    _hasDeviceSnapshot = false;
    totalDevices = 0;
    missingSharedSecretDevices = 0;
  }

  void close() {
    _revision++;
    _closed = true;
    _token = null;
    _userId = null;
    _sessionSaved = false;
    _clearBindings();
    _diagnostics.clear();
    _http.close(force: true);
  }
}

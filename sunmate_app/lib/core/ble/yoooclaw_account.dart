import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'ble_protocol.dart';
import 'recorder_authentication.dart';

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

enum OfficialAccountStage {
  sms('获取验证码'),
  login('验证码登录'),
  devices('读取设备列表');

  final String label;
  const OfficialAccountStage(this.label);
}

/// App 同源渠道 3 的短信、登录与设备列表已由用户正常验证码登录验证。
/// 登录字段最初由静态线索组合，已被真实服务接受；不等同于捕获了 APK 请求。
/// 会话只在本次页面内存中存在；持久保存的只有用户确认恢复的设备共享密钥。
class YoooClawAccount {
  static const deviceService = 'https://openclaw-service.yoooclaw.com';
  final Dio _http;
  String? _token;
  String? _userId;
  bool _closed = false;
  List<OwnedRecorderBinding> _bindings = [];
  final List<String> _diagnostics = [];
  List<String> get diagnostics => List.unmodifiable(_diagnostics);
  int totalDevices = 0;
  int missingSharedSecretDevices = 0;
  bool get isLoggedIn => !_closed && _token != null;

  YoooClawAccount({Dio? http})
      : _http = http ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 15),
            ));

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
    if (normalized.isEmpty ||
        normalized.length > 8192 ||
        !RegExp(r'^[A-Za-z0-9._~+/-]+=*$').hasMatch(normalized) ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(userId)) {
      throw const OfficialAccountException('官方 App 账号接口返回的会话格式不兼容');
    }
    _token = normalized;
    _userId = userId;
  }

  Future<List<OwnedRecorderBinding>> loadBindings() async {
    final result = await _post(
        deviceService, '/api/device/toc/homePage/pub/index',
        stage: OfficialAccountStage.devices, authenticated: true);
    _requireSuccess(result, stage: OfficialAccountStage.devices);
    final data = result['data'];
    final records = data is Map ? data['deviceList'] : null;
    if (records is! List || records.length > 1000) {
      throw const OfficialAccountException('账号设备列表缺失或格式不兼容');
    }
    _clearBindings();
    totalDevices = records.length;
    final counts = <String, int>{};
    for (final record in records) {
      if (record is Map<String, dynamic>) {
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
    _appendDiagnostic('设备资料：记录 $totalDevices；可恢复 ${_bindings.length}；'
        'sharedSecret 字段缺失 $missingSharedSecretDevices');
    return List.unmodifiable(_bindings);
  }

  void _clearBindings() {
    for (final binding in _bindings) binding.clear();
    _bindings = [];
    totalDevices = 0;
    missingSharedSecretDevices = 0;
  }

  void close() {
    _closed = true;
    _token = null;
    _userId = null;
    _clearBindings();
    _diagnostics.clear();
    _http.close(force: true);
  }
}

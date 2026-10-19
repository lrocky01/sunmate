import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'ble_json_rpc.dart';
import 'ble_protocol.dart';

/// 此处只实现已经从官方代码核实的密码协议，不生成厂商验机凭据。
class RecorderCryptography {
  final _exchange = X25519();

  Future<SimpleKeyPair> newKeyPair() => _exchange.newKeyPair();

  Future<Uint8List> sharedSecret(
      SimpleKeyPair phoneKey, String devicePublicKey) async {
    final publicBytes = decode32(devicePublicKey);
    final secret = await _exchange.sharedSecretKey(
      keyPair: phoneKey,
      remotePublicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
    );
    final bytes = Uint8List.fromList(await secret.extractBytes());
    if (bytes.length != 32 || bytes.every((b) => b == 0)) {
      throw const FormatException('设备公钥不能建立有效的 X25519 共享密钥');
    }
    return bytes;
  }

  static Uint8List decode32(String encoded) {
    late final Uint8List bytes;
    try {
      bytes = base64Decode(encoded.trim());
    } on FormatException {
      throw const FormatException('业务密钥或公钥不是合法 Base64');
    }
    if (bytes.length != 32 || bytes.every((b) => b == 0)) {
      throw const FormatException('业务密钥或公钥必须为非零的 32 字节');
    }
    return bytes;
  }

  static Future<String> answerIdentity(
      List<int> sharedSecret, String random) async {
    if (sharedSecret.length != 32 || sharedSecret.every((b) => b == 0)) {
      throw const FormatException('共享密钥长度无效');
    }
    final challenge = base64Decode(random);
    if (challenge.isEmpty || challenge.length > 1024) {
      throw const FormatException('设备身份挑战长度无效');
    }
    // 与官方 AES/CBC/PKCS5Padding 一致：AES 的 PKCS5 实际按 16 字节
    // 分组填充。全零 IV 是外设现有协议要求，不用于其它数据加密。
    final box = await AesCbc.with256bits(macAlgorithm: MacAlgorithm.empty)
        .encrypt(challenge,
            secretKey: SecretKey(sharedSecret), nonce: Uint8List(16));
    return base64Encode(box.cipherText);
  }
}

abstract interface class RecorderKeyStore {
  Future<String?> read(String deviceId, RecorderProtocol protocol);
  Future<void> write(
      String deviceId, RecorderProtocol protocol, String sharedSecret);
}

/// 业务密钥只进入 Keychain / Android KeyStore 保护的存储，不进诊断日志或偏好。
class SecureRecorderKeyStore implements RecorderKeyStore {
  final FlutterSecureStorage _storage;
  SecureRecorderKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                  accessibility:
                      KeychainAccessibility.first_unlock_this_device),
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  String _key(String deviceId, RecorderProtocol protocol) =>
      'sunmate_recorder_key_v1_${protocol.name}_${Uri.encodeComponent(deviceId.toLowerCase())}';

  @override
  Future<String?> read(String deviceId, RecorderProtocol protocol) =>
      _storage.read(key: _key(deviceId, protocol));

  @override
  Future<void> write(
      String deviceId, RecorderProtocol protocol, String sharedSecret) async {
    RecorderCryptography.decode32(sharedSecret);
    await _storage.write(key: _key(deviceId, protocol), value: sharedSecret);
  }
}

/// 合法厂商接入层应返回当前设备挑战的真实 HMAC；缺失时不发送 verifyResult。
typedef ManufacturerVerifier = Future<String> Function(
    {required String checkContent, required String mac, required String sn});

typedef PairingCommitter = Future<void> Function(
    {required String sn, required String mac, required String sharedSecret});

/// 一次已有设备恢复或新卡选择的能力；会话与密钥不出现在诊断中。
class RecorderAccountSession {
  final String serialNumber;
  final ManufacturerVerifier verifier;
  final PairingCommitter committer;
  final bool hasRecoverableKey;
  /// 密码备份恢复仅做本地密钥映射及真实AES，禁止首次绑定/云验机。
  final bool isOfflineBackup;
  final RecorderScanIdentity? newDeviceIdentity;
  final Future<bool> Function(String deviceId, RecorderProtocol protocol,
      String detectedSerial, RecorderKeyStore store)? restoreKey;
  /// 仅本机比较所选账号与该UUID已有key，不恢复或写入key。
  final Future<bool> Function(String deviceId, RecorderProtocol protocol,
      RecorderKeyStore store)? matchesExistingKey;
  /// 系统候选异步查询和接入前后均需检查账号代次。
  final void Function()? validateCurrent;
  RecorderAccountSession(this.serialNumber, this.verifier, this.committer,
      {this.restoreKey, this.hasRecoverableKey = false, this.isOfflineBackup = false, this.newDeviceIdentity,
      this.matchesExistingKey, this.validateCurrent});
}

enum RecorderAuthenticationState {
  idle,
  awaitingManufacturer,
  awaitingPairing,
  awaitingIdentityResult,
  keyNegotiated,
  verified,
  failed,
}

class RecorderAuthentication {
  final RecorderProtocol protocol;
  final String deviceId;
  final RecorderKeyStore store;
  final ManufacturerVerifier? verifier;
  final PairingCommitter? committer;
  /// 本地key落盘后记录待验证路由；不接收或复制密钥值。
  final Future<void> Function(String serialNumber)? onKeySaved;
  final RecorderCryptography _crypto;
  RecorderAuthenticationState state = RecorderAuthenticationState.idle;
  SimpleKeyPair? _phoneKey;
  Uint8List? _sharedSecret;
  String? _verifiedSn;
  String? _verifiedMac;
  bool _active = true;

  RecorderAuthentication({
    required this.protocol,
    required this.deviceId,
    required this.store,
    this.verifier,
    this.committer,
    this.onKeySaved,
    RecorderCryptography? cryptography,
  }) : _crypto = cryptography ?? RecorderCryptography();

  Future<bool> loadKey() async {
    final String? encoded;
    try {
      encoded = await store.read(deviceId, protocol);
    } catch (_) {
      throw StateError('读取设备安全密钥存储失败');
    }
    _checkActive();
    if (encoded == null) return false;
    _sharedSecret = RecorderCryptography.decode32(encoded);
    return true;
  }

  Future<Uint8List> answerManufacturer(Map<String, dynamic> params) async {
    if (protocol != RecorderProtocol.telink) {
      throw StateError('AiNote6095 的 iOS 首次绑定参数尚待独立验证');
    }
    if (state != RecorderAuthenticationState.idle) {
      throw StateError('拒绝重复或错序的厂商挑战');
    }
    _checkActive();
    if (_sharedSecret != null) {
      throw StateError('本机已有共享密钥；不自动重新协商或覆盖，请保留诊断');
    }
    final provider = verifier;
    if (provider == null) {
      throw StateError('需要自己的官方账号绑定材料或合法厂商验机接口；未发送假凭证');
    }
    String requireField(String field) {
      final value = params[field];
      if (value is! String || value.trim().isEmpty || value.length > 2048) {
        throw const FormatException('厂商挑战缺少必要的设备字段');
      }
      return value.trim();
    }

    final encrypted = requireField('encrypted');
    final mac = requireField('mac');
    final sn = requireField('sn');
    _verifiedSn = sn;
    _verifiedMac = mac;
    state = RecorderAuthenticationState.awaitingManufacturer;
    final hmac =
        (await provider(checkContent: encrypted, mac: mac, sn: sn)).trim();
    _checkActive();
    if (hmac.isEmpty || hmac.length > 2048) {
      state = RecorderAuthenticationState.failed;
      throw const FormatException('厂商未返回有效验机答复');
    }
    final phoneKey = await _crypto.newKeyPair();
    _checkActive();
    _phoneKey = phoneKey;
    final publicKey = await phoneKey.extractPublicKey();
    _checkActive();
    state = RecorderAuthenticationState.awaitingPairing;
    return BleJsonRpc.request('verifyResult', {
      'encrypted_random': hmac,
      'public_key': base64Encode(publicKey.bytes),
      // 官方 iOS/Telink 成功报文使用整数 1；Android 保持不传此字段。
      if (defaultTargetPlatform == TargetPlatform.iOS) 'isIos': 1,
    });
  }

  Future<void> acceptPairing(Map<String, dynamic> params) async {
    _checkActive();
    final phoneKey = _phoneKey;
    if (state != RecorderAuthenticationState.awaitingPairing ||
        phoneKey == null ||
        params['success'] != true ||
        params['public_key'] is! String) {
      throw StateError('拒绝失败、未经请求或缺少公钥的配对回执');
    }
    final secret = await _crypto.sharedSecret(phoneKey, params['public_key']);
    _checkActive();
    final existing = await store.read(deviceId, protocol);
    _checkActive();
    if (existing != null) throw StateError('安全存储中已有密钥，未覆盖');
    await store.write(deviceId, protocol, base64Encode(secret));
    _checkActive();
    _sharedSecret = secret;
    _phoneKey = null;
    await onKeySaved?.call(_verifiedSn!);
    _checkActive();
    final commit = committer;
    if (commit != null) {
      await commit(
          sn: _verifiedSn!,
          mac: _verifiedMac!,
          sharedSecret: base64Encode(secret));
      _checkActive();
    }
    // 还需一次设备挑战确认双方确实持有同一密钥，不在公钥交换时报告就绪。
    state = RecorderAuthenticationState.keyNegotiated;
  }

  Future<Uint8List> answerIdentity(Map<String, dynamic> params,
      {required int timestampSeconds}) async {
    _checkActive();
    if (state != RecorderAuthenticationState.idle &&
        state != RecorderAuthenticationState.keyNegotiated &&
        state != RecorderAuthenticationState.verified) {
      throw StateError('拒绝重复或错序的身份挑战');
    }
    final secret = _sharedSecret;
    if (secret == null) throw StateError('本机尚无这台设备的合法共享密钥');
    final random = params['random'];
    if (random is! String) throw const FormatException('身份挑战缺少 random');
    final encrypted = await RecorderCryptography.answerIdentity(secret, random);
    _checkActive();
    state = RecorderAuthenticationState.awaitingIdentityResult;
    return BleJsonRpc.request('verifyIdentity', {
      if (protocol == RecorderProtocol.aiNote6095)
        'timestamp': '$timestampSeconds',
      'encrypted': encrypted,
    });
  }

  bool acceptIdentityResult(Object? success) {
    if (!_active ||
        state != RecorderAuthenticationState.awaitingIdentityResult) {
      return false;
    }
    state = success == true
        ? RecorderAuthenticationState.verified
        : RecorderAuthenticationState.failed;
    return state == RecorderAuthenticationState.verified;
  }

  void _checkActive() {
    if (!_active) throw StateError('业务鉴权已取消');
  }

  void cancel() {
    _active = false;
    _sharedSecret?.fillRange(0, _sharedSecret!.length, 0);
    _sharedSecret = null;
    _phoneKey = null;
  }
}

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'ble_protocol.dart';
import 'recorder_authentication.dart';
import 'recorder_saved_identity.dart';

/// 文件中的身份不带旧手机UUID；导入不构成卡片身份验证。
class PortableRecorderMaterial {
  final String serialNumber;
  final String deviceName;
  final RecorderProtocol protocol;
  final Uint8List _secret;

  PortableRecorderMaterial._(
      this.serialNumber, this.deviceName, this.protocol, this._secret);

  factory PortableRecorderMaterial.fromJson(Object? value) {
    if (value is! Map ||
        value.length != 5 ||
        value['version'] != 1 ||
        value['sn'] is! String ||
        value['name'] is! String ||
        value['protocol'] != RecorderProtocol.telink.name ||
        value['secret'] is! String) {
      throw const FormatException('备份设备资料无效或协议暂不支持');
    }
    // 复用路由身份的SN/名称格式限制，但不把它写成已验证路由。
    final identity = RecorderSavedIdentity(
        remoteId: 'backup-validation',
        serialNumber: value['sn'],
        deviceName: value['name'],
        protocol: RecorderProtocol.telink);
    return PortableRecorderMaterial._(
        identity.serialNumber,
        identity.deviceName,
        identity.protocol,
        RecorderCryptography.decode32(value['secret']));
  }

  Map<String, Object> _json() {
    if (_secret.every((b) => b == 0)) throw StateError('备份资料已关闭');
    return {
      'version': 1,
      'sn': serialNumber,
      'name': deviceName,
      'protocol': protocol.name,
      'secret': base64Encode(_secret)
    };
  }

  bool _sameKey(String value) {
    final bytes = RecorderCryptography.decode32(value);
    try {
      var difference = 0;
      for (var i = 0; i < 32; i++) difference |= bytes[i] ^ _secret[i];
      return difference == 0;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  void clear() => _secret.fillRange(0, _secret.length, 0);
  @override
  String toString() => 'PortableRecorderMaterial(redacted)';
}

/// 固定成本和格式，拒绝由文件指定任意KDF工作量。CBC仅用于既有卡片协议；
/// 便携文件独立使用带完整性认证的GCM，密码不入安全存储或文件。
class RecorderBackupCodec {
  static const maximumFileBytes = 16384;
  static const iterations = 600000;
  static const _aad =
      'SunMate.recorder-backup.v1/PBKDF2-SHA256-600000/AES256GCM';

  static void validatePassword(String password) {
    if (password.runes.length < 12 ||
        utf8.encode(password).length > 1024 ||
        password.trim().isEmpty) {
      throw const FormatException('请设置至少12个字符的备份密码，最长1024字节');
    }
  }

  Future<Uint8List> encrypt(
      PortableRecorderMaterial material, String password) {
    validatePassword(password);
    final payload = jsonEncode(material._json());
    return Isolate.run(() => _encrypt(payload, password));
  }

  Future<PortableRecorderMaterial> decrypt(
      Uint8List file, String password) async {
    validatePassword(password);
    if (file.isEmpty || file.length > maximumFileBytes) {
      throw const FormatException('备份文件为空或超过16KB');
    }
    final json = await Isolate.run(() => _decrypt(file, password));
    return PortableRecorderMaterial.fromJson(jsonDecode(json));
  }

  static Future<SecretKey> _derive(String password, List<int> salt) =>
      Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
          .deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

  static Future<Uint8List> _encrypt(String payload, String password) async {
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final algorithm = AesGcm.with256bits();
    final box = await algorithm.encrypt(utf8.encode(payload),
        secretKey: await _derive(password, salt), aad: utf8.encode(_aad));
    return Uint8List.fromList(utf8.encode(jsonEncode({
      'format': 'sunmate-recorder-backup',
      'version': 1,
      'kdf': 'PBKDF2-HMAC-SHA256',
      'iterations': iterations,
      'cipher': 'AES-256-GCM',
      'salt': base64Encode(salt),
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'tag': base64Encode(box.mac.bytes),
    })));
  }

  static Future<String> _decrypt(Uint8List file, String password) async {
    try {
      final envelope = jsonDecode(utf8.decode(file));
      if (envelope is! Map ||
          envelope.length != 9 ||
          envelope['format'] != 'sunmate-recorder-backup' ||
          envelope['version'] != 1 ||
          envelope['kdf'] != 'PBKDF2-HMAC-SHA256' ||
          envelope['iterations'] != iterations ||
          envelope['cipher'] != 'AES-256-GCM') {
        throw const FormatException();
      }
      Uint8List field(String key, int min, int max) {
        if (envelope[key] is! String) throw const FormatException();
        final bytes = base64Decode(envelope[key]);
        if (bytes.length < min || bytes.length > max)
          throw const FormatException();
        return bytes;
      }

      final salt = field('salt', 16, 16);
      final nonce = field('nonce', 12, 12);
      final tag = field('tag', 16, 16);
      final ciphertext = field('ciphertext', 1, 4096);
      final plaintext = await AesGcm.with256bits().decrypt(
          SecretBox(ciphertext, nonce: nonce, mac: Mac(tag)),
          secretKey: await _derive(password, salt),
          aad: utf8.encode(_aad));
      try {
        return utf8.decode(plaintext);
      } finally {
        plaintext.fillRange(0, plaintext.length, 0);
      }
    } catch (_) {
      // 不向UI/日志暴露原始文件、密码或底层异常携带的数据。
      throw const FormatException('无法打开备份：密码错误、文件损坏或格式不支持');
    }
  }
}

/// 导入资料只在安全存储内暂存；与活动UUID密钥分开，不自动连接/覆盖。
class RecorderPortableStore {
  static const _prefix = 'sunmate_portable_recorder_v1_';
  final FlutterSecureStorage _storage;
  Future<void> _writes = Future.value();
  RecorderPortableStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
                iOptions: IOSOptions(
                    accessibility:
                        KeychainAccessibility.first_unlock_this_device),
                aOptions: AndroidOptions(encryptedSharedPreferences: true));

  Future<List<PortableRecorderMaterial>> readAll() async {
    final records = (await _storage.readAll())
        .entries
        .where((e) => e.key.startsWith(_prefix));
    if (records.length > 32) throw StateError('导入的备份数量过多');
    final result = <PortableRecorderMaterial>[];
    try {
      for (final entry in records) {
        final value =
            PortableRecorderMaterial.fromJson(jsonDecode(entry.value));
        result.add(value);
        if (entry.key != '$_prefix${value.serialNumber}')
          throw const FormatException();
      }
      return result;
    } catch (_) {
      for (final value in result) {
        value.clear();
      }
      throw StateError('本机备份资料无法读取，未改动密钥');
    }
  }

  Future<void> save(PortableRecorderMaterial material) {
    final value = jsonEncode(material._json());
    final operation = _writes.then((_) async {
      final key = '$_prefix${material.serialNumber}';
      final existing = await _storage.read(key: key);
      if (existing != null) {
        final previous =
            PortableRecorderMaterial.fromJson(jsonDecode(existing));
        try {
          if (!previous._sameKey(material._json()['secret'] as String)) {
            throw StateError('该SN已有不同的备份密钥，未覆盖');
          }
        } finally {
          previous.clear();
        }
        return;
      }
      if ((await _storage.readAll())
              .keys
              .where((k) => k.startsWith(_prefix))
              .length >=
          32) {
        throw StateError('本机备份数量已满');
      }
      await _storage.write(key: key, value: value);
      if (await _storage.read(key: key) != value) throw StateError('安全保存备份未完成');
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }
}

class RecorderBackupService {
  final RecorderKeyStore keys;
  final RecorderIdentityStore identities;
  final RecorderPortableStore imported;
  final RecorderBackupCodec codec;
  RecorderBackupService(
      {required this.keys,
      RecorderIdentityStore? identities,
      RecorderPortableStore? imported,
      RecorderBackupCodec? codec})
      : identities = identities ?? RecorderIdentityStore(),
        imported = imported ?? RecorderPortableStore(),
        codec = codec ?? RecorderBackupCodec();

  Future<List<RecorderSavedIdentity>> exportable() async => (await identities
          .readAll())
      .where(
          (i) => i.previouslyVerified && i.protocol == RecorderProtocol.telink)
      .toList();

  Future<Uint8List> export(
      RecorderSavedIdentity selected, String password) async {
    final matches = (await exportable()).where((r) => r.sameDevice(selected));
    if (matches.length != 1) throw StateError('请先连接卡片完成真实AES验证，再导出');
    final encoded = await keys.read(selected.remoteId, selected.protocol);
    if (encoded == null) throw StateError('本机没有该卡片的业务密钥');
    final material = PortableRecorderMaterial.fromJson({
      'version': 1,
      'sn': selected.serialNumber,
      'name': selected.deviceName,
      'protocol': selected.protocol.name,
      'secret': encoded
    });
    try {
      return await codec.encrypt(material, password);
    } finally {
      material.clear();
    }
  }

  Future<void> _checkLocal(PortableRecorderMaterial material) async {
    for (final identity in await identities.readAll()) {
      if (identity.serialNumber != material.serialNumber) continue;
      if (identity.protocol != material.protocol)
        throw StateError('相同SN的本机协议冲突，未导入');
      final key = await keys.read(identity.remoteId, identity.protocol);
      if (key != null && !material._sameKey(key)) {
        throw StateError('该卡片已有不同的本机密钥，未覆盖');
      }
    }
  }

  Future<void> acceptImport(PortableRecorderMaterial material) async {
    await _checkLocal(material);
    await imported.save(material);
  }

  /// 仅复用原连接状态机的恢复能力，两个厂商/云回调永远拒绝调用。
  RecorderAccountSession offlineSession(
      PortableRecorderMaterial material, RecorderScanIdentity scan) {
    if (!scan.isFresh(DateTime.now()) ||
        scan.serialNumber != material.serialNumber ||
        scan.protocol != material.protocol)
      throw StateError('当前广播SN与备份不匹配，请重新搜索');
    void validate() {
      material._json();
    }

    return RecorderAccountSession(
        material.serialNumber,
        ({required checkContent, required mac, required sn}) async =>
            throw StateError('备份恢复不执行厂商首次验机'),
        ({required sn, required mac, required sharedSecret}) async =>
            throw StateError('备份恢复不执行云绑定'),
        isOfflineBackup: true,
        hasRecoverableKey: true,
        validateCurrent: validate,
        restoreKey: (id, protocol, serial, store) async {
      validate();
      if (id.toLowerCase() != scan.remoteId.toLowerCase() ||
          serial != material.serialNumber ||
          protocol != material.protocol) {
        throw StateError('实际设备与备份身份不匹配');
      }
      await _checkLocal(material);
      final local = await store.read(id, protocol);
      if (local != null && !material._sameKey(local))
        throw StateError('当前设备已有不同密钥，未覆盖');
      if (local == null)
        await store.write(id, protocol, material._json()['secret'] as String);
      if (!material._sameKey((await store.read(id, protocol)) ?? ''))
        throw StateError('恢复密钥未保存成功');
      return true;
    }, matchesExistingKey: (id, protocol, store) async {
      validate();
      if (protocol != material.protocol) return false;
      final local = await store.read(id, protocol);
      return local != null && material._sameKey(local);
    });
  }
}

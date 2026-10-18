import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 独立归档账号恢复材料，不写入或删除活动 BLE 密钥、登录条目。
abstract interface class RecorderBindingBackupStore {
  Future<void> saveVerified(String value);
}

class SecureRecorderBindingBackupStore implements RecorderBindingBackupStore {
  static const keyPrefix = 'sunmate_recorder_binding_archive_v1_';
  final FlutterSecureStorage _storage;
  SecureRecorderBindingBackupStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
                iOptions: IOSOptions(
                    accessibility:
                        KeychainAccessibility.first_unlock_this_device),
                aOptions: AndroidOptions(encryptedSharedPreferences: true));

  @override
  Future<void> saveVerified(String value) async {
    final random = Random.secure();
    final suffix =
        base64UrlEncode(List.generate(32, (_) => random.nextInt(256)));
    final key = '$keyPrefix$suffix';
    // 每次独立归档，不能覆盖此前恢复材料。
    if (await _storage.read(key: key) != null)
      throw StateError('archive collision');
    await _storage.write(key: key, value: value);
    if (await _storage.read(key: key) != value) {
      throw StateError('archive verification failed');
    }
  }
}

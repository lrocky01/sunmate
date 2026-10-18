import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class OfficialAccountSessionStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

/// 账号登录使用独立条目；退出账号不接触录音卡的业务密钥。
class SecureOfficialAccountSessionStore implements OfficialAccountSessionStore {
  static const storageKey = 'sunmate_official_account_session_v1';
  final FlutterSecureStorage _storage;
  SecureOfficialAccountSessionStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
                iOptions: IOSOptions(
                    accessibility:
                        KeychainAccessibility.first_unlock_this_device),
                aOptions: AndroidOptions(encryptedSharedPreferences: true));

  @override
  Future<String?> read() => _storage.read(key: storageKey);
  @override
  Future<void> write(String value) =>
      _storage.write(key: storageKey, value: value);
  @override
  Future<void> delete() => _storage.delete(key: storageKey);
}

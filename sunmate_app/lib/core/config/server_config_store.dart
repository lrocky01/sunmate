import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class ServerConfigStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// 独立安全条目，不读写账号会话或录音卡业务密钥。
class SecureServerConfigStore implements ServerConfigStore {
  static const storageKey = 'sunmate_private_server_config_v1';
  final FlutterSecureStorage _storage;
  SecureServerConfigStore({FlutterSecureStorage? storage})
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
}

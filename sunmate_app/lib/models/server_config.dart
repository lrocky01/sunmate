/// 私有化服务器直连配置 (MOSS-ASR + Hermes Agent)
class ServerConfig {
  final String asrBaseUrl;
  final String hermesBaseUrl;
  final String asrToken;
  final String hermesToken;
  final bool loaded;
  final String? storageMessage;

  const ServerConfig({
    this.asrBaseUrl = "http://127.0.0.1:8000",
    this.hermesBaseUrl = "http://127.0.0.1:8080/v1",
    this.asrToken = "",
    this.hermesToken = "",
    this.loaded = false,
    this.storageMessage,
  });

  /// 向后兼容全局 token
  String get token => hermesToken.isNotEmpty ? hermesToken : asrToken;

  ServerConfig copyWith({
    String? asrBaseUrl,
    String? hermesBaseUrl,
    String? asrToken,
    String? hermesToken,
    String? token,
    bool? loaded,
    String? storageMessage,
    bool clearStorageMessage = false,
  }) {
    return ServerConfig(
      asrBaseUrl: asrBaseUrl ?? this.asrBaseUrl,
      hermesBaseUrl: hermesBaseUrl ?? this.hermesBaseUrl,
      asrToken: asrToken ?? token ?? this.asrToken,
      hermesToken: hermesToken ?? token ?? this.hermesToken,
      loaded: loaded ?? this.loaded,
      storageMessage:
          clearStorageMessage ? null : storageMessage ?? this.storageMessage,
    );
  }
}

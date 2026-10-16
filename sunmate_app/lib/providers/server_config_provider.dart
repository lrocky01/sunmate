import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ai/agent_client.dart';
import '../core/ai/asr_service.dart';
import '../models/server_config.dart';

class ServerConfigNotifier extends StateNotifier<ServerConfig> {
  ServerConfigNotifier() : super(const ServerConfig());

  void updateConfig({
    String? asrBaseUrl,
    String? hermesBaseUrl,
    String? asrToken,
    String? hermesToken,
    String? token,
  }) {
    state = state.copyWith(
      asrBaseUrl: asrBaseUrl,
      hermesBaseUrl: hermesBaseUrl,
      asrToken: asrToken,
      hermesToken: hermesToken,
      token: token,
    );
  }
}

/// 1. 全局服务器配置 Provider
final serverConfigProvider =
    StateNotifierProvider<ServerConfigNotifier, ServerConfig>((ref) {
  return ServerConfigNotifier();
});

/// 2. 全局 MOSS-ASR 服务 Provider (响应配置动态变更)
final asrServiceProvider = Provider<AsrService>((ref) {
  final config = ref.watch(serverConfigProvider);
  return AsrService(
    serverBaseUrl: config.asrBaseUrl,
    apiKey: config.asrToken.isNotEmpty ? config.asrToken : null,
  );
});

/// 3. 全局 Hermes Agent 客户端 Provider (响应配置动态变更)
final agentClientProvider = Provider<AgentClient>((ref) {
  final config = ref.watch(serverConfigProvider);
  return AgentClient(
    hermesBaseUrl: config.hermesBaseUrl,
    apiKey: config.hermesToken.isNotEmpty ? config.hermesToken : null,
  );
});

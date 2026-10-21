import 'dart:async';
import 'dart:convert';
import '../core/config/server_config_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ai/agent_client.dart';
import '../core/ai/asr_service.dart';
import '../models/server_config.dart';
import 'archive_sync_provider.dart';

class ServerConfigNotifier extends StateNotifier<ServerConfig> {
  final ServerConfigStore _store;
  late final Future<void> ready;
  Future<void> _writes = Future<void>.value();
  bool _readSucceeded = false;
  ServerConfigNotifier({ServerConfigStore? store})
      : _store = store ?? SecureServerConfigStore(),
        super(const ServerConfig()) {
    ready = reload();
  }

  Future<void> reload() {
    final operation = _writes.then((_) async {
      try {
        final text = await _store.read().timeout(const Duration(seconds: 5));
        var config = const ServerConfig();
        if (text != null) {
          if (text.length > 65536) throw const FormatException();
          final data = jsonDecode(text);
          if (data is! Map ||
              data['version'] != 1 ||
              ['asrBaseUrl', 'hermesBaseUrl', 'asrToken', 'hermesToken']
                  .any((key) => data[key] is! String))
            throw const FormatException();
          config = ServerConfig(
              asrBaseUrl: data['asrBaseUrl'],
              hermesBaseUrl: data['hermesBaseUrl'],
              asrToken: data['asrToken'],
              hermesToken: data['hermesToken']);
          _validate(config);
        }
        _readSucceeded = true;
        if (mounted)
          state = config.copyWith(loaded: true, clearStorageMessage: true);
      } catch (_) {
        _readSucceeded = false;
        if (mounted)
          state = state.copyWith(
              loaded: true, storageMessage: '安全保存的节点配置暂时无法读取，请重试恢复；未覆盖已有资料。');
      }
    });
    _writes = operation;
    return operation;
  }

  static void _validate(ServerConfig config) {
    for (final value in [config.asrBaseUrl, config.hermesBaseUrl]) {
      final uri = Uri.tryParse(value);
      if (value.length > 4096 ||
          uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const FormatException('节点地址格式无效。');
      }
    }
    if (config.asrToken.length > 16384 || config.hermesToken.length > 16384) {
      throw const FormatException('访问凭据长度无效。');
    }
  }

  Future<bool> updateConfig(
      {String? asrBaseUrl,
      String? hermesBaseUrl,
      String? asrToken,
      String? hermesToken,
      String? token}) {
    final done = Completer<bool>();
    _writes = _writes.then((_) async {
      await ready;
      if (!mounted || !_readSucceeded) {
        done.complete(false);
        return;
      }
      try {
        final next = state.copyWith(
            asrBaseUrl: asrBaseUrl,
            hermesBaseUrl: hermesBaseUrl,
            asrToken: asrToken,
            hermesToken: hermesToken,
            token: token);
        _validate(next);
        final text = jsonEncode({
          'version': 1,
          'asrBaseUrl': next.asrBaseUrl,
          'hermesBaseUrl': next.hermesBaseUrl,
          'asrToken': next.asrToken,
          'hermesToken': next.hermesToken
        });
        await _store.write(text).timeout(const Duration(seconds: 5));
        if (await _store.read().timeout(const Duration(seconds: 5)) != text) {
          throw const FormatException();
        }
        if (mounted)
          state = next.copyWith(loaded: true, clearStorageMessage: true);
        done.complete(true);
      } catch (_) {
        if (mounted)
          state = state.copyWith(storageMessage: '节点配置保存或校验失败，未确认保存成功。');
        done.complete(false);
      }
    });
    return done.future;
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
  final archive = ref.watch(archiveSyncProvider);
  return AgentClient(
    archiveContext: archive.referenceEnabled
        ? {
            'libraryId': archive.config.identity['libraryId'],
            'profile': archive.config.identity['profile'],
          }
        : null,
    hermesBaseUrl: config.hermesBaseUrl,
    apiKey: config.hermesToken.isNotEmpty ? config.hermesToken : null,
  );
});

import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/config/server_config_store.dart';
import 'package:sunmate_app/providers/server_config_provider.dart';

class ConfigMemoryStore implements ServerConfigStore {
  String? value;
  bool failRead = false, failWrite = false, mismatch = false;
  int writes = 0;
  Completer<void>? gate;
  @override
  Future<String?> read() async {
    if (failRead) throw StateError('synthetic-private-detail');
    return value;
  }

  @override
  Future<void> write(String next) async {
    writes++;
    if (failWrite) throw StateError('synthetic-private-detail');
    if (gate != null) await gate!.future;
    value = mismatch ? '{}' : next;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'first launch does not write defaults; new notifier restores four saved fields',
      () async {
    final store = ConfigMemoryStore();
    final first = ServerConfigNotifier(store: store);
    await first.ready;
    expect(first.state.loaded, true);
    expect(store.writes, 0);
    expect(
        await first.updateConfig(
            asrBaseUrl: 'http://192.0.2.20:8000',
            hermesBaseUrl: 'https://example.invalid/p/voice/v1',
            asrToken: 'synthetic-asr',
            hermesToken: 'synthetic-hermes'),
        true);
    first.dispose();
    final second = ServerConfigNotifier(store: store);
    await second.ready;
    expect(second.state.asrBaseUrl, 'http://192.0.2.20:8000');
    expect(second.state.hermesBaseUrl, 'https://example.invalid/p/voice/v1');
    expect(second.state.asrToken, 'synthetic-asr');
    expect(second.state.hermesToken, 'synthetic-hermes');
    second.dispose();
  });
  test('secure namespace does not modify unrelated mock credentials', () async {
    FlutterSecureStorage.setMockInitialValues(
        {'unrelated_mock_card': 'synthetic-only'});
    final store = SecureServerConfigStore();
    await store.write('synthetic-config');
    expect(await store.read(), 'synthetic-config');
    expect(await const FlutterSecureStorage().read(key: 'unrelated_mock_card'),
        'synthetic-only');
  });
  for (final broken in [
    'invalid-json',
    '{"version":2}',
    '{"version":1,"asrToken":42}'
  ]) {
    test('corrupt stored profile is preserved: $broken', () async {
      final store = ConfigMemoryStore()..value = broken;
      final notifier = ServerConfigNotifier(store: store);
      await notifier.ready;
      expect(await notifier.updateConfig(asrToken: 'replacement'), false);
      expect(store.writes, 0);
      expect(store.value, broken);
      expect(notifier.state.storageMessage, isNotNull);
      notifier.dispose();
    });
  }
  test(
      'read failure blocks overwrite and explicit retry restores saved profile',
      () async {
    final store = ConfigMemoryStore()..failRead = true;
    final notifier = ServerConfigNotifier(store: store);
    await notifier.ready;
    expect(await notifier.updateConfig(hermesToken: 'test'), false);
    expect(notifier.state.storageMessage,
        isNot(contains('synthetic-private-detail')));
    store.failRead = false;
    await notifier.reload();
    expect(await notifier.updateConfig(asrToken: 'test'), true);
    notifier.dispose();
  });
  for (final mismatch in [false, true]) {
    test('failed write or readback never reports saved ($mismatch)', () async {
      final store = ConfigMemoryStore()
        ..failWrite = !mismatch
        ..mismatch = mismatch;
      final notifier = ServerConfigNotifier(store: store);
      await notifier.ready;
      expect(await notifier.updateConfig(asrToken: 'synthetic-new'), false);
      expect(notifier.state.asrToken, '');
      expect(notifier.state.storageMessage, isNotNull);
      notifier.dispose();
    });
  }
  test('concurrent partial saves and reload serialize without losing fields',
      () async {
    final store = ConfigMemoryStore()..gate = Completer<void>();
    final notifier = ServerConfigNotifier(store: store);
    await notifier.ready;
    final a = notifier.updateConfig(asrToken: 'one');
    final b = notifier.updateConfig(hermesToken: 'two');
    final reload = notifier.reload();
    store.gate!.complete();
    expect(await a, true);
    expect(await b, true);
    await reload;
    expect(notifier.state.asrToken, 'one');
    expect(notifier.state.hermesToken, 'two');
    expect(jsonDecode(store.value!)['hermesToken'], 'two');
    notifier.dispose();
  });
  test('invalid credential-bearing URL never reaches persistence', () async {
    final store = ConfigMemoryStore();
    final notifier = ServerConfigNotifier(store: store);
    await notifier.ready;
    for (final url in [
      'https://user:pass@example.invalid',
      'file:///tmp',
      'http://example.invalid?token=fake'
    ]) {
      expect(await notifier.updateConfig(hermesBaseUrl: url), false);
    }
    expect(store.writes, 0);
    notifier.dispose();
  });
}

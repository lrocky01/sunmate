import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ble/ble_protocol.dart';
import 'package:sunmate_app/core/ble/recorder_credential_vault.dart';
import 'package:sunmate_app/core/ble/recorder_portable_backup.dart';
import 'package:sunmate_app/core/ble/recorder_saved_identity.dart';
import 'recorder_portable_backup_test.dart' show material, identity, sn;
import 'recorder_recovery_test.dart' show DeviceKeyStore;
import 'recorder_authentication_test.dart' show shared;

class FaultCredentialStorage extends FlutterSecureStorage {
  void Function(String, String?)? beforeWrite, afterWrite;
  bool mismatchNextSlotRead = false;
  @override
  Future<void> write(
      {required String key,
      required String? value,
      IOSOptions? iOptions,
      AndroidOptions? aOptions,
      LinuxOptions? lOptions,
      WebOptions? webOptions,
      MacOsOptions? mOptions,
      WindowsOptions? wOptions}) async {
    beforeWrite?.call(key, value);
    await super.write(
        key: key,
        value: value,
        iOptions: iOptions,
        aOptions: aOptions,
        lOptions: lOptions,
        webOptions: webOptions,
        mOptions: mOptions,
        wOptions: wOptions);
    afterWrite?.call(key, value);
  }

  @override
  Future<String?> read(
      {required String key,
      IOSOptions? iOptions,
      AndroidOptions? aOptions,
      LinuxOptions? lOptions,
      WebOptions? webOptions,
      MacOsOptions? mOptions,
      WindowsOptions? wOptions}) async {
    if (mismatchNextSlotRead &&
        key.startsWith('sunmate_credential_versions_')) {
      mismatchNextSlotRead = false;
      return 'synthetic-readback-mismatch';
    }
    return super.read(
        key: key,
        iOptions: iOptions,
        aOptions: aOptions,
        lOptions: lOptions,
        webOptions: webOptions,
        mOptions: mOptions,
        wOptions: wOptions);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const protocol = RecorderProtocol.telink;
  const id = 'test-phone';
  final old = base64Encode(shared), next = base64Encode(List.filled(32, 8));
  const storage = FlutterSecureStorage();
  late DeviceKeyStore legacy;
  late RecorderCredentialVault vault;
  RecorderSavedIdentity selected() => identity(id: id);
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    legacy = DeviceKeyStore();
    legacy.values[legacy.entry(id, protocol)] = old;
    vault = RecorderCredentialVault(legacy: legacy);
  });
  test('prepare archives old value but leaves active and legacy unchanged',
      () async {
    final token = await vault.prepare(selected(), next, source: '官方账号资料');
    expect(await vault.read(id, protocol), old);
    expect(legacy.values[legacy.entry(id, protocol)], old);
    expect(legacy.writes, 0);
    final history = await vault.history();
    expect(history, hasLength(2));
    expect(history.where((v) => v.active).single.source, '旧本机凭据');
    expect(history.every((v) => !v.verified), true);
    expect(token.toString(), isNot(contains(next)));
    expect(history.toString(), isNot(contains(next)));
    await expectLater(vault.write(id, protocol, next), throwsStateError);
  });
  test(
      'verified selection changes reference, survives restart, and restores old version',
      () async {
    final token = await vault.prepare(selected(), next, source: '官方账号资料');
    await vault.activateVerified(token, ensureCurrent: () {});
    final reopened = RecorderCredentialVault(legacy: legacy);
    expect(await reopened.read(id, protocol), next);
    expect(legacy.values[legacy.entry(id, protocol)], old);
    final previous = (await reopened.history()).singleWhere((v) => !v.active);
    final candidate = RecorderCandidateKeyStore(id, protocol);
    await reopened.loadArchived(previous, candidate);
    final restore = await reopened.prepare(
        selected(), (await candidate.read(id, protocol))!,
        source: '历史凭据');
    await reopened.activateVerified(restore, ensureCurrent: () {});
    expect(await reopened.read(id, protocol), old);
    expect((await reopened.history()).where((v) => v.active).single.verified,
        true);
    candidate.close();
  });
  for (final cancelAt in [4, 5]) {
    test(
        'cancel at commit boundary $cancelAt restores old reference and leaves archive',
        () async {
      final token = await vault.prepare(selected(), next, source: '官方账号资料');
      var checks = 0;
      await expectLater(
          vault.activateVerified(token, ensureCurrent: () {
            if (++checks == cancelAt)
              throw StateError('synthetic cancellation');
          }),
          throwsStateError);
      expect(await RecorderCredentialVault(legacy: legacy).read(id, protocol),
          old);
      expect((await vault.history()).where((v) => v.active).single.source,
          '旧本机凭据');
      expect(
          (await storage.readAll())
              .keys
              .any((k) => k.startsWith('sunmate_credential_switch_')),
          false);
    });
  }
  for (final failure in ['write-ack', 'readback', 'rollback']) {
    test('storage $failure failure retains rollback proof and old credential',
        () async {
      final faults = FaultCredentialStorage();
      final controlled =
          RecorderCredentialVault(legacy: legacy, storage: faults);
      final token =
          await controlled.prepare(selected(), next, source: '官方账号资料');
      var phase = 0;
      faults.beforeWrite = (key, value) {
        if (failure == 'rollback' &&
            phase == 1 &&
            key.startsWith('sunmate_credential_versions_')) {
          phase = 2;
          throw StateError('synthetic rollback write failure');
        }
      };
      faults.afterWrite = (key, value) {
        if (phase == 0 && key.startsWith('sunmate_credential_versions_')) {
          phase = 1;
          if (failure == 'readback') {
            faults.mismatchNextSlotRead = true;
          } else {
            throw StateError('synthetic write acknowledgement failure');
          }
        }
      };
      await expectLater(
          controlled.activateVerified(token, ensureCurrent: () {}),
          throwsStateError);
      final reopened = RecorderCredentialVault(legacy: legacy, storage: faults);
      expect(await reopened.read(id, protocol), old);
      expect(legacy.values[legacy.entry(id, protocol)], old);
      expect((await reopened.history()).where((v) => v.active).single.source,
          '旧本机凭据');
    });
  }
  test('stale concurrent candidate cannot commit or replace old value',
      () async {
    final stale = await vault.prepare(selected(), next, source: '官方账号资料');
    await vault.prepare(selected(), base64Encode(List.filled(32, 9)),
        source: '官方账号资料');
    await expectLater(
        vault.activateVerified(stale, ensureCurrent: () {}), throwsStateError);
    expect(await vault.read(id, protocol), old);
  });
  test('restart rolls back interrupted journal before exposing active value',
      () async {
    await vault.prepare(selected(), next, source: '官方账号资料');
    final entries = await storage.readAll();
    final slot = entries.keys
        .singleWhere((k) => k.startsWith('sunmate_credential_versions_v1_'));
    final before = entries[slot]!;
    final m = jsonDecode(before) as Map;
    m['active'] = (m['entries'] as List).last['id'];
    await storage.write(key: slot, value: jsonEncode(m));
    await storage.write(
        key: slot.replaceFirst(
            'sunmate_credential_versions_v1_', 'sunmate_credential_switch_v1_'),
        value: before);
    expect(
        await RecorderCredentialVault(legacy: legacy).read(id, protocol), old);
    expect((await storage.readAll())[slot], before);
  });
  test('same key is deduplicated and wrong SN/corrupt records fail closed',
      () async {
    await vault.prepare(selected(), next, source: '官方账号资料');
    await vault.prepare(selected(), next, source: '官方账号资料');
    expect(await vault.history(), hasLength(2));
    final wrong = RecorderSavedIdentity(
        remoteId: id,
        serialNumber: 'AB00000000000002',
        deviceName: 'Other',
        protocol: protocol);
    await expectLater(
        vault.prepare(wrong, next, source: '官方账号资料'), throwsStateError);
    final entries = await storage.readAll();
    final slot = entries.keys
        .singleWhere((k) => k.startsWith('sunmate_credential_versions_v1_'));
    await storage.write(key: slot, value: 'invalid');
    await expectLater(vault.read(id, protocol), throwsStateError);
    expect(legacy.values[legacy.entry(id, protocol)], old);
  });
  test('isolated candidate is bound to UUID/protocol, single-write, closes',
      () async {
    final candidate = RecorderCandidateKeyStore(id, protocol);
    await expectLater(
        candidate.write('wrong', protocol, next), throwsStateError);
    await candidate.write(id, protocol, next);
    await expectLater(candidate.write(id, protocol, old), throwsStateError);
    expect(await vault.read(id, protocol), old);
    candidate.close();
    await expectLater(candidate.read(id, protocol), throwsStateError);
  });
  test(
      'remove only selected imported record; active key, route and other imports survive',
      () async {
    final imported = RecorderPortableStore();
    final source = material(), other = material(serial: 'AB00000000000002');
    await imported.save(source);
    await imported.save(other);
    await imported.remove(source);
    final remaining = await imported.readAll();
    expect(remaining.single.serialNumber, 'AB00000000000002');
    expect(await vault.read(id, protocol), old);
    expect(legacy.writes, 0);
    for (final m in remaining) {
      m.clear();
    }
    source.clear();
    other.clear();
  });
  test('remove rejects changed snapshot and cannot erase newer source',
      () async {
    final imported = RecorderPortableStore();
    final source = material(), changed = material(key: List.filled(32, 4));
    await imported.save(source);
    await expectLater(imported.remove(changed), throwsStateError);
    final remaining = await imported.readAll();
    expect(remaining.single.serialNumber, sn);
    for (final m in remaining) {
      m.clear();
    }
    source.clear();
    changed.clear();
  });
}

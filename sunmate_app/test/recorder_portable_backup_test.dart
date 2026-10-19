import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/ble_protocol.dart';
import 'package:sunmate_app/core/ble/recorder_portable_backup.dart';
import 'package:sunmate_app/core/ble/recorder_saved_identity.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_recovery_test.dart' show DeviceKeyStore;
import 'recorder_authentication_test.dart' show shared;

// 公开RFC向量及合成身份，绝非真实卡片凭据。
const sn = 'AB00000000000001';
const password = 'synthetic-backup-password';
PortableRecorderMaterial material({List<int>? key, String serial = sn}) =>
    PortableRecorderMaterial.fromJson({
      'version': 1,
      'sn': serial,
      'name': 'Test recorder',
      'protocol': 'telink',
      'secret': base64Encode(key ?? shared)
    });
RecorderSavedIdentity identity(
        {String id = 'old-phone', bool verified = true}) =>
    RecorderSavedIdentity(
        remoteId: id,
        serialNumber: sn,
        deviceName: 'Test recorder',
        protocol: RecorderProtocol.telink,
        previouslyVerified: verified);
Map<int, List<int>> advertisement([String serial = sn]) => {
      0x1c0d: [1, 0xff, 0x1d, 0x2c, ...ascii.encode(serial)]
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final codec = RecorderBackupCodec();
  late Uint8List encrypted;
  setUpAll(() async {
    final source = material();
    try {
      encrypted = await codec.encrypt(source, password);
    } finally {
      source.clear();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
      'production encrypted envelope round trip, private fields concealed and random salt/nonce',
      () async {
    final source = material();
    final second = await codec.encrypt(source, password);
    source.clear();
    final a = jsonDecode(utf8.decode(encrypted));
    final b = jsonDecode(utf8.decode(second));
    expect(a['iterations'], 600000);
    expect(a['cipher'], 'AES-256-GCM');
    expect(a['salt'], isNot(b['salt']));
    expect(a['nonce'], isNot(b['nonce']));
    final text = utf8.decode(encrypted);
    for (final private in [
      sn,
      password,
      base64Encode(shared),
      'old-phone',
      'Test recorder'
    ]) {
      expect(text, isNot(contains(private)));
    }
    final restored = await codec.decrypt(encrypted, password);
    expect(restored.serialNumber, sn);
    expect(restored.toString(), isNot(contains(base64Encode(shared))));
    restored.clear();
  });

  test(
      'wrong password and authenticated ciphertext/tag/salt/nonce tampering fail closed',
      () async {
    await expectLater(codec.decrypt(encrypted, 'another-test-password'),
        throwsFormatException);
    for (final field in ['ciphertext', 'tag', 'salt', 'nonce']) {
      final value = jsonDecode(utf8.decode(encrypted));
      final bytes = base64Decode(value[field]);
      bytes[0] ^= 1;
      value[field] = base64Encode(bytes);
      await expectLater(
          codec.decrypt(
              Uint8List.fromList(utf8.encode(jsonEncode(value))), password),
          throwsFormatException);
    }
  });

  test('format, KDF resource limits and password validation are enforced',
      () async {
    for (final field in ['version', 'iterations', 'cipher', 'format', 'kdf']) {
      final value = jsonDecode(utf8.decode(encrypted));
      value[field] = field == 'iterations' ? 999999999999 : 'unsupported';
      await expectLater(
          codec.decrypt(
              Uint8List.fromList(utf8.encode(jsonEncode(value))), password),
          throwsFormatException);
    }
    for (final bytes in [
      Uint8List(0),
      Uint8List(16385),
      Uint8List.fromList([255])
    ]) {
      await expectLater(codec.decrypt(bytes, password), throwsFormatException);
    }
    expect(() => RecorderBackupCodec.validatePassword('short'),
        throwsFormatException);
    expect(() => RecorderBackupCodec.validatePassword(' ' * 12),
        throwsFormatException);
    expect(() => PortableRecorderMaterial.fromJson({'version': 1}),
        throwsFormatException);
  });

  test(
      'import is persisted only as pending material, does not create active key or verified route',
      () async {
    final keys = DeviceKeyStore();
    final service = RecorderBackupService(keys: keys);
    final imported = await codec.decrypt(encrypted, password);
    await service.acceptImport(imported);
    imported.clear();
    expect(keys.writes, 0);
    expect(await service.identities.readAll(), isEmpty);
    expect(await service.exportable(), isEmpty);
    final persisted = await RecorderPortableStore().readAll();
    expect(persisted.single.serialNumber, sn);
    persisted.single.clear();
  });

  test(
      'import preserves different existing SN keys and independent imported backups',
      () async {
    final keys = DeviceKeyStore();
    final service = RecorderBackupService(keys: keys);
    final original = material();
    final different = material(key: List.generate(32, (i) => i + 1));
    await service.acceptImport(original);
    await expectLater(service.acceptImport(different), throwsStateError);
    await service.identities.save(identity());
    keys.values[keys.entry('old-phone', RecorderProtocol.telink)] =
        base64Encode(shared);
    await expectLater(service.acceptImport(different), throwsStateError);
    expect(keys.writes, 0);
    final persisted = await service.imported.readAll();
    final scan = RecorderScanIdentity.fromAdvertisement(
        remoteId: 'new-phone',
        deviceName: 'Test recorder',
        manufacturerData: advertisement(),
        connectable: true,
        observedAt: DateTime.now())!;
    final session = service.offlineSession(persisted.single, scan);
    expect(
        await session.restoreKey!(
            'new-phone', RecorderProtocol.telink, sn, keys),
        true);
    expect(await keys.read('new-phone', RecorderProtocol.telink),
        base64Encode(shared));
    for (final p in persisted) {
      p.clear();
    }
    original.clear();
    different.clear();
  });

  test('only previously AES verified routes can be exported', () async {
    final keys = DeviceKeyStore();
    final service = RecorderBackupService(keys: keys);
    await service.identities.save(identity(verified: false));
    keys.values[keys.entry('old-phone', RecorderProtocol.telink)] =
        base64Encode(shared);
    await expectLater(service.export(identity(), password), throwsStateError);
    expect(await service.exportable(), isEmpty);
    await service.identities.save(identity());
    final bytes = await service.export(identity(), password);
    final recovered = await codec.decrypt(bytes, password);
    expect(recovered.serialNumber, sn);
    recovered.clear();
  });

  group('offline imported material through real driver state machine', () {
    final platform = TestBlePlatform();
    late DeviceKeyStore keys;
    late AiNote6095Driver driver;
    late PortableRecorderMaterial imported;
    late RecorderBackupService service;
    late BluetoothDevice device;
    var counter = 0;
    setUpAll(() {
      FlutterBluePlusPlatform.instance = platform;
    });
    setUp(() {
      platform.reset();
      keys = DeviceKeyStore();
      driver = AiNote6095Driver(
          keyStore: keys,
          authenticationTimeout: const Duration(milliseconds: 300));
      imported = material();
      service = RecorderBackupService(keys: keys);
      device = BluetoothDevice.fromId(
          '20000000-0000-0000-0000-${(++counter).toString().padLeft(12, '0')}');
    });
    tearDown(() async {
      await driver.dispose();
      await FlutterBluePlus.stopScan();
      imported.clear();
    });
    Future<RecorderScanIdentity> scan() async {
      await platform.advertise(device.remoteId, advertisement());
      return RecorderScanIdentity.fromAdvertisement(
          remoteId: device.remoteId.str,
          deviceName: 'Test recorder',
          manufacturerData: advertisement(),
          connectable: true,
          observedAt: DateTime.now())!;
    }

    List<String> methods() => platform.writes
        .where((w) => w.value.length > 2 && w.value[1] == 0x30)
        .map((w) =>
            jsonDecode(utf8.decode(w.value.sublist(2)))['method'] as String)
        .toList();

    test(
        'new phone UUID restores without account/network and still requires successful AES',
        () async {
      platform.authenticate = true;
      platform.identityOnSubscribe = true;
      final session = service.offlineSession(imported, await scan());
      expect(await driver.connectDevice(device, accountSession: session), true);
      expect(driver.isConnected, true);
      expect(methods(), contains('verifyIdentity'));
      expect(methods(), isNot(contains('bindRequest')));
      expect(methods(), isNot(contains('verifyResult')));
      expect((await service.identities.readAll()).single.remoteId,
          device.remoteId.str);
      expect(
          (await service.identities.readAll()).single.previouslyVerified, true);
      expect(driver.diagnosticText, isNot(contains(base64Encode(shared))));
      expect(await driver.hasAutomaticReconnectMaterial(), true);
    });

    test(
        'device rejects stale key: not ready, pending route only, no new pairing',
        () async {
      platform.replyMethod = 'verifyIdentityResult';
      platform.replySuccess = false;
      platform.identityOnSubscribe = true;
      final session = service.offlineSession(imported, await scan());
      expect(
          await driver.connectDevice(device, accountSession: session), false);
      expect(driver.isConnected, false);
      expect((await service.identities.readAll()).single.previouslyVerified,
          false);
      expect(await service.exportable(), isEmpty);
      expect(await driver.hasAutomaticReconnectMaterial(), false);
      expect(methods(), isNot(contains('bindRequest')));
    });

    test('different target UUID key is not overwritten or used for a response',
        () async {
      final old = base64Encode(List.generate(32, (i) => i + 1));
      keys.values[keys.entry(device.remoteId.str, RecorderProtocol.telink)] =
          old;
      final session = service.offlineSession(imported, await scan());
      expect(
          await driver.connectDevice(device, accountSession: session), false);
      expect(
          await keys.read(device.remoteId.str, RecorderProtocol.telink), old);
      expect(keys.writes, 0);
      expect(methods(), isEmpty);
    });

    test(
        'wrong SN, wrong UUID, stale scan and GATT mismatch fail before consuming imported key',
        () async {
      final wrong = RecorderScanIdentity.fromAdvertisement(
          remoteId: device.remoteId.str,
          deviceName: 'Other recorder',
          manufacturerData: advertisement('AB00000000000002'),
          connectable: true,
          observedAt: DateTime.now())!;
      expect(() => service.offlineSession(imported, wrong), throwsStateError);
      final snapshot = await scan();
      final session = service.offlineSession(imported, snapshot);
      await expectLater(
          session.restoreKey!('wrong-id', RecorderProtocol.telink, sn, keys),
          throwsStateError);
      await expectLater(
          session.restoreKey!(
              device.remoteId.str, RecorderProtocol.aiNote6095, sn, keys),
          throwsStateError);
      platform.otaOnly = true;
      expect(
          await driver.connectDevice(device, accountSession: session), false);
      expect(keys.writes, 0);
      expect(methods(), isEmpty);
      expect(
          RecorderScanIdentity.fromAdvertisement(
              remoteId: device.remoteId.str,
              deviceName: 'Test',
              manufacturerData: advertisement(),
              connectable: true,
              observedAt: DateTime.now().subtract(const Duration(seconds: 31))),
          isNull);
    });

    test(
        'manufacturer request during offline restore cannot invoke cloud or replace key',
        () async {
      platform.manufacturerOnSubscribe = true;
      final session = service.offlineSession(imported, await scan());
      expect(
          await driver.connectDevice(device, accountSession: session), false);
      expect(methods(), isNot(contains('verifyResult')));
      expect(methods(), isNot(contains('bindRequest')));
      expect(await keys.read(device.remoteId.str, RecorderProtocol.telink),
          base64Encode(shared));
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/ble_protocol.dart';
import 'package:sunmate_app/core/ble/recorder_authentication.dart';
import 'package:sunmate_app/core/ble/recorder_saved_identity.dart';
import 'package:sunmate_app/core/ble/yoooclaw_account.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_authentication_test.dart' show shared;
import 'yoooclaw_account_test.dart'
    show AccountHttpAdapter, MemoryOfficialSessionStore, record, response;

class DeviceKeyStore implements RecorderKeyStore {
  final values = <String, String>{};
  int writes = 0;
  Completer<void>? readGate;
  String entry(String id, RecorderProtocol p) =>
      '${id.toLowerCase()}/${p.name}';
  @override
  Future<String?> read(String id, RecorderProtocol p) async {
    if (readGate != null) await readGate!.future;
    return values[entry(id, p)];
  }

  @override
  Future<void> write(String id, RecorderProtocol p, String key) async {
    values[entry(id, p)] = key;
    writes++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = TestBlePlatform();
  late AiNote6095Driver driver;
  late DeviceKeyStore keys;
  late BluetoothDevice device;
  var number = 0;
  List<BluetoothDevice> system = [];
  setUpAll(() => FlutterBluePlusPlatform.instance = platform);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    platform.reset();
    keys = DeviceKeyStore();
    device = BluetoothDevice.fromId(
        '10000000-0000-0000-0000-${(++number).toString().padLeft(12, '0')}');
    system = [device];
    driver = AiNote6095Driver(
        keyStore: keys,
        systemDevices: () async => system,
        authenticationTimeout: const Duration(milliseconds: 150));
  });
  tearDown(() async {
    await driver.dispose();
    await FlutterBluePlus.stopScan();
  });

  RecorderSavedIdentity identity(
          {String? id,
          String sn = 'AB00000000000001',
          RecorderProtocol protocol = RecorderProtocol.telink,
          bool verified = false}) =>
      RecorderSavedIdentity(
          remoteId: id ?? device.remoteId.str,
          serialNumber: sn,
          deviceName: 'Test recorder',
          protocol: protocol,
          previouslyVerified: verified);

  void seed(
      {String? id,
      String? key,
      RecorderProtocol protocol = RecorderProtocol.telink}) {
    keys.values[keys.entry(id ?? device.remoteId.str, protocol)] =
        key ?? base64Encode(shared);
  }

  Future<YoooClawAccount> account({String? secret}) async {
    final adapter = AccountHttpAdapter();
    adapter.respond = (r) => r.path.endsWith('/loginOrRegister')
        ? response({
            'code': '000000',
            'data': {'jwtToken': 'test-only-session', 'id': '123'}
          })
        : response({
            'code': '000000',
            'data': {
              'deviceList': [record(secret: secret)]
            }
          });
    final client = YoooClawAccount(
        http: Dio()..httpClientAdapter = adapter,
        sessionStore: MemoryOfficialSessionStore());
    addTearDown(client.close);
    await client.login('13800000000', '1234');
    await client.loadBindings();
    return client;
  }

  test(
      'route metadata survives reopening but never contains a key or grants readiness',
      () async {
    seed();
    await RecorderIdentityStore().save(identity());
    final reopened = RecorderIdentityStore();
    expect((await reopened.readAll()).single.previouslyVerified, false);
    final routes = await driver.recoveryCandidates(includeSystemDevices: false);
    expect(routes.single.identity.remoteId, device.remoteId.str);
    expect(routes.single.systemConnected, false);
    expect(driver.hasVerifiedDevice, false);
    expect(driver.isConnected, false);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(RecorderIdentityStore.storageKey).toString(),
        isNot(contains(base64Encode(shared))));
    expect(keys.writes, 0);
  });

  test('pending metadata without local key is not offered for recovery',
      () async {
    await RecorderIdentityStore().save(identity());
    expect(await driver.recoveryCandidates(), isEmpty);
    expect(keys.writes, 0);
  });

  test(
      'legacy system-connected card matches selected account and local key without advertisement',
      () async {
    seed();
    final client = await account();
    final session = client.sessionForDevice(client.devices.single);
    final routes = await driver.recoveryCandidates(accountSession: session);
    expect(routes, hasLength(1));
    expect(routes.single.systemConnected, true);
    expect(routes.single.identity.serialNumber,
        client.devices.single.serialNumber);
    expect(await RecorderIdentityStore().readAll(),
        isEmpty); // Listing is read-only.
    expect(driver.isConnected, false);
    expect(platform.connectCount, 0);
    platform.authenticate = true;
    expect(
        await driver.connectDevice(device,
            accountSession: session, recoveryCandidate: routes.single),
        true);
    expect(driver.isConnected, true);
    expect(driver.snNumber, 'AB00000000000001');
    expect(keys.writes, 0);
    await Future<void>.delayed(
        Duration.zero); // Verified route persistence is asynchronous.
    expect((await RecorderIdentityStore().readAll()).single.previouslyVerified,
        true);
    final methods = platform.writes
        .where((w) => w.value.length > 2 && w.value[1] == 0x30)
        .map((w) => jsonDecode(utf8.decode(w.value.sublist(2)))['method'])
        .toList();
    expect(methods, contains('verifyIdentity'));
    expect(methods, isNot(contains('bindRequest')));
    expect(methods, isNot(contains('verifyResult')));
    expect(methods, isNot(contains('unbindRequest')));
    expect(driver.diagnosticText, isNot(contains(base64Encode(shared))));
  });

  test(
      'real system-device API uses a limited service list and returns no fake advertisement',
      () async {
    await driver.dispose();
    driver = AiNote6095Driver(keyStore: keys);
    seed();
    platform.systemDevices = [
      BmBluetoothDevice(
          remoteId: device.remoteId, platformName: 'Test recorder')
    ];
    final client = await account();
    final routes = await driver.recoveryCandidates(
        accountSession: client.sessionForDevice(client.devices.single));
    expect(routes, hasLength(1));
    expect(routes.single.systemConnected, true);
    expect(
        platform.systemLookup!.withServices.map((s) => s.str),
        containsAll([
          '1812',
          '00010203-0405-0607-0809-0a0b0c0d1930',
          'e2c1a300-7f4b-5e9d-bc23-1a2f3e4d5c6b'
        ]));
    expect(platform.connectCount, 0);
    expect(keys.writes, 0);
  });

  for (final scenario in [
    'no local key',
    'different key',
    'unsupported protocol'
  ]) {
    test('legacy lookup rejects $scenario without writing or connecting',
        () async {
      if (scenario != 'no local key')
        seed(
            key: scenario == 'different key'
                ? base64Encode(List.filled(32, 7))
                : null,
            protocol: scenario == 'unsupported protocol'
                ? RecorderProtocol.aiNote6095
                : RecorderProtocol.telink);
      final client = await account();
      final routes = await driver.recoveryCandidates(
          accountSession: client.sessionForDevice(client.devices.single));
      expect(routes, isEmpty);
      expect(keys.writes, 0);
      expect(platform.connectCount, 0);
      expect(platform.writes, isEmpty);
    });
  }

  test('same SN matching multiple system devices is ambiguous', () async {
    final other =
        BluetoothDevice.fromId('20000000-0000-0000-0000-000000000001');
    seed();
    seed(id: other.remoteId.str);
    system = [device, other];
    final client = await account();
    await expectLater(
        driver.recoveryCandidates(
            accountSession: client.sessionForDevice(client.devices.single)),
        throwsStateError);
    expect(platform.connectCount, 0);
    expect(await RecorderIdentityStore().readAll(), isEmpty);
  });

  test(
      'saved route with different account key stops without replacing either key',
      () async {
    seed();
    await RecorderIdentityStore().save(identity());
    final client = await account(secret: base64Encode(List.filled(32, 9)));
    await expectLater(
        driver.recoveryCandidates(
            accountSession: client.sessionForDevice(client.devices.single)),
        throwsStateError);
    expect(keys.values.values.single, base64Encode(shared));
    expect(keys.writes, 0);
  });

  for (final scenario in [
    'no challenge',
    'bad AES',
    'unsolicited success',
    'wrong GATT',
    'wrong SN'
  ]) {
    test('recoverable candidate cannot become ready on $scenario', () async {
      seed(
          key: scenario == 'bad AES' ? base64Encode(List.filled(32, 4)) : null);
      await RecorderIdentityStore().save(identity());
      final route = (await driver.recoveryCandidates()).single;
      platform.authenticate = ['bad AES', 'wrong SN'].contains(scenario);
      if (scenario == 'no challenge') platform.replyMethod = 'reportStatus';
      if (scenario == 'unsolicited success') {
        platform.replyMethod = 'verifyIdentityResult';
        platform.replySuccess = true;
      }
      if (scenario == 'wrong GATT') platform.otaOnly = true;
      if (scenario == 'wrong SN') platform.reportedSn = 'AB00000000000002';
      expect(
          await driver.connectDevice(device, recoveryCandidate: route), false);
      expect(driver.isConnected, false);
      expect(driver.hasVerifiedDevice, false);
      expect(keys.writes, 0);
      expect(
          (await RecorderIdentityStore().readAll()).single.previouslyVerified,
          false);
    });
  }

  test(
      'candidate key is rechecked when user clicks after account logout or key change',
      () async {
    seed();
    final client = await account();
    final session = client.sessionForDevice(client.devices.single);
    final route =
        (await driver.recoveryCandidates(accountSession: session)).single;
    await client.logout();
    expect(
        await driver.connectDevice(device,
            accountSession: session, recoveryCandidate: route),
        false);
    expect(platform.connectCount, 0);
    expect(platform.writes, isEmpty);
    expect(keys.writes, 0);
  });

  test('candidate UUID cannot be substituted after listing', () async {
    seed();
    await RecorderIdentityStore().save(identity());
    final route = (await driver.recoveryCandidates()).single;
    expect(
        await driver.connectDevice(BluetoothDevice.fromId('different-device'),
            recoveryCandidate: route),
        false);
    expect(platform.connectCount, 0);
    expect(keys.writes, 0);
  });

  test('a changed local key after listing cannot bypass the account comparison',
      () async {
    seed();
    final client = await account();
    final session = client.sessionForDevice(client.devices.single);
    final route =
        (await driver.recoveryCandidates(accountSession: session)).single;
    seed(key: base64Encode(List.filled(32, 5)));
    expect(
        await driver.connectDevice(device,
            recoveryCandidate: route, accountSession: session),
        false);
    expect(platform.connectCount, 0);
    expect(platform.writes, isEmpty);
    expect(keys.writes, 0);
  });

  test('saved identity protocol must agree with actual GATT before any command',
      () async {
    seed(protocol: RecorderProtocol.aiNote6095);
    await RecorderIdentityStore()
        .save(identity(protocol: RecorderProtocol.aiNote6095));
    final route = (await driver.recoveryCandidates()).single;
    expect(await driver.connectDevice(device, recoveryCandidate: route), false);
    expect(platform.writes, isEmpty);
    expect(keys.writes, 0);
    expect(driver.lastErrorMessage, contains('GATT'));
  });

  test('cancel while checking a saved identity cannot start a late connection',
      () async {
    seed();
    await RecorderIdentityStore().save(identity());
    final route = (await driver.recoveryCandidates()).single;
    final gate = Completer<void>();
    keys.readGate = gate;
    final connecting = driver.connectDevice(device, recoveryCandidate: route);
    await Future<void>.delayed(Duration.zero);
    await driver.disconnect();
    expect(await connecting, false);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(platform.connectCount, 0);
    expect(platform.writes, isEmpty);
    expect(driver.isConnected, false);
    expect(keys.writes, 0);
  });

  test('account change during asynchronous system lookup invalidates result',
      () async {
    await driver.dispose();
    final gate = Completer<List<BluetoothDevice>>();
    final entered = Completer<void>();
    driver = AiNote6095Driver(
        keyStore: keys,
        systemDevices: () {
          entered.complete();
          return gate.future;
        });
    seed();
    final client = await account();
    final result = driver.recoveryCandidates(
        accountSession: client.sessionForDevice(client.devices.single));
    final checked =
        expectLater(result, throwsA(isA<OfficialAccountException>()));
    await entered.future;
    await client.logout();
    gate.complete([device]);
    await checked;
    expect(platform.connectCount, 0);
  });

  test(
      'route store refuses conflicting UUID/SN and malformed records without deleting keys',
      () async {
    final store = RecorderIdentityStore();
    await store.save(identity());
    await expectLater(
        store.save(identity(sn: 'AB00000000000002')), throwsStateError);
    expect((await store.readAll()).single.serialNumber, 'AB00000000000001');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(RecorderIdentityStore.storageKey, ['not json']);
    await expectLater(store.readAll(), throwsFormatException);
    expect(keys.writes, 0);
  });
}

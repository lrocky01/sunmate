import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/ble_protocol.dart';
import 'package:sunmate_app/core/ble/ble_constants.dart';
import 'package:sunmate_app/core/ble/recorder_credential_vault.dart';
import 'package:sunmate_app/core/ble/recorder_authentication.dart';
import 'package:sunmate_app/core/ble/recorder_saved_identity.dart';
import 'package:sunmate_app/core/ble/yoooclaw_account.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_recovery_test.dart' show DeviceKeyStore;
import 'recorder_authentication_test.dart' show shared;
import 'recorder_portable_backup_test.dart' show advertisement, identity;
import 'yoooclaw_account_test.dart'
    show AccountHttpAdapter, MemoryOfficialSessionStore, record, response;

class GatedVault extends RecorderCredentialVault {
  final reached = Completer<void>(), release = Completer<void>();
  GatedVault(RecorderKeyStore legacy) : super(legacy: legacy);
  @override
  Future<void> activateVerified(RecorderCredentialSelection selected,
      {required void Function() ensureCurrent}) async {
    reached.complete();
    await release.future;
    await super.activateVerified(selected, ensureCurrent: ensureCurrent);
  }
}

final class CredentialTestPlatform extends TestBlePlatform {
  bool rejectAudio = false;
  @override
  Future<bool> setNotifyValue(BmSetNotifyValueRequest request) async {
    if (rejectAudio &&
        request.characteristicUuid.str == BleConstants.charOpusAudioData) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      rejectNotify = true;
      try {
        return await super.setNotifyValue(request);
      } finally {
        rejectNotify = false;
      }
    }
    return super.setNotifyValue(request);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = CredentialTestPlatform();
  late AiNote6095Driver driver;
  late RecorderCredentialVault vault;
  late DeviceKeyStore legacy;
  late BluetoothDevice device;
  late YoooClawAccount client;
  var number = 0;
  var cloudCalls = 0;
  final old = base64Encode(List.filled(32, 9));
  setUpAll(() => FlutterBluePlusPlatform.instance = platform);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    platform.reset();
    platform.rejectAudio = false;
    cloudCalls = 0;
    legacy = DeviceKeyStore();
    vault = RecorderCredentialVault(legacy: legacy);
    device = BluetoothDevice.fromId(
        '50000000-0000-0000-0000-${(++number).toString().padLeft(12, '0')}');
    legacy.values[legacy.entry(device.remoteId.str, RecorderProtocol.telink)] =
        old;
    final adapter = AccountHttpAdapter();
    adapter.respond = (r) {
      if (r.path.endsWith('/check') ||
          r.path.endsWith('/bind') ||
          r.path.endsWith('/unbind')) cloudCalls++;
      return r.path.endsWith('/loginOrRegister')
          ? response({
              'code': '000000',
              'data': {'jwtToken': 'test-only-session', 'id': '123'}
            })
          : response({
              'code': '000000',
              'data': {
                'deviceList': [record()]
              }
            });
    };
    client = YoooClawAccount(
        http: Dio()..httpClientAdapter = adapter,
        sessionStore: MemoryOfficialSessionStore());
    await client.login('13800000000', '1234');
    await client.loadBindings();
    driver = AiNote6095Driver(
        keyStore: vault,
        authenticationTimeout: const Duration(milliseconds: 200));
  });
  tearDown(() async {
    await driver.dispose();
    client.close();
    await FlutterBluePlus.stopScan();
  });
  Future<void> scan() => platform.advertise(device.remoteId, advertisement());
  List<String> methods() => platform.writes
      .where((w) => w.value.length > 6)
      .map((w) =>
          jsonDecode(utf8.decode(w.value.sublist(2)))['method'] as String)
      .toList();
  test(
      'explicit account candidate passes real AES and activates without overwriting legacy',
      () async {
    platform.authenticate = true;
    await RecorderIdentityStore().save(identity(id: device.remoteId.str));
    await expectLater(
        driver.recoveryCandidates(
            accountSession: client.sessionForDevice(client.devices.single)),
        throwsStateError);
    expect(await vault.read(device.remoteId.str, RecorderProtocol.telink), old);
    await scan();
    expect(
        await driver.connectDevice(device,
            accountSession:
                client.sessionForAccountCandidate(client.devices.single)),
        true);
    expect(driver.isConnected, true);
    expect(await vault.read(device.remoteId.str, RecorderProtocol.telink),
        base64Encode(shared));
    expect(legacy.values.values.single, old);
    expect(legacy.writes, 0);
    expect(
        (await vault.history()).where((r) => r.active).single.verified, true);
    expect(methods(), contains('verifyIdentity'));
    expect(
        methods(),
        isNot(anyElement(
            isIn(['bindRequest', 'verifyResult', 'unbindRequest']))));
    expect(cloudCalls, 0);
    await driver.disconnect();
    await client.logout();
    await scan();
    expect(await driver.connectDevice(device), true);
    expect(await vault.read(device.remoteId.str, RecorderProtocol.telink), base64Encode(shared));
    expect(cloudCalls, 0);
  });
  for (final scenario in [
    'no challenge',
    'wrong key',
    'unsolicited success',
    'manufacturer',
    'wrong SN',
    'wrong GATT',
    'audio reject after AES',
    'no fresh scan'
  ]) {
    test('$scenario cannot activate candidate, bypass AES or start new binding',
        () async {
      platform.replyMethod = 'reportStatus';
      if (scenario == 'wrong key') {
        platform.authenticate = true;
        await client.loadBindings();
      }
      if (scenario == 'unsolicited success') {
        platform.replyMethod = 'verifyIdentityResult';
        platform.replySuccess = true;
      }
      if (scenario == 'manufacturer') platform.manufacturerOnSubscribe = true;
      if (scenario == 'wrong SN') {
        platform.authenticate = true;
        platform.reportedSn = 'AB00000000000002';
      }
      if (scenario == 'wrong GATT') platform.otaOnly = true;
      if (scenario == 'audio reject after AES') {
        platform.authenticate = true;
        platform.identityOnSubscribe = true;
        platform.rejectAudio = true;
      }
      final session = scenario == 'wrong key'
          ? RecorderAccountSession(
              'AB00000000000001',
              ({required checkContent, required mac, required sn}) async =>
                  throw StateError('never'),
              ({required sn, required mac, required sharedSecret}) async =>
                  throw StateError('never'),
              credentialCandidate: true,
              hasRecoverableKey: true, restoreKey: (id, p, s, store) async {
              await store.write(id, p, base64Encode(List.filled(32, 4)));
              return true;
            })
          : client.sessionForAccountCandidate(client.devices.single);
      if (scenario != 'no fresh scan') await scan();
      expect(
          await driver.connectDevice(device, accountSession: session), false);
      expect(driver.isConnected, false);
      expect(
          await vault.read(device.remoteId.str, RecorderProtocol.telink), old);
      expect(legacy.values.values.single, old);
      expect(legacy.writes, 0);
      expect(
          methods(),
          isNot(anyElement(
              isIn(['bindRequest', 'verifyResult', 'unbindRequest']))));
      expect(cloudCalls, 0);
    });
  }
  test(
      'disconnect while committing cancels activation and cannot mark reconnect verified',
      () async {
    await driver.dispose();
    final gated = GatedVault(legacy);
    driver = AiNote6095Driver(
        keyStore: gated, authenticationTimeout: const Duration(seconds: 2));
    platform.authenticate = true;
    await scan();
    final connection = driver.connectDevice(device,
        accountSession:
            client.sessionForAccountCandidate(client.devices.single));
    await gated.reached.future;
    await driver.disconnect();
    gated.release.complete();
    expect(await connection, false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await gated.read(device.remoteId.str, RecorderProtocol.telink), old);
    expect(driver.hasVerifiedDevice, false);
  });
  test(
      'account logout invalidates selected candidate without replacing active key',
      () async {
    final session = client.sessionForAccountCandidate(client.devices.single);
    await client.logout();
    await scan();
    expect(await driver.connectDevice(device, accountSession: session), false);
    expect(await vault.read(device.remoteId.str, RecorderProtocol.telink), old);
    expect(cloudCalls, 0);
  });

  test('historical source must pass a new real AES challenge to restore',
      () async {
    platform.authenticate = true;
    await scan();
    expect(
        await driver.connectDevice(device,
            accountSession:
                client.sessionForAccountCandidate(client.devices.single)),
        true);
    await driver.disconnect();
    final historical = (await driver.backupService.credentialHistory())
        .singleWhere((v) => !v.active);
    await scan();
    final selectedScan = RecorderScanIdentity.fromAdvertisement(
        remoteId: device.remoteId.str,
        deviceName: 'Test recorder',
        manufacturerData: advertisement(),
        connectable: true,
        observedAt: DateTime.now())!;
    final session =
        driver.backupService.archivedSession(historical, selectedScan);
    // 复用模拟对端的持有密钥AES分支；下方禁止任何首次绑定指令。
    platform.authenticate = false;
    platform.firstBinding = true;
    platform.peerSecret = Uint8List.fromList(List.filled(32, 9));
    expect(await driver.connectDevice(device, accountSession: session), true);
    expect(await vault.read(device.remoteId.str, RecorderProtocol.telink), old);
    expect(legacy.values.values.single, old);
    expect(cloudCalls, 0);
    expect(
        methods(),
        isNot(anyElement(
            isIn(['bindRequest', 'verifyResult', 'unbindRequest']))));
  });
}

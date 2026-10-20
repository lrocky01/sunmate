import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/ble_constants.dart';
import 'package:sunmate_app/core/ble/ble_protocol.dart';
import 'package:sunmate_app/core/ble/recorder_authentication.dart';
import 'package:sunmate_app/core/ble/recorder_credential_vault.dart';
import 'package:sunmate_app/core/ble/recorder_portable_backup.dart';
import 'package:sunmate_app/core/ble/yoooclaw_account.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_recovery_test.dart' show DeviceKeyStore;
import 'recorder_portable_backup_test.dart' show advertisement, identity;
import 'recorder_credential_vault_test.dart' show FaultCredentialStorage;
import 'recorder_credential_driver_test.dart' show GatedVault;
import 'yoooclaw_account_test.dart'
    show
        AccountHttpAdapter,
        MemoryOfficialSessionStore,
        record,
        response,
        scanIdentity;

final class RebindingPlatform extends TestBlePlatform {
  String failure = '';
  @override
  Future<bool> firstBindReply(
      BmWriteCharacteristicRequest r, String method) async {
    if (connectCount > 1 &&
        failure == 'no challenge' &&
        method == 'getStatus') {
      event(r.remoteId, {'method': 'reportStatus', 'params': {}});
      return true;
    }
    if (failure == 'wrong AES' && method == 'verifyIdentity') {
      event(r.remoteId, {
        'method': 'verifyIdentityResult',
        'params': {'success': false}
      });
      return true;
    }
    return super.firstBindReply(r, method);
  }

  @override
  Future<bool> setNotifyValue(BmSetNotifyValueRequest r) async {
    if (failure == 'audio after AES' &&
        connectCount > 1 &&
        r.characteristicUuid.str == BleConstants.charDeviceEvent) {
      final result = await super.setNotifyValue(r);
      event(r.remoteId, {
        'method': 'verifyIdentityRequest',
        'params': {'random': base64Encode(List.generate(32, (i) => i))}
      });
      return result;
    }
    if (['audio', 'audio after AES'].contains(failure) &&
        connectCount > 1 &&
        r.characteristicUuid.str == BleConstants.charOpusAudioData) {
      if (failure == 'audio after AES') {
        await Future<void>.delayed(const Duration(milliseconds: 70));
      }
      rejectNotify = true;
      try {
        return await super.setNotifyValue(r);
      } finally {
        rejectNotify = false;
      }
    }
    return super.setNotifyValue(r);
  }
}

class GatedRebindingCrypto extends RecorderCryptography {
  final reached = Completer<void>(), release = Completer<void>();
  @override
  Future<Uint8List> sharedSecret(SimpleKeyPair key, String public) async {
    final secret = await super.sharedSecret(key, public);
    reached.complete();
    await release.future;
    return secret;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = RebindingPlatform();
  late AccountHttpAdapter http;
  late YoooClawAccount account;
  late DeviceKeyStore legacy;
  late RecorderCredentialVault vault;
  late AiNote6095Driver driver;
  late BluetoothDevice device;
  var count = 0, listed = false;
  final old = base64Encode(List.filled(32, 7));
  FutureOr<ResponseBody> Function(RequestOptions)? overrideResponse;
  setUpAll(() => FlutterBluePlusPlatform.instance = platform);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    platform.reset();
    platform.failure = '';
    platform.firstBinding = true;
    platform.requiresBindRequest = true;
    listed = false;
    overrideResponse = null;
    device = BluetoothDevice.fromId(
        '70000000-0000-0000-0000-${(++count).toString().padLeft(12, '0')}');
    legacy = DeviceKeyStore();
    legacy.values[legacy.entry(device.remoteId.str, RecorderProtocol.telink)] =
        old;
    vault = RecorderCredentialVault(legacy: legacy);
    http = AccountHttpAdapter();
    http.respond = (r) {
      if (r.path.endsWith('/loginOrRegister'))
        return response({
          'code': '000000',
          'data': {'jwtToken': 'test-only-session', 'id': 'test-user'}
        });
      if (r.path.endsWith('/index'))
        return response({
          'code': '000000',
          'data': {
            'deviceList': [if (listed) record()]
          }
        });
      if (overrideResponse != null) return overrideResponse!(r);
      return response({
        'code': '000000',
        'data': {'hmac': 'test-only-issued-hmac'}
      });
    };
    account = YoooClawAccount(
        http: Dio()..httpClientAdapter = http,
        sessionStore: MemoryOfficialSessionStore());
    await account.login('13800000000', '1234');
    await account.loadBindings();
    driver = AiNote6095Driver(
        keyStore: vault,
        authenticationTimeout: const Duration(milliseconds: 350));
  });
  tearDown(() async {
    await driver.dispose();
    account.close();
    await FlutterBluePlus.stopScan();
  });
  Future<void> scan() => platform.advertise(device.remoteId, advertisement());
  RecorderAccountSession session() =>
      account.sessionForRebinding(scanIdentity(remoteId: device.remoteId.str));
  List<String> methods() => platform.writes
      .where((r) => r.value.length > 6)
      .map((r) =>
          jsonDecode(utf8.decode(r.value.sublist(2)))['method'] as String)
      .toList();
  int calls(String suffix) =>
      http.requests.where((r) => r.path.endsWith(suffix)).length;
  Future<void> oldStillActive() async {
    expect(
        await RecorderCredentialVault(legacy: legacy)
            .read(device.remoteId.str, RecorderProtocol.telink),
        old);
    expect(legacy.writes, 0);
    expect(legacy.values.values.single, old);
  }

  test(
      'explicit rebind persists new key before cloud sync, verifies real AES then activates',
      () async {
    overrideResponse = (r) async {
      if (r.path.endsWith('/bind')) {
        await oldStillActive();
        final versions = await vault.history();
        expect(versions, hasLength(2));
        expect(versions.singleWhere((v) => !v.active).verified, false);
        expect((r.data['extInfo'] as Map)['sharedSecret'],
            base64Encode(platform.peerSecret!));
      }
      return response({
        'code': '000000',
        'data': {'hmac': 'test-only-issued-hmac'}
      });
    };
    await scan();
    expect(await driver.connectDevice(device, accountSession: session()), true);
    expect(driver.isConnected, true);
    expect(platform.connectCount, 2);
    expect(await vault.read(device.remoteId.str, RecorderProtocol.telink),
        base64Encode(platform.peerSecret!));
    expect(legacy.values.values.single, old);
    expect(legacy.writes, 0);
    final active = (await vault.history()).singleWhere((v) => v.active);
    expect(active.verified, true);
    expect(active.source, '重新建立业务绑定');
    expect(calls('/check'), 1);
    expect(calls('/bind'), 1);
    expect(calls('/unbind'), 0);
    expect(methods().where((m) => m == 'bindRequest'), hasLength(1));
    expect(methods().where((m) => m == 'verifyResult'), hasLength(1));
    expect(methods(), contains('verifyIdentity'));
    final logs = driver.connectionLogs.join('\n');
    expect(logs, isNot(contains(old)));
    expect(logs, isNot(contains(base64Encode(platform.peerSecret!))));
    expect(logs, isNot(contains('test-only-issued-hmac')));
  });

  test('ordinary add still rejects existing key without issuing cloud calls',
      () async {
    await scan();
    expect(
        await driver.connectDevice(device,
            accountSession: account.sessionForNewDevice(
                scanIdentity(remoteId: device.remoteId.str))),
        false);
    await oldStillActive();
    expect(calls('/check'), 0);
    expect(calls('/bind'), 0);
    expect(methods(), isEmpty);
  });

  for (final failure in [
    'wrong AES',
    'no challenge',
    'audio',
    'audio after AES'
  ]) {
    test(
        '$failure never activates new key and retains pending version after restart',
        () async {
      platform.failure = failure;
      await scan();
      expect(
          await driver.connectDevice(device, accountSession: session()), false);
      await oldStillActive();
      final versions = await RecorderCredentialVault(legacy: legacy).history();
      expect(versions, hasLength(2));
      expect(versions.singleWhere((v) => !v.active).verified, false);
      expect(calls('/check'), 1);
      expect(calls('/bind'), 1);
      expect(methods().where((m) => m == 'bindRequest'), hasLength(1));
    });
  }

  test(
      'cloud failure preserves pending derived key which can later pass local AES',
      () async {
    overrideResponse = (r) => r.path.endsWith('/bind')
        ? response({'code': '123456'})
        : response({
            'code': '000000',
            'data': {'hmac': 'test-only-issued-hmac'}
          });
    await scan();
    expect(
        await driver.connectDevice(device, accountSession: session()), false);
    await oldStillActive();
    final pending = (await vault.history()).singleWhere((v) => !v.active);
    expect(pending.verified, false);
    await scan();
    final recovery = RecorderBackupService(keys: vault)
        .archivedSession(pending, scanIdentity(remoteId: device.remoteId.str));
    expect(await driver.connectDevice(device, accountSession: recovery), true);
    expect(await vault.read(device.remoteId.str, RecorderProtocol.telink),
        base64Encode(platform.peerSecret!));
    expect(calls('/check'), 1);
    expect(calls('/bind'), 1);
  });

  for (final logout in [false, true]) {
    test('cancel or logout during cloud commit preserves durable key ($logout)',
        () async {
      final reached = Completer<void>(), release = Completer<ResponseBody>();
      overrideResponse = (r) {
        if (r.path.endsWith('/bind')) {
          reached.complete();
          return release.future;
        }
        return response({
          'code': '000000',
          'data': {'hmac': 'test-only-issued-hmac'}
        });
      };
      await scan();
      final op = driver.connectDevice(device, accountSession: session());
      await reached.future;
      if (logout) {
        await account.logout();
      } else {
        await driver.disconnect();
      }
      release.complete(response({'code': '000000'}));
      expect(await op, false);
      await oldStillActive();
      expect((await vault.history()).singleWhere((v) => !v.active).verified,
          false);
      expect(platform.connectCount, 1);
    });
  }

  test('failed old-key archive prevents all handshake writes', () async {
    final faults = FaultCredentialStorage();
    faults.beforeWrite =
        (_, __) => throw StateError('synthetic unavailable storage');
    await driver.dispose();
    vault = RecorderCredentialVault(legacy: legacy, storage: faults);
    driver = AiNote6095Driver(
        keyStore: vault,
        authenticationTimeout: const Duration(milliseconds: 200));
    await scan();
    expect(
        await driver.connectDevice(device, accountSession: session()), false);
    expect(calls('/check'), 0);
    expect(calls('/bind'), 0);
    expect(methods(), isEmpty);
    expect(legacy.values.values.single, old);
  });

  test('single-use confirmation cannot start a second negotiation', () async {
    final selected = session();
    await scan();
    expect(await driver.connectDevice(device, accountSession: selected), true);
    await driver.disconnect();
    await scan();
    expect(await driver.connectDevice(device, accountSession: selected), false);
    expect(calls('/check'), 1);
    expect(calls('/bind'), 1);
  });

  test('account list still containing SN rejects rebinding capability',
      () async {
    listed = true;
    await account.loadBindings();
    expect(session, throwsA(isA<OfficialAccountException>()));
    expect(calls('/check'), 0);
    expect(calls('/bind'), 0);
  });

  test('stale account selection and stale scan cannot start negotiation',
      () async {
    final selected = session();
    await account.loadBindings();
    await scan();
    expect(await driver.connectDevice(device, accountSession: selected), false);
    expect(calls('/check'), 0);
    expect(
        () => account.sessionForRebinding(scanIdentity(
            observedAt: DateTime.now().subtract(const Duration(minutes: 2)))),
        throwsA(isA<OfficialAccountException>()));
  });

  test(
      'cancellation during real key derivation still preserves pending material without cloud commit',
      () async {
    final saved = identity(id: device.remoteId.str);
    await vault.preserveForRebinding(saved);
    final pending = RecorderRebindingKeyStore(vault, saved);
    final crypto = GatedRebindingCrypto();
    var commits = 0;
    final auth = RecorderAuthentication(
        protocol: RecorderProtocol.telink,
        deviceId: device.remoteId.str,
        store: pending,
        cryptography: crypto,
        onNegotiatedKey: pending.preserveNegotiatedKey,
        verifier: ({required checkContent, required mac, required sn}) async =>
            'test-only-issued-hmac',
        committer: ({required sn, required mac, required sharedSecret}) async {
          commits++;
        });
    await auth.loadKey();
    await auth.answerManufacturer({
      'encrypted': 'test-challenge',
      'mac': 'test-mac',
      'sn': saved.serialNumber
    });
    final peer = await X25519().newKeyPair();
    final public = await peer.extractPublicKey();
    final op = auth.acceptPairing(
        {'success': true, 'public_key': base64Encode(public.bytes)});
    final checked = expectLater(op, throwsStateError);
    await crypto.reached.future;
    auth.cancel();
    pending.close();
    crypto.release.complete();
    await checked;
    await oldStillActive();
    expect(commits, 0);
    expect(
        (await RecorderCredentialVault(legacy: legacy).history())
            .singleWhere((v) => !v.active)
            .source,
        '重新建立业务绑定');
  });

  test('new-key storage failure blocks cloud bind and preserves old credential',
      () async {
    final faults = FaultCredentialStorage();
    faults.beforeWrite = (_, value) {
      if (value != null && value.contains('重新建立业务绑定')) {
        throw StateError('synthetic write failure');
      }
    };
    await driver.dispose();
    vault = RecorderCredentialVault(legacy: legacy, storage: faults);
    driver = AiNote6095Driver(
        keyStore: vault,
        authenticationTimeout: const Duration(milliseconds: 300));
    await scan();
    expect(
        await driver.connectDevice(device, accountSession: session()), false);
    await oldStillActive();
    expect(calls('/check'), 1);
    expect(calls('/bind'), 0);
    expect((await vault.history()).single.active, true);
    expect(driver.isConnected, false);
  });

  test(
      'capacity preflight rejects rebinding before any handshake or deleting history',
      () async {
    final saved = identity(id: device.remoteId.str);
    for (var i = 0; i < 31; i++) {
      await vault.prepare(saved, base64Encode(List.filled(32, 80 + i)),
          source: '官方账号资料');
    }
    await scan();
    expect(
        await driver.connectDevice(device, accountSession: session()), false);
    await oldStillActive();
    expect(await vault.history(), hasLength(32));
    expect(methods(), isEmpty);
    expect(calls('/check'), 0);
    expect(calls('/bind'), 0);
  });

  test(
      'isolated negotiation rejects different bytes after durable save and stale selection',
      () async {
    final saved = identity(id: device.remoteId.str);
    await vault.preserveForRebinding(saved);
    final pending = RecorderRebindingKeyStore(vault, saved);
    final next = base64Encode(List.filled(32, 50));
    await pending.preserveNegotiatedKey(next);
    await expectLater(
        pending.write(device.remoteId.str, RecorderProtocol.telink,
            base64Encode(List.filled(32, 51))),
        throwsStateError);
    await pending.write(device.remoteId.str, RecorderProtocol.telink, next);
    await expectLater(
        pending.write(device.remoteId.str, RecorderProtocol.telink, next),
        throwsStateError);
    final stale = pending.selection!;
    await vault.prepare(saved, base64Encode(List.filled(32, 52)),
        source: '官方账号资料');
    await expectLater(
        vault.loadPrepared(
            saved,
            stale,
            RecorderCandidateKeyStore(
                device.remoteId.str, RecorderProtocol.telink)),
        throwsStateError);
    await oldStillActive();
    pending.close();
  });

  test(
      'missing fresh broadcast and wrong GATT cannot use explicit confirmation',
      () async {
    expect(
        await driver.connectDevice(device, accountSession: session()), false);
    expect(methods(), isEmpty);
    await scan();
    platform.otaOnly = true;
    expect(
        await driver.connectDevice(device, accountSession: session()), false);
    expect(methods(), isEmpty);
    expect(calls('/check'), 0);
    expect(calls('/bind'), 0);
    await oldStillActive();
  });

  test('duplicate account records cannot authorize explicit rebinding',
      () async {
    http.respond = (_) => response({
          'code': '000000',
          'data': {
            'deviceList': [record(), record()]
          }
        });
    await account.loadBindings();
    expect(session, throwsA(isA<OfficialAccountException>()));
    expect(methods(), isEmpty);
  });

  test('automatic connection cannot initiate explicit rebind', () async {
    await scan();
    expect(
        await driver.connectDevice(device,
            isAutoReconnect: true, accountSession: session()),
        false);
    expect(platform.connectCount, 0);
    expect(methods(), isEmpty);
    await oldStillActive();
  });

  test('repeated click during one operation does not issue a second handshake',
      () async {
    final reached = Completer<void>(), release = Completer<ResponseBody>();
    overrideResponse = (r) {
      if (r.path.endsWith('/check')) {
        reached.complete();
        return release.future;
      }
      return response({'code': '000000'});
    };
    await scan();
    final selected = session();
    final first = driver.connectDevice(device, accountSession: selected);
    await reached.future;
    expect(await driver.connectDevice(device, accountSession: selected), false);
    release.complete(response({
      'code': '000000',
      'data': {'hmac': 'test-only-issued-hmac'}
    }));
    expect(await first, true);
    expect(calls('/check'), 1);
    expect(calls('/bind'), 1);
  });

  test(
      'disconnect at final activation retains old reference and new pending version',
      () async {
    await driver.dispose();
    final gated = GatedVault(legacy);
    vault = gated;
    driver = AiNote6095Driver(
        keyStore: vault,
        authenticationTimeout: const Duration(milliseconds: 350));
    await scan();
    final op = driver.connectDevice(device, accountSession: session());
    await gated.reached.future;
    await driver.disconnect();
    gated.release.complete();
    expect(await op, false);
    await oldStillActive();
    expect(
        (await vault.history()).singleWhere((v) => !v.active).verified, false);
  });
}

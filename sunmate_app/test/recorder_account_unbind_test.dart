import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ble/yoooclaw_account.dart';
import 'package:sunmate_app/core/ble/recorder_binding_backup_store.dart';
import 'package:sunmate_app/core/ble/official_account_session_store.dart';
import 'yoooclaw_account_test.dart'
    show
        AccountHttpAdapter,
        MemoryOfficialSessionStore,
        response,
        record,
        scanIdentity;

class MemoryBindingBackup implements RecorderBindingBackupStore {
  final values = <String>[];
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<void> saveVerified(String value) async {
    values.add(value);
    if (gate != null) await gate!.future;
    if (fail) throw StateError('private storage failure');
  }
}

class FailedReadBackStorage extends FlutterSecureStorage {
  final String? returned;
  int reads = 0;
  FailedReadBackStorage(this.returned);
  @override
  Future<String?> read(
          {required String key,
          IOSOptions? iOptions,
          AndroidOptions? aOptions,
          LinuxOptions? lOptions,
          WebOptions? webOptions,
          MacOsOptions? mOptions,
          WindowsOptions? wOptions}) async =>
      ++reads == 1 ? null : returned;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const serial = 'AB00000000000001';
  late AccountHttpAdapter adapter;
  late YoooClawAccount account;
  late MemoryBindingBackup backup;
  var listed = true, duplicate = false, missingMac = false;
  late FutureOr<ResponseBody> Function(RequestOptions) unbindResponse;
  setUp(() async {
    listed = true;
    duplicate = false;
    missingMac = false;
    adapter = AccountHttpAdapter();
    backup = MemoryBindingBackup();
    account = YoooClawAccount(
        http: Dio()..httpClientAdapter = adapter,
        sessionStore: MemoryOfficialSessionStore(),
        backupStore: backup);
    unbindResponse = (_) => response({'code': '000000'});
    adapter.respond = (r) {
      if (r.path.endsWith('/loginOrRegister'))
        return response({
          'code': '000000',
          'data': {'jwtToken': 'test-only-token', 'id': 'test-user'}
        });
      if (r.path.endsWith('/unbind')) return unbindResponse(r);
      final item = record();
      if (missingMac) (item['extInfo'] as Map).remove('mac');
      return response({
        'code': '000000',
        'data': {
          'deviceList': [if (listed) item, if (duplicate) record()]
        }
      });
    };
    await account.login('13800000000', '1234');
    await account.loadBindings();
  });
  tearDown(() => account.close());
  List<RequestOptions> unbinds() =>
      adapter.requests.where((r) => r.path.endsWith('/unbind')).toList();

  test(
      'archives before exact authenticated unbind, confirms list before adding',
      () async {
    final device = account.devices.single;
    final oldSession = account.sessionForDevice(device);
    unbindResponse = (r) {
      expect(backup.values, hasLength(1));
      expect(r.method, 'POST');
      expect(r.uri.path, '/api/device/toc/externalDeviceBind/unbind');
      expect(r.data, {'deviceId': serial, 'mac': 'test-only-mac'});
      expect(r.headers['Authorization'], 'Bearer test-only-token');
      expect(r.headers['UserId'], 'test-user');
      return response({'code': '000000'});
    };
    await account.unbindDevice(device, canProceed: () => true);
    final archive = jsonDecode(backup.values.single) as Map;
    expect(archive['userId'], 'test-user');
    expect(archive['serialNumber'], serial);
    expect(archive['protocol'], 'telink');
    expect(
        archive['sharedSecret'], (record()['extInfo'] as Map)['sharedSecret']);
    expect(archive.containsKey('token'), false);
    expect(account.hasPendingUnbind, true);
    expect(() => account.sessionForNewDevice(scanIdentity()),
        throwsA(isA<OfficialAccountException>()));
    await expectLater(
        oldSession.verifier(checkContent: 'challenge', mac: 'mac', sn: serial),
        throwsA(isA<OfficialAccountException>()));
    await account.loadBindings();
    expect(account.hasPendingUnbind, true);
    expect(account.canUnbindDevice(account.devices.single), false);
    expect(() => account.sessionForDevice(account.devices.single),
        throwsA(isA<OfficialAccountException>()));
    listed = false;
    await account.loadBindings();
    expect(account.hasPendingUnbind, false);
    expect(account.unbindNotice, contains('已确认账号列表移除'));
    expect(account.sessionForNewDevice(scanIdentity()).serialNumber, serial);
    expect(unbinds(), hasLength(1));
    final log = account.diagnostics.join('\n');
    for (final value in [
      'test-only-token',
      'test-only-mac',
      archive['sharedSecret'] as String
    ]) {
      expect(log, isNot(contains(value)));
    }
  });

  test('backup failure, busy hardware and stale selection send zero requests',
      () async {
    var device = account.devices.single;
    await expectLater(account.unbindDevice(device, canProceed: () => false),
        throwsA(isA<OfficialAccountException>()));
    expect(backup.values, isEmpty);
    await account.loadBindings();
    await expectLater(account.unbindDevice(device, canProceed: () => true),
        throwsA(isA<OfficialAccountException>()));
    device = account.devices.single;
    backup.fail = true;
    await expectLater(account.unbindDevice(device, canProceed: () => true),
        throwsA(isA<OfficialAccountException>()));
    expect(unbinds(), isEmpty);
    expect(account.canUnbindDevice(device), true);
  });

  for (final sessionChanged in [false, true]) {
    test('rechecks hardware/session after backup ($sessionChanged)', () async {
      backup.gate = Completer<void>();
      var idle = true;
      final operation =
          account.unbindDevice(account.devices.single, canProceed: () => idle);
      final check =
          expectLater(operation, throwsA(isA<OfficialAccountException>()));
      await Future<void>.delayed(Duration.zero);
      if (sessionChanged) {
        await account.logout();
      } else {
        idle = false;
      }
      backup.gate!.complete();
      await check;
      expect(unbinds(), isEmpty);
      expect(backup.values, hasLength(1));
    });
  }

  test('concurrent unbind and refresh cannot submit twice', () async {
    final gate = Completer<ResponseBody>(), entered = Completer<void>();
    unbindResponse = (_) {
      entered.complete();
      return gate.future;
    };
    final device = account.devices.single;
    final first = account.unbindDevice(device, canProceed: () => true);
    await entered.future;
    await expectLater(account.unbindDevice(device, canProceed: () => true),
        throwsA(isA<OfficialAccountException>()));
    await expectLater(
        account.loadBindings(), throwsA(isA<OfficialAccountException>()));
    gate.complete(response({'code': '000000'}));
    await first;
    expect(unbinds(), hasLength(1));
    expect(backup.values, hasLength(1));
  });

  test('business refusal retains record and recovery material', () async {
    final device = account.devices.single;
    unbindResponse = (_) => response({'code': '123456', 'message': 'private'});
    await expectLater(account.unbindDevice(device, canProceed: () => true),
        throwsA(isA<OfficialAccountException>()));
    expect(account.devices.single, same(device));
    expect(account.hasPendingUnbind, false);
    expect(account.canUnbindDevice(device), true);
    expect(backup.values, hasLength(1));
    expect(account.diagnostics.join(), isNot(contains('private')));
  });

  for (final status in [401, 403, 500]) {
    test('HTTP $status never starts binding or deletes backup', () async {
      unbindResponse = (_) => response({'message': 'private'}, status: status);
      await expectLater(
          account.unbindDevice(account.devices.single, canProceed: () => true),
          throwsA(isA<OfficialAccountException>()));
      expect(account.isLoggedIn, status != 401);
      expect(backup.values, hasLength(1));
      expect(unbinds(), hasLength(1));
      expect(adapter.requests.any((r) => r.path.endsWith('/bind')), false);
      if (status != 401) expect(account.hasPendingUnbind, true);
    });
  }

  test('timeout is uncertain and list verification never resends unbind',
      () async {
    unbindResponse = (r) => throw DioException(
        requestOptions: r, type: DioExceptionType.receiveTimeout);
    await expectLater(
        account.unbindDevice(account.devices.single, canProceed: () => true),
        throwsA(isA<OfficialAccountException>()));
    expect(account.hasPendingUnbind, true);
    expect(account.unbindNotice, contains('尚未确认'));
    listed = false;
    await account.loadBindings();
    expect(account.hasPendingUnbind, false);
    expect(unbinds(), hasLength(1));
  });

  test('refresh failure keeps accepted pending and blocks new-device session',
      () async {
    await account.unbindDevice(account.devices.single, canProceed: () => true);
    adapter.respond = (_) => response({'code': '000000', 'data': {}});
    await expectLater(
        account.loadBindings(), throwsA(isA<OfficialAccountException>()));
    expect(account.hasPendingUnbind, true);
    expect(account.unbindNotice, contains('服务器已接受'));
    expect(() => account.sessionForNewDevice(scanIdentity()),
        throwsA(isA<OfficialAccountException>()));
    expect(unbinds(), hasLength(1));
  });

  test('late success after logout cannot mutate a new login', () async {
    final gate = Completer<ResponseBody>(), entered = Completer<void>();
    unbindResponse = (_) {
      entered.complete();
      return gate.future;
    };
    final operation =
        account.unbindDevice(account.devices.single, canProceed: () => true);
    final check =
        expectLater(operation, throwsA(isA<OfficialAccountException>()));
    await entered.future;
    await account.logout();
    await account.login('13800000000', '1234');
    gate.complete(response({'code': '000000'}));
    await check;
    expect(account.isLoggedIn, true);
    expect(account.hasPendingUnbind, false);
    await account.loadBindings();
    expect(account.devices, hasLength(1));
  });

  test('duplicate SN or missing real MAC cannot be unbound', () async {
    duplicate = true;
    await account.loadBindings();
    expect(account.devices, isEmpty);
    duplicate = false;
    missingMac = true;
    await account.loadBindings();
    final device = account.devices.single;
    expect(account.canUnbindDevice(device), false);
    await expectLater(account.unbindDevice(device, canProceed: () => true),
        throwsA(isA<OfficialAccountException>()));
    expect(unbinds(), isEmpty);
  });

  test('secure archive is append-only and separate from login and active key',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      SecureOfficialAccountSessionStore.storageKey: 'test-only-login',
      'test-active-ble-key': 'test-only-old-key',
    });
    const storage = FlutterSecureStorage();
    final store = SecureRecorderBindingBackupStore(storage: storage);
    await store.saveVerified('test-only-first-material');
    await store.saveVerified('test-only-second-material');
    final all = await storage.readAll();
    expect(
        all[SecureOfficialAccountSessionStore.storageKey], 'test-only-login');
    expect(all['test-active-ble-key'], 'test-only-old-key');
    final archives = all.entries.where(
        (e) => e.key.startsWith(SecureRecorderBindingBackupStore.keyPrefix));
    expect(archives.map((e) => e.value).toSet(),
        {'test-only-first-material', 'test-only-second-material'});
  });

  for (final returned in [null, 'test-only-mismatched-material']) {
    test('secure archive rejects absent or different read-back ($returned)',
        () async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = FailedReadBackStorage(returned);
      await expectLater(
          SecureRecorderBindingBackupStore(storage: storage)
              .saveVerified('test-only-original-material'),
          throwsStateError);
      expect(storage.reads, 2);
    });
  }
}

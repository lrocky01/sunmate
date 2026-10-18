import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ble/official_account_session_store.dart';
import 'package:sunmate_app/core/ble/yoooclaw_account.dart';
import 'yoooclaw_account_test.dart'
    show AccountHttpAdapter, MemoryOfficialSessionStore, response, record;

void main() {
  late MemoryOfficialSessionStore store;
  late AccountHttpAdapter adapter;
  late YoooClawAccount account;
  setUp(() {
    store = MemoryOfficialSessionStore();
    adapter = AccountHttpAdapter();
    adapter.respond = (r) => r.path.endsWith('/loginOrRegister')
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
    account = YoooClawAccount(
        http: Dio()..httpClientAdapter = adapter, sessionStore: store);
  });
  tearDown(() => account.close());

  test('close and reopen restores login without SMS or login requests',
      () async {
    await account.login('13800000000', '1234');
    expect(account.isSessionSaved, true);
    final saved = store.value;
    expect(jsonDecode(saved!).keys,
        unorderedEquals(['version', 'token', 'userId']));
    expect(saved, isNot(contains('13800000000')));
    account.close();
    final reopenedAdapter = AccountHttpAdapter()
      ..respond = (_) => response({
            'code': '000000',
            'data': {
              'deviceList': [record()]
            }
          });
    account = YoooClawAccount(
        http: Dio()..httpClientAdapter = reopenedAdapter, sessionStore: store);
    expect(await account.restoreSession(), true);
    expect(account.isSessionSaved, true);
    await account.loadBindings();
    await account.loadBindings();
    expect(reopenedAdapter.requests.map((r) => r.uri.path),
        everyElement('/api/device/toc/homePage/pub/index'));
    expect(reopenedAdapter.requests, hasLength(2));
    expect(reopenedAdapter.requests.last.headers['Authorization'],
        'Bearer test-only-session');
    expect(
        account.diagnostics.join('\n'), isNot(contains('test-only-session')));
    expect(store.value, saved);
  });

  test(
      'authenticated 401 forgets invalid login and device data without requesting SMS',
      () async {
    await account.login('13800000000', '1234');
    await account.loadBindings();
    adapter.respond = (_) => response({'code': '401'}, status: 401);
    await expectLater(
        account.loadBindings(), throwsA(isA<OfficialAccountException>()));
    expect(account.isLoggedIn, false);
    expect(account.devices, isEmpty);
    expect(store.value, isNull);
    expect(await account.restoreSession(), false);
    expect(
        adapter.requests.any((r) => r.path.endsWith('/sendLoginSms')), false);
  });

  for (final status in [403, 429, 503]) {
    test('HTTP $status preserves saved login for retry', () async {
      await account.login('13800000000', '1234');
      final saved = store.value;
      adapter.respond = (_) => response({'code': '$status'}, status: status);
      await expectLater(
          account.loadBindings(), throwsA(isA<OfficialAccountException>()));
      expect(account.isLoggedIn, true);
      expect(store.value, saved);
    });
  }

  test('network failure preserves saved login', () async {
    await account.login('13800000000', '1234');
    final saved = store.value;
    adapter.respond = (r) => throw DioException(
        requestOptions: r, type: DioExceptionType.connectionTimeout);
    await expectLater(
        account.loadBindings(), throwsA(isA<OfficialAccountException>()));
    expect(store.value, saved);
    expect(account.isLoggedIn, true);
  });

  test('invalid saved data is cleared without sending it to the server',
      () async {
    for (final value in [
      'not-json',
      jsonEncode({'version': 1, 'token': 'bad\r\nheader', 'userId': '123'})
    ]) {
      store.value = value;
      expect(await account.restoreSession(), false);
      expect(store.value, isNull);
    }
    expect(adapter.requests, isEmpty);
  });

  test('safe-storage errors are reported without exposing native details',
      () async {
    store.failRead = true;
    await expectLater(
        account.restoreSession(), throwsA(isA<OfficialAccountException>()));
    store.failRead = false;
    store.failWrite = true;
    await account.login('13800000000', '1234');
    expect(account.isLoggedIn, true);
    expect(account.isSessionSaved, false);
    expect(store.value, isNull);
    expect(account.diagnostics.join('\n'), contains('系统安全存储未能保存'));
    expect(account.diagnostics.join('\n'),
        isNot(contains('test-only-storage-failure')));
  });

  test(
      'logout failure remains retryable; successful logout removes saved login',
      () async {
    await account.login('13800000000', '1234');
    store.failDelete = true;
    await expectLater(
        account.logout(), throwsA(isA<OfficialAccountException>()));
    expect(account.isLoggedIn, true);
    store.failDelete = false;
    await account.logout();
    expect(account.isLoggedIn, false);
    expect(store.value, isNull);
    expect(await account.restoreSession(), false);
  });

  test('logout wins over a pending secure-store write', () async {
    store.writeGate = Completer<void>();
    final login = account.login('13800000000', '1234');
    final rejected =
        expectLater(login, throwsA(isA<OfficialAccountException>()));
    while (!account.isLoggedIn) {
      await Future<void>.delayed(Duration.zero);
    }
    final logout = account.logout();
    store.writeGate!.complete();
    await rejected;
    await logout;
    expect(store.value, isNull);
    expect(account.isLoggedIn, false);
  });

  test('late old-login response cannot overwrite newer saved login', () async {
    final pending = Completer<ResponseBody>(), entered = Completer<void>();
    var calls = 0;
    adapter.respond = (_) {
      if (++calls == 1) {
        entered.complete();
        return pending.future;
      }
      return response({
        'code': '000000',
        'data': {'jwtToken': 'test-only-new-session', 'id': '456'}
      });
    };
    final old = account.login('13800000000', '1234');
    final rejected = expectLater(old, throwsA(isA<OfficialAccountException>()));
    await entered.future;
    await account.login('13800000000', '1234');
    pending.complete(response({
      'code': '000000',
      'data': {'jwtToken': 'test-only-old-session', 'id': '123'}
    }));
    await rejected;
    expect(jsonDecode(store.value!)['token'], 'test-only-new-session');
  });

  test('old-instance 401 cannot delete another instance newer saved login',
      () async {
    await account.login('13800000000', '1234');
    final pending = Completer<ResponseBody>(), entered = Completer<void>();
    adapter.respond = (_) {
      entered.complete();
      return pending.future;
    };
    final request = account.loadBindings();
    final rejected =
        expectLater(request, throwsA(isA<OfficialAccountException>()));
    await entered.future;
    final otherAdapter = AccountHttpAdapter()
      ..respond = (_) => response({
            'code': '000000',
            'data': {'jwtToken': 'test-only-new-session', 'id': '456'}
          });
    final other = YoooClawAccount(
        http: Dio()..httpClientAdapter = otherAdapter, sessionStore: store);
    addTearDown(other.close);
    await other.login('13800000000', '1234');
    pending.complete(response({'code': '401'}, status: 401));
    await rejected;
    expect(other.isLoggedIn, true);
    expect(jsonDecode(store.value!)['token'], 'test-only-new-session');
  });

  test('logout cancels a late device-list response', () async {
    await account.login('13800000000', '1234');
    final pending = Completer<ResponseBody>(), entered = Completer<void>();
    adapter.respond = (_) {
      entered.complete();
      return pending.future;
    };
    final request = account.loadBindings();
    final rejected =
        expectLater(request, throwsA(isA<OfficialAccountException>()));
    await entered.future;
    await account.logout();
    pending.complete(response({
      'code': '000000',
      'data': {
        'deviceList': [record()]
      }
    }));
    await rejected;
    expect(account.devices, isEmpty);
    expect(account.isLoggedIn, false);
  });

  test('secure account logout leaves the recorder-key storage entry intact',
      () async {
    FlutterSecureStorage.setMockInitialValues(
        {'test-only-recorder-key': 'test-only-preserved-key'});
    final secure = SecureOfficialAccountSessionStore();
    await secure.write(jsonEncode(
        {'version': 1, 'token': 'test-only-session', 'userId': '123'}));
    expect(await secure.read(), isNotNull);
    final secureAccount = YoooClawAccount(sessionStore: secure);
    addTearDown(secureAccount.close);
    expect(await secureAccount.restoreSession(), true);
    await secureAccount.logout();
    expect(await secure.read(), isNull);
    expect(
        await const FlutterSecureStorage().read(key: 'test-only-recorder-key'),
        'test-only-preserved-key');
  });
}

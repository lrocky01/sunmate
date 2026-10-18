import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ble/ble_protocol.dart';
import 'package:sunmate_app/core/ble/yoooclaw_account.dart';
import 'recorder_authentication_test.dart' show MemoryKeyStore, shared;

// All requests terminate in memory; no SMS or vendor calls occur in these tests.
class AccountHttpAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  FutureOr<ResponseBody> Function(RequestOptions)? respond;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelFuture) async {
    requests.add(options);
    return await respond!(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody response(Object body, {int status = 200}) =>
    ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType]
    });
Map<String, dynamic> record(
        {String type = 'TELINK',
        String sn = 'AB00000000000001',
        String? secret}) =>
    {
      'externalDeviceId': sn,
      'externalDeviceName': 'Test recorder',
      'deviceType': type,
      'extInfo': {
        'sharedSecret': secret ?? base64Encode(shared),
        'mac': 'test-only-mac'
      },
    };
void main() {
  late AccountHttpAdapter adapter;
  late YoooClawAccount client;
  setUp(() {
    adapter = AccountHttpAdapter();
    client = YoooClawAccount(http: Dio()..httpClientAdapter = adapter);
    adapter.respond = (r) {
      if (r.path.endsWith('/sendLoginSms')) return response({'code': '0'});
      if (r.path.endsWith('/loginOrRegister'))
        return response({
          'code': '200',
          'data': {
            'jwtToken': 'Bearer test-only-session',
            'id': '1000000000000000001'
          }
        });
      return response({
        'code': '000000',
        'data': {
          'deviceList': [record()]
        }
      });
    };
  });
  tearDown(() => client.close());
  test(
      'device material summary distinguishes missing, invalid and supported recovery',
      () {
    final good = AccountRecorderDevice.fromRecord(record())!;
    expect(good.hasRecoverableKey, true);
    expect(good.hasMac, true);
    expect(good.protocolLabel, 'telink');
    final missing = AccountRecorderDevice.fromRecord(
        {...record(), 'extInfo': <String, dynamic>{}})!;
    expect(missing.hasSharedSecretField, false);
    expect(missing.hasRecoverableKey, false);
    final invalid =
        AccountRecorderDevice.fromRecord(record(secret: 'invalid-test-key'))!;
    expect(invalid.hasSharedSecretField, true);
    expect(invalid.hasRecoverableKey, false);
    final unsupported =
        AccountRecorderDevice.fromRecord(record(type: 'UNKNOWN'))!;
    expect(unsupported.hasSharedSecretField, true);
    expect(unsupported.hasRecoverableKey, false);
    final unparsed = AccountRecorderDevice.fromRecord(
        {...record(), 'extInfo': 'unrecognized-test-shape'})!;
    expect(unparsed.keyMaterialSummary, '绑定资料格式待核对');
  });
  test('validated App channel login and account recovery use one service',
      () async {
    await client.sendSms('13800000000');
    await client.login('13800000000', '1234');
    final bindings = await client.loadBindings();
    expect(adapter.requests.map((r) => r.uri.host), [
      'openclaw-service.yoooclaw.com',
      'openclaw-service.yoooclaw.com',
      'openclaw-service.yoooclaw.com'
    ]);
    expect(adapter.requests[0].uri.path, '/api/account/auth/open/sendLoginSms');
    expect(adapter.requests[0].data,
        {'phone': '13800000000', 'channel': '3', 'deviceId': 'deviceId'});
    expect(adapter.requests[1].uri.path,
        '/api/account/auth/login/open/loginOrRegister');
    expect(adapter.requests[1].data, {
      'phone': '13800000000',
      'smsCode': '1234',
      'channel': '3',
      'deviceId': 'deviceId'
    });
    expect(adapter.requests[2].uri.path, '/api/device/toc/homePage/pub/index');
    expect(adapter.requests[2].headers['Authorization'],
        'Bearer test-only-session');
    expect(adapter.requests[2].headers['app_key'], 'yoooclaw');
    expect(adapter.requests[0].headers.containsKey('Authorization'), false);
    expect(adapter.requests.every((r) => r.headers['app_key'] == 'yoooclaw'),
        true);
    expect(adapter.requests.every((r) => !r.followRedirects), true);
    expect(bindings.single.matches('ab00000000000001', RecorderProtocol.telink),
        true);
    final keys = MemoryKeyStore();
    await bindings.single.saveForDevice(keys, 'ios-selected-peripheral');
    expect(keys.value, base64Encode(shared));
    expect(bindings.single.toString(), isNot(contains(base64Encode(shared))));
    final diagnostic = client.diagnostics.join('\n');
    expect(diagnostic, contains('读取设备列表：HTTP 200'));
    for (final sensitive in [
      'test-only-session',
      '13800000000',
      '1234',
      base64Encode(shared)
    ]) {
      expect(diagnostic, isNot(contains(sensitive)));
    }
  });
  test('bare App JWT gains the required Bearer scheme exactly once', () async {
    adapter.respond = (r) => r.path.endsWith('/loginOrRegister')
        ? response({
            'code': '200',
            'data': {'jwtToken': 'test-only-bare-session', 'id': '123'}
          })
        : response({
            'code': '200',
            'data': {'deviceList': []}
          });
    await client.login('13800000000', '1234');
    await client.loadBindings();
    expect(adapter.requests.last.headers['Authorization'],
        'Bearer test-only-bare-session');
    expect(adapter.requests.last.data, isNull);
    expect(adapter.requests.length, 2);
  });
  test(
      'response field inventory records counts and types, never unknown content',
      () async {
    await client.login('13800000000', '1234');
    adapter.respond = (_) => response({
          'code': '000000',
          'private-envelope-key': 'private-envelope-value',
          'data': {
            'deviceList': [
              {
                ...record(),
                'private-record-key': 'private-record-value',
                'extInfo': {
                  'mac': 'private-mac-value',
                  'uuid': null,
                  'private-ext-key': 'private-ext-value'
                }
              },
              {
                ...record(sn: 'AB00000000000002'),
                'extInfo': {'sharedSecret': ''}
              },
              {
                ...record(sn: 'AB00000000000003'),
                'extInfo': {'sharedSecret': null}
              },
            ],
            'private-data-key': 'private-data-value'
          }
        });
    await client.loadBindings();
    final text = client.diagnostics.join('\n');
    expect(text, contains('顶层 3 字段；data 2 字段；设备记录 3 条'));
    expect(text, contains('设备记录 #1：5 字段（额外 1）'));
    expect(text, contains('扩展 3 字段（额外 1）'));
    expect(text, contains('sharedSecret=缺失'));
    expect(text, contains('sharedSecret=空字符串'));
    expect(text, contains('sharedSecret=null'));
    expect(text, contains('uuid=null'));
    expect(text, isNot(contains('private-')));
    expect(text, isNot(contains(base64Encode(shared))));
    expect(text, isNot(contains('AB00000000000001')));
    expect(adapter.requests.length, 2);
  });
  test('invalid input and queries without login never leave the device',
      () async {
    await expectLater(client.sendSms('not-a-phone'),
        throwsA(isA<OfficialAccountException>()));
    await expectLater(client.login('13800000000', '123456'),
        throwsA(isA<OfficialAccountException>()));
    await expectLater(
        client.loadBindings(), throwsA(isA<OfficialAccountException>()));
    expect(adapter.requests, isEmpty);
  });
  test('HTTP failures do not expose request or response credentials', () async {
    adapter.respond = (r) => response(
        {'code': '401', 'msg': 'test-only-session and 1234'},
        status: 401);
    try {
      await client.login('13800000000', '1234');
      fail('must reject');
    } on OfficialAccountException catch (error) {
      expect(error.message, startsWith('验证码登录失败（HTTP 401'));
      expect(error.message, isNot(contains('test-only-session')));
      expect(error.message, isNot(contains('1234')));
      expect(client.isLoggedIn, false);
    }
  });
  test(
      'device 401 reports its stage and advertised scheme without leaking body or retrying',
      () async {
    await client.login('13800000000', '1234');
    adapter.respond = (r) => ResponseBody.fromString(
            'Jwt is missing test-only-session 1234', 401,
            headers: {
              'www-authenticate': [
                'Basic realm="private-response-value"',
                'Bearer realm="private-response-value"'
              ]
            });
    try {
      await client.loadBindings();
      fail('must reject');
    } on OfficialAccountException catch (error) {
      expect(error.message, contains('读取设备列表失败（HTTP 401）'));
      expect(error.message, isNot(contains('没有该接口权限')));
      final text = '${error.message}\n${client.diagnostics.join("\n")}';
      expect(text, contains('服务端认证方式 Bearer'));
      for (final sensitive in [
        'test-only-session',
        '1234',
        'private-response-value',
        'Jwt is missing'
      ]) {
        expect(text, isNot(contains(sensitive)));
      }
    }
    expect(adapter.requests.length, 2);
  });
  test(
      'SMS rejection and device forbidden remain distinct; only numeric business codes survive',
      () async {
    adapter.respond = (r) => response(
        {'code': '40301', 'msg': 'secret-code-from-server'},
        status: 403);
    await expectLater(
        client.sendSms('13800000000'),
        throwsA(isA<OfficialAccountException>().having((e) => e.message,
            'stage', contains('获取验证码失败（HTTP 403；业务码 40301）'))));
    adapter.respond = (r) => response({
          'code': '200',
          'data': {'jwtToken': 'test-only-session', 'id': '123'}
        });
    await client.login('13800000000', '1234');
    adapter.respond = (r) => response(
        {'code': 'secret-code-from-server', 'msg': 'sensitive-body'},
        status: 403);
    await expectLater(
        client.loadBindings(),
        throwsA(isA<OfficialAccountException>().having(
            (e) => e.message, 'stage', contains('读取设备列表失败（HTTP 403）'))));
    expect(client.diagnostics.join('\n'),
        isNot(contains('secret-code-from-server')));
    expect(adapter.requests.length, 3);
  });
  test('invalid session headers cannot become a login', () async {
    adapter.respond = (r) => response({
          'code': '200',
          'data': {'jwtToken': 'bad\r\nheader', 'id': '123'}
        });
    await expectLater(client.login('13800000000', '1234'),
        throwsA(isA<OfficialAccountException>()));
    expect(client.isLoggedIn, false);
  });
  test('duplicate records, missing keys and unknown profiles are never guessed',
      () async {
    await client.login('13800000000', '1234');
    adapter.respond = (r) => response({
          'code': '200',
          'data': {
            'deviceList': [
              record(),
              record(),
              record(sn: 'AB00000000000002', type: 'UNKNOWN'),
              record(sn: 'AB00000000000003', secret: 'redacted'),
            ]
          }
        });
    expect(await client.loadBindings(), isEmpty);
    expect(client.totalDevices, 4);
  });
  test('a different local key is never overwritten', () async {
    final binding = OwnedRecorderBinding.fromAccountRecord(record())!;
    final original = base64Encode(List.generate(32, (i) => i + 1));
    final keys = MemoryKeyStore()..value = original;
    await expectLater(binding.saveForDevice(keys, 'device'), throwsStateError);
    expect(keys.value, original);
    expect(keys.writes, 0);
    binding.clear();
    expect(
        binding.matches(binding.serialNumber, RecorderProtocol.telink), false);
  });
  test(
      'owned device without sharedSecret reports field absence without exposing data',
      () async {
    await client.login('13800000000', '1234');
    adapter.respond = (r) => response({
          'code': '000000',
          'data': {
            'deviceList': [
              {
                'externalDeviceId': 'AB00000000000001',
                'deviceType': 'TELINK',
                'extInfo': {
                  'mac': 'private-mac-value',
                  'uuid': 'private-uuid-value'
                }
              }
            ]
          }
        });
    expect(await client.loadBindings(), isEmpty);
    expect(client.totalDevices, 1);
    expect(client.missingSharedSecretDevices, 1);
    final text = client.diagnostics.join('\n');
    expect(text, contains('sharedSecret 字段缺失 1'));
    expect(text, isNot(contains('private-mac-value')));
    expect(text, isNot(contains('private-uuid-value')));
  });
  test('a duplicate SN with missing key still makes the other record ambiguous',
      () async {
    await client.login('13800000000', '1234');
    adapter.respond = (r) => response({
          'code': '000000',
          'data': {
            'deviceList': [
              record(),
              {
                'externalDeviceId': 'AB00000000000001',
                'deviceType': 'AI_NOTE_6095',
                'extInfo': {}
              }
            ]
          }
        });
    expect(await client.loadBindings(), isEmpty);
    expect(client.totalDevices, 2);
  });
  test('late response after closing cannot restore the session', () async {
    final pending = Completer<ResponseBody>();
    adapter.respond = (r) => pending.future;
    final login = client.login('13800000000', '1234');
    await Future<void>.delayed(Duration.zero);
    client.close();
    pending.complete(response({
      'code': '200',
      'data': {'jwtToken': 'test-only-session', 'id': '123'}
    }));
    await expectLater(login, throwsA(isA<OfficialAccountException>()));
    expect(client.isLoggedIn, false);
  });

  test(
      'selected owned device scopes real check and bind requests; credentials stay private',
      () async {
    await client.login('13800000000', '1234');
    await client.loadBindings();
    final session = client.sessionForDevice(client.devices.single);
    adapter.respond = (r) => r.path.endsWith('/check')
        ? response({
            'code': '000000',
            'data': {'hmac': 'test-only-issued-hmac'}
          })
        : response({'code': '000000'});
    final hmac = await session.verifier(
        checkContent: 'test-only-fresh-challenge',
        mac: '11:22:33:44:55:66',
        sn: 'AB00000000000001');
    expect(hmac, 'test-only-issued-hmac');
    expect(adapter.requests.last.data, {
      'checkContent': 'test-only-fresh-challenge',
      'mac': '11:22:33:44:55:66',
      'sn': 'AB00000000000001'
    });
    await session.committer(
        sn: 'AB00000000000001',
        mac: '11:22:33:44:55:66',
        sharedSecret: base64Encode(shared));
    expect(adapter.requests.last.uri.path,
        '/api/device/toc/externalDeviceBind/bind');
    expect(adapter.requests.last.data, {
      'deviceId': 'AB00000000000001',
      'deviceName': 'Test recorder',
      'extInfo': {
        'mac': '11:22:33:44:55:66',
        'sharedSecret': base64Encode(shared)
      }
    });
    final count = adapter.requests.length;
    await expectLater(
        session.verifier(
            checkContent: 'challenge', mac: 'mac', sn: 'AB00000000000002'),
        throwsA(isA<OfficialAccountException>()));
    expect(adapter.requests.length, count);
    final diagnostic = client.diagnostics.join('\n');
    client.close();
    await expectLater(
        session.verifier(
            checkContent: 'challenge', mac: 'mac', sn: 'AB00000000000001'),
        throwsA(isA<OfficialAccountException>()));
    expect(adapter.requests.length, count);
    for (final value in [
      'test-only-issued-hmac',
      'test-only-fresh-challenge',
      base64Encode(shared)
    ]) {
      expect(diagnostic, isNot(contains(value)));
    }
  });

  test(
      'account key restore requires observed SN and protocol; never replaces an existing identity',
      () async {
    await client.login('13800000000', '1234');
    await client.loadBindings();
    final session = client.sessionForDevice(client.devices.single);
    expect(session.hasRecoverableKey, true);
    final store = MemoryKeyStore();
    await expectLater(
        session.restoreKey!(
            'recorder', RecorderProtocol.telink, 'AB00000000000002', store),
        throwsA(isA<OfficialAccountException>()));
    expect(store.value, isNull);
    expect(
        await session.restoreKey!(
            'recorder', RecorderProtocol.aiNote6095, 'AB00000000000001', store),
        false);
    expect(store.value, isNull);
    expect(
        await session.restoreKey!(
            'recorder', RecorderProtocol.telink, 'AB00000000000001', store),
        true);
    expect(store.value, base64Encode(shared));
    store.value = base64Encode(List.filled(32, 42));
    await expectLater(
        session.restoreKey!(
            'recorder', RecorderProtocol.telink, 'AB00000000000001', store),
        throwsStateError);
    expect(store.value, base64Encode(List.filled(32, 42)));
  });

  test(
      'missing cloud key still permits owned-device selection, duplicate SN does not',
      () async {
    await client.login('13800000000', '1234');
    adapter.respond = (_) => response({
          'code': '000000',
          'data': {
            'deviceList': [
              {
                'externalDeviceId': 'AB00000000000001',
                'externalDeviceName': 'My recorder',
                'extInfo': {}
              }
            ]
          }
        });
    expect(await client.loadBindings(), isEmpty);
    final selected = client.devices.single;
    final oldSession = client.sessionForDevice(selected);
    expect(oldSession.hasRecoverableKey, false);
    adapter.respond = (_) => response({
          'code': '000000',
          'data': {'deviceList': []}
        });
    await client.loadBindings();
    expect(() => client.sessionForDevice(selected),
        throwsA(isA<OfficialAccountException>()));
    await expectLater(
        oldSession.verifier(
            checkContent: 'challenge', mac: 'mac', sn: selected.serialNumber),
        throwsA(isA<OfficialAccountException>()));
  });
}

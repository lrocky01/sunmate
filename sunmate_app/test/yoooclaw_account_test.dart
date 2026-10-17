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
ResponseBody response(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body), status, headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
Map<String, dynamic> record({String type = 'TELINK', String sn = 'AB00000000000001', String? secret}) => {
  'externalDeviceId': sn, 'externalDeviceName': 'Test recorder', 'deviceType': type,
  'extInfo': {'sharedSecret': secret ?? base64Encode(shared), 'mac': 'test-only-mac'},
};
void main() {
  late AccountHttpAdapter adapter;
  late YoooClawAccount client;
  setUp(() {
    adapter = AccountHttpAdapter();
    client = YoooClawAccount(http: Dio()..httpClientAdapter = adapter);
    adapter.respond = (r) {
      if (r.path.endsWith('/send-sms')) return response({'code': '0'});
      if (r.path.endsWith('/login')) return response({'code': '200', 'data': {
        'jwtToken': 'Bearer test-only-session', 'id': '1000000000000000001'}});
      return response({'code': '000000', 'data': {'deviceList': [record()]}});
    };
  });
  tearDown(() => client.close());
  test('normal website login and account recovery follow observed contracts', () async {
    await client.sendSms('13800000000');
    await client.login('13800000000', '1234');
    final bindings = await client.loadBindings();
    expect(adapter.requests.map((r) => r.uri.host), ['www.yoooclaw.com', 'www.yoooclaw.com', 'openclaw-service.yoooclaw.com']);
    expect(adapter.requests[0].data, {'phone': '13800000000', 'channel': 6});
    expect(adapter.requests[1].data, {'phone': '13800000000', 'smsCode': '1234', 'channel': 6});
    expect(adapter.requests[2].uri.path, '/api/device/toc/homePage/pub/index');
    expect(adapter.requests[2].headers['Authorization'], 'test-only-session');
    expect(adapter.requests[2].headers['app_key'], 'yoooclaw');
    expect(adapter.requests[0].headers.containsKey('Authorization'), false);
    expect(adapter.requests.every((r) => !r.followRedirects), true);
    expect(bindings.single.matches('ab00000000000001', RecorderProtocol.telink), true);
    final keys = MemoryKeyStore();
    await bindings.single.saveForDevice(keys, 'ios-selected-peripheral');
    expect(keys.value, base64Encode(shared));
    expect(bindings.single.toString(), isNot(contains(base64Encode(shared))));
  });
  test('invalid input and queries without login never leave the device', () async {
    await expectLater(client.sendSms('not-a-phone'), throwsA(isA<OfficialAccountException>()));
    await expectLater(client.login('13800000000', '123456'), throwsA(isA<OfficialAccountException>()));
    await expectLater(client.loadBindings(), throwsA(isA<OfficialAccountException>()));
    expect(adapter.requests, isEmpty);
  });
  test('HTTP failures do not expose request or response credentials', () async {
    adapter.respond = (r) => response({'code': '401', 'msg': 'test-only-session and 1234'}, status: 401);
    try {
      await client.login('13800000000', '1234');
      fail('must reject');
    } on OfficialAccountException catch (error) {
      expect(error.message, isNot(contains('test-only-session')));
      expect(error.message, isNot(contains('1234')));
      expect(client.isLoggedIn, false);
    }
  });
  test('invalid session headers cannot become a login', () async {
    adapter.respond = (r) => response({'code': '200', 'data': {'jwtToken': 'bad\r\nheader', 'id': '123'}});
    await expectLater(client.login('13800000000', '1234'), throwsA(isA<OfficialAccountException>()));
    expect(client.isLoggedIn, false);
  });
  test('duplicate records, missing keys and unknown profiles are never guessed', () async {
    await client.login('13800000000', '1234');
    adapter.respond = (r) => response({'code': '200', 'data': {'deviceList': [
      record(), record(), record(sn: 'AB00000000000002', type: 'UNKNOWN'),
      record(sn: 'AB00000000000003', secret: 'redacted'),
    ]}});
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
    expect(binding.matches(binding.serialNumber, RecorderProtocol.telink), false);
  });
  test('late response after closing cannot restore the session', () async {
    final pending = Completer<ResponseBody>();
    adapter.respond = (r) => pending.future;
    final login = client.login('13800000000', '1234');
    await Future<void>.delayed(Duration.zero);
    client.close();
    pending.complete(response({'code': '200', 'data': {'jwtToken': 'test-only-session', 'id': '123'}}));
    await expectLater(login, throwsA(isA<OfficialAccountException>()));
    expect(client.isLoggedIn, false);
  });
}

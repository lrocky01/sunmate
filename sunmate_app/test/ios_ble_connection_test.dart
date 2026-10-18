import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ble/ios_ble_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('sunmate/ble_connection');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('ANCS request is scoped to selected peripheral before connect',
      () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final bridge = IosBleConnection(isSupported: true);
    await bridge.configure('selected-peripheral', requiresAncs: true);
    expect(calls.single.method, 'configure');
    expect(calls.single.arguments,
        {'remote_id': 'selected-peripheral', 'requires_ancs': true});
  });
  test('diagnostics retain CoreBluetooth domain rather than guessing HCI',
      () async {
    messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
              'event': 'disconnected',
              'error_domain': 'CBErrorDomain',
              'error_code': 6,
              'error_description': 'The connection has timed out unexpectedly.',
              'ancs_authorized': true,
            });
    final snapshot =
        await IosBleConnection(isSupported: true).diagnostics('device');
    expect(snapshot['error_domain'], 'CBErrorDomain');
    expect(snapshot['error_code'], 6);
    expect(snapshot['ancs_authorized'], true);
  });
  test('non-iOS performs no native ANCS operation', () async {
    messenger.setMockMethodCallHandler(
        channel, (_) async => fail('Unexpected native call'));
    final bridge = IosBleConnection(isSupported: false);
    await bridge.configure('device', requiresAncs: true);
    expect(await bridge.diagnostics('device'), isEmpty);
  });
  test(
      'a missing native bridge response cannot block connection diagnostics forever',
      () async {
    messenger.setMockMethodCallHandler(
        channel, (_) => Completer<Object?>().future);
    final bridge = IosBleConnection(
        isSupported: true, timeout: const Duration(milliseconds: 20));
    await expectLater(bridge.configure('device', requiresAncs: true),
        throwsA(isA<TimeoutException>()));
    await expectLater(
        bridge.diagnostics('device'), throwsA(isA<TimeoutException>()));
  });
}

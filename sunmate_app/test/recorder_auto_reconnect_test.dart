import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/ble_protocol.dart';
import 'package:sunmate_app/core/ble/recorder_authentication.dart';
import 'package:sunmate_app/core/ble/recorder_saved_identity.dart';
import 'package:sunmate_app/core/hardware/hardware_device_driver.dart';
import 'package:sunmate_app/core/hardware/hardware_device_factory.dart';
import 'package:sunmate_app/providers/device_provider.dart';
import 'package:sunmate_app/views/recorder_connection_lifecycle.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_authentication_test.dart' show shared;

class LifecycleTestNotifier extends DeviceNotifier {
  final calls = <bool>[];
  LifecycleTestNotifier(super.factory);
  @override
  Future<void> setAppForeground(bool foreground) async {
    calls.add(foreground);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = TestBlePlatform();
  late HardwareDeviceFactory factory;
  late DeviceNotifier notifier;
  late StreamController<BluetoothAdapterState> adapters;
  late BluetoothDevice device;
  var number = 0;
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    FlutterBluePlusPlatform.instance = platform;
    factory = HardwareDeviceFactory();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    platform.reset();
    await factory.switchDriver(HardwareDeviceType.ainote6095Ble);
    device = BluetoothDevice.fromId(
        '30000000-0000-0000-0000-${(++number).toString().padLeft(12, '0')}');
    adapters = StreamController<BluetoothAdapterState>.broadcast();
    notifier = DeviceNotifier(factory, adapterStates: adapters.stream);
  });
  tearDown(() async {
    notifier.dispose();
    await factory.bleDriver.disconnect();
    await adapters.close();
  });
  Future<void> seed({bool verified = true, bool withKey = true}) async {
    final prefs = await SharedPreferences.getInstance();
    if (verified) {
      await prefs.setString(
          'sunmate_verified_ble_device_id_v2', device.remoteId.str);
      await prefs.setString(
          'sunmate_verified_ble_device_sn_v2', 'AB00000000000001');
    }
    await RecorderIdentityStore().save(RecorderSavedIdentity(
        remoteId: device.remoteId.str,
        serialNumber: 'AB00000000000001',
        deviceName: 'Test recorder',
        protocol: RecorderProtocol.telink,
        previouslyVerified: verified));
    if (withKey)
      await SecureRecorderKeyStore().write(
          device.remoteId.str, RecorderProtocol.telink, base64Encode(shared));
    platform.authenticate = true;
  }

  Future<void> waitFor(bool Function() ready) async {
    final end = DateTime.now().add(const Duration(seconds: 2));
    while (!ready()) {
      if (DateTime.now().isAfter(end))
        fail('Timed out waiting for reconnect state');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  test(
      'cold launch reconnects saved verified identity with real AES and no binding',
      () async {
    await seed();
    await notifier.setAppForeground(true);
    adapters.add(BluetoothAdapterState.on);
    await waitFor(() => notifier.state.isConnected);
    expect(platform.connectCount, 1);
    final methods = platform.writes
        .where((w) => w.value.length > 2 && w.value[1] == 0x30)
        .map((w) => jsonDecode(utf8.decode(w.value.sublist(2)))['method']);
    expect(methods, contains('verifyIdentity'));
    expect(methods, isNot(contains('bindRequest')));
    expect(
        await SecureRecorderKeyStore()
            .read(device.remoteId.str, RecorderProtocol.telink),
        base64Encode(shared));
  });

  for (final pending in [false, true]) {
    test(
        'no verified key or only pending identity does not start Bluetooth: pending=$pending',
        () async {
      await seed(verified: !pending, withKey: pending);
      await notifier.setAppForeground(true);
      expect(adapters.hasListener, false);
      adapters.add(BluetoothAdapterState.on);
      await settle();
      expect(platform.connectCount, 0);
    });
  }

  test('Bluetooth off then on retries once while foreground', () async {
    await seed();
    await notifier.setAppForeground(true);
    adapters.add(BluetoothAdapterState.off);
    await settle();
    expect(platform.connectCount, 0);
    adapters.add(BluetoothAdapterState.on);
    await waitFor(() => notifier.state.isConnected);
    adapters.add(BluetoothAdapterState.on);
    await notifier.setAppForeground(true);
    await settle();
    expect(platform.connectCount, 1);
  });

  test('background skips connection and foreground resumes it', () async {
    await seed();
    await notifier.setAppForeground(true);
    await notifier.setAppForeground(false);
    adapters.add(BluetoothAdapterState.on);
    await settle();
    expect(platform.connectCount, 0);
    await notifier.setAppForeground(true);
    await waitFor(() => notifier.state.isConnected);
    expect(platform.connectCount, 1);
  });

  test(
      'repeated resume and adapter callbacks cannot duplicate a pending connect',
      () async {
    await seed();
    platform.connectGate = Completer<void>();
    await notifier.setAppForeground(true);
    adapters.add(BluetoothAdapterState.on);
    await waitFor(() => platform.connectCount == 1);
    adapters.add(BluetoothAdapterState.on);
    await notifier.setAppForeground(true);
    await settle();
    expect(platform.connectCount, 1);
    platform.connectGate!.complete();
    await waitFor(() => notifier.state.isConnected);
  });

  test(
      'manual disconnect remains disconnected on subsequent foreground and Bluetooth events',
      () async {
    await seed();
    await notifier.setAppForeground(true);
    adapters.add(BluetoothAdapterState.on);
    await waitFor(() => notifier.state.isConnected);
    await notifier.disconnectDevice();
    await notifier.setAppForeground(false);
    await notifier.setAppForeground(true);
    adapters.add(BluetoothAdapterState.off);
    adapters.add(BluetoothAdapterState.on);
    await settle();
    expect(platform.connectCount, 1);
    expect(notifier.state.isConnected, false);
  });

  test('switching to phone microphone blocks automatic BLE takeover', () async {
    await seed();
    await notifier.switchDriverType(HardwareDeviceType.phoneInternalMic);
    await notifier.setAppForeground(true);
    adapters.add(BluetoothAdapterState.on);
    await settle();
    expect(platform.connectCount, 0);
    expect(
        factory.activeDriver.deviceType, HardwareDeviceType.phoneInternalMic);
  });

  test(
      'key removed after setup prevents automatic connection and never writes replacement',
      () async {
    await seed();
    await notifier.setAppForeground(true);
    FlutterSecureStorage.setMockInitialValues({});
    adapters.add(BluetoothAdapterState.on);
    await settle();
    expect(platform.connectCount, 0);
    expect(
        await SecureRecorderKeyStore()
            .read(device.remoteId.str, RecorderProtocol.telink),
        isNull);
  });

  test('explicit reconnect guard prevents late startup after user cancellation',
      () async {
    await seed();
    expect(
        await factory.bleDriver
            .reconnectVerifiedDeviceAutomatically(shouldConnect: () => false),
        false);
    expect(platform.connectCount, 0);
  });

  test('old verified preference cannot promote a pending route', () async {
    await seed();
    final prefs = await SharedPreferences.getInstance();
    final rows = prefs.getStringList(RecorderIdentityStore.storageKey)!;
    final row = jsonDecode(rows.single) as Map<String, dynamic>;
    row['verified'] = false;
    await prefs
        .setStringList(RecorderIdentityStore.storageKey, [jsonEncode(row)]);
    await notifier.setAppForeground(true);
    expect(adapters.hasListener, false);
    expect(platform.connectCount, 0);
  });

  test('damaged route keeps key and does not trigger startup Bluetooth',
      () async {
    await seed();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(RecorderIdentityStore.storageKey, ['{broken']);
    await notifier.setAppForeground(true);
    expect(adapters.hasListener, false);
    expect(
        await SecureRecorderKeyStore()
            .read(device.remoteId.str, RecorderProtocol.telink),
        base64Encode(shared));
  });

  test('incorrect saved key fails real AES and never triggers new binding',
      () async {
    await seed();
    final other = base64Encode(List<int>.filled(32, 7));
    await SecureRecorderKeyStore()
        .write(device.remoteId.str, RecorderProtocol.telink, other);
    await notifier.setAppForeground(true);
    adapters.add(BluetoothAdapterState.on);
    await waitFor(() => platform.connectCount == 1);
    await waitFor(() => !factory.bleDriver.isConnecting);
    expect(notifier.state.isConnected, false);
    final methods = platform.writes
        .where((w) => w.value.length > 2 && w.value[1] == 0x30)
        .map((w) => jsonDecode(utf8.decode(w.value.sublist(2)))['method']);
    expect(methods, contains('verifyIdentity'));
    expect(methods, isNot(contains('bindRequest')));
    expect(
        await SecureRecorderKeyStore()
            .read(device.remoteId.str, RecorderProtocol.telink),
        other);
  });

  testWidgets(
      'lifecycle bridge forwards launch resume background without connection UI',
      (tester) async {
    final bridge = LifecycleTestNotifier(factory);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(ProviderScope(
        overrides: [deviceProvider.overrideWith((ref) => bridge)],
        child: const MaterialApp(
            home: RecorderConnectionLifecycle(child: Text('Home')))));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(bridge.calls, [true, false, true]);
    expect(find.text('Home'), findsOneWidget);
    expect(platform.connectCount, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    expect(bridge.calls.last, false);
  });
}

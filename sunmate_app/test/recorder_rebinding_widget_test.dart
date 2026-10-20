import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/recorder_authentication.dart';
import 'package:sunmate_app/core/ble/recorder_saved_identity.dart';
import 'package:sunmate_app/core/ble/yoooclaw_account.dart';
import 'package:sunmate_app/providers/device_provider.dart';
import 'package:sunmate_app/views/home_page.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_portable_backup_test.dart' show advertisement;
import 'recorder_management_widget_test.dart'
    show ManagementNotifier, captureUi, screenshot;
import 'yoooclaw_account_test.dart'
    show AccountHttpAdapter, MemoryOfficialSessionStore, record, response;

class RebindingWidgetNotifier extends ManagementNotifier {
  int connects = 0;
  RecorderAccountSession? selected;
  RebindingWidgetNotifier() : super(ready: false);
  @override
  Future<List<RecorderRecoveryCandidate>> recoveryCandidates({
    RecorderAccountSession? accountSession,
    bool includeSystemDevices = true,
  }) async =>
      [];
  @override
  Future<bool> connectDevice(
    BluetoothDevice device, {
    RecorderAccountSession? accountSession,
    RecorderRecoveryCandidate? recoveryCandidate,
  }) async {
    connects++;
    selected = accountSession;
    return false;
  }

  @override
  Stream<String> get logStream => const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = TestBlePlatform();
  setUpAll(() async {
    FlutterBluePlusPlatform.instance = platform;
    if (captureUi) {
      for (final entry in {
        'RebindingFixture':
            '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
        'MaterialIcons':
            '/private/tmp/sunmate-flutter-sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(entry.key)
              ..addFont(File(entry.value)
                  .readAsBytes()
                  .then((b) => b.buffer.asByteData())))
            .load();
      }
    }
  });
  setUp(() {
    platform.reset();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  Future<void> advance(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  for (final size in [const Size(360, 640), const Size(390, 844)]) {
    testWidgets(
        'explicit rebind asks about selected SN before any connection at $size',
        (tester) async {
      final http = AccountHttpAdapter();
      http.respond = (r) => r.path.endsWith('/loginOrRegister')
          ? response({
              'code': '000000',
              'data': {'jwtToken': 'test-only-token', 'id': 'test-user'}
            })
          : response({
              'code': '000000',
              'data': {'deviceList': []}
            });
      final account = YoooClawAccount(
          http: Dio()..httpClientAdapter = http,
          sessionStore: MemoryOfficialSessionStore());
      await tester.runAsync(() async {
        await account.login('13800000000', '1234');
        await account.loadBindings();
      });
      final notifier = RebindingWidgetNotifier();
      final key = GlobalKey();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ProviderScope(
          overrides: [deviceProvider.overrideWith((ref) => notifier)],
          child: RepaintBoundary(
              key: key,
              child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: ThemeData(
                      useMaterial3: true,
                      fontFamily: captureUi ? 'RebindingFixture' : null,
                      colorScheme: ColorScheme.fromSeed(
                          seedColor: const Color(0xFFFF8C00))),
                  home: Scaffold(
                      body: RecorderConnectionSheet(account: account))))));
      await advance(tester);
      final entry = find.text('重新建立业务绑定（保留旧版本）');
      await tester.scrollUntilVisible(entry, 180,
          scrollable: find.byType(Scrollable).first);
      await advance(tester);
      await screenshot(tester, key, 'rebind-entry-${size.width.toInt()}');
      await tester.tap(entry);
      await advance(tester);
      expect(find.text('重新绑定录音卡'), findsOneWidget);
      expect(notifier.connects, 0);
      final device = BluetoothDevice.fromId(
          '80000000-0000-0000-0000-${size.width.toInt().toString().padLeft(12, '0')}');
      await platform.advertise(device.remoteId, advertisement());
      await advance(tester);
      final connect = find.text('重新绑定');
      await tester.tap(connect);
      await advance(tester);
      expect(find.text('重新建立业务绑定？'), findsOneWidget);
      expect(find.textContaining('AB00000000000001'), findsOneWidget);
      expect(find.textContaining('可能改变卡内密钥，旧备份不保证继续有效'), findsOneWidget);
      expect(find.textContaining('不能回滚卡内密钥'), findsOneWidget);
      expect(notifier.connects, 0);
      await screenshot(tester, key, 'rebind-confirm-${size.width.toInt()}');
      await tester.tap(find.text('取消'));
      await advance(tester);
      expect(notifier.connects, 0);
      await tester.tap(connect);
      await advance(tester);
      await tester.tap(find.text('确认重新绑定'));
      await advance(tester);
      expect(notifier.connects, 1);
      expect(notifier.selected!.reestablishBinding, true);
      expect(notifier.selected!.newDeviceIdentity!.serialNumber,
          'AB00000000000001');
      expect(
          http.requests.where((r) =>
              r.path.endsWith('/check') ||
              r.path.endsWith('/bind') ||
              r.path.endsWith('/unbind')),
          isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await advance(tester);
    });
  }

  testWidgets(
      'fresh list containing target SN stops before confirmation or BLE',
      (tester) async {
    var listed = false;
    final http = AccountHttpAdapter();
    http.respond = (r) => r.path.endsWith('/loginOrRegister')
        ? response({
            'code': '000000',
            'data': {'jwtToken': 'test-only-token', 'id': 'test-user'}
          })
        : response({
            'code': '000000',
            'data': {
              'deviceList': [if (listed) record()]
            }
          });
    final account = YoooClawAccount(
        http: Dio()..httpClientAdapter = http,
        sessionStore: MemoryOfficialSessionStore());
    await tester.runAsync(() async {
      await account.login('13800000000', '1234');
      await account.loadBindings();
    });
    final notifier = RebindingWidgetNotifier();
    await tester.pumpWidget(ProviderScope(
        overrides: [deviceProvider.overrideWith((ref) => notifier)],
        child: MaterialApp(
            home: Scaffold(body: RecorderConnectionSheet(account: account)))));
    await advance(tester);
    final entry = find.text('重新建立业务绑定（保留旧版本）');
    await tester.scrollUntilVisible(entry, 180,
        scrollable: find.byType(Scrollable).first);
    await advance(tester);
    await tester.tap(entry);
    await advance(tester);
    await platform.advertise(
        const DeviceIdentifier('80000000-0000-0000-0000-000000000099'),
        advertisement());
    await advance(tester);
    listed = true;
    await tester.tap(find.text('重新绑定'));
    await advance(tester);
    expect(find.text('重新建立业务绑定？'), findsNothing);
    expect(find.textContaining('该 SN 已在账号设备列表中'), findsOneWidget);
    expect(notifier.connects, 0);
    await tester.pumpWidget(const SizedBox());
    await advance(tester);
  });
}

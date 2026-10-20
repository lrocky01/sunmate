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
import 'package:sunmate_app/views/recorder_account_sheet.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_portable_backup_test.dart' show advertisement;
import 'recorder_management_widget_test.dart'
    show ManagementNotifier, captureUi, screenshot;
import 'yoooclaw_account_test.dart'
    show AccountHttpAdapter, MemoryOfficialSessionStore, record, response;

class CredentialWidgetNotifier extends ManagementNotifier {
  int connections = 0;
  RecorderAccountSession? selected;
  CredentialWidgetNotifier() : super(ready: false);
  @override
  Future<bool> connectDevice(BluetoothDevice device,
      {RecorderAccountSession? accountSession,
      RecorderRecoveryCandidate? recoveryCandidate}) async {
    connections++;
    selected = accountSession;
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = TestBlePlatform();
  setUpAll(() async {
    FlutterBluePlusPlatform.instance = platform;
    if (captureUi) {
      for (final item in {
        'CredentialFixture':
            '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
        'MaterialIcons':
            '/private/tmp/sunmate-flutter-sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'
      }.entries) {
        await (FontLoader(item.key)
              ..addFont(File(item.value)
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
        'explicit account source at $size confirms and enters isolated scan',
        (tester) async {
      final adapter = AccountHttpAdapter();
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
      final client = YoooClawAccount(
          http: Dio()..httpClientAdapter = adapter,
          sessionStore: MemoryOfficialSessionStore());
      await tester.runAsync(() async {
        await client.login('13800000000', '1234');
        await client.loadBindings();
      });
      final notifier = CredentialWidgetNotifier();
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
                      fontFamily: captureUi ? 'CredentialFixture' : null,
                      colorScheme: ColorScheme.fromSeed(
                          seedColor: const Color(0xFFFF8C00))),
                  home: Scaffold(
                      body: RecorderAccountSheet(
                          account: client,
                          onSelectDevice: (_) {
                            fail('normal recovery must not be selected');
                          }))))));
      await advance(tester);
      final action = find.text('使用账号资料验证');
      await tester.scrollUntilVisible(action, 200, scrollable: find.byType(Scrollable).first);
      await advance(tester);
      await tester.tap(action);
      await advance(tester);
      expect(find.text('使用账号资料验证？'), findsOneWidget);
      expect(find.textContaining('不会解绑、重新协商或删除旧版本'), findsOneWidget);
      await screenshot(
          tester, key, 'credential-account-confirm-${size.width.toInt()}');
      await tester.tap(find.text('取消'));
      await advance(tester);
      expect(notifier.connections, 0);
      await tester.tap(action);
      await advance(tester);
      await tester.tap(find.text('继续验证'));
      await advance(tester);
      expect(find.text('验证候选凭据'), findsOneWidget);
      expect(find.textContaining('连续点击5次'), findsNothing);
      expect(notifier.connections, 0);
      await screenshot(
          tester, key, 'credential-account-scan-${size.width.toInt()}');
      final device = BluetoothDevice.fromId(
          '60000000-0000-0000-0000-${size.width.toInt().toString().padLeft(12, '0')}');
      await platform.advertise(
          device.remoteId, advertisement('AB00000000000002'));
      await advance(tester);
      expect(find.text('连接验证'), findsNothing);
      await platform.advertise(device.remoteId, advertisement());
      await advance(tester);
      await tester.tap(find.text('连接验证'));
      await advance(tester);
      expect(notifier.connections, 1);
      expect(notifier.selected!.credentialCandidate, true);
      expect(notifier.selected!.hasRecoverableKey, true);
      expect(notifier.selected!.newDeviceIdentity, isNull);
      expect(find.textContaining('验证未完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await advance(tester);
      expect(client.isLoggedIn, true);
      await FlutterBluePlus.stopScan();
    });
  }
}

import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/recorder_connection_details.dart';
import 'package:sunmate_app/core/hardware/hardware_device_factory.dart';
import 'package:sunmate_app/models/device_status.dart';
import 'package:sunmate_app/providers/device_provider.dart';
import 'package:sunmate_app/views/recorder_management_page.dart';
import 'package:sunmate_app/views/home_page.dart';
import 'ble_connection_test.dart' show TestBlePlatform;

class ManagementNotifier extends DeviceNotifier {
  bool notificationRequest = true;
  bool rejectSave = false;
  bool ready;
  int changes = 0;
  ManagementNotifier({this.ready = true}) : super(HardwareDeviceFactory());
  @override
  DeviceStatus get bleDeviceStatus => DeviceStatus(
      isConnected: ready,
      deviceName: 'C·ONE-test',
      snNumber: ready ? 'AB00000000000001' : '--',
      batteryLevel: ready ? 76 : 0);
  @override
  RecorderConnectionDetails get bleConnectionDetails =>
      RecorderConnectionDetails(
          linkConnected: ready,
          gattDiscovered: ready,
          identityVerified: ready,
          businessReady: ready,
          channelsReady: ready,
          localIdentityLoaded: ready,
          protocol: ready ? 'telink' : '未识别',
          ancsAuthorized: ready ? true : null);
  @override
  bool get isBleLinkConnected => ready;
  @override
  bool get isBleConnecting => false;
  @override
  bool get supportsAncsRequestConfiguration => true;
  @override
  bool get requiresAncs => notificationRequest;
  @override
  bool? get ancsAuthorized => ready ? true : null;
  @override
  String get bleAudioStatistics => '通知=393；接收字节=17380；会话外忽略=0；最近完整录音帧=393';
  @override
  Future<bool> configureBleAncsRequest(bool value) async {
    changes++;
    if (rejectSave) return false;
    notificationRequest = value;
    state = state.copyWith(deviceName: 'refresh $changes');
    return true;
  }
}

const captureUi = bool.fromEnvironment('SUNMATE_CAPTURE_MANAGEMENT_UI');

Future<void> screenshot(WidgetTester tester, GlobalKey key, String name) async {
  if (!captureUi) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final picture = await boundary.toImage(pixelRatio: 1);
    final bytes = (await picture.toByteData(format: ui.ImageByteFormat.png))!;
    final folder = Directory(
        '/Users/m/Documents/VS/sunmate/build_output/recorder-management-local');
    await folder.create(recursive: true);
    await File('${folder.path}/$name.png')
        .writeAsBytes(bytes.buffer.asUint8List());
    picture.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterBluePlusPlatform.instance = TestBlePlatform();
    if (captureUi) {
      for (final entry in {
        'ManagementFixture':
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

  for (final size in [const Size(360, 640), const Size(390, 844)]) {
    testWidgets(
        'management groups expose true device state and recording details at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final notifier = ManagementNotifier();
      final key = GlobalKey();
      await tester.pumpWidget(ProviderScope(
          overrides: [deviceProvider.overrideWith((ref) => notifier)],
          child: MaterialApp(
              theme: ThemeData(
                  useMaterial3: true,
                  fontFamily: captureUi ? 'ManagementFixture' : null,
                  colorScheme:
                      ColorScheme.fromSeed(seedColor: const Color(0xFFFF8C00))),
              home: RepaintBoundary(
                  key: key,
                  child: RecorderManagementPage(
                      onOpenConnection: () {},
                      onOpenDiagnostics: () {},
                      onOpenAccount: () {},
                      onOpenButtonSettings: () {})))));
      await tester.pumpAndSettle();
      expect(find.text('AB00000000000001'), findsOneWidget);
      expect(find.text('76%'), findsOneWidget);
      expect(find.text('已连接 · 身份已验证'), findsWidgets);
      await screenshot(tester, key, '${size.width.toInt()}-management');
      await tester.scrollUntilVisible(find.text('录音设置'), 180);
      await tester.pumpAndSettle();
      await tester.tap(find.text('录音设置'));
      await tester.pumpAndSettle();
      expect(find.textContaining('通知=393'), findsOneWidget);
      expect(find.text('当前状态：待命'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('蓝牙诊断'), 180);
      await tester.pumpAndSettle();
      await screenshot(tester, key, '${size.width.toInt()}-management-lower');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'notification preference has next-connection semantics and save errors',
      (tester) async {
    final notifier = ManagementNotifier();
    await tester.pumpWidget(ProviderScope(
        overrides: [deviceProvider.overrideWith((ref) => notifier)],
        child: const MaterialApp(home: RecorderNotificationSettingsPage())));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(notifier.notificationRequest, false);
    expect(find.textContaining('下次连接'), findsOneWidget);
    notifier.rejectSave = true;
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(notifier.notificationRequest, false);
    expect(find.text('保存未完成，请重试。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'account unbind and diagnostics entries delegate without automatic operations',
      (tester) async {
    final notifier = ManagementNotifier(ready: false);
    var accountOpens = 0;
    var diagnostics = 0;
    await tester.pumpWidget(ProviderScope(
        overrides: [deviceProvider.overrideWith((ref) => notifier)],
        child: MaterialApp(
            home: RecorderManagementPage(
                onOpenConnection: () {},
                onOpenDiagnostics: () => diagnostics++,
                onOpenAccount: () => accountOpens++,
                onOpenButtonSettings: () {}))));
    expect(find.text('未连接'), findsWidgets);
    expect(find.text('尚未取得'), findsOneWidget);
    expect(accountOpens, 0);
    await tester.scrollUntilVisible(find.text('蓝牙诊断'), 220);
    await tester.pumpAndSettle();
    await tester.tap(find.text('蓝牙诊断'));
    await tester.pump();
    expect(diagnostics, 1);
    expect(accountOpens, 0);
    await tester.scrollUntilVisible(find.text('管理账号绑定与解绑'), 220);
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理账号绑定与解绑'));
    await tester.pump();
    expect(accountOpens, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown hardware settings are explained without fake switches',
      (tester) async {
    final notifier = ManagementNotifier();
    await tester.pumpWidget(ProviderScope(
        overrides: [deviceProvider.overrideWith((ref) => notifier)],
        child: MaterialApp(
            home: RecorderManagementPage(
                onOpenConnection: () {},
                onOpenDiagnostics: () {},
                onOpenAccount: () {},
                onOpenButtonSettings: () {}))));
    await tester.scrollUntilVisible(find.text('固件升级'), 180);
    await tester.pumpAndSettle();
    await tester.tap(find.text('固件升级'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不会发送固件升级指令'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home opens management route and preserves diagnostic access', (tester) async {
    final notifier = ManagementNotifier();
    await tester.pumpWidget(ProviderScope(
      overrides: [deviceProvider.overrideWith((ref) => notifier)],
      child: const MaterialApp(home: HomePage())));
    await tester.tap(find.text('录音卡设置与诊断'));
    await tester.pumpAndSettle();
    expect(find.text('录音卡管理'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('蓝牙诊断'), 220);
    await tester.pumpAndSettle();
    await tester.tap(find.text('蓝牙诊断'));
    await tester.pumpAndSettle();
    expect(find.byType(BleDiagnosticsSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/hardware/recorder_hardware_settings.dart';
import 'package:sunmate_app/providers/device_provider.dart';
import 'package:sunmate_app/views/recorder_management_page.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_management_widget_test.dart'
    show ManagementNotifier, captureUi, screenshot;

class SettingsNotifier extends ManagementNotifier {
  final methods = <String>[];
  List<int> caps = [2001, 3001];
  int clicks = 2;
  bool led = true;
  bool recording = false;
  bool reply = true;
  bool acceptWrite = true;
  int revisions = 0;
  SettingsNotifier({super.ready});
  late final RecorderSettingsController settings = RecorderSettingsController(
      isReady: () => ready,
      send: (method, params) async {
        methods.add(method);
        if (method == 'getCapabilities') {
          settings.acceptCapabilities({'capabilities': caps});
        } else if (method == 'getStatus') {
          settings.acceptRecording(recording);
        } else if (method == 'getUserSettings' && reply) {
          settings.acceptSettings(
              {'mainKeyMultiClick': clicks, 'longRecordingLedEnabled': led});
        } else if (method == 'setUserSettings' && acceptWrite) {
          if (params['mainKeyMultiClick'] is int)
            clicks = params['mainKeyMultiClick'] as int;
          if (params['longRecordingLedEnabled'] is bool)
            led = params['longRecordingLedEnabled'] as bool;
        }
      },
      onChanged: () =>
          state = state.copyWith(deviceName: 'settings ${++revisions}'),
      timeout: const Duration(milliseconds: 100));
  @override
  RecorderHardwareSettings get recorderHardwareSettings => settings.snapshot;
  @override
  Future<bool> refreshRecorderHardwareSettings() => settings.refresh();
  @override
  Future<bool> setMeetingRecordingClicks(int count) =>
      settings.setClicks(count);
  @override
  Future<bool> setMeetingRecordingLed(bool enabled) => settings.setLed(enabled);
  @override
  void dispose() {
    settings.reset();
    super.dispose();
  }
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
                  .then((bytes) => bytes.buffer.asByteData())))
            .load();
      }
    }
  });
  Future<GlobalKey> open(WidgetTester tester, SettingsNotifier notifier) async {
    if (tester.view.physicalSize / tester.view.devicePixelRatio == const Size(800, 600)) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    final key = GlobalKey();
    await tester.pumpWidget(ProviderScope(
        overrides: [deviceProvider.overrideWith((ref) => notifier)],
        child: MaterialApp(
            theme: ThemeData(
                useMaterial3: true,
                fontFamily: captureUi ? 'ManagementFixture' : null,
                colorScheme:
                    ColorScheme.fromSeed(seedColor: const Color(0xffff8c00))),
            home: RepaintBoundary(
                key: key, child: const RecorderRecordingSettingsPage()))));
    await tester.pump();
    return key;
  }

  for (final size in [const Size(360, 640), const Size(390, 844)]) {
    testWidgets('read current values and confirm both controls at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final notifier = SettingsNotifier();
      final key = await open(tester, notifier);
      await tester.pumpAndSettle();
      expect(find.text('已读取卡片当前设置。'), findsOneWidget);
      expect(
          tester
              .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
              .selected,
          {2});
      expect(tester.widget<Switch>(find.byType(Switch)).value, true);
      await screenshot(tester, key, 'meeting-${size.width.toInt()}-ready');
      await tester.tap(find.text('三击'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
              .selected,
          {3});
      expect(find.text('已保存，卡片回读已确认。'), findsOneWidget);
      await tester.ensureVisible(find.byType(Switch));
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(notifier.led, false);
      expect(find.text('已关闭：会议录音时不显示指示灯。'), findsOneWidget);
      expect(notifier.methods.where((m) => m == 'setUserSettings').length, 2);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unread values stay empty and timeout offers a fresh read',
      (tester) async {
    final notifier = SettingsNotifier()..reply = false;
    final key = await open(tester, notifier);
    expect(find.text('尚未读到有效的触发方式。'), findsOneWidget);
    expect(
        tester
            .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
            .selected,
        isEmpty);
    expect(
        tester
            .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
            .onSelectionChanged,
        isNull);
    await screenshot(tester, key, 'meeting-unread');
    await tester.pumpAndSettle();
    expect(find.text('未收到完整设置回报，请重新读取。'), findsOneWidget);
    notifier.reply = true;
    await tester.tap(find.text('读取卡片设置'));
    await tester.pumpAndSettle();
    expect(find.text('已读取卡片当前设置。'), findsOneWidget);
    expect(notifier.methods.where((m) => m == 'setUserSettings'), isEmpty);
  });

  testWidgets('failed write shows unknown values and requires manual reread',
      (tester) async {
    final notifier = SettingsNotifier();
    final key = await open(tester, notifier);
    await tester.pumpAndSettle();
    notifier.acceptWrite = false;
    await tester.tap(find.text('三击'));
    await tester.pumpAndSettle();
    expect(find.textContaining('未确认保存结果'), findsOneWidget);
    expect(
        tester
            .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
            .selected,
        isEmpty);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    await screenshot(tester, key, 'meeting-save-error');
    expect(notifier.methods.where((m) => m == 'setUserSettings').length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recording disables changes and keeps displayed card values',
      (tester) async {
    final notifier = SettingsNotifier()..recording = true;
    await open(tester, notifier);
    await tester.pumpAndSettle();
    expect(find.text('正在录音，请结束后再修改设置。'), findsOneWidget);
    expect(
        tester
            .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
            .onSelectionChanged,
        isNull);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    expect(notifier.methods.where((m) => m == 'setUserSettings'), isEmpty);
  });

  testWidgets('unsupported settings and disconnected device cannot be edited',
      (tester) async {
    final notifier = SettingsNotifier()..caps = [1002];
    await open(tester, notifier);
    await tester.pumpAndSettle();
    expect(find.text('当前卡片未报告按键次数设置能力。'), findsOneWidget);
    expect(find.byType(SegmentedButton<int>), findsNothing);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    notifier.ready = false;
    notifier.settings.reset();
    await tester.pumpAndSettle();
    expect(find.text('连接录音卡并完成身份验证后，可读取和修改设置。'), findsOneWidget);
    final reads = notifier.methods.length;
    await tester.tap(find.text('读取卡片设置'));
    await tester.pump();
    expect(notifier.methods.length, reads);
    expect(tester.takeException(), isNull);
  });
}

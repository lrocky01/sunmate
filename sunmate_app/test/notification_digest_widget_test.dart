import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/recordings/notification_digest_models.dart';
import 'package:sunmate_app/core/recordings/recording_processing_controller.dart';
import 'package:sunmate_app/providers/device_provider.dart';
import 'package:sunmate_app/providers/recording_processing_provider.dart';
import 'package:sunmate_app/views/notification_digest_page.dart';
import 'package:sunmate_app/views/timeline_page.dart';
import 'notification_digest_test.dart' show DigestWorld;
import 'four_fixes_widgets_test.dart' show PurposeLibrary, PageFactory;
import 'recorder_management_widget_test.dart' show captureUi, screenshot;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (captureUi)
      for (final font in {
        'ManagementFixture':
            '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
        'MaterialIcons':
            '/private/tmp/sunmate-flutter-sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'
      }.entries) {
        await (FontLoader(font.key)
              ..addFont(File(font.value)
                  .readAsBytes()
                  .then((b) => b.buffer.asByteData())))
            .load();
      }
  });
  late DigestWorld w;
  late PurposeLibrary driver;
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<GlobalKey> open(WidgetTester tester,
      {Widget page = const NotificationDigestPage(),
      bool dark = false,
      double scale = 1}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(ProviderScope(
        overrides: [
          recordingProcessingProvider.overrideWith((ref) => w.c),
          deviceFactoryProvider.overrideWithValue(PageFactory(driver))
        ],
        child: MaterialApp(
            theme: ThemeData(
                useMaterial3: true,
                fontFamily: captureUi ? 'ManagementFixture' : null,
                colorScheme: ColorScheme.fromSeed(
                    seedColor: const Color(0xffff8c00),
                    brightness: dark ? Brightness.dark : Brightness.light)),
            builder: (_, child) => MediaQuery(
                data: MediaQuery.of(_)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: key, child: child!)),
            home: page)));
    await tester.pumpAndSettle();
    return key;
  }

  Future<void> setup(WidgetTester tester) async {
    w = DigestWorld();
    driver = PurposeLibrary();
    await tester.runAsync(w.open);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(w.close);
    await driver.updates.close();
  }

  Future<void> drain(WidgetTester tester, {int? expectedCalls}) async {
    for (var n = 0; n < 250; n++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      if ((expectedCalls == null || w.agent.calls >= expectedCalls) &&
          w.c.notificationJobs.isNotEmpty &&
          w.c.notificationJobs.every((j) => ![
                NotificationDigestStage.queued,
                NotificationDigestStage.running
              ].contains(j.stage))) break;
    }
    await tester.pumpAndSettle();
  }

  testWidgets('manual three ranges and empty state never sends request',
      (tester) async {
    await setup(tester);
    final key = await open(tester);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('上次总结后'), findsOneWidget);
    expect(find.text('自定义时间'), findsOneWidget);
    final button = tester
        .widget<FilledButton>(find.byWidgetPredicate((w) => w is FilledButton));
    expect(button.onPressed, null);
    expect(w.agent.calls, 0);
    await tester.tap(find.text('上次总结后'));
    await tester.pumpAndSettle();
    expect(find.text('尚无成功简报，首次按今天处理。'), findsOneWidget);
    await screenshot(tester, key, 'notification-digest-empty');
    await close(tester);
  });
  testWidgets(
      'preview confirmation -> serial queue -> saved notification result; no ASR',
      (tester) async {
    await setup(tester);
    await tester.runAsync(() => w.notice('n'));
    final key = await open(tester);
    expect(w.agent.calls, 0);
    await tester.tap(find.text('生成通知简报'));
    await tester.pumpAndSettle();
    expect(find.textContaining('共 1 条'), findsOneWidget);
    expect(w.agent.calls, 0);
    await tester.tap(find.text('确认生成'));
    await drain(tester);
    expect(w.agent.calls, 1);
    expect(w.audioFixture.asr.submits, 0);
    expect(find.text('简报已保存'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('已保存通知简报 ·'), 300);
    await screenshot(tester, key, 'notification-digest-saved');
    await tester.tap(find.textContaining('已保存通知简报 ·'));
    await tester.pumpAndSettle();
    expect(find.text('合成通知简报'), findsOneWidget);
    expect(find.text('使用 1 条本机通知；不包含录音。'), findsOneWidget);
    await close(tester);
  });
  testWidgets(
      'custom range flows through date/time pickers with independent boundaries',
      (tester) async {
    await setup(tester);
    await tester
        .runAsync(() => w.notice('n', at: DateTime(2026, 10, 21, 10, 30)));
    await open(tester);
    await tester.tap(find.text('自定义时间'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(DateRangePickerDialog))).pop(
        DateTimeRange(
            start: DateTime(2026, 10, 21), end: DateTime(2026, 10, 21)));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(TimePickerDialog)))
        .pop(const TimeOfDay(hour: 10, minute: 0));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(TimePickerDialog)))
        .pop(const TimeOfDay(hour: 11, minute: 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('10:00:00 ～'), findsOneWidget);
    expect(find.text('当前可用通知：1 条'), findsOneWidget);
    expect(w.agent.calls, 0);
    await close(tester);
  });
  testWidgets(
      'failed result stays failed until explicit retry; dark large layout',
      (tester) async {
    await setup(tester);
    await tester.runAsync(() => w.notice('n'));
    w.agent.empty = true;
    final key = await open(tester, dark: true, scale: 1.3);
    await tester.tap(find.text('生成通知简报'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认生成'));
    await drain(tester);
    expect(w.c.notificationCoveredUntil, null);
    expect(w.agent.calls, 1);
    await tester.scrollUntilVisible(find.text('确认后重试'), 300);
    await screenshot(tester, key, 'notification-digest-failed-dark');
    w.agent.empty = false;
    await tester.tap(find.text('确认后重试'));
    await tester.pumpAndSettle();
    expect(w.agent.calls, 1);
    await tester.tap(find.text('确认重试'));
    await drain(tester, expectedCalls: 2);
    expect(w.agent.calls, 2);
    expect(w.c.notificationCoveredUntil, isNotNull);
    expect(tester.takeException(), null);
    await close(tester);
  });
  testWidgets('since last selects only later notifications after success',
      (tester) async {
    await setup(tester);
    await tester.runAsync(() async {
      await w.notice('old');
      await w.digest(w.c.notificationRange(NotificationDigestMode.today));
      w.now = w.now.add(const Duration(minutes: 10));
      await w.notice('new', at: w.now.subtract(const Duration(minutes: 2)));
    });
    await open(tester);
    await tester.tap(find.text('上次总结后'));
    await tester.pumpAndSettle();
    expect(find.text('当前可用通知：1 条'), findsOneWidget);
    expect(w.agent.calls, 1);
    await close(tester);
  });
  testWidgets(
      'timeline has separate notification digest and lifelog review entries',
      (tester) async {
    await setup(tester);
    final key = await open(tester, page: const TimelinePage());
    expect(find.text('通知简报'), findsOneWidget);
    expect(find.text('随身复盘'), findsOneWidget);
    await screenshot(tester, key, 'notification-digest-timeline-entry');
    await tester.tap(find.text('通知简报'));
    await tester.pumpAndSettle();
    expect(find.text('已保存通知简报'), findsOneWidget);
    expect(w.agent.calls, 0);
    await close(tester);
  });
}

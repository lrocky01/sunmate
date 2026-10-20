import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/hardware/recorder_hardware_settings.dart';
import 'package:sunmate_app/core/hardware/recorder_long_recordings.dart';
import 'package:sunmate_app/providers/device_provider.dart';
import 'package:sunmate_app/views/recorder_management_page.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_long_recordings_test.dart' show MemoryLongSessionStore;
import 'recorder_management_widget_test.dart'
    show ManagementNotifier, captureUi, screenshot;

class PurposeNotifier extends ManagementNotifier {
  final MemoryLongSessionStore store;
  bool cardRecording = false;
  bool ended = false;
  int revisions = 0;
  late final RecorderLongRecordingController recordings =
      RecorderLongRecordingController(
          store: store,
          isCardRecording: () => cardRecording,
          onChanged: () {
            if (!ended)
              state = state.copyWith(deviceName: 'purpose ${++revisions}');
          });
  PurposeNotifier(this.store) {
    unawaited(recordings.initialize());
  }
  @override
  RecorderLongRecordings get recorderLongRecordings => recordings.snapshot;
  @override
  RecorderHardwareSettings get recorderHardwareSettings =>
      const RecorderHardwareSettings();
  @override
  Future<bool> chooseLongRecordingPurpose(LongRecordingPurpose value) =>
      recordings.choose(value);
  @override
  Future<void> reloadLongRecordingSessions() => recordings.initialize();
  @override
  Future<bool> retryLongRecordingSessionSave() => recordings.retrySave();
  @override
  void dispose() {
    ended = true;
    unawaited(recordings.dispose());
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
                  .then((b) => b.buffer.asByteData())))
            .load();
      }
    }
  });
  Future<GlobalKey> open(WidgetTester tester, PurposeNotifier notifier,
      {Size size = const Size(390, 844)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    await tester.pumpAndSettle();
    return key;
  }

  for (final size in [const Size(360, 640), const Size(390, 844)]) {
    testWidgets(
        'purpose choice saves for next recording without changing hardware settings at $size',
        (tester) async {
      final notifier = PurposeNotifier(MemoryLongSessionStore());
      final key = await open(tester, notifier, size: size);
      expect(find.text('长录用途'), findsOneWidget);
      await tester.tap(find.text('随身记录'));
      await tester.pumpAndSettle();
      expect(
          notifier.recordings.snapshot.preferred, LongRecordingPurpose.lifelog);
      expect(find.text('已保存，下次新长录用于随身记录。'), findsOneWidget);
      expect(find.textContaining('不代表音频已保存'), findsOneWidget);
      await screenshot(tester, key, 'long-purpose-${size.width.toInt()}-ready');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('active session locks purpose and never claims audio saved',
      (tester) async {
    final notifier = PurposeNotifier(MemoryLongSessionStore());
    await notifier.recordings.choose(LongRecordingPurpose.lifelog);
    await notifier.recordings.started('AB00000000000001', 11);
    notifier.cardRecording = true;
    final key = await open(tester, notifier);
    expect(find.text('录音中不可修改用途。已有会话会继续保留原用途。'), findsOneWidget);
    expect(
        tester
            .widget<SegmentedButton<LongRecordingPurpose>>(
                find.byType(SegmentedButton<LongRecordingPurpose>))
            .onSelectionChanged,
        isNull);
    expect(find.textContaining('最近活动会话：随身记录'), findsOneWidget);
    await screenshot(tester, key, 'long-purpose-active');
    notifier.cardRecording = false;
    await notifier.recordings.stopped('AB00000000000001', 11);
    await tester.pumpAndSettle();
    expect(find.text('已收到结束事件，音频未同步'), findsOneWidget);
    expect(find.text('音频已保存'), findsNothing);
  });

  testWidgets(
      'historical status has unknown purpose and selection cannot rewrite it',
      (tester) async {
    final notifier = PurposeNotifier(MemoryLongSessionStore());
    await notifier.recordings
        .started('AB00000000000001', 11, observedStart: false);
    notifier.cardRecording = true;
    await open(tester, notifier);
    expect(find.textContaining('最近活动会话：用途未确认'), findsOneWidget);
    expect(notifier.recordings.snapshot.active!.purpose, isNull);
  });

  testWidgets('corrupt local metadata offers reload and preserves original',
      (tester) async {
    final store = MemoryLongSessionStore()..value = 'broken';
    final notifier = PurposeNotifier(store);
    await open(tester, notifier);
    expect(find.text('本机用途资料尚未读取。'), findsOneWidget);
    expect(
        tester
            .widget<SegmentedButton<LongRecordingPurpose>>(
                find.byType(SegmentedButton<LongRecordingPurpose>))
            .selected,
        isEmpty);
    expect(find.text('重试读取本机资料'), findsOneWidget);
    expect(store.value, 'broken');
    expect(store.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'preference write failure shows error without selecting unsaved purpose',
      (tester) async {
    final store = MemoryLongSessionStore()..rejectWrite = true;
    final notifier = PurposeNotifier(store);
    final key = await open(tester, notifier);
    await tester.tap(find.text('随身记录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('保存未完成'), findsOneWidget);
    expect(
        notifier.recordings.snapshot.preferred, LongRecordingPurpose.meeting);
    expect(find.text('重试保存会话资料'), findsNothing);
    await screenshot(tester, key, 'long-purpose-save-error');
    store.rejectWrite = false;
    await tester.tap(find.text('随身记录'));
    await tester.pumpAndSettle();
    expect(
        notifier.recordings.snapshot.preferred, LongRecordingPurpose.lifelog);
    expect(tester.takeException(), isNull);
  });
}

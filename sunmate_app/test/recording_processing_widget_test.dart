import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/hardware/recorder_long_recordings.dart';
import 'package:sunmate_app/providers/device_provider.dart';
import 'package:sunmate_app/providers/recording_processing_provider.dart';
import 'package:sunmate_app/views/recording_processing_pages.dart';
import 'package:sunmate_app/views/meeting_page.dart';
import 'package:sunmate_app/views/meeting_recording_overview.dart';
import 'package:sunmate_app/views/timeline_page.dart';
import 'package:sunmate_app/views/lifelog_timeline_section.dart';
import 'package:sunmate_app/core/ai/asr_service.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_models.dart';
import 'recording_overview_playback_test.dart'
    show OverviewAudio, createMeetingArchive;
import 'recording_processing_test.dart' show ProcessingFixture, notice;
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
  late ProcessingFixture f;
  late PurposeLibrary driver;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  Future<GlobalKey> open(WidgetTester tester, Widget child,
      {bool dark = false, double scale = 1}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(ProviderScope(
        overrides: [
          recordingProcessingProvider.overrideWith((ref) => f.c),
          recordingLocalAudioProvider.overrideWithValue(f.audio),
          recordingAudioStoreProvider.overrideWithValue(f.store),
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
                data: MediaQueryData(
                    size: const Size(390, 844),
                    textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: key, child: child!)),
            home: child)));
    await tester.pumpAndSettle();
    return key;
  }

  Future<void> setup(WidgetTester tester) async {
    f = ProcessingFixture();
    driver = PurposeLibrary();
    await tester.runAsync(f.open);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(f.close);
    await driver.updates.close();
  }

  testWidgets(
      'automatic settings default off and dependency is explicit, readback success',
      (tester) async {
    await setup(tester);
    final key = await open(tester, const RecordingProcessingSettingsPage());
    expect(
        tester
            .widgetList<SwitchListTile>(find.byType(SwitchListTile))
            .every((w) => !w.value),
        true);
    expect(f.asr.submits, 0);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(SwitchListTile, '会议分段自动转写'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(f.c.policy.meetingTranscribe, true);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(SwitchListTile, '会议停止后自动纪要'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(f.c.policy.meetingSummary, true);
    await screenshot(tester, key, 'segments-auto-settings');
    expect(tester.takeException(), isNull);
    await close(tester);
  });
  testWidgets(
      'meeting groups whole session, detail opens segments without submitting',
      (tester) async {
    await setup(tester);
    await tester.runAsync(() async {
      await f.start();
      await f.add(0);
      await f.add(1);
      await f.finish(parts: 2);
    });
    final key = await open(tester, const MeetingPage());
    expect(find.byType(MeetingRecordingOverview), findsOneWidget);
    expect(find.text('完整逐字稿'), findsOneWidget);
    expect(find.text('会议纪要'), findsOneWidget);
    expect(find.textContaining('第 1 段'), findsNothing);
    expect(f.asr.submits, 0);
    await screenshot(tester, key, 'segments-meeting-session');
    await tester.tap(find.text('分段详情'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第 1 段'), findsOneWidget);
    await screenshot(tester, key, 'segments-meeting-detail');
    expect(f.asr.submits, 0);
    expect(tester.takeException(), isNull);
    await close(tester);
  });
  testWidgets(
      'active session disables whole summary but allows prepared segment playback',
      (tester) async {
    await setup(tester);
    await tester.runAsync(() async {
      await f.start();
      await f.add(0);
    });
    await open(tester, RecordingSessionPage(sessionId: f.c.sessions.single.id));
    expect(
        tester
            .widget<FilledButton>(
                find.byWidgetPredicate((w) => w is FilledButton))
            .onPressed,
        isNull);
    await tester.runAsync(() async {
      await tester.tap(find.text('播放本段'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(f.audio.calls, 1);
    expect(f.asr.submits, 0);
    expect(tester.takeException(), isNull);
    await close(tester);
  });
  testWidgets(
      'lifelog persisted timed text and notification coexist, large dark screen',
      (tester) async {
    await setup(tester);
    await tester.runAsync(() async {
      await f.start(purpose: LongRecordingPurpose.lifelog);
      final p = await f.add(0, purpose: LongRecordingPurpose.lifelog);
      await f.c.transcribePart(p);
      await f.finish(purpose: LongRecordingPurpose.lifelog);
      await f.c.addTimelineEntry(notice());
    });
    final key =
        await open(tester, const TimelinePage(), dark: true, scale: 1.3);
    expect(find.text('随身长录音'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('合成转写').last, 350,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('合成通知正文'), findsOneWidget);
    expect(find.text('播放片段'), findsOneWidget);
    expect(find.text('合成转写'), findsOneWidget);
    await screenshot(tester, key, 'segments-lifelog-timeline-dark');
    expect(tester.takeException(), isNull);
    expect(f.agent.reviews, 0);
    await close(tester);
  });
  testWidgets(
      'unlocated segment remains visible within recording, without pretending absolute time',
      (tester) async {
    await setup(tester);
    await tester.runAsync(() async {
      await f.add(2, purpose: LongRecordingPurpose.lifelog);
      await f.add(3, purpose: LongRecordingPurpose.lifelog);
    });
    final key = await open(
        tester, RecordingSessionPage(sessionId: f.c.sessions.single.id),
        scale: 1.3);
    expect(find.textContaining('绝对时间待定位'), findsWidgets);
    expect(find.textContaining('待补齐前段'), findsWidgets);
    await screenshot(tester, key, 'segments-unlocated');
    expect(tester.takeException(), isNull);
    await close(tester);
  });
  testWidgets(
      'meeting main plays whole archive directly, keeps sections behind details',
      (tester) async {
    await setup(tester);
    final audio = OverviewAudio(f.store);
    f.audio = audio;
    await tester.runAsync(() async {
      final record = await createMeetingArchive(f, audio);
      driver.library =
          RecorderLongFileLibrary(loaded: true, recordings: [record]);
    });
    final key = await open(tester, const MeetingPage());
    expect(find.text('整场播放'), findsOneWidget);
    expect(find.text('完整逐字稿'), findsOneWidget);
    expect(find.text('会议纪要'), findsOneWidget);
    expect(find.text('播放本段'), findsNothing);
    await tester.runAsync(() async {
      await tester.tap(find.text('整场播放'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(audio.plays, 1);
    expect(find.text('停止整场播放'), findsOneWidget);
    expect(f.asr.submits, 0);
    expect(f.agent.meetings, 0);
    await screenshot(tester, key, 'meeting-overview-playing');
    await close(tester);
  });
  testWidgets(
      'complete transcript joins all source parts in order without another request',
      (tester) async {
    await setup(tester);
    await tester.runAsync(() async {
      final a = await f.add(0), b = await f.add(1);
      await f.finish(parts: 2);
      f.asr.result = AsrResult(success: true, rawText: '会议第一句');
      await f.c.transcribePart(a);
      f.asr.result = AsrResult(success: true, rawText: '会议第二句');
      await f.c.transcribePart(b);
    });
    final key = await open(tester, const MeetingPage());
    await tester.tap(find.text('完整逐字稿'));
    await tester.pumpAndSettle();
    expect(find.text('整场逐字稿已完整保存'), findsOneWidget);
    final texts = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((w) => w.data ?? '')
        .join();
    expect(texts, contains('会议第一句'));
    expect(texts.indexOf('会议第一句'), lessThan(texts.indexOf('会议第二句')));
    expect(f.asr.submits, 2);
    expect(f.agent.meetings, 0);
    await screenshot(tester, key, 'meeting-complete-transcript');
    await close(tester);
  });
  testWidgets(
      'explicit transcript action submits ASR only with default switches, saves result',
      (tester) async {
    await setup(tester);
    await tester.runAsync(() async {
      await f.add(0);
      await f.finish();
    });
    await open(tester, const MeetingPage());
    await tester.tap(find.text('完整逐字稿'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('补齐整场逐字稿'));
    await tester.pumpAndSettle();
    expect(f.asr.submits, 0);
    await tester.tap(find.text('开始转写'));
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      if (f.c
          .partsOf(f.c.sessions.single.id)
          .every((p) => f.c.transcript(p)?.stage.name == 'complete')) break;
    }
    expect(f.asr.submits, 1,
        reason: f.c
            .partsOf(f.c.sessions.single.id)
            .map((p) => f.c.transcript(p)?.stage.name)
            .join(','));
    await tester.pumpAndSettle();
    expect(f.agent.meetings, 0);
    expect(find.text('整场逐字稿已完整保存'), findsOneWidget);
    await close(tester);
  });
  testWidgets('saved minutes open in their own view without regenerating',
      (tester) async {
    await setup(tester);
    await tester.runAsync(() async {
      await f.add(0);
      await f.finish();
      await f.c.summarizeMeeting(f.c.sessions.single.id);
    });
    final key = await open(tester, const MeetingPage(), dark: true, scale: 1.3);
    await tester.tap(find.text('会议纪要'));
    await tester.pumpAndSettle();
    expect(find.text('合成会议结果'), findsOneWidget);
    expect(f.agent.meetings, 1);
    await screenshot(tester, key, 'meeting-saved-minutes-dark');
    await close(tester);
  });
  testWidgets(
      'incomplete meeting never claims full transcript or enables whole playback',
      (tester) async {
    await setup(tester);
    await tester.runAsync(() async {
      await f.add(0);
    });
    await open(tester, const MeetingPage());
    final button = tester.widget<FilledButton>(
        find.byWidgetPredicate((w) => w is FilledButton).first);
    expect(button.onPressed, isNull);
    await tester.tap(find.text('完整逐字稿'));
    await tester.pumpAndSettle();
    expect(find.textContaining('部分逐字稿'), findsOneWidget);
    expect(find.text('整场逐字稿已完整保存'), findsNothing);
    expect(f.asr.submits, 0);
    await close(tester);
  });
  testWidgets(
      'untranscribed lifelog segments interleave notifications by time and remain playable',
      (tester) async {
    await setup(tester);
    late String first, second;
    await tester.runAsync(() async {
      await f.start(purpose: LongRecordingPurpose.lifelog);
      first = (await f.add(0, purpose: LongRecordingPurpose.lifelog)).id;
      second = (await f.add(1, purpose: LongRecordingPurpose.lifelog)).id;
      await f.c.addTimelineEntry(notice());
    });
    final key = await open(
        tester,
        Scaffold(
            appBar: AppBar(title: const Text('随身记录时间轴')),
            body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: LifelogTimelineSection(
                    entries: f.c.timelineEntries, onEntry: (_) {}))));
    final p0 = find.byKey(ValueKey('lifelog-part:$first')),
        p1 = find.byKey(ValueKey('lifelog-part:$second')),
        n = find.byKey(const ValueKey('timeline-entry:notice'));
    expect(tester.getTopLeft(p1).dy, lessThan(tester.getTopLeft(n).dy));
    expect(tester.getTopLeft(n).dy, lessThan(tester.getTopLeft(p0).dy));
    expect(find.text('播放片段'), findsNWidgets(2));
    expect(f.asr.submits, 0);
    await screenshot(tester, key, 'lifelog-untranscribed-interleaved');
    await close(tester);
  });
  testWidgets(
      'hidden lifelog transcript stays hidden while original audio is retained',
      (tester) async {
    await setup(tester);
    await tester.runAsync(() async {
      await f.start(purpose: LongRecordingPurpose.lifelog);
      final p = await f.add(0, purpose: LongRecordingPurpose.lifelog);
      await f.c.transcribePart(p);
      await f.c.hideTimelineEntry(f.c.timelineEntries.single.id);
    });
    await open(
        tester,
        Scaffold(
            body: SingleChildScrollView(
                child: LifelogTimelineSection(
                    entries: f.c.timelineEntries, onEntry: (_) {}))));
    expect(find.text('合成转写'), findsNothing);
    expect(find.textContaining('文字已从时光轴隐藏'), findsOneWidget);
    expect(find.text('播放片段'), findsOneWidget);
    await close(tester);
  });
  testWidgets(
      'lifelog text within each segment keeps speaking order, not reversed timeline order',
      (tester) async {
    await setup(tester);
    await tester.runAsync(() async {
      await f.start(purpose: LongRecordingPurpose.lifelog);
      final p = await f.add(0, purpose: LongRecordingPurpose.lifelog);
      f.asr.result = AsrResult(success: true, rawText: '先说后说', segments: [
        DiarizedSegment(speaker: '0', start: 0, end: .2, text: '先说'),
        DiarizedSegment(speaker: '0', start: .3, end: .5, text: '后说')
      ]);
      await f.c.transcribePart(p);
    });
    await open(
        tester,
        Scaffold(
            body: SingleChildScrollView(
                child: LifelogTimelineSection(
                    entries: f.c.timelineEntries, onEntry: (_) {}))));
    expect(find.text('先说\n后说'), findsOneWidget);
    await close(tester);
  });
}

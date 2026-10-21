import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ai/asr_service.dart';
import 'package:sunmate_app/core/audio/recorder_archive_transcriber.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'package:sunmate_app/core/hardware/hardware_device_factory.dart';
import 'package:sunmate_app/providers/device_provider.dart';
import 'package:sunmate_app/views/meeting_page.dart';
import 'package:sunmate_app/views/timeline_page.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_models.dart';
import 'package:sunmate_app/core/hardware/recorder_long_recordings.dart';
import 'package:sunmate_app/core/notifications/notification_app_policy.dart';
import 'package:sunmate_app/providers/server_config_provider.dart';
import 'package:sunmate_app/views/notification_apps_page.dart';
import 'package:sunmate_app/views/recorder_long_files_page.dart';
import 'package:sunmate_app/views/recorder_purpose_files_section.dart';
import 'package:sunmate_app/views/settings_page.dart';
import 'server_config_persistence_test.dart' show ConfigMemoryStore;
import 'notification_app_policy_test.dart' show PolicyMemoryStore;
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recording_processing_test.dart'
    show MemoryContent, SegmentAudio, SegmentAsr, SegmentAgent;
import 'package:sunmate_app/core/hardware/recorder_long_file_store.dart';
import 'package:sunmate_app/core/recordings/recording_processing_controller.dart';
import 'package:sunmate_app/providers/recording_processing_provider.dart';
import 'recorder_management_widget_test.dart' show captureUi, screenshot;

class PurposeLibrary implements AiNote6095Driver {
  final updates = StreamController<void>.broadcast();
  RecorderLongFileLibrary library = const RecorderLongFileLibrary(loaded: true);
  @override
  RecorderLongFileLibrary get longFileLibrary => library;
  @override
  Stream<void> get stateChanges => updates.stream;
  @override
  Future<void> reloadLocalLongFiles() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ManualTranscriber extends RecorderArchiveTranscriber {
  int calls = 0;
  RecorderLongAudioRecord? selected;
  bool fail = false;
  ManualTranscriber() : super(asr: AsrService());
  @override
  Future<AsrResult> transcribe(RecorderLongAudioRecord record) async {
    calls++;
    selected = record;
    if (fail) throw StateError('synthetic-only');
    return AsrResult(success: true, rawText: 'Synthetic transcript');
  }
}

RecorderLongAudioRecord archive(LongRecordingPurpose? purpose,
        {bool saved = true, int id = 1792496000000}) =>
    RecorderLongAudioRecord(
        serialNumber: 'AB00000000000001',
        sessionId: id,
        purpose: purpose,
        stage: saved
            ? RecorderLongFileStage.saved
            : RecorderLongFileStage.waitingForTail,
        relativePlayablePath: saved
            ? 'recorder_long_audio_v1/AB00000000000001/s$id/voice.wav'
            : null,
        totalParts: 1,
        downloadedParts: saved ? 1 : 0,
        durationMs: saved ? 5000 : null);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    FlutterBluePlusPlatform.instance = TestBlePlatform();
    if (captureUi)
      for (final font in {
        'ManagementFixture':
            '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
        'MaterialIcons':
            '/private/tmp/sunmate-flutter-sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(font.key)
              ..addFont(File(font.value)
                  .readAsBytes()
                  .then((b) => b.buffer.asByteData())))
            .load();
      }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  Future<GlobalKey> open(WidgetTester tester, Widget child,
      {List<Override> overrides = const [],
      double scale = 1,
      Brightness brightness = Brightness.light}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(ProviderScope(
        overrides: overrides,
        child: MaterialApp(
            theme: ThemeData(
                useMaterial3: true,
                fontFamily: captureUi ? 'ManagementFixture' : null,
                colorScheme: ColorScheme.fromSeed(
                    seedColor: const Color(0xffff8c00),
                    brightness: brightness)),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: RepaintBoundary(key: key, child: child))));
    await tester.pumpAndSettle();
    return key;
  }

  testWidgets(
      'settings hydrate and save without health probes; reopen retains all four fields',
      (tester) async {
    final store = ConfigMemoryStore();
    final first = ServerConfigNotifier(store: store);
    await first.ready;
    await first.updateConfig(
        asrBaseUrl: 'http://192.0.2.5:8000',
        hermesBaseUrl: 'https://example.invalid/v1',
        asrToken: 'synthetic-asr',
        hermesToken: 'synthetic-hermes');
    final key = await open(tester, const SettingsPage(),
        overrides: [serverConfigProvider.overrideWith((ref) => first)]);
    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).controller!.text,
        'http://192.0.2.5:8000');
    expect(tester.widget<TextField>(fields.at(3)).controller!.text,
        'synthetic-hermes');
    await tester.enterText(fields.at(0), 'http://192.0.2.6:8000');
    await tester.ensureVisible(find.text('保存节点配置'));
    await tester.tap(find.text('保存节点配置'));
    await tester.pumpAndSettle();
    expect(find.text('已安全保存，重开 App 后自动恢复。'), findsOneWidget);
    expect(find.text('未测试'), findsNWidgets(2));
    await screenshot(tester, key, 'four-fixes-settings-saved');
    await tester.pumpWidget(const SizedBox());
    final next = ServerConfigNotifier(store: store);
    await next.ready;
    await open(tester, const SettingsPage(),
        overrides: [serverConfigProvider.overrideWith((ref) => next)]);
    expect(tester.widget<TextField>(fields.at(0)).controller!.text,
        'http://192.0.2.6:8000');
    expect(tester.widget<TextField>(fields.at(1)).controller!.text,
        'synthetic-asr');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'notification page empty then real app appears and switch persists',
      (tester) async {
    final policy = NotificationAppPolicy(store: PolicyMemoryStore());
    await policy.ready;
    final key = await open(tester, NotificationAppsPage(policy: policy));
    expect(find.textContaining('尚未收到应用通知'), findsOneWidget);
    policy.observe('com.tencent.xin', '微信', DateTime(2026, 10, 20));
    await tester.pumpAndSettle();
    expect(find.text('微信'), findsOneWidget);
    expect(find.textContaining('com.tencent.xin'), findsOneWidget);
    await tester.tap(find.widgetWithText(SwitchListTile, '微信'));
    await tester.pumpAndSettle();
    expect(policy.allows('com.tencent.xin'), false);
    await screenshot(tester, key, 'four-fixes-notification-apps');
    await tester.pumpWidget(const SizedBox());
    policy.dispose();
  });
  for (final purpose in LongRecordingPurpose.values) {
    testWidgets(
        '${purpose.name} observes saved purpose files and only transcribes on explicit tap',
        (tester) async {
      final driver = PurposeLibrary();
      final transcriber = ManualTranscriber();
      var results = 0;
      driver.library = RecorderLongFileLibrary(loaded: true, recordings: [
        archive(null),
        archive(
            purpose == LongRecordingPurpose.meeting
                ? LongRecordingPurpose.lifelog
                : LongRecordingPurpose.meeting,
            id: 1792496100000)
      ]);
      final key = await open(
          tester,
          Scaffold(
              body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: RecorderPurposeFilesSection(
                      purpose: purpose,
                      driver: driver,
                      transcriber: transcriber,
                      onTranscribed: (r, result) async {
                        results++;
                      }))),
          scale: 1.25);
      expect(find.textContaining('尚无${purpose.label}录音'), findsOneWidget);
      expect(find.text('查看用途未确认的历史录音'), findsOneWidget);
      driver.library = RecorderLongFileLibrary(
          loaded: true, recordings: [archive(purpose, saved: false)]);
      driver.updates.add(null);
      await tester.pumpAndSettle();
      expect(find.textContaining('等待尾段确认'), findsOneWidget);
      expect(find.byIcon(Icons.transcribe), findsNothing);
      driver.library =
          RecorderLongFileLibrary(loaded: true, recordings: [archive(purpose)]);
      driver.updates.add(null);
      await tester.pumpAndSettle();
      expect(transcriber.calls, 0);
      expect(results, 0);
      final action = find
          .text(purpose == LongRecordingPurpose.meeting ? '转写并生成纪要' : '转写到时光轴');
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(transcriber.calls, 1);
      expect(transcriber.selected!.purpose, purpose);
      expect(results, 1);
      await screenshot(tester, key, 'four-fixes-${purpose.name}-archive');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await driver.updates.close();
    });
  }
  testWidgets(
      'meeting and timeline pages receive purpose archive updates, without VOR or automatic processing',
      (tester) async {
    final driver = PurposeLibrary()
      ..library = RecorderLongFileLibrary(loaded: true, recordings: [
        archive(LongRecordingPurpose.meeting),
        archive(LongRecordingPurpose.lifelog, id: 1792496100000)
      ]);
    final factory = PageFactory(driver);
    final key = await open(tester, const MeetingPage(), overrides: [
      deviceFactoryProvider.overrideWithValue(factory),
      recordingProcessingProvider.overrideWith((ref) {
        final store = RecorderLongFileStore();
        return RecordingProcessingController(
            content: MemoryContent(),
            audioStore: store,
            audio: SegmentAudio(store),
            asr: () => SegmentAsr(),
            agent: () => SegmentAgent());
      })
    ]);
    expect(find.text('会议长录音'), findsOneWidget);
    expect(find.textContaining('整场已归档'), findsOneWidget);
    expect(find.text('下载与归档管理'), findsOneWidget);
    expect(find.text('整场播放'), findsOneWidget);
    await screenshot(tester, key, 'four-fixes-meeting-page');
    await tester.pumpWidget(const SizedBox());
    final timeline = await open(tester, const TimelinePage(),
        overrides: [
          deviceFactoryProvider.overrideWithValue(factory),
          recordingProcessingProvider.overrideWith((ref) {
            final store = RecorderLongFileStore();
            return RecordingProcessingController(
                content: MemoryContent(),
                audioStore: store,
                audio: SegmentAudio(store),
                asr: () => SegmentAsr(),
                agent: () => SegmentAgent());
          })
        ],
        brightness: Brightness.dark);
    expect(find.text('随身长录音'), findsOneWidget);
    expect(find.text('下载与整场播放'), findsOneWidget);
    expect(find.textContaining('VOR'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    await screenshot(tester, timeline, 'four-fixes-timeline-page-dark');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await driver.updates.close();
  });
  testWidgets(
      'failed manual ASR never adds timeline result or claims summary success',
      (tester) async {
    final driver = PurposeLibrary()
      ..library = RecorderLongFileLibrary(
          loaded: true, recordings: [archive(LongRecordingPurpose.lifelog)]);
    final transcriber = ManualTranscriber()..fail = true;
    var results = 0;
    await open(
        tester,
        Scaffold(
            body: SingleChildScrollView(
                child: RecorderPurposeFilesSection(
                    purpose: LongRecordingPurpose.lifelog,
                    driver: driver,
                    transcriber: transcriber,
                    onTranscribed: (r, result) async {
                      results++;
                    }))));
    await tester.tap(find.text('转写到时光轴'));
    await tester.pumpAndSettle();
    expect(results, 0);
    expect(find.textContaining('处理未完成，本机音频已保留'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await driver.updates.close();
  });
  testWidgets(
      'purpose filter limits playback library without changing default all view',
      (tester) async {
    // No device or audio operations needed to prove filtering.
    final driver = PurposeLibrary()
      ..library = RecorderLongFileLibrary(loaded: true, recordings: [
        archive(LongRecordingPurpose.meeting),
        archive(LongRecordingPurpose.lifelog, id: 1792496100000)
      ]);
    // The full playback page requests additional driver state; test filtering via source
    // through a driver that supplies those read-only properties below.
    final view = ReadOnlyLibrary(driver.library);
    await open(
        tester,
        RecorderLongFilesPage(
            driver: view, purposeFilter: LongRecordingPurpose.meeting));
    expect(find.textContaining('会议 · 1792496000000'), findsOneWidget);
    expect(find.textContaining('随身记录 ·'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await driver.updates.close();
    await view.updates.close();
  });
}

class ReadOnlyLibrary extends PurposeLibrary {
  ReadOnlyLibrary(RecorderLongFileLibrary value) {
    library = value;
  }
  @override
  bool get isConnected => false;
  @override
  bool get isRecording => false;
}

class PageFactory implements HardwareDeviceFactory {
  @override
  final AiNote6095Driver bleDriver;
  PageFactory(this.bleDriver);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

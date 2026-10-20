import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/audio/recorder_local_audio.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'package:sunmate_app/core/hardware/recorder_hardware_settings.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_models.dart';
import 'package:sunmate_app/core/hardware/recorder_long_recordings.dart';
import 'package:sunmate_app/views/recorder_long_files_page.dart';

import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_management_widget_test.dart' show captureUi, screenshot;

class _LibraryDriver implements AiNote6095Driver {
  final updates = StreamController<void>.broadcast();
  RecorderLongFileLibrary library;
  bool ready;
  bool? recording;
  int refreshes = 0;
  int saves = 0;
  int? lastSyncedSession;
  bool reject = false;
  _LibraryDriver(
      {this.ready = false,
      this.recording = false,
      this.library = const RecorderLongFileLibrary(loaded: true)});
  @override
  bool get isConnected => ready;
  @override
  String get snNumber => 'AB00000000000001';
  @override
  bool get isRecording => recording == true;
  @override
  RecorderHardwareSettings get hardwareSettings =>
      RecorderHardwareSettings(connected: ready, recording: recording);
  @override
  Stream<void> get stateChanges => updates.stream;
  @override
  RecorderLongFileLibrary get longFileLibrary => library;
  @override
  Future<void> reloadLocalLongFiles() async {}
  @override
  Future<bool> refreshLongFiles() async {
    refreshes++;
    if (reject) throw StateError('test');
    return true;
  }

  @override
  Future<bool> syncLongRecording(int sessionId) async {
    saves++;
    lastSyncedSession = sessionId;
    if (reject) throw StateError('test');
    return true;
  }

  @override
  Future<void> dispose() async {
    await updates.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  void replace(RecorderLongFileLibrary next) {
    library = next;
    updates.add(null);
  }
}

class _LocalAudio implements RecorderLocalAudio {
  int plays = 0;
  int stops = 0;
  bool reject = false;
  bool acknowledgePlaying = true;
  RecorderAudioPlaybackState playback = const RecorderAudioPlaybackState();
  @override
  Future<PreparedRecorderAudio> prepare(String path) =>
      throw UnimplementedError();
  @override
  Future<void> play(String path) async {
    plays++;
    if (reject) throw StateError('test');
    playback = RecorderAudioPlaybackState(
        isPlaying: acknowledgePlaying,
        relativePath: path,
        positionMs: 1000,
        durationMs: 65000);
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {
    stops++;
    playback = const RecorderAudioPlaybackState();
  }

  @override
  Future<RecorderAudioPlaybackState> state() async => playback;
}

RecorderLongAudioRecord _record(
        {RecorderLongFileStage stage = RecorderLongFileStage.discovered,
        int parts = 0,
        int sessionId = 123,
        LongRecordingPurpose purpose = LongRecordingPurpose.meeting,
        String? message}) =>
    RecorderLongAudioRecord(
      serialNumber: 'AB00000000000001',
      sessionId: sessionId,
      purpose: purpose,
      stage: stage,
      totalParts: 3,
      downloadedParts: parts,
      sourceBytes: 3072,
      receivedBytes: parts * 1024,
      message: message,
      relativePlayablePath: stage == RecorderLongFileStage.saved
          ? 'recorder_long_audio_v1/test/session.wav'
          : null,
      durationMs: stage == RecorderLongFileStage.saved ? 65000 : null,
    );

Finder _button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((w) => w is OutlinedButton));

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

  Future<GlobalKey> open(
      WidgetTester tester, _LibraryDriver driver, _LocalAudio audio,
      {Size size = const Size(390, 844),
      Brightness brightness = Brightness.light,
      double textScale = 1}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await driver.dispose();
    });
    final key = GlobalKey();
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
      theme: ThemeData(
          useMaterial3: true,
          fontFamily: captureUi ? 'ManagementFixture' : null,
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xffff8c00), brightness: brightness)),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!),
      home: RepaintBoundary(
          key: key, child: RecorderLongFilesPage(driver: driver, audio: audio)),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return key;
  }

  for (final size in [const Size(360, 640), const Size(390, 844)]) {
    testWidgets('offline saved recording plays from native receipt at $size',
        (tester) async {
      final driver = _LibraryDriver(
          library: RecorderLongFileLibrary(loaded: true, recordings: [
        _record(stage: RecorderLongFileStage.saved, parts: 3)
      ]));
      final audio = _LocalAudio();
      final key = await open(tester, driver, audio, size: size);
      expect(find.textContaining('未连接卡片'), findsOneWidget);
      expect(
          tester.widget<OutlinedButton>(_button('读取卡片目录')).onPressed, isNull);
      expect(find.text('已保存到手机'), findsOneWidget);
      await tester.ensureVisible(find.text('播放本机录音'));
      await tester.tap(find.text('播放本机录音'));
      await tester.pump();
      expect(audio.plays, 1);
      expect(find.text('正在播放 0:01 / 1:05'), findsOneWidget);
      await screenshot(tester, key, 'long-files-${size.width.toInt()}-playing');
      await tester.tap(find.text('停止播放'));
      await tester.pumpAndSettle();
      expect(audio.stops, 1);
      expect(find.text('播放本机录音'), findsOneWidget);
      expect(driver.saves, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'ready idle card offers directory refresh and incomplete recovery',
      (tester) async {
    final driver = _LibraryDriver(
        ready: true,
        library: RecorderLongFileLibrary(loaded: true, recordings: [
          _record(stage: RecorderLongFileStage.incomplete, parts: 1),
        ]));
    await open(tester, driver, _LocalAudio());
    await tester.tap(find.text('读取卡片目录'));
    await tester.pumpAndSettle();
    expect(driver.refreshes, 1);
    await tester.tap(find.text('继续恢复并保存'));
    await tester.pumpAndSettle();
    expect(driver.saves, 1);
    expect(find.text('1/3 段 · 1.0 KB / 3.0 KB'), findsOneWidget);
    expect(find.text('播放本机录音'), findsNothing);
    expect(find.textContaining('删除'), findsNothing);
    expect(find.textContaining('上传'), findsNothing);
  });

  testWidgets('recording and unknown recording state disable writes',
      (tester) async {
    final driver = _LibraryDriver(
        ready: true,
        recording: true,
        library:
            RecorderLongFileLibrary(loaded: true, recordings: [_record()]));
    await open(tester, driver, _LocalAudio());
    expect(find.textContaining('卡片正在录音'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(_button('保存到手机')).onPressed, isNull);
    driver.recording = null;
    driver.replace(RecorderLongFileLibrary(
        loaded: true, activeSessionId: 123, recordings: [_record()]));
    await tester.pumpAndSettle();
    expect(find.textContaining('录音状态尚未确认'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(_button('读取卡片目录')).onPressed, isNull);
    expect(driver.refreshes, 0);
  });

  testWidgets('busy progress and incomplete tail never offer playback',
      (tester) async {
    final driver = _LibraryDriver(
        ready: true,
        library: RecorderLongFileLibrary(
            loaded: true,
            busy: true,
            message: '正在保存分段',
            recordings: [
              _record(stage: RecorderLongFileStage.downloading, parts: 1),
            ]));
    final key = await open(tester, driver, _LocalAudio(),
        brightness: Brightness.dark, textScale: 1.5);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    expect(find.text('播放本机录音'), findsNothing);
    expect(tester.widget<OutlinedButton>(_button('继续恢复并保存')).onPressed, isNull);
    await screenshot(tester, key, 'long-files-dark-progress-large-type');
    driver.replace(RecorderLongFileLibrary(loaded: true, recordings: [
      _record(stage: RecorderLongFileStage.waitingForTail, parts: 2),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('等待尾段确认'), findsOneWidget);
    expect(find.text('播放本机录音'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('save and playback errors are recoverable without false success',
      (tester) async {
    final driver = _LibraryDriver(
        ready: true,
        library: RecorderLongFileLibrary(loaded: true, recordings: [_record()]))
      ..reject = true;
    final audio = _LocalAudio()..reject = true;
    final key = await open(tester, driver, audio);
    await tester.tap(find.text('保存到手机'));
    await tester.pumpAndSettle();
    expect(find.text('录音保存未完成，已保存的分段会保留。'), findsOneWidget);
    driver.replace(RecorderLongFileLibrary(
        loaded: true,
        recordings: [_record(stage: RecorderLongFileStage.saved, parts: 3)]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放本机录音'));
    await tester.pumpAndSettle();
    expect(find.text('本机音频播放失败，请稍后重试。'), findsOneWidget);
    expect(find.textContaining('正在播放'), findsNothing);
    await screenshot(tester, key, 'long-files-playback-error');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'empty library has a directory action without deletion or remote processing',
      (tester) async {
    final driver = _LibraryDriver(ready: true);
    await open(tester, driver, _LocalAudio());
    expect(find.text('暂无录音文件。可读取卡片目录查看最新分段。'), findsOneWidget);
    expect(find.byIcon(Icons.delete), findsNothing);
    expect(find.text('转写'), findsNothing);
    expect(find.text('同步到 Hermes'), findsNothing);
    expect(driver.refreshes, 0);
  });

  testWidgets('play command alone never claims playback has started',
      (tester) async {
    final driver = _LibraryDriver(
        library: RecorderLongFileLibrary(loaded: true, recordings: [
      _record(stage: RecorderLongFileStage.saved, parts: 3),
    ]));
    final audio = _LocalAudio()..acknowledgePlaying = false;
    await open(tester, driver, audio);
    await tester.tap(find.text('播放本机录音'));
    await tester.pumpAndSettle();
    expect(audio.plays, 1);
    expect(find.textContaining('正在播放'), findsNothing);
    expect(find.text('停止播放'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'quarantined connection disables new reads until ordinary reconnect',
      (tester) async {
    final driver = _LibraryDriver(
        ready: true,
        library: RecorderLongFileLibrary(
            loaded: true,
            needsReconnect: true,
            message: '文件通道待重连',
            recordings: [_record()]));
    await open(tester, driver, _LocalAudio());
    await tester.tap(find.text('读取卡片目录'));
    await tester.pump();
    expect(driver.refreshes, 0);
    expect(find.text('文件通道待重连'), findsOneWidget);
  });

  for (final purpose in LongRecordingPurpose.values) {
    testWidgets(
        '${purpose.name} active long recording saves only closed segments',
        (tester) async {
      final driver = _LibraryDriver(
          ready: true,
          recording: true,
          library: RecorderLongFileLibrary(
              loaded: true,
              activeSessionId: 123,
              recordings: [
                _record(
                    stage: RecorderLongFileStage.recording,
                    purpose: purpose,
                    parts: 3),
                _record(sessionId: 456),
              ]));
      final key = await open(tester, driver, _LocalAudio(),
          size: purpose == LongRecordingPurpose.meeting
              ? const Size(360, 640)
              : const Size(390, 844));
      expect(find.textContaining('正在长录，自动保存已关闭分段'), findsOneWidget);
      expect(find.text('录音中，已关闭分段持续保存'), findsOneWidget);
      expect(find.text('已保存到手机'), findsNothing);
      expect(find.text('播放本机录音'), findsNothing);
      await tester.tap(find.text('读取卡片目录'));
      await tester.pumpAndSettle();
      expect(driver.refreshes, 1);
      await tester.ensureVisible(find.text('同步已关闭分段'));
      await tester.tap(find.text('同步已关闭分段'));
      await tester.pumpAndSettle();
      expect(driver.saves, 1);
      expect(driver.lastSyncedSession, 123);
      await tester.ensureVisible(find.textContaining('正在长录，自动保存已关闭分段'));
      await tester.pumpAndSettle();
      await screenshot(tester, key, 'long-files-active-${purpose.name}');
      await tester.scrollUntilVisible(find.text('保存到手机'), 150);
      expect(tester.widget<OutlinedButton>(_button('保存到手机')).onPressed, isNull);
      expect(driver.saves, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'stop waits for tail scan and validation before whole recording playback',
      (tester) async {
    final driver = _LibraryDriver(
        ready: true,
        recording: true,
        library: RecorderLongFileLibrary(
            loaded: true,
            activeSessionId: 123,
            recordings: [
              _record(stage: RecorderLongFileStage.recording, parts: 2),
            ]));
    final key = await open(tester, driver, _LocalAudio());
    expect(find.text('同步已关闭分段'), findsOneWidget);
    driver.recording = false;
    driver.replace(RecorderLongFileLibrary(
        loaded: true,
        busy: true,
        message: '停止后正在确认尾段',
        recordings: [
          _record(stage: RecorderLongFileStage.waitingForTail, parts: 3),
        ]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('等待尾段确认'), findsOneWidget);
    expect(find.text('播放本机录音'), findsNothing);
    expect(tester.widget<OutlinedButton>(_button('继续恢复并保存')).onPressed, isNull);
    await screenshot(tester, key, 'long-files-stopped-tail-scan');
    driver.replace(RecorderLongFileLibrary(
        loaded: true,
        busy: true,
        recordings: [
          _record(stage: RecorderLongFileStage.preparing, parts: 3)
        ]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在校验和准备播放'), findsOneWidget);
    expect(find.text('播放本机录音'), findsNothing);
    driver.replace(RecorderLongFileLibrary(
        loaded: true,
        recordings: [_record(stage: RecorderLongFileStage.saved, parts: 3)]));
    await tester.pumpAndSettle();
    expect(find.text('已保存到手机'), findsOneWidget);
    expect(find.text('播放本机录音'), findsOneWidget);
    expect(find.text('同步已关闭分段'), findsNothing);
    expect(find.textContaining('转写'), findsOneWidget);
    expect(driver.saves, 0);
    expect(tester.takeException(), isNull);
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/recordings/recording_background.dart';
import 'package:sunmate_app/core/recordings/recording_processing_controller.dart';
import 'package:sunmate_app/core/recordings/recording_processing_models.dart';
import 'package:sunmate_app/core/hardware/recorder_long_recordings.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'package:sunmate_app/core/sync/archive_sync.dart';
import 'package:sunmate_app/core/sync/archive_models.dart';
import 'package:sunmate_app/providers/recording_background_provider.dart';
import 'package:sunmate_app/views/recording_background_page.dart';
import 'recording_processing_test.dart'
    show MemoryContent, ProcessingFixture, sn, session;
import 'archive_sync_test.dart' show SyncSecure, SyncRemote;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'reconciliation isolates old upload receipts from the currently paired library',
      () async {
    SharedPreferences.setMockInitialValues({});
    final f = ProcessingFixture();
    await f.open();
    addTearDown(f.close);
    final secure = SyncSecure();
    final config = ArchiveSyncConfig(
        url: 'http://127.0.0.1/sunmate/v1',
        token: 'synthetic',
        identity: SyncRemote.identity);
    secure.value = jsonEncode(config.toJson());
    final archive = ArchiveSyncController(
        store: f.memory, secure: secure, sources: () async => []);
    addTearDown(archive.dispose);
    await archive.ready;
    final target = jsonEncode(canonicalValue([config.url, config.identity]));
    final owner = RecordingWorkOwnership(f.memory);
    await owner.ready;
    owner.target = target;
    owner.policyTarget = target;
    owner.policy = owner.policy.changed('meetingUpload', true);
    final driver =
        AiNote6095Driver(longFileStore: f.store, localAudio: f.audio);
    addTearDown(driver.dispose);
    final c = RecordingBackgroundController(
        store: f.memory,
        ownership: owner,
        archive: archive,
        processing: f.c,
        driver: driver,
        supported: true,
        native: (method, args) async => method == 'snapshot'
            ? {
                'events': [],
                'transfers': [
                  {'target': 'other-library', 'id': 'old', 'state': 'received'},
                  {'target': target, 'id': 'current', 'state': 'received'}
                ]
              }
            : true,
        exchange: (_, action, value) async => action == 'policy'
            ? {'schema': 'sunmate.audio.v1', ...value, 'processorEnabled': true}
            : {'schema': 'sunmate.audio.v1', 'changes': [], 'cursor': 0});
    addTearDown(c.dispose);
    await c.ready;
    await c.refresh();
    expect(c.transfers.single['id'], 'current');
    expect(f.asr.submits + f.agent.meetings + f.agent.reviews, 0);
  });
  test(
      'server receipts seed revision one; visibility revocation uses revision two without resending text',
      () async {
    final memory = MemoryContent(),
        secure = SyncSecure(),
        remote = SyncRemote();
    final config = ArchiveSyncConfig(
        url: 'http://127.0.0.1/sunmate/v1',
        token: 'synthetic',
        identity: SyncRemote.identity);
    secure.value = jsonEncode(config.toJson());
    final source = ArchiveSource(
        'server-transcript:synthetic',
        'transcript',
        'meeting',
        DateTime.utc(2026, 10, 21),
        {'purpose': 'meeting', 'text': '合成转写'});
    var current = source;
    final c = ArchiveSyncController(
        store: memory,
        secure: secure,
        sources: () async => [current],
        transport: (_, __) => remote);
    addTearDown(c.dispose);
    await c.ready;
    final record = {...source.body, 'revision': 1, 'sha': await source.sha};
    remote.saved[remote.key(record)] = record;
    final target = jsonEncode(canonicalValue([config.url, config.identity]));
    await c.adoptServerRecord(source.body, target);
    expect(c.confirmed, 1);
    expect(remote.bodies, isEmpty);
    current = ArchiveSource(
        source.id, source.kind, source.category, source.time, source.payload,
        visible: false);
    await c.refresh();
    expect(remote.bodies.length, 1);
    expect(remote.bodies.single['revision'], 2);
    expect(remote.bodies.single['visible'], false);
    await c.adoptServerRecord(source.body, target);
    expect(remote.bodies.length, 1);
    await expectLater(c.adoptServerRecord(source.body, 'other-target'),
        throwsA(isA<ArchiveSyncException>()));
  });
  test('new defaults, dependencies, and policy corruption fail closed', () {
    final empty = RecordingBackgroundPolicy();
    expect(empty.any, false);
    final on = empty.changed('meetingSummary', true);
    expect(
        on['meetingSummary'] && on['meetingAsr'] && on['meetingUpload'], true);
    expect(on['lifelogUpload'], false);
    final off = on.changed('meetingUpload', false);
    expect(off['meetingSummary'] || off['meetingAsr'] || off['meetingUpload'],
        false);
    expect(on.changed('meetingAsr', false)['meetingSummary'], false);
    expect(
        () => RecordingBackgroundPolicy.fromJson({
              'revision': 1,
              'policy': {'meetingAsr': true}
            }),
        throwsFormatException);
  });

  test(
      'session ownership is durable, bound to the target, and never stolen by later settings',
      () async {
    final memory = MemoryContent();
    final owner = RecordingWorkOwnership(memory);
    await owner.ready;
    owner.target = 'synthetic-library';
    await owner.capture(RecordingSegmentSignal(
        SegmentSignalKind.started, sn, session,
        purpose: LongRecordingPurpose.meeting));
    owner.policy = owner.policy.changed('meetingAsr', true);
    await owner.capture(RecordingSegmentSignal(
        SegmentSignalKind.started, sn, session,
        purpose: LongRecordingPurpose.meeting));
    expect(owner.serverAsr('$sn:$session'), false);
    await owner.capture(RecordingSegmentSignal(
        SegmentSignalKind.started, sn, session + 1,
        purpose: LongRecordingPurpose.meeting));
    expect(owner.serverAsr('$sn:${session + 1}'), true);
    final restored = RecordingWorkOwnership(memory);
    await restored.ready;
    restored.target = 'other-library';
    expect(restored.serverAsr('$sn:${session + 1}'), true);
    expect(restored.current('$sn:${session + 1}'), false);
    expect(memory.data['background_owners']!.length, 2);
  });

  for (final purpose in LongRecordingPurpose.values) {
    test(
        '${purpose.name} server-owned ASR excludes phone submission and validates source/time before importing',
        () async {
      final f = ProcessingFixture();
      await f.open();
      addTearDown(f.close);
      f.c.dispose();
      f.c = RecordingProcessingController(
          content: f.memory,
          audioStore: f.store,
          audio: f.audio,
          asr: () => f.asr,
          agent: () => f.agent,
          serverOwnedAsr: (_) => true);
      await f.c.ready;
      await f.c.setPolicy(const ProcessingPolicy(
          meetingTranscribe: true,
          meetingSummary: true,
          lifelogTranscribe: true));
      await f.start(purpose: purpose);
      final p = await f.add(0, purpose: purpose);
      await f.c.resume();
      expect(f.asr.submits, 0);
      await expectLater(
          f.c.transcribePart(p), throwsA(isA<RecordingProcessingException>()));
      final meta = {
        'session': p.sessionId,
        'part': 0,
        'sourceSha': p.source.sha256,
        'samples48': p.samples48,
        'lead48': p.leadSamples48,
        'offset48': p.offsetSamples48
      };
      final result = {'text': '合成服务器转写', 'spans': <dynamic>[]};
      await expectLater(
          f.c.acceptServerTranscript({...meta, 'sourceSha': 'b' * 64}, result),
          throwsFormatException);
      expect(f.c.transcript(p), null);
      await f.c.acceptServerTranscript(meta, result);
      expect(f.c.transcript(p)!.text, '合成服务器转写');
      await f.c.acceptServerTranscript(
          meta, {'text': '不得覆盖已保存结果', 'spans': <dynamic>[]});
      expect(f.c.transcript(p)!.text, '合成服务器转写');
      await f.finish(purpose: purpose);
      await f.c.archiveImportedSession(p.sessionId);
      expect((await f.store.loadRecords()).single.canPlay, true);
      await f.c.acceptServerSummary('synthetic-remote-result', {
        'session': p.sessionId,
        'purpose': purpose.name,
        'parts': ['remote-part'],
        'text': '合成总结'
      });
      expect(f.c.summaries.single.kind, purpose.name);
      expect(await f.c.summaryCurrent(f.c.summaries.single), true);
      expect(f.agent.meetings + f.agent.reviews, 0);
      final saved = f.memory.data['transcripts']!.values.single;
      expect(saved['stage'], 'complete');
      expect(f.asr.submits, 0);
    });
  }

  testWidgets(
      'background page defaults off, exposes both purposes and finite iOS limits',
      (tester) async {
    const capture = bool.fromEnvironment('SUNMATE_CAPTURE_BACKGROUND_UI');
    final imageKey = GlobalKey();
    Future<void> screenshot(String name) async {
      if (!capture) return;
      await tester.runAsync(() async {
        final boundary = imageKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final directory = await Directory(
                '/Users/m/Documents/VS/sunmate/build_output/recorder-background-local')
            .create(recursive: true);
        await File('${directory.path}/$name.png')
            .writeAsBytes(data.buffer.asUint8List());
        image.dispose();
      });
    }

    if (capture) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.runAsync(() async {
        for (final e in {
          'BackgroundFixture':
              '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
          'MaterialIcons':
              '/private/tmp/sunmate-flutter-sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'
        }.entries) {
          await (FontLoader(e.key)
                ..addFont(File(e.value)
                    .readAsBytes()
                    .then((b) => b.buffer.asByteData())))
              .load();
        }
      });
    }
    SharedPreferences.setMockInitialValues({});
    late ProcessingFixture f;
    late ArchiveSyncController archive;
    late RecordingBackgroundController c;
    late AiNote6095Driver driver;
    var nativeCalls = 0, network = 0;
    await tester.runAsync(() async {
      f = ProcessingFixture();
      await f.open();
      final secure = SyncSecure();
      secure.value = jsonEncode(ArchiveSyncConfig(
              url: 'http://127.0.0.1/sunmate/v1',
              token: 'synthetic',
              identity: SyncRemote.identity)
          .toJson());
      archive = ArchiveSyncController(
          store: f.memory, secure: secure, sources: () async => []);
      await archive.ready;
      final owner = RecordingWorkOwnership(f.memory);
      await owner.ready;
      driver = AiNote6095Driver(longFileStore: f.store, localAudio: f.audio);
      c = RecordingBackgroundController(
          store: f.memory,
          ownership: owner,
          archive: archive,
          processing: f.c,
          driver: driver,
          supported: true,
          native: (_, __) async {
            nativeCalls++;
            return {};
          },
          exchange: (_, __, ___) async {
            network++;
            return {};
          });
      await c.ready;
      await c.refresh();
    });
    expect(nativeCalls, 0);
    expect(network, 0);
    await tester.pumpWidget(ProviderScope(
        overrides: [recordingBackgroundProvider.overrideWith((ref) => c)],
        child: RepaintBoundary(
            key: imageKey,
            child: MaterialApp(
                theme:
                    ThemeData(fontFamily: capture ? 'BackgroundFixture' : null),
                home: const RecordingBackgroundPage()))));
    await tester.pump();
    expect(find.text('后台蓝牙收段'), findsOneWidget);
    await screenshot('background-top');
    expect(
        tester
            .widgetList<SwitchListTile>(find.byType(SwitchListTile))
            .every((w) => !w.value),
        true);
    await tester.scrollUntilVisible(find.text('本次随身录音结束后自动复盘'), 250);
    expect(find.text('本次随身录音结束后自动复盘'), findsOneWidget);
    await tester.pump();
    await screenshot('background-lifelog');
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox());
    archive.dispose();
    await tester.runAsync(f.close);
    await tester.runAsync(driver.dispose);
  });
}

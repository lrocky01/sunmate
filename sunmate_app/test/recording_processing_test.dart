import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ai/agent_client.dart';
import 'package:sunmate_app/core/ai/asr_service.dart';
import 'package:sunmate_app/core/audio/recorder_local_audio.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_store.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_models.dart';
import 'package:sunmate_app/core/hardware/recorder_long_recordings.dart';
import 'package:sunmate_app/core/recordings/local_content_store.dart';
import 'package:sunmate_app/core/recordings/recording_processing_models.dart';
import 'package:sunmate_app/core/recordings/recording_processing_controller.dart';
import 'package:sunmate_app/models/timeline_entry.dart';
import 'recorder_long_file_store_test.dart' show ops, pages;

const sn = 'AB00000000000001';
const session = 1792496000000;

class MemoryContent implements RecordingContentStore {
  final data = <String, Map<String, Map<String, dynamic>>>{};
  bool fail = false;
  @override
  Future<List<Map<String, dynamic>>> readAll(String collection) async =>
      (jsonDecode(jsonEncode(data[collection]?.values.toList() ?? [])) as List)
          .cast<Map<String, dynamic>>();
  @override
  Future<void> put(
      String collection, String id, Map<String, dynamic> record) async {
    if (fail) throw const FileSystemException('synthetic storage failure');
    (data[collection] ??= {})[id] =
        jsonDecode(jsonEncode({...record, 'id': id, 'version': 1}));
  }
}

class SegmentAudio implements RecorderLocalAudio {
  final RecorderLongFileStore store;
  int calls = 0;
  bool reject = false;
  SegmentAudio(this.store);
  @override
  Future<PreparedRecorderAudio> prepare(String path) async {
    calls++;
    if (reject) throw const FormatException('synthetic reject');
    final bytes = await (await store.resolveRelative(path)).readAsBytes();
    final parsed = pages(bytes);
    final preSkip =
        ByteData.sublistView(parsed.first).getUint16(28 + 10, Endian.little);
    final granule =
        ByteData.sublistView(parsed.last).getUint64(6, Endian.little);
    final frames = (granule - preSkip) ~/ 3;
    final relative = path.replaceAll('.ogg', '.wav');
    await (await store.resolveRelative(relative))
        .writeAsBytes(List.filled(44 + frames * 2, 0));
    return PreparedRecorderAudio(
        relativePath: relative,
        durationMs: frames * 1000 ~/ 16000,
        sampleRate: 16000,
        frames: frames);
  }

  @override
  Future<void> play(String path) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<RecorderAudioPlaybackState> state() async =>
      const RecorderAudioPlaybackState();
}

class SegmentAsr extends AsrService {
  int submits = 0, polls = 0;
  bool unknown = false, failPoll = false, throwSubmit = false;
  Completer<void>? gate;
  AsrResult result = AsrResult(success: true, rawText: '合成转写', segments: [
    DiarizedSegment(speaker: '0', start: 0, end: .5, text: '合成转写')
  ]);
  @override
  Future<String?> submitJobFile(String path, {required String filename}) async {
    submits++;
    if (gate != null) await gate!.future;
    if (throwSubmit) throw const SocketException('synthetic');
    return unknown ? null : 'synthetic-$submits';
  }

  @override
  Future<AsrResult> pollJobResult(String id,
      {Duration pollInterval = const Duration(seconds: 2),
      int maxAttempts = 150}) async {
    polls++;
    return failPoll ? AsrResult(success: false) : result;
  }
}

class SegmentAgent extends AgentClient {
  int meetings = 0, reviews = 0;
  bool fail = false;
  String input = '';
  Completer<void>? gate;
  @override
  Future<Map<String, dynamic>> summarizeMeetingWithDiarization(
      {required List<DiarizedSegment> segments,
      required String rawText}) async {
    meetings++;
    input = rawText;
    if (gate != null) await gate!.future;
    if (fail) throw StateError('synthetic failure');
    return {'summary': '合成会议结果', 'actionItems': <String>[]};
  }

  @override
  Future<String> generateDailyLifelogReview(
      {required List<String> timeBlockEvents,
      required List<String> notifications}) async {
    reviews++;
    input = [...timeBlockEvents, ...notifications].join('\n');
    return '合成复盘';
  }
}

class ProcessingFixture {
  late Directory directory;
  late RecorderLongFileStore store;
  late SegmentAudio audio;
  final memory = MemoryContent(), asr = SegmentAsr(), agent = SegmentAgent();
  late RecordingProcessingController c;
  final allowed = <String>{'com.example.synthetic'};
  Future<void> open() async {
    directory = await Directory.systemTemp.createTemp('sm-segment-processing-');
    store = RecorderLongFileStore(
        rootDirectory: () async =>
            Directory('${directory.path}/recorder_long_audio_v1'));
    audio = SegmentAudio(store);
    await reopen();
  }

  Future<void> reopen() async {
    c = RecordingProcessingController(
        content: memory,
        audioStore: store,
        audio: audio,
        asr: () => asr,
        agent: () => agent,
        allowsNotification: allowed.contains);
    await c.ready;
  }

  Future<void> start(
          {LongRecordingPurpose? purpose = LongRecordingPurpose.meeting,
          int id = session}) =>
      c.accept(RecordingSegmentSignal(SegmentSignalKind.started, sn, id,
          purpose: purpose, observed: DateTime.fromMillisecondsSinceEpoch(id)));
  Future<RecorderCommittedSegment> commit(int part,
      {int count = 50, int id = session, int toc = 0xf8}) async {
    final bytes = ops(List.generate(count, (_) => [toc, 0xff, 0xfe]));
    final temp = await store.createTemporarySegment(sn, id, part);
    await temp.writeAsBytes(bytes);
    return store.commitSegment(sn, id, part, bytes.length, temp);
  }

  Future<ProcessingPart> add(int part,
      {LongRecordingPurpose purpose = LongRecordingPurpose.meeting,
      int id = session,
      int count = 50}) async {
    final source = await commit(part, id: id, count: count);
    await c.accept(RecordingSegmentSignal(SegmentSignalKind.source, sn, id,
        purpose: purpose, source: source));
    return c
        .partsOf(sessionKey(sn, id))
        .firstWhere((p) => p.source.part == part);
  }

  Future<void> finish(
          {int parts = 1,
          int id = session,
          LongRecordingPurpose purpose = LongRecordingPurpose.meeting}) =>
      c.accept(RecordingSegmentSignal(SegmentSignalKind.finalized, sn, id,
          purpose: purpose, totalParts: parts));
  Future<void> close() async {
    if (!c.disposed) c.dispose();
    await directory.delete(recursive: true);
  }
}

TimelineEntry notice(
        {String id = 'notice',
        String app = 'com.example.synthetic',
        int offset = 100}) =>
    TimelineEntry(
        id: id,
        timestamp: DateTime.fromMillisecondsSinceEpoch(session + offset),
        sourceType: TimelineSourceType.appNotification,
        sourceApp: '合成应用',
        appIdentifier: app,
        content: '合成通知正文');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProcessingFixture f;
  setUp(() async {
    f = ProcessingFixture();
    await f.open();
  });
  tearDown(() async => f.close());
  test(
      'default closed segment packages locally while active, no remote request; lazy playback',
      () async {
    await f.start();
    final p = await f.add(0);
    await f.c.resume();
    expect(p.ready, true);
    expect(f.c.sessionComplete(f.c.sessions.single), false);
    expect(f.asr.submits, 0);
    expect(f.agent.meetings, 0);
    expect(f.audio.calls, 0);
    expect((await f.c.preparePlayback(p)).frames, 16000);
    expect(f.asr.submits, 0);
  });
  test(
      'part waits previous context; offset uses exact samples, no fixed duration',
      () async {
    await f.start();
    final p1 = await f.add(1, count: 25);
    expect(p1.ready, false);
    expect(p1.offsetMs, null);
    final p0 = await f.add(0);
    expect(p1.ready, true);
    expect(p1.leadSamples48, 48000);
    expect(p0.durationMs, 1000);
    expect(p1.durationMs, 500);
    expect(p1.offsetMs, 1000);
    expect((await f.c.preparePlayback(p1)).frames, 8000);
  });
  test('missing prefix keeps later offsets unlocated, whole summary prohibited',
      () async {
    await f.add(2);
    final p = await f.add(3);
    expect(p.ready, true);
    expect(p.offsetMs, null);
    expect(f.c.absoluteStart(p), null);
    await expectLater(f.c.summarizeMeeting(f.c.sessions.single.id),
        throwsA(isA<RecordingProcessingException>()));
    expect(f.asr.submits, 0);
  });
  test(
      'new start captures off policy, enable mid-session never auto uploads history',
      () async {
    await f.start();
    await f.c.setPolicy(const ProcessingPolicy(meetingTranscribe: true));
    await f.add(0);
    await f.c.resume();
    expect(f.asr.submits, 0);
    await f.start(id: session + 10000);
    await f.add(0, id: session + 10000);
    await f.c.resume();
    expect(f.asr.submits, 1);
  });
  test(
      'start with unknown purpose captures complete policy until source resolves',
      () async {
    await f.c.setPolicy(const ProcessingPolicy(lifelogTranscribe: true));
    await f.start(purpose: null);
    await f.add(0, purpose: LongRecordingPurpose.lifelog);
    await f.c.resume();
    expect(f.asr.submits, 1);
    expect(f.c.timelineEntries.single.recordingPartId, isNotNull);
  });
  test('settings round trip and save failure preserve previous policy',
      () async {
    expect(
        await f.c.setPolicy(const ProcessingPolicy(
            meetingTranscribe: true, meetingSummary: true)),
        true);
    f.c.dispose();
    await f.reopen();
    expect(f.c.policy.meetingSummary, true);
    f.memory.fail = true;
    expect(await f.c.setPolicy(const ProcessingPolicy()), false);
    expect(f.c.policy.meetingSummary, true);
  });
  test(
      'successful transcript and summary reopen, source unchanged never uploads again',
      () async {
    await f.start();
    final p = await f.add(0);
    await f.finish();
    expect(await f.c.transcribePart(p), true);
    final summary = await f.c.summarizeMeeting(p.sessionId);
    expect(await f.c.summaryCurrent(summary), true);
    f.c.dispose();
    await f.reopen();
    final next = f.c.partsOf(p.sessionId).single;
    expect(f.c.transcript(next)!.text, '合成转写');
    expect(await f.c.transcribePart(next), true);
    await f.c.summarizeMeeting(p.sessionId);
    expect(f.asr.submits, 1);
    expect(f.agent.meetings, 1);
  });
  for (final throwsSubmit in [false, true])
    test('unknown submit $throwsSubmit never repeats without explicit consent',
        () async {
      final p = await f.add(0);
      f.asr.unknown = true;
      f.asr.throwSubmit = throwsSubmit;
      expect(await f.c.transcribePart(p), false);
      expect(f.c.transcript(p)!.stage, TranscriptionStage.submissionUnknown);
      f.c.dispose();
      await f.reopen();
      await f.c.resume();
      expect(f.asr.submits, 1);
      await expectLater(f.c.transcribePart(f.c.partsOf(p.sessionId).single),
          throwsA(isA<RecordingProcessingException>()));
      f.asr.unknown = false;
      f.asr.throwSubmit = false;
      expect(
          await f.c.transcribePart(f.c.partsOf(p.sessionId).single,
              confirmResubmit: true),
          true);
      expect(f.asr.submits, 2);
    });
  test('known task polls after reopen instead of upload', () async {
    final p = await f.add(0);
    f.asr.failPoll = true;
    expect(await f.c.transcribePart(p), false);
    expect(f.c.transcript(p)!.job, isNotNull);
    f.c.dispose();
    await f.reopen();
    f.asr.failPoll = false;
    await f.c.resume();
    expect(f.asr.submits, 1);
    expect(f.asr.polls, 2);
  });
  test('queued after previous request starts drains serially', () async {
    final p0 = await f.add(0), p1 = await f.add(1);
    f.asr.gate = Completer<void>();
    final a = f.c.transcribePart(p0);
    while (f.asr.submits == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final b = f.c.transcribePart(p1);
    f.asr.gate!.complete();
    await Future.wait([a, b]);
    expect(f.asr.submits, 2);
  });
  test('ASR boundary context clipped, exact overlap dedup and speakers scoped',
      () async {
    final p0 = await f.add(0), p1 = await f.add(1);
    f.asr.result = AsrResult(success: true, rawText: '前段共同末尾', segments: [
      DiarizedSegment(speaker: '0', start: 0, end: 1, text: '前段共同末尾')
    ]);
    await f.c.transcribePart(p0);
    f.asr.result = AsrResult(success: true, rawText: '上下文', segments: [
      DiarizedSegment(speaker: '0', start: 0, end: .9, text: '纯上下文'),
      DiarizedSegment(speaker: '0', start: 1, end: 1.9, text: '共同末尾新的内容')
    ]);
    await f.c.transcribePart(p1);
    final result = f.c.transcript(p1)!;
    expect(result.text, '新的内容');
    expect(result.spans.single.text, '新的内容');
    expect(result.spans.single.start, 0);
    expect(result.spans.single.speaker, '段2/0');
  });
  test(
      'context-only ASR result remains silent, never resurrected as current speech',
      () async {
    await f.add(0);
    final p = await f.add(1);
    f.asr.result = AsrResult(success: true, rawText: '前段内容', segments: [
      DiarizedSegment(speaker: '0', start: 0, end: .9, text: '前段内容')
    ]);
    await f.c.transcribePart(p);
    expect(f.c.transcript(p)!.text, isEmpty);
  });
  test(
      'uncertain continuity removes absolute association but keeps text and relative offsets',
      () async {
    await f.start(purpose: LongRecordingPurpose.lifelog);
    final p = await f.add(0, purpose: LongRecordingPurpose.lifelog);
    await f.c.transcribePart(p);
    expect(f.c.timelineEntries.length, 1);
    await f.c.accept(
        RecordingSegmentSignal(SegmentSignalKind.uncertain, sn, session));
    expect(f.c.absoluteStart(p), null);
    expect(p.offsetMs, 0);
    expect(f.c.timelineEntries, isEmpty);
    expect(f.c.transcript(p)!.text, isNotEmpty);
  });
  test(
      'clock mismatch invalidates absolute time; UTC across day offset remains consistent',
      () async {
    await f.c.accept(RecordingSegmentSignal(
        SegmentSignalKind.started, sn, session,
        observed: DateTime.fromMillisecondsSinceEpoch(session + 3600000)));
    final p = await f.add(0);
    expect(f.c.absoluteStart(p), null);
    final id = DateTime.utc(2026, 10, 20, 23, 59, 59).millisecondsSinceEpoch;
    await f.start(id: id);
    await f.add(0, id: id, count: 100);
    final second = await f.add(1, id: id);
    expect(f.c.absoluteStart(second), DateTime.utc(2026, 10, 21, 0, 0, 1));
  });
  test(
      'notifications persist only if allowed, stable ID replaces, switches filter future summaries',
      () async {
    await f.c.addTimelineEntry(notice());
    await f.c.addTimelineEntry(notice());
    await f.c.addTimelineEntry(notice(id: 'denied', app: 'com.denied'));
    f.c.dispose();
    await f.reopen();
    expect(f.c.timelineEntries.length, 1);
    expect((await f.memory.readAll('notifications')).length, 1);
    f.allowed.clear();
    expect(f.c.timelineEntries, isEmpty);
    await expectLater(
        f.c.summarizeLifelog(DateTime.fromMillisecondsSinceEpoch(session),
            DateTime.fromMillisecondsSinceEpoch(session + 2000)),
        throwsA(isA<RecordingProcessingException>()));
    expect(f.agent.reviews, 0);
  });
  test(
      'lifelog selected range fills transcriptions, contains timestamped speech and allowed notification',
      () async {
    await f.start(purpose: LongRecordingPurpose.lifelog);
    final p = await f.add(0, purpose: LongRecordingPurpose.lifelog);
    await f.finish(purpose: LongRecordingPurpose.lifelog);
    await f.c.addTimelineEntry(notice());
    final saved = await f.c.summarizeLifelog(
        DateTime.fromMillisecondsSinceEpoch(session),
        DateTime.fromMillisecondsSinceEpoch(session + 2000));
    expect(f.asr.submits, 1);
    expect(f.agent.input, contains('合成通知正文'));
    expect(f.agent.input, contains('合成转写'));
    expect(saved.partial, false);
    expect(f.c.transcript(p)!.spans.single.start, 0);
    expect(await f.c.summaryCurrent(saved), true);
    await f.c.addTimelineEntry(notice(id: 'new'));
    expect(await f.c.summaryCurrent(saved), false);
  });
  test(
      'unknown lifelog blocks full summary; explicit partial preserves coverage warning',
      () async {
    await f.add(1, purpose: LongRecordingPurpose.lifelog);
    await f.c.addTimelineEntry(notice());
    final from = DateTime.fromMillisecondsSinceEpoch(session),
        to = DateTime.fromMillisecondsSinceEpoch(session + 2000);
    await expectLater(f.c.summarizeLifelog(from, to),
        throwsA(isA<RecordingProcessingException>()));
    final saved = await f.c.summarizeLifelog(from, to, allowPartial: true);
    expect(saved.partial, true);
    expect(saved.text, contains('部分范围复盘'));
    expect(f.asr.submits, 0);
  });
  test('concurrent summary requests share one Hermes request', () async {
    final p = await f.add(0);
    await f.finish();
    await f.c.transcribePart(p);
    f.agent.gate = Completer<void>();
    final a = f.c.summarizeMeeting(p.sessionId),
        b = f.c.summarizeMeeting(p.sessionId);
    while (f.agent.meetings == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    f.agent.gate!.complete();
    final results = await Future.wait([a, b]);
    expect(f.agent.meetings, 1);
    expect(results.first.id, results.last.id);
  });
  test(
      'auto summary waits final proof; failure pauses across foreground and reopen',
      () async {
    await f.c.setPolicy(
        const ProcessingPolicy(meetingTranscribe: true, meetingSummary: true));
    await f.start();
    await f.add(0);
    await f.c.resume();
    expect(f.agent.meetings, 0);
    f.agent.fail = true;
    await f.finish();
    await f.c.resume();
    expect(f.agent.meetings, 1);
    await f.c.resume();
    expect(f.agent.meetings, 1);
    f.c.dispose();
    await f.reopen();
    await f.c.resume();
    expect(f.agent.meetings, 1);
  });
  test('derived source change retains old version and marks old summary stale',
      () async {
    final p = await f.add(0);
    await f.finish();
    await f.c.transcribePart(p);
    final summary = await f.c.summarizeMeeting(p.sessionId);
    final next = await f.add(0, count: 25);
    expect(next.id, isNot(p.id));
    expect(p.active, false);
    expect(await f.c.summaryCurrent(summary), false);
    expect((await f.memory.readAll('parts')).length, 2);
    expect(
        await (await f.store.resolveRelative(p.source.relativePath)).exists(),
        true);
  });
  test('corrupt source cannot play or upload, no deletion', () async {
    final p = await f.add(0);
    final file = await f.store.resolveRelative(p.source.relativePath);
    await file.writeAsBytes([1, 2, 3]);
    await expectLater(f.c.preparePlayback(p), throwsA(anything));
    expect(await f.c.transcribePart(p), false);
    expect(f.asr.submits, 0);
    expect(await file.exists(), true);
  });
  test(
      'private content store hashes filenames, reads atomically, refuses damaged record',
      () async {
    final directory = Directory('${f.directory.path}/content');
    final store = FileRecordingContentStore(root: () async => directory);
    await store.put('notifications', 'identifier', {'content': '合成正文'});
    await store.put('notifications', 'identifier', {'content': '更新正文'});
    expect((await store.readAll('notifications')).single['content'], '更新正文');
    final file =
        (await Directory('${directory.path}/notifications').list().toList())
            .single as File;
    expect(file.path, isNot(contains('identifier')));
    await file.writeAsString('invalid');
    await expectLater(
        store.put('notifications', 'identifier', {}), throwsA(anything));
    expect(await file.readAsString(), 'invalid');
  });
  test('invalid index fails closed, cannot change settings or overwrite',
      () async {
    f.c.dispose();
    f.memory.data['parts'] = {
      'bad': {'id': 'bad'}
    };
    await f.reopen();
    expect(f.c.loaded, false);
    expect(await f.c.setPolicy(const ProcessingPolicy(meetingTranscribe: true)),
        false);
  });
  test('existing task never queries a different private ASR node', () async {
    final p = await f.add(0);
    f.asr.failPoll = true;
    await f.c.transcribePart(p);
    expect(f.asr.polls, 1);
    f.asr.serverBaseUrl = 'http://192.0.2.7:8000';
    await f.c.resume();
    expect(f.asr.polls, 1);
    expect(f.asr.submits, 1);
    expect(f.c.transcript(p)!.message, contains('节点已变化'));
  });
  test(
      'large summaries reduce bounded batches, retain intermediate results and reuse',
      () async {
    final p = await f.add(0);
    await f.finish();
    f.asr.result =
        AsrResult(success: true, rawText: List.filled(16000, '测').join());
    await f.c.transcribePart(p);
    final summary = await f.c.summarizeMeeting(p.sessionId);
    expect(f.agent.meetings, greaterThan(1));
    expect(summary.text, isNotEmpty);
    expect(
        f.memory.data['summaries']!.values
            .any((v) => v['kind'] == 'intermediate'),
        true);
    final count = f.agent.meetings;
    await f.c.summarizeMeeting(p.sessionId);
    expect(f.agent.meetings, count);
  });
  test(
      'tampered derived audio is rejected before native decode or ASR submission',
      () async {
    final p = await f.add(0);
    final file = await f.store.resolveRelative(p.ogg!);
    final bytes = await file.readAsBytes();
    bytes[bytes.length - 1] ^= 1;
    await file.writeAsBytes(bytes);
    await expectLater(f.c.preparePlayback(p), throwsA(anything));
    expect(await f.c.transcribePart(p), false);
    expect(f.asr.submits, 0);
    expect(f.audio.calls, 0);
  });
}

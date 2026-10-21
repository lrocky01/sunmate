import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/audio/recorder_local_audio.dart';
import 'package:sunmate_app/core/audio/recording_overview_playback.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_models.dart';
import 'package:sunmate_app/core/hardware/recorder_long_recordings.dart';
import 'recording_processing_test.dart'
    show ProcessingFixture, SegmentAudio, sn, session;

class OverviewAudio extends SegmentAudio {
  OverviewAudio(super.store);
  int plays = 0, stops = 0;
  bool wrongReceipt = false, failPlay = false;
  RecorderAudioPlaybackState current = const RecorderAudioPlaybackState();
  Completer<void>? gate;
  @override
  Future<PreparedRecorderAudio> prepare(String path) async {
    if (gate != null) await gate!.future;
    final r = await super.prepare(path);
    return PreparedRecorderAudio(
        relativePath: r.relativePath,
        durationMs: r.durationMs + (wrongReceipt ? 1 : 0),
        sampleRate: r.sampleRate,
        frames: r.frames);
  }

  @override
  Future<void> play(String path) async {
    if (failPlay) throw StateError('synthetic failure');
    plays++;
    current = RecorderAudioPlaybackState(
        isPlaying: true, relativePath: path, positionMs: 0, durationMs: 1000);
  }

  @override
  Future<void> stop() async {
    stops++;
    current = const RecorderAudioPlaybackState();
  }

  @override
  Future<RecorderAudioPlaybackState> state() async => current;
}

Future<RecorderLongAudioRecord> createMeetingArchive(
    ProcessingFixture f, OverviewAudio audio) async {
  final p = await f.add(0);
  await f.finish();
  final full = await f.store.assemble(sn, session, [p.source]);
  final prepared = await audio.prepare(full.relativePath);
  final record = RecorderLongAudioRecord(
      serialNumber: sn,
      sessionId: session,
      purpose: LongRecordingPurpose.meeting,
      stage: RecorderLongFileStage.saved,
      totalParts: 1,
      downloadedParts: 1,
      relativeOggPath: full.relativePath,
      relativePlayablePath: prepared.relativePath,
      durationMs: prepared.durationMs);
  await f.store.saveRecord(record);
  return record;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProcessingFixture f;
  late OverviewAudio audio;
  late RecordingOverviewPlayback player;
  setUp(() async {
    f = ProcessingFixture();
    await f.open();
    audio = OverviewAudio(f.store);
    player = RecordingOverviewPlayback(store: f.store, audio: audio);
  });
  tearDown(() async {
    if (!player.disposed) player.dispose();
    await Future<void>.delayed(Duration.zero);
    await f.close();
  });
  test('whole meeting verified from disk plays offline without ASR or Hermes',
      () async {
    final record = await createMeetingArchive(f, audio);
    await player.playMeeting(record);
    expect(audio.plays, 1);
    expect(player.playing(RecordingOverviewPlayback.meetingKey(sn, session)),
        true);
    expect(player.error, null);
    expect(f.asr.submits, 0);
    expect(f.agent.meetings, 0);
    await player.playMeeting(record);
    expect(audio.stops, 1);
    expect(player.playback.isPlaying, false);
  });
  test('stale selected archive never uses changed disk provenance', () async {
    final record = await createMeetingArchive(f, audio);
    await f.store.saveRecord(
        record.copyWith(inventoryFingerprint: List.filled(64, 'a').join()));
    await player.playMeeting(record);
    expect(audio.plays, 0);
    expect(player.error, isNotNull);
  });
  test('invalid native receipt never reaches play', () async {
    final record = await createMeetingArchive(f, audio);
    audio.wrongReceipt = true;
    await player.playMeeting(record);
    expect(audio.plays, 0);
    expect(player.error, isNotNull);
    expect(
        await (await f.store.resolveRelative(record.relativeOggPath!)).exists(),
        true);
  });
  test('missing whole audio never silently plays a different source', () async {
    final record = await createMeetingArchive(f, audio);
    await (await f.store.resolveRelative(record.relativeOggPath!)).rename(
        (await f.store.resolveRelative(record.relativeOggPath!)).path +
            '.test-missing');
    await player.playMeeting(record);
    expect(audio.plays, 0);
    expect(player.error, isNotNull);
  });
  test('only ready segment can play; no automatic transcription', () async {
    final p = await f.add(0, purpose: LongRecordingPurpose.lifelog);
    await player.playSegment(f.c, p);
    expect(audio.plays, 1);
    expect(player.playing(p.id), true);
    expect(f.asr.submits, 0);
  });
  test('disposing overview cannot stop another screen audio', () async {
    final record = await createMeetingArchive(f, audio);
    await player.playMeeting(record);
    audio.current = const RecorderAudioPlaybackState(
        isPlaying: true, relativePath: 'recorder_long_audio_v1/other.wav');
    player.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(audio.stops, 0);
  });
  test('leaving while preparing never starts late audio', () async {
    final record = await createMeetingArchive(f, audio);
    audio.gate = Completer<void>();
    final request = player.playMeeting(record);
    while (audio.gate != null && !player.busy) {
      await Future<void>.delayed(Duration.zero);
    }
    player.dispose();
    audio.gate!.complete();
    await request;
    expect(audio.plays, 0);
  });
}

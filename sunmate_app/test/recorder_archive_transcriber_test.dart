import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ai/asr_service.dart';
import 'package:sunmate_app/core/audio/recorder_archive_transcriber.dart';
import 'package:sunmate_app/core/audio/recorder_local_audio.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_models.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_store.dart';
import 'package:sunmate_app/core/hardware/recorder_long_recordings.dart';

class FileAsr extends AsrService {
  int submits = 0;
  String? submittedPath;
  bool fail = false;
  @override
  Future<String?> submitJobFile(String path, {required String filename}) async {
    submits++;
    submittedPath = path;
    return fail ? null : 'synthetic-job';
  }

  @override
  Future<AsrResult> pollJobResult(String id,
          {Duration pollInterval = Duration.zero, int maxAttempts = 1}) async =>
      AsrResult(success: true, rawText: 'Synthetic transcript');
}

class PreparedAudio implements RecorderLocalAudio {
  final String wav;
  bool mismatch = false;
  PreparedAudio(this.wav);
  @override
  Future<PreparedRecorderAudio> prepare(String path) async =>
      PreparedRecorderAudio(
          relativePath: wav,
          durationMs: mismatch ? 2000 : 1000,
          sampleRate: 16000,
          frames: 16000);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory sandbox;
  late RecorderLongFileStore store;
  late RecorderLongAudioRecord record;
  late FileAsr asr;
  late PreparedAudio audio;
  const prefix = 'recorder_long_audio_v1/AB00000000000001/s1792496000000';
  setUp(() async {
    sandbox = await Directory.systemTemp
        .createTemp('sunmate-archive-transcription-test-');
    store = RecorderLongFileStore(
        rootDirectory: () async =>
            Directory('${sandbox.path}/recorder_long_audio_v1'));
    for (final path in ['$prefix/source.ogg', '$prefix/voice.wav']) {
      final file = await store.resolveRelative(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3, 4]);
    }
    record = const RecorderLongAudioRecord(
        serialNumber: 'AB00000000000001',
        sessionId: 1792496000000,
        purpose: LongRecordingPurpose.meeting,
        stage: RecorderLongFileStage.saved,
        relativeOggPath: '$prefix/source.ogg',
        relativePlayablePath: '$prefix/voice.wav',
        durationMs: 1000);
    await store.saveRecord(record);
    asr = FileAsr();
    audio = PreparedAudio('$prefix/voice.wav');
  });
  tearDown(() async => sandbox.delete(recursive: true));
  for (final purpose in LongRecordingPurpose.values) {
    test(
        '${purpose.name} submits only selected validated archive, never realtime cache',
        () async {
      record = record.copyWith(purpose: purpose);
      await store.saveRecord(record);
      final result =
          await RecorderArchiveTranscriber(asr: asr, store: store, audio: audio)
              .transcribe(record);
      expect(result.rawText, 'Synthetic transcript');
      expect(asr.submits, 1);
      expect(asr.submittedPath, endsWith('/voice.wav'));
      expect(await (await store.resolveRelative('$prefix/source.ogg')).exists(),
          true);
    });
  }
  test('incomplete and stale purpose selection cannot upload', () async {
    await store.saveRecord(
        record.copyWith(stage: RecorderLongFileStage.waitingForTail));
    final service =
        RecorderArchiveTranscriber(asr: asr, store: store, audio: audio);
    await expectLater(service.transcribe(record), throwsFormatException);
    expect(asr.submits, 0);
    await store
        .saveRecord(record.copyWith(purpose: LongRecordingPurpose.lifelog));
    await expectLater(service.transcribe(record), throwsFormatException);
    expect(asr.submits, 0);
  });
  test('changed native receipt or missing local file fails before upload',
      () async {
    final service =
        RecorderArchiveTranscriber(asr: asr, store: store, audio: audio);
    audio.mismatch = true;
    await expectLater(service.transcribe(record), throwsFormatException);
    expect(asr.submits, 0);
    audio.mismatch = false;
    await (await store.resolveRelative('$prefix/voice.wav')).delete();
    await expectLater(service.transcribe(record), throwsFormatException);
    expect(asr.submits, 0);
  });
  test('ASR submission failure keeps source and playable archive', () async {
    asr.fail = true;
    await expectLater(
        RecorderArchiveTranscriber(asr: asr, store: store, audio: audio)
            .transcribe(record),
        throwsFormatException);
    expect((await store.loadRecords()).single.canPlay, true);
  });
  test('file multipart streams to explicit private endpoint with existing auth',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final request = server.first.then((req) async {
      expect(req.uri.path, '/v1/jobs');
      expect(req.headers.value('authorization'), 'Bearer synthetic-only');
      final bytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
      final text = String.fromCharCodes(bytes);
      expect(text, contains('filename="synthetic.wav"'));
      expect(text, contains('name="diarize"'));
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"job_id":"local-job"}');
      await req.response.close();
    });
    try {
      final service = AsrService(
          serverBaseUrl: 'http://127.0.0.1:${server.port}',
          apiKey: 'synthetic-only');
      expect(
          await service.submitJobFile(
              (await store.resolveRelative('$prefix/voice.wav')).path,
              filename: 'synthetic.wav'),
          'local-job');
      await request;
    } finally {
      await server.close(force: true);
    }
  });
}

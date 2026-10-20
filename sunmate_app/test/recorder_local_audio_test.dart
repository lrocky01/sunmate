import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/audio/recorder_local_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('sunmate/recorder_local_audio_test');
  final calls = <MethodCall>[];
  late MethodChannelRecorderLocalAudio audio;
  const source = 'recorder_long_audio_v1/TEST/s1/meeting.ogg';
  const output = 'recorder_long_audio_v1/TEST/s1/playback-abc.wav';

  setUp(() {
    calls.clear();
    audio = MethodChannelRecorderLocalAudio(
      methodChannel: channel,
      isSupported: () => true,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'prepare') {
        return {
          'relativePath': output,
          'durationMs': 1000,
          'sampleRate': 16000,
          'frames': 16000
        };
      }
      if (call.method == 'state') {
        return {
          'isPlaying': true,
          'positionMs': 250,
          'durationMs': 1000,
          'relativePath': output
        };
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('prepares only a local archive and validates decoded PCM metadata',
      () async {
    final result = await audio.prepare(source);
    expect(result.relativePath, output);
    expect(result.frames, 16000);
    expect(result.sampleRate, 16000);
    expect(calls.single.method, 'prepare');
    expect(calls.single.arguments, {'relativePath': source});
  });
  test('play, pause, stop and state preserve the local playback path',
      () async {
    await audio.play(output);
    await audio.pause();
    final state = await audio.state();
    expect(state.isPlaying, isTrue);
    expect(state.relativePath, output);
    expect(state.positionMs, 250);
    await audio.stop();
    expect(calls.map((c) => c.method), ['play', 'pause', 'state', 'stop']);
  });
  test(
      'rejects external, traversal, non-audio and malformed paths before channel',
      () async {
    for (final path in [
      '/tmp/recording.ogg',
      '../recording.ogg',
      'recorder_long_audio_v1/TEST/../recording.ogg',
      'recorder_long_audio_v1//recording.ogg',
      'recorder_long_audio_v1/TEST/voice.wav',
      'recorder_long_audio_v1/TEST/voice.ogg?x=1',
      r'recorder_long_audio_v1/TEST\voice.ogg',
    ]) {
      await expectLater(audio.prepare(path), throwsFormatException);
    }
    await expectLater(audio.play(source), throwsFormatException);
    expect(calls, isEmpty);
  });
  test('unsupported platform makes no native or network call', () async {
    final unsupported = MethodChannelRecorderLocalAudio(
      methodChannel: channel,
      isSupported: () => false,
    );
    await expectLater(unsupported.prepare(source), throwsUnsupportedError);
    await expectLater(unsupported.play(output), throwsUnsupportedError);
    await expectLater(unsupported.pause(), throwsUnsupportedError);
    await expectLater(unsupported.stop(), throwsUnsupportedError);
    await expectLater(unsupported.state(), throwsUnsupportedError);
    expect(calls, isEmpty);
  });
  test('does not accept incomplete or inconsistent decoder results', () {
    for (final value in [
      {
        'relativePath': '/tmp/voice.wav',
        'durationMs': 1000,
        'sampleRate': 16000,
        'frames': 16000
      },
      {
        'relativePath': output,
        'durationMs': 0,
        'sampleRate': 16000,
        'frames': 16000
      },
      {
        'relativePath': output,
        'durationMs': 1000,
        'sampleRate': 48000,
        'frames': 16000
      },
      {
        'relativePath': output,
        'durationMs': 1000,
        'sampleRate': 16000,
        'frames': 0
      },
      {
        'relativePath': output,
        'durationMs': 1000,
        'sampleRate': 16000,
        'frames': 8000
      },
      {'relativePath': output, 'durationMs': 1000},
    ]) {
      expect(() => PreparedRecorderAudio.fromMap(value), throwsFormatException);
    }
  });
  test('native decode errors propagate without a successful prepared artifact',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'decode_failed', message: '原档已保留');
    });
    await expectLater(audio.prepare(source), throwsA(isA<PlatformException>()));
  });
  test('rejects malformed state and permits an idle player', () {
    expect(
        () => RecorderAudioPlaybackState.fromMap({
              'isPlaying': true,
              'positionMs': -1,
              'durationMs': 1000,
            }),
        throwsFormatException);
    final idle = RecorderAudioPlaybackState.fromMap({
      'isPlaying': false,
      'positionMs': 0,
      'durationMs': 0,
      'relativePath': null,
    });
    expect(idle.relativePath, isNull);
  });
}

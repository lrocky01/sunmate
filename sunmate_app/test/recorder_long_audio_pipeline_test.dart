import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/audio/recorder_local_audio.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_store.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_sync.dart';
import 'recorder_long_file_store_test.dart' show ops;
import 'recorder_long_file_sync_test.dart' show FileSyncTestWire, sn, session;

/// macOS仅调用与iOS共用的离线Core Audio核心，绝不访问手机或输出声音。
class _NativeCoreAudio implements RecorderLocalAudio {
  final String executable;
  final Directory support;
  _NativeCoreAudio(this.executable, this.support);
  @override
  Future<PreparedRecorderAudio> prepare(String path) async {
    final result = await Process.run(executable, [support.path, path]);
    if (result.exitCode != 0)
      throw StateError('native decode rejected synthetic audio');
    return PreparedRecorderAudio.fromMap(
        Map<Object?, Object?>.from(jsonDecode(result.stdout as String) as Map));
  }

  @override
  Future<void> play(String path) async {
    final result =
        await Process.run(executable, [support.path, path, 'verify-playback']);
    if (result.exitCode != 0)
      throw StateError('native playback validation rejected synthetic WAV');
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<RecorderAudioPlaybackState> state() async =>
      const RecorderAudioPlaybackState();
}

void main() {
  test(
      'synthetic card segments -> Dart store/Ogg -> real CoreAudio WAV -> offline playable archive',
      () async {
    final sandbox = await Directory.systemTemp.createTemp('sm-full-audio-');
    addTearDown(() => sandbox.delete(recursive: true));
    final executable = '${sandbox.path}/decode';
    final compile = await Process.run('swiftc', [
      'ios/Runner/RecorderLocalAudio.swift',
      'test/native_audio/main.swift',
      '-o',
      executable
    ]);
    expect(compile.exitCode, 0, reason: compile.stderr as String);
    final store = RecorderLongFileStore(
        rootDirectory: () async =>
            Directory('${sandbox.path}/recorder_long_audio_v1'));
    final wire = FileSyncTestWire();
    wire.parts[0] = ops(List.generate(50, (_) => [0xf8, 0xff, 0xfe]));
    wire.parts[1] = ops(List.generate(50, (_) => [0xf8, 0xff, 0xfe]));
    final audio = _NativeCoreAudio(executable, sandbox);
    final sync = RecorderLongFileSync(
        store: store,
        audio: audio,
        send: wire.send,
        isReady: () => true,
        isIdle: () => true,
        serialNumber: () => sn,
        purpose: (_) => null,
        onChanged: () {},
        tailInterval: const Duration(milliseconds: 1));
    addTearDown(sync.dispose);
    wire.sync = sync;
    sync.connected();
    expect(await sync.sync(session), true);
    final record = sync.snapshot.recordings.single;
    expect(record.canPlay, true);
    expect(record.durationMs, 2000);
    expect(await store.findSegment(sn, session, 0, wire.parts[0]!.length),
        isNotNull);
    final prepared = await audio.prepare(record.relativeOggPath!);
    expect(prepared.frames, 32000);
    expect(prepared.relativePath, record.relativePlayablePath);
    await audio.play(prepared.relativePath); // 校验播放目标；测试不启动扬声器。
    final saved = (await store.loadRecords()).single;
    expect(saved.canPlay, true);
    expect(saved.relativePlayablePath, prepared.relativePath);
    expect(await (await store.resolveRelative(prepared.relativePath)).length(),
        greaterThan(64000));
  }, skip: Platform.isMacOS ? false : '需macOS CoreAudio；其它平台协议/磁盘回归仍运行');
}

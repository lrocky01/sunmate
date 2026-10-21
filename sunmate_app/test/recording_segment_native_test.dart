import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/audio/recorder_local_audio.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_store.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_models.dart';
import 'recorder_long_file_store_test.dart' show ops, pages;

void main() {
  test(
      'real CoreAudio decodes each segment with bounded context; PCM boundaries match whole archive',
      () async {
    final sandbox = await Directory.systemTemp.createTemp('sm-segment-native-');
    addTearDown(() => sandbox.delete(recursive: true));
    final exe = '${sandbox.path}/decode';
    final compile = await Process.run('swiftc', [
      'ios/Runner/RecorderLocalAudio.swift',
      'test/native_audio/main.swift',
      '-o',
      exe
    ]);
    expect(compile.exitCode, 0, reason: compile.stderr as String);
    final encoded = '${sandbox.path}/synthetic.ogg';
    final encode = await Process.run('/opt/homebrew/bin/ffmpeg', [
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=437:sample_rate=16000:duration=4',
      '-c:a',
      'libopus',
      '-frame_duration',
      '20',
      encoded
    ]);
    expect(encode.exitCode, 0, reason: encode.stderr as String);
    final packets = <List<int>>[];
    final packet = <int>[];
    for (final page in pages(await File(encoded).readAsBytes())) {
      final n = page[26];
      var offset = 27 + n;
      for (final count in page.sublist(27, 27 + n)) {
        packet.addAll(page.sublist(offset, offset + count));
        offset += count;
        if (count < 255) {
          if (packets.isNotEmpty ||
              !(packet.length >= 8 &&
                  (ascii.decode(packet.sublist(0, 8), allowInvalid: true) ==
                          'OpusHead' ||
                      ascii.decode(packet.sublist(0, 8), allowInvalid: true) ==
                          'OpusTags'))) packets.add(List.of(packet));
          packet.clear();
        }
      }
    }
    expect(packets.length, greaterThan(180));
    final store = RecorderLongFileStore(
        rootDirectory: () async =>
            Directory('${sandbox.path}/recorder_long_audio_v1'));
    const sn = 'AB00000000000001', id = 1792496000000;
    Future<RecorderCommittedSegment> commit(
        int part, List<List<int>> values) async {
      final bytes = ops(values);
      final temp = await store.createTemporarySegment(sn, id, part);
      await temp.writeAsBytes(bytes);
      return store.commitSegment(sn, id, part, bytes.length, temp);
    }

    final p0 = await commit(0, packets.sublist(0, 100)),
        p1 = await commit(1, packets.sublist(100));
    Future<PreparedRecorderAudio> decode(String path) async {
      final result = await Process.run(exe, [sandbox.path, path]);
      expect(result.exitCode, 0, reason: result.stderr as String);
      return PreparedRecorderAudio.fromMap(
          Map<Object?, Object?>.from(jsonDecode(result.stdout as String)));
    }

    final full = await store.assemble(sn, id, [p0, p1]);
    final whole = await decode(full.relativePath);
    final a = await store.prepareSegment(sn, id, p0),
        b = await store.prepareSegment(sn, id, p1, previous: p0);
    final da = await decode(a.relativePath),
        db = await decode(b.relativePath),
        asr = await decode(b.asrRelativePath);
    expect(da.frames + db.frames, whole.frames);
    expect(db.frames, b.samples48 ~/ 3);
    expect(asr.frames, (b.samples48 + b.leadSamples48) ~/ 3);
    final bytesWhole = await (await store.resolveRelative(whole.relativePath))
            .readAsBytes(),
        bytesA =
            await (await store.resolveRelative(da.relativePath)).readAsBytes(),
        bytesB =
            await (await store.resolveRelative(db.relativePath)).readAsBytes();
    Uint8List pcm(Uint8List bytes) {
      var at = 12;
      while (at + 8 <= bytes.length) {
        final length =
            ByteData.sublistView(bytes).getUint32(at + 4, Endian.little);
        if (ascii.decode(bytes.sublist(at, at + 4)) == 'data')
          return Uint8List.sublistView(bytes, at + 8, at + 8 + length);
        at += 8 + length + (length % 2);
      }
      throw const FormatException('Missing WAV data chunk');
    }

    final fullPcm = pcm(bytesWhole), aPcm = pcm(bytesA), bPcm = pcm(bytesB);
    expect(aPcm.length, da.frames * 2);
    expect(bPcm.length, db.frames * 2);
    var firstError = 0;
    final f0 = ByteData.sublistView(fullPcm), s0 = ByteData.sublistView(aPcm);
    for (var i = 0; i < da.frames; i++)
      firstError += (f0.getInt16(i * 2, Endian.little) -
              s0.getInt16(i * 2, Endian.little))
          .abs();
    expect(firstError / da.frames, lessThan(2),
        reason: '首段不允许整段偏移；允许系统解码量化的微小差异');
    final expected = ByteData.sublistView(fullPcm, da.frames * 2),
        actual = ByteData.sublistView(bPcm);
    var error = 0;
    for (var i = 0; i < db.frames; i++)
      error += (expected.getInt16(i * 2, Endian.little) -
              actual.getInt16(i * 2, Endian.little))
          .abs();
    expect(error / db.frames, lessThan(2),
        reason: '前段1秒上下文应使解码边界收敛，避免重启解码的明显接缝');
    expect((await store.prepareSegment(sn, id, p1, previous: p0)).relativePath,
        b.relativePath);
  },
      skip: Platform.isMacOS && File('/opt/homebrew/bin/ffmpeg').existsSync()
          ? false
          : '需macOS CoreAudio与本机ffmpeg合成器；不读取真实录音');
}

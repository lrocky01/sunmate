import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/audio/opus_stream_receiver.dart';

Uint8List framed(List<int> opus,
    {Endian endian = Endian.little, int extra = 0}) {
  final header = ByteData(8)
    ..setUint32(0, opus.length, endian)
    ..setUint32(4, extra, endian);
  return Uint8List.fromList(
      [...header.buffer.asUint8List(), ...opus, ...List.filled(extra, 0)]);
}

void main() {
  test(
      'frame boundaries survive fragmented BLE notifications and extension fields',
      () {
    final parser = TelinkOpusFrames();
    final bytes = framed([0xf8, 0xff, 0xfe], extra: 3);
    for (var i = 0; i < bytes.length - 1; i++) {
      expect(parser.feed([bytes[i]]), isEmpty);
    }
    expect(parser.feed([bytes.last]).single, [0xf8, 0xff, 0xfe]);
    expect(parser.pendingBytes, 0);
    expect(parser.feed(framed([1, 2], endian: Endian.big)).single, [1, 2]);
  });
  test('multiple frames and bounded incomplete frames', () {
    final parser = TelinkOpusFrames();
    expect(
        parser.feed([
          ...framed([1]),
          ...framed([2, 3])
        ]),
        [
          [1],
          [2, 3]
        ]);
    expect(() => parser.feed(List.filled(65537, 0)), throwsFormatException);
    expect(parser.pendingBytes, 0);
  });
  test(
      'receiver emits one Ogg stream, preserves full first Opus bytes and closes with EOS',
      () async {
    final receiver = OpusStreamReceiver();
    final emitted = BytesBuilder();
    receiver.audioStream.listen(emitted.add);
    receiver.startCollecting(sessionId: 123);
    receiver.feedBlePacket(framed([0xf8, 0xff, 0xfe]));
    final recording = receiver.stopAndExport();
    expect(emitted.toBytes(), recording);
    expect(String.fromCharCodes(recording.sublist(0, 4)), 'OggS');
    expect(recording, containsAllInOrder('OpusHead'.codeUnits));
    expect(recording.sublist(recording.length - 27, recording.length - 23),
        'OggS'.codeUnits);
    expect(recording[recording.length - 22], 4);
    receiver.dispose();
  });
  test('empty, truncated and cancelled sessions never become valid recordings',
      () {
    final receiver = OpusStreamReceiver();
    receiver.startCollecting(sessionId: 1);
    expect(receiver.stopAndExport, throwsFormatException);
    receiver.startCollecting(sessionId: 2);
    receiver.feedBlePacket(framed([1]));
    receiver.feedBlePacket(Uint8List.fromList([1, 2]));
    expect(receiver.stopAndExport, throwsFormatException);
    receiver.startCollecting(sessionId: 3);
    receiver.feedBlePacket(framed([1]));
    receiver.cancel();
    expect(receiver.stopAndExport(), isEmpty);
    receiver.dispose();
  });
  test(
      'Ogg/Opus is recognized and decoded by independent ffmpeg when available',
      () async {
    final available = await Process.run('which', ['ffmpeg']);
    if (available.exitCode != 0) return;
    final dir = await Directory.systemTemp.createTemp('sunmate-opus-');
    final receiver = OpusStreamReceiver()..startCollecting(sessionId: 42);
    for (var i = 0; i < 50; i++) {
      receiver.feedBlePacket(framed([0xf8, 0xff, 0xfe])); // Opus silence 20ms.
    }
    final file = File('${dir.path}/recording.opus');
    await file.writeAsBytes(receiver.stopAndExport());
    final probe = await Process.run('ffmpeg', [
      '-v',
      'error',
      '-i',
      file.path,
      '-f',
      's16le',
      '-acodec',
      'pcm_s16le',
      '-ar',
      '16000',
      '${dir.path}/out.pcm'
    ]);
    expect(probe.exitCode, 0, reason: '${probe.stderr}');
    expect(await File('${dir.path}/out.pcm').length(), greaterThan(30000));
    receiver.dispose();
    await dir.delete(recursive: true);
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_models.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_store.dart';
import 'package:sunmate_app/core/hardware/recorder_long_recordings.dart';

const sn = 'SZ12001261804552';
const anotherSn = 'SZ12001261804553';
const session = 1792380000000;

Uint8List ops(List<List<int>> packets, {int reserved = 0}) {
  final result = BytesBuilder();
  for (final packet in packets) {
    final head = ByteData(8)
      ..setUint32(0, packet.length, Endian.little)
      ..setUint32(4, reserved, Endian.little);
    result
      ..add(head.buffer.asUint8List())
      ..add(packet);
  }
  return result.toBytes();
}

List<Uint8List> pages(Uint8List ogg) {
  final result = <Uint8List>[];
  var offset = 0;
  while (offset < ogg.length) {
    expect(ascii.decode(ogg.sublist(offset, offset + 4)), 'OggS');
    final count = ogg[offset + 26];
    final size = 27 +
        count +
        ogg
            .sublist(offset + 27, offset + 27 + count)
            .fold<int>(0, (a, b) => a + b);
    result.add(Uint8List.sublistView(ogg, offset, offset + size));
    offset += size;
  }
  expect(offset, ogg.length);
  return result;
}

int independentCrc(Uint8List bytes) {
  var result = 0;
  for (var i = 0; i < bytes.length; i++) {
    final byte = i >= 22 && i < 26 ? 0 : bytes[i];
    for (var shift = 7; shift >= 0; shift--) {
      final high = (result >> 31) & 1;
      result = ((result << 1) & 0xffffffff) | 0;
      if (high != ((byte >> shift) & 1)) result ^= 0x04c11db7;
    }
  }
  return result;
}

void main() {
  late Directory sandbox;
  late Directory root;
  late RecorderLongFileStore store;
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('sm-long-store-');
    root = Directory('${sandbox.path}/recorder_long_audio_v1');
    store = RecorderLongFileStore(rootDirectory: () async => root);
  });
  tearDown(() async {
    await sandbox.delete(recursive: true);
  });

  Future<RecorderCommittedSegment> segment(int part, List<List<int>> packets,
      {String serial = sn, int sessionId = session}) async {
    final data = ops(packets);
    final temp = await store.createTemporarySegment(serial, sessionId, part);
    await temp.writeAsBytes(data, flush: true);
    return store.commitSegment(serial, sessionId, part, data.length, temp);
  }

  test('unique temporary files and content-addressed OPS survive store restart',
      () async {
    final a = await store.createTemporarySegment(sn, session, 0);
    final b = await store.createTemporarySegment(sn, session, 0);
    expect(a.path, isNot(b.path));
    final committed = await segment(0, [
      [0xf8, 0xff, 0xfe]
    ]);
    expect(committed.sha256, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(committed.relativePath, contains('/p0-${committed.sha256}.ops'));
    final restored =
        await RecorderLongFileStore(rootDirectory: () async => root)
            .findSegment(sn, session, 0, committed.size);
    expect(restored?.sha256, committed.sha256);
    expect(await (await store.resolveRelative(committed.relativePath)).exists(),
        isTrue);
  });

  test('same-size OPS modification fails SHA recovery without deleting source',
      () async {
    final committed = await segment(0, [
      [0xf8, 0xff, 0xfe]
    ]);
    final file = await store.resolveRelative(committed.relativePath);
    await file.writeAsBytes(
        ops([
          [0xf8, 0xff, 0xfd]
        ]),
        flush: true);
    expect(await store.findSegment(sn, session, 0, committed.size), isNull);
    expect(await file.exists(), isTrue);
    await expectLater(
        store.assemble(sn, session, [committed]), throwsFormatException);
  });

  test('changed source size produces a new segment and retains old one',
      () async {
    final a = await segment(0, [
      [0xf8, 0xff, 0xfe]
    ]);
    final b = await segment(0, [
      [0xf8, 0xff, 0xfe],
      [0xf8, 0xff, 0xfe]
    ]);
    expect(a.relativePath, isNot(b.relativePath));
    expect((await store.findSegment(sn, session, 0, b.size))?.sha256, b.sha256);
    expect(
        await (await store.resolveRelative(a.relativePath)).exists(), isTrue);
  });

  test('re-downloading damaged content-addressed segment quarantines old bytes',
      () async {
    final old = await segment(0, [
      [0xf8, 0xff, 0xfe]
    ]);
    final file = await store.resolveRelative(old.relativePath);
    final damage = ops([
      [0xf8, 0xff, 0xfd]
    ]);
    await file.writeAsBytes(damage);
    final restored = await segment(0, [
      [0xf8, 0xff, 0xfe]
    ]);
    expect(restored.relativePath, old.relativePath);
    expect((await store.findSegment(sn, session, 0, restored.size))?.sha256,
        restored.sha256);
    final archived = await file.parent
        .list()
        .where((f) => f.path.contains('.invalid-'))
        .toList();
    expect(archived.length, 1);
    expect(await File(archived.single.path).readAsBytes(), damage);
  });

  for (final entry in <String, List<int>>{
    'truncated payload': [1, 0, 0, 0, 0, 0, 0, 0],
    'zero payload': [0, 0, 0, 0, 0, 0, 0, 0, 1],
    'nonzero reserved': ops([
      [0xf8, 0xff, 0xfe]
    ], reserved: 1),
    'trailing bytes': [
      ...ops([
        [0xf8, 0xff, 0xfe]
      ]),
      99
    ],
    'BE header': [0, 0, 0, 3, 0, 0, 0, 0, 0xf8, 0xff, 0xfe],
    'huge frame': [1, 0, 1, 0, 0, 0, 0, 0, 1],
  }.entries) {
    test('strict OPS rejects ${entry.key} and preserves temporary', () async {
      final temp = await store.createTemporarySegment(sn, session, 0);
      await temp.writeAsBytes(entry.value);
      await expectLater(
          store.commitSegment(sn, session, 0, entry.value.length, temp),
          throwsFormatException);
      expect(await temp.exists(), isTrue);
    });
  }

  test('size mismatch and resource limit reject before commit', () async {
    final temp = await store.createTemporarySegment(sn, session, 0);
    await temp.writeAsBytes(ops([
      [0xf8, 0xff, 0xfe]
    ]));
    await expectLater(
        store.commitSegment(sn, session, 0, 12, temp), throwsFormatException);
    await expectLater(
        store.commitSegment(
            sn, session, 0, RecorderLongFileStore.maxSegmentBytes + 1, temp),
        throwsFormatException);
    expect(await temp.exists(), isTrue);
  });

  test('assembly streams ordered packets, correct durations, granules and CRC',
      () async {
    final a = await segment(0, [
      [0x80, 0],
      [0x00, 0]
    ]); // 2.5ms + 10ms.
    final b = await segment(1, [
      [0xf8, 0xff, 0xfe],
      [0x18, 0]
    ]); // 20ms + 60ms.
    final audio = await store.assemble(sn, session, [a, b]);
    expect(audio.packetCount, 4);
    expect(audio.durationMs, 92);
    final file = await store.resolveRelative(audio.relativePath);
    final allPages = pages(await file.readAsBytes());
    expect(allPages.length, 7);
    expect(allPages.first[5], 2);
    expect(allPages.last[5], 4);
    expect(
        allPages
            .map((p) => ByteData.sublistView(p).getUint64(6, Endian.little)),
        [0, 0, 120, 600, 1560, 4440, 4440]);
    for (var i = 0; i < allPages.length; i++) {
      final page = allPages[i];
      final data = ByteData.sublistView(page);
      expect(data.getUint32(18, Endian.little), i);
      expect(data.getUint32(22, Endian.little), independentCrc(page));
    }
    expect(
        await (await store.resolveRelative(a.relativePath)).exists(), isTrue);
    expect(
        await (await store.resolveRelative(b.relativePath)).exists(), isTrue);
    final same = await store.assemble(sn, session, [a, b]);
    expect(same.relativePath, audio.relativePath);
  });

  test('120ms Opus packet accepted; overlong and invalid count rejected',
      () async {
    final accepted = await segment(0, [
      [0x83, 48, 0]
    ]); // 48 * 2.5ms.
    expect((await store.assemble(sn, session, [accepted])).durationMs, 120);
    for (final packet in [
      [0x83, 49, 0],
      [0x83, 0, 0],
      [0x83]
    ]) {
      final bad = await segment(0, [packet]);
      await expectLater(
          store.assemble(sn, session, [bad]), throwsFormatException);
    }
  });

  test(
      'max single-page lacing works; larger OPS payload retained but not playable',
      () async {
    final packet = Uint8List(65024)..[0] = 0x80;
    final valid = await segment(0, [packet]);
    final audio = await store.assemble(sn, session, [valid]);
    final allPages = pages(
        await (await store.resolveRelative(audio.relativePath)).readAsBytes());
    expect(allPages[2][26], 255);
    final tooLarge = await segment(0, [Uint8List(65025)..[0] = 0x80]);
    await expectLater(
        store.assemble(sn, session, [tooLarge]), throwsFormatException);
    expect(await (await store.resolveRelative(tooLarge.relativePath)).exists(),
        isTrue);
  });

  test('missing, duplicate, out-of-order and wrong-device segments rejected',
      () async {
    final a = await segment(0, [
      [0xf8, 0xff, 0xfe]
    ]);
    final b = await segment(1, [
      [0xf8, 0xff, 0xfe]
    ]);
    for (final inputs in <List<RecorderCommittedSegment>>[
      [],
      [b],
      [a, a],
      [b, a]
    ]) {
      await expectLater(
          store.assemble(sn, session, inputs), throwsFormatException);
    }
    await expectLater(
        store.assemble(anotherSn, session, [a]), throwsFormatException);
    await expectLater(
        store.assemble(sn, session + 1, [a]), throwsFormatException);
  });

  test('arbitrary temporary paths and symlink sources cannot be committed',
      () async {
    final outside = File('${sandbox.path}/outside.ops')
      ..writeAsBytesSync(ops([
        [0xf8, 0xff, 0xfe]
      ]));
    await expectLater(store.commitSegment(sn, session, 0, 11, outside),
        throwsFormatException);
    final temp = await store.createTemporarySegment(sn, session, 0);
    await temp.delete();
    await Link(temp.path).create(outside.path);
    await expectLater(store.commitSegment(sn, session, 0, 11, temp),
        throwsA(isA<FileSystemException>()));
    expect(
        await outside.readAsBytes(),
        ops([
          [0xf8, 0xff, 0xfe]
        ]));
  });

  test('relative path traversal and wrong prefix rejected', () async {
    for (final path in [
      '/$sn/a',
      'recorder_long_audio_v1/$sn/s$session/../a',
      'recorder_long_audio_v1/$sn/s$session/a\\b',
      'other/$sn/s$session/a',
      'recorder_long_audio_v1/$sn/s0/a',
      'recorder_long_audio_v1/$sn/s$session//a'
    ]) {
      await expectLater(store.resolveRelative(path), throwsFormatException);
    }
  });

  test('symlink root and child directory rejected', () async {
    await Directory('${sandbox.path}/outside').create();
    await Link(root.path).create('${sandbox.path}/outside');
    await expectLater(store.loadRecords(), throwsA(isA<FileSystemException>()));
    await Link(root.path).delete();
    await root.create();
    await Link('${root.path}/$sn').create('${sandbox.path}/outside');
    await expectLater(store.createTemporarySegment(sn, session, 0),
        throwsA(isA<FileSystemException>()));
    await expectLater(store.loadRecords(), throwsA(isA<FileSystemException>()));
  });

  test('record manifest survives restart without secrets and stays scoped',
      () async {
    const record = RecorderLongAudioRecord(
        serialNumber: sn,
        sessionId: session,
        purpose: LongRecordingPurpose.meeting,
        stage: RecorderLongFileStage.incomplete,
        totalParts: 2,
        downloadedParts: 1,
        sourceBytes: 50,
        receivedBytes: 25,
        message: '等待尾段');
    await store.saveRecord(record);
    final restored =
        await RecorderLongFileStore(rootDirectory: () async => root)
            .loadRecords();
    expect(restored.single.serialNumber, sn);
    expect(restored.single.purpose, LongRecordingPurpose.meeting);
    expect(restored.single.totalParts, 2);
    expect(restored.single.message, '等待尾段');
    expect(restored.single.canPlay, isFalse);
    await expectLater(
        store.saveRecord(record.copyWith(
            relativeOggPath:
                'recorder_long_audio_v1/$anotherSn/s$session/audio.ogg')),
        throwsFormatException);
  });

  test(
      'saved record needs files and missing playback restores as incomplete without rewriting',
      () async {
    final committed = await segment(0, [
      [0xf8, 0xff, 0xfe]
    ]);
    final audio = await store.assemble(sn, session, [committed]);
    const playable = 'recorder_long_audio_v1/$sn/s$session/audio.wav';
    final record = RecorderLongAudioRecord(
        serialNumber: sn,
        sessionId: session,
        stage: RecorderLongFileStage.saved,
        relativeOggPath: audio.relativePath,
        relativePlayablePath: playable,
        durationMs: 20);
    await expectLater(store.saveRecord(record), throwsFormatException);
    final wave = await store.resolveRelative(playable);
    await wave.writeAsBytes([82, 73, 70, 70, 0, 0, 0, 0, 87, 65, 86, 69]);
    await store.saveRecord(record);
    expect((await store.loadRecords()).single.canPlay, isTrue);
    final manifest = await store
        .resolveRelative('recorder_long_audio_v1/$sn/s$session/record.json');
    final original = await manifest.readAsString();
    await wave.delete();
    final restored = (await store.loadRecords()).single;
    expect(restored.canPlay, isFalse);
    expect(restored.stage, RecorderLongFileStage.incomplete);
    expect(await manifest.readAsString(), original);
  });

  test('saved manifest cannot reference symlink even before first write',
      () async {
    final committed = await segment(0, [
      [0xf8, 0xff, 0xfe]
    ]);
    final audio = await store.assemble(sn, session, [committed]);
    final outside = File('${sandbox.path}/outside.wav');
    await outside.writeAsBytes([1, 2, 3]);
    const playable = 'recorder_long_audio_v1/$sn/s$session/audio.wav';
    await Link((await store.resolveRelative(playable)).path)
        .create(outside.path);
    await expectLater(
        store.saveRecord(RecorderLongAudioRecord(
            serialNumber: sn,
            sessionId: session,
            stage: RecorderLongFileStage.saved,
            relativeOggPath: audio.relativePath,
            relativePlayablePath: playable,
            durationMs: 20)),
        throwsA(isA<FileSystemException>()));
    expect(await outside.readAsBytes(), [1, 2, 3]);
  });

  test(
      'inventory fingerprint persists and copyWith retains it; old manifest accepts missing field',
      () async {
    final fingerprint = 'ab' * 32;
    final record = RecorderLongAudioRecord(
        serialNumber: sn,
        sessionId: session,
        inventoryFingerprint: fingerprint,
        stage: RecorderLongFileStage.incomplete);
    expect(
        record.copyWith(downloadedParts: 1).inventoryFingerprint, fingerprint);
    await store.saveRecord(record);
    expect(
        (await store.loadRecords()).single.inventoryFingerprint, fingerprint);
    final file = await store
        .resolveRelative('recorder_long_audio_v1/$sn/s$session/record.json');
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    raw.remove('inventoryFingerprint');
    await file.writeAsString(jsonEncode(raw));
    expect((await store.loadRecords()).single.inventoryFingerprint, isNull);
    await expectLater(
        store.saveRecord(
            record.copyWith(inventoryFingerprint: 'not-a-fingerprint')),
        throwsFormatException);
    expect((await store.loadRecords()).single.inventoryFingerprint, isNull);
  });

  test('invalid persisted fingerprint is retained and rejected', () async {
    const record =
        RecorderLongAudioRecord(serialNumber: sn, sessionId: session);
    await store.saveRecord(record);
    final file = await store
        .resolveRelative('recorder_long_audio_v1/$sn/s$session/record.json');
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    raw['inventoryFingerprint'] = 'ABC';
    final broken = jsonEncode(raw);
    await file.writeAsString(broken);
    await expectLater(store.loadRecords(), throwsFormatException);
    await expectLater(store.saveRecord(record), throwsFormatException);
    expect(await file.readAsString(), broken);
  });

  test('stereo TOC rejected under mono container and original OPS retained',
      () async {
    final stereo = await segment(0, [
      [0xfc, 0xff, 0xfe]
    ]);
    await expectLater(
        store.assemble(sn, session, [stereo]), throwsFormatException);
    expect(await (await store.resolveRelative(stereo.relativePath)).exists(),
        isTrue);
    expect((await store.findSegment(sn, session, 0, stereo.size))?.sha256,
        stereo.sha256);
  });

  test('bad JSON is preserved and never cleared or overwritten by save',
      () async {
    const record =
        RecorderLongAudioRecord(serialNumber: sn, sessionId: session);
    await store.saveRecord(record);
    final file = await store
        .resolveRelative('recorder_long_audio_v1/$sn/s$session/record.json');
    await file.writeAsString('{broken');
    await expectLater(store.loadRecords(), throwsFormatException);
    await expectLater(store.saveRecord(record), throwsFormatException);
    expect(await file.readAsString(), '{broken');
  });

  test('source directory type collision fails without deleting original',
      () async {
    await root.create();
    final collision = File('${root.path}/$sn');
    await collision.writeAsString('preserve');
    await expectLater(store.createTemporarySegment(sn, session, 0),
        throwsA(isA<FileSystemException>()));
    expect(await collision.readAsString(), 'preserve');
  });

  test('bad identity and part resource bounds rejected', () async {
    await expectLater(store.createTemporarySegment('../wrong', session, 0),
        throwsFormatException);
    await expectLater(
        store.createTemporarySegment(sn, 0, 0), throwsFormatException);
    await expectLater(
        store.createTemporarySegment(sn, session, -1), throwsFormatException);
    await expectLater(store.createTemporarySegment(sn, session, 10000),
        throwsFormatException);
  });
}

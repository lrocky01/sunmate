import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/audio/recorder_local_audio.dart';
import 'package:sunmate_app/core/ble/telink_long_files.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_models.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_store.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_sync.dart';
import 'package:sunmate_app/core/hardware/recorder_long_recordings.dart';
import 'recorder_long_file_store_test.dart' show ops;

const sn = 'AB00000000000001';
const session = 1792380000000;
List<int> listEntry(int part, int size, {int id = session}) =>
    [0xaa, 0x55, 8, ...utf8.encode('longops_s${id}_p$part.ops $size')];
List<int> fileSize(int size) => (ByteData(7)
      ..setUint8(0, 0xaa)
      ..setUint8(1, 0x55)
      ..setUint8(2, 5)
      ..setInt32(3, size, Endian.big))
    .buffer
    .asUint8List();

/// 控制器边界使用假播放器；真实Opus解码另由native_audio测试验证。
class FileSyncTestAudio implements RecorderLocalAudio {
  final RecorderLongFileStore store;
  bool reject = false;
  bool wrongDuration = false;
  int prepares = 0;
  FileSyncTestAudio(this.store);
  @override
  Future<PreparedRecorderAudio> prepare(String relativeOggPath) async {
    prepares++;
    if (reject) throw StateError('test-private-error');
    final source =
        await (await store.resolveRelative(relativeOggPath)).readAsBytes();
    final samples48k = ByteData.sublistView(source)
        .getUint64(source.length - 27 + 6, Endian.little);
    final frames = samples48k ~/ 3;
    final path = relativeOggPath.replaceFirst('.ogg', '.wav');
    final bytes = ByteData(44 + frames * 2);
    bytes.buffer.asUint8List().setRange(0, 4, ascii.encode('RIFF'));
    bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
    bytes.buffer.asUint8List().setRange(8, 12, ascii.encode('WAVE'));
    await (await store.resolveRelative(path))
        .writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    return PreparedRecorderAudio(
        relativePath: path,
        frames: frames,
        sampleRate: 16000,
        durationMs: frames * 1000 ~/ 16000 + (wrongDuration ? 5 : 0));
  }

  @override
  Future<void> play(String path) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<RecorderAudioPlaybackState> state() async =>
      const RecorderAudioPlaybackState();
}

class FileSyncTestWire {
  late RecorderLongFileSync sync;
  final Map<int, List<int>> parts = {
    0: ops([
      [0xf8, 0xff, 0xfe]
    ]),
    1: ops([
      [0xf8, 0xff, 0xfe]
    ])
  };
  int lists = 0;
  final List<int> reads = [];
  final List<List<int>> commands = [];
  void Function(int)? onRead;
  void Function(int)? onList;
  bool completionFirst = false;
  Future<void> send(List<int> bytes) async {
    commands.add(List.of(bytes));
    if (bytes.length == 2 && bytes[0] == 0x11 && bytes[1] == 0x22) {
      lists++;
      if (onList != null) {
        onList!(lists);
        return;
      }
      list();
    } else if (bytes.length > 2 && bytes[0] == 0x11 && bytes[1] == 0x26) {
      final name = utf8.decode(bytes.sublist(2));
      final part = int.parse(RegExp(r'_p(\d+)\.ops$').firstMatch(name)![1]!);
      reads.add(part);
      if (onRead != null) {
        onRead!(part);
        return;
      }
      deliver(part);
    } else {
      throw StateError('unexpected command');
    }
  }

  void list({Iterable<int>? selected}) {
    for (final part in selected ?? parts.keys) {
      sync.acceptEvent(listEntry(part, parts[part]!.length));
    }
    sync.acceptEvent([0xaa, 0x55, 8]);
  }

  void deliver(int part) {
    final data = parts[part]!;
    if (completionFirst) sync.acceptEvent([0xaa, 0x55, 6]);
    // 允许跨特征数据先于size；提交仍要求size、完整字节和completion三者。
    sync.acceptData(data.sublist(0, 3));
    sync.acceptEvent(fileSize(data.length));
    sync.acceptData(data.sublist(3));
    if (!completionFirst) sync.acceptEvent([0xaa, 0x55, 6]);
  }
}

void main() {
  late Directory sandbox;
  late RecorderLongFileStore store;
  late FileSyncTestAudio audio;
  late FileSyncTestWire wire;
  late RecorderLongFileSync sync;
  var ready = true;
  var idle = true;
  var selectedPurpose = LongRecordingPurpose.meeting;
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('sm-file-sync-');
    store = RecorderLongFileStore(
        rootDirectory: () async =>
            Directory('${sandbox.path}/recorder_long_audio_v1'));
    audio = FileSyncTestAudio(store);
    wire = FileSyncTestWire();
    ready = true;
    idle = true;
    selectedPurpose = LongRecordingPurpose.meeting;
    sync = RecorderLongFileSync(
        store: store,
        audio: audio,
        send: wire.send,
        isReady: () => ready,
        isIdle: () => idle,
        serialNumber: () => sn,
        purpose: (_) => selectedPurpose,
        onChanged: () {},
        progressTimeout: const Duration(milliseconds: 60),
        tailInterval: const Duration(milliseconds: 1));
    wire.sync = sync;
    sync.connected();
  });
  tearDown(() async {
    await sync.dispose();
    await sandbox.delete(recursive: true);
  });

  test(
      'directory then serialized parts, final rescans, archive and offline restore',
      () async {
    expect(await sync.refresh(), true);
    expect(sync.snapshot.recordings.single.totalParts, 2);
    expect(await sync.sync(session), true);
    expect(wire.reads, [0, 1]);
    expect(wire.lists, 5); // manual refresh + two pre + two post scans
    final record = sync.snapshot.recordings.single;
    expect(record.canPlay, true);
    expect(record.purpose, LongRecordingPurpose.meeting);
    expect(record.downloadedParts, 2);
    expect(record.durationMs, 40);
    expect((await store.loadRecords()).single.canPlay, true);
    expect(await store.findSegment(sn, session, 0, 11), isNotNull);
    expect(wire.commands.every((b) => b[1] == 0x22 || b[1] == 0x26), true);
    ready = false;
    await sync.initialize();
    expect(sync.snapshot.recordings.single.canPlay, true);
    expect(await sync.refresh(), false);
  });

  test('not authenticated or not confirmed idle cannot send a file command',
      () async {
    ready = false;
    expect(await sync.sync(session), false);
    ready = true;
    idle = false;
    expect(await sync.refresh(), false);
    expect(wire.commands, isEmpty);
  });

  test('completion before final data does not truncate segment', () async {
    wire.completionFirst = true;
    expect(await sync.sync(session), true);
    expect(sync.snapshot.recordings.single.canPlay, true);
  });

  test(
      'disconnect preserves committed part and fresh AES connection resumes missing part only',
      () async {
    wire.onRead = (part) {
      if (part == 0)
        wire.deliver(part);
      else {
        ready = false;
        sync.connectionLost();
      }
    };
    expect(await sync.sync(session), false);
    expect(await store.findSegment(sn, session, 0, 11), isNotNull);
    expect(sync.snapshot.recordings.single.canPlay, false);
    ready = true;
    sync.connected();
    wire.onRead = null;
    expect(await sync.sync(session), true);
    expect(wire.reads, [0, 1, 1]);
  });

  test('timeout locks old stream and does not retry until physical reconnect',
      () async {
    wire.onRead = (part) {
      sync.acceptEvent(fileSize(wire.parts[part]!.length));
      sync.acceptData(wire.parts[part]!.sublist(0, 4));
    };
    expect(await sync.sync(session), false);
    expect(sync.snapshot.needsReconnect, true);
    expect(wire.reads, [0]);
    expect(await sync.sync(session), false);
    sync.acceptData(wire.parts[0]!.sublist(4));
    sync.acceptEvent([0xaa, 0x55, 6]);
    expect(sync.snapshot.recordings.single.canPlay, false);
    expect(wire.reads, [0]);
    sync.connected();
    wire.onRead = null;
    expect(await sync.sync(session), true);
    expect(wire.reads, [0, 0, 1]);
  });

  test('early completion with missing data remains pending until timeout',
      () async {
    wire.onRead = (part) {
      sync.acceptEvent(fileSize(wire.parts[part]!.length));
      sync.acceptData(wire.parts[part]!.sublist(0, 4));
      sync.acceptEvent([0xaa, 0x55, 6]);
    };
    expect(await sync.sync(session), false);
    expect(audio.prepares, 0);
    expect(sync.snapshot.needsReconnect, true);
  });

  test(
      'tail initially empty or growing is rescanned until continuous and stable',
      () async {
    wire.onList = (scan) {
      if (scan == 1) {
        sync.acceptEvent(listEntry(0, 0));
        sync.acceptEvent([0xaa, 0x55, 8]);
      } else if (scan == 2)
        wire.list(selected: [0]);
      else
        wire.list();
    };
    expect(await sync.sync(session), true);
    expect(wire.lists, 6);
    expect(wire.reads, [0, 1]);
  });

  test('missing p0 or middle part never assembles or deletes files', () async {
    wire.onList = (_) => wire.list(selected: [1]);
    expect(await sync.sync(session), false);
    expect(wire.lists, 5);
    expect(wire.reads, isEmpty);
    expect(audio.prepares, 0);
    expect(sync.snapshot.recordings.single.canPlay, false);
  });

  test(
      'known tail anchor prevents stable but incomplete inventory finalization',
      () async {
    sync.observePart(session, 2);
    expect(await sync.sync(session), false);
    expect(wire.reads, isEmpty);
    wire.parts[2] = ops([
      [0xf8, 0xff, 0xfe]
    ]);
    expect(await sync.sync(session), true);
    expect(wire.reads, [0, 1, 2]);
  });

  test(
      'directory growth during download retains committed parts and waits for recovery',
      () async {
    wire.onList = (scan) {
      if (scan > 2)
        wire.parts[2] = ops([
          [0xf8, 0xff, 0xfe]
        ]);
      wire.list();
    };
    expect(await sync.sync(session), false);
    expect(audio.prepares, 0);
    expect(sync.snapshot.recordings.single.canPlay, false);
    wire.onList = null;
    expect(await sync.sync(session), true);
    expect(wire.reads, [0, 1, 2]);
  });

  test(
      'size conflict excess data and malformed file event quarantine only file channel',
      () async {
    for (final mode in [0, 1, 2]) {
      sync.connected();
      wire.onRead = (part) {
        if (mode == 0) sync.acceptEvent(fileSize(123));
        if (mode == 1) sync.acceptData([...wire.parts[part]!, 0]);
        if (mode == 2) sync.acceptEvent([0xaa, 0x55, 5, 1]);
      };
      expect(await sync.sync(session), false);
      expect(sync.snapshot.needsReconnect, true);
      expect(ready, true);
      expect(audio.prepares, 0);
    }
  });

  test('mismatched duplicate catalog sizes reject before reading', () async {
    wire.onList = (_) {
      sync.acceptEvent(listEntry(0, 11));
      sync.acceptEvent(listEntry(0, 12));
      sync.acceptEvent([0xaa, 0x55, 8]);
    };
    expect(await sync.refresh(), false);
    expect(sync.snapshot.needsReconnect, true);
    expect(wire.reads, isEmpty);
  });

  test(
      'strict OPS rejects corrupt complete segment, retains partial and no playable archive',
      () async {
    wire.parts[0] = ops([
      [0xf8, 0xff, 0xfe]
    ], reserved: 1);
    expect(await sync.sync(session), false);
    expect(audio.prepares, 0);
    expect(await store.findSegment(sn, session, 0, 11), isNull);
    expect(sync.snapshot.recordings.single.canPlay, false);
  });

  test(
      'decode failure preserves Ogg and committed OPS for offline preparation retry',
      () async {
    audio.reject = true;
    expect(await sync.sync(session), false);
    expect(sync.snapshot.recordings.single.relativeOggPath, isNotNull);
    expect(sync.snapshot.recordings.single.canPlay, false);
    expect(sync.snapshot.message, isNot(contains('test-private-error')));
    audio.reject = false;
    expect(await sync.sync(session), true);
    expect(wire.reads, [0, 1]);
  });

  test('decoded sample duration mismatch cannot claim the whole source saved',
      () async {
    audio.wrongDuration = true;
    expect(await sync.sync(session), false);
    expect(sync.snapshot.recordings.single.canPlay, false);
    expect(await store.findSegment(sn, session, 0, 11), isNotNull);
  });

  test(
      'saved inventory changed under equal count/total bytes becomes incomplete',
      () async {
    expect(await sync.sync(session), true);
    final original = sync.snapshot.recordings.single.relativePlayablePath!;
    wire.onList = (_) {
      sync.acceptEvent(listEntry(0, 10));
      sync.acceptEvent(listEntry(1, 12));
      sync.acceptEvent([0xaa, 0x55, 8]);
    };
    expect(await sync.refresh(), true);
    expect(sync.snapshot.recordings.single.canPlay, false);
    expect((await store.loadRecords()).single.canPlay, false);
    expect(await (await store.resolveRelative(original)).exists(), true);
  });

  test('file protocol read has no offset/delete and paths/invalid sizes reject',
      () {
    final entry = RecorderLongFileEntry(session, 0, 11);
    expect(TelinkLongFileEvent.listCommand(), [0x11, 0x22]);
    expect(TelinkLongFileEvent.readCommand(entry),
        [0x11, 0x26, ...utf8.encode(entry.remoteName)]);
    expect(
        TelinkLongFileEvent.decode([0xaa, 0x55, 8]), isA<TelinkFileListEnd>());
    expect(
        (TelinkLongFileEvent.decode(fileSize(0x01020304)) as TelinkFileSize)
            .size,
        0x01020304);
    for (final bytes in [
      fileSize(0),
      fileSize(-1),
      [0xaa, 0x55, 5, 1],
      [0xaa, 0x55, 8, 255],
      [0xaa, 0x55, 6, 1]
    ]) {
      expect(() => TelinkLongFileEvent.decode(bytes), throwsFormatException);
    }
    final other = [0xaa, 0x55, 8, ...utf8.encode('../longops_s1_p0.ops 11')];
    expect(TelinkLongFileEvent.decode(other), isA<TelinkOtherFile>());
  });

  test('firmware directory prefixes normalize to a long-recording basename',
      () {
    for (final prefix in ['/storage/', '/records/nested/', 'records/', '//']) {
      final bytes = [
        0xaa,
        0x55,
        8,
        ...utf8.encode('${prefix}longops_s${session}_p0.ops 11')
      ];
      final event = TelinkLongFileEvent.decode(bytes);
      expect(event, isA<TelinkFileListEntry>());
      final entry = (event as TelinkFileListEntry).entry;
      expect(entry.sessionId, session);
      expect(entry.remoteName, 'longops_s${session}_p0.ops');
      expect(utf8.decode(TelinkLongFileEvent.readCommand(entry).sublist(2)),
          entry.remoteName);
    }
  });

  test('padded firmware part names are preserved in the exact read command',
      () {
    final name = 'longops_s${session}_p0000.ops';
    final event = TelinkLongFileEvent.decode(
            [0xaa, 0x55, 8, ...utf8.encode('/records/$name 11')])
        as TelinkFileListEntry;
    expect(event.entry.part, 0);
    expect(utf8.decode(TelinkLongFileEvent.readCommand(event.entry).sublist(2)),
        name);
  });

  for (final mode in LongRecordingPurpose.values) {
    test(
        '${mode.name}: prefixed catalog downloads, validates and archives both segments',
        () async {
      selectedPurpose = mode;
      wire.onList = (_) {
        for (final part in wire.parts.keys) {
          sync.acceptEvent([
            0xaa,
            0x55,
            8,
            ...utf8.encode(
                '/records/longops_s${session}_p$part.ops ${wire.parts[part]!.length}')
          ]);
        }
        sync.acceptEvent([0xaa, 0x55, 8]);
      };
      expect(await sync.refresh(), true);
      expect(sync.snapshot.recordings, hasLength(1));
      expect(await sync.sync(session), true);
      expect(wire.reads, [0, 1]);
      expect(sync.snapshot.recordings.single.canPlay, true);
      expect(sync.snapshot.recordings.single.purpose, mode);
      expect((await store.loadRecords()).single.canPlay, true);
    });
  }

  test('unsafe paths and unrelated files stay excluded', () {
    for (final name in [
      '../longops_s1_p0.ops',
      '/records/../longops_s1_p0.ops',
      './longops_s1_p0.ops',
      '/records/./longops_s1_p0.ops',
      r'records\longops_s1_p0.ops',
      '/records/longops_s1_p0.ops\u0000',
      '/records/settings.json',
      '/records/longops_s1_p0.ops/'
    ]) {
      expect(
          TelinkLongFileEvent.decode(
              [0xaa, 0x55, 8, ...utf8.encode('$name 11')]),
          isA<TelinkOtherFile>());
    }
  });

  test('read only accepts a basename matching its numeric identity', () {
    for (final name in [
      '../longops_s${session}_p0.ops',
      'longops_s${session}_p1.ops',
      'longops_s1_p0.ops',
      'longops_s${session}_p0.ops\n'
    ]) {
      expect(
          () => TelinkLongFileEvent.readCommand(
              RecorderLongFileEntry(session, 0, 11, remoteName: name)),
          throwsFormatException);
    }
    final canonical = RecorderLongFileEntry(session, 0, 11);
    final padded = RecorderLongFileEntry(session, 0, 11,
        remoteName: 'longops_s${session}_p0000.ops');
    expect(canonical.signature, '$session:0:11');
    expect(padded.signature, isNot(canonical.signature));
  });

  test('catalog diagnostics expose counts without filenames or directories',
      () async {
    wire.onList = (_) {
      sync.acceptEvent([
        0xaa,
        0x55,
        8,
        ...utf8.encode('/private-test/longops_s${session}_p0.ops 11')
      ]);
      sync.acceptEvent(
          [0xaa, 0x55, 8, ...utf8.encode('/private-test/unrelated.dat 11')]);
      sync.acceptEvent([0xaa, 0x55, 8]);
    };
    expect(await sync.refresh(), true);
    expect(
        sync.catalogDiagnostics, '请求=1；最近条目=2；识别长录=1；忽略其它=1；带目录=1；目录完成=true');
    expect(sync.catalogDiagnostics, isNot(contains('private-test')));
    expect(sync.catalogDiagnostics, isNot(contains('$session')));
  });

  test('different basenames for the same session and part reject the catalog',
      () async {
    wire.onList = (_) {
      sync.acceptEvent(listEntry(0, 11));
      sync.acceptEvent([
        0xaa,
        0x55,
        8,
        ...utf8.encode('/records/longops_s${session}_p0000.ops 11')
      ]);
    };
    expect(await sync.refresh(), false);
    expect(sync.snapshot.needsReconnect, true);
    expect(wire.reads, isEmpty);
  });

  test(
      'pending transport write cannot hide timeout or keep operation busy forever',
      () async {
    await sync.dispose();
    sync = RecorderLongFileSync(
        store: store,
        audio: audio,
        send: (_) => Completer<void>().future,
        isReady: () => ready,
        isIdle: () => idle,
        serialNumber: () => sn,
        purpose: (_) => null,
        onChanged: () {},
        progressTimeout: const Duration(milliseconds: 20));
    sync.connected();
    expect(await sync.refresh().timeout(const Duration(seconds: 1)), false);
    await Future<void>.delayed(Duration.zero);
    expect(sync.snapshot.busy, false);
    expect(sync.snapshot.needsReconnect, true);
  });

  test(
      'process restart reloads archive and committed OPS then reads only failed part',
      () async {
    wire.onRead = (part) {
      if (part == 0)
        wire.deliver(part);
      else {
        ready = false;
        sync.connectionLost();
      }
    };
    expect(await sync.sync(session), false);
    await sync.dispose();
    sync = RecorderLongFileSync(
        store: store,
        audio: audio,
        send: wire.send,
        isReady: () => ready,
        isIdle: () => idle,
        serialNumber: () => sn,
        purpose: (_) => null,
        onChanged: () {},
        tailInterval: const Duration(milliseconds: 1));
    wire.sync = sync;
    await sync.initialize();
    expect(sync.snapshot.recordings.single.downloadedParts, 1);
    ready = true;
    sync.connected();
    wire.onRead = null;
    expect(await sync.sync(session), true);
    expect(wire.reads, [0, 1, 1]);
    expect(
        sync.snapshot.recordings.single.purpose, LongRecordingPurpose.meeting);
  });

  test(
      'concurrent different operation is rejected rather than falsely returning previous success',
      () async {
    final first = sync.refresh();
    expect(await sync.sync(session), false);
    expect(await first, true);
    expect(audio.prepares, 0);
  });
}

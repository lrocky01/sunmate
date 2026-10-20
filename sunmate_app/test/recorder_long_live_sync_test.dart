import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_models.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_store.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_sync.dart';
import 'package:sunmate_app/core/hardware/recorder_long_recordings.dart';

import 'recorder_long_file_store_test.dart' show ops;
import 'recorder_long_file_sync_test.dart' as fixture;

class _SessionMemory implements RecorderLongSessionStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String raw) async {
    value = raw;
  }
}

Future<void> _until(bool Function() ready) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    if (clock.elapsed > const Duration(seconds: 3)) {
      fail('本地异步状态未在期限内完成');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  const sn = fixture.sn;
  const session = fixture.session;
  late Directory sandbox;
  late RecorderLongFileStore store;
  late fixture.FileSyncTestAudio audio;
  late fixture.FileSyncTestWire wire;
  late RecorderLongFileSync sync;
  late Map<int, LongRecordingPurpose?> purposes;
  late LongRecordingPurpose? Function(int) purpose;
  var ready = true;
  var idle = false;
  var serial = sn;

  Future<void> create(
      {bool automatic = false,
      Duration poll = const Duration(hours: 1),
      Future<void> Function()? status}) async {
    sync = RecorderLongFileSync(
        store: store,
        audio: audio,
        send: wire.send,
        isReady: () => ready,
        isIdle: () => idle,
        serialNumber: () => serial,
        purpose: (id) => purpose(id),
        onChanged: () {},
        progressTimeout: const Duration(milliseconds: 100),
        tailInterval: const Duration(milliseconds: 1),
        autoSyncDelay: automatic
            ? const Duration(milliseconds: 5)
            : const Duration(days: 1),
        livePollInterval: poll,
        requestStatus: status);
    wire.sync = sync;
    sync.connected();
    await sync.initialize();
  }

  Future<void> automatic() async {
    await sync.dispose();
    await create(automatic: true);
  }

  RecorderLongAudioRecord record([int id = session]) => sync.snapshot.recordings
      .singleWhere((r) => r.sessionId == id && r.serialNumber == sn);

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('sm-live-sync-');
    store = RecorderLongFileStore(
        rootDirectory: () async =>
            Directory('${sandbox.path}/recorder_long_audio_v1'));
    audio = fixture.FileSyncTestAudio(store);
    wire = fixture.FileSyncTestWire();
    ready = true;
    idle = false;
    serial = sn;
    purposes = {session: LongRecordingPurpose.meeting};
    purpose = (id) => purposes[id];
    await create();
  });
  tearDown(() async {
    await sync.dispose();
    await sandbox.delete(recursive: true);
  });

  for (final mode in LongRecordingPurpose.values) {
    test(
        'live ${mode.name}: saves closed OPS without whole-session preparation',
        () async {
      purposes[session] = mode;
      sync.recordingStarted(session);
      sync.segmentClosed(session, 0);
      expect(await sync.sync(session), isTrue);
      expect(wire.reads, [0]);
      expect(audio.prepares, 0);
      expect(record().canPlay, isFalse);
      expect(record().stage, RecorderLongFileStage.recording);
      expect(record().purpose, mode);
      expect(sync.snapshot.activeSessionId, session);
      expect(await store.findSegment(sn, session, 0, 11), isNotNull);
      expect(await store.findSegment(sn, session, 1, 11), isNull);
    });
  }

  test(
      'live purpose uses existing session freeze while next choice is rejected',
      () async {
    final owner = RecorderLongRecordingController(
        store: _SessionMemory(),
        isCardRecording: () => !idle,
        onChanged: () {});
    idle = true;
    await owner.initialize();
    expect(await owner.choose(LongRecordingPurpose.lifelog), isTrue);
    final prepared = owner.started(sn, session);
    idle = false;
    purpose = (id) => owner.snapshot.sessions
        .where((r) => r.sessionId == id)
        .firstOrNull
        ?.purpose;
    sync.recordingStarted(session, preparation: prepared.then<void>((_) {}));
    sync.segmentClosed(session, 0);
    expect(await sync.sync(session), isTrue);
    expect(await owner.choose(LongRecordingPurpose.meeting), isFalse);
    sync.segmentClosed(session, 1);
    expect(await sync.sync(session), isTrue);
    expect(record().purpose, LongRecordingPurpose.lifelog);
    expect(audio.prepares, 0);
    await owner.dispose();
  });

  test('one closed high part never proves lower parts closed', () async {
    wire.parts[2] = ops([
      [0xf8, 0xff, 0xfe]
    ]);
    sync.recordingStarted(session);
    sync.segmentClosed(session, 2);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, [2]);
    expect(await store.findSegment(sn, session, 0, 11), isNull);
    expect(await store.findSegment(sn, session, 1, 11), isNull);
    expect(record().downloadedParts, 1);
    expect(record().canPlay, isFalse);
  });

  test(
      'stable positive catalog sizes without closure do not download active recording',
      () async {
    sync.recordingStarted(session);
    expect(await sync.sync(session), isTrue);
    expect(await sync.sync(session), isTrue);
    expect(wire.lists, 2);
    expect(wire.reads, isEmpty);
    expect(audio.prepares, 0);
  });

  test('active part zero cannot be inferred closed from later catalog entries',
      () async {
    sync.recordingStarted(session, activePart: 0);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, isEmpty);
    expect(audio.prepares, 0);
  });

  test(
      'conflicting close at or above reported active part waits for new status',
      () async {
    sync.recordingStarted(session, activePart: 0);
    sync.segmentClosed(session, 0);
    sync.segmentClosed(session, 1);
    expect(await sync.sync(session), true);
    expect(wire.reads, isEmpty);
    sync.recordingStarted(session, activePart: 1);
    expect(await sync.sync(session), true);
    expect(wire.reads, [0]);
  });

  test('late active status cannot revive a stopped session in same connection',
      () async {
    sync.recordingStarted(session, activePart: 1);
    idle = true;
    sync.recordingStopped(session);
    sync.recordingStarted(session, activePart: 1);
    expect(sync.snapshot.activeSessionId, isNull);
    expect(sync.wasStopped(session), true);
    expect(await sync.sync(session), true);
    expect(record().canPlay, true);
    sync.connected();
    idle = false;
    sync.recordingStarted(session);
    expect(sync.snapshot.activeSessionId, session);
  });

  test('live status polling is serial and stops on stop and connection loss',
      () async {
    await sync.dispose();
    final queried = <Completer<void>>[];
    await create(
        poll: const Duration(milliseconds: 5),
        status: () {
          final result = Completer<void>();
          queried.add(result);
          return result.future;
        });
    sync.recordingStarted(session);
    await _until(() => queried.length == 1);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(queried, hasLength(1));
    sync.connectionLost();
    sync.connected();
    sync.recordingStarted(session);
    await _until(() => queried.length == 2);
    queried[0].complete();
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(queried, hasLength(2));
    queried[1].complete();
    await _until(() => queried.length == 3);
    idle = true;
    sync.recordingStopped(session);
    queried[2].complete();
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(queried, hasLength(3));
    expect(wire.commands, isEmpty);
  });

  test(
      'advancing current activePart saves older candidates only and reuses committed OPS',
      () async {
    wire.parts[2] = ops([
      [0xf8, 0xff, 0xfe]
    ]);
    sync.recordingStarted(session, activePart: 1);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, [0]);
    sync.recordingStarted(session, activePart: 2);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, [0, 1]);
    expect(record().downloadedParts, 2);
    expect(await store.findSegment(sn, session, 2, 11), isNull);
    expect(audio.prepares, 0);
  });

  test(
      'repeated explicit close is idempotent and never downloads same stored bytes again',
      () async {
    sync.recordingStarted(session);
    for (var i = 0; i < 5; i++) {
      sync.segmentClosed(session, 0);
    }
    expect(await sync.sync(session), isTrue);
    sync.segmentClosed(session, 0);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, [0]);
    expect(record().downloadedParts, 1);
  });

  test('automatic burst closures coalesce one serial live operation', () async {
    await automatic();
    sync.recordingStarted(session);
    sync.segmentClosed(session, 0);
    sync.segmentClosed(session, 1);
    sync.segmentClosed(session, 1);
    await _until(() => record().downloadedParts == 2 && !sync.snapshot.busy);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(wire.lists, 1);
    expect(wire.reads, [0, 1]);
    expect(audio.prepares, 0);
  });

  test(
      'stop during held read preserves receiver then tailscans before missing-tail download',
      () async {
    await automatic();
    final reading = Completer<void>();
    wire.onRead = (part) {
      if (part == 0) {
        if (!reading.isCompleted) reading.complete();
      } else {
        wire.deliver(part);
      }
    };
    sync.recordingStarted(session, activePart: 1);
    await reading.future.timeout(const Duration(seconds: 2));
    expect(wire.reads, [0]);
    expect(audio.prepares, 0);
    idle = true;
    sync.recordingStopped(session);
    await Future<void>.delayed(const Duration(milliseconds: 12));
    expect(wire.reads, [0]);
    expect(wire.lists, 1);
    wire.deliver(0);
    await _until(() => record().canPlay && !sync.snapshot.busy);
    expect(wire.reads, [0, 1]);
    expect(wire.lists, 5);
    expect(audio.prepares, 1);
    expect(sync.snapshot.activeSessionId, isNull);
    expect(record().durationMs, 40);
  });

  test(
      'disconnect drops closure proof; fresh proof reuses committed segment without new read',
      () async {
    sync.recordingStarted(session, activePart: 1);
    expect(await sync.sync(session), isTrue);
    ready = false;
    sync.connectionLost();
    ready = true;
    sync.connected();
    sync.recordingStarted(session);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, [0]);
    sync.segmentClosed(session, 0);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, [0]);
    sync.segmentClosed(session, 1);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, [0, 1]);
    expect(audio.prepares, 0);
  });

  test('old automatic failure cannot pause a new verified connection queue',
      () async {
    await automatic();
    final reading = Completer<void>();
    wire.onRead = (part) {
      if (!reading.isCompleted) {
        reading.complete();
      } else {
        wire.deliver(part);
      }
    };
    sync.recordingStarted(session, activePart: 1);
    await reading.future;
    sync.connectionLost();
    sync.connected();
    sync.recordingStarted(session, activePart: 1);
    await _until(() => record().downloadedParts == 1 && !sync.snapshot.busy);
    expect(wire.reads, [0, 0]);
    expect(sync.snapshot.needsReconnect, false);
    expect(audio.prepares, 0);
  });

  test(
      'no authentication means starts and closure hints cannot emit file commands',
      () async {
    ready = false;
    sync.recordingStarted(session, activePart: 1);
    sync.segmentClosed(session, 0);
    expect(await sync.sync(session), isFalse);
    expect(sync.snapshot.activeSessionId, isNull);
    expect(wire.commands, isEmpty);
  });

  test(
      'invalid card identity blocks file writes even with active-looking hints',
      () async {
    serial = 'wrong-card';
    sync.recordingStarted(session, activePart: 1);
    sync.segmentClosed(session, 0);
    expect(await sync.sync(session), isFalse);
    expect(wire.commands, isEmpty);
    expect(audio.prepares, 0);
  });

  test(
      'unrelated session close/stop neither changes active session nor downloads',
      () async {
    sync.recordingStarted(session);
    sync.segmentClosed(session + 1, 0);
    sync.recordingStopped(session + 1);
    expect(sync.snapshot.activeSessionId, session);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, isEmpty);
    expect(await sync.sync(session + 1), isFalse);
    expect(wire.reads, isEmpty);
  });

  test('session preparation is awaited before first list or purpose capture',
      () async {
    purposes[session] = null;
    final prepared = Completer<void>();
    sync.recordingStarted(session, activePart: 1, preparation: prepared.future);
    final operation = sync.sync(session);
    await Future<void>.delayed(const Duration(milliseconds: 12));
    expect(wire.commands, isEmpty);
    purposes[session] = LongRecordingPurpose.lifelog;
    prepared.complete();
    expect(await operation, isTrue);
    expect(record().purpose, LongRecordingPurpose.lifelog);
    expect(wire.reads, [0]);
  });

  test(
      'stop while waiting session preparation finalizes only after that purpose is ready',
      () async {
    await automatic();
    purposes[session] = null;
    final prepared = Completer<void>();
    sync.recordingStarted(session, activePart: 1, preparation: prepared.future);
    await _until(() => sync.snapshot.busy);
    idle = true;
    sync.recordingStopped(session);
    await Future<void>.delayed(const Duration(milliseconds: 12));
    expect(wire.commands, isEmpty);
    purposes[session] = LongRecordingPurpose.lifelog;
    prepared.complete();
    await _until(() => record().canPlay && !sync.snapshot.busy);
    expect(record().purpose, LongRecordingPurpose.lifelog);
    expect(wire.reads, [0, 1]);
    expect(audio.prepares, 1);
  });

  test(
      'stop before automatic live begins still waits for session purpose preparation',
      () async {
    await automatic();
    purposes[session] = null;
    final prepared = Completer<void>();
    sync.recordingStarted(session, activePart: 1, preparation: prepared.future);
    idle = true;
    sync.recordingStopped(session);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(wire.commands, isEmpty);
      expect(audio.prepares, 0);
      purposes[session] = LongRecordingPurpose.lifelog;
      prepared.complete();
      await _until(() => record().canPlay && !sync.snapshot.busy);
      expect(record().purpose, LongRecordingPurpose.lifelog);
    } finally {
      if (!prepared.isCompleted) prepared.complete();
    }
  });

  test(
      'preparation timeout pauses automatic work without emitting any file request',
      () async {
    await automatic();
    final prepared = Completer<void>();
    sync.recordingStarted(session, activePart: 1, preparation: prepared.future);
    await _until(() => sync.snapshot.failed && !sync.snapshot.busy);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(wire.commands, isEmpty);
    expect(audio.prepares, 0);
    expect(record().canPlay, isFalse);
    prepared.complete();
  });

  test('later session preparation cannot replace earlier pending purpose',
      () async {
    final first = Completer<void>();
    purposes[session] = null;
    sync.recordingStarted(session, preparation: first.future);
    idle = true;
    sync.recordingStopped(session);
    idle = false;
    sync.recordingStarted(session + 1, preparation: Future<void>.value());
    idle = true;
    sync.recordingStopped(session + 1);
    final saving = sync.sync(session);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(wire.commands, isEmpty);
    purposes[session] = LongRecordingPurpose.lifelog;
    first.complete();
    expect(await saving, true);
    expect(record().canPlay, true);
    expect(record().purpose, LongRecordingPurpose.lifelog);
  });

  test('activePart regression revokes inferred and explicit closure proof',
      () async {
    wire.parts[2] = ops([
      [0xf8, 0xff, 0xfe]
    ]);
    sync.recordingStarted(session, activePart: 2);
    sync.segmentClosed(session, 2);
    sync.recordingStarted(session, activePart: 1);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, isEmpty);
    sync.segmentClosed(session, 0);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, [0]);
    expect(audio.prepares, 0);
  });

  test(
      'unknown state revokes proof and refuses downloads until current status is restored',
      () async {
    sync.recordingStarted(session, activePart: 1);
    sync.recordingStateUnknown();
    expect(sync.snapshot.activeSessionId, isNull);
    expect(await sync.sync(session), isFalse);
    expect(wire.commands, isEmpty);
    sync.recordingStarted(session);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, isEmpty);
  });

  test('new session cannot inherit old session closure indexes', () async {
    sync.recordingStarted(session);
    sync.segmentClosed(session, 0);
    const second = session + 1;
    purposes[second] = LongRecordingPurpose.lifelog;
    sync.recordingStarted(second);
    wire.onList = (_) {
      sync.acceptEvent(fixture.listEntry(0, wire.parts[0]!.length, id: second));
      sync.acceptEvent([0xaa, 0x55, 8]);
    };
    expect(await sync.sync(second), isTrue);
    expect(wire.reads, isEmpty);
    expect(record(second).canPlay, isFalse);
    expect(record(second).purpose, LongRecordingPurpose.lifelog);
    expect(await sync.sync(session), isFalse);
  });

  test(
      'session switch during read quarantines untagged old bytes instead of reassignment',
      () async {
    final reading = Completer<void>();
    wire.onRead = (_) {
      if (!reading.isCompleted) reading.complete();
    };
    sync.recordingStarted(session, activePart: 1);
    final operation = sync.sync(session);
    await reading.future;
    sync.recordingStarted(session + 1, activePart: 1);
    wire.deliver(0);
    expect(await operation, isFalse);
    expect(sync.snapshot.needsReconnect, isTrue);
    expect(wire.reads, [0]);
    expect(audio.prepares, 0);
    expect(await store.findSegment(sn, session + 1, 0, 11), isNull);
  });

  test(
      'closed segment size growth downloads a new version and retains previous source',
      () async {
    sync.recordingStarted(session);
    sync.segmentClosed(session, 0);
    expect(await sync.sync(session), isTrue);
    final original = await store.findSegment(sn, session, 0, 11);
    wire.parts[0] = ops([
      [0xf8, 0xff, 0xfe],
      [0xf8, 0xff, 0xfe]
    ]);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, [0, 0]);
    expect(await store.findSegment(sn, session, 0, 22), isNotNull);
    expect(await (await store.resolveRelative(original!.relativePath)).exists(),
        isTrue);
    expect(audio.prepares, 0);
    expect(record().canPlay, isFalse);
  });

  test('automatic live timeout locks channel until a fresh verified connection',
      () async {
    await automatic();
    wire.onRead = (part) {
      sync.acceptEvent(fixture.fileSize(wire.parts[part]!.length));
      sync.acceptData(wire.parts[part]!.sublist(0, 4));
    };
    sync.recordingStarted(session, activePart: 1);
    await _until(() => sync.snapshot.needsReconnect && !sync.snapshot.busy);
    expect(wire.reads, [0]);
    sync.segmentClosed(session, 1);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(wire.reads, [0]);
    expect(await sync.sync(session), isFalse);
    expect(wire.reads, [0]);
    sync.connected();
    wire.onRead = null;
    sync.recordingStarted(session, activePart: 1);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, [0, 0]);
  });

  test('dispose cancels pending automatic work and ignores late test packets',
      () async {
    await automatic();
    sync.recordingStarted(session);
    sync.segmentClosed(session, 0);
    await sync.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    sync.acceptData(wire.parts[0]!);
    sync.acceptEvent([0xaa, 0x55, 6]);
    expect(wire.commands, isEmpty);
    expect(audio.prepares, 0);
  });

  test(
      'process restart restores live archive as unconfirmed and requires fresh closure',
      () async {
    sync.recordingStarted(session, activePart: 1);
    expect(await sync.sync(session), isTrue);
    await sync.dispose();
    await create();
    expect(record().stage, RecorderLongFileStage.incomplete);
    expect(sync.snapshot.activeSessionId, isNull);
    expect(record().canPlay, isFalse);
    sync.recordingStarted(session);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, [0]);
    sync.segmentClosed(session, 0);
    expect(await sync.sync(session), isTrue);
    expect(wire.reads, [0]);
  });
}

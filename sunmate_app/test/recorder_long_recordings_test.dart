import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/hardware/recorder_long_recordings.dart';

class MemoryLongSessionStore implements RecorderLongSessionStore {
  String? value;
  bool rejectWrite = false;
  int writes = 0;
  Completer<void>? readGate;
  Completer<void>? writeGate;
  @override
  Future<String?> read() async {
    await readGate?.future;
    return value;
  }

  @override
  Future<void> write(String next) async {
    await writeGate?.future;
    if (rejectWrite) throw StateError('test-only write error');
    writes++;
    value = next;
  }
}

void main() {
  const sn = 'AB00000000000001';
  const other = 'AB00000000000002';
  late MemoryLongSessionStore store;
  late RecorderLongRecordingController controller;
  var recording = false;
  var time = DateTime(2026, 10, 19, 17);
  RecorderLongRecordingController make() => RecorderLongRecordingController(
      store: store,
      isCardRecording: () => recording,
      onChanged: () {},
      now: () => time);
  setUp(() {
    store = MemoryLongSessionStore();
    recording = false;
    controller = make();
  });
  tearDown(() => controller.dispose());

  test(
      'choice persists without Bluetooth and starts with verified local metadata only',
      () async {
    expect(controller.snapshot.loaded, false);
    await controller.initialize();
    expect(controller.snapshot.canChoose, true);
    expect(await controller.choose(LongRecordingPurpose.lifelog), true);
    final restored = make();
    await restored.initialize();
    expect(restored.snapshot.preferred, LongRecordingPurpose.lifelog);
    expect(restored.snapshot.sessions, isEmpty);
    await restored.dispose();
  });

  test(
      'start freezes purpose and duplicate start/stop do not create records or retime',
      () async {
    await controller.choose(LongRecordingPurpose.lifelog);
    expect(await controller.started(sn, 1), true);
    final startTime = controller.snapshot.active!.firstObservedAt;
    time = time.add(const Duration(minutes: 1));
    await controller.started(sn, 1);
    expect(controller.snapshot.sessions.length, 1);
    expect(controller.snapshot.active!.purpose, LongRecordingPurpose.lifelog);
    expect(controller.snapshot.active!.firstObservedAt, startTime);
    expect(await controller.choose(LongRecordingPurpose.meeting), false);
    await controller.stopped(sn, 1);
    final endTime = controller.snapshot.sessions.single.stopObservedAt;
    time = time.add(const Duration(minutes: 1));
    await controller.stopped(sn, 1);
    expect(controller.snapshot.sessions.single.stopObservedAt, endTime);
    expect(controller.snapshot.sessions.single.observationLabel,
        contains('音频未同步'));
    expect(await controller.choose(LongRecordingPurpose.meeting), true);
    expect(controller.snapshot.sessions.single.purpose,
        LongRecordingPurpose.lifelog);
  });

  test('start stop and disconnect arriving together retain event order',
      () async {
    final start = controller.started(sn, 1);
    final stop = controller.stopped(sn, 1);
    final lost = controller.connectionLost();
    expect(await start, true);
    expect(await stop, true);
    expect(await lost, true);
    expect(controller.snapshot.sessions.single.observation,
        LongRecordingObservation.stopped);
    expect(controller.snapshot.active, isNull);
  });

  test(
      'card recording flag blocks selection even without a recovered session id',
      () async {
    await controller.initialize();
    recording = true;
    expect(await controller.choose(LongRecordingPurpose.lifelog), false);
    expect(controller.snapshot.preferred, LongRecordingPurpose.meeting);
    expect(store.writes, 0);
  });

  test(
      'disconnect does not fabricate end and reconnect preserves frozen old purpose',
      () async {
    await controller.started(sn, 1);
    await controller.connectionLost();
    expect(controller.snapshot.sessions.single.stopObservedAt, isNull);
    expect(controller.snapshot.active!.observation,
        LongRecordingObservation.connectionLost);
    await controller.choose(LongRecordingPurpose.lifelog);
    await controller.started(sn, 1, observedStart: false);
    expect(controller.snapshot.active!.purpose, LongRecordingPurpose.meeting);
    expect(controller.snapshot.preferred, LongRecordingPurpose.lifelog);
    await controller.stopped(sn, 1);
    await controller.started(sn, 2);
    expect(controller.snapshot.active!.purpose, LongRecordingPurpose.lifelog);
  });

  test('restart never treats persisted recording as current physical state',
      () async {
    await controller.started(sn, 1);
    final restored = make();
    await restored.initialize();
    expect(restored.snapshot.active, isNull);
    expect(restored.snapshot.sessions.single.observation,
        LongRecordingObservation.unconfirmed);
    await restored.started(sn, 1, observedStart: false);
    expect(restored.snapshot.active!.purpose, LongRecordingPurpose.meeting);
    expect(restored.snapshot.sessions.length, 1);
    await restored.dispose();
  });

  test('historical session discovered from status stays unassigned', () async {
    await controller.choose(LongRecordingPurpose.lifelog);
    await controller.started(sn, 10, observedStart: false);
    expect(controller.snapshot.active!.purpose, isNull);
    expect(controller.snapshot.active!.purposeLabel, '用途未确认');
    await controller.started(sn, 10);
    expect(controller.snapshot.active!.purpose, isNull);
  });

  test('same session number on another SN is a distinct record', () async {
    await controller.started(sn, 1);
    await controller.connectionLost();
    await controller.choose(LongRecordingPurpose.lifelog);
    await controller.started(other, 1);
    expect(controller.snapshot.sessions.length, 2);
    expect(controller.snapshot.active!.serialNumber, other);
    expect(controller.snapshot.active!.purpose, LongRecordingPurpose.lifelog);
    expect(controller.snapshot.sessions.last.purpose,
        LongRecordingPurpose.meeting);
  });

  test('unknown stops and invalid identities cannot create fictional sessions',
      () async {
    expect(await controller.stopped(sn, 123), false);
    expect(await controller.started('--', 1), false);
    expect(await controller.started(sn, 0), false);
    expect(controller.snapshot.sessions, isEmpty);
    expect(store.writes, 0);
  });

  for (final corrupt in [
    'not json',
    '{"version":2,"preferred":"meeting","sessions":[]}',
    '{"version":1,"preferred":"other","sessions":[]}'
  ]) {
    test('corrupt metadata is kept intact instead of overwritten: $corrupt',
        () async {
      store.value = corrupt;
      await controller.initialize();
      expect(controller.snapshot.loaded, false);
      expect(controller.snapshot.failed, true);
      expect(await controller.choose(LongRecordingPurpose.lifelog), false);
      expect(store.value, corrupt);
      expect(store.writes, 0);
    });
  }

  test('failed preference write leaves selected value unchanged', () async {
    await controller.initialize();
    store.rejectWrite = true;
    expect(await controller.choose(LongRecordingPurpose.lifelog), false);
    expect(controller.snapshot.preferred, LongRecordingPurpose.meeting);
    expect(controller.snapshot.failed, true);
    expect(store.value, isNull);
  });

  test('failed session save retains in-memory purpose for explicit retry',
      () async {
    await controller.initialize();
    store.rejectWrite = true;
    expect(await controller.started(sn, 1), false);
    expect(controller.snapshot.active!.purpose, LongRecordingPurpose.meeting);
    expect(controller.snapshot.failed, true);
    store.rejectWrite = false;
    expect(await controller.retrySave(), true);
    final stored = jsonDecode(store.value!) as Map;
    expect((stored['sessions'] as List).length, 1);
    expect(controller.snapshot.message, contains('不代表音频文件已同步'));
  });

  test(
      'a pending preference save cannot reclassify a start that already occurred',
      () async {
    await controller.initialize();
    final gate = Completer<void>();
    store.writeGate = gate;
    final choose = controller.choose(LongRecordingPurpose.lifelog);
    await Future<void>.delayed(Duration.zero);
    final start = controller.started(sn, 1);
    gate.complete();
    expect(await choose, true);
    expect(await start, true);
    expect(controller.snapshot.preferred, LongRecordingPurpose.lifelog);
    expect(controller.snapshot.active!.purpose, LongRecordingPurpose.meeting);
  });

  test(
      'initial load race uses persisted purpose at observed start, not queued choice',
      () async {
    store.value =
        jsonEncode({'version': 1, 'preferred': 'lifelog', 'sessions': []});
    final gate = Completer<void>();
    store.readGate = gate;
    final choose = controller.choose(LongRecordingPurpose.meeting);
    final start = controller.started(sn, 1);
    gate.complete();
    await choose;
    await start;
    expect(controller.snapshot.preferred, LongRecordingPurpose.meeting);
    expect(controller.snapshot.active!.purpose, LongRecordingPurpose.lifelog);
  });

  test('capacity is bounded without silently deleting old metadata', () async {
    final record = RecorderLongSession(
        serialNumber: sn,
        sessionId: 1,
        purpose: LongRecordingPurpose.meeting,
        firstObservedAt: time,
        observation: LongRecordingObservation.stopped);
    final records = List.generate(
        RecorderLongRecordingController.maximumSessions,
        (i) => {...record.toJson(), 'session': i + 1});
    store.value =
        jsonEncode({'version': 1, 'preferred': 'meeting', 'sessions': records});
    final original = store.value;
    expect(await controller.started(sn, 1001), false);
    expect(controller.snapshot.sessions.length,
        RecorderLongRecordingController.maximumSessions);
    expect(store.value, original);
  });

  test('stopped session cannot be resurrected by a duplicate start', () async {
    await controller.started(sn, 1);
    await controller.stopped(sn, 1);
    await controller.choose(LongRecordingPurpose.lifelog);
    await controller.started(sn, 1);
    expect(controller.snapshot.active, isNull);
    expect(controller.snapshot.sessions.single.purpose,
        LongRecordingPurpose.meeting);
    expect(controller.snapshot.sessions.single.observation,
        LongRecordingObservation.stopped);
  });
}

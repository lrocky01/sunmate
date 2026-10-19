import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/hardware/recorder_hardware_settings.dart';

class SettingsFixture {
  bool ready = true;
  final sent = <(String, Map<String, Object>)>[];
  Future<void> Function(String)? sending;
  late final controller = RecorderSettingsController(
      isReady: () => ready,
      send: (method, params) async {
        sent.add((method, Map.of(params)));
        await sending?.call(method);
      },
      onChanged: () {},
      timeout: const Duration(milliseconds: 50));

  Future<void> tick() => Future<void>.delayed(Duration.zero);
  Future<void> read(
      {List<int> caps = const [2001, 3001],
      Map<String, dynamic> values = const {
        'mainKeyMultiClick': 2,
        'longRecordingLedEnabled': true
      },
      bool? recording = false}) async {
    final result = controller.refresh();
    controller.acceptCapabilities({'capabilities': caps});
    await tick();
    if (recording != null) controller.acceptRecording(recording);
    controller.acceptSettings(values);
    expect(await result, true);
  }
}

void main() {
  late SettingsFixture f;
  setUp(() => f = SettingsFixture());
  tearDown(() => f.controller.reset());

  test('current values have no defaults; read capabilities status and settings',
      () async {
    expect(f.controller.snapshot.meetingClicks, isNull);
    expect(f.controller.snapshot.meetingLed, isNull);
    expect(f.controller.snapshot.canEdit, false);
    await f.read();
    expect(f.sent.map((e) => e.$1),
        ['getCapabilities', 'getStatus', 'getUserSettings']);
    expect(f.controller.snapshot.meetingClicks, 2);
    expect(f.controller.snapshot.meetingLed, true);
    expect(f.controller.snapshot.canEdit, true);
  });

  test('unauthenticated reads writes and reports cannot populate settings',
      () async {
    f.ready = false;
    expect(await f.controller.refresh(), false);
    expect(await f.controller.setClicks(3), false);
    expect(await f.controller.setLed(false), false);
    f.controller.acceptCapabilities({
      'capabilities': [2001, 3001]
    });
    f.controller.acceptSettings(
        {'mainKeyMultiClick': 2, 'longRecordingLedEnabled': true});
    expect(f.sent, isEmpty);
    expect(f.controller.snapshot.capabilitiesKnown, false);
  });

  test('strict capabilities cannot be inferred from model or string IDs',
      () async {
    final result = f.controller.refresh();
    f.controller.acceptCapabilities({
      'capabilities': ['2001', 3001]
    });
    expect(await result, false);
    expect(f.sent.map((e) => e.$1), ['getCapabilities']);
    expect(f.controller.snapshot.capabilitiesKnown, false);
  });

  test('unsupported card never reads user settings or writes a switch',
      () async {
    final result = f.controller.refresh();
    f.controller.acceptCapabilities({
      'capabilities': [1002]
    });
    expect(await result, false);
    expect(await f.controller.setClicks(2), false);
    expect(await f.controller.setLed(true), false);
    expect(f.sent.map((e) => e.$1), ['getCapabilities']);
  });

  test('a card may support only one setting without fabricated other values',
      () async {
    await f.read(caps: [3001], values: {'longRecordingLedEnabled': false});
    expect(f.controller.snapshot.meetingClicks, isNull);
    expect(f.controller.snapshot.meetingLed, false);
    expect(await f.controller.setClicks(3), false);
    expect(f.sent.where((e) => e.$1 == 'setUserSettings'), isEmpty);
  });

  for (final value in [
    <String, dynamic>{
      'mainKeyMultiClick': '2',
      'longRecordingLedEnabled': true
    },
    <String, dynamic>{'mainKeyMultiClick': 4, 'longRecordingLedEnabled': true},
    <String, dynamic>{'mainKeyMultiClick': 2, 'longRecordingLedEnabled': 1},
    <String, dynamic>{'mainKeyMultiClick': 2},
  ]) {
    test('incomplete or mistyped read cannot enable edits: $value', () async {
      final result = f.controller.refresh();
      f.controller.acceptCapabilities({
        'capabilities': [2001, 3001]
      });
      await f.tick();
      f.controller.acceptRecording(false);
      f.controller.acceptSettings(value);
      expect(await result, false);
      expect(f.controller.snapshot.canEdit, false);
      expect(f.controller.snapshot.failed, true);
    });
  }

  test('both recording and unknown recording state block writes', () async {
    await f.read(recording: null);
    expect(await f.controller.setClicks(3), false);
    // Only "not long recording" does not prove realtime recording is idle.
    f.controller.acceptStatus({
      'recording': {'is_long_recording': false}
    });
    expect(f.controller.snapshot.recording, isNull);
    f.controller.acceptStatus({
      'recording': {'is_recording': true}
    });
    expect(await f.controller.setLed(false), false);
    f.controller.acceptStatus({
      'recording': {'is_recording': false, 'is_long_recording': true}
    });
    expect(f.controller.snapshot.recording, true);
    f.controller.acceptStatus({
      'recording': {'is_recording': false, 'is_long_recording': false}
    });
    expect(f.controller.snapshot.canEdit, true);
    expect(f.sent.where((e) => e.$1 == 'setUserSettings'), isEmpty);
  });

  test(
      'write only sends changed field, ignores early report and confirms reread',
      () async {
    await f.read();
    final gate = Completer<void>();
    f.sending = (method) async {
      if (method == 'setUserSettings') await gate.future;
    };
    final result = f.controller.setClicks(3);
    expect(f.controller.snapshot.busy, true);
    expect(f.controller.snapshot.meetingClicks, 2);
    f.controller.acceptSettings(
        {'mainKeyMultiClick': 3, 'longRecordingLedEnabled': true});
    expect(f.controller.snapshot.meetingClicks, 2);
    expect(await f.controller.setLed(false), false);
    gate.complete();
    await f.tick();
    expect(f.sent.last.$1, 'getUserSettings');
    f.controller.acceptSettings(
        {'mainKeyMultiClick': 3, 'longRecordingLedEnabled': true});
    expect(await result, true);
    expect(f.sent.where((e) => e.$1 == 'setUserSettings').single.$2,
        {'mainKeyMultiClick': 3});
    expect(f.controller.snapshot.message, '已保存，卡片回读已确认。');
  });

  test('LED off is confirmed false instead of a missing-field default',
      () async {
    await f.read();
    final result = f.controller.setLed(false);
    await f.tick();
    f.controller.acceptSettings({'mainKeyMultiClick': 2});
    expect(f.controller.snapshot.busy, true);
    f.controller.acceptSettings(
        {'mainKeyMultiClick': 2, 'longRecordingLedEnabled': false});
    expect(await result, true);
    expect(f.sent.where((e) => e.$1 == 'setUserSettings').single.$2,
        {'longRecordingLedEnabled': false});
    expect(f.controller.snapshot.meetingLed, false);
  });

  test('mismatch times out without retry or pretending old value was restored',
      () async {
    await f.read();
    final result = f.controller.setClicks(3);
    await f.tick();
    f.controller.acceptSettings(
        {'mainKeyMultiClick': 2, 'longRecordingLedEnabled': true});
    expect(await result, false);
    expect(f.controller.snapshot.meetingClicks, isNull);
    expect(f.controller.snapshot.canEdit, false);
    expect(f.sent.where((e) => e.$1 == 'setUserSettings').length, 1);
    f.controller.acceptSettings(
        {'mainKeyMultiClick': 3, 'longRecordingLedEnabled': true});
    expect(
        f.controller.snapshot.meetingClicks, isNull); // late unsolicited reply
    await f.read(
        values: {'mainKeyMultiClick': 3, 'longRecordingLedEnabled': true});
    expect(f.controller.snapshot.canEdit, true);
  });

  test('transport failure is local to settings and requires reread', () async {
    await f.read();
    f.sending = (_) => Future.error(StateError('test failure'));
    expect(await f.controller.setLed(false), false);
    expect(f.controller.snapshot.failed, true);
    expect(f.controller.snapshot.meetingLed, isNull);
    expect(f.ready, true);
  });

  test('disconnect or new generation blocks old continuation and clears state',
      () async {
    await f.read();
    final gate = Completer<void>();
    f.sending = (method) async {
      if (method == 'setUserSettings') await gate.future;
    };
    final old = f.controller.setClicks(3);
    f.ready = false;
    f.controller.reset();
    expect(await old, false);
    f.ready = true;
    gate.complete();
    await f.tick();
    expect(f.sent.last.$1,
        'setUserSettings'); // old operation cannot request a read
    expect(f.controller.snapshot.meetingClicks, isNull);
    expect(f.controller.snapshot.confirmed, false);
  });

  test('recording starting during write cancels confirmation and followup',
      () async {
    await f.read();
    final gate = Completer<void>();
    f.sending = (method) async {
      if (method == 'setUserSettings') await gate.future;
    };
    final old = f.controller.setClicks(3);
    f.controller.acceptRecording(true);
    expect(await old, false);
    gate.complete();
    await f.tick();
    expect(f.sent.last.$1, 'setUserSettings');
    expect(f.controller.snapshot.canEdit, false);
  });

  test('changed capability snapshot invalidates previously confirmed values',
      () async {
    await f.read();
    f.controller.acceptCapabilities({
      'capabilities': [3001]
    });
    expect(f.controller.snapshot.confirmed, false);
    expect(await f.controller.setLed(false), false);
  });

  test('negative device result cannot confirm even with matching fields',
      () async {
    await f.read();
    final changed = f.controller.setClicks(3);
    await f.tick();
    f.controller.acceptSettings({
      'success': false,
      'mainKeyMultiClick': 3,
      'longRecordingLedEnabled': true
    });
    expect(await changed, false);
    expect(f.controller.snapshot.meetingClicks, isNull);
  });

  test('stalled write has a deadline and cannot send a late followup read',
      () async {
    await f.read();
    final gate = Completer<void>();
    f.sending = (method) async {
      if (method == 'setUserSettings') await gate.future;
    };
    final changed = f.controller.setClicks(3);
    expect(await changed, false);
    expect(f.controller.snapshot.busy, false);
    gate.complete();
    await f.tick();
    expect(f.sent.last.$1, 'setUserSettings');
    expect(f.controller.snapshot.confirmed, false);
  });

  test(
      'reset releases a read waiting for capabilities without further requests',
      () async {
    final reading = f.controller.refresh();
    await f.tick();
    f.controller.reset();
    expect(await reading, false);
    await f.tick();
    expect(f.sent.map((e) => e.$1), ['getCapabilities']);
  });
}

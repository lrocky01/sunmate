import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/ble_constants.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'package:sunmate_app/core/hardware/recorder_long_recordings.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_authentication_test.dart' show MemoryKeyStore, shared;
import 'recorder_long_recordings_test.dart' show MemoryLongSessionStore;
import 'telink_recording_test.dart' show start;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = TestBlePlatform();
  late AiNote6095Driver driver;
  late BluetoothDevice device;
  late MemoryKeyStore keys;
  late MemoryLongSessionStore sessions;
  var number = 0;
  setUpAll(() => FlutterBluePlusPlatform.instance = platform);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    platform.reset();
    platform.reportedSn = 'AB00000000000001';
    keys = MemoryKeyStore()..value = base64Encode(shared);
    sessions = MemoryLongSessionStore();
    device = BluetoothDevice.fromId(
        '40000000-0000-0000-0000-${(++number).toString().padLeft(12, '0')}');
    driver = AiNote6095Driver(
        keyStore: keys,
        longSessionStore: sessions,
        authenticationTimeout: const Duration(milliseconds: 150));
  });
  tearDown(() => driver.dispose());
  void event(List<int> bytes) =>
      platform.notify(device.remoteId, BleConstants.charDeviceEvent, bytes);
  Future<void> until(bool Function() test) async {
    for (var i = 0; i < 100 && !test(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(test(), true);
  }

  Future<void> connect() async {
    platform.authenticate = true;
    expect(await driver.connectDevice(device), true);
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }

  test(
      'real AES then long events freeze local purpose without extra BLE writes or audio submission',
      () async {
    await connect();
    final before = platform.writes.length;
    expect(
        await driver.chooseLongRecordingPurpose(LongRecordingPurpose.lifelog),
        true);
    event(start(11, kind: 1));
    await until(() => driver.longRecordings.active != null);
    expect(driver.longRecordings.active!.purpose, LongRecordingPurpose.lifelog);
    expect(
        await driver.chooseLongRecordingPurpose(LongRecordingPurpose.meeting),
        false);
    event([0xaa, 0x55, 2, 1]);
    await until(() =>
        driver.longRecordings.sessions.single.observation ==
        LongRecordingObservation.stopped);
    expect(driver.lastRecordedBytes, isNull);
    expect(platform.writes.length, before);
    expect(keys.writes, 0);
    expect(driver.isConnected, true);
  });

  test('unauthenticated events cannot create or complete sessions', () async {
    final connecting = driver.connectDevice(device);
    await until(
        () => driver.connectionLogs.any((v) => v.contains('音频 CCCD 已确认')));
    event(start(11, kind: 1));
    event([0xaa, 0x55, 2, 1]);
    platform.event(device.remoteId, {
      'method': 'reportStatus',
      'params': {
        'recording': {'is_long_recording': true, 'long_session': 12}
      }
    });
    expect(await connecting, false);
    expect(driver.longRecordings.sessions, isEmpty);
    expect(sessions.writes, 0);
    expect(keys.writes, 0);
  });

  test('real-time recording does not create long session metadata', () async {
    await connect();
    event(start(11));
    await until(() => driver.isRecording);
    expect(
        await driver.chooseLongRecordingPurpose(LongRecordingPurpose.lifelog),
        false);
    event([0xaa, 0x55, 2, 0]);
    await until(() => !driver.isRecording);
    expect(driver.longRecordings.sessions, isEmpty);
    expect(sessions.writes, 0);
  });

  test('long status cannot replace an active real-time recording', () async {
    await connect();
    event(start(11));
    await until(() => driver.isRecording);
    platform.event(device.remoteId, {
      'method': 'reportStatus',
      'params': {
        'recording': {
          'is_recording': true,
          'is_long_recording': true,
          'long_session': 99
        }
      }
    });
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(driver.longRecordings.sessions, isEmpty);
    event([0xaa, 0x55, 2, 0]);
    await until(() => !driver.isRecording);
    expect(sessions.writes, 0);
    expect(keys.writes, 0);
    expect(driver.isConnected, true);
  });

  test(
      'disconnect preserves frozen session purpose and requires fresh AES on reconnect',
      () async {
    await connect();
    event(start(11, kind: 1));
    await until(() => driver.longRecordings.active != null);
    await driver.disconnect();
    await until(() =>
        driver.longRecordings.active?.observation ==
        LongRecordingObservation.connectionLost);
    expect(driver.longRecordings.sessions.single.stopObservedAt, isNull);
    expect(
        await driver.chooseLongRecordingPurpose(LongRecordingPurpose.lifelog),
        true);
    await connect();
    platform.event(device.remoteId, {
      'method': 'reportStatus',
      'params': {
        'recording': {
          'is_recording': true,
          'is_long_recording': true,
          'long_session': 11
        }
      }
    });
    await until(() =>
        driver.longRecordings.active?.observation ==
        LongRecordingObservation.recording);
    expect(driver.longRecordings.active!.purpose, LongRecordingPurpose.meeting);
    expect(driver.connectionDetails.identityVerified, true);
    expect(keys.writes, 0);
    event([0xaa, 0x55, 2, 1]);
    await until(() =>
        driver.longRecordings.sessions.single.observation ==
        LongRecordingObservation.stopped);
    expect(driver.longRecordings.active, isNull);
    expect(driver.isRecording, false);
  });

  test('discovered historical status cannot inherit today selected purpose',
      () async {
    await connect();
    await driver.chooseLongRecordingPurpose(LongRecordingPurpose.lifelog);
    platform.event(device.remoteId, {
      'method': 'reportStatus',
      'params': {
        'recording': {
          'is_recording': true,
          'is_long_recording': true,
          'long_session': 99
        }
      }
    });
    await until(() => driver.longRecordings.active != null);
    expect(driver.longRecordings.active!.purpose, isNull);
    expect(driver.longRecordings.active!.purposeLabel, '用途未确认');
    expect(
        await driver.chooseLongRecordingPurpose(LongRecordingPurpose.meeting),
        false);
  });

  test(
      'local metadata save failure cannot invalidate AES or replace business keys',
      () async {
    await connect();
    sessions.rejectWrite = true;
    event(start(11, kind: 1));
    await until(() => driver.longRecordings.failed);
    expect(driver.isConnected, true);
    expect(driver.connectionDetails.identityVerified, true);
    expect(driver.longRecordings.active!.purpose, LongRecordingPurpose.meeting);
    expect(keys.writes, 0);
    expect(driver.lastRecordedBytes, isNull);
    sessions.rejectWrite = false;
    expect(await driver.retryLongRecordingSessionSave(), true);
  });
}

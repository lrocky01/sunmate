import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/ble_constants.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_authentication_test.dart' show MemoryKeyStore, shared;
import 'telink_recording_test.dart' show start;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = TestBlePlatform();
  late AiNote6095Driver driver;
  late BluetoothDevice device;
  late MemoryKeyStore keys;
  var number = 0;
  setUpAll(() => FlutterBluePlusPlatform.instance = platform);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    platform.reset();
    keys = MemoryKeyStore()..value = base64Encode(shared);
    device = BluetoothDevice.fromId(
        '30000000-0000-0000-0000-${(++number).toString().padLeft(12, '0')}');
    driver = AiNote6095Driver(
        keyStore: keys,
        authenticationTimeout: const Duration(milliseconds: 150),
        settingsTimeout: const Duration(milliseconds: 250));
  });
  tearDown(() => driver.dispose());
  Map<String, dynamic>? request(BmWriteCharacteristicRequest r) {
    if (r.value.length < 3 || r.value[1] != 0x30) return null;
    return jsonDecode(utf8.decode(r.value.sublist(2))) as Map<String, dynamic>;
  }

  int count(String method) =>
      platform.writes.where((r) => request(r)?['method'] == method).length;
  Future<void> until(bool Function() test) async {
    for (var i = 0; i < 100 && !test(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(test(), true);
  }

  void report(String method, Map<String, dynamic> params) =>
      platform.event(device.remoteId, {'method': method, 'params': params});
  Future<void> readReady() async {
    platform.authenticate = true;
    expect(await driver.connectDevice(device), true); // real AES test challenge
    final read = driver.refreshHardwareSettings(); // joins automatic read
    report('reportCapabilities', {
      'capabilities': [1002, 2001, 3001]
    });
    await until(() => count('getUserSettings') == 1);
    report('reportStatus', {
      'recording': {'is_recording': false, 'is_long_recording': false}
    });
    report('reportUserSettings',
        {'mainKeyMultiClick': 2, 'longRecordingLedEnabled': true});
    expect(await read, true);
    expect(driver.hardwareSettings.canEdit, true);
  }

  test(
      'verified driver writes correct business channel and only requested field',
      () async {
    await readReady();
    final changed = driver.setMeetingRecordingClicks(3);
    await until(() => count('getUserSettings') == 2);
    // ATT write and unrelated status cannot confirm saving.
    expect(driver.hardwareSettings.busy, true);
    report('reportStatus', {'battery': 66});
    report('setUserSettingsResult', {'success': true});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(driver.hardwareSettings.busy, true);
    report('reportUserSettings',
        {'mainKeyMultiClick': 3, 'longRecordingLedEnabled': true});
    expect(await changed, true);
    final write = platform.writes
        .singleWhere((r) => request(r)?['method'] == 'setUserSettings');
    expect(write.serviceUuid.str, BleConstants.serviceOpus);
    expect(write.characteristicUuid.str, BleConstants.charAppCmdWrite);
    expect(write.writeType, BmWriteType.withoutResponse);
    expect(write.value.take(2), [0x11, 0x30]);
    expect(request(write)!['params'], {'mainKeyMultiClick': 3});
    expect(driver.isConnected, true);
    expect(keys.writes, 0);
  });

  test('LED off saves by verified readback without changing click count',
      () async {
    await readReady();
    final changed = driver.setMeetingRecordingLed(false);
    await until(() => count('getUserSettings') == 2);
    report('reportUserSettings',
        {'mainKeyMultiClick': 2, 'longRecordingLedEnabled': false});
    expect(await changed, true);
    expect(driver.hardwareSettings.meetingLed, false);
    expect(
        request(platform.writes.singleWhere(
            (r) => request(r)?['method'] == 'setUserSettings'))!['params'],
        {'longRecordingLedEnabled': false});
    expect(keys.writes, 0);
  });

  test('unauthenticated reports cannot enable settings or issue config writes',
      () async {
    final connecting = driver.connectDevice(device);
    await until(
        () => driver.connectionLogs.any((l) => l.contains('音频 CCCD 已确认')));
    report('reportCapabilities', {
      'capabilities': [2001, 3001]
    });
    report('reportUserSettings',
        {'mainKeyMultiClick': 2, 'longRecordingLedEnabled': true});
    report('reportStatus', {'isRecording': false});
    expect(await driver.setMeetingRecordingClicks(3), false);
    expect(await connecting, false);
    expect(count('setUserSettings'), 0);
    expect(count('getUserSettings'), 0);
    expect(driver.hardwareSettings.confirmed, false);
    expect(keys.writes, 0);
  });

  test('binary long recording blocks both controls until matching stop',
      () async {
    await readReady();
    platform.notify(
        device.remoteId, BleConstants.charDeviceEvent, start(101, kind: 1));
    await until(() => driver.isRecording);
    expect(driver.hardwareSettings.recording, true);
    expect(await driver.setMeetingRecordingClicks(3), false);
    expect(await driver.setMeetingRecordingLed(false), false);
    expect(count('setUserSettings'), 0);
    platform.notify(
        device.remoteId, BleConstants.charDeviceEvent, [0xaa, 0x55, 2, 1]);
    await until(() => !driver.isRecording);
    expect(driver.hardwareSettings.canEdit, true);
    expect(driver.lastRecordedBytes, isNull);
  });

  test('disconnect cancels pending confirmation and old notifications',
      () async {
    await readReady();
    final changed = driver.setMeetingRecordingClicks(3);
    await until(() => count('getUserSettings') == 2);
    await driver.disconnect();
    expect(await changed, false);
    report('reportUserSettings',
        {'mainKeyMultiClick': 3, 'longRecordingLedEnabled': true});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(driver.hardwareSettings.confirmed, false);
    expect(driver.hardwareSettings.meetingClicks, isNull);
    expect(driver.hardwareSettings.connected, false);
    expect(keys.writes, 0);
  });

  test(
      'missing setting replies leave AES connection usable and never retry a write',
      () async {
    await readReady();
    final changed = driver.setMeetingRecordingLed(false);
    expect(await changed, false);
    expect(driver.isConnected, true);
    expect(driver.connectionDetails.identityVerified, true);
    expect(driver.hardwareSettings.failed, true);
    expect(driver.hardwareSettings.meetingLed, isNull);
    expect(count('setUserSettings'), 1);
    expect(keys.writes, 0);
  });
}

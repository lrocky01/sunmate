import 'dart:convert';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/ble_constants.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'package:sunmate_app/core/hardware/recorder_long_file_store.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_authentication_test.dart' show MemoryKeyStore, shared;
import 'recorder_long_file_store_test.dart' show ops;
import 'recorder_long_recordings_test.dart' show MemoryLongSessionStore;
import 'package:sunmate_app/core/hardware/recorder_long_recordings.dart';
import 'telink_recording_test.dart' show start;
import 'recorder_long_file_sync_test.dart'
    show FileSyncTestAudio, listEntry, fileSize, session;
import 'telink_notification_test.dart' show notificationFrame;

final class LongFileBlePlatform extends TestBlePlatform {
  final fileCommands = <BmWriteCharacteristicRequest>[];
  final subscribed = <String>[];
  bool includeFileChannel = true;
  bool rejectFileSubscribe = false;
  int listedParts = 1;
  @override
  Future<bool> discoverServices(BmDiscoverServicesRequest request) async {
    services.add(BmDiscoverServicesResult(
        remoteId: request.remoteId,
        success: true,
        errorCode: 0,
        errorString: '',
        services: [
          service(request.remoteId, BleConstants.serviceOta,
              [BleConstants.charOta]),
          service(request.remoteId, BleConstants.serviceOpus, [
            BleConstants.charAppCmdWrite,
            BleConstants.charDeviceEvent,
            BleConstants.charOpusAudioData,
            if (includeFileChannel) BleConstants.charFileData
          ]),
        ]));
    return true;
  }

  @override
  Future<bool> setNotifyValue(BmSetNotifyValueRequest request) async {
    subscribed.add(request.characteristicUuid.str);
    if (rejectFileSubscribe &&
        request.characteristicUuid.str == BleConstants.charFileData) {
      throw StateError('test-only-file-subscribe-error');
    }
    return super.setNotifyValue(request);
  }

  @override
  Future<bool> writeCharacteristic(BmWriteCharacteristicRequest request) async {
    final bytes = request.value;
    if (bytes.length < 2 ||
        bytes[0] != 0x11 ||
        ![0x22, 0x26].contains(bytes[1])) {
      return super.writeCharacteristic(request);
    }
    writes.add(request);
    fileCommands.add(request);
    written.add(BmCharacteristicData(
        remoteId: request.remoteId,
        primaryServiceUuid: request.primaryServiceUuid,
        serviceUuid: request.serviceUuid,
        characteristicUuid: request.characteristicUuid,
        instanceId: request.instanceId,
        value: bytes,
        success: true,
        errorCode: 0,
        errorString: ''));
    final data = ops([
      [0xf8, 0xff, 0xfe]
    ]);
    if (bytes[1] == 0x22) {
      for (var part = 0; part < listedParts; part++) {
        notify(request.remoteId, BleConstants.charDeviceEvent,
            listEntry(part, data.length));
      }
      notify(request.remoteId, BleConstants.charDeviceEvent, [0xaa, 0x55, 8]);
    } else {
      notify(request.remoteId, BleConstants.charDeviceEvent,
          fileSize(data.length));
      notify(request.remoteId, BleConstants.charFileData, data);
      notify(request.remoteId, BleConstants.charDeviceEvent, [0xaa, 0x55, 6]);
    }
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = LongFileBlePlatform();
  late Directory sandbox;
  late RecorderLongFileStore store;
  late FileSyncTestAudio audio;
  late MemoryKeyStore keys;
  late AiNote6095Driver driver;
  late BluetoothDevice device;
  var index = 0;
  setUpAll(() => FlutterBluePlusPlatform.instance = platform);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    platform.reset();
    platform.includeFileChannel = true;
    platform.rejectFileSubscribe = false;
    platform.listedParts = 1;
    platform.fileCommands.clear();
    platform.subscribed.clear();
    sandbox = await Directory.systemTemp.createTemp('sm-long-gatt-');
    store = RecorderLongFileStore(
        rootDirectory: () async =>
            Directory('${sandbox.path}/recorder_long_audio_v1'));
    audio = FileSyncTestAudio(store);
    keys = MemoryKeyStore()..value = base64Encode(shared);
    driver = AiNote6095Driver(
        keyStore: keys,
        longFileStore: store,
        longSessionStore: MemoryLongSessionStore(),
        localAudio: audio,
        authenticationTimeout: const Duration(milliseconds: 150));
    device = BluetoothDevice.fromId(
        '59000000-0000-0000-0000-${(++index).toString().padLeft(12, '0')}');
  });
  tearDown(() async {
    await driver.dispose();
    await sandbox.delete(recursive: true);
  });
  Future<void> connect() async {
    platform.authenticate = true;
    platform.reportedSn = 'AB00000000000001';
    expect(await driver.connectDevice(device), true);
    platform.event(device.remoteId, {
      'method': 'reportStatus',
      'params': {
        'recording': {'is_recording': false, 'is_long_recording': false}
      }
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  Future<void> until(bool Function() ready) async {
    final clock = Stopwatch()..start();
    while (!ready() && clock.elapsed < const Duration(seconds: 7)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(ready(), true);
  }

  List<int> downloadedParts() => platform.fileCommands
      .where((w) => w.value[1] == 0x26)
      .map((w) => int.parse(RegExp(r'_p(\d+)\.ops$')
          .firstMatch(utf8.decode(w.value.sublist(2)))!
          .group(1)!))
      .toList();

  for (final mode in LongRecordingPurpose.values) {
    test('AES + ${mode.name}: live closed download then stop archives tail',
        () async {
      await connect();
      expect(await driver.chooseLongRecordingPurpose(mode), true);
      platform.listedParts = 2;
      platform.notify(device.remoteId, BleConstants.charDeviceEvent,
          start(session, kind: 1));
      platform.event(device.remoteId, {
        'method': 'reportLongOpsSegmentClosed',
        'params': {'session': session, 'part': 0}
      });
      await until(() =>
          !driver.longFileLibrary.busy &&
          driver.longFileLibrary.recordings.any((r) => r.downloadedParts == 1));
      expect(driver.longFileLibrary.recordings.single.canPlay, false);
      expect(downloadedParts(), [0]);
      expect(audio.prepares, 0);
      expect(driver.longFileLibrary.recordings.single.purpose, mode);
      platform.notify(
          device.remoteId, BleConstants.charDeviceEvent, [0xaa, 0x55, 2, 1]);
      await until(() =>
          !driver.longFileLibrary.busy &&
          driver.longFileLibrary.recordings.single.canPlay);
      expect(downloadedParts(), [0, 1]);
      expect(driver.longFileLibrary.recordings.single.purpose, mode);
      expect(audio.prepares, 1);
      expect(driver.lastRecordedBytes, isNull);
      expect(driver.isConnected, true);
      expect(keys.writes, 0);
      for (final write in platform.fileCommands) {
        expect(write.characteristicUuid.str, BleConstants.charAppCmdWrite);
        expect(write.writeType, BmWriteType.withoutResponse);
        expect([0x22, 0x26], contains(write.value[1]));
      }
    });
  }

  test(
      'verified active status resumes closed parts and matching stopped status finalizes',
      () async {
    await connect();
    platform.listedParts = 2;
    platform.event(device.remoteId, {
      'method': 'reportStatus',
      'params': {
        'recording': {
          'is_recording': true,
          'is_long_recording': true,
          'long_session': session,
          'long_part': 1
        }
      }
    });
    await until(
        () => !driver.longFileLibrary.busy && downloadedParts().isNotEmpty);
    expect(downloadedParts(), [0]);
    expect(driver.longFileLibrary.activeSessionId, session);
    expect(driver.longFileLibrary.recordings.single.purpose, isNull);
    platform.event(device.remoteId, {
      'method': 'reportStatus',
      'params': {
        'recording': {
          'is_recording': false,
          'is_long_recording': false,
          'long_session': session,
          'long_part': 1
        }
      }
    });
    await until(() => driver.longFileLibrary.activeSessionId == null);
    platform.event(device.remoteId, {
      'method': 'reportStatus',
      'params': {
        'recording': {
          'is_recording': true,
          'is_long_recording': true,
          'long_session': session,
          'long_part': 1
        }
      }
    });
    platform.notify(
        device.remoteId, BleConstants.charDeviceEvent, start(session, kind: 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(driver.longFileLibrary.activeSessionId, isNull);
    expect(driver.isRecording, false);
    expect(driver.hardwareSettings.recording, false);
    await until(() =>
        !driver.longFileLibrary.busy &&
        driver.longFileLibrary.recordings.single.canPlay);
    expect(downloadedParts(), [0, 1]);
    expect(keys.writes, 0);
  });

  test('unknown or different active session cannot reuse old closed proofs',
      () async {
    await connect();
    platform.listedParts = 2;
    platform.notify(
        device.remoteId, BleConstants.charDeviceEvent, start(session, kind: 1));
    platform.event(device.remoteId, {
      'method': 'reportLongOpsSegmentClosed',
      'params': {'session': session, 'part': 0}
    });
    platform.event(device.remoteId, {
      'method': 'reportStatus',
      'params': {
        'recording': {'is_long_recording': true}
      }
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(platform.fileCommands, isEmpty);
    expect(driver.longFileLibrary.activeSessionId, isNull);
    platform.event(device.remoteId, {
      'method': 'reportStatus',
      'params': {
        'recording': {
          'is_long_recording': true,
          'long_session': session + 1,
          'long_part': 0
        }
      }
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(driver.longFileLibrary.activeSessionId, session + 1);
    expect(platform.fileCommands, isEmpty);
    expect(keys.writes, 0);
  });

  test(
      'AES challenge -> file CCCD -> readonly NR commands -> local archive, no realtime mix',
      () async {
    await connect();
    expect(platform.subscribed, contains(BleConstants.charFileData));
    expect(driver.hardwareSettings.recording, false);
    expect(await driver.refreshLongFiles(), true);
    expect(driver.longFileLibrary.recordings.single.sessionId, session);
    expect(await driver.syncLongRecording(session), true);
    expect(driver.longFileLibrary.recordings.single.canPlay, true);
    expect(driver.lastRecordedBytes, isNull);
    expect(driver.isConnected, true);
    expect(keys.writes, 0);
    expect(
        platform.fileCommands.where((w) => w.value[1] == 0x26), hasLength(1));
    for (final write in platform.fileCommands) {
      expect(write.characteristicUuid.str, BleConstants.charAppCmdWrite);
      expect(write.serviceUuid.str, BleConstants.serviceOpus);
      expect(write.writeType, BmWriteType.withoutResponse);
      expect(write.value[1], isNot(0x24));
    }
    // 同通道通知和设置/电量回报继续正常，未被文件解析器吞掉。
    platform.notify(
        device.remoteId, BleConstants.charDeviceEvent, notificationFrame());
    platform.event(device.remoteId, {
      'method': 'reportStatus',
      'params': {'battery': 71}
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(driver.batteryLevel, 71);
    expect(driver.diagnosticText, contains('本机可播放=1'));
  });

  test('unverified or recording state unknown cannot trigger file reads',
      () async {
    expect(await driver.refreshLongFiles(), false);
    platform.authenticate = true;
    expect(await driver.connectDevice(device), true);
    expect(driver.hardwareSettings.recording, isNull);
    expect(await driver.refreshLongFiles(), false);
    expect(platform.fileCommands, isEmpty);
    expect(keys.writes, 0);
  });

  test(
      'missing or rejected file CCCD does not destroy valid AES/realtime connection',
      () async {
    platform.rejectFileSubscribe = true;
    await connect();
    expect(driver.isConnected, true);
    expect(await driver.refreshLongFiles(), false);
    expect(platform.fileCommands, isEmpty);
    expect(driver.isConnected, true);
    expect(keys.writes, 0);
  });

  test('known closed segment hint prevents prematurely finalizing missing tail',
      () async {
    await connect();
    platform.event(device.remoteId, {
      'method': 'reportLongOpsSegmentClosed',
      'params': {'session': session, 'part': 1}
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(await driver.syncLongRecording(session), false);
    expect(platform.fileCommands.where((w) => w.value[1] == 0x26), isEmpty);
    expect(driver.longFileLibrary.recordings.single.canPlay, false);
    expect(driver.isConnected, true);
  });
}

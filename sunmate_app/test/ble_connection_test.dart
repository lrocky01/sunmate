import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sunmate_app/core/ble/ble_constants.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'package:sunmate_app/core/ble/yoooclaw_account.dart';
import 'yoooclaw_account_test.dart' show record;
import 'recorder_authentication_test.dart' show MemoryKeyStore, shared;

/// 模拟 GATT 操作与设备异步事件，检查驱动不会把 ATT 成功误当业务成功。
final class TestBlePlatform extends FlutterBluePlusPlatform {
  final connections = StreamController<BmConnectionStateResponse>.broadcast();
  final services = StreamController<BmDiscoverServicesResult>.broadcast();
  final descriptors = StreamController<BmDescriptorData>.broadcast();
  final received = StreamController<BmCharacteristicData>.broadcast();
  final written = StreamController<BmCharacteristicData>.broadcast();
  final mtus = StreamController<BmMtuChangedResponse>.broadcast();
  final writes = <BmWriteCharacteristicRequest>[];
  int connectCount = 0;
  bool otaOnly = false;
  bool rejectNotify = false;
  bool holdConnect = false;
  String replyMethod = 'bindResult';
  Object replySuccess = false;
  bool authenticate = false;
  String? reportedSn;

  @override
  Stream<BmConnectionStateResponse> get onConnectionStateChanged =>
      connections.stream;
  @override
  Stream<BmDiscoverServicesResult> get onDiscoveredServices => services.stream;
  @override
  Stream<BmDescriptorData> get onDescriptorWritten => descriptors.stream;
  @override
  Stream<BmCharacteristicData> get onCharacteristicReceived => received.stream;
  @override
  Stream<BmCharacteristicData> get onCharacteristicWritten => written.stream;
  @override
  Stream<BmMtuChangedResponse> get onMtuChanged => mtus.stream;
  @override
  Future<BmBluetoothAdapterState> getAdapterState(
          BmBluetoothAdapterStateRequest request) async =>
      BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on);

  void state(DeviceIdentifier id, BmConnectionStateEnum state) {
    connections.add(BmConnectionStateResponse(
        remoteId: id,
        connectionState: state,
        disconnectReasonCode:
            state == BmConnectionStateEnum.disconnected ? 9 : null,
        disconnectReasonString: state == BmConnectionStateEnum.disconnected
            ? 'Peripheral disconnected'
            : null));
  }

  @override
  Future<bool> connect(BmConnectRequest request) async {
    connectCount++;
    if (!holdConnect) {
      mtus.add(BmMtuChangedResponse(remoteId: request.remoteId, mtu: 185));
      state(request.remoteId, BmConnectionStateEnum.connected);
    }
    return true;
  }

  @override
  Future<bool> disconnect(BmDisconnectRequest request) async {
    state(request.remoteId, BmConnectionStateEnum.disconnected);
    return true;
  }

  BmBluetoothService service(
          DeviceIdentifier id, String serviceId, List<String> chars) =>
      BmBluetoothService(
          remoteId: id,
          primaryServiceUuid: null,
          serviceUuid: Guid(serviceId),
          characteristics: chars
              .map((char) => BmBluetoothCharacteristic(
                    remoteId: id,
                    primaryServiceUuid: null,
                    serviceUuid: Guid(serviceId),
                    characteristicUuid: Guid(char),
                    instanceId: 0,
                    descriptors: [],
                    properties: BmCharacteristicProperties(
                      broadcast: false,
                      read: false,
                      writeWithoutResponse:
                          char == BleConstants.charAppCmdWrite ||
                              char == BleConstants.charOta,
                      write: false,
                      notify: char != BleConstants.charAppCmdWrite,
                      indicate: false,
                      authenticatedSignedWrites: false,
                      extendedProperties: false,
                      notifyEncryptionRequired: false,
                      indicateEncryptionRequired: false,
                    ),
                  ))
              .toList());

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
          if (!otaOnly)
            service(request.remoteId, BleConstants.serviceOpus, [
              BleConstants.charAppCmdWrite,
              BleConstants.charDeviceEvent,
              BleConstants.charOpusAudioData,
            ]),
        ]));
    return true;
  }

  @override
  Future<bool> setNotifyValue(BmSetNotifyValueRequest request) async {
    descriptors.add(BmDescriptorData(
        remoteId: request.remoteId,
        primaryServiceUuid: request.primaryServiceUuid,
        serviceUuid: request.serviceUuid,
        characteristicUuid: request.characteristicUuid,
        descriptorUuid: Guid('2902'),
        instanceId: request.instanceId,
        value: [1, 0],
        success: !rejectNotify,
        errorCode: rejectNotify ? 15 : 0,
        errorString: rejectNotify ? 'Insufficient encryption' : ''));
    return true;
  }

  @override
  Future<bool> writeCharacteristic(BmWriteCharacteristicRequest request) async {
    writes.add(request);
    written.add(BmCharacteristicData(
        remoteId: request.remoteId,
        primaryServiceUuid: request.primaryServiceUuid,
        serviceUuid: request.serviceUuid,
        characteristicUuid: request.characteristicUuid,
        instanceId: request.instanceId,
        value: request.value,
        success: true,
        errorCode: 0,
        errorString: ''));
    final method = jsonDecode(utf8.decode(request.value.sublist(2)))['method'];
    if (method == 'getStatus' || (authenticate && method == 'verifyIdentity')) {
      final payload = utf8.encode(jsonEncode({
        'method': authenticate
            ? (method == 'getStatus'
                ? 'verifyIdentityRequest'
                : 'verifyIdentityResult')
            : replyMethod,
        'params': authenticate && method == 'getStatus'
            ? {'random': base64Encode(List.generate(32, (i) => i))}
            : {
                if (reportedSn != null) 'sn': reportedSn,
                'success': authenticate
                    ? jsonDecode(utf8.decode(request.value.sublist(2)))[
                            'params']['encrypted'] ==
                        'AWzzgd9AzLT+5DRwv3vC0DVE6lAp3218tf/EtCRcSY7+tu7AL/fYC9sVh8tjnQEh'
                    : replySuccess
              }
      }));
      received.add(BmCharacteristicData(
          remoteId: request.remoteId,
          primaryServiceUuid: null,
          serviceUuid: Guid(BleConstants.serviceOpus),
          characteristicUuid: Guid(BleConstants.charDeviceEvent),
          instanceId: 0,
          value: [0xaa, 0x55, 0x30, 0, 0, ...payload],
          success: true,
          errorCode: 0,
          errorString: ''));
    }
    return true;
  }

  void notify(DeviceIdentifier id, String characteristic, List<int> bytes) {
    received.add(BmCharacteristicData(
        remoteId: id,
        primaryServiceUuid: null,
        serviceUuid: Guid(BleConstants.serviceOpus),
        characteristicUuid: Guid(characteristic),
        instanceId: 0,
        value: bytes,
        success: true,
        errorCode: 0,
        errorString: ''));
  }

  void event(DeviceIdentifier id, Map<String, dynamic> value) => notify(
      id,
      BleConstants.charDeviceEvent,
      [0xaa, 0x55, 0x30, 0, 0, ...utf8.encode(jsonEncode(value))]);

  void reset() {
    writes.clear();
    authenticate = false;
    reportedSn = null;
    connectCount = 0;
    otaOnly = false;
    rejectNotify = false;
    holdConnect = false;
    replyMethod = 'bindResult';
    replySuccess = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = TestBlePlatform();
  var sequence = 0;
  late AiNote6095Driver driver;
  late BluetoothDevice device;
  setUpAll(() {
    FlutterBluePlusPlatform.instance = platform;
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    platform.reset();
    device = BluetoothDevice.fromId(
        '00000000-0000-0000-0000-${(++sequence).toString().padLeft(12, "0")}');
    driver = AiNote6095Driver();
  });
  tearDown(() async {
    await driver.dispose();
  });

  test('OTA-only device is disconnected without a single write', () async {
    platform.otaOnly = true;
    expect(await driver.connectDevice(device), false);
    expect(platform.writes, isEmpty);
    expect(driver.isConnected, false);
    expect(
        driver.connectionLogs.any((s) => s.contains(BleConstants.serviceOta)),
        true);
  });

  test('CCCD failure stops initialization before sending commands', () async {
    platform.rejectNotify = true;
    expect(await driver.connectDevice(device), false);
    expect(platform.writes, isEmpty);
    expect(driver.diagnosticText, contains('Insufficient encryption'));
  });

  test(
      'successful writes plus bindResult=false never become connection success',
      () async {
    expect(await driver.connectDevice(device), false);
    expect(driver.isConnected, false);
    expect(platform.writes, isNotEmpty);
    expect(
        platform.writes.every((w) =>
            w.serviceUuid.str == BleConstants.serviceOpus &&
            w.characteristicUuid.str == BleConstants.charAppCmdWrite &&
            w.writeType == BmWriteType.withoutResponse),
        true);
    expect(
        platform.writes.every((w) => w.value[0] == 0x11 && w.value[1] == 0x30),
        true);
    expect(platform.writes.map((w) => utf8.decode(w.value.sublist(2))).join(),
        isNot(contains('sunmate_auth')));
    expect(
        (await SharedPreferences.getInstance())
            .getString('sunmate_verified_ble_device_id_v2'),
        isNull);
  });

  test(
      'identity challenge does not cause a fabricated response or secret logging',
      () async {
    platform.replyMethod = 'verifyIdentityRequest';
    expect(await driver.connectDevice(device), false);
    final methods = platform.writes
        .map((w) => jsonDecode(utf8.decode(w.value.sublist(2)))['method'])
        .toList();
    expect(methods, isNot(contains('verifyIdentity')));
    expect(driver.connectionSummary, '业务鉴权未完成');
  });

  test('two calls for same device share one connection operation', () async {
    final first = driver.connectDevice(device);
    final second = driver.connectDevice(device);
    expect(identical(first, second), true);
    await Future.wait([first, second]);
    expect(platform.connectCount, 1);
  });

  test('bindResult=true alone still cannot mark business ready', () async {
    platform.replySuccess = true;
    expect(await driver.connectDevice(device), false);
    expect(driver.isConnected, false);
    expect(
        (await SharedPreferences.getInstance())
            .getString('sunmate_verified_ble_device_id_v2'),
        isNull);
  });

  test('unsolicited identity-success acknowledgement cannot mark ready',
      () async {
    platform.replyMethod = 'verifyIdentityResult';
    platform.replySuccess = true;
    expect(await driver.connectDevice(device), false);
    expect(driver.isConnected, false);
    await Future<void>.delayed(Duration.zero);
    expect(
        (await SharedPreferences.getInstance())
            .getString('sunmate_verified_ble_device_id_v2'),
        isNull);
  });

  test(
      'saved real-key protocol completes a challenge round trip without bindRequest',
      () async {
    await driver.dispose();
    final keys = MemoryKeyStore()..value = base64Encode(shared);
    driver = AiNote6095Driver(keyStore: keys);
    platform.authenticate = true;
    expect(await driver.connectDevice(device), true);
    final methods = platform.writes
        .map((w) => jsonDecode(utf8.decode(w.value.sublist(2)))['method']);
    expect(methods, contains('verifyIdentity'));
    expect(methods, isNot(contains('bindRequest')));
    expect(driver.isConnected, true);
    expect(driver.diagnosticText, isNot(contains(base64Encode(shared))));
    expect(driver.diagnosticText, isNot(contains('AWzzgd9AzLT+5DR')));
  });

  test(
      'verified hardware voice sessions emit complete Ogg before release; abort discards',
      () async {
    await driver.dispose();
    driver = AiNote6095Driver(
        keyStore: MemoryKeyStore()..value = base64Encode(shared));
    platform.authenticate = true;
    expect(await driver.connectDevice(device), true);
    final order = <String>[];
    final collected = <int>[];
    final buttons = driver.buttonEvents.listen((e) => order.add(e.action.name));
    final audio = driver.audioStream.listen((e) {
      order.add('audio');
      collected.addAll(e.bytes);
    });
    platform.event(device.remoteId, {
      'method': 'voiceCmd',
      'params': {'event': 'start', 'session_id': 77}
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    platform.notify(device.remoteId, BleConstants.charOpusAudioData,
        [3, 0, 0, 0, 0, 0, 0, 0, 0xf8, 0xff, 0xfe]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    platform.event(device.remoteId, {
      'method': 'voiceCmd',
      'params': {'event': 'release', 'session_id': 78}
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(driver.isRecording, true); // Wrong session cannot finalize.
    platform.event(device.remoteId, {
      'method': 'voiceCmd',
      'params': {'event': 'release', 'session_id': 77}
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(driver.isRecording, false);
    expect(collected, driver.lastRecordedBytes);
    expect(order.first, 'pressDown');
    expect(order.last, 'release');
    expect(String.fromCharCodes(collected.take(4)), 'OggS');
    platform.event(device.remoteId, {
      'method': 'voiceCmd',
      'params': {'event': 'start', 'session_id': 99}
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    platform.event(device.remoteId, {
      'method': 'voiceCmd',
      'params': {'event': 'abort', 'session_id': 99}
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(order.last, 'cancel');
    expect(driver.lastRecordedBytes, isNull);
    await buttons.cancel();
    await audio.cancel();
  });

  test('own-account restore requires observed SN/profile and verifies on reconnect', () async {
    await driver.dispose();
    final keys = MemoryKeyStore();
    driver = AiNote6095Driver(keyStore: keys);
    final matching = OwnedRecorderBinding.fromAccountRecord(record())!;
    expect(await driver.restoreOwnedBinding(matching), false);
    expect(keys.writes, 0);
    platform.replyMethod = 'verifyRequest';
    platform.reportedSn = matching.serialNumber;
    expect(await driver.connectDevice(device), false);
    final wrong = OwnedRecorderBinding.fromAccountRecord(record(sn: 'AB00000000000002'))!;
    expect(await driver.restoreOwnedBinding(wrong), false);
    expect(keys.writes, 0);
    expect(await driver.restoreOwnedBinding(matching), true);
    expect(keys.writes, 1);
    expect(driver.isConnected, false);
    platform.authenticate = true;
    expect(await driver.connect(), true);
    expect(driver.snNumber, matching.serialNumber);
    expect(driver.diagnosticText, isNot(contains(base64Encode(shared))));
    matching.clear();
    wrong.clear();
  });

  test('cancel while native connect is pending exits without GATT operations',
      () async {
    platform.holdConnect = true;
    final connected = driver.logStream.firstWhere((s) => s.contains('用户选择设备'));
    final result = driver.connectDevice(device);
    await connected;
    // Wait until the platform owns a pending connection; disconnect must bypass its operation queue.
    while (platform.connectCount == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await driver.disconnect().timeout(const Duration(seconds: 2));
    expect(await result.timeout(const Duration(seconds: 2)), false);
    expect(platform.writes, isEmpty);
    expect(driver.isConnected, false);
  });

  test('cancel before preference initialization cannot start a late connection',
      () async {
    final result = driver.connectDevice(device);
    await driver.disconnect();
    expect(await result, false);
    expect(platform.connectCount, 0);
  });
}

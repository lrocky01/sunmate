import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sunmate_app/core/ble/ble_constants.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'package:sunmate_app/core/ble/yoooclaw_account.dart';
import 'package:sunmate_app/core/ble/recorder_authentication.dart';
import 'package:sunmate_app/core/ble/recorder_saved_identity.dart';
import 'yoooclaw_account_test.dart' show record, scanIdentity, AccountHttpAdapter, response, MemoryOfficialSessionStore;
import 'recorder_authentication_test.dart' show MemoryKeyStore, shared;

/// 模拟 GATT 操作与设备异步事件，检查驱动不会把 ATT 成功误当业务成功。
base class TestBlePlatform extends FlutterBluePlusPlatform {
  final scans = StreamController<BmScanResponse>.broadcast();
  final connections = StreamController<BmConnectionStateResponse>.broadcast();
  final services = StreamController<BmDiscoverServicesResult>.broadcast();
  final descriptors = StreamController<BmDescriptorData>.broadcast();
  final received = StreamController<BmCharacteristicData>.broadcast();
  final written = StreamController<BmCharacteristicData>.broadcast();
  final mtus = StreamController<BmMtuChangedResponse>.broadcast();
  final writes = <BmWriteCharacteristicRequest>[];
  List<BmBluetoothDevice> systemDevices = [];
  BmSystemDevicesRequest? systemLookup;
  @override
  Future<BmDevicesList> getSystemDevices(BmSystemDevicesRequest request) async {
    systemLookup = request;
    return BmDevicesList(devices: systemDevices);
  }
  int connectCount = 0;
  bool otaOnly = false;
  bool rejectNotify = false;
  bool holdConnect = false;
  Completer<void>? connectGate;
  String replyMethod = 'bindResult';
  Object replySuccess = false;
  bool authenticate = false;
  bool firstBinding = false;
  bool identityOnSubscribe = false;
  bool manufacturerOnSubscribe = false;
  bool requiresBindRequest = false;
  bool rejectBindRequest = false;
  Uint8List? peerSecret;
  String? reportedSn;

  @override
  Stream<BmScanResponse> get onScanResponse => scans.stream;
  @override
  Future<bool> startScan(BmScanSettings request) async => true;
  @override
  Future<bool> stopScan(BmStopScanRequest request) async => true;

  Future<void> advertise(DeviceIdentifier id, Map<int, List<int>> data) async {
    await FlutterBluePlus.startScan();
    scans.add(BmScanResponse(advertisements: [
      BmScanAdvertisement(
          remoteId: id,
          platformName: 'C·ONE-test',
          advName: 'C·ONE-test',
          connectable: true,
          txPowerLevel: null,
          appearance: null,
          manufacturerData: data,
          serviceData: {},
          serviceUuids: [Guid('1812')],
          rssi: -45)
    ], success: true, errorCode: 0, errorString: ''));
    await FlutterBluePlus.scanResults
        .firstWhere((results) => results.any((r) => r.device.remoteId == id));
  }

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
    final gate = connectGate;
    if (gate != null) await gate.future;
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
    if (manufacturerOnSubscribe &&
        !rejectNotify &&
        request.characteristicUuid.str == BleConstants.charDeviceEvent) {
      event(request.remoteId, {
        'method': 'verifyRequest',
        'params': {
          'sn': 'AB00000000000001',
          'mac': 'test-only-mac',
          'encrypted': 'test-only-fresh-challenge'
        }
      });
    }
    if (identityOnSubscribe &&
        !rejectNotify &&
        request.characteristicUuid.str == BleConstants.charDeviceEvent) {
      event(request.remoteId, {
        'method': 'verifyIdentityRequest',
        'params': {
          if (reportedSn != null) 'sn': reportedSn,
          'random': base64Encode(List.generate(32, (i) => i)),
        }
      });
    }
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
    if (request.value.length == 6 &&
        request.value[0] == 0x11 &&
        request.value[1] == 0x29) {
      return true; // Official Telink RTC frame, independent of the JSON RPC channel.
    }
    final method = jsonDecode(utf8.decode(request.value.sublist(2)))['method'];
    if (firstBinding) return firstBindReply(request, method);
    if (method == 'getStatus' || (authenticate && method == 'verifyIdentity')) {
      final payload = utf8.encode(jsonEncode({
        'method': authenticate
            ? (method == 'getStatus'
                ? 'verifyIdentityRequest'
                : 'verifyIdentityResult')
            : replyMethod,
        'params': authenticate && method == 'getStatus'
            ? {
                if (reportedSn != null) 'sn': reportedSn,
                'random': base64Encode(List.generate(32, (i) => i))
              }
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

  Future<bool> firstBindReply(
      BmWriteCharacteristicRequest request, String method) async {
    if (method == 'bindRequest' && rejectBindRequest) {
      event(request.remoteId, {
        'method': 'bindError',
        'params': {'error': 'already_bound'}
      });
    } else if (connectCount == 1 &&
        (requiresBindRequest
            ? method == 'bindRequest'
            : method == 'getStatus')) {
      event(request.remoteId, {
        'method': 'verifyRequest',
        'params': {
          'sn': 'AB00000000000001',
          'mac': '11:22:33:44:55:66',
          'encrypted': 'test-only-fresh-challenge'
        }
      });
    } else if (method == 'verifyResult') {
      final params =
          jsonDecode(utf8.decode(request.value.sublist(2)))['params'];
      final key =
          await X25519().newKeyPairFromSeed(List.generate(32, (i) => i + 1));
      final public = await key.extractPublicKey();
      final secret = await X25519().sharedSecretKey(
          keyPair: key,
          remotePublicKey: SimplePublicKey(base64Decode(params['public_key']),
              type: KeyPairType.x25519));
      peerSecret = Uint8List.fromList(await secret.extractBytes());
      event(request.remoteId, {
        'method': 'pairingResult',
        'params': {
          'success': params['encrypted_random'] == 'test-only-issued-hmac',
          'public_key': base64Encode(public.bytes)
        }
      });
    } else if (method == 'getStatus' && connectCount > 1) {
      event(request.remoteId, {
        'method': 'verifyIdentityRequest',
        'params': {'random': base64Encode(List.generate(32, (i) => i))}
      });
    } else if (method == 'verifyIdentity') {
      final params =
          jsonDecode(utf8.decode(request.value.sublist(2)))['params'];
      final expected = await RecorderCryptography.answerIdentity(
          peerSecret!, base64Encode(List.generate(32, (i) => i)));
      event(request.remoteId, {
        'method': 'verifyIdentityResult',
        'params': {'success': params['encrypted'] == expected}
      });
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
    systemDevices = [];
    systemLookup = null;
    writes.clear();
    authenticate = false;
    firstBinding = false;
    identityOnSubscribe = false;
    manufacturerOnSubscribe = false;
    requiresBindRequest = false;
    rejectBindRequest = false;
    peerSecret = null;
    reportedSn = null;
    connectCount = 0;
    otaOnly = false;
    rejectNotify = false;
    holdConnect = false;
    connectGate = null;
    replyMethod = 'bindResult';
    replySuccess = false;
  }
}

RecorderAccountSession sessionWithBinding(OwnedRecorderBinding binding,
        {void Function()? onRestore}) =>
    RecorderAccountSession(
        binding.serialNumber,
        ({required checkContent, required mac, required sn}) async =>
            throw StateError('No new binding expected'),
        ({required sn, required mac, required sharedSecret}) async =>
            throw StateError('No new binding expected'),
        hasRecoverableKey: true, restoreKey: (id, protocol, sn, store) async {
      onRestore?.call();
      if (!binding.matches(sn, protocol)) return false;
      await binding.saveForDevice(store, id);
      return true;
    });

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
    driver =
        AiNote6095Driver(authenticationTimeout: const Duration(seconds: 2));
  });
  tearDown(() async {
    await driver.dispose();
    await FlutterBluePlus.stopScan();
  });

  for (final outcome in ['success', 'device rejection', 'cloud failure', 'old local key', 'different peripheral']) {
    test('empty-account first addition: $outcome', () async {
      await driver.dispose();
      final keys = MemoryKeyStore();
      if (outcome == 'old local key') keys.value = base64Encode(shared);
      driver = AiNote6095Driver(keyStore: keys,
          authenticationTimeout: const Duration(seconds: 2));
      final adapter = AccountHttpAdapter();
      final account = YoooClawAccount(http: Dio()..httpClientAdapter = adapter,
          sessionStore: MemoryOfficialSessionStore());
      addTearDown(account.close);
      adapter.respond = (request) {
        if (request.path.endsWith('/loginOrRegister')) {
          return response({'code': '000000', 'data': {'jwtToken': 'test-only-session', 'id': '123'}});
        }
        if (request.path.endsWith('/index')) {
          return response({'code': '000000', 'data': {'deviceList': []}});
        }
        if (request.path.endsWith('/check')) {
          return response({'code': '000000', 'data': {'hmac': 'test-only-issued-hmac'}});
        }
        return response({'code': outcome == 'cloud failure' ? '403' : '000000'});
      };
      await account.login('13800000000', '1234');
      await account.loadBindings();
      await platform.advertise(device.remoteId, {0x1c0d: [
        1, 255, 0x1d, 0x2c, ...ascii.encode('AB00000000000001')
      ]});
      final session = account.sessionForNewDevice(scanIdentity(
          remoteId: outcome == 'different peripheral' ? 'other-device' : device.remoteId.str));
      platform.firstBinding = true;
      platform.requiresBindRequest = true;
      platform.rejectBindRequest = outcome == 'device rejection';
      expect(await driver.connectDevice(device, accountSession: session), outcome == 'success');
      expect(driver.isConnected, outcome == 'success');
      final paths = adapter.requests.map((r) => r.uri.path).toList();
      expect(paths.any((p) => p.endsWith('/unbind')), false);
      if (outcome == 'success' || outcome == 'cloud failure') {
        expect(paths, containsAllInOrder([
          '/api/device/toc/externalDeviceBind/check',
          '/api/device/toc/externalDeviceBind/bind'
        ]));
        expect(keys.writes, 1);
        expect(base64Decode(keys.value!), platform.peerSecret);
        await Future<void>.delayed(Duration.zero);
        final saved = (await RecorderIdentityStore().readAll()).single;
        expect(saved.remoteId, device.remoteId.str);
        expect(saved.serialNumber, 'AB00000000000001');
        expect(saved.previouslyVerified, outcome == 'success');
      } else {
        expect(paths, hasLength(2));
        expect(keys.writes, 0);
      }
      if (outcome == 'success') {
        expect(platform.connectCount, 2);
        await driver.disconnect();
        final count = adapter.requests.length;
        expect(await driver.connectDevice(device), true);
        expect(adapter.requests.length, count);
        expect(keys.writes, 1);
      } else if (outcome == 'old local key') {
        expect(keys.value, base64Encode(shared));
        expect(platform.writes, isEmpty);
      } else if (outcome == 'different peripheral') {
        expect(platform.connectCount, 0);
        expect(platform.writes, isEmpty);
      } else if (outcome == 'device rejection') {
        expect(keys.value, isNull);
        expect(platform.connectCount, 1);
      }
      expect('${driver.diagnosticText}\n${account.diagnostics.join("\n")}',
          isNot(contains('test-only-issued-hmac')));
      if (keys.value != null) expect(driver.diagnosticText, isNot(contains(keys.value!)));
    });
  }

  test('selected advertisement survives scan cache clearing while system connects', () async {
    await driver.dispose();
    final keys = MemoryKeyStore();
    driver = AiNote6095Driver(keyStore: keys);
    platform.authenticate = true;
    platform.identityOnSubscribe = true;
    platform.connectGate = Completer<void>();
    await platform.advertise(device.remoteId, {0x1c0d: [
      1, 17, 0x1d, 0x2c, ...ascii.encode('AB00000000000001')
    ]});
    final binding = OwnedRecorderBinding.fromAccountRecord(record())!;
    addTearDown(binding.clear);
    final connected = driver.connectDevice(device, accountSession: sessionWithBinding(binding));
    while (platform.connectCount == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    // 模拟其它扫描会话替换缓存；不要等待被连接调用占用的平台串行队列。
    FlutterBluePlus.lastScanResults.clear();
    expect(FlutterBluePlus.lastScanResults, isEmpty);
    platform.connectGate!.complete();
    expect(await connected, true);
    expect(keys.writes, 1);
    expect(driver.snNumber, binding.serialNumber);
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
    platform.identityOnSubscribe = true;
    expect(await driver.connectDevice(device), true);
    final methods = platform.writes
        .where((w) => w.value.length > 2 && w.value[1] == 0x30)
        .map((w) => jsonDecode(utf8.decode(w.value.sublist(2)))['method']);
    expect(methods, contains('verifyIdentity'));
    expect(methods, isNot(contains('bindRequest')));
    expect(driver.isConnected, true);
    expect(driver.diagnosticText, isNot(contains(base64Encode(shared))));
    expect(driver.diagnosticText, isNot(contains('AWzzgd9AzLT+5DR')));
  });

  test(
      'login-first connection restores matching account identity and proves possession',
      () async {
    await driver.dispose();
    final keys = MemoryKeyStore();
    driver = AiNote6095Driver(keyStore: keys);
    platform.authenticate = true;
    platform.reportedSn = 'AB00000000000001';
    final binding = OwnedRecorderBinding.fromAccountRecord(record())!;
    addTearDown(binding.clear);
    final session = sessionWithBinding(binding);
    expect(await driver.connectDevice(device, accountSession: session), true);
    expect(keys.writes, 1);
    expect(platform.connectCount, 1);
    expect(driver.snNumber, binding.serialNumber);
    expect(driver.diagnosticText, isNot(contains(base64Encode(shared))));
  });

  for (final scenario in [
    'account mismatch',
    'event mismatch',
    'invalid broadcast',
    'different peripheral',
    'unknown GATT',
    'manufacturer challenge'
  ]) {
    test('account recovery rejects $scenario before using its key', () async {
      await driver.dispose();
      final keys = MemoryKeyStore();
      driver = AiNote6095Driver(
          keyStore: keys, authenticationTimeout: const Duration(seconds: 2));
      platform.authenticate = true;
      platform.identityOnSubscribe = true;
      if (scenario == 'manufacturer challenge') {
        platform.identityOnSubscribe = false;
        platform.manufacturerOnSubscribe = true;
      }
      if (scenario == 'event mismatch')
        platform.reportedSn = 'AB00000000000002';
      if (scenario == 'unknown GATT') platform.otaOnly = true;
      final binding = OwnedRecorderBinding.fromAccountRecord(record())!;
      addTearDown(binding.clear);
      final sn = scenario == 'account mismatch'
          ? 'AB00000000000002'
          : binding.serialNumber;
      await platform.advertise(
          scenario == 'different peripheral'
              ? const DeviceIdentifier('other-device')
              : device.remoteId,
          {
            0x1c0d: [
              1,
              0x11,
              0x1d,
              0x2c,
              ...ascii.encode(
                  scenario == 'invalid broadcast' ? 'AB0000000000000 ' : sn)
            ]
          });
      var restored = false;
      final session =
          sessionWithBinding(binding, onRestore: () => restored = true);
      expect(
          await driver.connectDevice(device, accountSession: session), false);
      expect(restored, false);
      expect(keys.writes, 0);
      expect(platform.writes, isEmpty);
      expect(driver.isConnected, false);
      if (scenario == 'manufacturer challenge') {
        expect(driver.lastErrorMessage, contains('未重新协商'));
      }
    });
  }

  test('recovered account key still needs a successful fresh AES reply',
      () async {
    await driver.dispose();
    final keys = MemoryKeyStore();
    driver = AiNote6095Driver(
        keyStore: keys, authenticationTimeout: const Duration(seconds: 2));
    platform.authenticate = true;
    platform.identityOnSubscribe = true;
    final wrong = record();
    (wrong['extInfo'] as Map)['sharedSecret'] =
        base64Encode(shared.reversed.toList());
    final binding = OwnedRecorderBinding.fromAccountRecord(wrong)!;
    addTearDown(binding.clear);
    await platform.advertise(device.remoteId, {
      0x1c0d: [1, 0x11],
      0x2c1d: ascii.encode(binding.serialNumber)
    });
    expect(
        await driver.connectDevice(device,
            accountSession: sessionWithBinding(binding)),
        false);
    expect(driver.isConnected, false);
    expect(driver.connectionDetails.identityVerified, false);
    expect(driver.diagnosticText,
        contains('method=verifyIdentityResult success=false'));
    expect(
        (await SharedPreferences.getInstance())
            .getString('sunmate_verified_ble_device_id_v2'),
        isNull);
    expect(
        platform.writes
            .where((w) => w.value.length > 2 && w.value[1] == 0x30)
            .map((w) => jsonDecode(utf8.decode(w.value.sublist(2)))['method']),
        isNot(contains('bindRequest')));
  });

  test('different reported SN cannot consume selected account key', () async {
    await driver.dispose();
    final keys = MemoryKeyStore();
    driver = AiNote6095Driver(keyStore: keys);
    platform.authenticate = true;
    platform.reportedSn = 'AB00000000000002';
    var restored = false;
    final session = RecorderAccountSession(
        'AB00000000000001',
        ({required checkContent, required mac, required sn}) async => '',
        ({required sn, required mac, required sharedSecret}) async {},
        restoreKey: (id, protocol, sn, store) async {
      restored = true;
      return true;
    });
    expect(await driver.connectDevice(device, accountSession: session), false);
    expect(restored, false);
    expect(keys.writes, 0);
    expect(driver.lastErrorMessage, contains('SN'));
  });

  test('broadcast SN restores account key when early identity omits SN',
      () async {
    await driver.dispose();
    final keys = MemoryKeyStore();
    driver = AiNote6095Driver(
        keyStore: keys, authenticationTimeout: const Duration(seconds: 2));
    platform.authenticate = true;
    platform.identityOnSubscribe = true;
    final binding = OwnedRecorderBinding.fromAccountRecord(record())!;
    addTearDown(binding.clear);
    await platform.advertise(device.remoteId, {
      0x1c0d: [0x01, 0x11, 0x1d, 0x2c, ...ascii.encode(binding.serialNumber)]
    });
    final session = sessionWithBinding(binding);
    expect(await driver.connectDevice(device, accountSession: session), true);
    expect(driver.snNumber, binding.serialNumber);
    expect(driver.diagnosticText, contains('本次设备广播'));
    expect(keys.writes, 1);
    final methods = platform.writes
        .where((w) => w.value.length > 2 && w.value[1] == 0x30)
        .map((w) => jsonDecode(utf8.decode(w.value.sublist(2)))['method']);
    expect(methods, contains('verifyIdentity'));
    expect(methods, isNot(contains('bindRequest')));
    expect(driver.diagnosticText, isNot(contains(base64Encode(shared))));
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

  test(
      'own-account restore requires observed SN/profile and verifies on reconnect',
      () async {
    await driver.dispose();
    final keys = MemoryKeyStore();
    driver = AiNote6095Driver(keyStore: keys);
    final matching = OwnedRecorderBinding.fromAccountRecord(record())!;
    expect(await driver.restoreOwnedBinding(matching), false);
    expect(keys.writes, 0);
    platform.replyMethod = 'verifyRequest';
    platform.reportedSn = matching.serialNumber;
    expect(await driver.connectDevice(device), false);
    final wrong =
        OwnedRecorderBinding.fromAccountRecord(record(sn: 'AB00000000000002'))!;
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

  test(
      'early identity challenge without local or cloud key must still send one legitimate bind request',
      () async {
    await driver.dispose();
    final keys = MemoryKeyStore();
    driver = AiNote6095Driver(keyStore: keys);
    platform.firstBinding = true;
    platform.identityOnSubscribe = true;
    platform.requiresBindRequest = true;
    var checks = 0, commits = 0;
    final session = RecorderAccountSession('AB00000000000001', (
        {required checkContent, required mac, required sn}) async {
      checks++;
      return 'test-only-issued-hmac';
    }, ({required sn, required mac, required sharedSecret}) async {
      commits++;
    }, restoreKey: (id, protocol, sn, store) async => false);
    expect(await driver.connectDevice(device, accountSession: session), true);
    final methods = platform.writes
        .where((w) => w.value.length > 2 && w.value[1] == 0x30)
        .map((w) => jsonDecode(utf8.decode(w.value.sublist(2)))['method'])
        .toList();
    expect(methods.where((m) => m == 'bindRequest'), hasLength(1));
    expect(methods,
        containsAllInOrder(['bindRequest', 'verifyResult', 'verifyIdentity']));
    expect(methods, isNot(contains('unbindRequest')));
    expect(platform.connectCount, 2);
    expect(checks, 1);
    expect(commits, 1);
    expect(keys.writes, 1);
    expect(driver.diagnosticText, isNot(contains(keys.value!)));
  });

  test('delayed account restore during CCCD does not race into a new binding',
      () async {
    await driver.dispose();
    final keys = MemoryKeyStore();
    driver = AiNote6095Driver(keyStore: keys);
    platform.authenticate = true;
    platform.identityOnSubscribe = true;
    platform.reportedSn = 'AB00000000000001';
    final entered = Completer<void>(), pending = Completer<void>();
    final audioReady =
        driver.logStream.firstWhere((s) => s.contains('音频 CCCD 已确认'));
    final session = RecorderAccountSession(
        'AB00000000000001',
        ({required checkContent, required mac, required sn}) async =>
            throw StateError('No manufacturer request expected'),
        ({required sn, required mac, required sharedSecret}) async =>
            throw StateError('No new binding expected'),
        restoreKey: (id, protocol, sn, store) async {
      entered.complete();
      await pending.future;
      await store.write(id, protocol, base64Encode(shared));
      return true;
    });
    final result = driver.connectDevice(device, accountSession: session);
    await entered.future;
    await audioReady;
    expect(platform.writes, isEmpty);
    pending.complete();
    expect(await result, true);
    expect(platform.connectCount, 1);
    expect(keys.writes, 1);
    expect(
        platform.writes
            .where((w) => w.value.length > 2 && w.value[1] == 0x30)
            .map((w) => jsonDecode(utf8.decode(w.value.sublist(2)))['method']),
        isNot(contains('bindRequest')));
  });

  test(
      'cancel exits pending account restoration without sending a binding request',
      () async {
    await driver.dispose();
    driver = AiNote6095Driver(keyStore: MemoryKeyStore());
    platform.authenticate = true;
    platform.identityOnSubscribe = true;
    platform.reportedSn = 'AB00000000000001';
    final entered = Completer<void>(), pending = Completer<void>();
    final session = RecorderAccountSession(
        'AB00000000000001',
        ({required checkContent, required mac, required sn}) async => '',
        ({required sn, required mac, required sharedSecret}) async {},
        restoreKey: (id, protocol, sn, store) async {
      entered.complete();
      await pending.future;
      return false;
    });
    final result = driver.connectDevice(device, accountSession: session);
    await entered.future;
    await driver.disconnect();
    expect(await result.timeout(const Duration(seconds: 1)), false);
    pending.complete();
    await Future<void>.delayed(Duration.zero);
    expect(platform.writes, isEmpty);
    expect(platform.connectCount, 1);
  });

  test(
      'device rejection of the normal bind request stops without retry or key changes',
      () async {
    await driver.dispose();
    final keys = MemoryKeyStore();
    driver = AiNote6095Driver(keyStore: keys);
    platform.firstBinding = true;
    platform.identityOnSubscribe = true;
    platform.requiresBindRequest = true;
    platform.rejectBindRequest = true;
    final session = RecorderAccountSession(
        'AB00000000000001',
        ({required checkContent, required mac, required sn}) async =>
            throw StateError('No challenge was issued'),
        ({required sn, required mac, required sharedSecret}) async =>
            throw StateError('No pairing happened'));
    expect(await driver.connectDevice(device, accountSession: session), false);
    final methods = platform.writes
        .where((w) => w.value.length > 2 && w.value[1] == 0x30)
        .map((w) => jsonDecode(utf8.decode(w.value.sublist(2)))['method'])
        .toList();
    expect(methods.where((m) => m == 'bindRequest'), hasLength(1));
    expect(methods, isNot(contains('verifyIdentity')));
    expect(methods, isNot(contains('verifyResult')));
    expect(methods, isNot(contains('unbindRequest')));
    expect(keys.writes, 0);
    expect(platform.connectCount, 1);
    expect(driver.lastErrorMessage, contains('bindError'));
    expect(driver.diagnosticText, contains('error=already_bound'));
    expect(driver.diagnosticText, contains('最近错误: 设备报告 bindError 失败'));
  });

  for (final target in [TargetPlatform.iOS, TargetPlatform.android]) {
    test(
      'logged-in first binding commits a fresh key then verifies a real peer challenge on reconnect on $target',
      () async {
        debugDefaultTargetPlatformOverride = target;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await driver.dispose();
        final keys = MemoryKeyStore();
        driver = AiNote6095Driver(keyStore: keys);
        platform.firstBinding = true;
        var checks = 0, commits = 0;
        final session = RecorderAccountSession(
          'AB00000000000001',
          ({required checkContent, required mac, required sn}) async {
            expect(checkContent, 'test-only-fresh-challenge');
            expect(sn, 'AB00000000000001');
            checks++;
            return 'test-only-issued-hmac';
          },
          ({required sn, required mac, required sharedSecret}) async {
            expect(base64Decode(sharedSecret), platform.peerSecret);
            expect(keys.value, sharedSecret);
            commits++;
          },
        );
        expect(
          await driver.connectDevice(device, accountSession: session),
          true,
        );
        expect(platform.connectCount, 2);
        expect(checks, 1);
        expect(commits, 1);
        expect(keys.writes, 1);
        expect(driver.isConnected, true);
        final reply = platform.writes
            .where((w) => w.value.length > 2 && w.value[1] == 0x30)
            .map((w) => jsonDecode(utf8.decode(w.value.sublist(2))) as Map)
            .singleWhere((message) => message['method'] == 'verifyResult');
        final params = reply['params'] as Map;
        if (target == TargetPlatform.iOS) {
          expect(params['isIos'], isA<int>());
          expect(params['isIos'], 1);
        } else {
          expect(params.containsKey('isIos'), false);
        }
        expect(driver.diagnosticText, isNot(contains('test-only-issued-hmac')));
        expect(driver.diagnosticText, isNot(contains(keys.value!)));
      },
    );
  }

  test(
      'cancel during account binding cannot launch an automatic reconnect later',
      () async {
    await driver.dispose();
    driver = AiNote6095Driver(keyStore: MemoryKeyStore());
    platform.firstBinding = true;
    final entered = Completer<void>(), pending = Completer<void>();
    final session = RecorderAccountSession(
        'AB00000000000001',
        ({required checkContent, required mac, required sn}) async =>
            'test-only-issued-hmac',
        ({required sn, required mac, required sharedSecret}) async {
      entered.complete();
      await pending.future;
    });
    final result = driver.connectDevice(device, accountSession: session);
    await entered.future;
    await driver.disconnect();
    expect(await result, false);
    pending.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(platform.connectCount, 1);
    expect(driver.isConnected, false);
  });

  test('outer deadline covers a platform connect call that never returns',
      () async {
    await driver.dispose();
    driver = AiNote6095Driver(
        connectionTimeout: const Duration(milliseconds: 80),
        cancellationTimeout: const Duration(milliseconds: 20));
    final gate = Completer<void>();
    platform.connectGate = gate;
    try {
      expect(
          await driver
              .connectDevice(device)
              .timeout(const Duration(seconds: 1)),
          false);
      expect(driver.isConnecting, false);
      expect(driver.isConnected, false);
      expect(driver.lastErrorMessage, contains('系统连接'));
      expect(platform.writes, isEmpty);
    } finally {
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    // The late connected callback must never advance this expired attempt to GATT.
    expect(platform.writes, isEmpty);
    expect(driver.isConnected, false);
  });

  test(
      'cancel interrupts the app wait even if the native invocation is stalled',
      () async {
    await driver.dispose();
    driver =
        AiNote6095Driver(cancellationTimeout: const Duration(milliseconds: 20));
    final gate = Completer<void>();
    platform.connectGate = gate;
    final connecting = driver.connectDevice(device);
    while (platform.connectCount == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    try {
      await driver.disconnect().timeout(const Duration(seconds: 1));
      expect(await connecting.timeout(const Duration(seconds: 1)), false);
      expect(driver.isConnecting, false);
      expect(driver.connectionSummary, '已取消本次操作，等待系统断开');
      expect(platform.writes, isEmpty);
    } finally {
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    expect(driver.isConnected, false);
    expect(platform.writes, isEmpty);
  });
}

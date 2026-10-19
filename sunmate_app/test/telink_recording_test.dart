import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/ble_constants.dart';
import 'package:sunmate_app/core/ble/ble_protocol.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_authentication_test.dart' show MemoryKeyStore, shared;

List<int> start(int session, {int kind = 0}) => (ByteData(12)
      ..setUint8(0, 0xaa)
      ..setUint8(1, 0x55)
      ..setUint8(2, 1)
      ..setUint8(3, kind)
      ..setInt64(4, session, Endian.big))
    .buffer
    .asUint8List();
const frame = [3, 0, 0, 0, 0, 0, 0, 0, 0xf8, 0xff, 0xfe];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = TestBlePlatform();
  late AiNote6095Driver driver;
  late MemoryKeyStore keys;
  late BluetoothDevice device;
  var number = 0;
  setUpAll(() => FlutterBluePlusPlatform.instance = platform);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    platform.reset();
    keys = MemoryKeyStore()..value = base64Encode(shared);
    device = BluetoothDevice.fromId(
        '20000000-0000-0000-0000-${(++number).toString().padLeft(12, '0')}');
    driver = AiNote6095Driver(
        keyStore: keys,
        authenticationTimeout: const Duration(milliseconds: 150));
  });
  tearDown(() async {
    await driver.dispose();
  });
  Future<void> connect() async {
    platform.authenticate = true;
    expect(await driver.connectDevice(device), true);
  }

  void event(List<int> bytes) =>
      platform.notify(device.remoteId, BleConstants.charDeviceEvent, bytes);
  void audio([List<int> bytes = frame]) =>
      platform.notify(device.remoteId, BleConstants.charOpusAudioData, bytes);
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('binary layout preserves full big-endian session and distinct type', () {
    final decoded = TelinkRecordingEvent.decode(start(0x0102030405060708))!;
    expect(decoded.sessionId, 0x0102030405060708);
    expect(decoded.kind, TelinkRecordingKind.realtime);
    expect(TelinkRecordingEvent.decode(start(1, kind: 1))!.kind,
        TelinkRecordingKind.long);
    expect(TelinkRecordingEvent.decode([0xaa, 0x55, 2])!.kind, isNull);
    expect(TelinkRecordingEvent.decode([0xaa, 0x55, 0x30, 0, 0]), isNull);
    for (final bytes in [
      start(0),
      start(-1),
      start(1, kind: 2),
      start(1).take(11).toList(),
      [...start(1), 0],
      [0xaa, 0x55, 2, 3],
      [0xaa, 0x55, 2, 0, 0],
      [0xaa, 0x55, 2, -1]
    ]) {
      expect(() => TelinkRecordingEvent.decode(bytes), throwsFormatException);
    }
  });

  test(
      'same-turn start audio stop emits complete Ogg before release without ACK',
      () async {
    await connect();
    await settle(); // 既有异步RTC同步结束后才统计额外写入。
    final writes = platform.writes.length;
    final order = <String>[];
    final collected = <int>[];
    final b = driver.buttonEvents.listen((e) => order.add(e.action.name));
    final a = driver.audioStream.listen((p) {
      order.add('audio');
      collected.addAll(p.bytes);
    });
    addTearDown(b.cancel);
    addTearDown(a.cancel);
    event(start(77));
    audio();
    event([0xaa, 0x55, 2, 0]);
    await settle();
    expect(order.first, 'pressDown');
    expect(order.last, 'release');
    expect(driver.isRecording, false);
    expect(collected, driver.lastRecordedBytes);
    expect(String.fromCharCodes(collected.take(4)), 'OggS');
    expect(driver.diagnosticText, contains('通知=1；接收字节=11；会话外忽略=0；最近完整录音帧=1'));
    expect(platform.writes.length, writes);
    expect(keys.writes, 0);
  });

  test('duplicate start and stop do not reset audio or emit a second release',
      () async {
    await connect();
    final events = <String>[];
    final b = driver.buttonEvents.listen((e) => events.add(e.action.name));
    addTearDown(b.cancel);
    event(start(77));
    audio();
    event(start(77));
    audio();
    event([0xaa, 0x55, 2]);
    event([0xaa, 0x55, 2]);
    await settle();
    expect(events, ['pressDown', 'release']);
    expect(driver.diagnosticText, contains('最近完整录音帧=2'));
  });

  test(
      'wrong-type stop and malformed events cannot end an active realtime session',
      () async {
    await connect();
    event([0xaa, 0x55, 2, 0]);
    event(start(77));
    audio();
    event([0xaa, 0x55, 2, 1]);
    event(start(77, kind: 1));
    event(start(0));
    event([0xaa, 0x55, 2, 2]);
    await settle();
    expect(driver.isRecording, true);
    expect(driver.isConnected, true);
    event([0xaa, 0x55, 2, 0]);
    await settle();
    expect(driver.lastRecordedBytes, isNotNull);
  });

  test('long recording is isolated and cannot submit realtime audio', () async {
    await connect();
    final buttons = <String>[];
    final b = driver.buttonEvents.listen((e) => buttons.add(e.action.name));
    addTearDown(b.cancel);
    event(start(1, kind: 1));
    audio();
    event([0xaa, 0x55, 2, 1]);
    await settle();
    expect(buttons, isEmpty);
    expect(driver.lastRecordedBytes, isNull);
    expect(driver.diagnosticText, contains('会话外忽略=1'));
    event(start(2));
    audio();
    event([0xaa, 0x55, 2, 0]);
    await settle();
    expect(buttons, ['pressDown', 'release']);
  });

  test(
      'binary control can interleave fragmented JSON without corrupting either',
      () async {
    await connect();
    event(
        [0xaa, 0x55, 0x30, 0, 0, ...utf8.encode('{"method":"reportStatus",')]);
    event(start(77));
    audio();
    event([0xaa, 0x55, 2, 0]);
    event(utf8.encode('"params":{"battery":65}}'));
    await settle();
    expect(driver.lastRecordedBytes, isNotNull);
    expect(driver.batteryLevel, 65);
    expect(driver.isConnected, true);
  });

  test('JSON voice start release and abort retain their session matching',
      () async {
    await connect();
    void jsonEvent(String name, int id) => platform.event(device.remoteId, {
          'method': 'voiceCmd',
          'params': {'event': name, 'session_id': id}
        });
    jsonEvent('start', 77);
    audio();
    jsonEvent('release', 78);
    await settle();
    expect(driver.isRecording, true);
    jsonEvent('release', 77);
    await settle();
    expect(driver.lastRecordedBytes, isNotNull);
    event(start(88));
    audio();
    jsonEvent('abort', 88);
    event([0xaa, 0x55, 2, 0]);
    await settle();
    expect(driver.lastRecordedBytes, isNull);
    expect(driver.isRecording, false);
  });

  for (final partial in [false, true]) {
    test(
        'empty or truncated recording cancels without release: partial=$partial',
        () async {
      await connect();
      final events = <String>[];
      final b = driver.buttonEvents.listen((e) => events.add(e.action.name));
      addTearDown(b.cancel);
      event(start(77));
      if (partial) audio(frame.take(9).toList());
      event([0xaa, 0x55, 2, 0]);
      await settle();
      expect(events, ['pressDown', 'cancel']);
      expect(driver.lastRecordedBytes, isNull);
    });
  }

  test(
      'unauthenticated binary events and audio cannot grant readiness or recording',
      () async {
    final connecting = driver.connectDevice(device);
    while (!driver.connectionLogs.any((s) => s.contains('音频 CCCD 已确认'))) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    event(start(77));
    audio();
    event([0xaa, 0x55, 2, 0]);
    expect(await connecting, false);
    expect(driver.isConnected, false);
    expect(driver.isRecording, false);
    expect(driver.lastRecordedBytes, isNull);
    expect(keys.writes, 0);
  });

  test('disconnect discards unfinished audio and reconnect requires AES again',
      () async {
    await connect();
    event(start(77));
    audio();
    await settle();
    await driver.disconnect();
    event([0xaa, 0x55, 2, 0]);
    audio();
    await settle();
    expect(driver.isRecording, false);
    expect(driver.lastRecordedBytes, isNull);
    expect(await driver.connectDevice(device), true);
    event([0xaa, 0x55, 2, 0]);
    event(start(88));
    audio();
    event([0xaa, 0x55, 2, 0]);
    await settle();
    expect(driver.lastRecordedBytes, isNotNull);
    expect(driver.diagnosticText, contains('通知=1；接收字节=11'));
    expect(keys.writes, 0);
  });
}

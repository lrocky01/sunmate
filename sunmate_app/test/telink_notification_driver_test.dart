import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/ble_constants.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'package:sunmate_app/core/notifications/mobile_notification_manager.dart';
import 'package:sunmate_app/models/timeline_entry.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_authentication_test.dart' show MemoryKeyStore, shared;
import 'telink_notification_test.dart' show notificationFrame;
import 'telink_recording_test.dart' show start, frame;

class RejectingNotificationManager extends MobileNotificationManager {
  RejectingNotificationManager() : super.isolated();
  @override
  void onIosAncsNotificationPosted(
          {required String appIdentifier,
          required String title,
          required String message,
          String subtitle = '',
          DateTime? timestamp,
          String? notificationIdentity}) =>
      throw StateError('test-private-content');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = TestBlePlatform();
  late AiNote6095Driver driver;
  late MobileNotificationManager manager;
  late MemoryKeyStore keys;
  late BluetoothDevice device;
  late List<TimelineEntry> notifications;
  var number = 0;
  setUpAll(() => FlutterBluePlusPlatform.instance = platform);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    platform.reset();
    keys = MemoryKeyStore()..value = base64Encode(shared);
    manager = MobileNotificationManager.isolated();
    notifications = [];
    final subscription = manager.notificationStream.listen(notifications.add);
    addTearDown(subscription.cancel);
    device = BluetoothDevice.fromId(
        '49000000-0000-0000-0000-${(++number).toString().padLeft(12, '0')}');
    driver = AiNote6095Driver(
        keyStore: keys,
        notificationManager: manager,
        authenticationTimeout: const Duration(milliseconds: 150));
  });
  tearDown(() async {
    await driver.dispose();
    manager.dispose();
  });
  Future<void> connect() async {
    platform.authenticate = true;
    expect(await driver.connectDevice(device), true);
  }

  void event(List<int> bytes) =>
      platform.notify(device.remoteId, BleConstants.charDeviceEvent, bytes);
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 25));

  test(
      'real test AES challenge then notification manager, no extra writes or key changes',
      () async {
    await connect();
    await settle();
    final writes = platform.writes.length;
    event(notificationFrame());
    await settle();
    expect(notifications, hasLength(1));
    final entry = notifications.single;
    expect(entry.sourceType, TimelineSourceType.appNotification);
    expect(entry.sourceApp, '微信');
    expect(entry.content, '[测试标题]: 副标题\nSM-LOCAL 通知测试甲123');
    expect(entry.timestamp, DateTime(2026, 10, 19, 22, 22, 59));
    expect(driver.isConnected, true);
    expect(keys.writes, 0);
    expect(platform.writes.length, writes);
    expect(driver.diagnosticText, contains('通知回传: 已接收=1'));
    for (final value in ['测试标题', 'SM-LOCAL', 'com.tencent.xin', '305419896']) {
      expect(driver.diagnosticText, isNot(contains(value)));
    }
  });

  test('complete notifications and fragmented JSON remain separate', () async {
    await connect();
    event(
        [0xaa, 0x55, 0x30, 0, 0, ...utf8.encode('{"method":"reportStatus",')]);
    event(notificationFrame());
    event(utf8.encode('"params":{"battery":73}}'));
    await settle();
    expect(driver.batteryLevel, 73);
    expect(notifications, hasLength(1));
    expect(driver.isConnected, true);
  });

  test('fragmented long notification, duplicate and same UID with changed body',
      () async {
    await connect();
    final bytes = notificationFrame(message: '合成测试长通知' * 100);
    for (var offset = 0; offset < bytes.length; offset += 80) {
      event(bytes.sublist(offset, (offset + 80).clamp(0, bytes.length)));
    }
    event(bytes);
    event(notificationFrame(message: '相同UID的新正文'));
    event(notificationFrame(uid: 0x12345679, message: '同秒第二条通知'));
    await settle();
    expect(notifications, hasLength(3));
    expect(notifications.first.content, contains('合成测试长通知' * 100));
    expect(notifications.map((e) => e.id).toSet(), hasLength(2));
    expect(notifications[0].id, notifications[1].id); // 同UID更新同一持久记录。
    expect(notifications[1].content, contains('相同UID的新正文'));
    expect(driver.isConnected, true);
  });

  test('invalid date uses reception time and empty content does not dispatch',
      () async {
    await connect();
    final before = DateTime.now();
    event(notificationFrame(date: '20260230T120000'));
    event(notificationFrame(uid: 2, title: '', subtitle: '', message: ''));
    await settle();
    expect(notifications, hasLength(1));
    expect(notifications.single.timestamp.isBefore(before), false);
    expect(notifications.single.timestamp.isAfter(DateTime.now()), false);
  });

  test('bad UID/length/UTF8 and unknown events never change readiness',
      () async {
    await connect();
    event(notificationFrame()..[14] ^= 1);
    event([...notificationFrame(), 0]);
    event(notificationFrame()..[21] = 255);
    for (final id in [1, 2, 3]) {
      event(notificationFrame(event: id));
    }
    await settle();
    expect(notifications, isEmpty);
    expect(driver.isConnected, true);
    event(notificationFrame());
    await settle();
    expect(notifications, hasLength(1));
    expect(driver.diagnosticText, contains('无效=3'));
  });

  test('incomplete notification cannot swallow new binary recording or JSON',
      () async {
    await connect();
    final bytes = notificationFrame();
    event(bytes.sublist(0, 20));
    event(start(77));
    platform.notify(device.remoteId, BleConstants.charOpusAudioData, frame);
    event([0xaa, 0x55, 2, 0]);
    platform.event(device.remoteId, {
      'method': 'reportStatus',
      'params': {'battery': 61}
    });
    event(notificationFrame());
    await settle();
    expect(driver.lastRecordedBytes, isNotNull);
    expect(driver.batteryLevel, 61);
    expect(notifications, hasLength(1));
    expect(driver.isConnected, true);
  });

  test('unauthenticated frame cannot bypass or be replayed after real AES',
      () async {
    platform.replyMethod = 'reportCapabilities';
    final connecting = driver.connectDevice(device);
    while (!driver.connectionLogs.any((s) => s.contains('音频 CCCD 已确认'))) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    event(notificationFrame());
    final partial = notificationFrame(uid: 22);
    event(partial.sublist(0, 20));
    await settle();
    platform.authenticate = true;
    platform.event(device.remoteId, {
      'method': 'verifyIdentityRequest',
      'params': {'random': base64Encode(List.generate(32, (i) => i))}
    });
    expect(await connecting, true);
    event(partial.sublist(20));
    await settle();
    expect(notifications, isEmpty);
    event(notificationFrame());
    await settle();
    expect(notifications, hasLength(1));
    expect(keys.writes, 0);
  });

  test(
      'false identity result revokes notification dispatch immediately in queue order',
      () async {
    await connect();
    platform.event(device.remoteId, {
      'method': 'verifyIdentityResult',
      'params': {'success': false}
    });
    event(notificationFrame());
    await settle();
    expect(notifications, isEmpty);
    expect(driver.isConnected, false);
    expect(keys.writes, 0);
  });

  test(
      'disconnect clears fragments and duplicate cache, reconnect requires AES',
      () async {
    await connect();
    final bytes = notificationFrame();
    event(bytes);
    await settle();
    event(bytes.sublist(0, 20));
    await settle();
    await driver.disconnect();
    event(bytes.sublist(20));
    event(notificationFrame(uid: 23));
    await settle();
    expect(notifications, hasLength(1));
    await connect();
    event(bytes.sublist(20));
    event(bytes);
    await settle();
    expect(notifications, hasLength(2));
  });

  test('dedup cache is bounded to 256 UIDs', () async {
    await connect();
    for (var i = 0; i < 257; i++) {
      event(notificationFrame(uid: i));
    }
    // 等所有异步散列和流分发完成，不假设机器吞吐速度。
    for (var i = 0; i < 100 && notifications.length < 257; i++) {
      await settle();
    }
    expect(notifications, hasLength(257));
    event(notificationFrame(uid: 256)); // cache hit
    event(notificationFrame(uid: 0)); // oldest was evicted
    await settle();
    expect(notifications, hasLength(258));
  });

  test(
      'manager failure is isolated from AES state and logs omit exception contents',
      () async {
    await driver.dispose();
    final rejecting = RejectingNotificationManager();
    addTearDown(rejecting.dispose);
    driver = AiNote6095Driver(keyStore: keys, notificationManager: rejecting);
    await connect();
    event(notificationFrame());
    await settle();
    expect(driver.isConnected, true);
    expect(driver.diagnosticText, contains('无效=1'));
    expect(driver.diagnosticText, isNot(contains('test-private-content')));
  });
}

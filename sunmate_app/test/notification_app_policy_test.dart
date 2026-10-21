import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/notifications/mobile_notification_manager.dart';
import 'package:sunmate_app/core/notifications/notification_app_policy.dart';
import 'package:sunmate_app/models/timeline_entry.dart';

class PolicyMemoryStore implements NotificationPolicyStore {
  String? value;
  bool fail = false;
  Completer<void>? gate;
  int writes = 0;
  @override
  Future<String?> read() async {
    if (gate != null) await gate!.future;
    return value;
  }

  @override
  Future<void> write(String next) async {
    writes++;
    if (fail) throw StateError('private-synthetic-error');
    value = next;
  }
}

void main() {
  test('observed registry stores identifiers/counts only and restores switches',
      () async {
    final store = PolicyMemoryStore();
    final policy = NotificationAppPolicy(store: store);
    await policy.ready;
    policy.observe('com.tencent.xin', '微信', DateTime(2026, 10, 20));
    expect(policy.allows('com.tencent.xin'), true);
    expect(await policy.setAppEnabled('com.tencent.xin', false), true);
    await policy.flush();
    policy.dispose();
    final restored = NotificationAppPolicy(store: store);
    await restored.ready;
    expect(restored.apps.single.count, 1);
    expect(restored.apps.single.name, '微信');
    expect(restored.allows('com.tencent.xin'), false);
    expect((jsonDecode(store.value!)['apps'] as List).single.keys,
        unorderedEquals(['id', 'name', 'count', 'lastSeen', 'enabled']));
    restored.dispose();
  });
  test(
      'app and global switches filter delivery but still register real app ids',
      () async {
    final store = PolicyMemoryStore();
    final policy = NotificationAppPolicy(store: store);
    final manager = MobileNotificationManager.isolated(policy: policy);
    final entries = <TimelineEntry>[];
    final sub = manager.notificationStream.listen(entries.add);
    await manager.initialize();
    void post(String id) => manager.onIosAncsNotificationPosted(
        appIdentifier: id,
        title: 'Synthetic title',
        message: 'Synthetic private body');
    post('com.tencent.xin');
    await Future<void>.delayed(Duration.zero);
    expect(entries.length, 1);
    await policy.setAppEnabled('com.tencent.xin', false);
    post('com.tencent.xin');
    post('com.apple.MobileSMS');
    await Future<void>.delayed(Duration.zero);
    expect(entries.length, 2);
    expect(policy.apps.length, 2);
    await policy.setEnabled(false);
    post('com.new.app');
    await Future<void>.delayed(Duration.zero);
    expect(entries.length, 2);
    expect(policy.apps.length, 3);
    await policy.flush();
    expect(store.value, isNot(contains('Synthetic')));
    await sub.cancel();
    manager.dispose();
  });
  test('notifications wait for restored disabled policy before any delivery',
      () async {
    final store = PolicyMemoryStore()
      ..value = '{"version":1,"enabled":false,"apps":[]}'
      ..gate = Completer<void>();
    final policy = NotificationAppPolicy(store: store);
    final manager = MobileNotificationManager.isolated(policy: policy);
    final entries = <TimelineEntry>[];
    final sub = manager.notificationStream.listen(entries.add);
    manager.onIosAncsNotificationPosted(
        appIdentifier: 'com.test', title: '', message: 'synthetic');
    expect(entries, isEmpty);
    store.gate!.complete();
    await policy.ready;
    await Future<void>.delayed(Duration.zero);
    expect(entries, isEmpty);
    expect(policy.apps.single.id, 'com.test');
    await policy.flush();
    await sub.cancel();
    manager.dispose();
  });
  test('damaged preferences fail closed and are not overwritten', () async {
    final store = PolicyMemoryStore()..value = 'bad-data';
    final policy = NotificationAppPolicy(store: store);
    await policy.ready;
    policy.observe('com.test', 'test', DateTime.now());
    expect(policy.allows('com.test'), false);
    expect(await policy.setEnabled(true), false);
    expect(store.writes, 0);
    expect(store.value, 'bad-data');
    policy.dispose();
  });
  test('failed switch persistence retains last confirmed choice', () async {
    final store = PolicyMemoryStore();
    final policy = NotificationAppPolicy(store: store);
    await policy.ready;
    policy.observe('com.test', 'test', DateTime.now());
    await policy.flush();
    store.fail = true;
    expect(await policy.setAppEnabled('com.test', false), false);
    expect(policy.allows('com.test'), true);
    expect(policy.message, isNot(contains('private-synthetic')));
    policy.dispose();
  });
  test('invalid identifiers and unknown app switches are rejected', () async {
    final policy = NotificationAppPolicy(store: PolicyMemoryStore());
    await policy.ready;
    policy.observe('../bad', 'bad', DateTime.now());
    expect(policy.apps, isEmpty);
    expect(await policy.setAppEnabled('com.unknown', false), false);
    policy.dispose();
  });
  test('queued global/app switches merge without reverting either choice',
      () async {
    final policy = NotificationAppPolicy(store: PolicyMemoryStore());
    await policy.ready;
    policy.observe('com.test', 'test', DateTime.now());
    final a = policy.setEnabled(false),
        b = policy.setAppEnabled('com.test', false);
    expect(await a, true);
    expect(await b, true);
    await policy.setEnabled(true);
    expect(policy.allows('com.test'), false);
    policy.dispose();
  });
}

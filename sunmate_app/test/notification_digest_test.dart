import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ai/agent_client.dart';
import 'package:sunmate_app/core/recordings/local_content_store.dart';
import 'package:sunmate_app/core/recordings/notification_digest_models.dart';
import 'package:sunmate_app/core/recordings/recording_processing_controller.dart';
import 'package:sunmate_app/models/timeline_entry.dart';
import 'recording_processing_test.dart' show ProcessingFixture, MemoryContent;

class DigestAgent extends AgentClient {
  int calls = 0, active = 0, maxActive = 0;
  bool fail = false, empty = false;
  Completer<void>? gate;
  final payloads = <List<Map<String, String>>>[];
  @override
  Future<String> generateNotificationDigest(
      {required List<Map<String, String>> notifications,
      int? filteredSpamCount}) async {
    calls++;
    active++;
    if (active > maxActive) maxActive = active;
    payloads.add(notifications);
    try {
      if (gate != null) await gate!.future;
      if (fail) throw const AgentResponseException('synthetic failure');
      return empty ? '   ' : '合成通知简报';
    } finally {
      active--;
    }
  }
}

class DigestMemory extends MemoryContent {
  bool rejectSummary = false, dropSummary = false;
  @override
  Future<void> put(
      String collection, String id, Map<String, dynamic> record) async {
    if (collection == 'summaries' && record['kind'] == 'notification') {
      if (rejectSummary) throw const FileSystemException('synthetic');
      if (dropSummary) return;
    }
    return super.put(collection, id, record);
  }
}

class DigestWorld {
  final audioFixture = ProcessingFixture(),
      agent = DigestAgent(),
      memory = DigestMemory();
  late RecordingProcessingController c;
  DateTime now = DateTime(2026, 10, 21, 12);
  final allowed = {'com.example.test'};
  Future<void> open() async {
    await audioFixture.open();
    await reopen();
  }

  Future<void> reopen({RecordingContentStore? store}) async {
    c = RecordingProcessingController(
        content: store ?? memory,
        audioStore: audioFixture.store,
        audio: audioFixture.audio,
        asr: () => audioFixture.asr,
        agent: () => agent,
        allowsNotification: allowed.contains,
        notificationClock: () => now);
    await c.ready;
  }

  Future<void> notice(String id,
          {DateTime? at, String? body, String app = 'com.example.test'}) =>
      c.addTimelineEntry(TimelineEntry(
          id: id,
          timestamp: at ?? now.subtract(const Duration(hours: 1)),
          sourceType: TimelineSourceType.appNotification,
          sourceApp: '合成通知应用',
          appIdentifier: app,
          content: body ?? '合成测试正文'));
  NotificationDigestRange range(DateTime from, DateTime to) =>
      NotificationDigestRange(NotificationDigestMode.custom, from, to);
  Future<NotificationDigestJob> digest(NotificationDigestRange range) async {
    final job = await c.enqueueNotificationDigest(range);
    await c.processNotificationQueue();
    return job;
  }

  Future<void> close() async {
    if (!c.disposed) c.dispose();
    await audioFixture.close();
  }
}

Future<void> until(bool Function() ready) async {
  for (var n = 0; n < 500 && !ready(); n++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(ready(), true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DigestWorld w;
  setUp(() async {
    w = DigestWorld();
    await w.open();
  });
  tearDown(() async => w.close());
  test('received notifications never auto generate; audio and notes excluded',
      () async {
    await w.notice('n');
    await w.c.addTimelineEntry(TimelineEntry(
        id: 'audio',
        timestamp: w.now.subtract(const Duration(hours: 1)),
        sourceType: TimelineSourceType.audioVoice,
        sourceApp: 'audio',
        content: '不应发往通知简报'));
    await w.c.resume();
    expect(w.agent.calls, 0);
    final job =
        await w.digest(w.c.notificationRange(NotificationDigestMode.today));
    expect(job.stage, NotificationDigestStage.saved);
    expect(w.agent.payloads.single.length, 1);
    expect(w.agent.payloads.single.single['id'], 'n');
    expect(w.audioFixture.asr.submits, 0);
    expect(w.c.summaries.single.kind, 'notification');
  });
  test('today and first sinceLast use local midnight, upper bound exclusive',
      () async {
    final range = w.c.notificationRange(NotificationDigestMode.today);
    expect(range.from, DateTime(2026, 10, 21));
    expect(w.c.notificationRange(NotificationDigestMode.sinceLast).from,
        range.from);
    await w.notice('start', at: range.from);
    await w.notice('end', at: range.to);
    await w.notice('old',
        at: range.from.subtract(const Duration(microseconds: 1)));
    final job = await w.digest(range);
    expect(job.inputIds, ['start']);
    expect(w.c.notificationCoveredUntil, range.to);
  });
  test(
      'same simultaneous enqueue and later fixed range reuse exactly one request',
      () async {
    await w.notice('n');
    final range = w.c.notificationRange(NotificationDigestMode.today);
    final jobs = await Future.wait([
      w.c.enqueueNotificationDigest(range),
      w.c.enqueueNotificationDigest(range)
    ]);
    await w.c.processNotificationQueue();
    expect(jobs.first.id, jobs.last.id);
    expect(w.agent.calls, 1);
    await w.digest(range);
    expect(w.agent.calls, 1);
  });
  test('manual queue is serial across distinct ranges', () async {
    await w.notice('n');
    w.agent.gate = Completer<void>();
    final first = await w.c.enqueueNotificationDigest(
        w.c.notificationRange(NotificationDigestMode.today));
    await until(() => w.agent.calls == 1);
    w.now = w.now.add(const Duration(minutes: 1));
    await w.notice('second', at: w.now.subtract(const Duration(seconds: 30)));
    final second = await w.c.enqueueNotificationDigest(
        w.c.notificationRange(NotificationDigestMode.today));
    expect(second.id, isNot(first.id));
    expect(second.stage, NotificationDigestStage.queued);
    w.agent.gate!.complete();
    await w.c.processNotificationQueue();
    expect(w.agent.calls, 2);
    expect(w.agent.maxActive, 1);
    expect(
        w.c.notificationJobs
            .every((j) => j.stage == NotificationDigestStage.saved),
        true);
  });
  for (final empty in [false, true])
    test(
        'failure or empty $empty neither saves fake text nor moves cursor, manual retry only',
        () async {
      await w.notice('n');
      w.agent.fail = !empty;
      w.agent.empty = empty;
      final job =
          await w.digest(w.c.notificationRange(NotificationDigestMode.today));
      expect(job.stage, NotificationDigestStage.failed);
      expect(w.c.notificationCoveredUntil, null);
      expect(w.c.summaries, isEmpty);
      await w.c.resume();
      await w.c.processNotificationQueue();
      expect(w.agent.calls, 1);
      w.agent.fail = false;
      w.agent.empty = false;
      await w.c.retryNotificationDigest(job.id);
      await w.c.processNotificationQueue();
      expect(w.agent.calls, 2);
      expect(job.stage, NotificationDigestStage.saved);
    });
  for (final drop in [false, true])
    test(
        'summary storage ${drop ? "unconfirmed" : "failure"} leaves coverage unchanged',
        () async {
      await w.notice('n');
      w.memory.rejectSummary = !drop;
      w.memory.dropSummary = drop;
      final job =
          await w.digest(w.c.notificationRange(NotificationDigestMode.today));
      expect(job.stage, NotificationDigestStage.failed);
      expect(w.c.notificationCoveredUntil, null);
      expect(w.c.summaries.where((s) => s.kind == 'notification'), isEmpty);
    });
  test('saved result and last coverage reopen, meetings and lifelog do not mix',
      () async {
    await w.notice('n');
    final job =
        await w.digest(w.c.notificationRange(NotificationDigestMode.today));
    final end = w.c.notificationCoveredUntil;
    w.c.dispose();
    await w.reopen();
    expect(w.c.notificationJobs.single.stage, NotificationDigestStage.saved);
    expect(w.c.summaries.single.id, job.id);
    expect(w.c.notificationCoveredUntil!.isAtSameMomentAs(end!), true);
    await w.c.resume();
    expect(w.agent.calls, 1);
  });
  test(
      'running at restart becomes interrupted; never resends without confirmation',
      () async {
    await w.notice('n');
    w.c.foreground = false;
    final job = await w.c.enqueueNotificationDigest(
        w.c.notificationRange(NotificationDigestMode.today));
    final raw = w.memory.data['notification_jobs']![job.id]!;
    raw['stage'] = 'running';
    w.c.dispose();
    await w.reopen();
    await w.c.resume();
    await w.c.processNotificationQueue();
    expect(
        w.c.notificationJobs.single.stage, NotificationDigestStage.interrupted);
    expect(w.agent.calls, 0);
    await w.c.retryNotificationDigest(job.id);
    await w.c.processNotificationQueue();
    expect(w.agent.calls, 1);
  });
  test(
      'explicit queued jobs survive reopen and then continue, no background generation',
      () async {
    await w.notice('n');
    w.c.foreground = false;
    await w.c.enqueueNotificationDigest(
        w.c.notificationRange(NotificationDigestMode.today));
    await w.c.processNotificationQueue();
    expect(w.agent.calls, 0);
    w.c.dispose();
    await w.reopen();
    await w.c.processNotificationQueue();
    expect(w.agent.calls, 1);
  });
  test('revoked app permission before queued request prevents sending',
      () async {
    await w.notice('n');
    w.c.foreground = false;
    final job = await w.c.enqueueNotificationDigest(
        w.c.notificationRange(NotificationDigestMode.today));
    w.allowed.clear();
    w.c.foreground = true;
    await w.c.processNotificationQueue();
    expect(w.agent.calls, 0);
    expect(job.stage, NotificationDigestStage.failed);
    expect(w.c.notificationCoveredUntil, null);
  });
  test('permission change mid-response prevents successful summary and cursor',
      () async {
    await w.notice('n');
    w.agent.gate = Completer<void>();
    final job = await w.c.enqueueNotificationDigest(
        w.c.notificationRange(NotificationDigestMode.today));
    await until(() => w.agent.calls == 1);
    w.allowed.clear();
    w.c.notificationPolicyChanged();
    w.agent.gate!.complete();
    await w.c.processNotificationQueue();
    expect(job.stage, NotificationDigestStage.failed);
    expect(w.c.notificationCoveredUntil, null);
  });
  test(
      'source update or changed server before processing pauses for explicit action',
      () async {
    await w.notice('n');
    w.c.foreground = false;
    final job = await w.c.enqueueNotificationDigest(
        w.c.notificationRange(NotificationDigestMode.today));
    w.agent.hermesBaseUrl = 'http://192.0.2.5/v1';
    w.c.foreground = true;
    await w.c.processNotificationQueue();
    expect(job.stage, NotificationDigestStage.failed);
    expect(w.agent.calls, 0);
    await w.c.retryNotificationDigest(job.id);
    await w.c.processNotificationQueue();
    expect(w.agent.calls, 1);
    expect(job.stage, NotificationDigestStage.saved);
  });
  test(
      'custom separated interval never skips gap; later covering request bridges it',
      () async {
    await w.notice('one', at: DateTime(2026, 10, 21, 8));
    await w.notice('two', at: DateTime(2026, 10, 21, 11));
    await w
        .digest(w.range(DateTime(2026, 10, 21, 7), DateTime(2026, 10, 21, 9)));
    expect(w.c.notificationCoveredUntil, DateTime(2026, 10, 21, 9));
    w.now = w.now.add(const Duration(seconds: 1));
    await w.digest(
        w.range(DateTime(2026, 10, 21, 10), DateTime(2026, 10, 21, 12)));
    expect(w.c.notificationCoveredUntil, DateTime(2026, 10, 21, 9));
    await w.notice('gap', at: DateTime(2026, 10, 21, 9, 30));
    await w
        .digest(w.range(DateTime(2026, 10, 21, 9), DateTime(2026, 10, 21, 10)));
    expect(w.c.notificationCoveredUntil, DateTime(2026, 10, 21, 12));
  });
  test(
      'no allowed inputs, invalid future/long range or cancelled queue never sends or advances',
      () async {
    await expectLater(
        w.c.enqueueNotificationDigest(
            w.c.notificationRange(NotificationDigestMode.today)),
        throwsA(isA<RecordingProcessingException>()));
    await w.notice('n');
    await expectLater(
        w.c.enqueueNotificationDigest(
            w.range(w.now, w.now.add(const Duration(seconds: 1)))),
        throwsA(isA<RecordingProcessingException>()));
    w.c.foreground = false;
    final job = await w.c.enqueueNotificationDigest(
        w.c.notificationRange(NotificationDigestMode.today));
    await w.c.cancelNotificationDigest(job.id);
    w.c.foreground = true;
    await w.c.processNotificationQueue();
    expect(w.agent.calls, 0);
    expect(w.c.notificationCoveredUntil, null);
  });
  test(
      'large bodies use notification-only bounded batches and saved intermediates',
      () async {
    await w.notice('large', body: List.filled(22000, '字').join());
    final job =
        await w.digest(w.c.notificationRange(NotificationDigestMode.today));
    expect(job.stage, NotificationDigestStage.saved);
    expect(w.agent.calls, greaterThan(1));
    expect(w.agent.payloads.every((batch) => batch.isNotEmpty), true);
    expect(
        w.memory.data['summaries']!.values
            .any((v) => v['kind'] == 'intermediate'),
        true);
  });
  test('input modification marks saved digest outdated', () async {
    await w.notice('n');
    await w.digest(w.c.notificationRange(NotificationDigestMode.today));
    final saved = w.c.summaries.single;
    expect(await w.c.summaryCurrent(saved), true);
    await w.notice('n', body: '更新正文');
    expect(await w.c.summaryCurrent(saved), false);
  });
  test('real private JSON store preserves queued requests and saved summaries',
      () async {
    w.c.dispose();
    final store = FileRecordingContentStore(
        root: () async =>
            Directory('${w.audioFixture.directory.path}/digest-content'));
    await w.reopen(store: store);
    await w.notice('n');
    await w.digest(w.c.notificationRange(NotificationDigestMode.today));
    w.c.dispose();
    await w.reopen(store: store);
    expect(w.c.loaded, true);
    expect(w.c.notificationJobs.single.stage, NotificationDigestStage.saved);
    expect(w.c.summaries.single.text, '合成通知简报');
  });
}

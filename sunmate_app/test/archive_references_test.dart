import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ai/agent_client.dart';
import 'package:sunmate_app/core/sync/archive_models.dart';
import 'package:sunmate_app/core/sync/archive_sync.dart';
import 'package:sunmate_app/core/sync/archive_projection.dart';
import 'package:sunmate_app/core/recordings/recording_processing_controller.dart';
import 'package:sunmate_app/core/hardware/recorder_long_recordings.dart';
import 'package:sunmate_app/core/recordings/notification_digest_models.dart';
import 'recording_processing_test.dart'
    show ProcessingFixture, session, sn, notice;
import 'archive_sync_test.dart' show SyncSecure, SyncRemote;

class ReferenceAgent extends AgentClient {
  final requests = <Map<String, dynamic>>[];
  String mode = 'valid';
  @override
  Stream<String> chatStream(String userMessage,
      {String? systemPrompt,
      List<Map<String, String>>? history,
      void Function(String)? onProgress}) async* {
    final start = userMessage.indexOf('{"schemaVersion"');
    final request =
        jsonDecode(userMessage.substring(start)) as Map<String, dynamic>;
    requests.add(request);
    if (request['schemaVersion'] == 'sunmate.reference.merge.v1') {
      yield jsonEncode({
        'status': 'complete',
        'libraryId': request['libraryId'],
        'usedBatchShas': [for (final row in request['batches']) row['sha']],
        'text': '合成合并结果'
      });
      return;
    }
    final archive = request['archive'] as Map;
    if (mode == 'plain_error') {
      yield '查询工具不可用';
      return;
    }
    final refs = List<Map<String, dynamic>>.from(archive['records']);
    yield jsonEncode({
      'status': mode == 'error' ? 'error' : 'complete',
      'libraryId':
          mode == 'wrong_library' ? 'other-library' : archive['libraryId'],
      'used': mode == 'missing_source' ? [] : refs,
      'text': '合成处理结果'
    });
  }
}

void main() {
  test(
      'automatic meeting summary cannot implicitly enable persistent archive uploads',
      () async {
    final f = ProcessingFixture();
    await f.open();
    final remote = SyncRemote();
    final sync = ArchiveSyncController(
        store: f.memory,
        secure: SyncSecure(),
        sources: () => projectArchive(f.memory, f.allowed.contains),
        transport: (_, __) => remote);
    try {
      await sync.ready;
      await sync.pair('http://127.0.0.1/sunmate/v1', 'synthetic-token',
          SyncRemote.identity);
      f.c.dispose();
      f.c = RecordingProcessingController(
          content: f.memory,
          audioStore: f.store,
          audio: f.audio,
          asr: () => f.asr,
          agent: () => f.agent,
          archive: sync);
      await f.c.ready;
      await f.start();
      final part = await f.add(0);
      await f.finish();
      await f.c.transcribePart(part);
      await f.c.summarizeMeeting('$sn:$session', automatic: true);
      expect(f.agent.meetings, 1);
      expect(remote.bodies, isEmpty);
      expect(sync.config.automatic, isEmpty);
    } finally {
      sync.dispose();
      await f.close();
    }
  });
  test(
      'saved report pins source versions; changed ASR and legacy reports are marked explicitly',
      () async {
    final f = ProcessingFixture();
    await f.open();
    try {
      await f.start();
      final part = await f.add(0);
      await f.finish();
      await f.c.transcribePart(part);
      final summary = await f.c.summarizeMeeting('$sn:$session');
      expect(summary.sourceVersions, isNotEmpty);
      var projected = await projectArchive(f.memory, f.allowed.contains);
      expect(
          projected
              .singleWhere((v) => v.kind == 'summary')
              .payload['sourceState'],
          'current');
      final prior = Map<String, String>.from(summary.sourceVersions);
      final transcript = f.c.transcript(part)!;
      transcript.text = '合成修改后的转写';
      await f.memory.put('transcripts', transcript.id, transcript.toJson());
      projected = await projectArchive(f.memory, f.allowed.contains);
      final report = projected.singleWhere((v) => v.kind == 'summary');
      expect(report.payload['sourceState'], 'source_changed');
      expect(
          (report.payload['sources'] as List).first['sha'], prior.values.first);
      final legacy = summary.toJson()..remove('sourceVersions');
      await f.memory.put('summaries', summary.id, legacy);
      projected = await projectArchive(f.memory, f.allowed.contains);
      expect(
          projected
              .singleWhere((v) => v.kind == 'summary')
              .payload['sourceState'],
          'legacy_versions_unknown');
    } finally {
      await f.close();
    }
  });
  test(
      'large reference ranges are processed in bounded batches then merged, with no original bodies',
      () async {
    final agent = ReferenceAgent();
    final refs = ArchiveReferences('server', 'lib', 'default', 'client', [
      for (var i = 0; i < 25; i++) {'id': 'record:$i', 'sha': 'sha-$i'}
    ]);
    expect(await agent.summarizeArchiveReferences(refs, task: 'notification'),
        '合成合并结果');
    expect(agent.requests.length, 4);
    expect((agent.requests.first['archive']['records'] as List).length, 12);
    expect(agent.requests.last['schemaVersion'], 'sunmate.reference.merge.v1');
    expect(jsonEncode(agent.requests).contains('payload'), false);
  });
  test(
      'model requests contain exact references without re-sending bodies; errors never save as results',
      () async {
    final agent = ReferenceAgent();
    final refs = ArchiveReferences('server', 'lib', 'default', 'client', [
      {'id': 'transcript:p1', 'sha': 'version-sha'}
    ]);
    expect(await agent.summarizeArchiveReferences(refs, task: 'meeting'),
        '合成处理结果');
    expect(jsonEncode(agent.requests).contains('payload'), false);
    expect(jsonEncode(agent.requests).contains('version-sha'), true);
    for (final mode in [
      'plain_error',
      'error',
      'wrong_library',
      'missing_source'
    ]) {
      agent.mode = mode;
      await expectLater(
          agent.summarizeArchiveReferences(refs, task: 'notification'),
          throwsA(isA<AgentResponseException>()));
    }
  });
  for (final purpose in LongRecordingPurpose.values) {
    test(
        'real processing and archive wiring: ${purpose.name}, reuses receipts and archives final result',
        () async {
      final f = ProcessingFixture();
      await f.open();
      final remote = SyncRemote(),
          secure = SyncSecure(),
          agent = ReferenceAgent();
      final sync = ArchiveSyncController(
          store: f.memory,
          secure: secure,
          sources: () => projectArchive(f.memory, f.allowed.contains),
          transport: (_, __) => remote);
      try {
        await sync.ready;
        await sync.pair('http://127.0.0.1/sunmate/v1', 'synthetic-token',
            SyncRemote.identity);
        f.c.dispose();
        f.c = RecordingProcessingController(
            content: f.memory,
            audioStore: f.store,
            audio: f.audio,
            asr: () => f.asr,
            agent: () => agent,
            archive: sync,
            allowsNotification: f.allowed.contains);
        await f.c.ready;
        await f.start(purpose: purpose);
        final part = await f.add(0, purpose: purpose);
        await f.finish(purpose: purpose);
        await f.c.transcribePart(part);
        await f.c.addTimelineEntry(notice());
        await sync.setAutomatic({'summary'});
        final from = DateTime.fromMillisecondsSinceEpoch(session - 1000),
            to = DateTime.fromMillisecondsSinceEpoch(session + 10000);
        final saved = purpose == LongRecordingPurpose.meeting
            ? await f.c.summarizeMeeting('$sn:$session')
            : await f.c.summarizeLifelog(from, to);
        expect(saved.text, '合成处理结果');
        expect(agent.requests.length, 1);
        expect(remote.bodies.any((v) => v['kind'] == 'transcript'), true);
        final before = remote.bodies.length;
        if (purpose == LongRecordingPurpose.meeting) {
          await f.c.summarizeMeeting('$sn:$session');
        } else {
          await f.c.summarizeLifelog(from, to);
        }
        expect(agent.requests.length, 1);
        expect(remote.bodies.length, before);
        await sync.refresh();
        expect(remote.bodies.last['kind'], 'summary');
        expect((remote.bodies.last['payload'] as Map)['sources'], isNotEmpty);
      } finally {
        sync.dispose();
        await f.close();
      }
    });
  }
  test(
      'notification digest queue uses references, persists result and cannot advance on invalid response',
      () async {
    final f = ProcessingFixture();
    await f.open();
    final remote = SyncRemote(), agent = ReferenceAgent();
    final sync = ArchiveSyncController(
        store: f.memory,
        secure: SyncSecure(),
        sources: () => projectArchive(f.memory, f.allowed.contains),
        transport: (_, __) => remote);
    try {
      await sync.ready;
      await sync.pair('http://127.0.0.1/sunmate/v1', 'synthetic-token',
          SyncRemote.identity);
      f.c.dispose();
      f.c = RecordingProcessingController(
          content: f.memory,
          audioStore: f.store,
          audio: f.audio,
          asr: () => f.asr,
          agent: () => agent,
          archive: sync,
          allowsNotification: f.allowed.contains,
          notificationClock: () =>
              DateTime.fromMillisecondsSinceEpoch(session + 10000));
      await f.c.ready;
      await f.c.addTimelineEntry(notice());
      final range = NotificationDigestRange(
          NotificationDigestMode.custom,
          DateTime.fromMillisecondsSinceEpoch(session),
          DateTime.fromMillisecondsSinceEpoch(session + 1000));
      final job = await f.c.enqueueNotificationDigest(range);
      await f.c.processNotificationQueue();
      expect(job.stage, NotificationDigestStage.saved);
      expect(f.c.summaries.single.kind, 'notification');
      expect(remote.bodies.single['kind'], 'notification');
      expect(
          agent.requests.single['from'], range.from.toUtc().toIso8601String());
    } finally {
      sync.dispose();
      await f.close();
    }
  });
}

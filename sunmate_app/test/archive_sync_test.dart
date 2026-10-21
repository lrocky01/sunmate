import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/config/server_config_store.dart';
import 'package:sunmate_app/core/sync/archive_models.dart';
import 'package:sunmate_app/core/sync/archive_sync.dart';
import 'package:sunmate_app/core/sync/archive_transport.dart';
import 'package:sunmate_app/core/sync/archive_projection.dart';
import 'recording_processing_test.dart'
    show MemoryContent, ProcessingFixture, notice;

class SyncSecure implements ServerConfigStore {
  String? value;
  bool fail = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String next) async {
    if (fail) throw StateError('synthetic');
    value = next;
  }
}

class SyncRemote implements ArchiveTransport {
  void Function()? onReceipt;
  static const identity = {
    'serverId': 'test-server',
    'libraryId': 'test-library',
    'profile': 'default',
    'clientId': 'test-client'
  };
  final saved = <String, Map<String, dynamic>>{};
  final bodies = <Map<String, dynamic>>[];
  bool offline = false,
      lostAck = false,
      invalidReceipt = false,
      auth = false,
      conflict = false;
  String key(Map<String, dynamic> v) =>
      '${v['id']}:${v['revision']}:${v['sha']}';
  @override
  Future<Map<String, dynamic>> capabilities() async =>
      {'schema': archiveSchema, ...identity, 'rawAudio': false};
  @override
  Future<List<Map<String, dynamic>>> exchange(String route,
      Map<String, dynamic> identity, List<Map<String, dynamic>> rows) async {
    if (route == 'receipts') onReceipt?.call();
    if (auth)
      throw const ArchiveSyncException('synthetic revoked', pause: true);
    if (offline) throw const ArchiveSyncException('synthetic offline');
    if (route == 'ingest') {
      bodies.addAll(rows);
      for (final row in rows) {
        saved[key(row)] = row;
      }
      if (lostAck) {
        lostAck = false;
        throw const ArchiveSyncException('synthetic unknown receipt');
      }
    }
    return [
      for (final row in rows)
        {
          for (final k in ['id', 'revision', 'sha']) k: row[k],
          'status': conflict
              ? 'conflict'
              : saved.containsKey(key(row))
                  ? 'accepted'
                  : 'missing',
          if (invalidReceipt) 'sha': 'incorrect',
        }
    ];
  }
}

ArchiveSource source(String id,
        {String text = '合成通知',
        bool visible = true,
        String category = 'notification'}) =>
    ArchiveSource(
        id,
        category == 'meeting' ? 'transcript' : 'notification',
        category,
        DateTime.utc(2026, 10, 21, 10),
        {'text': text, 'scope': 'synthetic', 'offsetMs': 0},
        aliases: {id},
        visible: visible);

void main() {
  test(
      'foreground refresh coalesces; unchanged source generation avoids rereading all files per receipt',
      () async {
    final store = MemoryContent(), remote = SyncRemote();
    var generation = 0, reads = 0;
    var rows = [source('n1')];
    final controller = ArchiveSyncController(
        store: store,
        secure: SyncSecure(),
        sourceGeneration: () => generation,
        sources: () async {
          reads++;
          return rows;
        },
        transport: (_, __) => remote);
    try {
      await controller.ready;
      await controller.pair('http://127.0.0.1/sunmate/v1', 'synthetic-token',
          SyncRemote.identity);
      final before = reads;
      await controller.ensureReferences({'n1'});
      expect(reads - before, 1);
      final a = controller.refresh(), b = controller.refresh();
      expect(identical(a, b), true);
      await a;
      remote.onReceipt = () {
        rows = [source('n1', visible: false)];
        generation++;
      };
      await expectLater(controller.ensureReferences({'n1'}),
          throwsA(isA<ArchiveSyncException>()));
      expect(remote.bodies.length, 1);
    } finally {
      controller.dispose();
    }
  });
  test(
      'large history persists per-source cursors instead of one oversized state document',
      () async {
    final memory = MemoryContent(),
        secure = SyncSecure(),
        remote = SyncRemote();
    final longId = List.filled(1050, 'a').join();
    final rows = [for (var i = 0; i < 1000; i++) source('$longId$i')];
    final controller = ArchiveSyncController(
        store: memory,
        secure: secure,
        sources: () async => rows,
        transport: (_, __) => remote);
    try {
      await controller.ready;
      await controller.pair('http://127.0.0.1/sunmate/v1', 'synthetic-token',
          SyncRemote.identity);
      final states = await memory.readAll('archive_state');
      expect(states.length, 1000);
      expect(states.every((v) => jsonEncode(v).length < 4096), true);
    } finally {
      controller.dispose();
    }
  });
  test('source changes during receipt query cannot send the old body',
      () async {
    var rows = [source('n1')];
    final remote = SyncRemote();
    final sync = ArchiveSyncController(
        store: MemoryContent(),
        secure: SyncSecure(),
        sources: () async => rows,
        transport: (_, __) => remote);
    try {
      await sync.ready;
      await sync.pair('http://127.0.0.1/sunmate/v1', 'synthetic-token',
          SyncRemote.identity);
      remote.onReceipt = () => rows = [source('n1', visible: false)];
      await expectLater(
          sync.ensureReferences({'n1'}), throwsA(isA<ArchiveSyncException>()));
      expect(remote.bodies, isEmpty);
    } finally {
      sync.dispose();
    }
  });
  late MemoryContent store;
  late SyncSecure secure;
  late SyncRemote remote;
  late List<ArchiveSource> rows;
  late ArchiveSyncController sync;
  Future<void> open() async {
    sync = ArchiveSyncController(
        store: store,
        secure: secure,
        sources: () async => rows,
        transport: (_, __) => remote);
    await sync.ready;
  }

  setUp(() async {
    store = MemoryContent();
    secure = SyncSecure();
    remote = SyncRemote();
    rows = [];
    await open();
    await sync.pair(
        'http://127.0.0.1/sunmate/v1', 'synthetic-token', SyncRemote.identity);
  });
  tearDown(() => sync.dispose());
  test('default off; enabling baselines old data; new source auto syncs',
      () async {
    rows.add(source('old'));
    await sync.setAutomatic({'notification'});
    await sync.refresh();
    expect(remote.bodies, isEmpty);
    rows.add(source('new'));
    await sync.refresh();
    expect(remote.bodies.single['id'], 'new');
    await sync.refresh();
    expect(remote.bodies.length, 1);
    expect(sync.confirmed, 1);
  });
  test('archived query only checks references; missing version is filled',
      () async {
    rows.add(source('n1'));
    final refs = await sync.ensureReferences({'n1'});
    expect(refs.records.single['id'], 'n1');
    await sync.ensureReferences({'n1'});
    expect(remote.bodies.length, 1);
    remote.saved.clear();
    await sync.ensureReferences({'n1'});
    expect(remote.bodies.length, 2);
  });
  test('lost acknowledgement is recovered without repeating content', () async {
    rows.add(source('n1'));
    remote.lostAck = true;
    await expectLater(
        sync.ensureReferences({'n1'}), throwsA(isA<ArchiveSyncException>()));
    expect(sync.pending, 1);
    sync.dispose();
    await open();
    await sync.refresh(retry: true);
    expect(remote.bodies.length, 1);
    expect(sync.confirmed, 1);
  });
  test('source commit to queue crash gap is reconciled after restart',
      () async {
    await sync.setAutomatic({'notification'});
    rows.add(source('new-durable-source'));
    sync.dispose();
    await open();
    await sync.refresh();
    expect(remote.bodies.single['id'], 'new-durable-source');
  });
  test('offline backoff, manual retry and authentication pause', () async {
    await sync.setAutomatic({'notification'});
    rows.add(source('n1'));
    remote.offline = true;
    await sync.refresh();
    expect(sync.pending, 1);
    expect(sync.retryAt, isNotNull);
    remote.offline = false;
    remote.auth = true;
    await sync.refresh(retry: true);
    expect(sync.paused, true);
    remote.auth = false;
    await sync.refresh();
    expect(remote.bodies, isEmpty);
    await sync.refresh(retry: true);
    expect(sync.confirmed, 1);
  });
  test('wrong receipt and conflicts cannot confirm or replace content',
      () async {
    rows.add(source('n1'));
    remote.invalidReceipt = true;
    await expectLater(
        sync.ensureReferences({'n1'}), throwsA(isA<ArchiveSyncException>()));
    expect(sync.confirmed, 0);
    expect(sync.paused, true);
    remote.invalidReceipt = false;
    remote.conflict = true;
    await sync.refresh(retry: true);
    expect(sync.entries.single['status'], 'conflict');
    expect(sync.confirmed, 0);
  });
  test(
      'visibility withdrawal syncs even when automatic sync is off; reenable creates new revision',
      () async {
    rows.add(source('n1'));
    await sync.ensureReferences({'n1'});
    rows[0] = source('n1', visible: false);
    await sync.refresh();
    expect(remote.bodies.last['visible'], false);
    await expectLater(
        sync.ensureReferences({'n1'}), throwsA(isA<ArchiveSyncException>()));
    rows[0] = source('n1');
    await sync.ensureReferences({'n1'});
    expect(remote.bodies.last['revision'], 3);
    expect(remote.bodies.last['visible'], true);
  });
  test('old queued body never transmits after permission changes', () async {
    await sync.setAutomatic({'notification'});
    rows.add(source('n1'));
    remote.offline = true;
    await sync.refresh();
    rows[0] = source('n1', visible: false);
    remote.offline = false;
    await sync.refresh(retry: true);
    expect(remote.bodies.every((v) => v['visible'] == false), true);
  });
  test('endpoint switch pauses old queue and does not send it to new identity',
      () async {
    rows.add(source('n1'));
    remote.offline = true;
    await expectLater(
        sync.ensureReferences({'n1'}), throwsA(isA<ArchiveSyncException>()));
    remote.offline = false;
    await sync.pair(
        'http://127.0.0.2/sunmate/v1', 'synthetic-token', SyncRemote.identity);
    await sync.refresh();
    expect(remote.bodies, isEmpty);
    expect(sync.pending, 0);
  });
  test('save failure and background execution do not send content', () async {
    secure.fail = true;
    await expectLater(sync.setAutomatic({'notification'}), throwsStateError);
    expect(sync.config.automatic, isEmpty);
    rows.add(source('n1'));
    sync.setForeground(false);
    await expectLater(
        sync.ensureReferences({'n1'}), throwsA(isA<ArchiveSyncException>()));
    expect(remote.bodies, isEmpty);
  });
  test(
      'history explicitly backfills selected types; repeated backfill only reads receipts',
      () async {
    rows.addAll([source('n1'), source('t1', category: 'meeting')]);
    await sync.refresh();
    await sync.backfill(
        DateTime.utc(2026, 10, 21), DateTime.utc(2026, 10, 22), {'meeting'});
    await sync.refresh();
    expect(remote.bodies.single['id'], 't1');
    await sync.backfill(
        DateTime.utc(2026, 10, 21), DateTime.utc(2026, 10, 22), {'meeting'});
    await sync.refresh();
    expect(remote.bodies.length, 1);
  });
  test('projection excludes jobs paths credentials and intermediate summaries',
      () async {
    final fixture = ProcessingFixture();
    await fixture.open();
    try {
      await fixture.start();
      final part = await fixture.add(0);
      await fixture.finish();
      await fixture.c.transcribePart(part);
      await fixture.c.addTimelineEntry(notice());
      final projected = await projectArchive(fixture.memory, (_) => true);
      final encoded = jsonEncode(projected.map((v) => v.body).toList());
      expect(projected.map((v) => v.kind),
          containsAll(['session', 'transcript', 'notification']));
      expect(encoded.contains('recorder_long_audio_v1/'), false);
      expect(encoded.contains('serverFingerprint'), false);
      expect(encoded.contains('synthetic-1'), false);
      expect(
          projected
              .firstWhere((v) => v.kind == 'transcript')
              .payload['audioUploaded'],
          false);
    } finally {
      await fixture.close();
    }
  });
  test(
      'real Dart HTTP -> Python SQLite -> receipt reuse and Unicode fingerprint',
      () async {
    final temp = await Directory.systemTemp.createTemp('sm-archive-wire-');
    final fixture = File('../sunmate-hermes/tests/archive_loopback.py');
    final process =
        await Process.start('python3', [fixture.absolute.path, temp.path]);
    try {
      final line = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 10));
      final data = jsonDecode(line);
      final transport = HttpArchiveTransport(
          'http://127.0.0.1:${data['port']}/sunmate/v1', data['token']);
      final cap = await transport.capabilities();
      final identity = {
        for (final k in ['serverId', 'libraryId', 'clientId', 'profile'])
          k: cap[k]
      };
      final input = source('notification:wire', text: '测试引号"和换行\n第二行');
      final record = {...input.body, 'sha': await input.sha, 'revision': 1};
      expect(
          (await transport.exchange('ingest', identity, [record]))
              .single['status'],
          'accepted');
      expect(
          (await transport.exchange('ingest', identity, [record]))
              .single['status'],
          'already_present');
      expect(
          (await transport.exchange('receipts', identity, [record]))
              .single['sha'],
          await input.sha);
    } finally {
      process.kill();
      await process.exitCode;
      await temp.delete(recursive: true);
    }
  });
}

import '../../models/timeline_entry.dart';
import '../recordings/local_content_store.dart';
import '../recordings/recording_processing_models.dart';
import 'archive_models.dart';

/// Explicit allowlist: no file paths, ASR jobs, tokens, card credentials or intermediate reports.
Future<List<ArchiveSource>> projectArchive(RecordingContentStore store,
    bool Function(String) allowsNotification, {String? serverTarget}) async {
  final hidden = (await store.readAll('hidden')).map((v) => v['id']).toSet();
  final sessions = {
    for (final row in await store.readAll('sessions'))
      row['id'] as String: ProcessingSession.fromJson(row)
  };
  final transcripts = {
    for (final row in await store.readAll('transcripts'))
      row['id'] as String: PartTranscript.fromJson(row)
  };
  final result = <ArchiveSource>[];
  final parts = [
    for (final row in await store.readAll('parts')) ProcessingPart.fromJson(row)
  ];
  final serverTranscripts = <String, Map<String, dynamic>>{};
  final serverSummaries = <String, Map<String, dynamic>>{};
  final serverRecords = <String, Map<String, dynamic>>{};
  final uploaded = <String, Set<int>>{};
  if (serverTarget != null) {
    for (final row in await store.readAll('background_results')) {
      if (row['target'] != serverTarget || row['body'] is! Map) continue;
      final body = Map<String, dynamic>.from(row['body']);
      if (row['kind'] == 'audio' && body['metadata'] is Map && body['state'] != 'awaiting_upload') {
        final m = body['metadata'];
        final current = parts.where((p) => p.active && p.sessionId == m['session'] && p.source.part == m['part'] && p.source.sha256 == m['sourceSha']);
        if (current.isNotEmpty) (uploaded[m['session']] ??= {}).add(m['part']);
      }
      final record = body['archiveRecord'];
      if (record is! Map<String, dynamic> || row['applied'] != true) continue;
      serverRecords[record['id']] = record;
      if (row['kind'] == 'audio' && body['state'] == 'complete') {
        final m = body['metadata'];
        serverTranscripts['${m['session']}:${m['part']}:${m['sourceSha']}'] = record;
      } else if (row['kind'] == 'summary') {
        serverSummaries[await contentFingerprint(['server-summary', row['remoteId'] ?? row['id']])] = record;
      }
    }
  }
  bool complete(ProcessingSession s) {
    final active = parts.where((p) => p.sessionId == s.id && p.active).toList()
      ..sort((a, b) => a.source.part.compareTo(b.source.part));
    return s.complete &&
        s.totalParts != null &&
        active.length == s.totalParts &&
        List.generate(active.length,
                (i) => active[i].source.part == i && active[i].ready)
            .every((v) => v);
  }

  for (final s in sessions.values) {
    if (s.purpose == null) continue;
    result.add(ArchiveSource(
        'session:${s.id}',
        'session',
        s.purpose!.name,
        s.estimatedAnchor ??
            s.observedStart ??
            s.observedEnd ??
            DateTime.utc(1970),
        {
          'scope': s.id,
          'purpose': s.purpose!.name,
          'complete': complete(s),
          'recordingStopped': s.complete,
          'archivedParts': parts
              .where((p) => p.active && p.sessionId == s.id && p.ready)
              .length,
          'transcribedParts': parts
              .where((p) =>
                  p.active &&
                  p.sessionId == s.id &&
                  transcripts[p.transcriptKey]?.stage ==
                      TranscriptionStage.complete)
              .length,
          'totalParts': s.totalParts,
          'timeConfidence': s.estimatedAnchor == null ? 'unknown' : 'estimated',
          'observedStart': s.observedStart?.toUtc().toIso8601String(),
          'observedEnd': s.observedEnd?.toUtc().toIso8601String(),
          'audioLocation': (uploaded[s.id]?.isNotEmpty ?? false) ? 'phone_card_and_private_server' : 'phone_and_card',
          'audioUploaded': complete(s) && uploaded[s.id]?.length == s.totalParts,
          if (uploaded[s.id]?.isNotEmpty ?? false) 'uploadedParts': uploaded[s.id]!.length,
        },
        aliases: {
          'session:${s.id}'
        }));
  }
  for (final p in parts) {
    final s = sessions[p.sessionId];
    if (s == null || s.purpose == null) continue;
    final t = transcripts[p.transcriptKey];
    if (t == null || t.stage != TranscriptionStage.complete) continue;
    final aliases = {
      p.id,
      'segment_${t.id}',
      for (var i = 0; i < t.spans.length; i++) 'segment_${t.id}_$i'
    };
    final remote = serverTranscripts[p.id];
    if (remote != null) {
      result.add(ArchiveSource(remote['id'], 'transcript', s.purpose!.name,
          DateTime.parse(remote['timestamp']), Map<String, dynamic>.from(remote['payload']),
          aliases: aliases, visible: p.active && !aliases.any(hidden.contains)));
      continue;
    }
    // Hiding any sentence hides this complete source version from server queries.
    final visible = p.active && !aliases.any(hidden.contains);
    final start = p.offsetMs == null
        ? null
        : s.estimatedAnchor?.add(Duration(milliseconds: p.offsetMs!));
    result.add(ArchiveSource(
        'transcript:${p.id}',
        'transcript',
        s.purpose!.name,
        start ?? s.observedStart ?? s.observedEnd ?? DateTime.utc(1970),
        {
          'scope': s.id,
          'purpose': s.purpose!.name,
          'part': p.source.part,
          'sourceSha': p.source.sha256,
          'text': t.text,
          'offsetMs': p.offsetMs,
          'durationMs': p.durationMs,
          'timeConfidence': start == null ? 'unknown' : 'estimated',
          'spans': [
            for (final span in t.spans)
              {
                'startMs': (span.start * 1000).round(),
                'endMs': (span.end * 1000).round(),
                'speaker': span.speaker,
                'text': span.text,
              }
          ],
          'partComplete': true,
          'coverage': 'closed_part_only',
          'audioUploaded': false,
        },
        aliases: aliases,
        visible: visible));
  }
  for (final category in ['notifications', 'notes']) {
    for (final row in await store.readAll(category)) {
      final e = TimelineEntry.fromJson(row);
      final notification = category == 'notifications';
      result.add(ArchiveSource(
          '${notification ? 'notification' : 'note'}:${e.id}',
          notification ? 'notification' : 'note',
          notification ? 'notification' : 'lifelog',
          e.timestamp,
          {
            'text': e.content,
            'sourceApp': e.sourceApp,
            'appIdentifier': e.appIdentifier,
            'endTimestamp': e.endTimestamp?.toUtc().toIso8601String(),
            'timeConfidence': 'reported',
          },
          aliases: {e.id},
          visible: !hidden.contains(e.id) &&
              (!notification ||
                  e.appIdentifier != null &&
                      allowsNotification(e.appIdentifier!))));
    }
  }
  for (final row in await store.readAll('summaries')) {
    final s = SavedRecordingSummary.fromJson(row);
    if (s.kind == 'intermediate') continue;
    final dependencies =
        result.where((v) => v.aliases.any(s.inputIds.contains)).toList();
    final visible = dependencies.every((v) => v.visible) && (!s.serverOrigin || s.inputIds.every((id) => dependencies.any((v) => v.aliases.contains(id))));
    final remote = serverSummaries[s.id];
    if (remote != null) {
      result.add(ArchiveSource(remote['id'], 'summary', 'summary', DateTime.parse(remote['timestamp']),
          Map<String, dynamic>.from(remote['payload']), aliases: {s.id, 'summary:${s.id}'}, visible: visible));
      continue;
    }
    result.add(ArchiveSource(
        'summary:${s.id}',
        'summary',
        'summary',
        s.created,
        {
          'scope': s.scope,
          'purpose': s.kind,
          'text': s.text,
          'partial': s.partial,
          'from': s.from?.toUtc().toIso8601String(),
          'to': s.to?.toUtc().toIso8601String(),
          'inputFingerprint': s.inputFingerprint,
          'sources': [
            for (final v in s.sourceVersions.entries)
              {'id': v.key, 'sha': v.value}
          ],
          'sourceVersionsKnown': s.sourceVersions.isNotEmpty,
          'sourceState': s.sourceVersions.isEmpty
              ? 'legacy_versions_unknown'
              : s.sourceVersions.entries.every(
                          (e) => dependencies.any((v) => v.id == e.key)) &&
                      (await Future.wait(dependencies.map((v) async =>
                              s.sourceVersions[v.id] == await v.sha)))
                          .every((v) => v)
                  ? 'current'
                  : 'source_changed',
        },
        aliases: {'summary:${s.id}'},
        visible: visible));
  }
  // A superseded source or unimported result cannot remain query-visible merely
  // because the server originally committed it before the phone reconciled.
  for (final record in serverRecords.values) {
    if (result.any((v) => v.id == record['id'])) continue;
    result.add(ArchiveSource(record['id'], record['kind'], record['kind'] == 'summary' ? 'summary' : record['payload']['purpose'],
      DateTime.parse(record['timestamp']), Map<String, dynamic>.from(record['payload']), visible: false));
  }
  return result;
}

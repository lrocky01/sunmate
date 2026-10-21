import 'dart:collection';
import 'dart:convert';
import '../recordings/local_content_store.dart';

const archiveSchema = 'sunmate.archive.v1';
Object? canonicalValue(Object? value) {
  if (value is Map) {
    return SplayTreeMap<String, dynamic>.from({
      for (final key in value.keys) key as String: canonicalValue(value[key])
    });
  }
  if (value is List) return value.map(canonicalValue).toList();
  return value;
}

class ArchiveSource {
  final String id, kind, category;
  final DateTime time;
  final Map<String, dynamic> payload;
  final Set<String> aliases;
  final bool visible;
  ArchiveSource(this.id, this.kind, this.category, this.time, this.payload,
      {Set<String>? aliases, this.visible = true})
      : aliases = aliases ?? {id};
  Map<String, dynamic> get body => {
        'id': id,
        'kind': kind,
        'timestamp': time.toUtc().toIso8601String(),
        'payload': payload,
        'visible': visible
      };
  Future<String> get sha => contentFingerprint(canonicalValue(body)!);
}

class ArchiveSyncException implements Exception {
  final String message;
  final bool pause;
  final bool isolated;
  const ArchiveSyncException(this.message,
      {this.pause = false, this.isolated = false});
  @override
  String toString() => message;
}

/// Only references, never the archived body, are included in a model request.
class ArchiveReferences {
  final String serverId, libraryId, profile, clientId;
  final List<Map<String, dynamic>> records;
  ArchiveReferences(
      this.serverId, this.libraryId, this.profile, this.clientId, this.records);
  Map<String, dynamic> toJson() => {
        'schema': archiveSchema,
        'libraryId': libraryId,
        'profile': profile,
        'clientId': clientId,
        'records': records,
      };
  String encode() => jsonEncode(toJson());
}

abstract interface class ArchiveReferenceResolver {
  bool get referenceEnabled;
  bool get automaticMeetingSync;
  Future<ArchiveReferences?> existingReferences(Set<String> sourceIds);
  Future<ArchiveReferences> ensureReferences(Set<String> sourceIds);
}

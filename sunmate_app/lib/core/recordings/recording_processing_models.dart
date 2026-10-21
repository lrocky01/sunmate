import '../hardware/recorder_long_file_models.dart';
import '../hardware/recorder_long_recordings.dart';
import '../ai/asr_service.dart';

enum SegmentSignalKind { started, source, finalized, uncertain }

class RecordingSegmentSignal {
  final SegmentSignalKind kind;
  final String sn;
  final int session;
  final LongRecordingPurpose? purpose;
  final RecorderCommittedSegment? source;
  final int? totalParts;
  final DateTime observed;
  RecordingSegmentSignal(this.kind, this.sn, this.session,
      {this.purpose, this.source, this.totalParts, DateTime? observed})
      : observed = observed ?? DateTime.now();
}

String sessionKey(String sn, int session) => '$sn:$session';

class ProcessingPolicy {
  final bool meetingTranscribe, meetingSummary, lifelogTranscribe;
  const ProcessingPolicy(
      {this.meetingTranscribe = false,
      this.meetingSummary = false,
      this.lifelogTranscribe = false});
  bool transcribe(LongRecordingPurpose? purpose) =>
      purpose == LongRecordingPurpose.meeting
          ? meetingTranscribe
          : purpose == LongRecordingPurpose.lifelog && lifelogTranscribe;
  Map<String, dynamic> toJson() => {
        'meetingTranscribe': meetingTranscribe,
        'meetingSummary': meetingSummary,
        'lifelogTranscribe': lifelogTranscribe
      };
  factory ProcessingPolicy.fromJson(Map<String, dynamic> v) {
    if (v['meetingTranscribe'] is! bool ||
        v['meetingSummary'] is! bool ||
        v['lifelogTranscribe'] is! bool ||
        v['meetingSummary'] == true && v['meetingTranscribe'] != true)
      throw const FormatException('处理设置无效');
    return ProcessingPolicy(
        meetingTranscribe: v['meetingTranscribe'],
        meetingSummary: v['meetingSummary'],
        lifelogTranscribe: v['lifelogTranscribe']);
  }
}

class ProcessingSession {
  final String sn;
  final int session;
  LongRecordingPurpose? purpose;
  bool automaticTranscribe = false, automaticSummary = false;
  ProcessingPolicy? startedPolicy;
  bool complete = false, timingUncertain = false;
  int? totalParts;
  DateTime? observedStart, observedEnd;
  ProcessingSession(this.sn, this.session, {this.purpose});
  String get id => sessionKey(sn, session);
  DateTime? get estimatedAnchor {
    if (timingUncertain || session < 1577836800000 || session > 4102444800000)
      return null;
    final date = DateTime.fromMillisecondsSinceEpoch(session, isUtc: true);
    if (observedStart != null &&
        date.difference(observedStart!).abs() > const Duration(minutes: 5))
      return null;
    return date;
  }

  String get timeLabel => estimatedAnchor == null ? '绝对时间待定位' : '依据卡片会话时间估算';
  Map<String, dynamic> toJson() => {
        'sn': sn,
        'session': session,
        'purpose': purpose?.name,
        'startedPolicy': startedPolicy?.toJson(),
        'autoTranscribe': automaticTranscribe,
        'autoSummary': automaticSummary,
        'complete': complete,
        'timingUncertain': timingUncertain,
        'totalParts': totalParts,
        'observedStart': observedStart?.toUtc().toIso8601String(),
        'observedEnd': observedEnd?.toUtc().toIso8601String()
      };
  factory ProcessingSession.fromJson(Map<String, dynamic> v) {
    validateIdentity(v['sn'], v['session']);
    final r = ProcessingSession(v['sn'], v['session'],
        purpose: v['purpose'] == null
            ? null
            : LongRecordingPurpose.values.byName(v['purpose']));
    if ([
          v['autoTranscribe'],
          v['autoSummary'],
          v['complete'],
          v['timingUncertain']
        ].any((b) => b is! bool) ||
        v['totalParts'] != null &&
            (v['totalParts'] is! int ||
                v['totalParts'] < 1 ||
                v['totalParts'] > 10000)) throw const FormatException('会话状态无效');
    r.startedPolicy = v['startedPolicy'] == null
        ? null
        : ProcessingPolicy.fromJson(
            Map<String, dynamic>.from(v['startedPolicy']));
    if (v['autoTranscribe'] !=
            (r.startedPolicy?.transcribe(r.purpose) ?? false) ||
        v['autoSummary'] !=
            (r.purpose == LongRecordingPurpose.meeting &&
                (r.startedPolicy?.meetingSummary ?? false)))
      throw const FormatException('自动处理许可不匹配');
    r.automaticTranscribe = v['autoTranscribe'];
    r.automaticSummary = v['autoSummary'];
    r.complete = v['complete'];
    r.timingUncertain = v['timingUncertain'];
    r.totalParts = v['totalParts'];
    r.observedStart =
        v['observedStart'] == null ? null : DateTime.parse(v['observedStart']);
    r.observedEnd =
        v['observedEnd'] == null ? null : DateTime.parse(v['observedEnd']);
    return r;
  }
}

enum PartPreparation { waiting, ready, failed }

class ProcessingPart {
  final String sn;
  final int session;
  final RecorderCommittedSegment source;
  LongRecordingPurpose? purpose;
  bool active = true;
  PartPreparation preparation = PartPreparation.waiting;
  String? ogg,
      asrOgg,
      playable,
      transcriptKey,
      message,
      contextSha,
      oggSha,
      asrOggSha;
  int? samples48, leadSamples48, offsetSamples48;
  ProcessingPart(this.sn, this.session, this.source, {this.purpose});
  String get id => '$sn:$session:${source.part}:${source.sha256}';
  String get positionKey => '$sn:$session:${source.part}';
  String get sessionId => sessionKey(sn, session);
  int? get durationMs => samples48 == null ? null : samples48! * 1000 ~/ 48000;
  int? get offsetMs =>
      offsetSamples48 == null ? null : offsetSamples48! * 1000 ~/ 48000;
  bool get ready =>
      preparation == PartPreparation.ready &&
      ogg != null &&
      asrOgg != null &&
      samples48 != null;
  Map<String, dynamic> toJson() => {
        'sn': sn,
        'session': session,
        'part': source.part,
        'size': source.size,
        'sha': source.sha256,
        'source': source.relativePath,
        'purpose': purpose?.name,
        'active': active,
        'preparation': preparation.name,
        'ogg': ogg,
        'asrOgg': asrOgg,
        'playable': playable,
        'samples48': samples48,
        'lead48': leadSamples48,
        'offset48': offsetSamples48,
        'transcript': transcriptKey,
        'message': message,
        'contextSha': contextSha,
        'oggSha': oggSha,
        'asrOggSha': asrOggSha
      };
  factory ProcessingPart.fromJson(Map<String, dynamic> v) {
    validateIdentity(v['sn'], v['session']);
    if (v['part'] is! int ||
        v['part'] < 0 ||
        v['part'] >= 10000 ||
        v['size'] is! int ||
        v['size'] <= 0 ||
        v['size'] > 256 * 1024 * 1024 ||
        v['sha'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(v['sha']))
      throw const FormatException('片段来源无效');
    final source = RecorderCommittedSegment(
        part: v['part'],
        size: v['size'],
        sha256: v['sha'],
        relativePath: v['source']);
    if (source.relativePath !=
        'recorder_long_audio_v1/${v['sn']}/s${v['session']}/p${source.part}-${source.sha256}.ops')
      throw const FormatException('片段路径不匹配');
    final r = ProcessingPart(v['sn'], v['session'], source,
        purpose: v['purpose'] == null
            ? null
            : LongRecordingPurpose.values.byName(v['purpose']));
    if (v['active'] is! bool) throw const FormatException('片段版本标记无效');
    r.active = v['active'];
    r.preparation = PartPreparation.values.byName(v['preparation']);
    for (final field in ['ogg', 'asrOgg', 'playable']) {
      final path = v[field];
      if (path != null &&
          (path is! String ||
              !path.startsWith(
                  'recorder_long_audio_v1/${r.sn}/s${r.session}/') ||
              path.split('/').length != 4 ||
              path.split('/').any((p) =>
                  !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(p) ||
                  p == '.' ||
                  p == '..'))) throw const FormatException('片段输出路径无效');
    }
    for (final field in ['samples48', 'lead48', 'offset48']) {
      if (v[field] != null &&
          (v[field] is! int || v[field] < 0 || v[field] > 192000000000))
        throw const FormatException('片段时间无效');
    }
    if (v['transcript'] != null &&
        (v['transcript'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(v['transcript'])))
      throw const FormatException('转写索引无效');
    for (final field in ['contextSha', 'oggSha', 'asrOggSha']) {
      if (v[field] != null &&
          (v[field] is! String ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(v[field])))
        throw const FormatException('派生指纹无效');
    }
    r.contextSha = v['contextSha'];
    r.oggSha = v['oggSha'];
    r.asrOggSha = v['asrOggSha'];
    r.ogg = v['ogg'];
    r.asrOgg = v['asrOgg'];
    r.playable = v['playable'];
    r.samples48 = v['samples48'];
    r.leadSamples48 = v['lead48'];
    r.offsetSamples48 = v['offset48'];
    r.transcriptKey = v['transcript'];
    r.message = v['message'];
    if (r.ready &&
        (r.samples48! <= 0 ||
            r.samples48! % 3 != 0 ||
            r.oggSha == null ||
            r.asrOggSha == null ||
            r.leadSamples48 == null ||
            r.leadSamples48! > 65535)) throw const FormatException('分段封装证据不完整');
    return r;
  }
}

enum TranscriptionStage {
  queued,
  preparing,
  submitting,
  submissionUnknown,
  polling,
  queryNeeded,
  complete,
  failed
}

class PartTranscript {
  final String id, partId;
  TranscriptionStage stage = TranscriptionStage.queued;
  String? job, serverFingerprint;
  String text = '';
  List<DiarizedSegment> spans = [];
  bool manual = false;
  String? message;
  PartTranscript(this.id, this.partId, {this.manual = false});
  String get stageLabel => switch (stage) {
        TranscriptionStage.queued => '等待转写',
        TranscriptionStage.preparing => '准备转写音频',
        TranscriptionStage.submitting => '正在提交ASR',
        TranscriptionStage.submissionUnknown => '提交结果不确定，请确认后重试',
        TranscriptionStage.polling => '正在转写',
        TranscriptionStage.queryNeeded => '保留任务，可继续查询',
        TranscriptionStage.complete => '转写已保存',
        TranscriptionStage.failed => '转写未完成，可重试'
      };
  Map<String, dynamic> toJson() => {
        'partId': partId,
        'stage': stage.name,
        'job': job,
        'serverFingerprint': serverFingerprint,
        'text': text,
        'manual': manual,
        'message': message,
        'spans': [
          for (final s in spans)
            {
              'speaker': s.speaker,
              'start': s.start,
              'end': s.end,
              'text': s.text
            }
        ]
      };
  factory PartTranscript.fromJson(Map<String, dynamic> v) {
    if (v['id'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(v['id']) ||
        v['partId'] is! String ||
        v['text'] is! String ||
        v['text'].length > 500000 ||
        v['manual'] is! bool ||
        v['spans'] is! List ||
        v['spans'].length > 20000 ||
        v['job'] != null &&
            (v['job'] is! String ||
                !RegExp(r'^[A-Za-z0-9_.-]{1,255}$').hasMatch(v['job'])))
      throw const FormatException('转写结果无效');
    final r = PartTranscript(v['id'], v['partId'], manual: v['manual']);
    r.stage = TranscriptionStage.values.byName(v['stage']);
    r.job = v['job'];
    if (v['serverFingerprint'] != null &&
        (v['serverFingerprint'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(v['serverFingerprint'])))
      throw const FormatException('ASR任务来源无效');
    r.serverFingerprint = v['serverFingerprint'];
    r.text = v['text'];
    r.message = v['message'];
    for (final raw in v['spans']) {
      if (raw is! Map<String, dynamic> ||
          raw['start'] is! num ||
          raw['end'] is! num ||
          raw['text'] is! String ||
          raw['speaker'] is! String ||
          !(raw['start'] as num).isFinite ||
          !(raw['end'] as num).isFinite ||
          raw['start'] < 0 ||
          raw['end'] < raw['start']) throw const FormatException('转写时间段无效');
      r.spans.add(DiarizedSegment.fromJson(raw));
    }
    if (r.stage == TranscriptionStage.submitting)
      r.stage = r.job == null
          ? TranscriptionStage.submissionUnknown
          : TranscriptionStage.queryNeeded;
    else if (r.stage == TranscriptionStage.polling ||
        r.stage == TranscriptionStage.queryNeeded)
      r.stage = r.job == null
          ? TranscriptionStage.submissionUnknown
          : TranscriptionStage.queryNeeded;
    else if (r.stage == TranscriptionStage.preparing)
      r.stage = TranscriptionStage.queued;
    return r;
  }
}

class SavedRecordingSummary {
  final String id, kind, scope, inputFingerprint, text;
  final bool serverOrigin;
  final DateTime created;
  final bool partial;
  final DateTime? from, to;
  final List<String> inputIds;
  final Map<String, String> sourceVersions;
  SavedRecordingSummary(
      {required this.id,
      required this.kind,
      required this.scope,
      required this.inputFingerprint,
      required this.text,
      required this.created,
      required this.inputIds,
      this.sourceVersions = const {},
      this.serverOrigin = false,
      this.partial = false,
      this.from,
      this.to});
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'scope': scope,
        'inputFingerprint': inputFingerprint,
        'text': text,
        'created': created.toUtc().toIso8601String(),
        'partial': partial,
        'from': from?.toUtc().toIso8601String(),
        'to': to?.toUtc().toIso8601String(),
        'inputIds': inputIds,
        'sourceVersions': sourceVersions,
        'serverOrigin': serverOrigin,
      };
  factory SavedRecordingSummary.fromJson(Map<String, dynamic> v) {
    final versions = Map<String, String>.from(v['sourceVersions'] ?? {});
    if (versions.length > 100000 ||
        versions.entries.any((e) =>
            e.key.length > 1100 ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(e.value)))
      throw const FormatException('总结来源版本无效');
    if (!['meeting', 'lifelog', 'intermediate', 'notification']
            .contains(v['kind']) ||
        v['text'] is! String ||
        v['text'].length > 500000 ||
        v['scope'] is! String ||
        v['inputFingerprint'] is! String ||
        v['partial'] is! bool ||
        v['inputIds'] is! List ||
        v['inputIds'].length > 100000 ||
        v['inputIds'].any((id) => id is! String))
      throw const FormatException('总结记录无效');
    if (v['kind'] == 'notification') {
      if (v['id'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(v['id']) ||
          v['inputFingerprint'] != v['id'] ||
          v['from'] is! String ||
          v['to'] is! String ||
          v['inputIds'].isEmpty ||
          v['inputIds'].length > 5000 ||
          v['inputIds'].toSet().length != v['inputIds'].length ||
          v['inputIds'].any((id) => id.isEmpty || id.length > 1024))
        throw const FormatException('通知简报来源无效');
      final start = DateTime.parse(v['from']), end = DateTime.parse(v['to']);
      if (!end.isAfter(start) ||
          end.difference(start) > const Duration(days: 31))
        throw const FormatException('通知简报范围无效');
    }
    return SavedRecordingSummary(
        id: v['id'],
        kind: v['kind'],
        scope: v['scope'],
        inputFingerprint: v['inputFingerprint'],
        text: v['text'],
        created: DateTime.parse(v['created']),
        inputIds: List<String>.from(v['inputIds']),
        sourceVersions: versions,
        serverOrigin: v['serverOrigin'] == true,
        partial: v['partial'],
        from: v['from'] == null ? null : DateTime.parse(v['from']),
        to: v['to'] == null ? null : DateTime.parse(v['to']));
  }
}

void validateIdentity(dynamic sn, dynamic session) {
  if (!RecorderLongSession.validSerial(sn) ||
      session is! int ||
      session <= 0 ||
      session > 0x7fffffffffffffff) throw const FormatException('录音身份无效');
}

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../ai/agent_client.dart';
import '../ai/asr_service.dart';
import '../audio/recorder_local_audio.dart';
import '../hardware/recorder_long_file_store.dart';
import '../hardware/recorder_long_recordings.dart';
import '../../models/timeline_entry.dart';
import 'local_content_store.dart';
import 'recording_processing_models.dart';
import 'notification_digest_models.dart';
import '../sync/archive_models.dart';
import '../sync/archive_projection.dart';
part 'notification_digest_processing.dart';

class RecordingProcessingException implements Exception {
  final String message;
  const RecordingProcessingException(this.message);
  @override
  String toString() => message;
}

/// 只处理已经安全提交的本机源段；不持有BLE命令、厂商账号或业务密钥。
class RecordingProcessingController extends ChangeNotifier {
  final RecordingContentStore content;
  final RecorderLongFileStore audioStore;
  final RecorderLocalAudio audio;
  final AsrService Function() asr;
  final AgentClient Function() agent;
  final ArchiveReferenceResolver? archive;
  final bool Function(String appId) allowsNotification;
  final Map<String, ProcessingSession> _sessions = {};
  final Map<String, ProcessingPart> _parts = {};
  final Map<String, PartTranscript> _transcripts = {};
  final Map<String, SavedRecordingSummary> _summaries = {};
  final Map<String, TimelineEntry> _entries = {};
  final Set<String> _hidden = {};
  final Map<String, NotificationDigestJob> _notificationJobs = {};
  final Map<String, Future<NotificationDigestJob>> _notificationEnqueues = {};
  Future<void>? _notificationRun;
  final DateTime Function() notificationClock;
  ProcessingPolicy policy = const ProcessingPolicy();
  late final Future<void> ready;
  bool loaded = false, foreground = true, disposed = false;
  String? message;
  Future<void> _local = Future<void>.value();
  Future<void>? _asrRun, _summaryRun;
  final Map<String, Future<SavedRecordingSummary>> _summaryRequests = {};
  final Set<String> _autoAttempted = {};
  int _requestGeneration = 0, _notificationPolicyGeneration = 0;
  Future<SavedRecordingSummary> _once(
      String key, Future<SavedRecordingSummary> Function() work) async {
    final existing = _summaryRequests[key];
    if (existing != null) return existing;
    final task = work();
    _summaryRequests[key] = task;
    try {
      return await task;
    } finally {
      _summaryRequests.remove(key);
    }
  }

  bool get transcribing => _asrRun != null;
  List<ProcessingSession> get sessions =>
      _sessions.values.toList()..sort((a, b) => b.session.compareTo(a.session));
  List<SavedRecordingSummary> get summaries => _summaries.values.toList()
    ..sort((a, b) => b.created.compareTo(a.created));
  List<ProcessingPart> partsOf(String session) =>
      _parts.values.where((p) => p.active && p.sessionId == session).toList()
        ..sort((a, b) => a.source.part.compareTo(b.source.part));
  PartTranscript? transcript(ProcessingPart part) =>
      _transcripts[part.transcriptKey];
  ProcessingSession? session(String id) => _sessions[id];
  RecordingProcessingController(
      {required this.content,
      required this.audioStore,
      required this.audio,
      required this.asr,
      required this.agent,
      this.archive,
      bool Function(String)? allowsNotification,
      DateTime Function()? notificationClock})
      : notificationClock = notificationClock ?? DateTime.now,
        allowsNotification = allowsNotification ?? ((_) => true) {
    ready = _load();
  }
  void _changed() {
    if (!disposed) notifyListeners();
  }

  Future<Map<String, String>> _summarySourceVersions(Set<String> ids) async => {
        for (final source in await projectArchive(content, allowsNotification))
          if (source.visible && source.aliases.any(ids.contains))
            source.id: await source.sha
      };

  Future<void> _saveSession(ProcessingSession s) =>
      content.put('sessions', s.id, s.toJson());
  Future<void> _savePart(ProcessingPart p) =>
      content.put('parts', p.id, p.toJson());
  Future<void> _saveTranscript(PartTranscript t) =>
      content.put('transcripts', t.id, t.toJson());
  void _require() {
    if (!loaded || disposed)
      throw const RecordingProcessingException('本机结果尚未成功读取，未覆盖旧资料。');
  }

  Future<void> _load() async {
    try {
      final settings = await content.readAll('settings');
      if (settings.isNotEmpty) {
        if (settings.length != 1 ||
            settings.single['id'] != 'processing-policy')
          throw const FormatException();
        policy = ProcessingPolicy.fromJson(settings.single);
      }
      for (final value in await content.readAll('sessions')) {
        final s = ProcessingSession.fromJson(value);
        if (value['id'] != s.id) throw const FormatException();
        _sessions[s.id] = s;
      }
      for (final value in await content.readAll('parts')) {
        final p = ProcessingPart.fromJson(value);
        if (value['id'] != p.id) throw const FormatException();
        _parts[p.id] = p;
      }
      final positions = <String>{};
      for (final p in _parts.values.where((p) => p.active)) {
        if (!positions.add(p.positionKey))
          throw const FormatException('同一片段存在冲突活动版本');
      }
      for (final value in await content.readAll('transcripts')) {
        final t = PartTranscript.fromJson(value);
        _transcripts[t.id] = t;
      }
      for (final p in _parts.values) {
        if (!_sessions.containsKey(p.sessionId))
          throw const FormatException('片段会话缺失');
        if (p.transcriptKey != null) {
          final t = _transcripts[p.transcriptKey];
          if (t == null ||
              t.partId != p.id ||
              t.id !=
                  await contentFingerprint([p.id, p.asrOgg, 'moss-diarize-v1']))
            throw const FormatException('转写来源不匹配');
          if (t.spans
              .any((v) => p.samples48 == null || v.end > p.samples48! / 48000))
            throw const FormatException('转写时间超出片段');
        }
      }
      for (final value in await content.readAll('summaries')) {
        final s = SavedRecordingSummary.fromJson(value);
        _summaries[s.id] = s;
      }
      for (final category in ['notifications', 'notes']) {
        for (final value in await content.readAll(category)) {
          final e = TimelineEntry.fromJson(value);
          _entries[e.id] = e;
        }
      }
      for (final value in await content.readAll('attempts')) {
        if (value['id'] is! String) throw const FormatException();
        _autoAttempted.add(value['id']);
      }
      for (final value in await content.readAll('hidden'))
        _hidden.add(value['id']);
      await _loadNotificationJobs();
      loaded = true;
      message = null;
    } catch (_) {
      loaded = false;
      message = '本机分段或结果库读取失败，原文件保留；请检查存储后重新打开。';
    }
    _changed();
  }

  Future<bool> setPolicy(ProcessingPolicy next) async {
    await ready;
    try {
      _require();
      if (next.meetingSummary && !next.meetingTranscribe)
        throw const FormatException();
      await content.put('settings', 'processing-policy', next.toJson());
      final stored = await content.readAll('settings');
      if (stored.length != 1 ||
          await contentFingerprint(
                  ProcessingPolicy.fromJson(stored.single).toJson()) !=
              await contentFingerprint(next.toJson()))
        throw const FormatException();
      policy = next;
      message = null;
      _changed();
      return true;
    } catch (_) {
      message = '自动处理设置未确认保存；原选择保留。';
      _changed();
      return false;
    }
  }

  Future<void> _queueLocal(Future<void> Function() work) {
    final task = _local.then((_) async {
      await ready;
      _require();
      if (!disposed) await work();
    });
    _local = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  Future<void> accept(RecordingSegmentSignal signal) => _queueLocal(() async {
        validateIdentity(signal.sn, signal.session);
        final id = sessionKey(signal.sn, signal.session);
        final s = _sessions.putIfAbsent(
            id,
            () => ProcessingSession(signal.sn, signal.session,
                purpose: signal.purpose));
        s.purpose = signal.purpose ?? s.purpose;
        if (signal.kind == SegmentSignalKind.started) {
          s.startedPolicy ??= policy;
          s.observedStart ??= signal.observed;
          s.complete = false;
        }
        if (signal.kind == SegmentSignalKind.uncertain)
          s.timingUncertain = true;
        s.automaticTranscribe = s.startedPolicy?.transcribe(s.purpose) ?? false;
        s.automaticSummary = s.purpose == LongRecordingPurpose.meeting &&
            (s.startedPolicy?.meetingSummary ?? false);
        if (signal.kind == SegmentSignalKind.source) {
          final source = signal.source!;
          await audioStore.validateSegment(signal.sn, signal.session, source);
          final candidate = ProcessingPart(signal.sn, signal.session, source,
              purpose: s.purpose);
          final existing = _parts[candidate.id];
          for (final p in _parts.values.where((p) =>
              p.active &&
              p.positionKey == candidate.positionKey &&
              p.id != candidate.id)) {
            p.active = false;
            await _savePart(p);
            s.complete = false;
          }
          final part = existing ?? candidate;
          part.active = true;
          part.purpose = s.purpose;
          _parts[part.id] = part;
          if (existing == null) s.complete = false;
          await _savePart(part);
        }
        if (signal.kind == SegmentSignalKind.finalized) {
          s.totalParts = signal.totalParts;
          s.observedEnd = signal.observed;
          s.complete = true;
        }
        for (final part in partsOf(s.id)) {
          if (part.purpose != s.purpose) {
            part.purpose = s.purpose;
            await _savePart(part);
          }
        }
        await _saveSession(s);
        await _preparePending(s);
        await _recalculate(s);
        _changed();
        if (foreground) _resumeQuietly();
      }).catchError((Object _) {
        message = '分段处理已暂停，源音频和已有结果保留，请检查本机存储。';
        _changed();
      });

  Future<void> _preparePending(ProcessingSession s) async {
    final parts = partsOf(s.id);
    for (final p in parts) {
      final previous =
          parts.where((v) => v.source.part == p.source.part - 1).firstOrNull;
      if (p.ready &&
          p.oggSha != null &&
          p.asrOggSha != null &&
          (p.source.part == 0 || p.contextSha == previous?.source.sha256))
        continue;
      if (p.source.part > 0 && previous == null) {
        p.message = '等待前段解码上下文';
        await _savePart(p);
        continue;
      }
      try {
        final prepared = await audioStore.prepareSegment(
            p.sn, p.session, p.source,
            previous: previous?.source);
        final changed = p.ogg != prepared.relativePath;
        p.ogg = prepared.relativePath;
        p.asrOgg = prepared.asrRelativePath;
        p.samples48 = prepared.samples48;
        p.leadSamples48 = prepared.leadSamples48;
        p.contextSha = previous?.source.sha256;
        p.oggSha = prepared.sha256;
        p.asrOggSha = prepared.asrSha256;
        p.preparation = PartPreparation.ready;
        p.message = null;
        if (changed) p.transcriptKey = null;
        await _savePart(p);
      } catch (_) {
        p.preparation = PartPreparation.failed;
        p.message = '分段封装未完成，源音频保留，可重试。';
        await _savePart(p);
      }
    }
    if (s.automaticTranscribe && policy.transcribe(s.purpose)) {
      for (final p in parts.where((p) => p.ready))
        await _request(p, manual: false);
    }
  }

  Future<void> _recalculate(ProcessingSession s) async {
    int? offset = 0;
    var expected = 0;
    for (final p in partsOf(s.id)) {
      if (p.source.part != expected || p.samples48 == null) offset = null;
      final changed = p.offsetSamples48 != offset;
      p.offsetSamples48 = offset;
      if (offset != null) offset += p.samples48!;
      expected = p.source.part + 1;
      if (changed) await _savePart(p);
    }
  }

  /// 只导入已经提交且无版本歧义的旧OPS；旧整场音频不做覆盖迁移。
  Future<void> importExisting() async {
    await ready;
    if (!loaded || disposed) return;
    try {
      for (final record in await audioStore.loadRecords()) {
        final sources = await audioStore.discoverSegments(
            record.serialNumber, record.sessionId);
        for (final source in sources) {
          if (_parts.values.any((p) =>
              p.active &&
              p.sn == record.serialNumber &&
              p.session == record.sessionId &&
              p.source.part == source.part)) continue;
          await accept(RecordingSegmentSignal(
              SegmentSignalKind.source, record.serialNumber, record.sessionId,
              purpose: record.purpose, source: source));
        }
        if (record.canPlay &&
            sources.length == record.totalParts &&
            List.generate(sources.length, (i) => sources[i].part == i)
                .every((v) => v)) {
          await accept(RecordingSegmentSignal(SegmentSignalKind.finalized,
              record.serialNumber, record.sessionId,
              purpose: record.purpose, totalParts: record.totalParts));
        }
      }
    } catch (_) {
      message = '部分旧录音暂未完成分段索引；旧整场录音仍可从文件页查看。';
      _changed();
    }
  }

  DateTime? absoluteStart(ProcessingPart part) {
    final anchor = _sessions[part.sessionId]?.estimatedAnchor;
    return anchor == null || part.offsetMs == null
        ? null
        : anchor.add(Duration(milliseconds: part.offsetMs!));
  }

  DateTime? absoluteEnd(ProcessingPart p) =>
      absoluteStart(p)?.add(Duration(milliseconds: p.durationMs ?? 0));
  String timingLabel(ProcessingPart p) =>
      absoluteStart(p) == null ? '绝对时间待定位；保留录音相对顺序' : '连续录音时间估算';

  Future<PreparedRecorderAudio> preparePlayback(ProcessingPart p) async {
    await ready;
    await _local;
    _require();
    if (!p.ready || !p.active)
      throw const RecordingProcessingException('片段尚未封装完整。');
    await audioStore.validateSegment(p.sn, p.session, p.source);
    await audioStore.validateDerived(p.ogg!, p.oggSha);
    final prepared = await audio.prepare(p.ogg!);
    if (prepared.durationMs != p.durationMs ||
        prepared.frames != p.samples48! ~/ 3 ||
        !prepared.relativePath
            .startsWith('recorder_long_audio_v1/${p.sn}/s${p.session}/'))
      throw const RecordingProcessingException('片段解码回执与源音频不一致。');
    final file = await audioStore.resolveRelative(prepared.relativePath);
    if (!await file.exists() || await file.length() <= 44)
      throw const RecordingProcessingException('片段播放文件缺失。');
    p.playable = prepared.relativePath;
    await _savePart(p);
    _changed();
    return prepared;
  }

  Future<void> _request(ProcessingPart p, {required bool manual}) async {
    if (!p.ready || !p.active) return;
    final id = await contentFingerprint([p.id, p.asrOgg, 'moss-diarize-v1']);
    var t = _transcripts[id];
    if (t == null) {
      t = PartTranscript(id, p.id, manual: manual);
      _transcripts[id] = t;
      await _saveTranscript(t);
    } else if (manual) {
      t.manual = true;
      await _saveTranscript(t);
    }
    if (p.transcriptKey == id) return;
    p.transcriptKey = id;
    ++_requestGeneration;
    await _savePart(p);
  }

  Future<bool> transcribePart(ProcessingPart p,
      {bool confirmResubmit = false}) async {
    await ready;
    await _local;
    _require();
    if (!p.ready) {
      await _queueLocal(() async {
        final s = _sessions[p.sessionId];
        if (s != null) {
          await _preparePending(s);
          await _recalculate(s);
        }
      });
    }
    if (!p.ready)
      throw const RecordingProcessingException('片段未准备好，先补齐前段或检查封装。');
    await _request(p, manual: true);
    ++_requestGeneration;
    final t = transcript(p)!;
    if (t.stage == TranscriptionStage.submissionUnknown) {
      if (!confirmResubmit)
        throw const RecordingProcessingException(
            '上次提交结果不确定；需明确确认后才能再次上传，可能产生重复任务。');
      t.stage = TranscriptionStage.queued;
      await _saveTranscript(t);
    } else if (t.stage == TranscriptionStage.failed) {
      t.stage = TranscriptionStage.queued;
      await _saveTranscript(t);
    }
    await resume();
    return t.stage == TranscriptionStage.complete;
  }

  void setForeground(bool active) {
    foreground = active;
    if (active && !disposed) {
      _resumeQuietly();
      unawaited(processNotificationQueue());
    }
  }

  void _resumeQuietly() {
    unawaited(resume().catchError((Object _) {
      message = '本机处理暂未完成，已有音频与结果保留。';
      _changed();
    }));
  }

  Future<void> resume() async {
    await ready;
    await _local;
    if (!loaded || disposed || !foreground) return;
    unawaited(processNotificationQueue());
    if (_asrRun != null) return _asrRun;
    final completed = Completer<void>();
    _asrRun = completed.future;
    try {
      int generation;
      do {
        generation = _requestGeneration;
        await _drainAsr();
        if (!disposed) await _maybeAutoSummaries();
      } while (!disposed &&
          foreground &&
          generation != _requestGeneration &&
          _transcripts.values.any((t) => t.stage == TranscriptionStage.queued));
      completed.complete();
    } catch (error, stack) {
      completed.completeError(error, stack);
    } finally {
      _asrRun = null;
      _changed();
    }
    return completed.future;
  }

  Future<void> _drainAsr() async {
    final attempted = <String>{};
    while (true) {
      final waiting =
          _transcripts.values.where((t) => !attempted.contains(t.id)).toList();
      if (waiting.isEmpty) return;
      final t = waiting.first;
      attempted.add(t.id);
      if (disposed || !foreground) return;
      final p = _parts[t.partId];
      if (p == null ||
          !p.active ||
          p.transcriptKey != t.id ||
          !p.ready ||
          t.stage == TranscriptionStage.complete ||
          t.stage == TranscriptionStage.submissionUnknown ||
          t.stage == TranscriptionStage.failed) continue;
      final s = _sessions[p.sessionId];
      if (t.job == null &&
          !t.manual &&
          !(s?.automaticTranscribe == true && policy.transcribe(s?.purpose)))
        continue;

      try {
        final service = asr();
        final sourcePath = p.asrOgg!;
        final server = await contentFingerprint(
            service.serverBaseUrl.replaceAll(RegExp(r'/+$'), ''));
        if (t.job != null && t.serverFingerprint != server) {
          t.message = 'ASR节点已变化，保留原任务；请切回原节点继续查询。';
          await _saveTranscript(t);
          continue;
        }
        if (t.job == null) {
          t.stage = TranscriptionStage.preparing;
          await _saveTranscript(t);
          _changed();
          await audioStore.validateSegment(p.sn, p.session, p.source);
          await audioStore.validateDerived(p.asrOgg!, p.asrOggSha);
          final prepared = await audio.prepare(sourcePath);
          if (prepared.frames != (p.samples48! + (p.leadSamples48 ?? 0)) ~/ 3)
            throw const FormatException();
          final file = await audioStore.resolveRelative(prepared.relativePath);
          if (!await file.exists() || await file.length() <= 44)
            throw const FormatException();
          if (disposed || !foreground) {
            t.stage = TranscriptionStage.queued;
            await _saveTranscript(t);
            return;
          }
          if (!p.active || p.transcriptKey != t.id || p.asrOgg != sourcePath)
            continue;
          t.serverFingerprint = server;
          t.stage = TranscriptionStage.submitting;
          await _saveTranscript(t);
          _changed();
          final job = await service.submitJobFile(file.path,
              filename: 'part_${p.source.part}.wav');
          if (job == null ||
              !RegExp(r'^[A-Za-z0-9_.-]{1,255}$').hasMatch(job)) {
            t.stage = TranscriptionStage.submissionUnknown;
            t.message = '无法确认ASR是否接收，请确认后重试；未自动重复上传。';
            await _saveTranscript(t);
            _changed();
            return;
          }
          t.job = job;
          await _saveTranscript(t);
        }
        if (disposed) return;
        t.stage = TranscriptionStage.polling;
        await _saveTranscript(t);
        _changed();
        final result = await service.pollJobResult(t.job!);
        if (disposed) return;
        if (!result.success) {
          t.stage = TranscriptionStage.queryNeeded;
          t.message = '尚未取得转写结果，任务ID已保存，可继续查询。';
          await _saveTranscript(t);
          _changed();
          return;
        }
        if (!p.active || p.transcriptKey != t.id || p.asrOgg != sourcePath) {
          t.stage = TranscriptionStage.failed;
          t.message = '源音频版本已变化，旧任务资料保留，不用于当前片段。';
          await _saveTranscript(t);
          continue;
        }
        _applyResult(p, t, result);
        await _saveTranscript(t);
        _changed();
      } catch (_) {
        if (disposed) return;
        t.stage = t.job != null
            ? TranscriptionStage.queryNeeded
            : t.stage == TranscriptionStage.submitting
                ? TranscriptionStage.submissionUnknown
                : TranscriptionStage.failed;
        t.message = '分段转写未完成，音频与任务资料保留，请检查私有ASR或本机存储。';
        try {
          await _saveTranscript(t);
        } catch (_) {
          message = '转写状态暂未安全保存；请检查本机存储。';
        }
        _changed();
        return;
      }
    }
  }

  void _applyResult(ProcessingPart p, PartTranscript t, AsrResult result) {
    if (result.rawText.length > 500000 || result.segments.length > 20000)
      throw const FormatException();
    final lead = (p.leadSamples48 ?? 0) / 48000;
    final duration = p.samples48! / 48000;
    final spans = <DiarizedSegment>[];
    for (final span in result.segments) {
      if (!span.start.isFinite ||
          !span.end.isFinite ||
          span.start < 0 ||
          span.end < span.start ||
          span.end > duration + lead + 5) throw const FormatException();
      final start = math.max(0.0, span.start - lead);
      final end = math.min(duration, span.end - lead);
      if (end <= 0 || end < start || span.text.trim().isEmpty) continue;
      spans.add(DiarizedSegment(
          speaker: '段${p.source.part + 1}/${span.speaker}',
          start: start,
          end: end,
          text: span.text));
    }
    // 有时间戳时，仅保留落入本段的文字；纯上下文结果不能回填到当前段。
    String text = result.segments.isNotEmpty
        ? spans.map((s) => s.text).join('\n').trim()
        : result.rawText.trim();
    // 无句级时间戳时无法准确裁掉解码上下文，显式标注整段估算。
    final previous = partsOf(p.sessionId)
        .where((v) => v.source.part == p.source.part - 1)
        .firstOrNull;
    final before = previous == null ? '' : transcript(previous)?.text ?? '';
    var removed = 0;
    if (before.isNotEmpty && text.isNotEmpty && lead > 0) {
      for (var length = math.min(120, math.min(before.length, text.length));
          length >= 3;
          length--) {
        if (before.endsWith(text.substring(0, length))) {
          removed = length;
          text = text.substring(length).trimLeft();
          break;
        }
      }
    }
    final cleaned = <DiarizedSegment>[];
    for (final span in spans) {
      final count = math.min(removed, span.text.length);
      final value = span.text.substring(count).trimLeft();
      removed -= count;
      if (removed > 0) removed--; // join分隔符
      if (value.isNotEmpty)
        cleaned.add(DiarizedSegment(
            speaker: span.speaker,
            start: span.start,
            end: span.end,
            text: value));
    }
    t.spans = cleaned;
    t.text = text;
    t.stage = TranscriptionStage.complete;
    t.message = text.isEmpty
        ? '本段未识别到有效语音；结果已保存。'
        : result.segments.isEmpty && lead > 0
            ? 'ASR未返回句级时间，文字可能包含前段边界上下文；仅作整段时间估算。'
            : null;
  }

  List<TimelineEntry> get timelineEntries {
    final entries = <TimelineEntry>[];
    for (final e in _entries.values) {
      if (_hidden.contains(e.id)) continue;
      if (e.sourceType == TimelineSourceType.appNotification &&
          (e.appIdentifier == null || !allowsNotification(e.appIdentifier!)))
        continue;
      entries.add(e);
    }
    for (final p in _parts.values
        .where((p) => p.active && p.purpose == LongRecordingPurpose.lifelog)) {
      final t = transcript(p);
      final start = absoluteStart(p);
      if (t?.stage != TranscriptionStage.complete ||
          start == null ||
          t!.text.isEmpty) continue;
      if (t.spans.isNotEmpty) {
        for (var i = 0; i < t.spans.length; i++) {
          final span = t.spans[i];
          final id = 'segment_${t.id}_$i';
          if (!_hidden.contains(id))
            entries.add(TimelineEntry(
                id: id,
                timestamp: start
                    .add(Duration(milliseconds: (span.start * 1000).round())),
                endTimestamp: start
                    .add(Duration(milliseconds: (span.end * 1000).round())),
                sourceType: TimelineSourceType.audioVoice,
                sourceApp: '随身录音 · ${span.speaker}',
                content: span.text,
                tags: '时间估算',
                recordingPartId: p.id));
        }
      } else {
        final id = 'segment_${t.id}';
        if (!_hidden.contains(id))
          entries.add(TimelineEntry(
              id: id,
              timestamp: start,
              endTimestamp: absoluteEnd(p),
              sourceType: TimelineSourceType.audioVoice,
              sourceApp: '随身录音',
              content: t.text,
              tags: '整段时间估算',
              recordingPartId: p.id));
      }
    }
    return entries..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  Future<void> addTimelineEntry(TimelineEntry e) async {
    await ready;
    _require();
    if (e.sourceType == TimelineSourceType.appNotification &&
        (e.appIdentifier == null || !allowsNotification(e.appIdentifier!)))
      return;
    await content.put(
        e.sourceType == TimelineSourceType.appNotification
            ? 'notifications'
            : 'notes',
        e.id,
        e.toJson());
    _entries[e.id] = e;
    _changed();
  }

  Future<void> hideTimelineEntry(String id) async {
    await ready;
    _require();
    await content.put('hidden', id, {});
    _hidden.add(id);
    _changed();
  }

  void notificationPolicyChanged() {
    _notificationPolicyGeneration++;
    _changed();
  }

  Future<void> _ensureParts(List<ProcessingPart> parts) async {
    for (final p in parts) {
      if (!p.ready)
        throw const RecordingProcessingException('所选内容有未封装或缺少上下文的片段，请先恢复音频。');
      if (transcript(p)?.stage != TranscriptionStage.complete)
        await _request(p, manual: true);
    }
    await resume();
    if (parts.any((p) => transcript(p)?.stage != TranscriptionStage.complete))
      throw const RecordingProcessingException(
          '所选录音尚未全部转写完成；已完成结果保留，可继续查询后生成总结。');
  }

  bool sessionComplete(ProcessingSession s) {
    final parts = partsOf(s.id);
    return s.complete &&
        s.totalParts != null &&
        parts.length == s.totalParts &&
        List.generate(parts.length,
            (i) => parts[i].source.part == i && parts[i].ready).every((v) => v);
  }

  /// 此入口只主动请求转写；已有自动纪要许可仍由原队列处理。
  Future<void> transcribeMeeting(String id) async {
    await ready;
    await _local;
    _require();
    final s = _sessions[id];
    if (s == null ||
        s.purpose != LongRecordingPurpose.meeting ||
        !sessionComplete(s)) {
      throw const RecordingProcessingException('会议尚未完整归档，请先补齐音频再转写整场。');
    }
    await _ensureParts(partsOf(id));
  }

  Future<SavedRecordingSummary> summarizeMeeting(String id,
          {bool automatic = false}) =>
      _once('meeting:$id', () => _summarizeMeeting(id, automatic: automatic));
  Future<SavedRecordingSummary> _summarizeMeeting(String id,
      {bool automatic = false}) async {
    await ready;
    await _local;
    _require();
    final s = _sessions[id];
    if (s == null ||
        s.purpose != LongRecordingPurpose.meeting ||
        !sessionComplete(s))
      throw const RecordingProcessingException('会议尚未停止并完成尾段归档，不能生成整场纪要。');
    final parts = partsOf(id);
    if (!automatic) await _ensureParts(parts);
    if (parts.any((p) => transcript(p)?.stage != TranscriptionStage.complete))
      throw const RecordingProcessingException('会议仍有待转写片段。');
    final raw = parts
        .map((p) => '[片段${p.source.part + 1}]\n${transcript(p)!.text}')
        .join('\n');
    final fingerprint = await contentFingerprint([
      id,
      [
        for (final p in parts)
          [
            p.id,
            p.offsetMs,
            transcript(p)!.text,
            [
              for (final span in transcript(p)!.spans)
                [span.start, span.end, span.speaker, span.text]
            ]
          ]
      ],
      'meeting-v1'
    ]);
    if (raw.trim().isEmpty ||
        parts.every((p) => transcript(p)!.text.trim().isEmpty))
      throw const RecordingProcessingException('会议录音未识别到有效语音，未生成纪要。');
    final existing = _summaries[fingerprint];
    if (existing != null) return existing;
    final sourceVersions =
        await _summarySourceVersions(parts.map((p) => p.id).toSet());
    String text;
    final sourceIds = parts.map((p) => p.id).toSet();
    ArchiveReferences? archived;
    if (archive?.referenceEnabled ?? false) {
      archived = automatic && !archive!.automaticMeetingSync
          ? await archive!.existingReferences(sourceIds)
          : await archive!.ensureReferences(sourceIds);
    }
    if (archived != null) {
      text =
          await agent().summarizeArchiveReferences(archived, task: 'meeting');
    } else {
      final reduced = await _reduceInputs([
        for (final p in parts)
          '[片段${p.source.part + 1}, 相对${p.offsetMs}ms；${timingLabel(p)}]\n${transcript(p)!.spans.isEmpty ? transcript(p)!.text : transcript(p)!.spans.map((v) => "[${v.start}-${v.end}s ${v.speaker}] ${v.text}").join("\n")}\n${transcript(p)!.message ?? ""}'
      ], 'meeting');
      final result = await agent().summarizeMeetingWithDiarization(
          segments: const [],
          rawText:
              '以下是同一场会议各段；段内说话人编号不代表跨段同一人，不确定时间只作相对顺序。\n${reduced.join('\n')}');
      final value = result['summary'];
      if (value is! String || value.trim().isEmpty)
        throw const RecordingProcessingException('未收到完整会议纪要。');
      text = value;
    }
    final saved = SavedRecordingSummary(
        id: fingerprint,
        kind: 'meeting',
        scope: id,
        inputFingerprint: fingerprint,
        text: text,
        created: DateTime.now(),
        inputIds: parts.map((p) => p.id).toList(),
        sourceVersions: sourceVersions);
    await content.put('summaries', saved.id, saved.toJson());
    _summaries[saved.id] = saved;
    _changed();
    return saved;
  }

  Future<void> _maybeAutoSummaries() async {
    if (_summaryRun != null || disposed || !foreground) return;
    final work = () async {
      for (final s in sessions) {
        if (disposed || !foreground) return;
        if (_summaryRequests.containsKey('meeting:${s.id}') ||
            !s.automaticSummary ||
            !policy.meetingSummary ||
            !sessionComplete(s) ||
            partsOf(s.id).any(
                (p) => transcript(p)?.stage != TranscriptionStage.complete))
          continue;
        try {
          final key = await contentFingerprint([
            'auto-meeting',
            s.id,
            [
              for (final p in partsOf(s.id)) [p.id, transcript(p)!.text]
            ]
          ]);
          if (_autoAttempted.contains(key)) continue;
          await content.put('attempts', key, {'scope': s.id});
          _autoAttempted.add(key);
          await summarizeMeeting(s.id, automatic: true);
        } catch (_) {
          message = '会议自动纪要未完成；已有转写保留，可手动重试。';
          _changed();
        }
      }
    }();
    _summaryRun = work;
    try {
      await work;
    } finally {
      _summaryRun = null;
    }
  }

  List<ProcessingPart> partsInRange(DateTime from, DateTime to) => _parts.values
      .where((p) =>
          p.active &&
          p.purpose == LongRecordingPurpose.lifelog &&
          absoluteStart(p) != null &&
          absoluteStart(p)!.isBefore(to) &&
          absoluteEnd(p)!.isAfter(from))
      .toList();
  bool _mayOverlap(ProcessingSession? s, DateTime? from, DateTime? to) {
    if (s == null) return true;
    if (from != null && s.observedEnd != null && !s.observedEnd!.isAfter(from))
      return false;
    final start = s.estimatedAnchor ?? s.observedStart;
    return to == null || start == null || start.isBefore(to);
  }

  int unknownLifelogParts({DateTime? from, DateTime? to}) => _parts.values
      .where((p) =>
          p.active &&
          p.purpose == LongRecordingPurpose.lifelog &&
          absoluteStart(p) == null &&
          _mayOverlap(_sessions[p.sessionId], from, to))
      .length;
  Future<SavedRecordingSummary> summarizeLifelog(DateTime from, DateTime to,
          {bool allowPartial = false}) =>
      _once('lifelog:$from/$to/$allowPartial',
          () => _summarizeLifelog(from, to, allowPartial: allowPartial));
  Future<SavedRecordingSummary> _summarizeLifelog(DateTime from, DateTime to,
      {bool allowPartial = false}) async {
    await ready;
    await _local;
    _require();
    if (!to.isAfter(from) || to.difference(from) > const Duration(days: 31))
      throw const RecordingProcessingException('请选择不超过31天的有效时间范围。');
    final parts = partsInRange(from, to)
      ..sort((a, b) => (a.offsetMs ?? 0).compareTo(b.offsetMs ?? 0));
    final uncertain = unknownLifelogParts(from: from, to: to);
    final active = sessions.any((s) =>
        s.purpose == LongRecordingPurpose.lifelog &&
        !sessionComplete(s) &&
        s.estimatedAnchor != null &&
        s.estimatedAnchor!.isBefore(to) &&
        _mayOverlap(s, from, to));
    if (!allowPartial && (uncertain > 0 || active))
      throw const RecordingProcessingException(
          '存在未定位片段或未完整归档的随身录音；可先补齐，或明确选择仅总结已定位内容。');
    await _ensureParts(parts);
    final notificationEpoch = _notificationPolicyGeneration;
    final entries = timelineEntries
        .where((e) =>
            e.timestamp.isBefore(to) &&
            (e.endTimestamp ?? e.timestamp.add(const Duration(milliseconds: 1)))
                .isAfter(from))
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (entries.isEmpty)
      throw const RecordingProcessingException('所选时间没有可用于复盘的内容。');
    final fingerprint = await contentFingerprint([
      from.toUtc().toIso8601String(),
      to.toUtc().toIso8601String(),
      entries.map((e) => e.toJson()).toList(),
      allowPartial && (uncertain > 0 || active),
      uncertain,
      active,
      'lifelog-v1'
    ]);
    final existing = _summaries[fingerprint];
    if (existing != null) return existing;
    String line(TimelineEntry e) =>
        '[${e.timestamp.toLocal().toIso8601String()}] [${e.sourceApp}] [${e.tags}] ${e.content}';
    final voices = entries
        .where((e) => e.sourceType != TimelineSourceType.appNotification)
        .map(line)
        .toList();
    final sourceVersions =
        await _summarySourceVersions(entries.map((e) => e.id).toSet());
    if (allowPartial && (uncertain > 0 || active))
      voices.insert(0, '[范围说明] 本次仅使用已定位、已关闭的内容；仍有未定位或未完成录音，不代表全量。');
    final text = (archive?.referenceEnabled ?? false)
        ? await agent().summarizeArchiveReferences(
            await archive!.ensureReferences(entries.map((e) => e.id).toSet()),
            task: 'lifelog',
            from: from.toUtc().toIso8601String(),
            to: to.toUtc().toIso8601String(),
            partial: allowPartial && (uncertain > 0 || active))
        : await agent().generateDailyLifelogReview(
            timeBlockEvents: await _reduceInputs(voices, 'lifelog-voice',
                notificationEpoch: notificationEpoch),
            notifications: await _reduceInputs(
                entries
                    .where((e) =>
                        e.sourceType == TimelineSourceType.appNotification)
                    .map(line)
                    .toList(),
                'lifelog-notifications',
                notificationEpoch: notificationEpoch));
    _checkNotificationEpoch(notificationEpoch);
    final saved = SavedRecordingSummary(
        id: fingerprint,
        kind: 'lifelog',
        scope:
            '${from.toUtc().toIso8601String()}/${to.toUtc().toIso8601String()}',
        inputFingerprint: fingerprint,
        text: allowPartial && (uncertain > 0 || active)
            ? '【部分范围复盘：仍有未定位或未完整录音】\n$text'
            : text,
        created: DateTime.now(),
        inputIds: entries.map((e) => e.id).toList(),
        sourceVersions: sourceVersions,
        partial: allowPartial && (uncertain > 0 || active),
        from: from,
        to: to);
    await content.put('summaries', saved.id, saved.toJson());
    _summaries[saved.id] = saved;
    _changed();
    return saved;
  }

  /// 大范围输入分批提炼并保存中间结果，最终总结不一次塞入全天原文。
  void _checkNotificationEpoch(int? epoch) {
    if (epoch != null && epoch != _notificationPolicyGeneration)
      throw const RecordingProcessingException('通知采集选择已变化，本次复盘暂停；请按当前选择重新生成。');
  }

  Future<List<String>> _reduceInputs(List<String> lines, String kind,
      {int? notificationEpoch}) async {
    _checkNotificationEpoch(notificationEpoch);
    var current = lines;
    for (var level = 0; level < 4; level++) {
      if (current.fold<int>(0, (n, s) => n + s.length) <= 12000) return current;
      final chunks = <String>[];
      var buffer = StringBuffer();
      for (final line in current) {
        for (var start = 0; start < line.length; start += 10000) {
          final piece =
              line.substring(start, math.min(line.length, start + 10000));
          if (buffer.length + piece.length > 12000) {
            chunks.add(buffer.toString());
            buffer = StringBuffer();
          }
          buffer.writeln(piece);
        }
      }
      if (buffer.isNotEmpty) chunks.add(buffer.toString());
      if (chunks.length > 256)
        throw const RecordingProcessingException('本次范围过大，请缩小时间范围后处理；已有结果保留。');
      final next = <String>[];
      for (final chunk in chunks) {
        _checkNotificationEpoch(notificationEpoch);
        final id =
            await contentFingerprint(['intermediate-v1', kind, level, chunk]);
        var saved = _summaries[id];
        if (saved == null) {
          final result = await agent().summarizeMeetingWithDiarization(
              segments: const [],
              rawText:
                  '这是供最终汇总的局部资料，请只整理已提供事实、时间及来源，保留不确定性，不推断跨段说话人身份。\n$chunk');
          final text = result['summary'];
          if (text is! String || text.trim().isEmpty || text.length > 500000)
            throw const RecordingProcessingException('分批整理未取得有效结果，已完成内容保留。');
          saved = SavedRecordingSummary(
              id: id,
              kind: 'intermediate',
              scope: kind,
              inputFingerprint: id,
              text: text,
              created: DateTime.now(),
              inputIds: const []);
          await content.put('summaries', id, saved.toJson());
          _summaries[id] = saved;
        }
        next.add(saved.text);
      }
      current = next;
    }
    throw const RecordingProcessingException('本次资料过多，已保存分批整理；请缩小范围后生成最终总结。');
  }

  Future<bool> summaryCurrent(SavedRecordingSummary saved) async {
    if (saved.kind == 'notification') return _notificationSummaryCurrent(saved);
    if (saved.kind == 'meeting') {
      final s = session(saved.scope);
      if (s == null || !sessionComplete(s)) return false;
      final parts = partsOf(s.id);
      if (parts.any((p) => transcript(p)?.stage != TranscriptionStage.complete))
        return false;
      return saved.inputFingerprint ==
          await contentFingerprint([
            s.id,
            [
              for (final p in parts)
                [
                  p.id,
                  p.offsetMs,
                  transcript(p)!.text,
                  [
                    for (final span in transcript(p)!.spans)
                      [span.start, span.end, span.speaker, span.text]
                  ]
                ]
            ],
            'meeting-v1'
          ]);
    }
    if (saved.kind == 'lifelog' && saved.from != null && saved.to != null) {
      final entries = timelineEntries
          .where((e) =>
              e.timestamp.isBefore(saved.to!) &&
              (e.endTimestamp ??
                      e.timestamp.add(const Duration(milliseconds: 1)))
                  .isAfter(saved.from!))
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      final active = sessions.any((s) =>
          s.purpose == LongRecordingPurpose.lifelog &&
          !sessionComplete(s) &&
          s.estimatedAnchor != null &&
          s.estimatedAnchor!.isBefore(saved.to!) &&
          _mayOverlap(s, saved.from, saved.to));
      return saved.inputFingerprint ==
          await contentFingerprint([
            saved.from!.toUtc().toIso8601String(),
            saved.to!.toUtc().toIso8601String(),
            entries.map((e) => e.toJson()).toList(),
            saved.partial,
            unknownLifelogParts(from: saved.from, to: saved.to),
            active,
            'lifelog-v1'
          ]);
    }
    return false;
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

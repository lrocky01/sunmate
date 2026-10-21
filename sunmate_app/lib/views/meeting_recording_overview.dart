import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/audio/recording_overview_playback.dart';
import '../core/hardware/recorder_long_file_models.dart';
import '../core/recordings/recording_processing_controller.dart';
import '../core/recordings/recording_processing_models.dart';
import '../providers/recording_overview_playback_provider.dart';
import '../providers/recording_processing_provider.dart';
import 'recording_processing_pages.dart';
import 'recorder_long_files_page.dart';
import '../core/hardware/recorder_long_recordings.dart';

bool meetingTranscriptComplete(
        RecordingProcessingController c, ProcessingSession? session) =>
    session != null &&
    c.sessionComplete(session) &&
    c
        .partsOf(session.id)
        .every((p) => c.transcript(p)?.stage == TranscriptionStage.complete);

class MeetingRecordingOverview extends ConsumerWidget {
  final String serialNumber;
  final int sessionId;
  final RecorderLongAudioRecord? archive;
  const MeetingRecordingOverview(
      {super.key,
      required this.serialNumber,
      required this.sessionId,
      this.archive});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(recordingProcessingProvider);
    final session = c.session(sessionKey(serialNumber, sessionId));
    final player = ref.watch(recordingOverviewPlaybackProvider);
    final key = RecordingOverviewPlayback.meetingKey(serialNumber, sessionId);
    final complete =
        session == null ? archive?.canPlay == true : c.sessionComplete(session);
    final transcriptReady = meetingTranscriptComplete(c, session);
    final minutes = c.summaries
        .where((s) =>
            s.kind == 'meeting' &&
            s.scope == sessionKey(serialNumber, sessionId))
        .firstOrNull;
    final time = session?.estimatedAnchor ??
        session?.observedStart ??
        (sessionId >= 1577836800000 && sessionId <= 4102444800000
            ? DateTime.fromMillisecondsSinceEpoch(sessionId)
            : null);
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('会议 · ${recordingTime(time)}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(complete
              ? '整场已归档${archive?.durationMs == null ? "" : " · ${partDuration(archive!.durationMs)}"}'
              : '录音中或尾段待补齐；整场尚未完整'),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 4, children: [
            FilledButton.icon(
                onPressed: player.busy || !complete || archive?.canPlay != true
                    ? null
                    : () => player.playMeeting(archive!),
                icon: Icon(player.playing(key) ? Icons.stop : Icons.play_arrow),
                label: Text(player.playing(key) ? '停止整场播放' : '整场播放')),
            OutlinedButton.icon(
                onPressed: session == null
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            MeetingTranscriptPage(sessionId: session.id))),
                icon: const Icon(Icons.article_outlined),
                label: const Text('完整逐字稿')),
            OutlinedButton.icon(
                onPressed: session == null
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            MeetingMinutesPage(sessionId: session.id))),
                icon: const Icon(Icons.summarize_outlined),
                label: const Text('会议纪要')),
          ]),
          Text(transcriptReady
              ? '完整逐字稿已保存'
              : '逐字稿${c.partsOf(sessionKey(serialNumber, sessionId)).any((p) => c.transcript(p)?.stage == TranscriptionStage.complete) ? "尚未齐全" : "待转写"}'),
          if (transcriptReady)
            Text(
                c
                    .partsOf(session!.id)
                    .map((p) => c.transcript(p)!.text)
                    .firstWhere((s) => s.isNotEmpty, orElse: () => ''),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          if (minutes != null)
            Text(minutes.text, maxLines: 3, overflow: TextOverflow.ellipsis),
          if (minutes != null)
            FutureBuilder<bool>(
                future: c.summaryCurrent(minutes),
                builder: (_, state) => Text(state.hasData
                    ? (state.data! ? '会议纪要已保存' : '已有纪要待更新')
                    : '正在核对纪要版本…')),
          if (player.selected == key && player.error != null)
            Text(player.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (player.selected == key && player.playback.durationMs > 0) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
                value: (player.playback.positionMs / player.playback.durationMs)
                    .clamp(0, 1),
                semanticsLabel: '整场录音播放进度'),
            Text(
                '${partDuration(player.playback.positionMs)} / ${partDuration(player.playback.durationMs)}'),
          ],
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => session == null
                          ? const RecorderLongFilesPage(
                              purposeFilter: LongRecordingPurpose.meeting)
                          : RecordingSessionPage(sessionId: session.id))),
                  icon: const Icon(Icons.chevron_right),
                  label: Text(session == null ? '归档详情' : '分段详情'))),
          if (session == null) const Text('历史音频仍可播放；分段索引准备好后可生成逐字稿和纪要。'),
        ]));
  }
}

/// 逐字稿以连续正文呈现；不把技术分段包装成多场会议。
class MeetingTranscriptPage extends ConsumerStatefulWidget {
  final String sessionId;
  const MeetingTranscriptPage({super.key, required this.sessionId});
  @override
  ConsumerState<MeetingTranscriptPage> createState() =>
      _MeetingTranscriptState();
}

class _MeetingTranscriptState extends ConsumerState<MeetingTranscriptPage> {
  bool _busy = false;
  String? _error;
  Future<void> _transcribe() async {
    final c = ref.read(recordingProcessingProvider);
    final parts = c.partsOf(widget.sessionId);
    final pending = parts
        .where((p) => c.transcript(p)?.stage != TranscriptionStage.complete)
        .length;
    final yes = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                    title: const Text('补齐整场逐字稿'),
                    content: Text(
                        '本场有 $pending 个待转写片段，将发送至配置的私有 ASR。已保存的结果会复用。纪要仍遵循你设置的自动处理开关。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('开始转写'))
                    ])) ??
        false;
    if (!yes || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await c.transcribeMeeting(widget.sessionId);
    } catch (error) {
      if (mounted)
        _error = error is RecordingProcessingException
            ? error.message
            : '转写未完成，已有结果保留，可从分段详情继续处理。';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(recordingProcessingProvider);
    final session = c.session(widget.sessionId);
    final parts = c.partsOf(widget.sessionId);
    final complete = meetingTranscriptComplete(c, session);
    final blocks = <String>[];
    for (final p in parts) {
      final t = c.transcript(p);
      if (t?.stage != TranscriptionStage.complete) {
        blocks.add('［此处转写尚未完成］');
        continue;
      }
      if (t!.text.isEmpty) {
        blocks.add('［此处未识别到有效语音］');
        continue;
      }
      if (t.spans.isEmpty) {
        blocks.add('[${partDuration(p.offsetMs)}] ${t.text}');
      } else
        for (final span in t.spans)
          blocks.add(
              '[${p.offsetMs == null ? "位置待确认" : partDuration(p.offsetMs! + (span.start * 1000).round())}] ${span.speaker}\n${span.text}');
    }
    final text = blocks.join('\n\n');
    return Scaffold(
        appBar: AppBar(title: const Text('完整逐字稿'), actions: [
          IconButton(
              tooltip: '复制当前逐字稿',
              onPressed: text.isEmpty
                  ? null
                  : () => Clipboard.setData(ClipboardData(
                      text: '${complete ? "完整逐字稿" : "部分逐字稿，内容尚未齐全"}\n$text')),
              icon: const Icon(Icons.copy))
        ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text(complete ? '整场逐字稿已完整保存' : '部分逐字稿 · 音频或转写尚未齐全',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text('时间为整场内的相对位置。说话人编号仅在局部有效，不代表跨段同一人。'),
          if (!complete)
            Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                    onPressed:
                        _busy || session == null || !c.sessionComplete(session)
                            ? null
                            : _transcribe,
                    icon: const Icon(Icons.transcribe),
                    label: const Text('补齐整场逐字稿'))),
          if (_busy) const LinearProgressIndicator(semanticsLabel: '正在补齐整场逐字稿'),
          if (_error != null)
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const Divider(height: 32),
          SelectableText(text.isEmpty ? '尚无已保存的逐字稿。音频完整归档后可开始转写。' : text),
        ]));
  }
}

class MeetingMinutesPage extends ConsumerStatefulWidget {
  final String sessionId;
  const MeetingMinutesPage({super.key, required this.sessionId});
  @override
  ConsumerState<MeetingMinutesPage> createState() => _MeetingMinutesState();
}

class _MeetingMinutesState extends ConsumerState<MeetingMinutesPage> {
  bool _busy = false;
  String? _error;
  Future<void> _generate() async {
    final c = ref.read(recordingProcessingProvider);
    final pending = c
        .partsOf(widget.sessionId)
        .where((p) => c.transcript(p)?.stage != TranscriptionStage.complete)
        .length;
    final yes = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                    title: const Text('生成整场会议纪要'),
                    content: Text(
                        '先向私有 ASR 补齐 $pending 个待转写片段，再将整场文字交给 Hermes 生成纪要。已有且未变化的结果会复用。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('生成纪要'))
                    ])) ??
        false;
    if (!yes || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await c.summarizeMeeting(widget.sessionId);
    } catch (error) {
      if (mounted)
        _error = error is RecordingProcessingException
            ? error.message
            : '会议纪要未完成，已有逐字稿保留，请检查私有节点后重试。';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(recordingProcessingProvider);
    final session = c.session(widget.sessionId);
    final versions = c.summaries
        .where((s) => s.kind == 'meeting' && s.scope == widget.sessionId)
        .toList();
    final latest = versions.firstOrNull;
    return Scaffold(
        appBar: AppBar(title: const Text('会议纪要'), actions: [
          IconButton(
              tooltip: '复制会议纪要',
              onPressed: latest == null
                  ? null
                  : () => Clipboard.setData(ClipboardData(text: latest.text)),
              icon: const Icon(Icons.copy))
        ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (session == null || !c.sessionComplete(session))
            const Text('会议尚未完整归档，暂不能生成整场纪要。'),
          Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                  onPressed:
                      _busy || session == null || !c.sessionComplete(session)
                          ? null
                          : _generate,
                  icon: const Icon(Icons.summarize_outlined),
                  label: Text(latest == null ? '生成会议纪要' : '核对并更新纪要'))),
          if (_busy) const LinearProgressIndicator(semanticsLabel: '正在生成会议纪要'),
          if (_error != null)
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 16),
          if (latest == null)
            const Text('尚未生成纪要。逐字稿会独立保留，生成纪要前无需重新录音。')
          else ...[
            FutureBuilder<bool>(
                future: c.summaryCurrent(latest),
                builder: (_, state) => Text(state.hasData
                    ? (state.data! ? '已保存 · 当前整场内容' : '旧纪要 · 资料已变化，待更新')
                    : '正在核对版本…')),
            Text('保存于 ${recordingTime(latest.created)}'),
            const SizedBox(height: 12),
            SelectableText(latest.text),
            if (versions.length > 1) ...[
              const Divider(height: 32),
              const Text('历史纪要'),
              for (final version in versions.skip(1))
                SavedSummaryTile(summary: version)
            ],
          ],
        ]));
  }
}

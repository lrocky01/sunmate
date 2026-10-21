import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/audio/recorder_local_audio.dart';
import '../core/hardware/recorder_long_recordings.dart';
import '../core/recordings/recording_processing_controller.dart';
import '../core/recordings/recording_processing_models.dart';
import '../providers/device_provider.dart';
import '../providers/recording_processing_provider.dart';
import 'recorder_long_files_page.dart';
import 'recorder_management_page.dart';

String recordingTime(DateTime? time) => time == null
    ? '时间待定位'
    : '${time.toLocal().month}月${time.toLocal().day}日 ${time.toLocal().hour.toString().padLeft(2, '0')}:${time.toLocal().minute.toString().padLeft(2, '0')}:${time.toLocal().second.toString().padLeft(2, '0')}';
String partDuration(int? ms) => ms == null
    ? '待计算'
    : '${ms ~/ 60000}:${(ms ~/ 1000 % 60).toString().padLeft(2, '0')}';

class RecordingProcessingSettingsPage extends ConsumerStatefulWidget {
  const RecordingProcessingSettingsPage({super.key});
  @override
  ConsumerState<RecordingProcessingSettingsPage> createState() =>
      _ProcessingSettingsState();
}

class _ProcessingSettingsState
    extends ConsumerState<RecordingProcessingSettingsPage> {
  bool _saving = false;
  Future<void> _save(ProcessingPolicy policy) async {
    if (_saving) return;
    setState(() => _saving = true);
    final saved = await ref.read(recordingProcessingProvider).setPolicy(policy);
    if (mounted) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(saved ? '自动处理设置已回读确认。' : '设置保存未确认，请重试。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(recordingProcessingProvider);
    final p = c.policy;
    return Scaffold(
        appBar: AppBar(title: const Text('长录自动处理')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('自动开关默认关闭，只对新开始的录音生效。已有或正在进行的录音可手动处理。'),
          const SizedBox(height: 16),
          SwitchListTile(
              title: const Text('会议分段自动转写'),
              subtitle: const Text('已关闭片段就绪后，自动发送到配置的私有 ASR。'),
              value: p.meetingTranscribe,
              onChanged: _saving || !c.loaded
                  ? null
                  : (v) => _save(ProcessingPolicy(
                      meetingTranscribe: v,
                      meetingSummary: v && p.meetingSummary,
                      lifelogTranscribe: p.lifelogTranscribe))),
          SwitchListTile(
              title: const Text('会议停止后自动纪要'),
              subtitle: const Text('需同时开启会议自动转写；整场尾段齐全、转写完成后才发送文字到 Hermes。'),
              value: p.meetingSummary,
              onChanged: _saving || !c.loaded || !p.meetingTranscribe
                  ? null
                  : (v) => _save(ProcessingPolicy(
                      meetingTranscribe: p.meetingTranscribe,
                      meetingSummary: v,
                      lifelogTranscribe: p.lifelogTranscribe))),
          const Divider(height: 32),
          SwitchListTile(
              title: const Text('随身分段自动转写'),
              subtitle: const Text('只自动转写音频。复盘由你选择时间范围后手动生成，不逐段自动总结。'),
              value: p.lifelogTranscribe,
              onChanged: _saving || !c.loaded
                  ? null
                  : (v) => _save(ProcessingPolicy(
                      meetingTranscribe: p.meetingTranscribe,
                      meetingSummary: p.meetingSummary,
                      lifelogTranscribe: v))),
          if (c.message != null)
            Text(c.message!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 16),
          const Text(
              'App 被系统挂起时无法保证持续处理；回到前台继续已有任务。播放不会触发转写。提交结果不确定时会暂停，不自动重复上传。'),
        ]));
  }
}

class ProcessedRecordingsSection extends ConsumerWidget {
  final LongRecordingPurpose purpose;
  final bool showSessions;
  const ProcessedRecordingsSection(
      {super.key, required this.purpose, this.showSessions = true});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(recordingProcessingProvider);
    final driver = ref.read(deviceFactoryProvider).bleDriver;
    final sessions = c.sessions.where((s) => s.purpose == purpose).toList();
    return StreamBuilder<void>(
        stream: driver.stateChanges,
        builder: (context, snapshot) {
          final legacy = driver.longFileLibrary.recordings
              .where((r) =>
                  r.purpose == purpose &&
                  sessions.every(
                      (s) => s.id != sessionKey(r.serialNumber, r.sessionId)))
              .toList();
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                    purpose == LongRecordingPurpose.meeting ? '会议长录音' : '随身长录音',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(purpose == LongRecordingPurpose.meeting
                    ? '一场会议保留完整录音，可展开各段播放、逐字稿与整场纪要。'
                    : '按段查看音频与文字；时间可定位的内容会与允许采集的通知进入同一时光轴。'),
                Wrap(spacing: 8, children: [
                  TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  const RecorderRecordingSettingsPage())),
                      icon: const Icon(Icons.tune),
                      label: const Text('选择下次录音用途')),
                  TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  const RecordingProcessingSettingsPage())),
                      icon: const Icon(Icons.auto_mode),
                      label: const Text('自动处理设置')),
                  TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => RecorderLongFilesPage(
                                  purposeFilter: purpose))),
                      icon: const Icon(Icons.folder_open),
                      label: const Text('下载与整场播放')),
                ]),
                if (!c.loaded && c.message == null)
                  const LinearProgressIndicator(),
                if (c.message != null)
                  Text(c.message!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                if (c.loaded && sessions.isEmpty && legacy.isEmpty)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                          '尚无${purpose.label}录音。先选择用途，再用卡片按键录制；已保存的录音可从文件页读取。')),
                for (final s in sessions.where((s) =>
                    showSessions ||
                    c.partsOf(s.id).any((p) => c.absoluteStart(p) == null)))
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                          '${showSessions ? s.purpose?.label ?? "用途未确认" : "待定位录音"} · ${recordingTime(s.estimatedAnchor ?? s.observedStart)}'),
                      subtitle: Text(
                          '${c.sessionComplete(s) ? "整场已归档" : "录音中或整场待补齐"} · 已索引 ${c.partsOf(s.id).length} 段\n${s.timeLabel}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) =>
                              RecordingSessionPage(sessionId: s.id)))),
                for (final record in legacy)
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                          '${record.purposeLabel} · ${recordingTime(record.sessionId >= 1577836800000 && record.sessionId <= 4102444800000 ? DateTime.fromMillisecondsSinceEpoch(record.sessionId) : null)}'),
                      subtitle: Text('${record.stageLabel}；旧整场归档仍保留，分段索引待导入'),
                      trailing: const Icon(Icons.folder_open),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) =>
                              RecorderLongFilesPage(purposeFilter: purpose)))),
                if (purpose == LongRecordingPurpose.lifelog &&
                    c.unknownLifelogParts() > 0)
                  Text(
                      '有 ${c.unknownLifelogParts()} 段时间待定位，可在录音会话内查看；不会强行匹配通知。'),
              ]);
        });
  }
}

class RecordingSessionPage extends ConsumerStatefulWidget {
  final String sessionId;
  const RecordingSessionPage({super.key, required this.sessionId});
  @override
  ConsumerState<RecordingSessionPage> createState() =>
      _RecordingSessionPageState();
}

class _RecordingSessionPageState extends ConsumerState<RecordingSessionPage> {
  late final RecorderLocalAudio _audio;
  @override
  void initState() {
    super.initState();
    _audio = ref.read(recordingLocalAudioProvider);
  }

  bool _working = false;
  String? _error, _playing, _playingPath;
  Timer? _timer;
  Future<void> _run(Future<void> Function() work) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await work();
    } catch (error) {
      if (mounted)
        setState(() => _error = error is RecordingProcessingException
            ? error.message
            : '本次处理未完成，原音频与已有结果保留，请重试。');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_stopOwned().catchError((Object _) {}));
    super.dispose();
  }

  Future<void> _stopOwned() async {
    if (_playingPath == null) return;
    final state = await _audio.state();
    if (state.relativePath == _playingPath) await _audio.stop();
  }

  Future<void> _play(ProcessingPart p) async {
    final audio = _audio;
    if (_playing == p.id) {
      await audio.stop();
      _timer?.cancel();
      if (mounted) setState(() => _playing = null);
      return;
    }
    final prepared =
        await ref.read(recordingProcessingProvider).preparePlayback(p);
    if (!mounted) return;
    _playingPath = prepared.relativePath;
    await audio.play(prepared.relativePath);
    final state = await audio.state();
    if (!mounted) {
      await _stopOwned();
      return;
    }
    setState(() => _playing =
        state.isPlaying && state.relativePath == _playingPath ? p.id : null);
    _timer?.cancel();
    if (state.isPlaying)
      _timer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
        try {
          final state = await audio.state();
          if (!state.isPlaying || state.relativePath != _playingPath) {
            _timer?.cancel();
            if (mounted) setState(() => _playing = null);
          }
        } catch (_) {
          _timer?.cancel();
          if (mounted) setState(() => _playing = null);
        }
      });
  }

  Future<void> _transcribe(ProcessingPart p) async {
    final c = ref.read(recordingProcessingProvider);
    final uncertain =
        c.transcript(p)?.stage == TranscriptionStage.submissionUnknown;
    var confirmed = false;
    if (uncertain) {
      confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                      title: const Text('确认重新提交这段音频'),
                      content: const Text(
                          '上次请求可能已被 ASR 接收，但没有取得任务ID。重新提交可能产生重复任务；本机原录音和旧资料会保留。'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消')),
                        FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('确认重新提交'))
                      ])) ??
          false;
      if (!confirmed) return;
    }
    final ok = await c.transcribePart(p, confirmResubmit: confirmed);
    if (!ok && mounted)
      setState(() => _error = c.transcript(p)?.message ?? '转写尚未完成，任务资料已保留。');
  }

  Future<void> _summary() async {
    final c = ref.read(recordingProcessingProvider);
    final parts = c.partsOf(widget.sessionId);
    final count = parts
        .where((p) => c.transcript(p)?.stage != TranscriptionStage.complete)
        .length;
    final yes = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                    title: const Text('生成整场会议纪要'),
                    content: Text(
                        '本场共 ${parts.length} 段，其中 $count 段待转写。将向私有 ASR 补齐转写，再把文字交给 Hermes 生成纪要；已完成且未变化的结果会复用。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('处理并生成'))
                    ])) ??
        false;
    if (yes) await c.summarizeMeeting(widget.sessionId);
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(recordingProcessingProvider);
    final s = c.session(widget.sessionId);
    final parts = c.partsOf(widget.sessionId);
    return Scaffold(
        appBar: AppBar(
            title: Text(s?.purpose == LongRecordingPurpose.meeting
                ? '会议录音与纪要'
                : '随身分段录音')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (s != null) ...[
            Text(c.sessionComplete(s) ? '整场音频已完整归档' : '整场尚未确认完整；已关闭的段可独立处理。'),
            Text(s.timeLabel),
            if (s.purpose == LongRecordingPurpose.meeting)
              FilledButton.icon(
                  onPressed: _working || !c.sessionComplete(s)
                      ? null
                      : () => _run(_summary),
                  icon: const Icon(Icons.summarize_outlined),
                  label: const Text('补齐转写并生成会议纪要')),
          ],
          if (_working) const LinearProgressIndicator(),
          if (_error != null)
            Semantics(
                liveRegion: true,
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          if (parts.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('尚无已关闭并提交的分段。保持连接后等待同步，停止后补齐尾段。')),
          for (final p in parts) ...[
            const Divider(height: 24),
            Text('第 ${p.source.part + 1} 段 · ${partDuration(p.durationMs)}',
                style: Theme.of(context).textTheme.titleMedium),
            Text(c.absoluteStart(p) == null
                ? '相对位置 ${p.offsetMs == null ? "待补齐前段" : partDuration(p.offsetMs)}'
                : '${recordingTime(c.absoluteStart(p))} ～ ${recordingTime(c.absoluteEnd(p))}'),
            Text(c.timingLabel(p)),
            if (p.message != null) Text(p.message!),
            Wrap(spacing: 12, children: [
              OutlinedButton.icon(
                  onPressed:
                      _working || !p.ready ? null : () => _run(() => _play(p)),
                  icon: Icon(_playing == p.id ? Icons.stop : Icons.play_arrow),
                  label: Text(_playing == p.id ? '停止播放' : '播放本段')),
              OutlinedButton.icon(
                  onPressed: _working ? null : () => _run(() => _transcribe(p)),
                  icon: const Icon(Icons.transcribe),
                  label: Text(c.transcript(p)?.job != null &&
                          c.transcript(p)?.stage != TranscriptionStage.complete
                      ? '继续查询转写'
                      : '转写本段')),
            ]),
            Text(c.transcript(p)?.stageLabel ??
                (p.ready ? '已封装，尚未转写' : '等待分段封装')),
            if (c.transcript(p)?.message != null)
              Text(c.transcript(p)!.message!),
            if (c.transcript(p)?.stage == TranscriptionStage.complete) ...[
              const SizedBox(height: 8),
              SelectableText(c.transcript(p)!.text.isEmpty
                  ? '本段未识别到有效语音。'
                  : c.transcript(p)!.text),
              for (final span in c.transcript(p)!.spans)
                Text(
                    '${partDuration((span.start * 1000).round())} ～ ${partDuration((span.end * 1000).round())} · ${span.speaker}: ${span.text}'),
              if (c.transcript(p)!.spans.isNotEmpty)
                const Text('说话人编号仅在本段内有效；不同段的相同编号不代表同一个人。'),
            ],
          ],
          const Divider(height: 32),
          for (final summary in c.summaries
              .where((v) => v.kind == 'meeting' && v.scope == widget.sessionId))
            SavedSummaryTile(summary: summary),
        ]));
  }
}

class SavedRecordingSummaryPage extends StatelessWidget {
  final SavedRecordingSummary summary;
  const SavedRecordingSummaryPage({super.key, required this.summary});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          title: Text(summary.kind == 'meeting'
              ? '已保存会议纪要'
              : summary.kind == 'notification'
                  ? '已保存通知简报'
                  : '已保存时光复盘'),
          actions: [
            IconButton(
                tooltip: '复制总结',
                icon: const Icon(Icons.copy),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: summary.text)))
          ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('保存于 ${recordingTime(summary.created)}'),
        if (summary.from != null)
          Text(
              '范围 ${recordingTime(summary.from)} ～ ${recordingTime(summary.to)}'),
        if (summary.kind == 'notification')
          Text('使用 ${summary.inputIds.length} 条本机通知；不包含录音。'),
        if (summary.partial) const Text('本次仅使用已就绪且可定位内容，不代表完整记录。'),
        const SizedBox(height: 16),
        SelectableText(summary.text)
      ]));
}

class SavedSummaryTile extends ConsumerWidget {
  final SavedRecordingSummary summary;
  const SavedSummaryTile({super.key, required this.summary});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(recordingProcessingProvider);
    return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
            '已保存${summary.kind == "meeting" ? "纪要" : summary.kind == "notification" ? "通知简报" : "复盘"} · ${recordingTime(summary.created)}'),
        subtitle: FutureBuilder<bool>(
            future: c.summaryCurrent(summary),
            builder: (_, snapshot) => Text(snapshot.hasData
                ? (snapshot.data! ? '当前资料的已保存结果' : '输入已变化或未齐全，旧结果待更新')
                : '核对输入版本…')),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => SavedRecordingSummaryPage(summary: summary))));
  }
}

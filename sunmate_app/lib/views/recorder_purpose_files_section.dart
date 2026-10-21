import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ai/asr_service.dart';
import '../core/audio/recorder_archive_transcriber.dart';
import '../core/hardware/ainote_6095_driver.dart';
import '../core/hardware/recorder_long_file_models.dart';
import '../core/hardware/recorder_long_recordings.dart';
import '../providers/device_provider.dart';
import '../providers/server_config_provider.dart';
import 'recorder_long_files_page.dart';
import 'recorder_management_page.dart';

typedef RecorderTranscriptHandler = Future<void> Function(
    RecorderLongAudioRecord record, AsrResult result);

/// 直接观察同一份长录归档，不复制音频，也不自动调用私有服务。
class RecorderPurposeFilesSection extends ConsumerStatefulWidget {
  final LongRecordingPurpose purpose;
  final AiNote6095Driver? driver;
  final RecorderArchiveTranscriber? transcriber;
  final RecorderTranscriptHandler? onTranscribed;
  const RecorderPurposeFilesSection(
      {super.key,
      required this.purpose,
      this.driver,
      this.transcriber,
      this.onTranscribed});
  @override
  ConsumerState<RecorderPurposeFilesSection> createState() =>
      _PurposeFilesState();
}

class _PurposeFilesState extends ConsumerState<RecorderPurposeFilesSection> {
  late final AiNote6095Driver _driver;
  StreamSubscription<void>? _changes;
  bool _loading = true;
  bool _busy = false;
  String? _status;
  @override
  void initState() {
    super.initState();
    _driver = widget.driver ?? ref.read(deviceFactoryProvider).bleDriver;
    _changes = _driver.stateChanges.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _driver.reloadLocalLongFiles();
    } catch (_) {
      _status = '本机录音资料读取失败，请重新打开页面。';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  Future<void> _transcribe(RecorderLongAudioRecord record) async {
    if (_busy || !record.canPlay || widget.onTranscribed == null) return;
    setState(() {
      _busy = true;
      _status = '正在校验本机音频并提交私有 ASR，完成前请留在此页。';
    });
    try {
      final transcriber = widget.transcriber ??
          RecorderArchiveTranscriber(asr: ref.read(asrServiceProvider));
      final result = await transcriber.transcribe(record);
      if (!mounted) return;
      setState(() => _status = widget.purpose == LongRecordingPurpose.meeting
          ? '转写完成，正在请求 Hermes 生成会议纪要…'
          : '转写完成，正在加入时光轴…');
      await widget.onTranscribed!(record, result);
      if (mounted)
        setState(() => _status = widget.purpose == LongRecordingPurpose.meeting
            ? '本次会议纪要已生成，可在下方查看。'
            : '转写已加入时光轴，可手动生成复盘。');
    } catch (_) {
      if (mounted) setState(() => _status = '处理未完成，本机音频已保留；请检查私有节点配置后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _time(int session) {
    if (session <= 0 || session > 8640000000000000) return '时间待确认';
    final date = DateTime.fromMillisecondsSinceEpoch(session);
    return '${date.month}月${date.day}日 ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  void _openFiles({bool all = false}) =>
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => RecorderLongFilesPage(
              driver: _driver, purposeFilter: all ? null : widget.purpose)));

  @override
  Widget build(BuildContext context) {
    final records = _driver.longFileLibrary.recordings
        .where((r) => r.purpose == widget.purpose)
        .toList();
    final unknown =
        _driver.longFileLibrary.recordings.any((r) => r.purpose == null);
    final meeting = widget.purpose == LongRecordingPurpose.meeting;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(meeting ? '会议长录音' : '随身长录音',
          style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      const Text('双击／三击只负责启停。录音用途在开始前选择，文件会按本次用途显示；停止并确认尾段后才可完整播放和转写。'),
      Wrap(spacing: 8, children: [
        TextButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const RecorderRecordingSettingsPage())),
            icon: const Icon(Icons.tune),
            label: const Text('选择下次录音用途')),
        TextButton.icon(
            onPressed: () => _openFiles(),
            icon: const Icon(Icons.folder_open),
            label: const Text('下载与播放')),
      ]),
      if (_loading || _busy) const LinearProgressIndicator(),
      if (_status != null)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Semantics(liveRegion: true, child: Text(_status!))),
      if (!_loading && records.isEmpty)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
                '尚无${widget.purpose.label}录音。先选择用途，再用卡片按键录制；已有文件可到“下载与播放”读取目录。')),
      for (final record in records) ...[
        const Divider(height: 24),
        Text('${record.purposeLabel} · ${_time(record.sessionId)}',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
            '${record.stageLabel} · 已保存 ${record.downloadedParts}/${record.totalParts} 段'),
        if (record.message != null) Text(record.message!),
        Wrap(spacing: 12, children: [
          TextButton(
              onPressed: () => _openFiles(),
              child: Text(record.canPlay ? '查看并播放' : '查看下载进度')),
          if (record.canPlay && widget.onTranscribed != null)
            OutlinedButton.icon(
                onPressed: _busy ? null : () => _transcribe(record),
                icon: const Icon(Icons.transcribe),
                label: Text(meeting ? '转写并生成纪要' : '转写到时光轴')),
        ]),
      ],
      if (unknown)
        TextButton(
            onPressed: () => _openFiles(all: true),
            child: const Text('查看用途未确认的历史录音')),
      const SizedBox(height: 12),
      Text(
          meeting
              ? '仅点击“转写并生成纪要”才会发送到配置的 ASR 和 Hermes。'
              : '仅点击“转写到时光轴”才会发送音频到配置的 ASR；生成复盘时再发送文字给 Hermes。',
          style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

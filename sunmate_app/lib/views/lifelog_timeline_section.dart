import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/hardware/recorder_long_recordings.dart';
import '../core/recordings/recording_processing_models.dart';
import '../models/timeline_entry.dart';
import '../providers/recording_overview_playback_provider.dart';
import '../providers/recording_processing_provider.dart';
import 'recording_processing_pages.dart';

/// 每个音频段只有一个时间轴条目；通知保持独立来源，不因没有转写而藏掉音频。
class LifelogTimelineSection extends ConsumerWidget {
  final List<TimelineEntry> entries;
  final void Function(TimelineEntry) onEntry;
  const LifelogTimelineSection(
      {super.key, required this.entries, required this.onEntry});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(recordingProcessingProvider);
    final player = ref.watch(recordingOverviewPlaybackProvider);
    final parts = [
      for (final session
          in c.sessions.where((s) => s.purpose == LongRecordingPurpose.lifelog))
        ...c.partsOf(session.id).where((p) => c.absoluteStart(p) != null)
    ];
    String visibleText(ProcessingPart p) {
      if (c.transcript(p)?.stage != TranscriptionStage.complete)
        return c.transcript(p)?.stageLabel ?? '音频已保存，尚未转写；播放不会上传音频。';
      if (c.transcript(p)!.text.isEmpty) return '本段未识别到有效语音。';
      final paragraphs = entries
          .where((e) => e.recordingPartId == p.id)
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return paragraphs.isEmpty
          ? '本段文字已从时光轴隐藏，可在录音详情查看。'
          : paragraphs.map((e) => e.content).join('\n');
    }

    final visibleParts = parts.map((p) => p.id).toSet();
    final items = <({DateTime at, ProcessingPart? part, TimelineEntry? entry})>[
      for (final p in parts) (at: c.absoluteStart(p)!, part: p, entry: null),
      for (final e in entries.where((e) =>
          e.recordingPartId == null ||
          !visibleParts.contains(e.recordingPartId)))
        (at: e.timestamp, part: null, entry: e),
    ]..sort((a, b) => b.at.compareTo(a.at));
    if (items.isEmpty)
      return const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child:
              Text('时光轴暂无记录。已同步的随身音频段、允许采集的通知和灵感会按时间出现在这里；时间待定位的录音可在上方单独查看。'));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final item in items) ...[
        const Divider(height: 24),
        if (item.part case final p?) ...[
          Text('${recordingTime(item.at)} ～ ${recordingTime(c.absoluteEnd(p))}',
              key: ValueKey('lifelog-part:${p.id}'),
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text('随身录音 · ${partDuration(p.durationMs)}',
              style: Theme.of(context).textTheme.titleMedium),
          Text(c.timingLabel(p)),
          Wrap(spacing: 8, children: [
            OutlinedButton.icon(
                onPressed: player.busy || !p.ready
                    ? null
                    : () => player.playSegment(c, p),
                icon:
                    Icon(player.playing(p.id) ? Icons.stop : Icons.play_arrow),
                label: Text(player.playing(p.id) ? '停止片段播放' : '播放片段')),
            TextButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        RecordingSessionPage(sessionId: p.sessionId))),
                icon: const Icon(Icons.chevron_right),
                label: const Text('文字与详情')),
          ]),
          if (player.selected == p.id && player.error != null)
            Text(player.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          Text(visibleText(p)),
        ] else if (item.entry case final e?)
          ListTile(
              key: ValueKey('timeline-entry:${e.id}'),
              contentPadding: EdgeInsets.zero,
              isThreeLine: true,
              leading: Icon(e.sourceType == TimelineSourceType.appNotification
                  ? Icons.notifications_outlined
                  : e.sourceType == TimelineSourceType.audioVoice
                      ? Icons.mic_none
                      : Icons.bookmark_outline),
              title: Text('${e.sourceApp} · ${recordingTime(e.timestamp)}'),
              subtitle:
                  Text(e.content, maxLines: 3, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onEntry(e)),
      ],
    ]);
  }
}

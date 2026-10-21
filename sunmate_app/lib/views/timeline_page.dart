import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/timeline_entry.dart';
import '../providers/timeline_provider.dart';
import '../core/hardware/recorder_long_recordings.dart';
import 'recording_processing_pages.dart';
import '../providers/recording_processing_provider.dart';
import 'notification_apps_page.dart';
import 'lifelog_timeline_section.dart';
import 'notification_digest_page.dart';

class TimelinePage extends ConsumerWidget {
  const TimelinePage({super.key});

  void _showAddBookmarkDialog(BuildContext context, TimelineNotifier notifier) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.bookmark_add, color: Color(0xFFFF8C00)),
            SizedBox(width: 8),
            Text("随手灵感速记打标", style: TextStyle(fontSize: 16)),
          ],
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: "输入此刻的关键想法、决议或灵感...",
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            child: const Text("取消"),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF8C00),
              foregroundColor: Colors.white,
            ),
            child: const Text("保存打标"),
            onPressed: () async {
              final text = controller.text.trim();
              if (text.isNotEmpty) {
                final saved = await notifier.addBookmark(text);
                if (!context.mounted || !ctx.mounted) return;
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(saved ? "✓ 灵感已安全保存" : "未能安全保存，请检查本机存储")),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  void _showEntryDetail(BuildContext context, TimelineEntry entry,
      TimelineNotifier notifier, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  entry.sourceType == TimelineSourceType.audioVoice
                      ? Icons.mic
                      : (entry.sourceType == TimelineSourceType.systemNote
                          ? Icons.bookmark
                          : Icons.notifications),
                  color: const Color(0xFFFF8C00),
                ),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(
                  entry.sourceApp,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16),
                )),
                const SizedBox(width: 8),
                Text(
                  "${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}:${entry.timestamp.second.toString().padLeft(2, '0')}",
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
            const Divider(height: 24),
            if (entry.endTimestamp != null)
              Text(
                  '${recordingTime(entry.timestamp)} ～ ${recordingTime(entry.endTimestamp)} · ${entry.tags}'),
            if (entry.recordingPartId != null)
              TextButton.icon(
                  onPressed: () {
                    final c = ref.read(recordingProcessingProvider);
                    final s = c.sessions
                        .where((s) => c
                            .partsOf(s.id)
                            .any((p) => p.id == entry.recordingPartId))
                        .firstOrNull;
                    if (s != null) {
                      Navigator.of(ctx).pop();
                      Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) =>
                              RecordingSessionPage(sessionId: s.id)));
                    }
                  },
                  icon: const Icon(Icons.audio_file_outlined),
                  label: const Text('查看对应录音与各段')),
            Text(
              entry.content,
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text("复制内容"),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: entry.content));
                      Navigator.of(ctx).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("✓ 已复制到剪贴板")),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                    ),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text("从时光轴隐藏"),
                    onPressed: () {
                      notifier.deleteEntry(entry.id);
                      Navigator.of(ctx).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("已从今日流水中移除该记录")),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _chooseRange(
      BuildContext context, WidgetRef ref, TimelineNotifier notifier) async {
    final now = DateTime.now();
    final days = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: now,
        initialDateRange: DateTimeRange(
            start: DateTime(now.year, now.month, now.day),
            end: DateTime(now.year, now.month, now.day)),
        helpText: '选择复盘日期范围（最多31天）');
    if (days == null || !context.mounted) return;
    final startTime = await showTimePicker(
        context: context,
        initialTime: const TimeOfDay(hour: 0, minute: 0),
        helpText: '起始时间');
    if (startTime == null || !context.mounted) return;
    final endTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(now),
        helpText: '结束时间');
    if (endTime == null || !context.mounted) return;
    final from = DateTime(days.start.year, days.start.month, days.start.day,
        startTime.hour, startTime.minute);
    final to = DateTime(days.end.year, days.end.month, days.end.day,
        endTime.hour, endTime.minute);
    final c = ref.read(recordingProcessingProvider);
    final parts = c.partsInRange(from, to);
    var partial = false;
    final yes = await showDialog<bool>(
            context: context,
            builder: (ctx) => StatefulBuilder(
                builder: (ctx, setLocal) => AlertDialog(
                        title: const Text('处理所选范围并复盘'),
                        content: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(
                                  '${recordingTime(from)} ～ ${recordingTime(to)}\n范围内 ${parts.length} 段录音。先向私有 ASR 补齐未转写片段，再把文字和允许采集的通知交给 Hermes；已完成结果复用。'),
                              Text(
                                  '另有 ${c.unknownLifelogParts()} 段时间待定位，不会猜测归入所选范围。'),
                              CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('有缺段或未定位时，仅总结已就绪内容'),
                                  value: partial,
                                  onChanged: (v) =>
                                      setLocal(() => partial = v ?? false)),
                            ])),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消')),
                          FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('处理并生成'))
                        ]))) ??
        false;
    if (yes)
      await notifier.generateDailyReport(
          from: from, to: to, allowPartial: partial);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timelineState = ref.watch(timelineProvider);
    final notifier = ref.read(timelineProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text("时光复盘"),
        actions: [
          IconButton(
            tooltip: "选择范围生成随身复盘",
            icon: timelineState.isGeneratingReport
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome),
            onPressed: timelineState.isGeneratingReport
                ? null
                : () => _chooseRange(context, ref, notifier),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const NotificationDigestPage())),
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: const Text('通知简报')),
              OutlinedButton.icon(
                  onPressed: timelineState.isGeneratingReport
                      ? null
                      : () => _chooseRange(context, ref, notifier),
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: const Text('随身复盘')),
            ]),
            const SizedBox(height: 16),
            const ProcessedRecordingsSection(
                purpose: LongRecordingPurpose.lifelog, showSessions: false),
            TextButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const NotificationAppsPage())),
                icon: const Icon(Icons.notifications_outlined),
                label: const Text('管理通知采集应用')),
            const Text(
                '允许采集的通知、分段文字和复盘保存在本机。范围复盘先补齐所选录音的转写，再整理时间轴；时间不确定的录音单独标注。'),
            for (final summary in ref
                .watch(recordingProcessingProvider)
                .summaries
                .where((s) => s.kind == 'lifelog'))
              SavedSummaryTile(summary: summary),
            if (timelineState.lastError != null)
              Text(timelineState.lastError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const Divider(height: 32),
            // 3. 全天时光轴流水与快捷模拟打标
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                    child: Text("时光轴流水 (语音 + 通知融合)",
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold))),
                TextButton.icon(
                  icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                  label: const Text("灵感打标",
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  onPressed: () => _showAddBookmarkDialog(context, notifier),
                ),
              ],
            ),
            const SizedBox(height: 8),

            LifelogTimelineSection(
                entries: timelineState.entries,
                onEntry: (entry) =>
                    _showEntryDetail(context, entry, notifier, ref)),
          ],
        ),
      ),
    );
  }
}

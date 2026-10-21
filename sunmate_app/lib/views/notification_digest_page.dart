import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/recordings/notification_digest_models.dart';
import '../core/recordings/recording_processing_controller.dart';
import '../providers/recording_processing_provider.dart';
import 'recording_processing_pages.dart';
import 'notification_apps_page.dart';

class NotificationDigestPage extends ConsumerStatefulWidget {
  const NotificationDigestPage({super.key});
  @override
  ConsumerState<NotificationDigestPage> createState() =>
      _NotificationDigestState();
}

class _NotificationDigestState extends ConsumerState<NotificationDigestPage> {
  NotificationDigestMode _mode = NotificationDigestMode.today;
  DateTime? _from, _to;
  bool _saving = false;
  String? _error;
  Future<void> _custom() async {
    final now =
        ref.read(recordingProcessingProvider).notificationClock().toLocal();
    final days = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: now,
        initialDateRange: DateTimeRange(
            start: _from ?? DateTime(now.year, now.month, now.day),
            end: _to ?? now),
        helpText: '选择通知日期范围（最多31天）');
    if (days == null || !mounted) return;
    final start = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(
            _from ?? DateTime(now.year, now.month, now.day)),
        helpText: '开始时间');
    if (start == null || !mounted) return;
    final end = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(_to ?? now),
        helpText: '结束时间');
    if (end == null || !mounted) return;
    setState(() {
      _mode = NotificationDigestMode.custom;
      _from = DateTime(days.start.year, days.start.month, days.start.day,
          start.hour, start.minute);
      _to = DateTime(
          days.end.year, days.end.month, days.end.day, end.hour, end.minute);
      _error = null;
    });
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await work();
    } catch (error) {
      if (mounted)
        _error = error is RecordingProcessingException
            ? error.message
            : '本次通知简报操作未完成，请检查本机存储后重试。';
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
          context: context,
          builder: (ctx) =>
              AlertDialog(title: Text(title), content: Text(body), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(action))
              ])) ??
      false;
  Future<void> _enqueue() async {
    final c = ref.read(recordingProcessingProvider);
    final range = c.notificationRange(_mode,
        from: _from, to: _mode == NotificationDigestMode.custom ? _to : null);
    final count = c.notificationsInRange(range.from, range.to).length;
    if (!await _confirm(
            '生成通知简报',
            '${recordingTime(range.from)} ～ ${recordingTime(range.to)}\n共 $count 条当前允许使用的本机通知。仅把这些通知文字发给私有 Hermes，不发送录音；结果保存到本机。',
            '确认生成') ||
        !mounted) return;
    await _run(() async {
      final job = await c.enqueueNotificationDigest(range);
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(job.stage == NotificationDigestStage.saved
                ? '这份简报已保存，可从下方查看。'
                : [
                    NotificationDigestStage.failed,
                    NotificationDigestStage.interrupted,
                    NotificationDigestStage.cancelled
                  ].contains(job.stage)
                    ? '已有相同范围的任务，请在处理记录中确认后重试。'
                    : '已加入手动处理队列。')));
    });
  }

  Future<void> _retry(NotificationDigestJob job) async {
    if (!await _confirm(
            '重试这份通知简报',
            '将重新核对原范围的资料和采集选择。上次请求可能已被 Hermes 接收，重新生成可能产生重复处理；已有资料与局部结果会保留。',
            '确认重试') ||
        !mounted) return;
    await _run(() =>
        ref.read(recordingProcessingProvider).retryNotificationDigest(job.id));
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(recordingProcessingProvider);
    final range = c.notificationRange(_mode,
        from: _from, to: _mode == NotificationDigestMode.custom ? _to : null);
    final count = c.notificationsInRange(range.from, range.to).length;
    final validRange = range.to.isAfter(range.from) &&
        range.to.difference(range.from) <= const Duration(days: 31) &&
        !range.to.isAfter(c.notificationClock());
    final jobs = c.notificationJobs;
    final results = c.summaries.where((s) => s.kind == 'notification').toList();
    return Scaffold(
        appBar: AppBar(title: const Text('通知简报')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('单独整理通知中的重要沟通、提醒与待跟进事项，不需要开启录音或 ASR。默认由你手动生成。'),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final mode in NotificationDigestMode.values)
              ChoiceChip(
                  label: Text(mode.label),
                  selected: _mode == mode,
                  onSelected: _saving
                      ? null
                      : (_) {
                          if (mode == NotificationDigestMode.custom) {
                            _custom();
                          } else {
                            setState(() {
                              _mode = mode;
                              _error = null;
                            });
                          }
                        })
          ]),
          const SizedBox(height: 12),
          Text('${recordingTime(range.from)} ～ ${recordingTime(range.to)}'),
          Text('当前可用通知：$count 条'),
          if (_mode == NotificationDigestMode.sinceLast)
            const Text('按通知自身时间筛选；较早补到或更新的通知，请核对历史简报的待更新范围。'),
          if (_mode == NotificationDigestMode.sinceLast &&
              c.notificationCoveredUntil == null)
            const Text('尚无成功简报，首次按今天处理。'),
          if (c.notificationCoveredUntil != null)
            Text('已连续总结至 ${recordingTime(c.notificationCoveredUntil)}'),
          const SizedBox(height: 8),
          const Text('自定义区间若与已总结范围之间有空档，不会跳过空档推进“上次总结后”。失败或中断也不推进。'),
          const SizedBox(height: 12),
          Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                  onPressed:
                      _saving || !c.loaded || count == 0 ? null : _enqueue,
                  icon: const Icon(Icons.summarize_outlined),
                  label: const Text('生成通知简报'))),
          if (!validRange &&
              (_mode == NotificationDigestMode.custom ||
                  range.to.difference(range.from) > const Duration(days: 31)))
            Text('请选择不超过31天、开始早于结束且不晚于现在的时间范围。',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (count == 0 && c.loaded)
            const Text('所选范围暂无允许使用的本机通知。不会向智能体发送空请求。'),
          if (!c.loaded && c.message == null || _saving)
            const LinearProgressIndicator(),
          if (c.message != null)
            Text(c.message!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (_error != null)
            Semantics(
                liveRegion: true,
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          TextButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const NotificationAppsPage())),
              icon: const Icon(Icons.notifications_outlined),
              label: const Text('管理允许采集的应用')),
          const Divider(height: 32),
          Text('处理记录', style: Theme.of(context).textTheme.titleLarge),
          if (jobs.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('尚未提交通知简报。收到通知不会自动生成或上传。')),
          for (final job in jobs) ...[
            const SizedBox(height: 12),
            Text('${job.range.mode.label} · ${job.inputIds.length} 条通知',
                style: Theme.of(context).textTheme.titleMedium),
            Text(
                '${recordingTime(job.range.from)} ～ ${recordingTime(job.range.to)}'),
            Text(job.stageLabel),
            if (job.stage == NotificationDigestStage.running)
              const LinearProgressIndicator(semanticsLabel: '正在生成通知简报'),
            if (job.message != null)
              Text(job.message!,
                  style: TextStyle(
                      color: job.stage == NotificationDigestStage.saved
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : Theme.of(context).colorScheme.error)),
            Wrap(spacing: 8, children: [
              if ([
                NotificationDigestStage.failed,
                NotificationDigestStage.interrupted,
                NotificationDigestStage.cancelled
              ].contains(job.stage))
                TextButton(
                    onPressed: _saving ? null : () => _retry(job),
                    child: const Text('确认后重试')),
              if (job.stage == NotificationDigestStage.queued)
                TextButton(
                    onPressed: _saving
                        ? null
                        : () => _run(() => c.cancelNotificationDigest(job.id)),
                    child: const Text('取消等待')),
            ]),
          ],
          const Divider(height: 32),
          Text('已保存通知简报', style: Theme.of(context).textTheme.titleLarge),
          if (results.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('成功生成并确认保存后，会在这里显示。')),
          for (final summary in results) SavedSummaryTile(summary: summary),
        ]));
  }
}

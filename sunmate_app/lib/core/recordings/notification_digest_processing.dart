part of 'recording_processing_controller.dart';

extension NotificationDigestProcessing on RecordingProcessingController {
  List<NotificationDigestJob> get notificationJobs =>
      _notificationJobs.values.toList()
        ..sort((a, b) => b.created.compareTo(a.created));
  bool get notificationBusy => _notificationRun != null;
  List<TimelineEntry> notificationsInRange(DateTime from, DateTime to) =>
      timelineEntries
          .where((e) =>
              e.sourceType == TimelineSourceType.appNotification &&
              !e.timestamp.isBefore(from) &&
              e.timestamp.isBefore(to))
          .toList()
        ..sort((a, b) {
          final time = a.timestamp.compareTo(b.timestamp);
          return time == 0 ? a.id.compareTo(b.id) : time;
        });

  /// 仅成功落盘的简报参与连续覆盖；离散自定义区间不会跳过中间未总结的通知。
  DateTime? get notificationCoveredUntil {
    final saved = summaries
        .where(
            (s) => s.kind == 'notification' && s.from != null && s.to != null)
        .toList()
      ..sort((a, b) {
        final created = a.created.compareTo(b.created);
        return created == 0 ? a.from!.compareTo(b.from!) : created;
      });
    if (saved.isEmpty) return null;
    var end = saved.first.to!;
    saved.sort((a, b) => a.from!.compareTo(b.from!));
    for (final s in saved) {
      if (!s.from!.isAfter(end) && s.to!.isAfter(end)) end = s.to!;
    }
    return end;
  }

  NotificationDigestRange notificationRange(NotificationDigestMode mode,
      {DateTime? from, DateTime? to}) {
    final now = notificationClock();
    final local = now.toLocal();
    return NotificationDigestRange(
        mode,
        mode == NotificationDigestMode.custom
            ? from ?? DateTime(local.year, local.month, local.day)
            : mode == NotificationDigestMode.sinceLast
                ? notificationCoveredUntil ??
                    DateTime(local.year, local.month, local.day)
                : DateTime(local.year, local.month, local.day),
        to ?? now);
  }

  void _validateNotificationRange(NotificationDigestRange range) {
    if (!range.to.isAfter(range.from) ||
        range.to.difference(range.from) > const Duration(days: 31) ||
        range.from.isBefore(DateTime.utc(2020)) ||
        range.to.isAfter(notificationClock()))
      throw const RecordingProcessingException(
          '请选择不超过31天、且结束时间不晚于现在的范围；间隔过长可分批生成。');
  }

  Future<String> _notificationFingerprint(
          NotificationDigestRange range, List<TimelineEntry> entries) =>
      contentFingerprint([
        'notification-digest-v1',
        range.from.toUtc().toIso8601String(),
        range.to.toUtc().toIso8601String(),
        entries.map((e) => e.toJson()).toList()
      ]);
  Future<String> _notificationServer() => contentFingerprint(
      [agent().hermesBaseUrl.replaceAll(RegExp(r'/+$'), ''), agent().model]);
  Future<void> _saveNotificationJob(NotificationDigestJob job) =>
      content.put('notification_jobs', job.id, job.toJson());
  Future<void> _loadNotificationJobs() async {
    for (final value in await content.readAll('notification_jobs')) {
      final job = NotificationDigestJob.fromJson(value);
      if (_summaries[job.id]?.kind == 'notification') {
        job.stage = NotificationDigestStage.saved;
        job.message = null;
      } else if (job.stage == NotificationDigestStage.saved) {
        job.stage = NotificationDigestStage.interrupted;
        job.message = '保存结果暂不可读，请检查本机资料；未自动重新生成。';
      }
      _notificationJobs[job.id] = job;
    }
  }

  Future<NotificationDigestJob> enqueueNotificationDigest(
      NotificationDigestRange range) async {
    await ready;
    final key =
        '${range.from.toUtc().toIso8601String()}/${range.to.toUtc().toIso8601String()}';
    final existing = _notificationEnqueues[key];
    if (existing != null) return existing;
    final task = _enqueueNotificationDigest(range);
    _notificationEnqueues[key] = task;
    try {
      return await task;
    } finally {
      _notificationEnqueues.remove(key);
    }
  }

  Future<NotificationDigestJob> _enqueueNotificationDigest(
      NotificationDigestRange range) async {
    await ready;
    _require();
    _validateNotificationRange(range);
    final entries = notificationsInRange(range.from, range.to);
    if (entries.isEmpty)
      throw const RecordingProcessingException(
          '所选范围暂无允许使用的本机通知；未请求智能体，也未推进总结范围。');
    if (entries.length > 5000)
      throw const RecordingProcessingException('所选通知超过5000条，请缩小范围分批处理。');
    final fingerprint = await _notificationFingerprint(range, entries);
    final existing = _notificationJobs[fingerprint];
    if (existing != null) return existing; // 失败/中断也需要显式重试，不借重复点击重发。
    final job = NotificationDigestJob(
        id: fingerprint,
        fingerprint: fingerprint,
        range: range,
        inputIds: entries.map((e) => e.id).toList(),
        created: notificationClock(),
        serverFingerprint: await _notificationServer(),
        stage: _summaries[fingerprint]?.kind == 'notification'
            ? NotificationDigestStage.saved
            : NotificationDigestStage.queued);
    await _saveNotificationJob(job);
    _notificationJobs[job.id] = job;
    _changed();
    unawaited(processNotificationQueue());
    return job;
  }

  Future<void> retryNotificationDigest(String id) async {
    await ready;
    _require();
    final job = _notificationJobs[id];
    if (job == null ||
        ![
          NotificationDigestStage.failed,
          NotificationDigestStage.interrupted,
          NotificationDigestStage.cancelled
        ].contains(job.stage)) return;
    await _verifyNotificationInputs(job, checkServer: false);
    final server = await _notificationServer();
    if (![
      NotificationDigestStage.failed,
      NotificationDigestStage.interrupted,
      NotificationDigestStage.cancelled
    ].contains(job.stage)) return;
    job.serverFingerprint = server;
    job.stage = NotificationDigestStage.queued;
    job.message = null;
    try {
      await _saveNotificationJob(job);
    } catch (_) {
      job.stage = NotificationDigestStage.failed;
      job.message = '重试状态未保存，未重新发送。';
      _changed();
      rethrow;
    }
    _changed();
    unawaited(processNotificationQueue());
  }

  Future<void> cancelNotificationDigest(String id) async {
    await ready;
    _require();
    final job = _notificationJobs[id];
    if (job == null || job.stage != NotificationDigestStage.queued) return;
    job.stage = NotificationDigestStage.cancelled;
    try {
      await _saveNotificationJob(job);
    } catch (_) {
      job.stage = NotificationDigestStage.queued;
      rethrow;
    }
    _changed();
  }

  Future<List<TimelineEntry>> _verifyNotificationInputs(
      NotificationDigestJob job,
      {bool checkServer = true}) async {
    _require();
    final entries = notificationsInRange(job.range.from, job.range.to);
    if (await _notificationFingerprint(job.range, entries) != job.fingerprint)
      throw const RecordingProcessingException('通知资料或采集选择已变化，请重新选择范围、预览数量后生成。');
    if (checkServer && await _notificationServer() != job.serverFingerprint)
      throw const RecordingProcessingException('Hermes节点已变化，任务已暂停；可确认后手动重试。');
    return entries;
  }

  /// 只执行用户已明确入队的请求；没有通知驱动的自动生成或失败自动重试。
  Future<void> processNotificationQueue() async {
    await ready;
    if (!loaded || disposed || !foreground) return;
    if (_notificationRun != null) return _notificationRun;
    final completed = Completer<void>();
    _notificationRun = completed.future;
    _changed();
    try {
      while (!disposed && foreground) {
        final queued = _notificationJobs.values
            .where((j) => j.stage == NotificationDigestStage.queued)
            .toList()
          ..sort((a, b) => a.created.compareTo(b.created));
        if (queued.isEmpty) break;
        final job = queued.first;
        try {
          final entries = await _verifyNotificationInputs(job);
          if (disposed || !foreground) break;
          // 取消按钮可能在读取校验期间执行。
          if (job.stage != NotificationDigestStage.queued) continue;
          job.stage = NotificationDigestStage.running;
          await _saveNotificationJob(job);
          _changed();
          final epoch = _notificationPolicyGeneration;
          final text = await _generateNotificationText(job, entries, epoch);
          if (disposed) return;
          _checkNotificationEpoch(epoch);
          await _verifyNotificationInputs(job);
          if (text.trim().isEmpty || text.length > 500000)
            throw const RecordingProcessingException('智能体未返回有效简报，请稍后手动重试。');
          final saved = SavedRecordingSummary(
              id: job.id,
              kind: 'notification',
              scope:
                  '${job.range.from.toUtc().toIso8601String()}/${job.range.to.toUtc().toIso8601String()}',
              inputFingerprint: job.fingerprint,
              text: text,
              created: notificationClock(),
              inputIds: job.inputIds,
              from: job.range.from,
              to: job.range.to);
          await content.put('summaries', saved.id, saved.toJson());
          final stored = (await content.readAll('summaries'))
              .where((v) => v['id'] == saved.id)
              .toList();
          if (stored.length != 1 ||
              jsonEncode(
                      SavedRecordingSummary.fromJson(stored.single).toJson()) !=
                  jsonEncode(saved.toJson()))
            throw const RecordingProcessingException(
                '简报保存尚未确认；未推进本次总结范围，请检查本机存储。');
          _summaries[saved.id] = saved;
          job.stage = NotificationDigestStage.saved;
          job.message = null;
          await _saveNotificationJob(job);
          _changed();
        } catch (error) {
          if (disposed) return;
          // 如果结果已安全保存，队列回执写失败不能把有效简报当成未生成。
          job.stage = _summaries[job.id]?.kind == 'notification'
              ? NotificationDigestStage.saved
              : NotificationDigestStage.failed;
          job.message = job.stage == NotificationDigestStage.saved
              ? '简报已保存，队列状态暂未确认；重开后可从历史结果查看。'
              : error is RecordingProcessingException
                  ? error.message
                  : '通知简报未完成；已有资料保留，请检查私有 Hermes 后手动重试。';
          try {
            await _saveNotificationJob(job);
          } catch (_) {
            message = '通知简报处理状态未安全保存，请检查本机存储。';
          }
          _changed();
        }
      }
    } finally {
      _notificationRun = null;
      completed.complete();
      _changed();
    }
  }

  Future<String> _generateNotificationText(
      NotificationDigestJob job, List<TimelineEntry> entries, int epoch) async {
    final service = agent();
    var rows = <Map<String, String>>[
      for (final e in entries)
        {
          'id': e.id,
          'timestamp': e.timestamp.toUtc().toIso8601String(),
          'appName': e.sourceApp,
          'packageName': e.appIdentifier!,
          'content': e.content
        },
    ];
    for (var level = 0; level < 5; level++) {
      _checkNotificationEpoch(epoch);
      await _verifyNotificationInputs(job);
      if (jsonEncode(rows).length <= 12000) {
        return service.generateNotificationDigest(notifications: rows);
      }
      final chunks = <List<Map<String, String>>>[];
      var current = <Map<String, String>>[];
      for (final row in rows) {
        final body = row['content']!;
        final count = (body.length / 8000).ceil().clamp(1, 100000);
        for (var n = 0; n < count; n++) {
          final item = {
            ...row,
            'content':
                body.substring(n * 8000, math.min(body.length, (n + 1) * 8000)),
            if (count > 1) 'fragment': '${n + 1}/$count'
          };
          if (current.isNotEmpty &&
              jsonEncode([...current, item]).length > 12000) {
            chunks.add(current);
            current = [];
          }
          current.add(item);
        }
      }
      if (current.isNotEmpty) chunks.add(current);
      if (chunks.length > 512)
        throw const RecordingProcessingException('通知正文过多，请缩小时间范围分批生成。');
      final next = <Map<String, String>>[];
      for (var i = 0; i < chunks.length; i++) {
        _checkNotificationEpoch(epoch);
        await _verifyNotificationInputs(job);
        if (disposed)
          throw const RecordingProcessingException('处理已中断，未自动重复提交。');
        final key = await contentFingerprint(
            ['notification-batch-v1', job.serverFingerprint, level, chunks[i]]);
        var partial = _summaries[key];
        if (partial == null) {
          final text = await service.generateNotificationDigest(
              notifications: chunks[i]);
          if (disposed) throw const RecordingProcessingException('处理已中断。');
          _checkNotificationEpoch(epoch);
          await _verifyNotificationInputs(job);
          if (text.trim().isEmpty || text.length > 500000)
            throw const RecordingProcessingException('局部简报未返回有效内容，已完成批次保留。');
          partial = SavedRecordingSummary(
              id: key,
              kind: 'intermediate',
              scope: 'notification:${job.id}',
              inputFingerprint: key,
              text: text,
              created: notificationClock(),
              inputIds: job.inputIds);
          await content.put('summaries', key, partial.toJson());
          _summaries[key] = partial;
        }
        next.add({
          'id': 'batch-${i + 1}-$key',
          'timestamp': job.range.from.toUtc().toIso8601String(),
          'appName': '批次摘要',
          'content': partial.text,
          'sourceType': 'notification_digest_batch'
        });
      }
      rows = next;
    }
    throw const RecordingProcessingException('通知范围过大，已保存局部整理，请缩小范围后生成最终简报。');
  }

  Future<bool> _notificationSummaryCurrent(SavedRecordingSummary saved) async {
    if (saved.from == null || saved.to == null) return false;
    return saved.inputFingerprint ==
        await _notificationFingerprint(
            NotificationDigestRange(
                NotificationDigestMode.custom, saved.from!, saved.to!),
            notificationsInRange(saved.from!, saved.to!));
  }
}

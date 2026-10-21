enum NotificationDigestMode { today, sinceLast, custom }

extension NotificationDigestModeLabel on NotificationDigestMode {
  String get label => switch (this) {
        NotificationDigestMode.today => '今天',
        NotificationDigestMode.sinceLast => '上次总结后',
        NotificationDigestMode.custom => '自定义时间',
      };
}

class NotificationDigestRange {
  final NotificationDigestMode mode;
  final DateTime from, to;
  const NotificationDigestRange(this.mode, this.from, this.to);
}

enum NotificationDigestStage {
  queued,
  running,
  saved,
  failed,
  interrupted,
  cancelled
}

class NotificationDigestJob {
  final String id, fingerprint;
  final NotificationDigestRange range;
  final List<String> inputIds;
  final DateTime created;
  String serverFingerprint;
  NotificationDigestStage stage;
  String? message;
  NotificationDigestJob(
      {required this.id,
      required this.fingerprint,
      required this.range,
      required this.inputIds,
      required this.created,
      required this.serverFingerprint,
      this.stage = NotificationDigestStage.queued,
      this.message});
  String get stageLabel => switch (stage) {
        NotificationDigestStage.queued => '等待处理',
        NotificationDigestStage.running => '正在生成通知简报',
        NotificationDigestStage.saved => '简报已保存',
        NotificationDigestStage.failed => '未完成，可手动重试',
        NotificationDigestStage.interrupted => '上次处理中断，需确认后重试',
        NotificationDigestStage.cancelled => '已取消等待',
      };
  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'mode': range.mode.name,
        'from': range.from.toUtc().toIso8601String(),
        'to': range.to.toUtc().toIso8601String(),
        'inputIds': inputIds,
        'created': created.toUtc().toIso8601String(),
        'serverFingerprint': serverFingerprint,
        'stage': stage.name,
        'message': message
      };
  factory NotificationDigestJob.fromJson(Map<String, dynamic> v) {
    for (final key in ['id', 'fingerprint', 'serverFingerprint']) {
      if (v[key] is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(v[key]))
        throw const FormatException('通知队列指纹无效');
    }
    if (v['id'] != v['fingerprint'] ||
        v['inputIds'] is! List ||
        v['inputIds'].isEmpty ||
        v['inputIds'].length > 5000 ||
        v['inputIds']
            .any((id) => id is! String || id.isEmpty || id.length > 1024) ||
        v['inputIds'].toSet().length != v['inputIds'].length ||
        v['message'] != null &&
            (v['message'] is! String || v['message'].length > 256))
      throw const FormatException('通知队列无效');
    final from = DateTime.parse(v['from']), to = DateTime.parse(v['to']);
    if (!to.isAfter(from) || to.difference(from) > const Duration(days: 31))
      throw const FormatException('通知队列范围无效');
    final stage = NotificationDigestStage.values.byName(v['stage']);
    return NotificationDigestJob(
        id: v['id'],
        fingerprint: v['fingerprint'],
        range: NotificationDigestRange(
            NotificationDigestMode.values.byName(v['mode']), from, to),
        inputIds: List<String>.from(v['inputIds']),
        created: DateTime.parse(v['created']),
        serverFingerprint: v['serverFingerprint'],
        stage: stage == NotificationDigestStage.running
            ? NotificationDigestStage.interrupted
            : stage,
        message: stage == NotificationDigestStage.running
            ? '上次生成结果不确定；未自动重复发送，请确认后重试。'
            : v['message']);
  }
}

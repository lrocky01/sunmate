/// 时光机时间线事件类型
enum TimelineSourceType {
  audioVoice, // 录音卡采集的日常说话/对话
  appNotification, // 手机应用通知 (微信/钉钉/邮件等)
  systemNote, // 系统自动打标或日程备忘
}

/// 全天时光机流水事件项
class TimelineEntry {
  final String id;
  final DateTime timestamp;
  final TimelineSourceType sourceType;
  final String sourceApp; // 来源应用或录音会话 ID
  final String content; // 转写内容或通知正文
  final String tags;
  final String? appIdentifier;
  final DateTime? endTimestamp;
  final String? recordingPartId;

  TimelineEntry({
    required this.id,
    required this.timestamp,
    required this.sourceType,
    required this.sourceApp,
    required this.content,
    this.tags = "",
    this.appIdentifier,
    this.endTimestamp,
    this.recordingPartId,
  });
  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'endTimestamp': endTimestamp?.toUtc().toIso8601String(),
        'sourceType': sourceType.name,
        'sourceApp': sourceApp,
        'content': content,
        'tags': tags,
        'appIdentifier': appIdentifier,
        'recordingPartId': recordingPartId
      };
  factory TimelineEntry.fromJson(Map<String, dynamic> v) {
    for (final key in [
      'id',
      'timestamp',
      'sourceType',
      'sourceApp',
      'content',
      'tags'
    ]) {
      if (v[key] is! String) throw const FormatException('时间轴记录无效');
    }
    if (v['id'].length > 1024 ||
        v['content'].length > 500000 ||
        v['sourceApp'].length > 256 ||
        v['tags'].length > 256 ||
        v['appIdentifier'] != null &&
            (v['appIdentifier'] is! String ||
                !RegExp(r'^[A-Za-z0-9_.-]{1,255}$')
                    .hasMatch(v['appIdentifier'])) ||
        v['recordingPartId'] != null &&
            (v['recordingPartId'] is! String ||
                v['recordingPartId'].length > 512))
      throw const FormatException('时间轴内容无效');
    final start = DateTime.parse(v['timestamp']);
    final end =
        v['endTimestamp'] == null ? null : DateTime.parse(v['endTimestamp']);
    if (end != null && end.isBefore(start))
      throw const FormatException('时间轴区间无效');
    return TimelineEntry(
        id: v['id'],
        timestamp: start,
        endTimestamp: end,
        sourceType: TimelineSourceType.values.byName(v['sourceType']),
        sourceApp: v['sourceApp'],
        content: v['content'],
        tags: v['tags'],
        appIdentifier: v['appIdentifier'],
        recordingPartId: v['recordingPartId']);
  }
}

/// 每日智能体复盘与个人画像报告模型
class DailyProfileReport {
  final DateTime date;
  final String cognitiveReflection; // 认知与决策分析
  final String communicationScore; // 沟通表现与情绪复盘
  final String energyDistribution; // 时间精力分布与效率评估
  final List<String> growthAdvice; // 个性化能力提升建议
  final String fullMarkdown; // 完整 Markdown 报告

  DailyProfileReport({
    required this.date,
    required this.cognitiveReflection,
    required this.communicationScore,
    required this.energyDistribution,
    required this.growthAdvice,
    required this.fullMarkdown,
  });
}

/// 时光机时间线事件类型
enum TimelineSourceType {
  audioVoice,       // 录音卡采集的日常说话/对话
  appNotification,  // 手机应用通知 (微信/钉钉/邮件等)
  systemNote,       // 系统自动打标或日程备忘
}

/// 全天时光机流水事件项
class TimelineEntry {
  final String id;
  final DateTime timestamp;
  final TimelineSourceType sourceType;
  final String sourceApp; // 来源应用或录音会话 ID
  final String content;   // 转写内容或通知正文
  final String tags;

  TimelineEntry({
    required this.id,
    required this.timestamp,
    required this.sourceType,
    required this.sourceApp,
    required this.content,
    this.tags = "",
  });
}

/// 每日智能体复盘与个人画像报告模型
class DailyProfileReport {
  final DateTime date;
  final String cognitiveReflection; // 认知与决策分析
  final String communicationScore;  // 沟通表现与情绪复盘
  final String energyDistribution;   // 时间精力分布与效率评估
  final List<String> growthAdvice;   // 个性化能力提升建议
  final String fullMarkdown;        // 完整 Markdown 报告

  DailyProfileReport({
    required this.date,
    required this.cognitiveReflection,
    required this.communicationScore,
    required this.energyDistribution,
    required this.growthAdvice,
    required this.fullMarkdown,
  });
}

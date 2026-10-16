/// 会议录音与智能体分析归档模型
class MeetingRecord {
  final String id;
  final String title;
  final DateTime createdAt;
  final int durationSeconds;
  final String filePath;
  final String transcript;       // ASR 完整转写文字
  final String summary;          // 智能体生成的结构化会议纪要
  final List<String> actionItems;// 待办任务清单
  final bool isTranscribed;

  MeetingRecord({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.durationSeconds,
    required this.filePath,
    this.transcript = "",
    this.summary = "",
    this.actionItems = const [],
    this.isTranscribed = false,
  });

  MeetingRecord copyWith({
    String? title,
    String? transcript,
    String? summary,
    List<String>? actionItems,
    bool? isTranscribed,
  }) {
    return MeetingRecord(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      durationSeconds: durationSeconds,
      filePath: filePath,
      transcript: transcript ?? this.transcript,
      summary: summary ?? this.summary,
      actionItems: actionItems ?? this.actionItems,
      isTranscribed: isTranscribed ?? this.isTranscribed,
    );
  }
}

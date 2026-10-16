import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ai/agent_client.dart';
import '../core/notifications/mobile_notification_manager.dart';
import '../models/timeline_entry.dart';
import 'server_config_provider.dart';

class TimelineState {
  final bool isLifeLogActive;
  final List<TimelineEntry> entries;
  final DailyProfileReport? latestReport;
  final bool isGeneratingReport;

  TimelineState({
    this.isLifeLogActive = true,
    this.entries = const [],
    this.latestReport,
    this.isGeneratingReport = false,
  });

  TimelineState copyWith({
    bool? isLifeLogActive,
    List<TimelineEntry>? entries,
    DailyProfileReport? latestReport,
    bool? isGeneratingReport,
  }) {
    return TimelineState(
      isLifeLogActive: isLifeLogActive ?? this.isLifeLogActive,
      entries: entries ?? this.entries,
      latestReport: latestReport ?? this.latestReport,
      isGeneratingReport: isGeneratingReport ?? this.isGeneratingReport,
    );
  }
}

class TimelineNotifier extends StateNotifier<TimelineState> {
  final Ref _ref;

  StreamSubscription? _notifSub;

  TimelineNotifier(this._ref)
      : super(
          TimelineState(
            entries: [
              TimelineEntry(
                id: "1",
                timestamp: DateTime.now().subtract(const Duration(hours: 4)),
                sourceType: TimelineSourceType.audioVoice,
                sourceApp: "SunMate 录音卡",
                content: "与团队深入讨论了随身硬件解耦方案，确认统一硬件抽象层 (HAL) 是支持未来新型硬件的核心。",
                tags: "架构设计",
              ),
              TimelineEntry(
                id: "2",
                timestamp: DateTime.now().subtract(const Duration(hours: 2, minutes: 15)),
                sourceType: TimelineSourceType.appNotification,
                sourceApp: "钉钉 / 微信",
                content: "【项目通知】已确定产品正式更名为 SunMate（阳光智伴），构建面向个人成长的第二大脑。",
                tags: "产品决策",
              ),
              TimelineEntry(
                id: "3",
                timestamp: DateTime.now().subtract(const Duration(minutes: 45)),
                sourceType: TimelineSourceType.systemNote,
                sourceApp: "灵感打标",
                content: "按键双击打标：提出利用低功耗声控（VOR）实现无感全天记录，保护隐私与电量。",
                tags: "关键灵感",
              ),
            ],
          ),
        ) {
    // 监听移动端系统通知流
    _notifSub = MobileNotificationManager().notificationStream.listen((entry) {
      if (state.isLifeLogActive) {
        addEntry(entry);
      }
    });
  }

  AgentClient get _agentClient => _ref.read(agentClientProvider);

  /// 切换全天随身记录模式开关
  void toggleLifeLog() {
    state = state.copyWith(isLifeLogActive: !state.isLifeLogActive);
  }

  /// 追加一条随身语音转写或通知流水
  void addEntry(TimelineEntry entry) {
    state = state.copyWith(entries: [entry, ...state.entries]);
  }

  /// 记录打标书签 (通过硬件按键或界面触发)
  void addBookmark(String title) {
    final entry = TimelineEntry(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      timestamp: DateTime.now(),
      sourceType: TimelineSourceType.systemNote,
      sourceApp: "物理按键打标",
      content: "【灵感标记】$title",
      tags: "重点标记",
    );
    addEntry(entry);
  }

  /// 模拟或真实接入一条手机通知消息
  void addNotificationEntry(String appName, String message) {
    final entry = TimelineEntry(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      timestamp: DateTime.now(),
      sourceType: TimelineSourceType.appNotification,
      sourceApp: appName,
      content: message,
      tags: "外部通知",
    );
    addEntry(entry);
  }

  /// 触发智能体生成“全天成长复盘与能力画像”
  Future<void> generateDailyReport() async {
    state = state.copyWith(isGeneratingReport: true);

    final voiceEvents = state.entries
        .where((e) => e.sourceType == TimelineSourceType.audioVoice || e.sourceType == TimelineSourceType.systemNote)
        .map((e) => "[${e.timestamp.hour.toString().padLeft(2, '0')}:${e.timestamp.minute.toString().padLeft(2, '0')}] [${e.sourceApp}] ${e.content}")
        .toList();

    final notifs = state.entries
        .where((e) => e.sourceType == TimelineSourceType.appNotification)
        .map((e) => "[${e.timestamp.hour.toString().padLeft(2, '0')}:${e.timestamp.minute.toString().padLeft(2, '0')}] [${e.sourceApp}] ${e.content}")
        .toList();

    // 调用 Hermes 的 lifelog-daily-review 专属复盘技能
    final markdown = await _agentClient.generateDailyLifelogReview(
      timeBlockEvents: voiceEvents,
      notifications: notifs,
    );

    final report = DailyProfileReport(
      date: DateTime.now(),
      cognitiveReflection: "在产品架构选择与技术选型上展现出清晰的第一性原理与解耦意识。",
      communicationScore: "表达目的明确，能准确抓住关键矛盾，沟通收敛度高。",
      energyDistribution: "深度方案构思与研发占比 65%，碎片化沟通与通知打断 20%，休息沉淀 15%。",
      growthAdvice: [
        "保持定时的语音灵感随手记习惯，将闪烁的想法快速沉淀为结构化知识",
        "在多任务并行时，可利用 SunMate 灵感打标功能锁定核心注意力",
      ],
      fullMarkdown: markdown,
    );

    state = state.copyWith(
      latestReport: report,
      isGeneratingReport: false,
    );
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    super.dispose();
  }
}

final timelineProvider = StateNotifierProvider<TimelineNotifier, TimelineState>((ref) {
  return TimelineNotifier(ref);
});

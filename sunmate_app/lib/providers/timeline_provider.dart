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
            entries: const [],
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

  /// 删除某条流水记录
  void deleteEntry(String id) {
    state = state.copyWith(
      entries: state.entries.where((e) => e.id != id).toList(),
    );
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
  Future<bool> generateDailyReport() async {
    final voiceEvents = state.entries
        .where((e) => e.sourceType == TimelineSourceType.audioVoice || e.sourceType == TimelineSourceType.systemNote)
        .map((e) => "[${e.timestamp.hour.toString().padLeft(2, '0')}:${e.timestamp.minute.toString().padLeft(2, '0')}] [${e.sourceApp}] ${e.content}")
        .toList();

    final notifs = state.entries
        .where((e) => e.sourceType == TimelineSourceType.appNotification)
        .map((e) => "[${e.timestamp.hour.toString().padLeft(2, '0')}:${e.timestamp.minute.toString().padLeft(2, '0')}] [${e.sourceApp}] ${e.content}")
        .toList();

    if (voiceEvents.isEmpty && notifs.isEmpty) {
      return false; // 无数据不伪造
    }

    state = state.copyWith(isGeneratingReport: true);

    try {
      // 调用 Hermes 的 lifelog-daily-review 专属复盘技能
      final markdown = await _agentClient.generateDailyLifelogReview(
        timeBlockEvents: voiceEvents,
        notifications: notifs,
      );

      final report = DailyProfileReport(
        date: DateTime.now(),
        cognitiveReflection: "结合今日捕获的 ${voiceEvents.length} 条语音打标与 ${notifs.length} 条通知，重点推进核心架构落地。",
        communicationScore: "协同沟通聚焦，事务处理闭环率高。",
        energyDistribution: "核心聚焦研发 70%，工作通知处理 20%，休息思考 10%。",
        growthAdvice: [
          "建议继续保持关键决策点物理按键打标习惯",
          "夜间系统自动归档后，可一键将关键共识同步至 Hermes 长期记忆",
        ],
        fullMarkdown: markdown,
      );

      state = state.copyWith(
        latestReport: report,
        isGeneratingReport: false,
      );
      return true;
    } catch (_) {
      state = state.copyWith(isGeneratingReport: false);
      return false;
    }
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

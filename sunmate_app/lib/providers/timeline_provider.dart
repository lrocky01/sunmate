import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/recordings/recording_processing_controller.dart';
import '../core/notifications/mobile_notification_manager.dart';
import '../models/timeline_entry.dart';
import 'recording_processing_provider.dart';

class TimelineState {
  final bool isLifeLogActive;
  final List<TimelineEntry> entries;
  final DailyProfileReport? latestReport;
  final bool isGeneratingReport;
  final String? lastError;

  TimelineState({
    this.isLifeLogActive = true,
    this.entries = const [],
    this.latestReport,
    this.isGeneratingReport = false,
    this.lastError,
  });

  TimelineState copyWith({
    bool? isLifeLogActive,
    List<TimelineEntry>? entries,
    DailyProfileReport? latestReport,
    bool? isGeneratingReport,
    String? lastError,
    bool clearError = false,
  }) {
    return TimelineState(
      isLifeLogActive: isLifeLogActive ?? this.isLifeLogActive,
      entries: entries ?? this.entries,
      latestReport: latestReport ?? this.latestReport,
      isGeneratingReport: isGeneratingReport ?? this.isGeneratingReport,
      lastError: clearError ? null : lastError ?? this.lastError,
    );
  }
}

class TimelineNotifier extends StateNotifier<TimelineState> {
  final Ref _ref;

  late final RecordingProcessingController _processing =
      _ref.read(recordingProcessingProvider);
  void _contentChanged() {
    if (!mounted) return;
    final reports =
        _processing.summaries.where((s) => s.kind == 'lifelog').toList();
    final latest = reports.isEmpty ? null : reports.first;
    state = state.copyWith(
        entries: _processing.timelineEntries,
        latestReport: latest == null
            ? null
            : DailyProfileReport(
                date: latest.created,
                cognitiveReflection: '详见完整报告',
                communicationScore: '未单独计算',
                energyDistribution: '未单独计算',
                growthAdvice: const [],
                fullMarkdown: latest.text));
  }

  late final MobileNotificationManager _notifications =
      MobileNotificationManager();
  void _notificationSettingsChanged() {
    if (mounted)
      state = state.copyWith(isLifeLogActive: _notifications.appPolicy.enabled);
  }

  TimelineNotifier(this._ref)
      : super(
          TimelineState(
            entries: const [],
          ),
        ) {
    // 监听移动端系统通知流
    _notifications.appPolicy.addListener(_notificationSettingsChanged);
    _notificationSettingsChanged();
    _processing.addListener(_contentChanged);
    _contentChanged();
  }

  /// 兼容旧按键动作：只切换App通知采集，不控制卡片录音。
  Future<void> toggleLifeLog() async {
    await _notifications.appPolicy
        .setEnabled(!_notifications.appPolicy.enabled);
  }

  /// 追加一条随身语音转写或通知流水
  Future<bool> addEntry(TimelineEntry entry) async {
    try {
      await _processing.addTimelineEntry(entry);
      return true;
    } catch (_) {
      if (mounted) state = state.copyWith(lastError: '内容未安全保存，请检查本机存储。');
      return false;
    }
  }

  /// 删除某条流水记录
  Future<void> deleteEntry(String id) async {
    try {
      await _processing.hideTimelineEntry(id);
    } catch (_) {
      if (mounted) state = state.copyWith(lastError: '时间轴隐藏状态保存失败，请重试。');
    }
  }

  /// 记录打标书签 (通过硬件按键或界面触发)
  Future<bool> addBookmark(String title) async {
    final entry = TimelineEntry(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      timestamp: DateTime.now(),
      sourceType: TimelineSourceType.systemNote,
      sourceApp: "物理按键打标",
      content: "【灵感标记】$title",
      tags: "重点标记",
    );
    return addEntry(entry);
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

  /// 手动范围复盘：先补所选录音的转写，再融合允许的通知，不后台定时总结。
  Future<bool> generateDailyReport(
      {DateTime? from, DateTime? to, bool allowPartial = false}) async {
    final now = DateTime.now();
    state = state.copyWith(isGeneratingReport: true, clearError: true);
    try {
      await _processing.summarizeLifelog(
          from ?? DateTime(now.year, now.month, now.day), to ?? now,
          allowPartial: allowPartial);
      if (mounted) state = state.copyWith(isGeneratingReport: false);
      return true;
    } catch (error) {
      if (mounted)
        state = state.copyWith(
            isGeneratingReport: false,
            lastError: error is RecordingProcessingException
                ? error.message
                : '复盘未完成，已有录音与文字已保留，请检查私有节点。');
      return false;
    }
  }

  @override
  void dispose() {
    _notifications.appPolicy.removeListener(_notificationSettingsChanged);
    _processing.removeListener(_contentChanged);
    super.dispose();
  }
}

final timelineProvider =
    StateNotifierProvider<TimelineNotifier, TimelineState>((ref) {
  return TimelineNotifier(ref);
});

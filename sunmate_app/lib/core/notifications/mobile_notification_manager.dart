import 'dart:async';
import 'dart:io';
import '../../models/timeline_entry.dart';

/// 移动端原始通知消息模型 (对齐 Android 与 Hermes 规范)
class MobileNotificationEvent {
  final String packageName;
  final String appName;
  final String title;
  final String content;
  final DateTime timestamp;
  final bool isOngoing; // 是否为常驻后台服务通知 (如音乐播放、正在充电等)

  MobileNotificationEvent({
    required this.packageName,
    required this.appName,
    required this.title,
    required this.content,
    required this.timestamp,
    this.isOngoing = false,
  });

  Map<String, dynamic> toJson() => {
        'packageName': packageName,
        'appName': appName,
        'title': title,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// 移动端系统通知拦截与过滤管理器 (跨平台适配)
class MobileNotificationManager {
  static final MobileNotificationManager _instance = MobileNotificationManager._internal();
  factory MobileNotificationManager() => _instance;
  MobileNotificationManager._internal();

  /// 独立实例供本地回归/独立消费者使用，不关闭全局通知流。
  MobileNotificationManager.isolated();

  int _ancsSequence = 0;

  final _notificationStreamController = StreamController<TimelineEntry>.broadcast();
  Stream<TimelineEntry> get notificationStream => _notificationStreamController.stream;

  // 常见噪音包名黑名单 (如系统无意义广播、输入法提示、电池监控等)
  final Set<String> _ignoredPackages = {
    'com.android.systemui',
    'com.google.android.inputmethod.pinyin',
    'com.sohu.inputmethod.sogou',
    'android',
  };

  /// 初始化通知监听服务
  Future<void> initialize() async {
    if (Platform.isAndroid) {
      // Android 端: 检查是否已授予 NotificationListenerService 特殊权限
      // 真实设备可通过 MethodChannel 或 flutter_notification_listener 桥接
    } else if (Platform.isIOS) {
      // iOS ANCS 正文由已鉴权的录音卡驱动接入；普通 App 不直接监听其它 App 通知。
    }
  }

  /// 处理从 Android 原生 NotificationListenerService 上报的原始通知
  void onAndroidNotificationPosted({
    required String packageName,
    required String title,
    required String content,
    required int timestampMillis,
    bool isOngoing = false,
  }) {
    // 1. 过滤常驻系统通知 (如 "微信正在后台运行"、"正在充电")
    if (isOngoing) return;

    // 2. 过滤系统内部无意义包名
    if (_ignoredPackages.contains(packageName)) return;

    // 3. 过滤空白与乱码
    if (content.trim().isEmpty) return;

    final appName = _resolveHumanFriendlyAppName(packageName);
    final entryTime = DateTime.fromMillisecondsSinceEpoch(timestampMillis);

    // 4. 打包为时间轴条目
    final entry = TimelineEntry(
      id: "notif_${timestampMillis}_${packageName.hashCode}",
      timestamp: entryTime,
      sourceType: TimelineSourceType.appNotification,
      sourceApp: appName,
      content: title.isNotEmpty ? "[$title]: $content" : content,
      tags: "外部通知",
    );

    _notificationStreamController.add(entry);
  }

  /// 处理 iOS 端通过快捷指令 (Shortcuts) / 日程推送的通知消息
  void onIosShortcutOrEventIngested({
    required String sourceName,
    required String text,
    DateTime? timestamp,
  }) {
    if (text.trim().isEmpty) return;
    final entryTime = timestamp ?? DateTime.now();

    final entry = TimelineEntry(
      id: "ios_${entryTime.millisecondsSinceEpoch}",
      timestamp: entryTime,
      sourceType: TimelineSourceType.appNotification,
      sourceApp: sourceName,
      content: text,
      tags: "外部通知",
    );

    _notificationStreamController.add(entry);
  }

  /// 处理来自硬件 ANCS (Apple Notification Center Service) 蓝牙透传的 iOS 系统通知
  void onIosAncsNotificationPosted({
    required String appIdentifier,
    required String title,
    required String message,
    String subtitle = '',
    DateTime? timestamp,
  }) {
    if (message.trim().isEmpty && title.trim().isEmpty && subtitle.trim().isEmpty) return;
    final entryTime = timestamp ?? DateTime.now();
    final appName = _resolveHumanFriendlyAppName(appIdentifier);

    // 现有促销标记只分类，不删除通知，也不触发任何网络上传。
    final isPromo = message.contains("退订") ||
        message.contains("优惠券") ||
        message.contains("仅剩") ||
        message.contains("抢购") ||
        message.contains("大促");

    final entry = TimelineEntry(
      id: "ancs_${entryTime.millisecondsSinceEpoch}_${appIdentifier.hashCode}_${++_ancsSequence}",
      timestamp: entryTime,
      sourceType: TimelineSourceType.appNotification,
      sourceApp: appName,
      content: title.isNotEmpty
          ? "[$title]: ${[subtitle, message].where((s) => s.isNotEmpty).join('\n')}"
          : [subtitle, message].where((s) => s.isNotEmpty).join('\n'),
      tags: isPromo ? "外部通知·已过滤" : "外部通知·高价值",
    );

    _notificationStreamController.add(entry);
  }

  /// 将包名 / iOS Bundle Identifier 映射为人类易读的应用名称
  String _resolveHumanFriendlyAppName(String pkg) {
    switch (pkg) {
      // iOS / Android 微信
      case 'com.tencent.xin':
      case 'com.tencent.mm':
        return '微信';
      // iOS / Android 钉钉
      case 'com.laiwang.DingTalk':
      case 'com.alibaba.android.rimet':
        return '钉钉';
      // iOS / Android 飞书
      case 'com.bytedance.ee.lark':
      case 'com.ss.android.lark':
        return '飞书';
      // iOS / Android 企业微信
      case 'com.tencent.wework':
      case 'com.tencent.ww':
        return '企业微信';
      // iOS 短信 / 电话
      case 'com.apple.MobileSMS':
      case 'com.apple.mobilephone':
      case 'com.android.mms':
      case 'com.google.android.apps.messaging':
        return '短信/通话';
      // 邮件
      case 'com.apple.mobilemail':
      case 'com.android.email':
      case 'com.google.android.gm':
        return '邮件';
      // 日程与待办
      case 'com.apple.mobilecal':
      case 'com.apple.reminders':
        return '系统日程/提醒';
      default:
        // 若为未知包名，截取最后一段
        final parts = pkg.split('.');
        return parts.isNotEmpty ? parts.last : pkg;
    }
  }

  void dispose() {
    _notificationStreamController.close();
  }
}

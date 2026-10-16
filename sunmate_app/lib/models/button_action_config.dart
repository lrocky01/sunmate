/// 硬件按键支持的自定义业务行为枚举
enum CustomActionBehavior {
  none,              // 无动作
  pushToTalk,        // 长按对讲 (直连 AI 智能体对话)
  toggleRecording,   // 开始/结束会议录音
  toggleLifeLog,     // 开启/关闭随身记录 (全天模式)
  bookmark,          // 录音/时光打标 (标记重点时刻)
  queryBattery,      // 播报/查询设备电量
}

extension CustomActionBehaviorExt on CustomActionBehavior {
  String get label {
    switch (this) {
      case CustomActionBehavior.pushToTalk:
        return "对讲通话 (直连智能体实时对话)";
      case CustomActionBehavior.toggleRecording:
        return "开始/结束会议录音";
      case CustomActionBehavior.toggleLifeLog:
        return "开启/关闭随身记录 (全天时光机)";
      case CustomActionBehavior.bookmark:
        return "灵感打标 (标记当前重点时刻)";
      case CustomActionBehavior.queryBattery:
        return "查询并播报设备电量";
      case CustomActionBehavior.none:
        return "无动作";
    }
  }
}

/// 用户自定义按键配置模型
class ButtonActionConfig {
  final CustomActionBehavior singleClick;
  final CustomActionBehavior doubleClick;
  final CustomActionBehavior tripleClick;
  final CustomActionBehavior longPress;

  const ButtonActionConfig({
    this.singleClick = CustomActionBehavior.bookmark,        // 单击: 会议录音标签记录 (打标)
    this.doubleClick = CustomActionBehavior.toggleRecording, // 双击: 会议录音开启/结束
    this.tripleClick = CustomActionBehavior.toggleLifeLog,   // 三击: 随身时光机开启/结束
    this.longPress = CustomActionBehavior.pushToTalk,        // 长按: 即时说与 Hermes 对话
  });

  ButtonActionConfig copyWith({
    CustomActionBehavior? singleClick,
    CustomActionBehavior? doubleClick,
    CustomActionBehavior? tripleClick,
    CustomActionBehavior? longPress,
  }) {
    return ButtonActionConfig(
      singleClick: singleClick ?? this.singleClick,
      doubleClick: doubleClick ?? this.doubleClick,
      tripleClick: tripleClick ?? this.tripleClick,
      longPress: longPress ?? this.longPress,
    );
  }
}

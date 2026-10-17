/// YoooClaw (AiNote 6095) 蓝牙 GATT 服务与特征值常量表
class BleConstants {
  // 主业务服务 (Custom OPUS Audio & Control Service)
  static const String serviceOpus = "00010203-0405-0607-0809-0a0b0c0d1913";

  // App 向硬件写命令 (Write / Write Without Response)
  static const String charAppCmdWrite = "00010203-0405-0607-0809-0a0b0c0d2b15";

  // 硬件向 App 上报状态变更与按键事件 (Notify)
  static const String charDeviceEvent = "00010203-0405-0607-0809-0a0b0c0d2b30";

  // 硬件向 App 上报实时语音流 (Raw Opus 40/80 字节 Notify)
  static const String charOpusAudioData = "00010203-0405-0607-0809-0a0b0c0d2b31";

  // 离线文件块传输通道 (Notify / Read)
  static const String charFileData = "00010203-0405-0607-0809-0a0b0c0d2b32";

  // 扩展调试通道
  static const String charExtDebug = "00010203-0405-0607-0809-0a0b0c0d2b33";

  // 标准电池服务与特征值
  static const String serviceBattery = "0000180F-0000-1000-8000-00805F9B34FB";
  static const String charBatteryLevel = "00002A19-0000-1000-8000-00805F9B34FB";

  // Apple Notification Center Service (ANCS) 标准 UUID
  static const String serviceAncs = "7905F431-B5CE-4E99-A40F-4B1E122D00D0";
  static const String charAncsNotificationSource = "9FBF120D-6301-42D9-8C58-25E699A21DBD";
  static const String charAncsControlPoint = "69D1D8F4-AE17-495B-BA50-A248018B29D3";
  static const String charAncsDataSource = "22EAC6E9-24D6-4BB5-BE44-442488A8322C";

  // 硬件向 App 上报 ANCS 系统通知的自定义事件码
  static const int eventAncsNotification = 0x20;
  static const int eventAncsConfigResponse = 0x21;

  // 广播过滤关键字 (官方 C·ONE, AiNote 6095 等全系列)
  static const List<String> targetDevicePrefixes = [
    "C·ONE",
    "C.ONE",
    "C-ONE",
    "CONE",
    "AiNote",
    "ATW6095",
    "6095",
    "Claw",
    "Yooo",
  ];

  /// 智能判定是否为推荐录音卡设备 (支持 C·ONE-4552、AiNote、1913 服务等归一化校验)
  static bool isTargetDevice(String advName, [List<dynamic>? serviceUuids]) {
    if (advName.isEmpty) return false;
    final lower = advName.toLowerCase();

    // 1. 服务 UUID 中包含 1913
    if (serviceUuids != null) {
      for (final u in serviceUuids) {
        final str = u.toString().toLowerCase();
        if (str.contains("1913")) return true;
      }
    }

    // 2. 原始前缀直接包含 (如 C·ONE-4552)
    for (final prefix in targetDevicePrefixes) {
      if (lower.contains(prefix.toLowerCase())) return true;
    }

    // 3. 剥离特殊标点符号后的归一化校验 (如把 'c·one' 变为 'cone')
    final normalized = lower.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    if (normalized.contains("cone") ||
        normalized.contains("ainote") ||
        normalized.contains("6095") ||
        normalized.contains("atw")) {
      return true;
    }

    return false;
  }
}

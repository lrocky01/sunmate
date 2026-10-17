/// 录音卡状态数据模型
class DeviceStatus {
  final bool isConnected;
  final String deviceName;
  final String deviceId;
  final String snNumber;       // 硬件唯一序列号 (例如 SZ12001261804552)
  final int batteryLevel;      // 0 ~ 100%
  final bool isCharging;
  final int recordingState;    // 0: 空闲, 1: 录音中, 2: 暂停
  final int freeStorageBytes;  // 剩余存储字节
  final int gain0;             // 主麦增益 (0~48dB)
  final int gain1;             // 降噪副麦增益 (0~48dB)

  const DeviceStatus({
    this.isConnected = false,
    this.deviceName = "未连接",
    this.deviceId = "",
    this.snNumber = "--",
    this.batteryLevel = 0,
    this.isCharging = false,
    this.recordingState = 0,
    this.freeStorageBytes = 0,
    this.gain0 = 24,
    this.gain1 = 24,
  });

  bool get isRecording => recordingState == 1;
  bool get isPaused => recordingState == 2;

  DeviceStatus copyWith({
    bool? isConnected,
    String? deviceName,
    String? deviceId,
    String? snNumber,
    int? batteryLevel,
    bool? isCharging,
    int? recordingState,
    int? freeStorageBytes,
    int? gain0,
    int? gain1,
  }) {
    return DeviceStatus(
      isConnected: isConnected ?? this.isConnected,
      deviceName: deviceName ?? this.deviceName,
      deviceId: deviceId ?? this.deviceId,
      snNumber: snNumber ?? this.snNumber,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      isCharging: isCharging ?? this.isCharging,
      recordingState: recordingState ?? this.recordingState,
      freeStorageBytes: freeStorageBytes ?? this.freeStorageBytes,
      gain0: gain0 ?? this.gain0,
      gain1: gain1 ?? this.gain1,
    );
  }
}

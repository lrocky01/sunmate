import 'dart:async';
import 'dart:typed_data';

/// 硬件设备类型
enum HardwareDeviceType {
  /// AiNote 6095 Telink 蓝牙录音卡
  ainote6095Ble,

  /// 手机本机麦克风与软按键 (无外设兜底模式)
  phoneInternalMic,

  /// 预留：未来新型外设 (例如：双麦拾音棒、智能胸针、骨传导耳机等)
  customExternalBle,
}

/// 物理或软按键事件动作类型
enum ButtonActionType {
  pressDown,    // 按下
  release,      // 松开
  singleClick,  // 单击
  doubleClick,  // 双击
  tripleClick,  // 三击
  longPress,    // 长按触发
}

/// 统一按键事件
class DeviceButtonEvent {
  final int buttonId; // 按键编号 (主键通常为 1)
  final ButtonActionType action;
  final DateTime timestamp;

  DeviceButtonEvent({
    required this.buttonId,
    required this.action,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() => 'DeviceButtonEvent(btn: $buttonId, action: $action, at: $timestamp)';
}

/// 音频数据格式
enum AudioEncodingFormat {
  rawOpus, // 16kHz Opus (AiNote 6095 蓝牙卡默认)
  pcm16Bit, // 线性 PCM 16bit 16kHz (手机麦克风或解压后数据)
  aac,      // 预留格式
}

/// 统一音频数据包
class AudioDataPacket {
  final Uint8List bytes;
  final AudioEncodingFormat format;
  final int sampleRate; // 如 16000
  final int channels;   // 如 1 (单声道)
  final double amplitude; // 0.0 ~ 1.0 能量/音量分贝指示
  final DateTime timestamp;

  AudioDataPacket({
    required this.bytes,
    required this.format,
    this.sampleRate = 16000,
    this.channels = 1,
    this.amplitude = 0.0,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// 统一硬件设备抽象接口 (HAL - Hardware Abstraction Layer)
/// 任何接入 SunMate 的输入设备（蓝牙卡、未来胸针、手机麦克风）均需实现该接口
abstract class HardwareDeviceDriver {
  /// 驱动类型
  HardwareDeviceType get deviceType;

  /// 设备展示名称
  String get displayName;

  /// 硬件唯一序列号 (SN)
  String get snNumber;

  /// 是否已连接/可用
  bool get isConnected;

  /// 当前电池电量 (0~100，手机原生可取系统电量)
  int get batteryLevel;

  /// 是否正在录音/采集中
  bool get isRecording;

  /// 是否处于暂停状态
  bool get isPaused;

  /// 物理按键事件广播流 (单击、双击、长按等)
  Stream<DeviceButtonEvent> get buttonEvents;

  /// 实时音频数据流 (Opus/PCM)
  Stream<AudioDataPacket> get audioStream;

  /// 设备连接状态与电量变化通知流
  Stream<void> get stateChanges;

  /// 初始化与连接设备
  Future<bool> connect();

  /// 断开连接
  Future<void> disconnect();

  /// 开启录音/开始音频流采集
  Future<bool> startRecording();

  /// 暂停录音
  Future<bool> pauseRecording();

  /// 恢复录音
  Future<bool> resumeRecording();

  /// 停止录音/结束音频流采集
  Future<bool> stopRecording();

  /// 时间戳对齐与时钟同步
  Future<bool> syncTime();

  /// 保存 iOS ANCS 连接请求偏好；系统授权状态由 iOS 单独管理。
  Future<bool> sendAncsConfig({required bool enable, int mode = 3});

  /// 资源释放
  Future<void> dispose();
}

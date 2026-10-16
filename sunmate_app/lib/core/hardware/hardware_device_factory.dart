import 'hardware_device_driver.dart';
import 'ainote_6095_driver.dart';
import 'phone_mic_driver.dart';

/// 硬件驱动管理工厂
class HardwareDeviceFactory {
  static final HardwareDeviceFactory _instance = HardwareDeviceFactory._internal();
  factory HardwareDeviceFactory() => _instance;
  HardwareDeviceFactory._internal();

  final AiNote6095Driver _aiNoteDriver = AiNote6095Driver();
  final PhoneMicDriver _phoneMicDriver = PhoneMicDriver();

  HardwareDeviceDriver? _currentDriver;

  /// 获取当前激活的硬件驱动 (默认为 AiNote 6095 蓝牙卡)
  HardwareDeviceDriver get activeDriver {
    _currentDriver ??= _aiNoteDriver;
    return _currentDriver!;
  }

  /// 切换设备驱动源
  Future<HardwareDeviceDriver> switchDriver(HardwareDeviceType type) async {
    // 暂停旧驱动
    if (_currentDriver != null && _currentDriver!.isRecording) {
      await _currentDriver!.stopRecording();
    }

    switch (type) {
      case HardwareDeviceType.ainote6095Ble:
        _currentDriver = _aiNoteDriver;
        break;
      case HardwareDeviceType.phoneInternalMic:
        _currentDriver = _phoneMicDriver;
        break;
      case HardwareDeviceType.customExternalBle:
        _currentDriver = _aiNoteDriver; // 预留扩展
        break;
    }
    return _currentDriver!;
  }

  AiNote6095Driver get bleDriver => _aiNoteDriver;
  PhoneMicDriver get phoneMicDriver => _phoneMicDriver;

  void dispose() {
    _aiNoteDriver.dispose();
    _phoneMicDriver.dispose();
  }
}

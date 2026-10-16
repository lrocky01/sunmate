import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/hardware/hardware_device_driver.dart';
import '../core/hardware/hardware_device_factory.dart';
import '../models/device_status.dart';

/// 硬件驱动工厂全局 Provider
final deviceFactoryProvider = Provider<HardwareDeviceFactory>((ref) {
  final factory = HardwareDeviceFactory();
  ref.onDispose(() => factory.dispose());
  return factory;
});

/// 设备连接状态与状态机 Notifier (对接 HAL 抽象层)
class DeviceNotifier extends StateNotifier<DeviceStatus> {
  final HardwareDeviceFactory _factory;
  StreamSubscription? _stateSub;

  DeviceNotifier(this._factory) : super(const DeviceStatus()) {
    _bindActiveDriver();
  }

  void _bindActiveDriver() {
    _stateSub?.cancel();
    final driver = _factory.activeDriver;
    _updateStateFromDriver(driver);

    _stateSub = driver.stateChanges.listen((_) {
      _updateStateFromDriver(driver);
    });
  }

  void _updateStateFromDriver(HardwareDeviceDriver driver) {
    state = state.copyWith(
      isConnected: driver.isConnected,
      deviceName: driver.displayName,
      batteryLevel: driver.batteryLevel,
      recordingState: driver.isRecording ? 1 : (driver.isPaused ? 2 : 0),
    );
  }

  /// 切换设备驱动源 (例如：AiNote 6095 蓝牙卡 <-> 手机原生麦克风)
  Future<void> switchDriverType(HardwareDeviceType type) async {
    await _factory.switchDriver(type);
    _bindActiveDriver();
  }

  /// 获取当前激活的硬件驱动
  HardwareDeviceDriver get activeDriver => _factory.activeDriver;

  /// 开始录音
  Future<bool> startRecording() async {
    final success = await _factory.activeDriver.startRecording();
    _updateStateFromDriver(_factory.activeDriver);
    return success;
  }

  /// 停止录音
  Future<bool> stopRecording() async {
    final success = await _factory.activeDriver.stopRecording();
    _updateStateFromDriver(_factory.activeDriver);
    return success;
  }

  /// 暂停录音
  Future<bool> pauseRecording() async {
    final success = await _factory.activeDriver.pauseRecording();
    _updateStateFromDriver(_factory.activeDriver);
    return success;
  }

  /// 恢复录音
  Future<bool> resumeRecording() async {
    final success = await _factory.activeDriver.resumeRecording();
    _updateStateFromDriver(_factory.activeDriver);
    return success;
  }

  /// 同步时钟
  Future<void> syncTime() async {
    await _factory.activeDriver.syncTime();
  }

  /// 向硬件下发 iOS ANCS 通知配置
  Future<bool> sendAncsConfig({required bool enable, int mode = 3}) async {
    return await _factory.activeDriver.sendAncsConfig(enable: enable, mode: mode);
  }

  /// 刷新状态
  Future<void> refreshStatus() async {
    _updateStateFromDriver(_factory.activeDriver);
  }

  /// 扫描附近蓝牙录音卡
  Stream<List<ScanResult>> scanNearbyDevices() {
    return _factory.bleDriver.scanNearbyDevices();
  }

  /// 停止蓝牙扫描
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
  }

  /// 获取最近一次连接失败的真实错误详情
  String? get lastError => _factory.bleDriver.lastErrorMessage;

  /// 连接指定的蓝牙外设
  Future<bool> connectDevice(BluetoothDevice device) async {
    await stopScan(); // 关键：连接前彻底停止扫描
    await switchDriverType(HardwareDeviceType.ainote6095Ble);
    final ok = await _factory.bleDriver.connectDevice(device);
    _updateStateFromDriver(_factory.activeDriver);
    return ok;
  }

  /// 断开当前设备连接
  Future<void> disconnectDevice() async {
    await _factory.activeDriver.disconnect();
    _updateStateFromDriver(_factory.activeDriver);
  }

  /// 解除当前设备绑定 (清除已保存的设备信息)
  Future<void> unpairDevice() async {
    await _factory.bleDriver.unpairDevice();
    _updateStateFromDriver(_factory.activeDriver);
  }

  /// 尝试自动重连上次保存的录音卡
  Future<bool> autoReconnect() async {
    final ok = await _factory.bleDriver.autoReconnectLastDevice();
    _updateStateFromDriver(_factory.activeDriver);
    return ok;
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    super.dispose();
  }
}

final deviceProvider = StateNotifierProvider<DeviceNotifier, DeviceStatus>((ref) {
  final factory = ref.watch(deviceFactoryProvider);
  return DeviceNotifier(factory);
});

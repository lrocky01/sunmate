import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ble/ble_constants.dart';
import '../core/hardware/hardware_device_driver.dart';
import '../providers/device_provider.dart';
import '../main.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = ref.watch(deviceProvider);
    final devNotifier = ref.read(deviceProvider.notifier);
    final activeDriver = devNotifier.activeDriver;

    return Scaffold(
      appBar: AppBar(
        title: const Text("SunMate 阳光智伴"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "刷新状态",
            onPressed: () => devNotifier.refreshStatus(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. 硬件连接与状态卡片
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: device.isConnected ? const Color(0xFFE8F5E9) : const Color(0xFFFFF3E0),
                          radius: 28,
                          child: Icon(
                            activeDriver.deviceType == HardwareDeviceType.phoneInternalMic
                                ? Icons.phone_android
                                : Icons.bluetooth,
                            color: device.isConnected ? Colors.green.shade700 : const Color(0xFFFF8C00),
                            size: 32,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                device.isConnected ? device.deviceName : "未连接随身设备",
                                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                device.isConnected
                                    ? (activeDriver.deviceType == HardwareDeviceType.phoneInternalMic
                                        ? "原生麦克风就绪 (无外设模式)"
                                        : "蓝牙卡连接正常 (GATT 已就绪)")
                                    : "设备待连接 (可一键切换为手机麦克风)",
                                style: TextStyle(
                                  color: device.isConnected ? Colors.green.shade700 : Colors.grey,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 32),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _StatusIndicator(
                          icon: Icons.battery_charging_full,
                          label: "电量",
                          value: device.isConnected
                              ? (device.batteryLevel > 0 ? "${device.batteryLevel}%" : "读取中...")
                              : "--",
                          color: device.isConnected
                              ? (device.batteryLevel > 20
                                  ? Colors.green
                                  : (device.batteryLevel > 0 ? Colors.red : Colors.orange))
                              : Colors.grey,
                        ),
                        _StatusIndicator(
                          icon: Icons.fiber_manual_record,
                          label: "状态",
                          value: device.isConnected
                              ? (device.isRecording
                                  ? "采集中"
                                  : (device.isPaused ? "已暂停" : "待命"))
                              : "未连接",
                          color: device.isConnected
                              ? (device.isRecording ? Colors.red : Colors.green.shade700)
                              : Colors.grey,
                        ),
                        _StatusIndicator(
                          icon: Icons.graphic_eq,
                          label: "驱动源",
                          value: activeDriver.deviceType == HardwareDeviceType.phoneInternalMic
                              ? "手机麦克风"
                              : "6095 蓝牙卡",
                          color: const Color(0xFFFF8C00),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    // 蓝牙硬件设备扫描与连接按钮
                    if (!device.isConnected)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF8C00),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: const Icon(Icons.bluetooth_searching, size: 20),
                          label: const Text("🔍 搜索并连接 AiNote 蓝牙卡",
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          onPressed: () => showBleDevicePickerModal(context, ref),
                        ),
                      )
                    else ...[
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.grey.shade700,
                                side: BorderSide(color: Colors.grey.shade400),
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.bluetooth_disabled, size: 18),
                              label: const Text("断开", style: TextStyle(fontSize: 13)),
                              onPressed: () => devNotifier.disconnectDevice(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red.shade700,
                                side: BorderSide(color: Colors.red.shade300),
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.link_off, size: 18),
                              label: const Text("解绑设备", style: TextStyle(fontSize: 13)),
                              onPressed: () async {
                                await devNotifier.unpairDevice();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text("已清除设备绑定记录")),
                                  );
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFF8C00),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.sync, size: 18),
                              label: const Text("重新配对", style: TextStyle(fontSize: 13)),
                              onPressed: () => showBleDevicePickerModal(context, ref),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // 2. 快捷控制
            const Text("快速录音控制 (亦可直接操作硬件按键)", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: device.isRecording ? const Color(0xFFE65100) : const Color(0xFFFF8C00),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: Icon(device.isRecording ? Icons.pause : Icons.mic),
                    label: Text(device.isRecording ? "暂停录音" : "开启录音"),
                    onPressed: () {
                      if (device.isRecording) {
                        devNotifier.pauseRecording();
                      } else {
                        devNotifier.startRecording();
                      }
                    },
                  ),
                ),
                if (device.isRecording || device.isPaused) ...[
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey.shade800,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.stop),
                    label: const Text("结束并保存"),
                    onPressed: () => devNotifier.stopRecording(),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 28),

            // 3. SunMate 三大核心功能引导
            const Text("SunMate 核心场景", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            _FeatureTile(
              icon: Icons.record_voice_over,
              title: "长按对讲 (直连智能体)",
              subtitle: "即按即说，物理键与屏幕软按键无缝呼叫第二大脑",
              color: const Color(0xFFFF8C00),
              onTap: () => ref.read(currentTabProvider.notifier).state = 1,
            ),
            _FeatureTile(
              icon: Icons.groups,
              title: "会议录音与纪要提炼",
              subtitle: "高精度 ASR 自动转写，提炼核心共识与待办清单 Action Items",
              color: Colors.indigo,
              onTap: () => ref.read(currentTabProvider.notifier).state = 2,
            ),
            _FeatureTile(
              icon: Icons.timeline,
              title: "随身时光机与成长画像",
              subtitle: "低功耗 VOR 声控记录 + 手机通知对齐，每日复盘认知决策",
              color: Colors.teal,
              onTap: () => ref.read(currentTabProvider.notifier).state = 3,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusIndicator extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatusIndicator({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 26),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}

class _FeatureTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback? onTap;

  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: color.withOpacity(0.12),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}

/// 弹出蓝牙设备搜索与连接半屏弹窗
void showBleDevicePickerModal(BuildContext context, WidgetRef ref) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => const _BleDevicePickerModal(),
  );
}

class _BleDevicePickerModal extends ConsumerStatefulWidget {
  const _BleDevicePickerModal();

  @override
  ConsumerState<_BleDevicePickerModal> createState() => _BleDevicePickerModalState();
}

class _BleDevicePickerModalState extends ConsumerState<_BleDevicePickerModal> {
  bool _isConnecting = false;
  String? _connectingDeviceId;
  String? _connectingDeviceName;
  String? _connectionError;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  void _startScan() {
    setState(() {
      _connectionError = null;
    });
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
  }

  @override
  void dispose() {
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devNotifier = ref.read(deviceProvider.notifier);

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("搜索蓝牙录音卡设备",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    SizedBox(height: 2),
                    Text("请确保 C·ONE / AiNote 6095 处于开机状态",
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: "重新扫描",
                  onPressed: _isConnecting ? null : _startScan,
                ),
              ],
            ),
          ),

          // 连接错误提示卡片
          if (_connectionError != null) ...[
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade300),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _connectionError!,
                      style: TextStyle(fontSize: 12, color: Colors.red.shade900, height: 1.3),
                    ),
                  ),
                  TextButton(
                    onPressed: _startScan,
                    child: const Text("重试", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ],

          // iOS 系统配对重要提示横幅
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF8E1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFFD54F)),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, size: 18, color: Color(0xFFE65100)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "重要提示：点击连接后，iOS 系统若弹出【想要与您的 iPhone 配对】，请务必点击【配对】；连接成功后硬件指示灯将常亮就绪。",
                    style: TextStyle(fontSize: 11, color: Color(0xFFE65100), height: 1.3),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // 主体内容：正在连接提示 vs 扫描设备列表
          Expanded(
            child: _isConnecting
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 52,
                            height: 52,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFF8C00)),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            "正在连接 ${_connectingDeviceName ?? '录音卡'}...",
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            "已独占蓝牙通道，正在下发鉴权握手与状态同步...\n请留意硬件指示灯由快闪转为常亮",
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.5),
                          ),
                        ],
                      ),
                    ),
                  )
                : StreamBuilder<List<ScanResult>>(
                    // 仅监听纯流 scanResults，坚决不重新调用 scanNearbyDevices()
                    stream: FlutterBluePlus.scanResults,
                    builder: (context, snapshot) {
                      final allResults = snapshot.data ?? [];

                      // 1. 过滤掉所有无名字的匿名广播
                      final validResults = allResults.where((item) {
                        final n = item.device.platformName.isNotEmpty
                            ? item.device.platformName
                            : item.advertisementData.advName;
                        return n.trim().isNotEmpty;
                      }).toList();

                      if (validResults.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.bluetooth_searching, size: 48, color: Colors.grey.shade400),
                                const SizedBox(height: 12),
                                const Text("正在搜索附近的蓝牙录音卡...",
                                    style: TextStyle(fontWeight: FontWeight.bold)),
                                const SizedBox(height: 8),
                                const Text(
                                  "提示：\n1. 请确认录音卡处于开机状态；\n2. 若名称包含 C·ONE 或 AiNote，请靠近手机；\n3. 若硬件卡已连其它设备，请长按按键 3 秒重新广播配对。",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.5),
                                ),
                                const SizedBox(height: 16),
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFFF8C00),
                                    foregroundColor: Colors.white,
                                  ),
                                  icon: const Icon(Icons.refresh),
                                  label: const Text("重新搜索"),
                                  onPressed: _startScan,
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      // 2. 智能排序：推荐录音卡置顶 (支持 C·ONE-4552, AiNote 等)，其余按信号由强到弱排序
                      validResults.sort((a, b) {
                        final nameA = a.device.platformName.isNotEmpty ? a.device.platformName : a.advertisementData.advName;
                        final nameB = b.device.platformName.isNotEmpty ? b.device.platformName : b.advertisementData.advName;

                        final isTargetA = BleConstants.isTargetDevice(nameA, a.advertisementData.serviceUuids);
                        final isTargetB = BleConstants.isTargetDevice(nameB, b.advertisementData.serviceUuids);

                        if (isTargetA && !isTargetB) return -1;
                        if (!isTargetA && isTargetB) return 1;
                        return b.rssi.compareTo(a.rssi);
                      });

                      return ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        itemCount: validResults.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = validResults[index];
                          final name = item.device.platformName.isNotEmpty
                              ? item.device.platformName
                              : item.advertisementData.advName;

                          final isTarget = BleConstants.isTargetDevice(name, item.advertisementData.serviceUuids);

                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            leading: CircleAvatar(
                              backgroundColor: isTarget ? const Color(0xFFFFF3E0) : Colors.grey.shade100,
                              child: Icon(
                                Icons.bluetooth,
                                color: isTarget ? const Color(0xFFFF8C00) : Colors.grey.shade600,
                              ),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    name,
                                    style: TextStyle(
                                      fontWeight: isTarget ? FontWeight.bold : FontWeight.normal,
                                      color: isTarget ? const Color(0xFFE65100) : Colors.black87,
                                    ),
                                  ),
                                ),
                                if (isTarget)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFF8C00).withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text("推荐录音卡",
                                        style: TextStyle(fontSize: 10, color: Color(0xFFE65100), fontWeight: FontWeight.bold)),
                                  ),
                              ],
                            ),
                            subtitle: Text("信号: ${item.rssi} dBm · ID: ${item.device.remoteId.str}",
                                style: const TextStyle(fontSize: 11, color: Colors.grey)),
                            trailing: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isTarget ? const Color(0xFFFF8C00) : Colors.grey.shade200,
                                foregroundColor: isTarget ? Colors.white : Colors.black87,
                                elevation: isTarget ? 1 : 0,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              child: const Text("连接"),
                              onPressed: () async {
                                // 1. 彻底停止扫描，独占 CoreBluetooth 通道，防止连接被打断
                                await FlutterBluePlus.stopScan();

                                setState(() {
                                  _isConnecting = true;
                                  _connectingDeviceId = item.device.remoteId.str;
                                  _connectingDeviceName = name;
                                  _connectionError = null;
                                });

                                final ok = await devNotifier.connectDevice(item.device);

                                if (mounted) {
                                  setState(() {
                                    _isConnecting = false;
                                    _connectingDeviceId = null;
                                  });

                                  if (ok) {
                                    Navigator.of(context).pop();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text("✓ 已成功连接到 $name！指示灯已就绪"),
                                        backgroundColor: Colors.green.shade700,
                                      ),
                                    );
                                  } else {
                                    final err = devNotifier.lastError ?? "连接握手超时";
                                    setState(() {
                                      _connectionError = "连接未完成: $err\n请靠近录音卡或长按按键 3 秒进入配对状态后重试";
                                    });
                                  }
                                }
                              },
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/hardware/hardware_device_driver.dart';
import '../providers/device_provider.dart';

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
                                device.deviceName,
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
                          value: "${device.batteryLevel}%",
                          color: device.batteryLevel > 20 ? Colors.green : Colors.red,
                        ),
                        _StatusIndicator(
                          icon: Icons.fiber_manual_record,
                          label: "状态",
                          value: device.isRecording
                              ? "采集中"
                              : (device.isPaused ? "已暂停" : "待命"),
                          color: device.isRecording ? Colors.red : Colors.grey.shade700,
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
            ),
            _FeatureTile(
              icon: Icons.groups,
              title: "会议录音与纪要提炼",
              subtitle: "高精度 ASR 自动转写，提炼核心共识与待办清单 Action Items",
              color: Colors.indigo,
            ),
            _FeatureTile(
              icon: Icons.timeline,
              title: "随身时光机与成长画像",
              subtitle: "低功耗 VOR 声控记录 + 手机通知对齐，每日复盘认知决策",
              color: Colors.teal,
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

  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.12),
          child: Icon(icon, color: color),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.grey),
      ),
    );
  }
}

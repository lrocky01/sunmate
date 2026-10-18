import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ble/ble_constants.dart';
import '../core/ble/ble_protocol.dart';
import '../core/ble/yoooclaw_account.dart';
import '../core/hardware/hardware_device_driver.dart';
import '../providers/device_provider.dart';
import 'recorder_account_sheet.dart';
import 'recorder_device_status.dart';
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
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("SunMate 阳光智伴", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            Text("v1.0.22+23 · 蓝牙配对与诊断", style: TextStyle(fontSize: 11, color: Colors.black54)),
          ],
        ),
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
                                device.isConnected || devNotifier.isBleLinkConnected ? device.deviceName : "未连接随身设备",
                                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                              ),
                              if (device.snNumber.isNotEmpty && device.snNumber != "--") ...[
                                const SizedBox(height: 2),
                                Text(
                                  "SN: ${device.snNumber}",
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: Colors.black54,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 2),
                              Text(
                                device.isConnected
                                    ? (activeDriver.deviceType == HardwareDeviceType.phoneInternalMic
                                        ? "原生麦克风就绪 (无外设模式)"
                                        : devNotifier.connectionSummary)
                                    : devNotifier.connectionSummary,
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
                    TextButton.icon(
                      icon: const Icon(Icons.receipt_long, size: 18),
                      label: const Text('录音卡设置与诊断'),
                      onPressed: () => showModalBottomSheet<void>(
                        context: context, isScrollControlled: true,
                        builder: (_) => const BleDiagnosticsSheet(),
                      ),
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
                    if (!device.isConnected && !devNotifier.isBleLinkConnected && !devNotifier.isBleConnecting)
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
                              onPressed: () => activeDriver.deviceType == HardwareDeviceType.phoneInternalMic
                                  ? devNotifier.disconnectDevice() : devNotifier.cancelBleConnection(),
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
                              label: const Text("清除记录", style: TextStyle(fontSize: 13)),
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
                              label: const Text("查看连接", style: TextStyle(fontSize: 13)),
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

/// 断开后和下次启动仍可查看最近一次连接记录。
class BleDiagnosticsSheet extends ConsumerWidget {
  const BleDiagnosticsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(deviceProvider);
    final notifier = ref.read(deviceProvider.notifier);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Expanded(child: Text('录音卡设置 · 1.0.22+23', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                IconButton(
                  tooltip: '复制诊断日志', icon: const Icon(Icons.copy),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: notifier.diagnosticText));
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('诊断日志已复制')));
                  },
                ),
              ]),
              Text(notifier.connectionSummary),
              const SizedBox(height: 8),
              const Text('日志包含设备标识、GATT 与系统错误，不包含密钥或通知正文。', style: TextStyle(fontSize: 12, color: Colors.grey)),
              const Divider(),
              Expanded(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                RecorderDeviceStatusPanel(details: notifier.bleConnectionDetails),
                ExpansionTile(tilePadding: EdgeInsets.zero, title: const Text('完整诊断日志'), children: [SelectableText(notifier.diagnosticText, style: const TextStyle(fontFamily: 'monospace', fontSize: 11))]),
              ]))),
              TextButton.icon(
                onPressed: () => showModalBottomSheet(
                  context: context, isScrollControlled: true,
                  builder: (_) => const RecorderAccountSheet()),
                icon: const Icon(Icons.key), label: const Text('通过自己的官方账号恢复设备绑定')),
              if (notifier.isBleLinkConnected || notifier.isBleConnecting)
                TextButton(onPressed: notifier.cancelBleConnection, child: const Text('取消并断开蓝牙连接')),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
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
    builder: (ctx) => const RecorderConnectionSheet(),
  );
}

class RecorderConnectionSheet extends ConsumerStatefulWidget {
  final YoooClawAccount? account;
  const RecorderConnectionSheet({super.key, this.account});

  @override
  ConsumerState<RecorderConnectionSheet> createState() => _BleDevicePickerModalState();
}

class _BleDevicePickerModalState extends ConsumerState<RecorderConnectionSheet> {
  late final YoooClawAccount _account;
  late final DeviceNotifier _deviceNotifier;
  AccountRecorderDevice? _selectedAccountDevice;
  bool _addingNewDevice = false;
  bool _isConnecting = false;
  String? _connectingDeviceName;
  String? _connectionError;
  StreamSubscription<String>? _logSub;

  @override
  void initState() {
    super.initState();
    _account = widget.account ?? YoooClawAccount();
    _deviceNotifier = ref.read(deviceProvider.notifier);
    // 监听底层实时诊断日志，逐行驱动 UI 点亮
    _logSub = ref.read(deviceProvider.notifier).logStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _startScan() async {
    setState(() {
      _connectionError = null;
    });
    try {
      // 关键第一性原理：必须等待 CBCentralManager 状态变为 poweredOn 再扫描
      // 若当前为 unknown 或 unauthorized，直接调用 startScan 会静默失败
      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        await FlutterBluePlus.adapterState
            .where((s) => s == BluetoothAdapterState.on)
            .first
            .timeout(const Duration(seconds: 4));
      }
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectionError = "蓝牙未就绪或未授权，请确认 iPhone 蓝牙已开启且允许 App 访问蓝牙";
        });
      }
    }
  }

  @override
  void dispose() {
    _logSub?.cancel();
    if (_isConnecting) {
      unawaited(_deviceNotifier.cancelBleConnection());
    }
    _account.close();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Widget _deviceSettings(DeviceNotifier notifier) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ExpansionTile(
        title: const Text('设备资料与连接方式', style: TextStyle(fontSize: 14)),
        subtitle: Text(notifier.requiresAncs ? '录音并请求 iPhone 通知' : '仅录音连接',
            style: const TextStyle(fontSize: 12)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          if (_selectedAccountDevice != null)
            RecorderAccountDeviceInfo(device: _selectedAccountDevice!)
          else
            const Text('选择附近的新录音卡后，验证设备身份并保存绑定。当前首次添加支持 C·ONE（Telink）。'),
          if (notifier.supportsAncsRequestConfiguration)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('请求 iPhone 通知服务'),
              subtitle: const Text('关闭可对照仅录音连接，业务身份验证仍保留'),
              value: notifier.requiresAncs,
              onChanged: _isConnecting || notifier.isBleConnecting || notifier.isBleLinkConnected
                  ? null : (value) async {
                    await notifier.configureBleAncsRequest(value);
                    if (mounted) setState(() {});
                  },
            ),
          const Text('先断开其它手机的蓝牙连接。已有系统配对时可能不再弹窗；不要因连接失败而解绑或重置卡片。', style: TextStyle(fontSize: 12)),
        ],
      ),
      if (_connectionError != null) ...[
        Padding(padding: const EdgeInsets.all(12), child: Text(_connectionError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error))),
        TextButton.icon(icon: const Icon(Icons.receipt_long, size: 18),
          label: const Text('查看并复制完整诊断日志'),
          onPressed: () => showModalBottomSheet<void>(context: context,
              isScrollControlled: true, builder: (_) => const BleDiagnosticsSheet())),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    final devNotifier = ref.read(deviceProvider.notifier);

    if (_selectedAccountDevice == null && !_addingNewDevice) {
      return Material(color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: RecorderAccountSheet(account: _account, closeAccountOnDispose: false,
        onReconnectVerified: devNotifier.canReconnectVerifiedDevice ? () async {
          _isConnecting = true;
          final connected = await devNotifier.autoReconnect();
          if (!mounted) return connected;
          _isConnecting = false;
          if (connected) Navigator.of(context).maybePop();
          return connected;
        } : null,
        onSelectDevice: (device) {
          setState(() => _selectedAccountDevice = device);
          _startScan();
        },
        onAddDevice: () {
          setState(() => _addingNewDevice = true);
          _startScan();
        }));
    }

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
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  tooltip: '返回账号设备',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _isConnecting ? null : () {
                    unawaited(FlutterBluePlus.stopScan());
                    setState(() {
                      _addingNewDevice = false;
                      _selectedAccountDevice = null;
                      _connectionError = null;
                    });
                  },
                ),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_addingNewDevice ? '添加新录音卡' : '录音卡连接设置',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(_addingNewDevice ? '搜索附近卡片并验证身份' : '账号 SN：${_selectedAccountDevice!.serialNumber}',
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ],
                )),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (devNotifier.supportsAncsRequestConfiguration)
                      PopupMenuButton<bool>(
                        tooltip: '蓝牙连接方式',
                        enabled: !_isConnecting && !devNotifier.isBleConnecting &&
                            !devNotifier.isBleLinkConnected,
                        initialValue: devNotifier.requiresAncs,
                        icon: Icon(devNotifier.requiresAncs
                            ? Icons.notifications_active_outlined : Icons.mic_none),
                        onSelected: (value) async {
                          await devNotifier.configureBleAncsRequest(value);
                          if (mounted) setState(() {});
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: true, child: Text('录音并请求 iPhone 通知')),
                          PopupMenuItem(value: false, child: Text('仅录音连接')),
                        ],
                      ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: "重新扫描",
                      onPressed: _isConnecting ? null : _startScan,
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: "关闭弹窗",
                      onPressed: () async {
                        if (_isConnecting) await devNotifier.cancelBleConnection();
                        if (!mounted) return;
                        setState(() {
                          _isConnecting = false;
                        });
                        Navigator.of(context).maybePop();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // 主体内容：正在连接提示 (带实时诊断日志) vs 扫描设备列表
          Expanded(
            child: _isConnecting
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _deviceSettings(devNotifier),
                          const SizedBox(height: 16),
                          // 若日志中已经出现成功握手，显示大号绿勾，否则显示转圈
                          ref.watch(deviceProvider).isConnected
                              ? const Icon(Icons.check_circle, color: Color(0xFF2E7D32), size: 52)
                              : const SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFF8C00)),
                                  ),
                                ),
                          const SizedBox(height: 14),
                          Text(
                            '${_connectingDeviceName ?? "录音卡"}：${devNotifier.connectionSummary}',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 12),
                          RecorderDeviceStatusPanel(details: devNotifier.bleConnectionDetails),
                          ExpansionTile(
                            title: const Text('本次连接日志'),
                            children: [SelectableText(devNotifier.connectionLogs.join('\n'),
                                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'))],
                          ),
                          const SizedBox(height: 16),
                          // 操作按钮组：完成进入主界面 或 取消连接
                          if (ref.watch(deviceProvider).isConnected) ...[
                            SizedBox(
                              width: double.infinity,
                              height: 44,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF2E7D32),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                icon: const Icon(Icons.done_all),
                                label: const Text("完成并进入主界面", style: TextStyle(fontWeight: FontWeight.bold)),
                                onPressed: () {
                                  setState(() {
                                    _isConnecting = false;
                                  });
                                  Navigator.of(context).maybePop();
                                },
                              ),
                            ),
                          ] else ...[
                            TextButton.icon(
                              icon: const Icon(Icons.cancel_outlined, size: 18),
                              label: const Text("取消连接并返回"),
                              style: TextButton.styleFrom(foregroundColor: Colors.grey.shade700),
                              onPressed: () async {
                                await devNotifier.cancelBleConnection();
                                if (!mounted) return;
                                setState(() {
                                  _isConnecting = false;
                                });
                              },
                            ),
                          ],
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
                        return ListView(children: [
                          _deviceSettings(devNotifier),
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.bluetooth_searching, size: 48, color: Colors.grey.shade400),
                                const SizedBox(height: 12),
                                Text(_connectionError != null
                                    ? '暂时无法搜索录音卡'
                                    : FlutterBluePlus.isScanningNow
                                        ? '正在搜索附近的蓝牙录音卡...'
                                        : '没有发现录音卡',
                                    style: const TextStyle(fontWeight: FontWeight.bold)),
                                const SizedBox(height: 8),
                                Text(
                                  _addingNewDevice
                                      ? '请将 C·ONE 开机并靠近手机，断开其它手机的蓝牙连接后重新搜索。'
                                      : "提示：\n1. 请确认录音卡处于开机状态；\n2. 若名称包含 C·ONE 或 AiNote，请靠近手机；\n3. 若录音卡刚连接过 Android，请先关闭 Android 蓝牙，再重新扫描。",
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 12, color: Colors.black54, height: 1.5),
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
                        ]);
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
                        itemCount: validResults.length + 1,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          if (index == 0) return _deviceSettings(devNotifier);
                          final item = validResults[index - 1];
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
                            subtitle: Text("${_addingNewDevice ? 'SN: ${RecorderAdvertisementSerial.telink(item.advertisementData.manufacturerData) ?? '未识别'}\n' : ''}信号: ${item.rssi} dBm · 广播${item.advertisementData.connectable ? '可连接' : '未标为可连接'}\nID: ${item.device.remoteId.str}",
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
                                if (_isConnecting || devNotifier.isBleConnecting) return;

                                setState(() {
                                  _isConnecting = true;
                                  _connectingDeviceName = name;
                                  _connectionError = null;
                                });

                                var ok = false;
                                String? operationError;
                                try {
                                  final identity = RecorderScanIdentity.fromAdvertisement(
                                      remoteId: item.device.remoteId.str,
                                      deviceName: name,
                                      manufacturerData: item.advertisementData.manufacturerData,
                                      connectable: item.advertisementData.connectable,
                                      observedAt: item.timeStamp);
                                  if (_addingNewDevice && identity == null) {
                                    throw const OfficialAccountException('未取得新鲜且完整的 C·ONE 广播，请重新搜索后选择');
                                  }
                                  ok = await devNotifier.connectDevice(item.device,
                                      accountSession: _addingNewDevice
                                          ? _account.sessionForNewDevice(identity!)
                                          : _account.sessionForDevice(_selectedAccountDevice!));
                                } on OfficialAccountException catch (error) {
                                  operationError = error.message;
                                } catch (_) {
                                  operationError = '蓝牙操作未完成，请查看并复制诊断日志';
                                }

                                if (mounted) {
                                  if (ok) {
                                    // 成功时重置连接状态，保持就绪状态展示 600ms 后平滑退出弹窗
                                    setState(() {
                                      _isConnecting = false;
                                    });
                                    await Future.delayed(const Duration(milliseconds: 600));
                                    if (mounted) {
                                      Navigator.of(context).maybePop();
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text("$name：设备业务已验证"),
                                          backgroundColor: Colors.green.shade700,
                                        ),
                                      );
                                    }
                                  } else {
                                    final err = operationError ?? devNotifier.lastError ?? "连接握手超时";
                                    setState(() {
                                      _isConnecting = false;
                                      _connectionError = '${devNotifier.connectionSummary}\n$err';
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

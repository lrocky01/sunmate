import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/hardware/hardware_device_driver.dart';
import '../models/button_action_config.dart';
import '../providers/button_action_provider.dart';
import '../providers/device_provider.dart';
import '../providers/server_config_provider.dart';
import 'home_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final TextEditingController _asrUrlController =
      TextEditingController(text: "http://127.0.0.1:8000");
  final TextEditingController _asrTokenController = TextEditingController();
  final TextEditingController _hermesUrlController =
      TextEditingController(text: "http://127.0.0.1:8080/v1");
  final TextEditingController _hermesTokenController = TextEditingController();

  String _asrStatusText = "未测试";
  Color _asrStatusColor = Colors.grey;
  String _hermesStatusText = "未测试";
  Color _hermesStatusColor = Colors.grey;
  bool _isTesting = false;

  void _syncConfigToProvider() {
    ref.read(serverConfigProvider.notifier).updateConfig(
          asrBaseUrl: _asrUrlController.text.trim(),
          asrToken: _asrTokenController.text.trim(),
          hermesBaseUrl: _hermesUrlController.text.trim(),
          hermesToken: _hermesTokenController.text.trim(),
        );
  }

  Future<void> _testAsrConnection() async {
    _syncConfigToProvider();
    setState(() {
      _asrStatusText = "正在探活...";
      _asrStatusColor = Colors.orange;
    });

    final asr = ref.read(asrServiceProvider);
    final ok = await asr.checkHealth();

    setState(() {
      if (ok) {
        _asrStatusText = "✓ MOSS-ASR 健康检查通过 (MLX int5 就绪)";
        _asrStatusColor = Colors.green;
      } else {
        _asrStatusText = "✗ 连接失败，请检查端口、Token与外网映射";
        _asrStatusColor = Colors.red;
      }
    });
  }

  Future<void> _testHermesConnection() async {
    _syncConfigToProvider();
    setState(() {
      _hermesStatusText = "正在握手...";
      _hermesStatusColor = Colors.orange;
    });

    final client = ref.read(agentClientProvider);
    final ok = await client.checkHealth();

    setState(() {
      if (ok) {
        _hermesStatusText = "✓ Hermes 智能体握手成功 (HTTP 200 OK)";
        _hermesStatusColor = Colors.green;
      } else {
        _hermesStatusText = "✗ 握手失败，请检查 URL 或 Token";
        _hermesStatusColor = Colors.red;
      }
    });
  }

  Future<void> _testAllConnections() async {
    setState(() => _isTesting = true);
    await Future.wait([
      _testAsrConnection(),
      _testHermesConnection(),
    ]);
    setState(() => _isTesting = false);
  }

  @override
  Widget build(BuildContext context) {
    final buttonConfig = ref.watch(buttonActionProvider);
    final buttonNotifier = ref.read(buttonActionProvider.notifier);
    final device = ref.watch(deviceProvider);
    final devNotifier = ref.read(deviceProvider.notifier);
    final currentDriverType = devNotifier.activeDriver.deviceType;

    return Scaffold(
      appBar: AppBar(
        title: const Text("SunMate 系统与设备设置"),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 0. 私有直连服务器配置 (MOSS-ASR + Hermes Agent)
          const Text("私有服务器直连配置 (无需任何第三方中转)",
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ASR 配置
                  Row(
                    children: [
                      const Icon(Icons.dns, color: Color(0xFFFF8C00), size: 20),
                      const SizedBox(width: 8),
                      const Text("MOSS-ASR 服务器 (MLX 加速)",
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _asrUrlController,
                    decoration: const InputDecoration(
                      labelText: "ASR 基础地址 (例: http://your-ip:8000)",
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _asrTokenController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: "ASR 访问密钥 / Token (可选，外网防刷)",
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(_asrStatusText,
                            style: TextStyle(color: _asrStatusColor, fontSize: 12)),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.wifi_tethering, size: 16),
                        label: const Text("探测 ASR", style: TextStyle(fontSize: 12)),
                        onPressed: _testAsrConnection,
                      ),
                    ],
                  ),
                  const Divider(height: 20),

                  // Hermes 配置
                  Row(
                    children: [
                      const Icon(Icons.psychology, color: Colors.purple, size: 20),
                      const SizedBox(width: 8),
                      const Text("Hermes 智能体端点",
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _hermesUrlController,
                    decoration: const InputDecoration(
                      labelText: "Hermes 地址 (例: http://your-ip:8080/v1)",
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _hermesTokenController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: "Hermes 访问密钥 / Token (可选，防盗用)",
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(_hermesStatusText,
                            style: TextStyle(color: _hermesStatusColor, fontSize: 12)),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.smart_toy, size: 16),
                        label: const Text("探测 Hermes", style: TextStyle(fontSize: 12)),
                        onPressed: _testHermesConnection,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // 一键复制 Hermes 自动安装指令引导卡
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.purple.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.purple.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: const [
                            Icon(Icons.auto_awesome, color: Colors.purple, size: 18),
                            SizedBox(width: 6),
                            Text("不知道怎么配置 Hermes 端点？",
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.purple)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          "点击复制以下指令，直接发给你的 Hermes 智能体对话框。它将自动安装 5 大专属技能并启动端点，向你汇报地址与密钥：",
                          style: TextStyle(fontSize: 11, color: Colors.black87, height: 1.4),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.purple.shade800,
                              side: BorderSide(color: Colors.purple.shade400),
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            icon: const Icon(Icons.copy, size: 16),
                            label: const Text("📋 一键复制 Hermes 自动接入指令",
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            onPressed: () => _copyHermesSetupPrompt(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 一键双端诊断按钮
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF8C00),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _isTesting ? null : _testAllConnections,
                      icon: _isTesting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.bolt, size: 18),
                      label: Text(
                          _isTesting ? "正在连通性测试中..." : "⚡ 一键测试双端连通性 (ASR + Hermes)",
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // 1. 硬件抽象层 (HAL) 设备源选择
          const Text("硬件抽象层 (HAL) 驱动源",
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                RadioListTile<HardwareDeviceType>(
                  title: const Text("AiNote 6095 蓝牙录音卡 (Telink 芯片方案)",
                      style: TextStyle(fontSize: 14)),
                  subtitle: const Text("支持 0x1913/2B15 协议，按键上报与 Opus 16kHz 音频流",
                      style: TextStyle(fontSize: 12)),
                  value: HardwareDeviceType.ainote6095Ble,
                  groupValue: currentDriverType,
                  onChanged: (val) {
                    if (val != null) {
                      devNotifier.switchDriverType(val);
                      buttonNotifier.rebindDriver();
                    }
                  },
                ),
                const Divider(height: 1),
                RadioListTile<HardwareDeviceType>(
                  title: const Text("手机内置麦克风与软按键 (无外设模式)",
                      style: TextStyle(fontSize: 14)),
                  subtitle: const Text("兜底模式，无需外接硬件，通过手机麦克风与屏幕按键对讲",
                      style: TextStyle(fontSize: 12)),
                  value: HardwareDeviceType.phoneInternalMic,
                  groupValue: currentDriverType,
                  onChanged: (val) {
                    if (val != null) {
                      devNotifier.switchDriverType(val);
                      buttonNotifier.rebindDriver();
                    }
                  },
                ),
                if (currentDriverType == HardwareDeviceType.ainote6095Ble) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.bluetooth,
                                color: device.isConnected ? Colors.green : Colors.grey, size: 20),
                            const SizedBox(width: 8),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  device.isConnected ? "已连接: ${device.deviceName}" : "蓝牙卡未连接",
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: device.isConnected ? Colors.green.shade700 : Colors.grey,
                                    fontWeight: device.isConnected ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                                if (device.snNumber.isNotEmpty && device.snNumber != "--")
                                  Text(
                                    "SN: ${device.snNumber}",
                                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.black54),
                                  ),
                              ],
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            if (device.isConnected) ...[
                              TextButton.icon(
                                style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
                                icon: const Icon(Icons.link_off, size: 14),
                                label: const Text("解绑", style: TextStyle(fontSize: 12)),
                                onPressed: () async {
                                  await devNotifier.unpairDevice();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text("已清除设备绑定记录")),
                                    );
                                  }
                                },
                              ),
                              const SizedBox(width: 4),
                            ],
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFF8C00),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              ),
                              icon: const Icon(Icons.bluetooth_searching, size: 14),
                              label: Text(device.isConnected ? "重新配对" : "搜索连接",
                                  style: const TextStyle(fontSize: 12)),
                              onPressed: () => showBleDevicePickerModal(context, ref),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 2. 实体按键映射区
          const Text("按键交互自定义 (支持外设按键与屏幕软按键)",
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  _ActionDropdownTile(
                    title: "单击按键",
                    value: buttonConfig.singleClick,
                    onChanged: (val) {
                      if (val != null) {
                        buttonNotifier.updateConfig(buttonConfig.copyWith(singleClick: val));
                      }
                    },
                  ),
                  const Divider(height: 1),
                  _ActionDropdownTile(
                    title: "双击按键",
                    value: buttonConfig.doubleClick,
                    onChanged: (val) {
                      if (val != null) {
                        buttonNotifier.updateConfig(buttonConfig.copyWith(doubleClick: val));
                      }
                    },
                  ),
                  const Divider(height: 1),
                  _ActionDropdownTile(
                    title: "三击按键",
                    value: buttonConfig.tripleClick,
                    onChanged: (val) {
                      if (val != null) {
                        buttonNotifier.updateConfig(buttonConfig.copyWith(tripleClick: val));
                      }
                    },
                  ),
                  const Divider(height: 1),
                  _ActionDropdownTile(
                    title: "长按按键 (推荐对讲)",
                    value: buttonConfig.longPress,
                    onChanged: (val) {
                      if (val != null) {
                        buttonNotifier.updateConfig(buttonConfig.copyWith(longPress: val));
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // 3. 硬件校准
          const Text("硬件参数与时钟对齐",
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                 mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("硬件 RTC 时钟同步", style: TextStyle(fontWeight: FontWeight.bold)),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.sync, size: 16),
                    label: const Text("立即校准"),
                    onPressed: () => devNotifier.syncTime(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // 4. iOS ANCS 系统通知透传
          const Text("🍎 iOS 系统通知同步 (ANCS 硬件级)",
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("连接时请求系统通知授权",
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          Text("下次连接生效，系统授权单独管理",
                              style: TextStyle(fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                      Switch(
                        value: devNotifier.requiresAncs,
                        onChanged: (val) async {
                          final saved = await devNotifier.sendAncsConfig(enable: val);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
                            saved ? '已保存，下次连接录音卡时生效' : 'ANCS 系统通知授权仅适用于 iPhone',
                          )));
                        },
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  Text('当前 ANCS：${devNotifier.ancsAuthorized == true ? "已授权" : "未授权或尚未确认"}'),
                  const SizedBox(height: 8),
                  const Text(
                    "📌 iOS 真实系统配对指引：\n"
                    "1. 打开 iPhone【设置】->【蓝牙】；\n"
                    "2. 找到已配对的 C·ONE，点击右侧 ⓘ；\n"
                    "3. 若有【共享系统通知】开关，可在此管理授权；\n"
                    "4. 系统授权与设备业务鉴权分开验证；本版不保证通知正文已可透传。",
                    style: TextStyle(fontSize: 12, color: Colors.blueGrey, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  void _copyHermesSetupPrompt(BuildContext context) {
    const prompt = """请作为我的随身智能体，执行以下命令一键配置并启动 SunMate 专属随身第二大脑端点：
curl -fsSL https://raw.githubusercontent.com/lrocky01/sunmate/main/sunmate-hermes/setup_hermes.sh | bash

安装并启动完成后，请直接告诉我：
1. 你的局域网/公网端点地址 (如 http://192.168.x.x:8080/v1)
2. 安全访问 Token
我将直接填入手机 SunMate App 设置页进行连接。""";

    Clipboard.setData(const ClipboardData(text: prompt));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("✓ 已复制 Hermes 接入指令！请在与 Hermes 的对话框或终端中粘贴发送。"),
        backgroundColor: Colors.purple,
        duration: Duration(seconds: 4),
      ),
    );
  }
}

class _ActionDropdownTile extends StatelessWidget {
  final String title;
  final CustomActionBehavior value;
  final ValueChanged<CustomActionBehavior?> onChanged;

  const _ActionDropdownTile({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      trailing: DropdownButton<CustomActionBehavior>(
        value: value,
        underline: const SizedBox(),
        items: CustomActionBehavior.values.map((type) {
          return DropdownMenuItem(
            value: type,
            child: Text(type.label, style: const TextStyle(fontSize: 13)),
          );
        }).toList(),
        onChanged: onChanged,
      ),
    );
  }
}

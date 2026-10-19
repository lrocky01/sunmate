import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/device_provider.dart';
import 'recorder_device_status.dart';
import 'recorder_backup_page.dart';

/// 录音卡的日常管理入口；不把未核实的固件设置做成可写开关。
class RecorderManagementPage extends ConsumerWidget {
  final VoidCallback onOpenConnection;
  final VoidCallback onOpenDiagnostics;
  final VoidCallback onOpenAccount;
  final VoidCallback onOpenButtonSettings;
  const RecorderManagementPage(
      {super.key,
      required this.onOpenConnection,
      required this.onOpenDiagnostics,
      required this.onOpenAccount,
      required this.onOpenButtonSettings});

  void _open(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(deviceProvider);
    final notifier = ref.read(deviceProvider.notifier);
    final device = notifier.bleDeviceStatus;
    final details = notifier.bleConnectionDetails;
    final scheme = Theme.of(context).colorScheme;
    final status = device.isConnected
        ? '已连接 · 身份已验证'
        : notifier.isBleConnecting
            ? '正在连接'
            : details.linkConnected
                ? '蓝牙已连接 · 等待验证'
                : '未连接';
    final hasSn = device.snNumber.isNotEmpty && device.snNumber != '--';
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLow,
      appBar: AppBar(title: const Text('录音卡管理')),
      body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          children: [
            Row(children: [
              Icon(Icons.surround_sound_outlined,
                  size: 48, color: scheme.primary),
              const SizedBox(width: 16),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(
                        device.deviceName.startsWith('未连接')
                            ? '尚未连接录音卡'
                            : device.deviceName,
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 6),
                    Text(status,
                        style: TextStyle(
                            color: device.isConnected
                                ? Colors.green.shade800
                                : scheme.onSurfaceVariant)),
                  ])),
            ]),
            const SizedBox(height: 24),
            _SettingsGroup(children: [
              _SettingsRow(
                  icon: Icons.badge_outlined,
                  title: '设备名称',
                  value: device.deviceName),
              _SettingsRow(
                  icon: Icons.info_outline,
                  title: 'SN 号',
                  value: hasSn ? device.snNumber : '尚未取得',
                  onTap: !hasSn
                      ? null
                      : () async {
                          await Clipboard.setData(
                              ClipboardData(text: device.snNumber));
                          if (context.mounted)
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('SN 已复制')));
                        }),
              _SettingsRow(
                  icon: Icons.bluetooth,
                  title: '设备状态',
                  value: status,
                  onTap: onOpenConnection),
              _SettingsRow(
                  icon: Icons.battery_4_bar_outlined,
                  title: '设备电量',
                  value: device.isConnected && device.batteryLevel > 0
                      ? '${device.batteryLevel}%'
                      : '待设备上报'),
            ]),
            const SizedBox(height: 20),
            _SettingsGroup(children: [
              _SettingsRow(
                  icon: Icons.notifications_outlined,
                  title: '通知与灯效',
                  value: '通知连接设置',
                  onTap: () =>
                      _open(context, const RecorderNotificationSettingsPage())),
              _SettingsRow(
                  icon: Icons.mic_none,
                  title: '录音设置',
                  value: device.isRecording ? '正在采音' : '实时录音与音频状态',
                  onTap: () =>
                      _open(context, const RecorderRecordingSettingsPage())),
              _SettingsRow(
                  icon: Icons.touch_app_outlined,
                  title: '按键动作',
                  value: 'App 内动作配置',
                  onTap: onOpenButtonSettings),
              _SettingsRow(
                  icon: Icons.apps_outlined,
                  title: '可采集的应用',
                  value: '应用筛选待适配',
                  onTap: () => _open(
                      context,
                      const _RecorderInfoPage(title: '可采集的应用', paragraphs: [
                        '当前可查看 iPhone 通知服务授权状态，尚未接入按应用筛选通知的功能。',
                        'Android 官方 App 的应用采集与 iPhone 通知服务是不同路径，不能直接复用其应用列表设置。',
                        '这不影响录音卡实时采音；蓝牙诊断不记录通知正文。',
                      ]))),
              _SettingsRow(
                  icon: Icons.system_update_outlined,
                  title: '固件升级',
                  value: '升级服务未接入',
                  onTap: () => _open(
                      context,
                      const _RecorderInfoPage(title: '固件升级', paragraphs: [
                        '当前版本尚未接入固件版本查询和升级服务，本页不会发送固件升级指令。',
                        '设备业务连接与固件升级使用不同通道，后续需要核对适配固件和完整升级流程。',
                      ]))),
            ]),
            const SizedBox(height: 20),
            _SettingsGroup(children: [
              _SettingsRow(
                  icon: Icons.key_outlined,
                  title: '本机密钥与恢复',
                  value: details.identityVerified ? '本次 AES 已验证' : '查看恢复方式',
                  onTap: () => _open(
                      context,
                      const RecorderBackupPage())),
              _SettingsRow(
                  icon: Icons.receipt_long_outlined,
                  title: '蓝牙诊断',
                  value: '连接、鉴权与音频日志',
                  onTap: onOpenDiagnostics),
              _SettingsRow(
                  icon: Icons.account_circle_outlined,
                  title: '官方账号与设备恢复',
                  value: '账号资料与绑定状态',
                  onTap: onOpenAccount),
            ]),
            const SizedBox(height: 20),
            TextButton.icon(
                onPressed:
                    notifier.isBleLinkConnected || notifier.isBleConnecting
                        ? notifier.cancelBleConnection
                        : onOpenConnection,
                icon: Icon(
                    notifier.isBleLinkConnected || notifier.isBleConnecting
                        ? Icons.link_off
                        : Icons.bluetooth_searching),
                label: Text(
                    notifier.isBleLinkConnected || notifier.isBleConnecting
                        ? '断开蓝牙连接'
                        : '选择录音卡连接')),
            TextButton(
                onPressed: onOpenAccount,
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                child: const Text('管理账号绑定与解绑')),
            const Text('解绑需在账号设备页选择卡片并确认；本页不会自动清除系统配对或业务密钥。',
                style: TextStyle(fontSize: 12), textAlign: TextAlign.center),
          ]),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const _SettingsGroup({required this.children});
  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 52),
            children[i],
          ]
        ]),
      );
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final VoidCallback? onTap;
  const _SettingsRow(
      {required this.icon,
      required this.title,
      required this.value,
      this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
      onTap: onTap,
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
          child: Row(children: [
            Icon(icon, size: 24),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(title, style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(value,
                      style: TextStyle(
                          fontSize: 13,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                ])),
            if (onTap != null)
              const Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: Icon(Icons.chevron_right, size: 20)),
          ])));
}

class RecorderNotificationSettingsPage extends ConsumerStatefulWidget {
  const RecorderNotificationSettingsPage({super.key});
  @override
  ConsumerState<RecorderNotificationSettingsPage> createState() =>
      _RecorderNotificationSettingsState();
}

class _RecorderNotificationSettingsState
    extends ConsumerState<RecorderNotificationSettingsPage> {
  bool _saving = false;
  String? _error;
  @override
  Widget build(BuildContext context) {
    ref.watch(deviceProvider);
    final notifier = ref.read(deviceProvider.notifier);
    return Scaffold(
        appBar: AppBar(title: const Text('通知与灯效')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('连接时请求 iPhone 通知服务'),
              subtitle: const Text('更改在下次连接时生效，系统决定是否显示授权弹窗。'),
              value: notifier.requiresAncs,
              onChanged: !notifier.supportsAncsRequestConfiguration || _saving
                  ? null
                  : (value) async {
                      setState(() {
                        _saving = true;
                        _error = null;
                      });
                      try {
                        if (!await notifier.configureBleAncsRequest(value)) {
                          throw StateError('preference not saved');
                        }
                      } catch (_) {
                        if (mounted) setState(() => _error = '保存未完成，请重试。');
                      } finally {
                        if (mounted) setState(() => _saving = false);
                      }
                    }),
          if (!notifier.supportsAncsRequestConfiguration)
            const Text('此连接选项仅适用于 iPhone。'),
          if (_error != null)
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 16),
          Text(
              '本轮通知授权属性：${notifier.ancsAuthorized == null ? '未知' : notifier.ancsAuthorized! ? '允许' : '未允许'}'),
          const Divider(height: 32),
          const Text('灯效配置',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('会议录音呼吸灯可在录音设置中开关。自定义颜色、亮度和闪烁节奏尚未接入；通知连接选项不会修改灯效。'),
          Align(alignment: Alignment.centerLeft, child: TextButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const RecorderRecordingSettingsPage())),
            icon: const Icon(Icons.mic_none), label: const Text('设置会议录音呼吸灯'))),
        ]));
  }
}

class RecorderRecordingSettingsPage extends ConsumerStatefulWidget {
  const RecorderRecordingSettingsPage({super.key});
  @override
  ConsumerState<RecorderRecordingSettingsPage> createState() =>
      _RecorderRecordingSettingsState();
}

class _RecorderRecordingSettingsState
    extends ConsumerState<RecorderRecordingSettingsPage> {
  StreamSubscription<void>? _settingsChanges;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = ref.read(deviceProvider.notifier);
      // 即使当前HAL输入切到手机麦克风，也继续显示这张录音卡的真实回报。
      _settingsChanges = notifier.recorderHardwareSettingsChanges.listen((_) {
        if (mounted) setState(() {});
      });
      final settings = notifier.recorderHardwareSettings;
      if (settings.connected && !settings.busy) {
        notifier.refreshRecorderHardwareSettings();
      }
    });
  }

  @override
  void dispose() {
    _settingsChanges?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(deviceProvider);
    final notifier = ref.read(deviceProvider.notifier);
    final details = notifier.bleConnectionDetails;
    final settings = notifier.recorderHardwareSettings;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('录音设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '会议录音',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextButton.icon(
                onPressed: settings.connected && !settings.busy
                    ? notifier.refreshRecorderHardwareSettings
                    : null,
                icon: const Icon(Icons.refresh),
                label: const Text('读取卡片设置'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('选择启动和结束会议录音的按键方式。双击与三击为二选一。'),
          const SizedBox(height: 16),
          Text('会议录音触发方式', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (!settings.connected)
            const Text('连接录音卡并完成身份验证后，可读取和修改设置。')
          else if (settings.capabilitiesKnown && !settings.supportsClicks)
            const Text('当前卡片未报告按键次数设置能力。')
          else ...[
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 2, label: Text('双击')),
                ButtonSegment(value: 3, label: Text('三击')),
              ],
              emptySelectionAllowed: true,
              selected: settings.meetingClicks == null
                  ? <int>{}
                  : {settings.meetingClicks!},
              onSelectionChanged: settings.canEdit && settings.supportsClicks
                  ? (values) {
                      if (values.isNotEmpty)
                        notifier.setMeetingRecordingClicks(values.single);
                    }
                  : null,
            ),
            if (settings.meetingClicks == null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('尚未读到有效的触发方式。'),
              ),
          ],
          const SizedBox(height: 20),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('会议录音呼吸灯'),
            subtitle: Text(
              settings.capabilitiesKnown && !settings.supportsLed
                  ? '当前卡片未报告录音指示灯设置能力。'
                  : settings.meetingLed == null
                  ? '尚未读到有效的灯光设置。'
                  : settings.meetingLed!
                  ? '已开启：会议录音时显示指示灯。'
                  : '已关闭：会议录音时不显示指示灯。',
            ),
            value: settings.meetingLed ?? false,
            onChanged: settings.canEdit && settings.supportsLed
                ? notifier.setMeetingRecordingLed
                : null,
          ),
          if (settings.connected && settings.recording == true)
            const Text('正在录音，请结束后再修改设置。')
          else if (settings.connected && settings.recording == null)
            const Text('录音状态尚未确认，请读取卡片设置后再修改。'),
          if (settings.busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(semanticsLabel: '正在与卡片确认设置'),
          ],
          if (settings.message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  settings.message!,
                  style: TextStyle(
                    color: settings.failed
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          const Text('修改后会重新读取卡片，回报与选择一致才确认保存。这里仅设置会议录音指示灯。'),
          const Divider(height: 32),
          const Text(
            '实时录音',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text('完成设备身份验证后，按住卡片按键说话，松开结束。开始、音频和结束事件由卡片上报。'),
          const SizedBox(height: 16),
          Text(
            '当前状态：${!details.businessReady
                ? details.linkConnected
                      ? '等待身份验证'
                      : '未连接'
                : notifier.bleDeviceStatus.isRecording
                ? '正在采音'
                : '待命'}',
          ),
          const SizedBox(height: 8),
          Text(notifier.bleAudioStatistics),
          const Divider(height: 32),
          RecorderDeviceStatusPanel(details: notifier.bleConnectionDetails),
          const Divider(height: 32),
          const Text('录音与转写分开验证。音频链路不依赖 ASR/Hermes；当前还没有离线录音文件列表、保存及回放功能。'),
        ],
      ),
    );
  }
}

class _RecorderInfoPage extends StatelessWidget {
  final String title;
  final List<String> paragraphs;
  const _RecorderInfoPage({required this.title, required this.paragraphs});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        for (final paragraph in paragraphs)
          Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(paragraph,
                  style: const TextStyle(fontSize: 16, height: 1.5))),
      ]));
}

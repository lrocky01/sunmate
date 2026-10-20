import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ble/yoooclaw_account.dart';
import '../providers/device_provider.dart';
import 'recorder_device_status.dart';
import 'recorder_backup_page.dart';

class RecorderAccountSheet extends ConsumerStatefulWidget {
  final YoooClawAccount? account;
  final ValueChanged<AccountRecorderDevice>? onSelectDevice;
  final VoidCallback? onAddDevice;
  final VoidCallback? onRebindDevice;
  final bool closeAccountOnDispose;
  final Future<bool> Function()? onReconnectVerified;
  final Widget? savedIdentitySection;
  const RecorderAccountSheet(
      {super.key,
      this.account,
      this.onSelectDevice,
      this.onAddDevice,
      this.onRebindDevice,
      this.onReconnectVerified,
      this.savedIdentitySection,
      this.closeAccountOnDispose = true});
  @override
  ConsumerState<RecorderAccountSheet> createState() =>
      _RecorderAccountSheetState();
}

class _RecorderAccountSheetState extends ConsumerState<RecorderAccountSheet> {
  late final YoooClawAccount _account;
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _scroll = ScrollController();
  List<OwnedRecorderBinding> _bindings = [];
  Timer? _timer;
  int _seconds = 0;
  bool _busy = false;
  bool _confirmingUnbind = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _account = widget.account ?? YoooClawAccount();
    unawaited(_run(() async {
      if (await _account.restoreSession()) await _loadBindings();
    }));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      await action();
    } on OfficialAccountException catch (error) {
      if (mounted) setState(() => _status = error.message);
    } catch (_) {
      if (mounted) setState(() => _status = '操作未完成，请查看蓝牙诊断；未显示账号或密钥内容');
    } finally {
      if (mounted) setState(() {
        _busy = false;
        if (!_account.isLoggedIn) _bindings = [];
      });
    }
  }

  Future<void> _sendSms() => _run(() async {
        await _account.sendSms(_phone.text.trim());
        if (!mounted) return;
        setState(() {
          _seconds = 60;
          _status = '验证码已发送，请在本页输入';
        });
        _timer?.cancel();
        _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (!mounted || _seconds <= 1) {
            timer.cancel();
            if (mounted) setState(() => _seconds = 0);
          } else {
            setState(() => _seconds--);
          }
        });
      });

  Future<void> _loadBindings() async {
    final bindings = await _account.loadBindings();
    if (!mounted) return;
    setState(() {
      _bindings = bindings;
      _status = widget.onSelectDevice != null
          ? _account.devices.isEmpty
              ? '账号暂无设备，可以添加新录音卡'
              : '已读取 ${_account.devices.length} 台账号设备，请选择要连接的录音卡'
          : bindings.isNotEmpty
              ? '已读取 ${bindings.length} 台具备恢复材料的设备，请核对当前卡的 SN'
              : _account.totalDevices == 0
                  ? '当前官方账号没有返回设备记录，请核对登录账号'
                  : _account.missingSharedSecretDevices > 0
                      ? '账号设备资料中缺少共享密钥。请先让官方 App 联网连接并完成同步，再点「重新读取我的设备」'
                      : '账号有设备记录，但没有唯一且格式完整的可恢复密钥；未猜测或替换';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  Future<void> _login() => _run(() async {
        FocusScope.of(context).unfocus();
        try {
          await _account.login(_phone.text.trim(), _code.text.trim());
          if (mounted) setState(() => _status = '官方账号登录成功，正在读取设备绑定');
          await _loadBindings();
        } finally {
          if (mounted) _code.clear();
        }
      });

  Future<void> _restore(OwnedRecorderBinding binding) => _run(() async {
        final notifier = ref.read(deviceProvider.notifier);
        if (!notifier.canRestoreBinding(binding)) {
          setState(() => _status = '请先在首页连接目标卡取得真实 SN，并结束正在进行的录音');
          return;
        }
        setState(() => _status = '正在安全保存匹配资料并重新连接验证');
        final connected = await notifier.restoreBindingAndReconnect(binding);
        if (!mounted) return;
        setState(() => _status = connected
            ? '设备已通过本地身份验证，可用录音卡物理按键录音'
            : notifier.lastError ?? '尚未通过设备身份验证，请保留蓝牙诊断日志');
      });

  bool _hardwareIdle() {
    if (!mounted) return false;
    final notifier = ref.read(deviceProvider.notifier);
    return !notifier.isBleLinkConnected &&
        !notifier.isBleConnecting &&
        !notifier.activeDriver.isRecording &&
        !notifier.activeDriver.isPaused;
  }

  Future<void> _confirmCandidate(AccountRecorderDevice device) =>
      _run(() async {
        if (!_hardwareIdle() || !device.hasRecoverableKey) {
          throw const OfficialAccountException('请先结束蓝牙连接，并读取完整账号资料');
        }
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('使用账号资料验证？'),
                    content: SingleChildScrollView(
                        child: Text(
                            '${device.deviceName}\nSN：${device.serialNumber}\n\n'
                            '本机旧凭据会安全归档保留。账号资料作为独立候选，只有卡片本次验证通过后才启用；失败或没有挑战时保持现状。\n\n'
                            '不会解绑、重新协商或删除旧版本。')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('继续验证'))
                    ]));
        if (confirmed != true || !mounted) return;
        if (!_hardwareIdle())
          throw const OfficialAccountException('连接状态已变化，请先结束当前连接');
        final session = _account.sessionForAccountCandidate(device);
        await showRecorderCredentialCandidate(context,
            serialNumber: device.serialNumber, sessionForScan: (_) => session);
        if (mounted)
          setState(() => _status =
              ref.read(deviceProvider.notifier).bleDeviceStatus.isConnected
                  ? '所选凭据已通过卡片验证；旧版本保留在本机密钥与恢复中。'
                  : '候选验证未完成；旧凭据保留，请查看蓝牙诊断。');
      });

  Widget _candidateButton(AccountRecorderDevice device) => OutlinedButton.icon(
      onPressed: _busy ||
              !_hardwareIdle() ||
              !device.hasRecoverableKey ||
              _account.hasPendingUnbind
          ? null
          : () => _confirmCandidate(device),
      icon: const Icon(Icons.verified_user_outlined),
      label: const Text('使用账号资料验证'));

  Future<void> _confirmUnbind(AccountRecorderDevice device) => _run(() async {
        if (!_hardwareIdle() || !_account.canUnbindDevice(device)) {
          throw const OfficialAccountException('请先结束录音和蓝牙连接，再重新读取设备');
        }
        setState(() => _confirmingUnbind = true);
        bool? confirmed;
        final metadataOnly = device.isSharedSecretMissing;
        final archiveDescription = metadataOnly
            ? '账号没有返回共享密钥，没有可备份的账号密钥。'
                '提交前安全归档SN、MAC及原始扩展资料；这份归档不能用于密钥恢复。'
                '本机旧密钥保留，历史版本也保留。'
            : '将删除这张卡在官方账号中的绑定记录。'
                '提交前会安全备份账号恢复资料，本机旧密钥保留。';
        try {
          confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  title: Text(metadataOnly ? '仅解绑账号记录？' : '解绑账号设备？'),
                  content: SingleChildScrollView(
                      child: Text(
                          '${device.deviceName}\nSN：${device.serialNumber}\n\n'
                          '$archiveDescription\n\n'
                          '${metadataOnly ? "确认后只请求删除服务器账号记录。" : ""}'
                          '不会清除卡内数据或系统配对，也不会自动重新绑定。解绑不能保证修复连接或身份挑战超时；后续重新绑定可能影响未同步录音，请先确认已备份。')),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    TextButton(
                        style: TextButton.styleFrom(
                            foregroundColor:
                                Theme.of(context).colorScheme.error),
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(metadataOnly ? '归档并仅解绑账号记录' : '备份并解绑账号设备')),
                  ],
                ));
        } finally {
          if (mounted) setState(() => _confirmingUnbind = false);
        }
        if (confirmed != true || !mounted) return;
        await _account.unbindDevice(device, canProceed: _hardwareIdle);
        await _loadBindings();
      });

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    _scroll.dispose();
    if (widget.closeAccountOnDispose) _account.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(deviceProvider);
    final notifier = ref.read(deviceProvider.notifier);
    return SafeArea(
        child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
            controller: _scroll,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Expanded(
                      child: Text(
                          widget.onSelectDevice != null
                              ? '连接录音卡'
                              : '恢复官方账号设备绑定',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold))),
                  IconButton(
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      tooltip: '关闭',
                      icon: const Icon(Icons.close)),
                ]),
                if (widget.savedIdentitySection != null) widget.savedIdentitySection!,
                Text(widget.onSelectDevice != null
                    ? '已有本机密钥或导入备份可直接离线连接；首次绑定或从官方账号取回资料时再登录。'
                    : '使用自己的 YoooClaw App 账号登录，读取设备绑定资料。'),
                const Text('登录状态会安全保存在本机，重新打开时自动恢复；验证码不保存。'),
                const SizedBox(height: 8),
                if (widget.onSelectDevice == null)
                  const Text(
                      '先在首页连接一次目标录音卡，取得设备上报的 SN。恢复时必须与账号记录的 SN 和协议同时匹配。录音、MOSS-ASR 和 Hermes 仍走你的私有端点。'),
                const SizedBox(height: 12),
                if (widget.onSelectDevice == null)
                  Text('当前录音卡 SN：${notifier.detectedBleSerial}'),
                const SizedBox(height: 12),
                if (widget.onReconnectVerified != null) ...[
                    OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                  final connected =
                                      await widget.onReconnectVerified!();
                                  if (mounted)
                                    setState(() => _status = connected
                                        ? '设备身份已验证'
                                        : '本机身份重连未完成，请查看蓝牙诊断');
                                }),
                        child: const Text('使用本机已验证身份重连')),
                    const SizedBox(height: 8),
                ],
                if (!_account.isLoggedIn) ...[
                  TextField(
                      controller: _phone,
                      enabled: !_busy,
                      decoration: const InputDecoration(labelText: '官方账号手机号'),
                      keyboardType: TextInputType.phone,
                      autofillHints: const [
                        AutofillHints.telephoneNumber
                      ],
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(11)
                      ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                        child: TextField(
                            controller: _code,
                            enabled: !_busy,
                            decoration:
                                const InputDecoration(labelText: '4 位短信验证码'),
                            keyboardType: TextInputType.number,
                            obscureText: true,
                            autofillHints: const [
                          AutofillHints.oneTimeCode
                        ],
                            inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(4)
                        ])),
                    const SizedBox(width: 8),
                    TextButton(
                        onPressed: _busy || _seconds > 0 ? null : _sendSms,
                        child: Text(_seconds > 0 ? '${_seconds}s' : '获取验证码')),
                  ]),
                  const SizedBox(height: 12),
                  FilledButton(
                      onPressed: _busy ? null : _login,
                      child: Text(widget.onSelectDevice != null
                          ? '登录并读取我的设备'
                          : '登录并读取我的绑定设备')),
                ] else ...[
                  Text(_account.isSessionSaved
                      ? '登录状态已安全保存'
                      : '本次登录可用，尚未安全保存；关闭后可能需要重新登录'),
                  OutlinedButton(
                      onPressed: _busy ? null : () => _run(_loadBindings),
                      child: const Text('重新读取我的设备')),
                  TextButton(
                      onPressed: _busy ? null : () => _run(() async {
                        await _account.logout();
                        if (!mounted) return;
                        _timer?.cancel();
                        _phone.clear();
                        _code.clear();
                        setState(() {
                          _seconds = 0;
                          _bindings = [];
                          _status = '已退出官方账号，录音卡的本机业务密钥保留';
                        });
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
                        });
                      }),
                      child: const Text('退出官方账号')),
                ],
                if (_busy && !_confirmingUnbind)
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: LinearProgressIndicator()),
                if (_status.isNotEmpty)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(_status)),
                if (_account.unbindNotice != null)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(_account.unbindNotice!)),
                if (_account.diagnostics.isNotEmpty) ...[
                  SelectableText(_account.diagnostics.join('\n'),
                      style: const TextStyle(fontSize: 11)),
                  TextButton(
                      onPressed: () => Clipboard.setData(ClipboardData(
                          text: 'SunMate 官方账号请求诊断\n'
                              '${_account.diagnostics.join("\n")}')),
                      child: const Text('复制账号诊断（不含凭据）')),
                ],
                if (widget.onSelectDevice != null && _account.isLoggedIn) ...[
                  if (widget.onAddDevice != null) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                        onPressed: _busy || _account.hasPendingUnbind
                            ? null
                            : widget.onAddDevice,
                        icon: const Icon(Icons.add),
                        label: const Text('添加新录音卡')),
                    const Text('用于账号列表中尚无记录的卡片。已有设备请选择下方记录；添加不会自动解绑或重置卡片。'),
                    if (widget.onRebindDevice != null) ...[
                      OutlinedButton.icon(
                          onPressed: _busy || _account.hasPendingUnbind || !_hardwareIdle()
                              ? null : widget.onRebindDevice,
                          icon: const Icon(Icons.key_outlined),
                          label: const Text('重新建立业务绑定（保留旧版本）')),
                      const Text('用于账号已无这张卡、但本机仍有旧密钥的情况。搜索并核对SN后还需单独确认；可能改变卡内密钥，不会自动解绑。'),
                    ],
                    const SizedBox(height: 20),
                  ],
                  const Text(
                      '已有设备使用账号保存的资料验证；首次添加新卡时，才在真实协商后同步绑定资料。录音、MOSS-ASR 和 Hermes 仍直连私有端点。'),
                  for (final device in _account.devices) ...[
                    const Divider(height: 28),
                    Text(device.deviceName,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    RecorderAccountDeviceInfo(device: device),
                    const SizedBox(height: 12),
                    FilledButton(
                        onPressed: _busy || _account.hasPendingUnbind
                            ? null
                            : () => widget.onSelectDevice!(device),
                        child: const Text('选择并搜索')),
                    _candidateButton(device),
                    const Text('本机旧密钥冲突时，可单独验证账号资料；验证通过后才切换，旧版本保留。'),
                    TextButton(
                        style: TextButton.styleFrom(
                            foregroundColor:
                                Theme.of(context).colorScheme.error),
                        onPressed: _busy ||
                                !_hardwareIdle() ||
                                !_account.canUnbindDevice(device)
                            ? null
                            : () => _confirmUnbind(device),
                        child: Text(device.isSharedSecretMissing ? '仅解绑账号记录' : '解绑账号设备')),
                    if (!_hardwareIdle()) const Text('请先结束录音和蓝牙连接，再解绑账号设备。'),
                    if (!device.hasMac)
                      const Text('账号未返回真实MAC，不能提交账号解绑；不会用iPhone设备UUID代替。')
                    else if (device.isSharedSecretMissing)
                      Text(_account.canUnbindDevice(device) || _busy || _account.hasPendingUnbind
                          ? '账号未返回共享密钥；可手动仅解绑账号记录，先归档元数据并保留本机密钥。此操作不会自动重新绑定。'
                          : '账号扩展资料暂不能完整安全归档，请重新读取设备；未开放解绑，不会丢弃未知字段。')
                    else if (!device.hasRecoverableKey)
                      const Text('账号返回了密钥字段，但格式或设备类型不匹配；暂不能安全备份并解绑，请保留账号诊断。'),
                  ],
                ],
                if (widget.onSelectDevice == null)
                  for (final binding in _bindings)
                    Card(
                        child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(binding.deviceName,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          Text(
                              'SN：${binding.serialNumber}\n协议：${binding.protocol.name}'),
                          const SizedBox(height: 8),
                          FilledButton(
                              onPressed:
                                  _busy || !notifier.canRestoreBinding(binding)
                                      ? null
                                      : () => _restore(binding),
                              child: const Text('恢复并验证连接')),
                          for(final device in _account.devices.where((d)=>d.serialNumber==binding.serialNumber))
                            _candidateButton(device),
                          if (!notifier.canRestoreBinding(binding))
                            const Text('当前卡尚未取得匹配的 SN / 协议，或设备正在操作中',
                                style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    )),
              ],
            )),
      ),
    ));
  }
}

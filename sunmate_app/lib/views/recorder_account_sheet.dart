import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ble/yoooclaw_account.dart';
import '../providers/device_provider.dart';

class RecorderAccountSheet extends ConsumerStatefulWidget {
  final YoooClawAccount? account;
  const RecorderAccountSheet({super.key, this.account});
  @override
  ConsumerState<RecorderAccountSheet> createState() =>
      _RecorderAccountSheetState();
}

class _RecorderAccountSheetState extends ConsumerState<RecorderAccountSheet> {
  late final YoooClawAccount _account;
  final _phone = TextEditingController();
  final _code = TextEditingController();
  List<OwnedRecorderBinding> _bindings = [];
  Timer? _timer;
  int _seconds = 0;
  bool _busy = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _account = widget.account ?? YoooClawAccount();
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
      if (mounted) setState(() => _busy = false);
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
      _status = bindings.isNotEmpty
          ? '已读取 ${bindings.length} 台具备恢复材料的设备，请核对当前卡的 SN'
          : _account.totalDevices == 0
              ? '该会话下没有设备记录；尚不能确认官网账号与 App 设备记录互通'
              : '账号有设备记录，但没有唯一且格式完整的可恢复密钥；未猜测或替换';
    });
  }

  Future<void> _login() => _run(() async {
        try {
          await _account.login(_phone.text.trim(), _code.text.trim());
          if (mounted) setState(() => _status = '官网登录成功，正在读取设备绑定');
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

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    _account.close();
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
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Expanded(
                  child: Text('恢复官方账号设备绑定',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold))),
              IconButton(
                  onPressed: () => Navigator.pop(context),
                  tooltip: '关闭',
                  icon: const Icon(Icons.close)),
            ]),
            const Text(
                '使用你自己的 YoooClaw 官网手机号验证码登录，只读取设备绑定资料。验证码和登录会话只在本页内存中使用，关闭后清除。'),
            const SizedBox(height: 8),
            const Text(
                '先在首页连接一次目标录音卡，取得设备上报的 SN。恢复时必须与账号记录的 SN 和协议同时匹配。录音、MOSS-ASR 和 Hermes 仍走你的私有端点。'),
            const SizedBox(height: 12),
            Text('当前录音卡 SN：${notifier.detectedBleSerial}'),
            const SizedBox(height: 12),
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
                  child: const Text('登录并读取我的绑定设备')),
            ] else ...[
              OutlinedButton(
                  onPressed: _busy ? null : () => _run(_loadBindings),
                  child: const Text('重新读取我的设备')),
            ],
            if (_busy)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator()),
            if (_status.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(_status)),
            if (_account.diagnostics.isNotEmpty) ...[
              SelectableText(_account.diagnostics.join('\n'),
                  style: const TextStyle(fontSize: 11)),
              TextButton(
                  onPressed: () => Clipboard.setData(ClipboardData(
                      text: 'SunMate 官方账号请求诊断\n'
                          '${_account.diagnostics.join("\n")}')),
                  child: const Text('复制账号诊断（不含凭据）')),
            ],
            for (final binding in _bindings)
              Card(
                  child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(binding.deviceName,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(
                        'SN：${binding.serialNumber}\n协议：${binding.protocol.name}'),
                    const SizedBox(height: 8),
                    FilledButton(
                        onPressed: _busy || !notifier.canRestoreBinding(binding)
                            ? null
                            : () => _restore(binding),
                        child: const Text('恢复并验证连接')),
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

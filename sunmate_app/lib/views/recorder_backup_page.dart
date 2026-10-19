import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ble/ble_protocol.dart';
import '../core/ble/recorder_backup_files.dart';
import '../core/ble/recorder_portable_backup.dart';
import '../core/ble/recorder_saved_identity.dart';
import '../providers/device_provider.dart';

class RecorderBackupPage extends ConsumerStatefulWidget {
  final RecorderBackupFiles? files;
  const RecorderBackupPage({super.key, this.files});
  @override
  ConsumerState<RecorderBackupPage> createState() => _RecorderBackupPageState();
}

class _RecorderBackupPageState extends ConsumerState<RecorderBackupPage> {
  late final RecorderBackupService _service;
  late final RecorderBackupFiles _files;
  List<RecorderSavedIdentity> _exportable = [];
  List<PortableRecorderMaterial> _imported = [];
  RecorderSavedIdentity? _selected;
  bool _busy = true;
  String? _message;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _service = ref.read(deviceProvider.notifier).recorderBackup;
    _files = widget.files ?? RecorderBackupFiles();
    unawaited(_load().catchError((Object _) {
      if (mounted)
        setState(() {
          _busy = false;
          _failed = true;
          _message = '无法读取本机备份资料；现有密钥保持。请返回后重试。';
        });
    }));
  }

  Future<void> _load() async {
    final exportable = await _service.exportable();
    final imported = await _service.imported.readAll();
    if (!mounted) {
      for (final material in imported) {
        material.clear();
      }
      return;
    }
    for (final material in _imported) {
      material.clear();
    }
    setState(() {
      _exportable = exportable;
      _selected = exportable.isEmpty ? null : exportable.first;
      _imported = imported;
      _busy = false;
    });
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    try {
      await action();
    } catch (error) {
      if (mounted)
        setState(() {
          _failed = true;
          // 只给操作提示；不显示底层异常或任何文件/密钥内容。
          _message = error is FormatException
              ? '${error.message}'
              : error is StateError
                  ? '${error.message}'
                  : '操作未完成，请重试；现有绑定与密钥保持';
        });
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
        });
    }
  }

  Future<void> _export() => _perform(() async {
        final identity = _selected;
        if (identity == null) return;
        final password = await _askPassword(context, exporting: true);
        if (!mounted) return;
        if (password == null) {
          setState(() {
            _message = '已取消导出';
          });
          return;
        }
        final encrypted = await _service.export(identity, password);
        if (!mounted) return;
        final saved = await _files.save(encrypted);
        if (mounted)
          setState(() {
            _message = saved ? '加密备份已保存。请另行保管密码，密码无法找回。' : '已取消保存';
          });
      });

  Future<void> _import() => _perform(() async {
        final encrypted = await _files.pick();
        if (!mounted) return;
        if (encrypted == null) {
          _cancelImport();
          return;
        }
        final password = await _askPassword(context, exporting: false);
        if (!mounted) return;
        if (password == null) {
          _cancelImport();
          return;
        }
        final material = await _service.codec.decrypt(encrypted, password);
        try {
          if (!mounted) return;
          final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                      title: const Text('确认导入录音卡备份'),
                      content: Text(
                          '${material.deviceName}\nSN：${material.serialNumber}\n\n将安全保存为待验证资料。仍需连接这张卡并通过真实AES验证，不覆盖不同旧密钥。'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消')),
                        FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('确认导入'))
                      ]));
          if (!mounted) return;
          if (confirmed != true) {
            _cancelImport();
            return;
          }
          await _service.acceptImport(material);
          await _load();
          if (mounted)
            setState(() {
              _message = '已导入待验证资料。请在下方选择卡片连接验证，无需登录官方账号。';
            });
        } finally {
          material.clear();
        }
      });

  void _cancelImport() => setState(() {
        _message = '已取消导入，未保存备份资料';
      });

  Future<void> _connect(PortableRecorderMaterial material) async {
    if (_busy) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            _BackupConnectPage(material: material, service: _service)));
    if (mounted) await _perform(_load);
  }

  @override
  void dispose() {
    for (final material in _imported) {
      material.clear();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('本机密钥与恢复')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('备份这张卡，换机后继续连接',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        const Text(
            '已有密钥的日常重连使用本地AES，无需再次手机号登录。备份只含设备身份和业务密钥，不含账号Token或系统蓝牙配对。'),
        const SizedBox(height: 24),
        Text('导出加密备份', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_exportable.isEmpty)
          const Text('尚无已验证卡片。请先完成一次真实AES连接，再导出备份。')
        else
          DropdownButtonFormField<RecorderSavedIdentity>(
              key: ValueKey(_selected),
              initialValue: _selected,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '选择已验证卡片'),
              items: _exportable
                  .map((r) => DropdownMenuItem(
                      value: r,
                      child: Text('${r.deviceName} · ${r.serialNumber}',
                          overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                        _selected = value;
                      })),
        const SizedBox(height: 12),
        FilledButton.icon(
            onPressed: _busy || _selected == null ? null : _export,
            icon: const Icon(Icons.save_alt),
            label: const Text('设置密码并导出')),
        const SizedBox(height: 28),
        Text('导入已有备份', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('选择加密文件并输入原备份密码。恢复时会重新识别这张卡，再由卡片验证密钥；无需登录官方账号。'),
        const SizedBox(height: 12),
        OutlinedButton.icon(
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('选择加密备份文件')),
        if (_busy)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Row(children: [
                SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 12),
                Expanded(child: Text('正在处理，请稍候…'))
              ])),
        if (_message != null)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(_message!,
                  semanticsLabel: _message,
                  style: TextStyle(
                      color: _failed
                          ? Theme.of(context).colorScheme.error
                          : null))),
        if (_imported.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('已导入的备份资料', style: Theme.of(context).textTheme.titleMedium),
          ..._imported.map((r) => ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(r.deviceName),
              subtitle: Text('SN：${r.serialNumber}\n需在当前连接中通过卡片验证'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _busy ? null : () => _connect(r))),
        ],
        const SizedBox(height: 24),
        const Text('请将密码与备份文件分开保管。卡片重置或重新绑定产生新密钥后，旧备份可能失效；此时仍需真实首次绑定。',
            style: TextStyle(fontSize: 13)),
      ]));
}

Future<String?> _askPassword(BuildContext context,
    {required bool exporting}) async {
  final first = TextEditingController();
  final second = TextEditingController();
  final form = GlobalKey<FormState>();
  try {
    return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                scrollable: true,
                title: Text(exporting ? '设置备份密码' : '输入备份密码'),
                content: Form(
                    key: form,
                    child: AutofillGroup(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(exporting
                              ? '至少12个字符。忘记密码将无法解密，SunMate不会保存密码。'
                              : '输入导出文件时设置的密码，离线解密无需官方登录。'),
                          const SizedBox(height: 16),
                          TextFormField(
                              controller: first,
                              obscureText: true,
                              autocorrect: false,
                              enableSuggestions: false,
                              autofillHints: const [],
                              decoration:
                                  const InputDecoration(labelText: '备份密码'),
                              validator: (value) {
                                try {
                                  RecorderBackupCodec.validatePassword(
                                      value ?? '');
                                  return null;
                                } catch (_) {
                                  return '请使用至少12个字符的备份密码';
                                }
                              }),
                          if (exporting) ...[
                            const SizedBox(height: 12),
                            TextFormField(
                                controller: second,
                                obscureText: true,
                                autocorrect: false,
                                enableSuggestions: false,
                                autofillHints: const [],
                                decoration:
                                    const InputDecoration(labelText: '再次输入密码'),
                                validator: (value) =>
                                    value == first.text ? null : '两次密码不一致')
                          ],
                        ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () {
                        if (form.currentState!.validate())
                          Navigator.pop(context, first.text);
                      },
                      child: Text(exporting ? '加密备份' : '解密'))
                ]));
  } finally {
    TextInput.finishAutofillContext(shouldSave: false);
    // 等待Dialog的退场动画卸载输入框后释放控制器。
    await Future<void>.delayed(const Duration(milliseconds: 250));
    first.clear();
    second.clear();
    first.dispose();
    second.dispose();
  }
}

class _BackupConnectPage extends ConsumerStatefulWidget {
  final PortableRecorderMaterial material;
  final RecorderBackupService service;
  const _BackupConnectPage({required this.material, required this.service});
  @override
  ConsumerState<_BackupConnectPage> createState() => _BackupConnectPageState();
}

class _BackupConnectPageState extends ConsumerState<_BackupConnectPage> {
  StreamSubscription<List<ScanResult>>? _scan;
  List<ScanResult> _results = [];
  bool _connecting = false;
  String? _result;
  late final DeviceNotifier _notifier;
  @override
  void initState() {
    super.initState();
    _notifier = ref.read(deviceProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _search();
    });
  }

  Future<void> _search() async {
    if (_connecting) return;
    await _scan?.cancel();
    if (!mounted) return;
    try {
      _scan = FlutterBluePlus.scanResults.listen((results) {
        if (mounted)
          setState(() {
            _results = results
                .where((r) =>
                    RecorderAdvertisementSerial.telink(
                        r.advertisementData.manufacturerData) ==
                    widget.material.serialNumber)
                .toList();
          });
      }, onError: (Object _) {
        if (mounted)
          setState(() {
            _result = '搜索未完成，请确认蓝牙权限并重新搜索';
          });
      });
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    } catch (_) {
      if (mounted)
        setState(() {
          _result = '无法开始搜索，请确认蓝牙已开启';
        });
    }
  }

  Future<void> _connect(ScanResult result) async {
    if (_connecting ||
        _notifier.isBleConnecting ||
        _notifier.isBleLinkConnected) {
      setState(() {
        _result = '请先结束当前录音卡连接，再恢复备份';
      });
      return;
    }
    setState(() {
      _connecting = true;
      _result = '正在连接并等待卡片真实AES验证…';
    });
    try {
      final scan = RecorderScanIdentity.fromAdvertisement(
          remoteId: result.device.remoteId.str,
          deviceName: result.advertisementData.advName,
          manufacturerData: result.advertisementData.manufacturerData,
          connectable: result.advertisementData.connectable,
          observedAt: result.timeStamp);
      if (scan == null) throw StateError('未取得新鲜的可连接广播，请重新搜索');
      final session = widget.service.offlineSession(widget.material, scan);
      final ok =
          await _notifier.connectDevice(result.device, accountSession: session);
      if (mounted)
        setState(() {
          _result = ok
              ? '连接成功：卡片真实AES验证已通过，可返回录音卡管理。'
              : '验证未完成，请查看蓝牙诊断。未解绑、未重新协商或覆盖旧密钥。';
        });
    } catch (_) {
      if (mounted)
        setState(() {
          _result = '恢复连接未完成：请确认广播新鲜、卡片身份一致且本机无不同旧密钥。';
        });
    } finally {
      if (mounted)
        setState(() {
          _connecting = false;
        });
    }
  }

  @override
  void dispose() {
    unawaited(_scan?.cancel());
    unawaited(_notifier.stopScan());
    if (_connecting) unawaited(_notifier.cancelBleConnection());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_connecting,
      child: Scaffold(
          appBar: AppBar(title: const Text('连接备份中的录音卡')),
          body: ListView(padding: const EdgeInsets.all(20), children: [
            Text('SN：${widget.material.serialNumber}'),
            const SizedBox(height: 12),
            const Text(
                '将卡片置于附近。若无法发现，按已确认的方式连续点击5次按键，蓝灯闪烁后重新搜索。关闭其它手机的蓝牙连接，保留现有账号和系统配对。'),
            const SizedBox(height: 12),
            OutlinedButton(
                onPressed: _connecting ? null : _search,
                child: const Text('重新搜索')),
            if (_results.isEmpty)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text('尚未发现匹配SN的卡片')),
            ..._results.map((r) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(r.advertisementData.advName.isEmpty
                    ? '录音卡'
                    : r.advertisementData.advName),
                subtitle: Text('信号：${r.rssi} dBm'),
                trailing: FilledButton(
                    onPressed: _connecting ? null : () => _connect(r),
                    child: const Text('连接验证')))),
            if (_result != null)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(_result!)),
            if (_connecting)
              TextButton(
                  onPressed: _notifier.cancelBleConnection,
                  child: const Text('取消连接')),
          ])));
}

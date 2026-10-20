import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ble/ble_protocol.dart';
import '../core/ble/recorder_backup_files.dart';
import '../core/ble/recorder_portable_backup.dart';
import '../core/ble/recorder_saved_identity.dart';
import '../core/ble/recorder_authentication.dart';
import '../core/ble/recorder_credential_vault.dart';
import '../providers/device_provider.dart';

/// 普通连接入口复用备份页的离线SN搜索；仅在此路由存活时持有解密资料。
Future<void> showImportedRecorderConnection(BuildContext context,
    RecorderBackupService service, String serialNumber) async {
  final materials = await service.imported.readAll();
  try {
    final matches =
        materials.where((m) => m.serialNumber == serialNumber).toList();
    if (matches.length != 1) throw StateError('本机备份资料已变化，请重新读取');
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            _BackupConnectPage(serialNumber:matches.single.serialNumber,
                sessionForScan:(scan)=>service.offlineSession(matches.single,scan))));
  } finally {
    for (final material in materials) {
      material.clear();
    }
  }
}

Future<void> showRecorderCredentialCandidate(BuildContext context,
    {required String serialNumber,
    required RecorderAccountSession Function(RecorderScanIdentity) sessionForScan}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>
      _BackupConnectPage(serialNumber:serialNumber,sessionForScan:sessionForScan,candidate:true)));

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
  List<RecorderCredentialSummary> _history = [];
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
    List<RecorderCredentialSummary> history;
    try { history=await _service.credentialHistory(); }
    catch(_) { for(final m in imported) { m.clear(); } rethrow; }
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
      _history = history;
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
            _BackupConnectPage(serialNumber:material.serialNumber,
                sessionForScan:(scan)=>_service.offlineSession(material,scan))));
    if (mounted) await _perform(_load);
  }

  Future<void> _removeImported(PortableRecorderMaterial material) =>
      _perform(() async {
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('移除导入资料？'),
                    content: SingleChildScrollView(
                        child: Text(
                            'SN：${material.serialNumber}\n\n只移除这份本机导入记录。已恢复的活动密钥、导出文件、账号绑定和卡片数据都会保留。若需改用账号密钥，请选择“使用账号资料验证”。')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('移除导入资料'))
                    ]));
        if (confirmed != true || !mounted) return;
        await _service.imported.remove(material);
        await _load();
        if (mounted) setState(() => _message = '导入资料已移除；活动密钥及导出文件保留。');
      });

  Future<void> _restoreHistory(RecorderCredentialSummary selected) async {
    if (_busy) return;
    final notifier = ref.read(deviceProvider.notifier);
    if (notifier.isBleConnecting || notifier.isBleLinkConnected) {
      setState(() => _message = '请先结束当前蓝牙连接，再验证历史凭据。');
      return;
    }
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('验证并恢复历史凭据？'),
                content: SingleChildScrollView(
                    child: Text(
                        'SN：${selected.identity.serialNumber}\n\n将用这份历史资料连接卡片。卡片本次验证通过后才切换活动凭据；失败保持现状。所有旧版本保留，不解绑或重新协商。')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('继续验证'))
                ]));
    if (confirmed != true || !mounted) return;
    await showRecorderCredentialCandidate(context,
        serialNumber: selected.identity.serialNumber,
        sessionForScan: (scan) => _service.archivedSession(selected, scan));
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
        Align(alignment:Alignment.centerLeft,child:TextButton.icon(
            onPressed:_busy?null:()=>_perform(_load),icon:const Icon(Icons.refresh),label:const Text('重新读取本机资料'))),
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
              trailing: IconButton(tooltip:'移除导入资料',
                  onPressed:_busy?null:()=>_removeImported(r),
                  icon:const Icon(Icons.delete_outline)),
              onTap: _busy ? null : () => _connect(r))),
        ],
        if(_history.isNotEmpty) ...[
          const SizedBox(height:28),
          Text('连接凭据与历史版本',style:Theme.of(context).textTheme.titleMedium),
          const SizedBox(height:8),
          const Text('只有标为“当前使用”的版本用于日常连接。历史版本可重新验证后恢复；移除导入记录不会清除这些凭据。'),
          ..._history.map((r)=>Padding(padding:const EdgeInsets.symmetric(vertical:12),
            child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
              Text('${r.identity.deviceName} · ${r.active ? "当前使用" : "保留版本"}',
                  style:const TextStyle(fontWeight:FontWeight.w600)),
              Text('SN：${r.identity.serialNumber}\n${r.source} · ${r.createdAt.toLocal().toString().split(".").first}'),
              Text(r.verified?'曾通过卡片验证；恢复时仍会重新验证':'仍需本次卡片验证'),
              if(!r.active) TextButton(onPressed:_busy?null:()=>_restoreHistory(r),child:const Text('验证并恢复')),
            ]))),
        ],
        const SizedBox(height: 24),
        const Text('请将密码与备份文件分开保管。卡片重置或重新协商可能改变密钥；旧备份是否可用，以卡片本次验证为准。也可选择账号资料验证。',
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
  final String serialNumber;
  final RecorderAccountSession Function(RecorderScanIdentity) sessionForScan;
  final bool candidate;
  const _BackupConnectPage(
      {required this.serialNumber,
      required this.sessionForScan,
      this.candidate = false});
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
                    widget.serialNumber)
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
      if (scan.serialNumber != widget.serialNumber ||
          !scan.isFresh(DateTime.now())) {
        throw StateError('当前广播身份不匹配');
      }
      final session = widget.sessionForScan(scan);
      if (session.serialNumber != widget.serialNumber ||
          session.credentialCandidate != widget.candidate)
        throw StateError('所选凭据来源已变化');
      final ok =
          await _notifier.connectDevice(result.device, accountSession: session);
      if (mounted)
        setState(() {
          _result = ok
              ? widget.candidate
                  ? '卡片验证通过，已启用所选凭据；旧版本保留，可返回管理。'
                  : '连接成功：卡片真实AES验证已通过，可返回录音卡管理。'
              : '验证未完成，请查看蓝牙诊断。未解绑、未重新协商或覆盖旧密钥。';
        });
    } catch (_) {
      if (mounted)
        setState(() {
          _result = widget.candidate
              ? '候选验证未完成；旧凭据保留，请查看蓝牙诊断。'
              : '恢复连接未完成：请确认广播新鲜、卡片身份一致且本机无不同旧密钥。';
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
          appBar:
              AppBar(title: Text(widget.candidate ? '验证候选凭据' : '连接备份中的录音卡')),
          body: ListView(padding: const EdgeInsets.all(20), children: [
            Text('SN：${widget.serialNumber}'),
            if (widget.candidate)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child:
                      Text('卡片本次验证通过后才启用所选凭据。失败或没有身份挑战时保持现状；不执行首次绑定，不覆盖旧版本。')),
            const SizedBox(height: 12),
            Text(widget.candidate
                ? '将卡片置于附近，结束其它手机与卡片的连接。仅选择SN匹配的卡片；没有发现时保留当前绑定，查看连接诊断，不用重新添加设备。'
                : '将卡片置于附近。若无法发现，按已确认的方式连续点击5次按键，蓝灯闪烁后重新搜索。关闭其它手机的蓝牙连接，保留现有账号和系统配对。'),
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

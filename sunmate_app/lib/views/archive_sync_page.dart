import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../core/sync/archive_sync.dart';
import '../core/sync/archive_models.dart';
import '../providers/archive_sync_provider.dart';

class ArchiveSyncPage extends ConsumerStatefulWidget {
  const ArchiveSyncPage({super.key});
  @override
  ConsumerState<ArchiveSyncPage> createState() => _ArchiveSyncPageState();
}

class _ArchiveSyncPageState extends ConsumerState<ArchiveSyncPage> {
  final url = TextEditingController(), token = TextEditingController();
  bool working = false, restored = false;
  String? error;
  DateTime from = DateTime.now().subtract(const Duration(days: 1));
  DateTime to = DateTime.now();
  final selected = <String>{'meeting', 'lifelog', 'notification', 'summary'};
  static const labels = {
    'meeting': '会议资料与转写',
    'lifelog': '随身记录与转写',
    'notification': '允许采集的通知',
    'summary': '纪要、简报与复盘结果'
  };
  @override
  void initState() {
    super.initState();
    final sync = ref.read(archiveSyncProvider);
    sync.ready.then((_) {
      if (!mounted) return;
      setState(() {
        url.text = sync.config.url;
        token.text = sync.config.token;
        restored = true;
      });
    });
  }

  @override
  void dispose() {
    url.dispose();
    token.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() work) async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted)
        setState(() => error =
            e is ArchiveSyncException ? e.message : '操作未完成，请检查本机存储与私有归档服务。');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<bool> confirm(String title, String text,
          {String action = '确认'}) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) =>
              AlertDialog(title: Text(title), content: Text(text), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(action))
              ])) ??
      false;
  Future<void> connect(ArchiveSyncController sync) async {
    final identity = await sync.probe(url.text.trim(), token.text.trim());
    if (!mounted) return;
    final plain = Uri.parse(url.text.trim()).scheme == 'http';
    if (!await confirm(
        '确认私有资料库',
        'Profile：${identity['profile']}\n资料库：${identity['libraryId']}\n'
            '${plain ? '当前使用 HTTP，请确认这是你保护的私网入口。\n' : ''}'
            '确认后保存独立同步凭据；各类自动同步仍关闭。已有队列不会转发到新资料库。')) return;
    await sync.pair(url.text.trim(), token.text.trim(), identity);
  }

  Future<void> pick(bool start) async {
    final value = start ? from : to;
    final date = await showDatePicker(
        context: context,
        initialDate: value,
        firstDate: DateTime(2020),
        lastDate: DateTime.now());
    if (date == null || !mounted) return;
    final time = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(value));
    if (time == null || !mounted) return;
    setState(() {
      final next =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
      if (start) {
        from = next;
      } else {
        to = next;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(archiveSyncProvider);
    final enabled = restored && sync.loaded && !working && !sync.busy;
    final paired = enabled && sync.config.paired;
    final history = sync
        .history(from, to)
        .where((v) => selected.contains(v.category))
        .length;
    return Scaffold(
        appBar: AppBar(title: const Text('私有资料同步')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text('自动归档，按资料问答', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text(
              '转写、通知和总结保存到你自己的资料库。已确认的内容只传引用，缺少的再补传；同步本身不调用模型。原音频保留在手机和卡片。'),
          const SizedBox(height: 20),
          TextField(
              controller: url,
              enabled: enabled,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                  labelText: '归档服务地址',
                  hintText: 'https://你的节点/sunmate/v1',
                  border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
              controller: token,
              enabled: enabled,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              decoration: const InputDecoration(
                  labelText: '独立同步凭据',
                  helperText: '与 Hermes Token、录音卡密钥分开保存',
                  border: OutlineInputBorder())),
          const SizedBox(height: 12),
          FilledButton(
              onPressed: enabled ? () => run(() => connect(sync)) : null,
              child: const Text('核对并保存连接')),
          if (sync.config.paired)
            Text(
                '已确认 Profile：${sync.config.identity['profile']}\n资料库：${sync.config.identity['libraryId']}'),
          if (working || sync.busy) const LinearProgressIndicator(),
          if (error != null || sync.message != null)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(error ?? sync.message!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          const Divider(height: 32),
          Text('自动同步', style: Theme.of(context).textTheme.titleMedium),
          const Text(
              '默认关闭。开启后同步新增资料；旧资料通过下方范围补传。ASR 与自动纪要仍在录音处理设置中独立控制。手动生成报告会补传所选来源，关闭自动同步只暂停自动归档。'),
          for (final entry in labels.entries)
            SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(entry.value),
                value: sync.config.automatic.contains(entry.key),
                onChanged: !paired
                    ? null
                    : (value) => run(() async {
                          final next = {...sync.config.automatic};
                          if (value) {
                            next.add(entry.key);
                          } else {
                            next.remove(entry.key);
                          }
                          await sync.setAutomatic(next);
                        })),
          const Divider(height: 32),
          Text('归档状态', style: Theme.of(context).textTheme.titleMedium),
          Text(
              '本机通知 ${sync.received} 条 · 待发送 ${sync.pending} 个版本 · 服务器已确认 ${sync.confirmed} 个版本'),
          Text(
              '最后成功：${sync.lastSuccess == null ? '尚无' : DateFormat('MM月dd日 HH:mm').format(sync.lastSuccess!.toLocal())}'),
          const Text('停用通知来源或隐藏记录后，下一次同步会更新服务器查询可见性；离线时尚未生效。App 恢复前台后继续队列。'),
          TextButton.icon(
              onPressed:
                  enabled ? () => run(() => sync.refresh(retry: true)) : null,
              icon: const Icon(Icons.sync),
              label: const Text('核对队列并重试')),
          const Divider(height: 32),
          Text('历史资料补传', style: Theme.of(context).textTheme.titleMedium),
          TextButton(
              onPressed: enabled ? () => pick(true) : null,
              child: Text('开始：${from.toString().substring(0, 16)}')),
          TextButton(
              onPressed: enabled ? () => pick(false) : null,
              child: Text('结束：${to.toString().substring(0, 16)}')),
          for (final entry in labels.entries)
            CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(entry.value),
                value: selected.contains(entry.key),
                onChanged: !enabled
                    ? null
                    : (value) => setState(() {
                          if (value == true) {
                            selected.add(entry.key);
                          } else {
                            selected.remove(entry.key);
                          }
                        })),
          OutlinedButton(
              onPressed: paired && selected.isNotEmpty
                  ? () => run(() async {
                        if (!to.isAfter(from) ||
                            to.difference(from) > const Duration(days: 31))
                          throw const ArchiveSyncException('请选择31天以内的有效时间范围。');
                        await sync.refresh();
                        final count = sync
                            .history(from, to)
                            .where((v) => selected.contains(v.category))
                            .length;
                        if (!mounted ||
                            !await confirm('补传 $count 条资料',
                                '仅同步所选范围及类别中允许的文字和元数据，已有版本只核对回执。',
                                action: '确认补传')) return;
                        await sync.backfill(from, to, selected);
                        await sync.refresh(retry: true);
                      })
                  : null,
              child: Text('预览并补传（当前 $history 条）')),
          const Divider(height: 32),
          Text('最近回执', style: Theme.of(context).textTheme.titleMedium),
          if (sync.entries.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('尚无归档回执。先确认连接，再开启同步或补传历史资料。')),
          for (final row in sync.entries.reversed.take(20))
            ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                    '${labels[row['category']] ?? row['category']} · 版本 ${row['record']['revision']}'),
                subtitle: Text(DateFormat('MM月dd日 HH:mm').format(
                    DateTime.parse(row['record']['timestamp']).toLocal())),
                trailing: Text({
                      'confirmed': '已确认',
                      'pending': '待发送',
                      'invalid': '格式拒绝',
                      'conflict': '版本冲突',
                      'superseded': '已有新版本'
                    }[row['status']] ??
                    '待核对')),
        ]));
  }
}

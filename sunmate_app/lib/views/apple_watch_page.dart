import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/apple_watch_provider.dart';
import '../providers/chat_provider.dart';
import '../core/recordings/apple_watch_controller.dart';

class AppleWatchPage extends ConsumerStatefulWidget {
  const AppleWatchPage({super.key});
  @override
  ConsumerState<AppleWatchPage> createState() => _AppleWatchPageState();
}

class _AppleWatchPageState extends ConsumerState<AppleWatchPage>
    with WidgetsBindingObserver {
  bool _sending = false;
  Set<String> _types = {};
  String? _actionMessage;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_refresh);
  }

  Future<void> _refresh() async {
    final c = ref.read(appleWatchProvider);
    await c.refresh();
    await c.refreshHealth();
    if (mounted) setState(() => _types = Set.of(c.healthTypes));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _play(WatchPart part) async {
    try {
      await ref.read(appleWatchProvider).play(part);
    } catch (_) {
      if (mounted) setState(() => _actionMessage = '播放未完成，源音频保留，请重试。');
    }
  }

  Future<void> _send(WatchPart part) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _actionMessage = '正在校验音频，随后使用已有私有 ASR 和 Hermes。';
    });
    try {
      final bytes = await ref.read(appleWatchProvider).audio(part);
      final chat = ref.read(chatProvider.notifier),
          id = ref.read(chatProvider.notifier).beginVoiceInput();
      if (id == null) throw const FormatException();
      chat.finishVoiceInput();
      await chat.handleVoiceInput(bytes,
          voiceMessageId: id, filename: 'watch.wav');
      if (mounted)
        setState(() => _actionMessage = '已交给 AI 对讲页面，转写和完整回复状态请在那里查看。');
    } catch (_) {
      if (mounted) setState(() => _actionMessage = '未能提交音频，原录音保留，可重试。');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(appleWatchProvider),
        ready = c.loaded && c.supported && !c.busy;
    return Scaffold(
      appBar: AppBar(title: const Text('Apple Watch 与健康只读'), actions: [
        IconButton(
            onPressed: c.busy ? null : _refresh,
            tooltip: '刷新连接和本机资料',
            icon: const Icon(Icons.refresh))
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('从手腕开始记录', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('首期原型：在手表选择对讲、会议或随身用途，先离线保存，再同步到手机。新开关默认关闭。'),
        const SizedBox(height: 16),
        if (!c.loaded || c.busy) const LinearProgressIndicator(),
        Text(!c.supported
            ? '需要 iPhone 上的原生手表接收模块。'
            : !c.paired
                ? '系统尚未报告已配对手表。'
                : !c.installed
                    ? '已配对；尚未报告安装 SunMate 手表 App。'
                    : c.reachable
                        ? '手表 App 当前可即时通信。'
                        : '手表暂不可即时通信，文件由系统安排后台传输。'),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('接收手表录音'),
            subtitle: const Text('先在手机开启接收，再在手表启用录音和同步；不会读取或修改录音卡密钥。'),
            value: c.enabled,
            onChanged: ready
                ? (v) =>
                    c.configure(enabled: v, backgroundSync: c.backgroundSync)
                : null),
        const Text('手表上的“自动同步已保存音频”控制后台补传；仅收到手机落盘回执才确认送达。这里不代表服务器音频上传已启用。'),
        if (c.message != null)
          Text(c.message!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (_actionMessage != null)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_actionMessage!)),
        const Divider(height: 32),
        Text('本机录音', style: Theme.of(context).textTheme.titleMedium),
        if (c.sessions.isEmpty)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('尚无已校验手表录音。手表结束录音并同步后，可在这里查看。')),
        for (final s in c.sessions)
          ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('${{
                'voice': '语音对讲',
                'meeting': '会议',
                'lifelog': '随身记录'
              }[s.purpose]} · ${s.started.toLocal().toString().substring(0, 16)}'),
              subtitle: Text(
                  '${s.parts.length} 段 · ${s.duration.inSeconds} 秒 · ${s.interrupted ? '有中断，请检查覆盖' : s.complete ? '手机文件已齐全' : '尚未完整'}'),
              children: [
                for (final p in s.parts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('片段 ${p.part + 1} · ${p.duration.inSeconds} 秒'),
                    trailing: Wrap(children: [
                      IconButton(
                          onPressed: () => _play(p),
                          tooltip: '播放这一段',
                          icon: const Icon(Icons.play_arrow)),
                      if (s.purpose == 'voice')
                        IconButton(
                            onPressed: _sending ? null : () => _send(p),
                            tooltip: '确认发送到私有对讲',
                            icon: const Icon(Icons.send))
                    ]),
                  )
              ]),
        if (c.sessions.isNotEmpty)
          TextButton(
              onPressed: () => c.stopPlayback(), child: const Text('停止播放')),
        const Divider(height: 32),
        Text('健康只读 · 仅保存在本机视图', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('按项目向苹果健康申请读取，不写入健康数据、不上传给 ASR 或 Hermes，也不计算压力评分。'),
        for (final e in {
          'heart': '心率与静息心率',
          'hrv': 'HRV（SDNN）',
          'sleep': '最近24小时睡眠',
          'steps': '今天步数'
        }.entries)
          CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(e.value),
              value: _types.contains(e.key),
              onChanged: ready
                  ? (v) => setState(() {
                        if (v == true) {
                          _types.add(e.key);
                        } else {
                          _types.remove(e.key);
                        }
                      })
                  : null),
        OutlinedButton(
            onPressed: !ready || _types.isEmpty
                ? null
                : () => c.configureHealth(true, _types),
            child: const Text('授权并读取选中项目')),
        if (c.healthEnabled)
          TextButton(
              onPressed: ready ? () => c.configureHealth(false, _types) : null,
              child: const Text('关闭本 App 健康读取')),
        for (final row in c.healthSamples)
          ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${{
                'heartRate': '心率',
                'restingHeartRate': '静息心率',
                'hrvSDNN': 'HRV（SDNN）',
                'sleep': '睡眠',
                'steps': '步数'
              }[row['kind']]}：${(row['value'] as num).toStringAsFixed(row['kind'] == 'steps' ? 0 : 1)} ${row['unit']}'),
              subtitle: Text(
                  '${row['source']} · 截至 ${DateTime.parse(row['to']).toLocal().toString().substring(0, 16)}')),
        if (c.healthEnabled && c.healthSamples.isEmpty)
          const Text('暂无可用样本；可能尚未测量、未同步或未开放读取。请解锁后重试，不会用0代替缺失数据。'),
        const SizedBox(height: 16),
        const Text('GPS版可离线录音。熄屏、中断和续航仍需实机验证；手机收到文件不等于服务器已完成 ASR 或总结。'),
      ]),
    );
  }
}

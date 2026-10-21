import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/recording_background_provider.dart';

class RecordingBackgroundPage extends ConsumerWidget {
  const RecordingBackgroundPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(recordingBackgroundProvider);
    final enabled = c.loaded && c.supported && !c.busy;
    Future<void> run(Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {/* The controller shows a fixed safe error. */}
    }

    Widget flag(String key, String title, String subtitle) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: Text(subtitle),
        value: c.policy[key],
        onChanged: enabled ? (v) => run(() => c.setFlag(key, v)) : null);
    return Scaffold(
        appBar: AppBar(title: const Text('后台录音与服务器处理')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text('手机收段，服务器继续处理', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text(
              '全部默认关闭。开启前先在“私有资料同步”核对自己的资料库。设置作用于之后开始的新录音；旧录音和已有转写任务保留原处理方式。'),
          const SizedBox(height: 16),
          flag('receive', '后台蓝牙收段',
              '仅接收已关闭分段；当前文件完成后交接。断连后仍需真实身份验证。状态恢复在下次启动后生效。'),
          flag('cellular', '允许蜂窝网络上传音频', '默认仅 Wi-Fi；可能产生较大流量。'),
          const Divider(height: 32),
          Text('会议', style: Theme.of(context).textTheme.titleMedium),
          flag('meetingUpload', '自动上传会议分段', '上传校验过的音频，停止后确认完整目录。原音频继续保留。'),
          flag('meetingAsr', '服务器自动转写会议', '开启时一并开启上传；手机不再重复提交本次 ASR。'),
          flag('meetingSummary', '完整归档后自动会议纪要', '等待停止、尾段确认和全部转写后生成整场纪要。'),
          const Divider(height: 32),
          Text('随身记录', style: Theme.of(context).textTheme.titleMedium),
          flag('lifelogUpload', '自动上传随身分段', '按时间段保留来源与时间证据。'),
          flag('lifelogAsr', '服务器自动转写随身记录', '逐段处理，结果恢复到本机时间线。'),
          flag('lifelogSummary', '本次随身录音结束后自动复盘',
              '结合本次范围内已允许并已同步的通知；时间不明时不强行关联，不默认读取其它客户端通知。'),
          const Divider(height: 32),
          if (c.busy) const LinearProgressIndicator(),
          Text(c.message ?? (c.loaded ? '后台处理开关默认关闭。' : '正在安全读取设置…')),
          const SizedBox(height: 12),
          Text(
              '原生上传：${c.transfers.where((v) => v['state'] == 'received').length} 段已获服务器回执；${c.transfers.where((v) => v['state'] != 'received').length} 段待核对。'),
          OutlinedButton.icon(
              onPressed: enabled ? () => run(c.refresh) : null,
              icon: const Icon(Icons.sync),
              label: const Text('核对上传与取回结果')),
          for (final state in c.serverStates.values.toList().reversed.take(10))
            ListTile(
                contentPadding: EdgeInsets.zero,
                title:
                    Text(state['kind'] == 'summary' ? '服务器总结已取回' : '服务器处理状态'),
                subtitle: Text({
                      'received': '音频已归档',
                      'polling': '正在转写',
                      'complete': '转写已保存',
                      'submission_unknown': '提交结果待核对，未重复提交',
                      'failed': '转写失败，原音频保留',
                      'preparation_paused': '服务器解码或空间待恢复，原音频保留',
                      'summary_unknown': '总结请求结果待核对，未重复请求',
                      'batch_unknown': '分批整理结果待核对',
                      'manual_range_required': '资料量超出自动处理范围，请按时间范围整理'
                    }[state['state']] ??
                    '结果已取回')),
          const SizedBox(height: 20),
          const Text(
              '服务器需显式启用私有 ASR 和 Hermes 处理配置。关闭开关会停止新任务，联网确认前服务器可能尚未收到停用；已经发出的请求无法撤回。'),
          const SizedBox(height: 12),
          const Text(
              'iOS 会决定后台唤醒和传输时机，不能保证持续运行。强制划掉 App 会中止系统传输；已经送达服务器的任务可继续，未送达的在重新打开后恢复。卡片、手机和服务器的原录音均不会自动删除。'),
        ]));
  }
}

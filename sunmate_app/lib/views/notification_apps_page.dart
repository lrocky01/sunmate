import 'package:flutter/material.dart';
import '../core/notifications/mobile_notification_manager.dart';
import '../core/notifications/notification_app_policy.dart';

class NotificationAppsPage extends StatefulWidget {
  final NotificationAppPolicy? policy;
  const NotificationAppsPage({super.key, this.policy});
  @override
  State<NotificationAppsPage> createState() => _NotificationAppsState();
}

class _NotificationAppsState extends State<NotificationAppsPage> {
  late final NotificationAppPolicy _policy =
      widget.policy ?? MobileNotificationManager().appPolicy;
  bool _saving = false;
  Future<void> _save(Future<bool> Function() operation) async {
    setState(() => _saving = true);
    try {
      await operation();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('可采集的应用')),
        body: AnimatedBuilder(
            animation: _policy,
            builder: (context, _) => ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text('这里只列出录音卡实际回传过通知的应用，不是手机已安装应用清单。'),
                    const SizedBox(height: 12),
                    SwitchListTile(
                        title: const Text('允许 SunMate 采集通知'),
                        subtitle: const Text(
                            '仅控制 SunMate 本地采集与使用，不改变 iPhone 通知、共享系统通知授权或卡片灯效。'),
                        value: _policy.enabled,
                        onChanged: !_policy.loaded || _saving
                            ? null
                            : (v) => _save(() => _policy.setEnabled(v))),
                    if (!_policy.loaded && _policy.message == null)
                      const LinearProgressIndicator(),
                    if (_saving) const LinearProgressIndicator(),
                    if (_policy.message != null) ...[
                      Text(_policy.message!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                      TextButton(
                          onPressed: _saving
                              ? null
                              : () => _save(() async {
                                    await _policy.reload();
                                    return _policy.loaded;
                                  }),
                          child: const Text('重试读取设置')),
                    ],
                    if (_policy.loaded && _policy.apps.isEmpty)
                      const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child:
                              Text('尚未收到应用通知。请保持录音卡连接，并发送一条测试通知；收到后应用会出现在这里。')),
                    for (final app in _policy.apps)
                      SwitchListTile(
                          title: Text(app.name),
                          subtitle: Text('${app.id}\n已回传 ${app.count} 条通知'),
                          isThreeLine: true,
                          value: app.enabled,
                          onChanged:
                              !_policy.loaded || !_policy.enabled || _saving
                                  ? null
                                  : (v) => _save(
                                      () => _policy.setAppEnabled(app.id, v))),
                    const SizedBox(height: 16),
                    const Text('采集选择会保存在本机。此页不读取或展示通知正文，也不会自动上传给智能体。'),
                  ],
                )),
      );
}

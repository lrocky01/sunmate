import 'package:flutter/material.dart';
import '../core/ble/recorder_connection_details.dart';
import '../core/ble/yoooclaw_account.dart';

/// 设备设置中展示经过核对的资料；不展示或推断共享密钥值。
class RecorderAccountDeviceInfo extends StatelessWidget {
  final AccountRecorderDevice device;
  const RecorderAccountDeviceInfo({super.key, required this.device});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('SN：${device.serialNumber}'),
          const SizedBox(height: 6),
          Text('账号设备类型：${device.protocolLabel}'),
          const SizedBox(height: 6),
          Text('蓝牙地址资料：${device.hasMac ? "账号已返回" : "账号未返回"}'),
          const SizedBox(height: 6),
          Text('共享密钥：${device.keyMaterialSummary}'),
          const SizedBox(height: 8),
          Text('账号资料与当前蓝牙连接分别验证，密钥值不显示。',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      );
}

/// 系统连接、GATT、业务验证和录音就绪各自显示真实状态。
class RecorderDeviceStatusPanel extends StatelessWidget {
  final RecorderConnectionDetails details;
  const RecorderDeviceStatusPanel({super.key, required this.details});

  Widget _row(
          BuildContext context, String title, String value, bool complete) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(
              complete
                  ? Icons.check_circle_outline
                  : Icons.radio_button_unchecked,
              size: 20,
              color: complete
                  ? Colors.green.shade800
                  : Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(value, style: const TextStyle(fontSize: 13)),
              ])),
        ]),
      );

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _row(
              context,
              '蓝牙链路',
              details.linkConnected
                  ? '已建立'
                  : details.nativeState == 1
                      ? '系统正在连接，尚无成功回调'
                      : '尚未建立',
              details.linkConnected),
          _row(
              context,
              '设备服务',
              details.gattDiscovered
                  ? '已识别 ${details.protocol}'
                  : details.linkConnected
                      ? '等待发现 GATT 服务'
                      : '等待蓝牙链路',
              details.gattDiscovered),
          _row(
              context,
              '设备身份',
              details.identityVerified
                  ? '本次身份挑战已通过'
                  : details.authenticationStarted
                      ? '本次验证尚未完成，详情见日志'
                      : details.gattDiscovered
                          ? '尚未通过业务验证'
                          : '尚未执行业务鉴权',
              details.identityVerified),
          _row(
              context,
              '录音通道',
              details.businessReady
                  ? '已就绪，可使用卡片按键录音'
                  : details.channelsReady
                      ? '已订阅，等待身份验证'
                      : '尚未就绪',
              details.businessReady),
          const SizedBox(height: 8),
          Text(
              'iPhone 通知：${details.requiresAncs ? "本次请求通知服务" : "仅录音连接"}。'
              '通知授权属性为${details.ancsAuthorized == null ? "未知" : details.ancsAuthorized! ? "允许" : "未允许"}，不代表设备已配对或身份已验证。',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('查看系统连接详情', style: TextStyle(fontSize: 13)),
            children: [
              Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                      '本轮本机身份：${details.localIdentityLoaded ? "已加载合法格式的密钥，仍需卡片验证" : "尚未加载，不能据此判断存储中没有密钥"}\n'
                      '原生状态：${details.nativeStateLabel}\n'
                      '系统已连接列表匹配：${details.systemConnectedMatch == null ? "未查询" : details.systemConnectedMatch! ? "命中" : "未命中"}\n'
                      '最近广播可连接：${details.advertisementConnectable == null ? "未知" : details.advertisementConnectable! ? "是" : "否"}\n'
                      '列表仅查询 HID 与录音卡服务；未命中不能单独证明物理链路状态。',
                      style: const TextStyle(fontSize: 12))),
            ],
          ),
        ],
      );
}

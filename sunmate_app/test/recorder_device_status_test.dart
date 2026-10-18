import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ble/recorder_connection_details.dart';
import 'package:sunmate_app/core/ble/yoooclaw_account.dart';
import 'package:sunmate_app/views/recorder_device_status.dart';
import 'yoooclaw_account_test.dart' show record;

Widget screen(Widget child) => MaterialApp(
    home: Scaffold(
        body: SingleChildScrollView(
            child: Padding(padding: const EdgeInsets.all(16), child: child))));

void main() {
  testWidgets('failed authentication remains visible after link cleanup',
      (tester) async {
    await tester.pumpWidget(screen(const RecorderDeviceStatusPanel(
        details: RecorderConnectionDetails(authenticationStarted: true))));
    expect(find.text('本次验证尚未完成，详情见日志'), findsOneWidget);
    expect(find.text('尚未执行业务鉴权'), findsNothing);
    expect(find.text('本次身份挑战已通过'), findsNothing);
  });
  testWidgets(
      'system ANCS authorization cannot mark pending BLE or identity ready',
      (tester) async {
    await tester.pumpWidget(screen(const RecorderDeviceStatusPanel(
        details: RecorderConnectionDetails(
            nativeState: 1,
            ancsAuthorized: true,
            systemConnectedMatch: true))));
    expect(find.text('系统正在连接，尚无成功回调'), findsOneWidget);
    expect(find.text('尚未执行业务鉴权'), findsOneWidget);
    expect(find.text('已就绪，可使用卡片按键录音'), findsNothing);
    await tester.tap(find.text('查看系统连接详情'));
    await tester.pumpAndSettle();
    expect(find.textContaining('尚未加载，不能据此判断存储中没有密钥'), findsOneWidget);
    expect(find.textContaining('系统已连接列表匹配：命中'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GATT and a saved identity still require the device challenge',
      (tester) async {
    await tester.pumpWidget(screen(const RecorderDeviceStatusPanel(
        details: RecorderConnectionDetails(
            linkConnected: true,
            gattDiscovered: true,
            channelsReady: true,
            localIdentityLoaded: true,
            protocol: 'telink'))));
    expect(find.text('尚未通过业务验证'), findsOneWidget);
    expect(find.text('已订阅，等待身份验证'), findsOneWidget);
    expect(find.text('本次身份挑战已通过'), findsNothing);
  });

  testWidgets(
      'account device details distinguish recoverable key from missing field without revealing it',
      (tester) async {
    final complete = AccountRecorderDevice.fromRecord(record())!;
    final missing = AccountRecorderDevice.fromRecord(
        {...record(), 'extInfo': <String, dynamic>{}})!;
    await tester.pumpWidget(screen(Column(children: [
      RecorderAccountDeviceInfo(device: complete),
      RecorderAccountDeviceInfo(device: missing)
    ])));
    expect(find.text('共享密钥：可恢复，仍需卡片验证'), findsOneWidget);
    expect(find.text('共享密钥：账号未返回共享密钥'), findsOneWidget);
    expect(find.textContaining('test-only-mac'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

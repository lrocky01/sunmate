import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/yoooclaw_account.dart';
import 'package:sunmate_app/views/recorder_account_sheet.dart';
import 'yoooclaw_account_test.dart' show record;

class WidgetAccount extends YoooClawAccount {
  bool loggedIn = false;
  bool closed = false;
  int smsCalls = 0;
  final binding = OwnedRecorderBinding.fromAccountRecord(record())!;
  @override
  bool get isLoggedIn => loggedIn;
  @override
  Future<void> sendSms(String phone) async { smsCalls++; }
  @override
  Future<void> login(String phone, String smsCode) async { loggedIn = true; }
  @override
  Future<List<OwnedRecorderBinding>> loadBindings() async => [binding];
  @override
  void close() { closed = true; loggedIn = false; binding.clear(); super.close(); }
}
void main() {
  testWidgets('phone layout supports login; mismatched/unobserved hardware cannot restore', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final account = WidgetAccount();
    await tester.pumpWidget(ProviderScope(child: MaterialApp(home: Scaffold(
        body: RecorderAccountSheet(account: account)))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField).at(0), '13800000000');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.ensureVisible(find.text('获取验证码'));
    await tester.tap(find.text('获取验证码'));
    await tester.pumpAndSettle();
    expect(account.smsCalls, 1);
    expect(find.text('60s'), findsOneWidget);
    await tester.ensureVisible(find.text('登录并读取我的绑定设备'));
    await tester.tap(find.text('登录并读取我的绑定设备'));
    await tester.pumpAndSettle();
    expect(find.text('Test recorder'), findsOneWidget);
    final restore = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '恢复并验证连接'));
    expect(restore.onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    expect(account.closed, true);
  });
}

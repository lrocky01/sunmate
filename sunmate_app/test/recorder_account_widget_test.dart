import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/yoooclaw_account.dart';
import 'package:sunmate_app/views/recorder_account_sheet.dart';
import 'package:sunmate_app/views/home_page.dart';
import 'yoooclaw_account_test.dart' show record;

class WidgetAccount extends YoooClawAccount {
  bool loggedIn = false;
  bool closed = false;
  int smsCalls = 0;
  final binding = OwnedRecorderBinding.fromAccountRecord(record())!;
  @override
  List<AccountRecorderDevice> get devices =>
      [AccountRecorderDevice.fromRecord(record())!];
  @override
  bool get isLoggedIn => loggedIn;
  @override
  Future<void> sendSms(String phone) async {
    smsCalls++;
  }

  @override
  Future<void> login(String phone, String smsCode) async {
    loggedIn = true;
  }

  @override
  Future<List<OwnedRecorderBinding>> loadBindings() async => [binding];
  @override
  void close() {
    closed = true;
    loggedIn = false;
    binding.clear();
    super.close();
  }
}

void main() {
  testWidgets(
      'connection entry requires account login before scanning or device SN',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final account = WidgetAccount();
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Scaffold(body: RecorderConnectionSheet(account: account)))));
    await tester.pumpAndSettle();
    expect(find.text('登录并连接录音卡'), findsOneWidget);
    expect(find.text('录音卡连接设置'), findsNothing);
    expect(find.textContaining('当前录音卡 SN'), findsNothing);
    await tester.enterText(find.byType(TextField).at(0), '13800000000');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.ensureVisible(find.text('登录并读取我的设备'));
    await tester.tap(find.text('登录并读取我的设备'));
    await tester.pumpAndSettle();
    expect(find.text('选择并搜索'), findsOneWidget);
    expect(find.text('Test recorder'), findsOneWidget);
    final scroll = tester.widget<SingleChildScrollView>(find.descendant(
        of: find.byType(RecorderAccountSheet),
        matching: find.byType(SingleChildScrollView)));
    expect(scroll.controller!.offset, 0);
    expect(account.closed, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    expect(account.closed, true);
  });
  testWidgets(
      'device settings and scan failure remain scrollable on a small phone',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final account = WidgetAccount()..loggedIn = true;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Scaffold(body: RecorderConnectionSheet(account: account)))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('选择并搜索'));
    await tester.tap(find.text('选择并搜索'));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('录音卡连接设置'), findsOneWidget);
    await tester.tap(find.text('设备资料与连接方式'));
    await tester.pumpAndSettle();
    expect(find.textContaining('可恢复，仍需卡片验证'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    expect(account.closed, true);
  });
  testWidgets(
      'phone layout supports login; mismatched/unobserved hardware cannot restore',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final account = WidgetAccount();
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Scaffold(body: RecorderAccountSheet(account: account)))));
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
    final restore = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '恢复并验证连接'));
    expect(restore.onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    expect(account.closed, true);
  });
}

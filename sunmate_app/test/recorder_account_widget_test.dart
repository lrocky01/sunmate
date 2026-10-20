import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sunmate_app/core/ble/yoooclaw_account.dart';
import 'package:sunmate_app/views/recorder_account_sheet.dart';
import 'package:sunmate_app/views/home_page.dart';
import 'yoooclaw_account_test.dart' show record;

class WidgetAccount extends YoooClawAccount {
  bool loggedIn = false;
  bool closed = false;
  int smsCalls = 0;
  int listCalls = 0;
  final binding = OwnedRecorderBinding.fromAccountRecord(record())!;
  @override
  List<AccountRecorderDevice> get devices =>
      [AccountRecorderDevice.fromRecord(record())!];
  @override
  bool get isLoggedIn => loggedIn;
  @override
  bool get isSessionSaved => loggedIn;
  @override
  Future<bool> restoreSession() async => loggedIn;
  @override
  Future<void> logout() async { loggedIn = false; }
  @override
  Future<void> sendSms(String phone) async {
    smsCalls++;
  }

  @override
  Future<void> login(String phone, String smsCode) async {
    loggedIn = true;
  }

  @override
  Future<List<OwnedRecorderBinding>> loadBindings() async {
    listCalls++;
    return [binding];
  }
  @override
  void close() {
    closed = true;
    loggedIn = false;
    binding.clear();
    super.close();
  }
}

class EmptyWidgetAccount extends WidgetAccount {
  @override
  List<AccountRecorderDevice> get devices => [];
  @override
  Future<List<OwnedRecorderBinding>> loadBindings() async => [];
}

class RestoringWidgetAccount extends WidgetAccount {
  @override
  Future<bool> restoreSession() async { loggedIn = true; return true; }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  Future<void> chooseOfficialRoute(WidgetTester tester) async {
    final entry = find.text('首次绑定或通过官方账号恢复');
    if (entry.evaluate().isNotEmpty) {
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
    }
  }
  testWidgets('saved login restores and refreshes without SMS; logout shows login', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final account = RestoringWidgetAccount();
    await tester.pumpWidget(ProviderScope(child: MaterialApp(home: Scaffold(
        body: RecorderConnectionSheet(account: account)))));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('登录状态已安全保存'), findsOneWidget);
    expect(account.listCalls, 1);
    await tester.ensureVisible(find.text('重新读取我的设备'));
    await tester.tap(find.text('重新读取我的设备'));
    await tester.pumpAndSettle();
    expect(account.listCalls, 2);
    expect(account.smsCalls, 0);
    await tester.ensureVisible(find.text('退出官方账号'));
    await tester.tap(find.text('退出官方账号'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('退出官方账号'), findsNothing);
    expect(account.smsCalls, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
  });
  testWidgets('empty account can add a new recorder after login', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final account = EmptyWidgetAccount();
    await tester.pumpWidget(ProviderScope(child: MaterialApp(
        home: Scaffold(body: RecorderConnectionSheet(account: account)))));
    await tester.pumpAndSettle();
    expect(find.text('添加新录音卡'), findsNothing);
    await chooseOfficialRoute(tester);
    await tester.enterText(find.byType(TextField).at(0), '13800000000');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.ensureVisible(find.text('登录并读取我的设备'));
    await tester.tap(find.text('登录并读取我的设备'));
    await tester.pumpAndSettle();
    expect(find.text('选择并搜索'), findsNothing);
    await tester.ensureVisible(find.text('添加新录音卡'));
    await tester.tap(find.text('添加新录音卡'));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('添加新录音卡'), findsOneWidget);
    expect(find.textContaining('账号 SN：'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('返回账号设备'));
    await tester.pumpAndSettle();
    expect(find.text('连接录音卡'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('添加新录音卡'), findsOneWidget);
    expect(account.closed, false);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    expect(account.closed, true);
  });
  testWidgets(
      'first binding without local material keeps official account route',
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
    expect(find.text('连接录音卡'), findsOneWidget);
    await chooseOfficialRoute(tester);
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
    await chooseOfficialRoute(tester);
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

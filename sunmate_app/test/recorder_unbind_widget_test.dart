import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/yoooclaw_account.dart';
import 'package:sunmate_app/providers/device_provider.dart';
import 'package:sunmate_app/core/hardware/hardware_device_factory.dart';
import 'package:sunmate_app/views/recorder_account_sheet.dart';
import 'recorder_account_widget_test.dart' show WidgetAccount;

class UnbindWidgetAccount extends WidgetAccount {
  int unbindCalls = 0;
  bool pending = false, removed = false, failRefresh = false;
  Completer<void>? gate;
  @override
  bool get hasPendingUnbind => pending;
  @override
  String? get unbindNotice => pending ? '服务器已接受解绑请求，尚未确认列表移除' : null;
  @override
  List<AccountRecorderDevice> get devices => removed ? [] : super.devices;
  @override
  bool canUnbindDevice(AccountRecorderDevice device) => loggedIn && !pending;
  @override
  Future<void> unbindDevice(AccountRecorderDevice device,
      {required bool Function() canProceed}) async {
    if (!canProceed()) throw const OfficialAccountException('蓝牙正在连接');
    unbindCalls++;
    if (gate != null) await gate!.future;
    pending = true;
  }

  @override
  Future<List<OwnedRecorderBinding>> loadBindings() async {
    listCalls++;
    if (pending && failRefresh) throw const OfficialAccountException('列表暂不可用');
    if (pending) {
      removed = true;
      pending = false;
    }
    return removed ? [] : [binding];
  }
}

class BusyDeviceNotifier extends DeviceNotifier {
  BusyDeviceNotifier() : super(HardwareDeviceFactory());
  @override
  bool get isBleConnecting => true;
}

void main() {
  for (final size in [const Size(360, 640), const Size(390, 844)]) {
    testWidgets('unbind cancellation and confirmation at $size',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final account = UnbindWidgetAccount()..loggedIn = true;
      var additions = 0;
      await tester.pumpWidget(ProviderScope(
          child: MaterialApp(
              home: Scaffold(
                  body: RecorderAccountSheet(
                      account: account,
                      onSelectDevice: (_) {},
                      onAddDevice: () => additions++)))));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('解绑账号设备'));
      await tester.tap(find.text('解绑账号设备'));
      await tester.pumpAndSettle();
      expect(find.textContaining('AB00000000000001'), findsWidgets);
      expect(find.textContaining('本机旧密钥保留'), findsOneWidget);
      expect(account.unbindCalls, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(account.unbindCalls, 0);
      await tester.tap(find.text('解绑账号设备'));
      await tester.pumpAndSettle();
      account.gate = Completer<void>();
      await tester.tap(find.text('备份并解绑账号设备'));
      await tester.pump();
      expect(account.unbindCalls, 1);
      expect(
          tester
              .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, '重新读取我的设备'))
              .onPressed,
          isNull);
      account.gate!.complete();
      await tester.pumpAndSettle();
      expect(account.unbindCalls, 1);
      expect(find.text('解绑账号设备'), findsNothing);
      expect(additions, 0);
      await tester.ensureVisible(find.text('添加新录音卡'));
      await tester.tap(find.text('添加新录音卡'));
      expect(additions, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'accepted but failed refresh disables add, refresh never re-unbinds',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final account = UnbindWidgetAccount()
      ..loggedIn = true
      ..failRefresh = true;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Scaffold(
                body: RecorderAccountSheet(
                    account: account,
                    onSelectDevice: (_) {},
                    onAddDevice: () {})))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('解绑账号设备'));
    await tester.tap(find.text('解绑账号设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('备份并解绑账号设备'));
    await tester.pumpAndSettle();
    expect(find.text('列表暂不可用'), findsOneWidget);
    expect(find.textContaining('尚未确认列表移除'), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(find.ancestor(
                of: find.text('添加新录音卡'),
                matching: find.byWidgetPredicate((w) => w is OutlinedButton)))
            .onPressed,
        isNull);
    account.failRefresh = false;
    await tester.ensureVisible(find.text('重新读取我的设备'));
    await tester.tap(find.text('重新读取我的设备'));
    await tester.pumpAndSettle();
    expect(account.unbindCalls, 1);
    expect(find.text('解绑账号设备'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pending native connection disables account unbind',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final account = UnbindWidgetAccount()..loggedIn = true;
    await tester.pumpWidget(ProviderScope(
        overrides: [
          deviceProvider.overrideWith((ref) => BusyDeviceNotifier()),
        ],
        child: MaterialApp(
            home: Scaffold(
                body: RecorderAccountSheet(
                    account: account, onSelectDevice: (_) {})))));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '解绑账号设备'))
            .onPressed,
        isNull);
    expect(account.unbindCalls, 0);
    await tester.pumpWidget(const SizedBox());
  });
}

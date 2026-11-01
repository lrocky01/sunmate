import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/hardware/apple_watch_driver.dart';
import 'package:sunmate_app/core/recordings/apple_watch_controller.dart';
import 'package:sunmate_app/providers/apple_watch_provider.dart';
import 'package:sunmate_app/views/apple_watch_page.dart';
import 'apple_watch_test.dart' show FakeWatchNative;

void main() {
  testWidgets(
      'watch controls start disabled and health requires explicit action',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final native = FakeWatchNative();
    final driver = AppleWatchDriver(native: native);
    final controller = AppleWatchController(driver);
    await tester.pumpWidget(ProviderScope(
      overrides: [appleWatchProvider.overrideWith((ref) => controller)],
      child: const MaterialApp(home: AppleWatchPage()),
    ));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        false);
    expect(native.calls.where((c) => c == 'healthConfigure'), isEmpty);
    await tester.scrollUntilVisible(find.text('心率与静息心率'), 250);
    await tester.tap(find.text('心率与静息心率'));
    await tester.pumpAndSettle();
    expect(native.calls.where((c) => c == 'healthConfigure'), isEmpty);
    await tester.scrollUntilVisible(find.text('授权并读取选中项目'), 200);
    await tester.tap(find.text('授权并读取选中项目'));
    await tester.pumpAndSettle();
    expect(native.calls.where((c) => c == 'healthConfigure').length, 1);
    expect(find.textContaining('暂无可用样本'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await driver.dispose();
  });
}

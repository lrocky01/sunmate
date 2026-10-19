import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/ble_protocol.dart';
import 'package:sunmate_app/core/ble/recorder_authentication.dart';
import 'package:sunmate_app/core/ble/recorder_saved_identity.dart';
import 'package:sunmate_app/core/ble/yoooclaw_account.dart';
import 'package:sunmate_app/core/hardware/hardware_device_factory.dart';
import 'package:sunmate_app/providers/device_provider.dart';
import 'package:sunmate_app/views/home_page.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_account_widget_test.dart' show WidgetAccount;

class RecoveryWidgetAccount extends WidgetAccount {
  @override
  RecorderAccountSession sessionForDevice(AccountRecorderDevice device) =>
      RecorderAccountSession(
          device.serialNumber,
          ({required checkContent, required mac, required sn}) async =>
              throw StateError('No new issuance'),
          ({required sn, required mac, required sharedSecret}) async =>
              throw StateError('No rebind'));
}

class RecoveryNotifier extends DeviceNotifier {
  final RecorderRecoveryCandidate candidate;
  final bool saved;
  int connects = 0;
  RecorderRecoveryCandidate? selected;
  RecoveryNotifier(this.candidate, this.saved) : super(HardwareDeviceFactory());
  @override
  bool get canReconnectVerifiedDevice => false;
  @override
  bool get isBleConnecting => false;
  @override
  Stream<String> get logStream => const Stream.empty();
  @override
  String get connectionSummary => '设备身份待验证';
  @override
  String? get lastError => '尚未收到本次身份验证成功回执';
  @override
  Future<List<RecorderRecoveryCandidate>> recoveryCandidates({
    RecorderAccountSession? accountSession,
    bool includeSystemDevices = true,
  }) async =>
      saved || includeSystemDevices ? [candidate] : [];
  @override
  Future<bool> connectDevice(
    BluetoothDevice device, {
    RecorderAccountSession? accountSession,
    RecorderRecoveryCandidate? recoveryCandidate,
  }) async {
    connects++;
    selected = recoveryCandidate;
    return false; // UI must retain the pending state; real AES is tested in recorder_recovery_test.
  }
}

Future<void> capture(WidgetTester tester, GlobalKey key, String label) async {
  if (!const bool.fromEnvironment('SUNMATE_CAPTURE_RECOVERY_UI')) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    final directory = Directory(
        '/Users/m/Documents/VS/sunmate/build_output/recovery-ui-local');
    await directory.create(recursive: true);
    await File('${directory.path}/$label.png')
        .writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = TestBlePlatform();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterBluePlusPlatform.instance = platform;
    if (const bool.fromEnvironment('SUNMATE_CAPTURE_RECOVERY_UI')) {
      for (final entry in {
        'RecoveryFixture': '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
        'MaterialIcons': '/private/tmp/sunmate-flutter-sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(entry.key)..addFont(File(entry.value).readAsBytes().then((b) => b.buffer.asByteData()))).load();
      }
    }
  });
  for (final size in [const Size(360, 640), const Size(390, 844)]) {
    for (final saved in [true, false]) {
      testWidgets('recovery entry without advertising: saved=$saved, $size',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        platform.reset();
        final candidate = RecorderRecoveryCandidate(
            RecorderSavedIdentity(
                remoteId: '30000000-0000-0000-0000-000000000001',
                serialNumber: 'AB00000000000001',
                deviceName: 'Test recorder',
                protocol: RecorderProtocol.telink),
            systemConnected: !saved);
        final notifier = RecoveryNotifier(candidate, saved);
        final account = RecoveryWidgetAccount()..loggedIn = !saved;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() => FlutterBluePlus.adapterState.first);
        final boundary = GlobalKey();
        await tester.pumpWidget(ProviderScope(
            overrides: [deviceProvider.overrideWith((ref) => notifier)],
            child: RepaintBoundary(
                key: boundary,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: ThemeData(useMaterial3: true,
                    fontFamily: const bool.fromEnvironment('SUNMATE_CAPTURE_RECOVERY_UI') ? 'RecoveryFixture' : null,
                    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFF8C00), brightness: Brightness.light)),
                    home: Scaffold(
                        body: RecorderConnectionSheet(account: account))))));
        await tester.pumpAndSettle();
        if (!saved) {
          await tester.ensureVisible(find.text('选择并搜索'));
          await tester.tap(find.text('选择并搜索'));
          await tester.pumpAndSettle();
          expect(find.textContaining('系统已连接 · 等待身份验证'), findsOneWidget);
        } else {
          expect(find.text('本机已保存的录音卡'), findsOneWidget);
          expect(find.textContaining('本机密钥已保存 · 等待身份验证'), findsOneWidget);
        }
        expect(find.text('继续验证'), findsOneWidget);
        expect(notifier.connects, 0);
        expect(tester.takeException(), isNull);
        await capture(tester, boundary,
            '${size.width.toInt()}-${saved ? 'pending' : 'system'}');
        await tester.ensureVisible(find.text('继续验证'));
        await tester.tap(find.text('继续验证'));
        await tester.pumpAndSettle();
        expect(notifier.connects, 1);
        expect(notifier.selected, same(candidate));
        expect(find.textContaining('尚未收到本次身份验证成功回执'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(account.smsCalls, 0);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 300));
      });
    }
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/recorder_backup_files.dart';
import 'package:sunmate_app/core/ble/recorder_portable_backup.dart';
import 'package:sunmate_app/providers/device_provider.dart';
import 'package:sunmate_app/views/recorder_backup_page.dart';
import 'recorder_management_widget_test.dart'
    show ManagementNotifier, captureUi;
import 'recorder_portable_backup_test.dart'
    show material, identity, password, sn;
import 'recorder_recovery_test.dart' show DeviceKeyStore;
import 'recorder_authentication_test.dart' show shared;
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_portable_backup_test.dart' show advertisement;
import 'dart:convert';
import 'dart:ui' as ui;

class FakeBackupFiles extends RecorderBackupFiles {
  int saves = 0;
  int picks = 0;
  bool cancelled = false;
  bool failPick = false;
  @override
  Future<bool> save(Uint8List bytes) async {
    saves++;
    return !cancelled;
  }

  @override
  Future<Uint8List?> pick() async {
    picks++;
    if (failPick) throw PlatformException(code: 'read-failure');
    return cancelled ? null : Uint8List.fromList([1, 2, 3]);
  }
}

// Widget只测试交互；实际600000轮加密及篡改失败另有真实codec回归。
class WidgetBackupCodec extends RecorderBackupCodec {
  bool rejected = false;
  int exports = 0;
  @override
  Future<Uint8List> encrypt(
      PortableRecorderMaterial value, String password) async {
    RecorderBackupCodec.validatePassword(password);
    exports++;
    return Uint8List.fromList([7, 8, 9]);
  }

  @override
  Future<PortableRecorderMaterial> decrypt(
      Uint8List bytes, String password) async {
    if (rejected) throw const FormatException('无法打开备份：密码错误、文件损坏或格式不支持');
    return material();
  }
}

class BackupNotifier extends ManagementNotifier {
  final RecorderBackupService service;
  BackupNotifier(this.service) : super(ready: false);
  @override
  RecorderBackupService get recorderBackup => service;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RecorderBackupService service;
  late WidgetBackupCodec codec;
  late FakeBackupFiles files;
  final platform = TestBlePlatform();
  // 对话框打开时后台有忙碌指示，使用有界帧推进，不等待动画永久静止。
  Future<void> advance(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  setUpAll(() async {
    FlutterBluePlusPlatform.instance = platform;
    if (captureUi) {
      for (final item in {
        'BackupFixture': '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
        'MaterialIcons':
            '/private/tmp/sunmate-flutter-sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(item.key)
              ..addFont(File(item.value)
                  .readAsBytes()
                  .then((b) => b.buffer.asByteData())))
            .load();
      }
    }
  });
  setUp(() {
    platform.reset();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  void initialize() {
    codec = WidgetBackupCodec();
    files = FakeBackupFiles();
    service = RecorderBackupService(keys: DeviceKeyStore(), codec: codec);
  }

  Future<void> show(WidgetTester tester, {GlobalKey? boundary}) async {
    if (tester.view.physicalSize.width != 360 &&
        tester.view.physicalSize.width != 390) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(ProviderScope(
        overrides: [
          deviceProvider.overrideWith((ref) => BackupNotifier(service))
        ],
        child: RepaintBoundary(
            key: boundary,
            child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: ThemeData(
                    useMaterial3: true,
                    fontFamily: captureUi ? 'BackupFixture' : null,
                    colorScheme: ColorScheme.fromSeed(
                        seedColor: const Color(0xFFFF8C00))),
                home: RecorderBackupPage(files: files)))));
    await advance(tester);
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    if (!captureUi) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final dir = Directory(
          '/Users/m/Documents/VS/sunmate/build_output/recorder-backup-local');
      await dir.create(recursive: true);
      await File('${dir.path}/$name.png')
          .writeAsBytes(bytes.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> openImport(WidgetTester tester) async {
    await tester.ensureVisible(find.text('选择加密备份文件'));
    await tester.tap(find.text('选择加密备份文件'));
    await advance(tester);
  }

  Future<void> enterImportPassword(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).first, password);
    await tester.tap(find.text('解密'));
    await advance(tester);
  }

  for (final size in [const Size(360, 640), const Size(390, 844)]) {
    testWidgets('backup empty and imported page at $size; import stays pending',
        (tester) async {
      initialize();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      await show(tester, boundary: key);
      expect(find.textContaining('尚无已验证卡片'), findsOneWidget);
      final export = tester.widget<FilledButton>(find
          .ancestor(
              of: find.text('设置密码并导出'),
              matching: find.byWidgetPredicate((w) => w is FilledButton))
          .first);
      expect(export.onPressed, isNull);
      await capture(tester, key, '${size.width.toInt()}-empty');
      await openImport(tester);
      await enterImportPassword(tester);
      expect(find.text('确认导入录音卡备份'), findsOneWidget);
      expect(await service.imported.readAll(), isEmpty);
      await tester.tap(find.text('确认导入'));
      await advance(tester);
      final stored = await service.imported.readAll();
      expect(stored.single.serialNumber, sn);
      stored.single.clear();
      expect(await service.identities.readAll(), isEmpty);
      expect((service.keys as DeviceKeyStore).writes, 0);
      await tester.scrollUntilVisible(find.text('Test recorder'), 160);
      await advance(tester);
      await capture(tester, key, '${size.width.toInt()}-imported');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'export requires password confirmation and handles save cancellation',
      (tester) async {
    initialize();
    await service.identities.save(identity());
    (service.keys as DeviceKeyStore).values['old-phone/telink'] =
        base64Encode(shared);
    final key = GlobalKey();
    await show(tester, boundary: key);
    await capture(tester, key, 'export-ready');
    await tester.tap(find.text('设置密码并导出'));
    await advance(tester);
    await capture(tester, key, 'export-password');
    await tester.enterText(find.byType(TextFormField).first, password);
    await tester.enterText(find.byType(TextFormField).last, 'mismatch');
    await tester.tap(find.text('加密备份'));
    await advance(tester);
    expect(find.text('两次密码不一致'), findsOneWidget);
    expect(files.saves, 0);
    await tester.enterText(find.byType(TextFormField).last, password);
    files.cancelled = true;
    await tester.tap(find.text('加密备份'));
    await advance(tester);
    expect(files.saves, 1);
    expect(codec.exports, 1);
    expect(find.text('已取消保存'), findsOneWidget);
    await tester.tap(find.text('设置密码并导出'));
    await advance(tester);
    await tester.tap(find.text('取消'));
    await advance(tester);
    expect(find.text('已取消导出'), findsOneWidget);
    expect(files.saves, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('import cancellation and wrong password do not save anything',
      (tester) async {
    initialize();
    files.cancelled = true;
    final key = GlobalKey();
    await show(tester, boundary: key);
    await openImport(tester);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.text('已取消导入，未保存备份资料'), findsOneWidget);
    files.cancelled = false;
    codec.rejected = true;
    await openImport(tester);
    await enterImportPassword(tester);
    expect(find.text('无法打开备份：密码错误、文件损坏或格式不支持'), findsOneWidget);
    expect(await service.imported.readAll(), isEmpty);
    expect(await service.identities.readAll(), isEmpty);
    codec.rejected = false;
    await openImport(tester);
    await tester.tap(find.text('取消'));
    await advance(tester);
    expect(find.text('已取消导入，未保存备份资料'), findsOneWidget);
    await openImport(tester);
    await enterImportPassword(tester);
    expect(find.text('确认导入录音卡备份'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await advance(tester);
    expect(find.text('已取消导入，未保存备份资料'), findsOneWidget);
    expect(await service.imported.readAll(), isEmpty);
    await capture(tester, key, 'import-cancelled');
    expect(tester.takeException(), isNull);
  });

  testWidgets('native picker failure has safe feedback and can be retried',
      (tester) async {
    initialize();
    files.failPick = true;
    await show(tester);
    await openImport(tester);
    expect(find.text('操作未完成，请重试；现有绑定与密钥保持'), findsOneWidget);
    expect(find.textContaining('read-failure'), findsNothing);
    files.failPick = false;
    await openImport(tester);
    expect(find.text('输入备份密码'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await advance(tester);
    expect(find.text('已取消导入，未保存备份资料'), findsOneWidget);
    expect(await service.imported.readAll(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'persisted import opens independent SN scan without official login',
      (tester) async {
    initialize();
    final imported = material();
    await service.acceptImport(imported);
    imported.clear();
    final key = GlobalKey();
    await show(tester, boundary: key);
    await tester.scrollUntilVisible(find.text('Test recorder'), 160);
    await advance(tester);
    await tester.tap(find.text('Test recorder'));
    await advance(tester);
    expect(find.text('连接备份中的录音卡'), findsOneWidget);
    expect(find.textContaining('连续点击5次'), findsOneWidget);
    expect(find.text('连接验证'), findsNothing);
    final device =
        BluetoothDevice.fromId('30000000-0000-0000-0000-000000000001');
    await platform.advertise(device.remoteId, advertisement());
    await advance(tester);
    expect(find.text('连接验证'), findsOneWidget);
    await capture(tester, key, 'offline-scan');
    expect((service.keys as DeviceKeyStore).writes, 0);
    expect(await service.identities.readAll(), isEmpty);
    await tester.pageBack();
    await advance(tester);
    expect(find.text('本机密钥与恢复'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await FlutterBluePlus.stopScan();
  });
}

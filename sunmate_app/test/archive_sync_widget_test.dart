import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/sync/archive_sync.dart';
import 'package:sunmate_app/providers/archive_sync_provider.dart';
import 'package:sunmate_app/views/archive_sync_page.dart';
import 'recording_processing_test.dart' show MemoryContent;
import 'archive_sync_test.dart' show SyncSecure, SyncRemote, source;
import 'recorder_management_widget_test.dart' show captureUi, screenshot;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (captureUi) {
      await (FontLoader('ArchiveFixture')
            ..addFont(
                File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf')
                    .readAsBytes()
                    .then((v) => v.buffer.asByteData())))
          .load();
      await (FontLoader('MaterialIcons')
            ..addFont(File(
                    '/private/tmp/sunmate-flutter-sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
                .readAsBytes()
                .then((v) => v.buffer.asByteData())))
          .load();
    }
  });
  for (final dark in [false, true]) {
    testWidgets(
        'sync switches, counters, history and receipt visibility (${dark ? 'dark' : 'light'})',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final remote = SyncRemote(),
          secure = SyncSecure(),
          rows = [source('old')];
      final sync = ArchiveSyncController(
          store: MemoryContent(),
          secure: secure,
          sources: () async => rows,
          transport: (_, __) => remote);
      await sync.ready;
      await sync.pair('http://127.0.0.1/sunmate/v1', 'synthetic-token',
          SyncRemote.identity);
      final boundary = GlobalKey();
      await tester.pumpWidget(ProviderScope(
          overrides: [archiveSyncProvider.overrideWith((ref) => sync)],
          child: MaterialApp(
              theme: ThemeData(
                  useMaterial3: true,
                  fontFamily: captureUi ? 'ArchiveFixture' : null,
                  brightness: dark ? Brightness.dark : Brightness.light,
                  colorSchemeSeed: Colors.orange),
              home: RepaintBoundary(
                  key: boundary, child: const ArchiveSyncPage()))));
      await tester.pumpAndSettle();
      expect(find.text('私有资料同步'), findsOneWidget);
      await tester.pumpAndSettle();
      await screenshot(tester, boundary,
          'archive-sync-${dark ? 'dark' : 'light'}-connection');
      final switches = find.byType(SwitchListTile);
      await tester.scrollUntilVisible(switches.at(0), 250,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await screenshot(
          tester, boundary, 'archive-sync-${dark ? 'dark' : 'light'}-switches');
      expect(tester.widget<SwitchListTile>(switches.at(0)).value, false);
      await tester.tap(switches.at(0));
      await tester.pumpAndSettle();
      expect(sync.config.automatic, {'meeting'});
      expect(remote.bodies, isEmpty);
      rows.add(source('new', category: 'meeting'));
      await sync.refresh();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('归档状态'), 250,
          scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('服务器已确认 1 个版本'), findsOneWidget);
      await tester.pumpAndSettle();
      await screenshot(
          tester, boundary, 'archive-sync-${dark ? 'dark' : 'light'}-status');
      await tester.scrollUntilVisible(find.text('最近回执'), 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await screenshot(
          tester, boundary, 'archive-sync-${dark ? 'dark' : 'light'}-receipts');
      expect(find.text('已确认'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
      'unpaired state disables automatic upload and shows safe connection errors',
      (tester) async {
    final sync = ArchiveSyncController(
        store: MemoryContent(), secure: SyncSecure(), sources: () async => []);
    await sync.ready;
    await tester.pumpWidget(ProviderScope(
        overrides: [archiveSyncProvider.overrideWith((ref) => sync)],
        child: const MaterialApp(home: ArchiveSyncPage())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对并保存连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('独立同步凭据。'), findsOneWidget);
    expect(sync.config.paired, false);
    await tester.pumpWidget(const SizedBox());
  });
}

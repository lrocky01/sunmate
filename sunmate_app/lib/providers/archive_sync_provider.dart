import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/notifications/mobile_notification_manager.dart';
import '../core/sync/archive_projection.dart';
import '../core/sync/archive_sync.dart';
import '../core/sync/archive_models.dart';
import '../core/recordings/local_content_store.dart';
import 'recording_processing_provider.dart';

final archiveSyncProvider =
    ChangeNotifierProvider<ArchiveSyncController>((ref) {
  final store = ref.watch(recordingContentStoreProvider);
  final policy = MobileNotificationManager().appPolicy;
  late final ArchiveSyncController controller;
  controller = ArchiveSyncController(
      store: store,
      sourceGeneration: store is FileRecordingContentStore
          ? () => jsonEncode([
                store.sourceGeneration,
                policy.loaded,
                policy.enabled,
                policy.apps.where((v) => !v.enabled).map((v) => v.id).toList()
                  ..sort(),
              ])
          : null,
      sources: () async {
        await policy.ready;
        if (!policy.loaded) throw const FormatException('通知权限尚未安全读取');
        return projectArchive(store, policy.allows, serverTarget: jsonEncode(canonicalValue([controller.config.url, controller.config.identity])));
      });
  final timer = Timer.periodic(const Duration(seconds: 20), (_) {
    if (controller.foreground) unawaited(controller.refresh());
  });
  void changed() {
    unawaited(controller.refresh());
  }

  policy.addListener(changed);
  unawaited(controller.ready.then((_) => controller.refresh()));
  ref.onDispose(() {
    timer.cancel();
    policy.removeListener(changed);
  });
  return controller;
});

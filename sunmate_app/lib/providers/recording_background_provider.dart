import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/recordings/recording_background.dart';
import 'recording_processing_provider.dart';
import 'archive_sync_provider.dart';
import 'device_provider.dart';

final recordingWorkOwnershipProvider = Provider<RecordingWorkOwnership>(
    (ref) => RecordingWorkOwnership(ref.watch(recordingContentStoreProvider)));

final recordingBackgroundProvider =
    ChangeNotifierProvider<RecordingBackgroundController>((ref) {
  final processing = ref.watch(recordingProcessingProvider);
  final controller = RecordingBackgroundController(
      store: ref.watch(recordingContentStoreProvider),
      ownership: ref.watch(recordingWorkOwnershipProvider),
      archive: ref.watch(archiveSyncProvider),
      processing: processing,
      driver: ref.read(deviceFactoryProvider).bleDriver);
  // Foreground reconciliation is a convenience; daemon uploads and the server's
  // persisted worker are independent once the phone has submitted the files.
  final timer = Timer.periodic(const Duration(seconds: 20), (_) {
    if (controller.foreground && !controller.busy)
      unawaited(controller.refresh().catchError((Object _) {}));
  });
  void configurationChanged() {
    unawaited(
        controller.archiveConfigurationChanged().catchError((Object _) {}));
  }

  final archive = ref.read(archiveSyncProvider);
  archive.addListener(configurationChanged);
  ref.onDispose(() {
    timer.cancel();
    archive.removeListener(configurationChanged);
  });
  return controller;
});

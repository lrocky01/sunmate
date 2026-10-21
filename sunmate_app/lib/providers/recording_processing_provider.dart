import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/audio/recorder_local_audio.dart';
import '../core/hardware/recorder_long_file_store.dart';
import '../core/notifications/mobile_notification_manager.dart';
import '../core/recordings/local_content_store.dart';
import '../core/recordings/recording_processing_controller.dart';
import 'device_provider.dart';
import 'server_config_provider.dart';
import 'archive_sync_provider.dart';
import 'recording_background_provider.dart';

final recordingContentStoreProvider =
    Provider<RecordingContentStore>((ref) => FileRecordingContentStore());
final recordingAudioStoreProvider =
    Provider<RecorderLongFileStore>((ref) => RecorderLongFileStore());
final recordingLocalAudioProvider =
    Provider<RecorderLocalAudio>((ref) => MethodChannelRecorderLocalAudio());
final recordingProcessingProvider =
    ChangeNotifierProvider<RecordingProcessingController>((ref) {
  final manager = MobileNotificationManager();
  final ownership = ref.watch(recordingWorkOwnershipProvider);
  final controller = RecordingProcessingController(
      content: ref.watch(recordingContentStoreProvider),
      audioStore: ref.watch(recordingAudioStoreProvider),
      audio: ref.watch(recordingLocalAudioProvider),
      asr: () => ref.read(asrServiceProvider),
      agent: () => ref.read(agentClientProvider),
      archive: ref.read(archiveSyncProvider),
      serverOwnedAsr: (id) => !ownership.loaded || ownership.serverAsr(id),
      allowsNotification: manager.appPolicy.allows);
  final signals =
      ref.read(deviceFactoryProvider).bleDriver.segmentSignals.listen((signal) {
    unawaited(() async {
      await ownership.capture(signal);
      await controller.accept(signal);
    }().catchError((Object _) {
      controller.message = '本次录音的处理归属尚未保存，保留原音频，未启动自动转写。';
    }));
  });
  final notifications = manager.notificationStream.listen((entry) {
    unawaited(controller.addTimelineEntry(entry).catchError((Object _) {
      controller.message = '通知尚未安全保存，请检查本机结果库。';
      controller.notificationPolicyChanged();
    }));
  });
  String policyState() {
    final disabled = manager.appPolicy.apps
        .where((a) => !a.enabled)
        .map((a) => a.id)
        .toList()
      ..sort();
    return jsonEncode(
        [manager.appPolicy.loaded, manager.appPolicy.enabled, disabled]);
  }

  var lastPolicy = policyState();
  void policyChanged() {
    final next = policyState();
    if (next != lastPolicy) {
      lastPolicy = next;
      controller.notificationPolicyChanged();
    }
  }

  manager.appPolicy.addListener(policyChanged);
  unawaited(controller.ready.then((_) async {
    await controller.importExisting();
    await controller.resume();
  }).catchError((Object _) {
    controller.message = "本机处理恢复未完成，已有内容保留。";
    controller.notificationPolicyChanged();
  }));
  ref.onDispose(() {
    unawaited(signals.cancel());
    unawaited(notifications.cancel());
    manager.appPolicy.removeListener(policyChanged);
  });
  return controller;
});

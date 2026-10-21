import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/recording_processing_provider.dart';
import '../providers/archive_sync_provider.dart';
import '../providers/recording_background_provider.dart';
import 'dart:async';

class RecordingProcessingLifecycle extends ConsumerStatefulWidget {
  final Widget child;
  const RecordingProcessingLifecycle({super.key, required this.child});
  @override
  ConsumerState<RecordingProcessingLifecycle> createState() =>
      _RecordingProcessingLifecycleState();
}

class _RecordingProcessingLifecycleState
    extends ConsumerState<RecordingProcessingLifecycle>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && state != AppLifecycleState.paused) return;
    ref.read(archiveSyncProvider).setForeground(state == AppLifecycleState.resumed);
    final processing = ref.read(recordingProcessingProvider);
    if (state == AppLifecycleState.paused) processing.setForeground(false);
    unawaited(ref.read(recordingBackgroundProvider).setForeground(state == AppLifecycleState.resumed).then((_) {
      if (mounted && state == AppLifecycleState.resumed && WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) processing.setForeground(true);
    }));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(archiveSyncProvider);
    ref.watch(recordingProcessingProvider);
    ref.watch(recordingBackgroundProvider);
    return widget.child;
  }
}

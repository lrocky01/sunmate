import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/recording_processing_provider.dart';
import '../providers/archive_sync_provider.dart';

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
    ref.read(archiveSyncProvider).setForeground(state == AppLifecycleState.resumed);
    ref
        .read(recordingProcessingProvider)
        .setForeground(state == AppLifecycleState.resumed);
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
    return widget.child;
  }
}

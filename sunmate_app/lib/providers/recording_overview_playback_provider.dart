import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/audio/recording_overview_playback.dart';
import 'recording_processing_provider.dart';

final recordingOverviewPlaybackProvider =
    ChangeNotifierProvider.autoDispose<RecordingOverviewPlayback>((ref) =>
        RecordingOverviewPlayback(
            store: ref.watch(recordingAudioStoreProvider),
            audio: ref.watch(recordingLocalAudioProvider)));

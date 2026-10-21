import 'dart:async';
import 'package:flutter/foundation.dart';
import '../hardware/recorder_long_file_models.dart';
import '../hardware/recorder_long_file_store.dart';
import '../hardware/recorder_long_recordings.dart';
import '../recordings/recording_processing_controller.dart';
import '../recordings/recording_processing_models.dart';
import 'recorder_local_audio.dart';

/// 两种用途共用一个本机播放器；播放前沿用归档/分段的校验，不依赖BLE连接。
class RecordingOverviewPlayback extends ChangeNotifier {
  final RecorderLongFileStore store;
  final RecorderLocalAudio audio;
  RecordingOverviewPlayback({required this.store, required this.audio});
  String? selected, relativePath, error;
  bool busy = false, disposed = false;
  RecorderAudioPlaybackState playback = const RecorderAudioPlaybackState();
  Timer? _timer;
  bool _reading = false;
  static String meetingKey(String sn, int session) => 'meeting:$sn:$session';
  bool playing(String id) => selected == id && playback.isPlaying;
  void _changed() {
    if (!disposed) notifyListeners();
  }

  Future<void> playMeeting(RecorderLongAudioRecord selectedRecord) =>
      _play(meetingKey(selectedRecord.serialNumber, selectedRecord.sessionId),
          () async {
        final matches = (await store.loadRecords()).where((r) =>
            r.serialNumber == selectedRecord.serialNumber &&
            r.sessionId == selectedRecord.sessionId &&
            r.purpose == LongRecordingPurpose.meeting &&
            r.inventoryFingerprint == selectedRecord.inventoryFingerprint &&
            r.relativePlayablePath == selectedRecord.relativePlayablePath &&
            r.relativeOggPath == selectedRecord.relativeOggPath);
        if (matches.length != 1 ||
            !matches.single.canPlay ||
            matches.single.relativeOggPath == null)
          throw const FormatException();
        final record = matches.single;
        final prepared = await audio.prepare(record.relativeOggPath!);
        if (prepared.relativePath != record.relativePlayablePath ||
            prepared.durationMs != record.durationMs)
          throw const FormatException();
        final file = await store.resolveRelative(prepared.relativePath);
        if (!await file.exists() || await file.length() <= 44)
          throw const FormatException();
        return prepared;
      });

  Future<void> playSegment(
          RecordingProcessingController controller, ProcessingPart part) =>
      _play(part.id, () => controller.preparePlayback(part));

  Future<void> _play(
      String key, Future<PreparedRecorderAudio> Function() prepare) async {
    if (busy || disposed) return;
    if (playing(key)) {
      await stop();
      return;
    }
    busy = true;
    error = null;
    selected = key;
    _timer?.cancel();
    playback = const RecorderAudioPlaybackState();
    _changed();
    try {
      await _stopOwned();
      relativePath = null;
      final prepared = await prepare();
      if (disposed) return;
      relativePath = prepared.relativePath;
      await audio.play(prepared.relativePath); // 原生端再次核验WAV及来源证明。
      if (disposed) {
        await _stopOwned();
        return;
      }
      await _read();
      if (error == null && playback.isPlaying) {
        _timer = Timer.periodic(
            const Duration(milliseconds: 500), (_) => unawaited(_read()));
      }
    } catch (_) {
      error = '本机录音播放失败，请检查音频保存状态后重试。';
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> _read() async {
    if (_reading || disposed) return;
    _reading = true;
    try {
      final next = await audio.state();
      if (disposed) return;
      playback = next.relativePath == relativePath
          ? next
          : const RecorderAudioPlaybackState();
      if (!playback.isPlaying) _timer?.cancel();
    } catch (_) {
      _timer?.cancel();
      playback = const RecorderAudioPlaybackState();
      error = '无法确认播放状态，请重试。';
    } finally {
      _reading = false;
      _changed();
    }
  }

  Future<void> _stopOwned() async {
    final state = await audio.state();
    if (relativePath != null && state.relativePath == relativePath)
      await audio.stop();
  }

  Future<void> stop() async {
    if (busy || disposed) return;
    busy = true;
    _timer?.cancel();
    _changed();
    try {
      await _stopOwned();
      playback = const RecorderAudioPlaybackState();
    } catch (_) {
      error = '停止播放未完成，请重试。';
    } finally {
      busy = false;
      _changed();
    }
  }

  @override
  void dispose() {
    disposed = true;
    _timer?.cancel();
    unawaited(_stopOwned().catchError((Object _) {}));
    super.dispose();
  }
}

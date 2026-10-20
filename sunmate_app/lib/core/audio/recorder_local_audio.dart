import 'dart:io';

import 'package:flutter/services.dart';

/// Only paths below ApplicationSupport/recorder_long_audio_v1 are accepted.
class PreparedRecorderAudio {
  final String relativePath;
  final int durationMs;
  final int sampleRate;
  final int frames;

  const PreparedRecorderAudio({
    required this.relativePath,
    required this.durationMs,
    required this.sampleRate,
    required this.frames,
  });

  factory PreparedRecorderAudio.fromMap(Map<Object?, Object?> value) {
    final path = value['relativePath'];
    final duration = value['durationMs'];
    final rate = value['sampleRate'];
    final frames = value['frames'];
    if (path is! String ||
        !_safeRecordingPath(path, '.wav') ||
        duration is! int ||
        duration <= 0 ||
        rate is! int ||
        rate != 16000 ||
        frames is! int ||
        frames <= 0 ||
        duration != frames * 1000 ~/ rate) {
      throw const FormatException('本地录音解码结果无效');
    }
    return PreparedRecorderAudio(
      relativePath: path,
      durationMs: duration,
      sampleRate: rate,
      frames: frames,
    );
  }
}

class RecorderAudioPlaybackState {
  final bool isPlaying;
  final int positionMs;
  final int durationMs;
  final String? relativePath;

  const RecorderAudioPlaybackState({
    this.isPlaying = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.relativePath,
  });

  factory RecorderAudioPlaybackState.fromMap(Map<Object?, Object?> value) {
    final path = value['relativePath'];
    final position = value['positionMs'];
    final duration = value['durationMs'];
    if (value['isPlaying'] is! bool ||
        position is! int ||
        position < 0 ||
        duration is! int ||
        duration < 0 ||
        (path != null &&
            (path is! String || !_safeRecordingPath(path, '.wav')))) {
      throw const FormatException('本地播放状态无效');
    }
    return RecorderAudioPlaybackState(
      isPlaying: value['isPlaying'] as bool,
      positionMs: position,
      durationMs: duration,
      relativePath: path as String?,
    );
  }
}

abstract interface class RecorderLocalAudio {
  Future<PreparedRecorderAudio> prepare(String relativeOggPath);
  Future<void> play(String relativePlayablePath);
  Future<void> pause();
  Future<void> stop();
  Future<RecorderAudioPlaybackState> state();
}

/// Uses the device's Opus decoder; no audio or credentials leave the phone.
class MethodChannelRecorderLocalAudio implements RecorderLocalAudio {
  static const channel = MethodChannel('sunmate/recorder_local_audio');
  final bool Function() _isSupported;
  final MethodChannel _channel;

  MethodChannelRecorderLocalAudio({
    MethodChannel? methodChannel,
    bool Function()? isSupported,
  })  : _channel = methodChannel ?? channel,
        _isSupported = isSupported ?? (() => Platform.isIOS);

  void _checkSupported() {
    if (!_isSupported()) {
      throw UnsupportedError('当前平台尚未接入本地会议录音解码与播放');
    }
  }

  @override
  Future<PreparedRecorderAudio> prepare(String relativeOggPath) async {
    _checkSupported();
    if (!_safeRecordingPath(relativeOggPath, '.ogg')) {
      throw const FormatException('录音必须位于本机长录目录');
    }
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'prepare',
      {'relativePath': relativeOggPath},
    );
    if (value == null) throw const FormatException('本地录音解码未返回结果');
    return PreparedRecorderAudio.fromMap(value);
  }

  @override
  Future<void> play(String relativePlayablePath) async {
    _checkSupported();
    if (!_safeRecordingPath(relativePlayablePath, '.wav')) {
      throw const FormatException('播放文件必须位于本机长录目录');
    }
    await _channel
        .invokeMethod<void>('play', {'relativePath': relativePlayablePath});
  }

  @override
  Future<void> pause() async {
    _checkSupported();
    await _channel.invokeMethod<void>('pause');
  }

  @override
  Future<void> stop() async {
    _checkSupported();
    await _channel.invokeMethod<void>('stop');
  }

  @override
  Future<RecorderAudioPlaybackState> state() async {
    _checkSupported();
    final value = await _channel.invokeMapMethod<Object?, Object?>('state');
    if (value == null) throw const FormatException('未取得本地播放状态');
    return RecorderAudioPlaybackState.fromMap(value);
  }
}

bool _safeRecordingPath(String path, String extension) {
  final parts = path.split('/');
  return parts.length >= 3 &&
      parts.first == 'recorder_long_audio_v1' &&
      parts.every((p) =>
          RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(p) && p != '.' && p != '..') &&
      path.endsWith(extension);
}

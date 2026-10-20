import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/audio/recorder_local_audio.dart';
import '../core/hardware/ainote_6095_driver.dart';
import '../core/hardware/recorder_long_file_models.dart';
import '../providers/device_provider.dart';

/// 卡片长录与本机归档共用一个列表；未完成校验的文件不能播放。
class RecorderLongFilesPage extends ConsumerStatefulWidget {
  final AiNote6095Driver? driver;
  final RecorderLocalAudio? audio;
  const RecorderLongFilesPage({super.key, this.driver, this.audio});

  @override
  ConsumerState<RecorderLongFilesPage> createState() =>
      _RecorderLongFilesState();
}

class _RecorderLongFilesState extends ConsumerState<RecorderLongFilesPage> {
  late final AiNote6095Driver _driver;
  late final RecorderLocalAudio _audio;
  StreamSubscription<void>? _changes;
  Timer? _playbackTimer;
  RecorderAudioPlaybackState _playback = const RecorderAudioPlaybackState();
  bool _audioBusy = false;
  bool _readingPlayback = false;
  bool _loading = true;
  String? _error;

  bool get _fileChannelReady =>
      _driver.isConnected &&
      !_driver.longFileLibrary.needsReconnect &&
      !_driver.longFileLibrary.busy;

  bool get _isIdle =>
      _driver.hardwareSettings.recording == false && !_driver.isRecording;

  bool get _isLongRecording =>
      _driver.longFileLibrary.activeSessionId != null &&
      (_driver.isRecording || _driver.hardwareSettings.recording == true);

  bool get _canReadDirectory =>
      _fileChannelReady && (_isIdle || _isLongRecording);

  bool _canSave(RecorderLongAudioRecord record) =>
      _fileChannelReady &&
      record.serialNumber == _driver.snNumber &&
      ((_isIdle && _driver.longFileLibrary.activeSessionId == null) ||
          (_isLongRecording &&
              record.sessionId == _driver.longFileLibrary.activeSessionId));

  @override
  void initState() {
    super.initState();
    _driver = widget.driver ?? ref.read(deviceFactoryProvider).bleDriver;
    _audio = widget.audio ?? MethodChannelRecorderLocalAudio();
    _changes = _driver.stateChanges.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(_loadLocal());
  }

  Future<void> _loadLocal() async {
    try {
      await _driver.reloadLocalLongFiles();
    } catch (_) {
      if (mounted) _error = '本机录音资料读取失败，请重新打开此页重试。';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    if (!_canReadDirectory) return;
    setState(() => _error = null);
    try {
      final ok = await _driver.refreshLongFiles();
      if (!ok && mounted && _driver.longFileLibrary.message == null) {
        setState(() => _error = '未读到卡片目录，请确认连接后重试。');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '卡片目录读取失败，请确认连接后重试。');
    }
  }

  Future<void> _sync(RecorderLongAudioRecord record) async {
    if (!_canSave(record)) return;
    setState(() => _error = null);
    try {
      final ok = await _driver.syncLongRecording(record.sessionId);
      if (!ok && mounted && _driver.longFileLibrary.message == null) {
        setState(() => _error = '录音保存未完成，重新连接后可继续恢复。');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '录音保存未完成，已保存的分段会保留。');
    }
  }

  Future<void> _readPlayback() async {
    if (_readingPlayback || !mounted) return;
    _readingPlayback = true;
    try {
      final state = await _audio.state();
      if (!mounted) return;
      setState(() => _playback = state);
      if (!state.isPlaying) {
        _playbackTimer?.cancel();
        _playbackTimer = null;
      }
    } catch (_) {
      _playbackTimer?.cancel();
      _playbackTimer = null;
      if (mounted) {
        setState(() {
          _playback = const RecorderAudioPlaybackState();
          _error = '无法确认播放状态，请重试播放。';
        });
      }
    } finally {
      _readingPlayback = false;
    }
  }

  Future<void> _play(RecorderLongAudioRecord record) async {
    if (_audioBusy || !record.canPlay) return;
    setState(() {
      _audioBusy = true;
      _error = null;
    });
    try {
      await _audio.play(record.relativePlayablePath!);
      await _readPlayback();
      if (mounted && _playback.isPlaying) {
        _playbackTimer?.cancel();
        _playbackTimer = Timer.periodic(const Duration(milliseconds: 500),
            (_) => unawaited(_readPlayback()));
      }
    } catch (_) {
      if (mounted) setState(() => _error = '本机音频播放失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  Future<void> _stop() async {
    if (_audioBusy) return;
    setState(() => _audioBusy = true);
    try {
      await _audio.stop();
      await _readPlayback();
    } catch (_) {
      if (mounted) setState(() => _error = '停止播放未完成，请重试。');
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    _playbackTimer?.cancel();
    // 页面退出即释放本次播放；不会修改卡片或本机音频文件。
    unawaited(_audio.stop().catchError((Object _) {}));
    super.dispose();
  }

  String _duration(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  String _bytes(int count) => count >= 1024 * 1024
      ? '${(count / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(count / 1024).toStringAsFixed(1)} KB';

  @override
  Widget build(BuildContext context) {
    final library = _driver.longFileLibrary;
    final scheme = Theme.of(context).colorScheme;
    final connectionHint = !_driver.isConnected
        ? '未连接卡片。手机上已保存的录音仍可播放；连接并完成身份验证后可读取卡片目录。'
        : _isLongRecording
            ? '正在长录，自动保存已关闭分段；当前写入段等待关闭，停止后确认完整归档。'
            : _driver.isRecording || _driver.hardwareSettings.recording == true
                ? '卡片正在录音，请结束后再读取目录或保存音频。'
                : _driver.hardwareSettings.recording == null
                    ? '卡片录音状态尚未确认，请先在录音设置中读取卡片状态。'
                    : '已连接卡片。保存会保留卡片原始录音，断连后可继续恢复。';
    return Scaffold(
      appBar: AppBar(title: const Text('长录文件与播放')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Text(connectionHint, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: !_loading && _canReadDirectory ? _refresh : null,
                icon: const Icon(Icons.refresh),
                label: const Text('读取卡片目录'),
              ),
            ),
            if (_loading || library.busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(semanticsLabel: '正在读取或保存长录文件'),
            ],
            if (library.message != null || _error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(_error ?? library.message!,
                      style: TextStyle(
                          color: _error != null || library.failed
                              ? scheme.error
                              : scheme.onSurfaceVariant)),
                ),
              ),
            const SizedBox(height: 24),
            Text('录音文件', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (!_loading && library.recordings.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(library.loaded
                    ? '暂无录音文件。可读取卡片目录查看最新分段。'
                    : '尚未读取到录音文件。已保存的音频会显示在这里。'),
              ),
            for (final record in library.recordings) ...[
              _recordRow(record),
              const Divider(height: 24),
            ],
            const SizedBox(height: 12),
            Text('音频校验完整并保存到手机后才可播放。此处不进行转写或智能体同步。',
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _recordRow(RecorderLongAudioRecord record) {
    final playing = _playback.isPlaying &&
        _playback.relativePath == record.relativePlayablePath;
    final activeLong = record.stage == RecorderLongFileStage.recording ||
        record.sessionId == _driver.longFileLibrary.activeSessionId;
    final remaining = activeLong
        ? '已保存 ${record.downloadedParts} 个已关闭分段'
        : record.totalParts > 0
            ? '${record.downloadedParts}/${record.totalParts} 段'
            : '${record.downloadedParts} 段';
    final progress = record.sourceBytes > 0
        ? (record.receivedBytes / record.sourceBytes).clamp(0.0, 1.0)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${record.purposeLabel} · ${record.sessionId}',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(record.stageLabel),
        const SizedBox(height: 4),
        Text('录音卡 ${record.serialNumber}',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text(
            '$remaining · ${_bytes(record.receivedBytes)} / ${_bytes(record.sourceBytes)}',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        if (record.stage == RecorderLongFileStage.downloading) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(value: progress, semanticsLabel: '录音分段保存进度'),
        ],
        if (record.message != null) ...[
          const SizedBox(height: 8),
          Text(record.message!),
        ],
        if (record.canPlay) ...[
          const SizedBox(height: 8),
          Text(playing
              ? '正在播放 ${_duration(_playback.positionMs)} / ${_duration(_playback.durationMs)}'
              : '时长 ${_duration(record.durationMs ?? 0)}'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: _audioBusy
                ? null
                : playing
                    ? _stop
                    : () => _play(record),
            icon: Icon(playing ? Icons.stop : Icons.play_arrow),
            label: Text(playing ? '停止播放' : '播放本机录音'),
          ),
        ] else ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: _canSave(record) ? () => _sync(record) : null,
            icon: const Icon(Icons.download_outlined),
            label: Text(activeLong
                ? '同步已关闭分段'
                : record.downloadedParts > 0
                    ? '继续恢复并保存'
                    : '保存到手机'),
          ),
        ],
      ],
    );
  }
}

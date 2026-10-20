import 'recorder_long_recordings.dart';

enum RecorderLongFileStage {
  discovered,
  recording,
  downloading,
  waitingForTail,
  preparing,
  saved,
  incomplete
}

class RecorderLongFileEntry {
  final int sessionId;
  final int part;
  final int size;
  final String? _remoteName;
  const RecorderLongFileEntry(this.sessionId, this.part, this.size,
      {String? remoteName})
      : _remoteName = remoteName;
  String get remoteName => _remoteName ?? 'longops_s${sessionId}_p$part.ops';
  String get signature {
    final canonical = 'longops_s${sessionId}_p$part.ops';
    // 保持既有归档指纹；固件的零填充文件名仍参与目录变更检查。
    return '$sessionId:$part:$size${remoteName == canonical ? '' : ':$remoteName'}';
  }
}

class RecorderCommittedSegment {
  final int part;
  final int size;
  final String sha256;
  final String relativePath;
  const RecorderCommittedSegment(
      {required this.part,
      required this.size,
      required this.sha256,
      required this.relativePath});
}

class RecorderOggAudio {
  final String relativePath;
  final int packetCount;
  final int durationMs;
  const RecorderOggAudio(this.relativePath, this.packetCount, this.durationMs);
}

/// 这里只记录本地音频归档，不含账号、密钥或远程URL。
class RecorderLongAudioRecord {
  final String serialNumber;
  final int sessionId;
  final LongRecordingPurpose? purpose;
  final RecorderLongFileStage stage;
  final int totalParts;
  final int downloadedParts;
  final int sourceBytes;
  final int receivedBytes;
  final String? relativeOggPath;
  final String? relativePlayablePath;
  final String? inventoryFingerprint;
  final int? durationMs;
  final DateTime? savedAt;
  final String? message;
  const RecorderLongAudioRecord(
      {required this.serialNumber,
      required this.sessionId,
      this.purpose,
      this.stage = RecorderLongFileStage.discovered,
      this.totalParts = 0,
      this.downloadedParts = 0,
      this.sourceBytes = 0,
      this.receivedBytes = 0,
      this.relativeOggPath,
      this.relativePlayablePath,
      this.inventoryFingerprint,
      this.durationMs,
      this.savedAt,
      this.message});
  bool get canPlay =>
      stage == RecorderLongFileStage.saved && relativePlayablePath != null;
  String get purposeLabel => purpose?.label ?? '用途未确认';
  String get stageLabel => switch (stage) {
        RecorderLongFileStage.discovered => '卡片录音，尚未保存',
        RecorderLongFileStage.recording => '录音中，已关闭分段持续保存',
        RecorderLongFileStage.downloading => '正在保存分段',
        RecorderLongFileStage.waitingForTail => '等待尾段确认',
        RecorderLongFileStage.preparing => '正在校验和准备播放',
        RecorderLongFileStage.saved => '已保存到手机',
        RecorderLongFileStage.incomplete => '保存未完成，可继续恢复',
      };
  RecorderLongAudioRecord copyWith(
          {LongRecordingPurpose? purpose,
          RecorderLongFileStage? stage,
          int? totalParts,
          int? downloadedParts,
          int? sourceBytes,
          int? receivedBytes,
          String? relativeOggPath,
          String? relativePlayablePath,
          String? inventoryFingerprint,
          int? durationMs,
          DateTime? savedAt,
          String? message}) =>
      RecorderLongAudioRecord(
          serialNumber: serialNumber,
          sessionId: sessionId,
          purpose: purpose ?? this.purpose,
          stage: stage ?? this.stage,
          totalParts: totalParts ?? this.totalParts,
          downloadedParts: downloadedParts ?? this.downloadedParts,
          sourceBytes: sourceBytes ?? this.sourceBytes,
          receivedBytes: receivedBytes ?? this.receivedBytes,
          relativeOggPath: relativeOggPath ?? this.relativeOggPath,
          relativePlayablePath:
              relativePlayablePath ?? this.relativePlayablePath,
          inventoryFingerprint:
              inventoryFingerprint ?? this.inventoryFingerprint,
          durationMs: durationMs ?? this.durationMs,
          savedAt: savedAt ?? this.savedAt,
          message: message);
}

class RecorderLongFileLibrary {
  final bool loaded;
  final bool busy;
  final bool failed;
  final bool needsReconnect;
  final String? message;
  final int? activeSessionId;
  final List<RecorderLongAudioRecord> recordings;
  const RecorderLongFileLibrary(
      {this.loaded = false,
      this.busy = false,
      this.failed = false,
      this.needsReconnect = false,
      this.message,
      this.activeSessionId,
      this.recordings = const []});
}

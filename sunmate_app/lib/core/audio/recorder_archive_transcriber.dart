import '../ai/asr_service.dart';
import '../hardware/recorder_long_file_models.dart';
import '../hardware/recorder_long_file_store.dart';
import 'recorder_local_audio.dart';

/// 仅由用户对某份完整归档点击转写时调用，不读取实时对讲缓存。
class RecorderArchiveTranscriber {
  final RecorderLongFileStore store;
  final RecorderLocalAudio audio;
  final AsrService asr;
  RecorderArchiveTranscriber(
      {required this.asr,
      RecorderLongFileStore? store,
      RecorderLocalAudio? audio})
      : store = store ?? RecorderLongFileStore(),
        audio = audio ?? MethodChannelRecorderLocalAudio();

  Future<AsrResult> transcribe(RecorderLongAudioRecord selected) async {
    final records = await store.loadRecords();
    final matches = records.where((r) =>
        r.serialNumber == selected.serialNumber &&
        r.sessionId == selected.sessionId &&
        r.purpose == selected.purpose &&
        r.inventoryFingerprint == selected.inventoryFingerprint &&
        r.relativeOggPath == selected.relativeOggPath &&
        r.relativePlayablePath == selected.relativePlayablePath);
    if (matches.length != 1 ||
        !matches.single.canPlay ||
        matches.single.relativeOggPath == null ||
        selected.purpose == null) {
      throw const FormatException('请先完整保存并确认这份录音的用途。');
    }
    final record = matches.single;
    // 复用本机解码校验，避免上传过期路径或未完成的音频。
    final prepared = await audio.prepare(record.relativeOggPath!);
    if (prepared.relativePath != record.relativePlayablePath ||
        prepared.durationMs != record.durationMs) {
      throw const FormatException('本机音频与归档不一致，请先检查播放。');
    }
    final file = await store.resolveRelative(prepared.relativePath);
    if (!await file.exists() || await file.length() == 0) {
      throw const FormatException('本机录音文件缺失。');
    }
    final job = await asr.submitJobFile(file.path,
        filename: '${record.purpose!.name}_${record.sessionId}.wav');
    if (job == null) throw const FormatException('无法提交转写，请检查私有 ASR 节点。');
    final result = await asr.pollJobResult(job);
    if (!result.success || result.rawText.trim().isEmpty) {
      throw const FormatException('转写未得到有效文字，请检查 ASR 状态后重试。');
    }
    return result;
  }
}

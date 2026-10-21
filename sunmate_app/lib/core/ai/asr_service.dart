import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';

/// 对外仅提供固定提示，不带服务地址、凭据或响应正文。
class AsrTranscriptionException implements Exception {
  final String message;
  const AsrTranscriptionException(this.message);
}

/// 说话人分段转写项 (来自 MOSS-Transcribe-Diarize)
class DiarizedSegment {
  final String speaker; // 说话人标签, 例如 "Speaker 0", "Speaker 1"
  final double start;   // 起始秒数
  final double end;     // 结束秒数
  final String text;    // 转写文本

  DiarizedSegment({
    required this.speaker,
    required this.start,
    required this.end,
    required this.text,
  });

  factory DiarizedSegment.fromJson(Map<String, dynamic> json) {
    return DiarizedSegment(
      speaker: json['speaker'] ?? json['speaker_id'] ?? '未知说话人',
      start: (json['start'] as num?)?.toDouble() ?? 0.0,
      end: (json['end'] as num?)?.toDouble() ?? 0.0,
      text: json['text'] ?? '',
    );
  }

  @override
  String toString() => "[$speaker ${start.toStringAsFixed(1)}s~${end.toStringAsFixed(1)}s]: $text";
}

/// 转写完整结果
class AsrResult {
  final bool success;
  final String rawText;
  final List<DiarizedSegment> segments; // 带说话人标签的分段列表
  final String? error;

  AsrResult({
    required this.success,
    this.rawText = "",
    this.segments = const [],
    this.error,
  });
}

/// 专为 MOSS-Transcribe-Diarize (MLX) 打造的 ASR 客户端服务
class AsrService {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(minutes: 5),
  ));

  String serverBaseUrl; // 例如 "http://192.168.1.100:8000" 或公网穿透地址
  String? apiKey;       // 自建服务可选 Token

  AsrService({
    this.serverBaseUrl = "http://127.0.0.1:8000",
    this.apiKey,
  });

  /// 1. 健康检查 (GET /health)
  Future<bool> checkHealth() async {
    try {
      final url = "${serverBaseUrl.replaceAll(RegExp(r'/+$'), '')}/health";
      final res = await _dio.get(
        url,
        options: Options(
          headers: {
            if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
          },
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 2. 短语音同步转写 (POST /v1/audio/transcriptions - 适用于对讲)
  Future<String> transcribeShortAudio(Uint8List audioBytes, {String filename = "speech.opus"}) async {
    if (audioBytes.isEmpty) return "";

    try {
      final url = "${serverBaseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/audio/transcriptions";
      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(audioBytes, filename: filename),
        'model': 'moss-transcribe-diarize-0.9b',
        'language': 'zh',
      });

      final options = Options(headers: {
        if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      });

      final response = await _dio.post(url, data: formData, options: options);
      if (response.statusCode == 200 && response.data != null) {
        final data = response.data;
        final text = data is Map ? data['text'] : data;
        if (text is String && text.trim().isNotEmpty) return text;
        throw const AsrTranscriptionException('未识别到清晰语音，请重新说话。');
      }
      throw const AsrTranscriptionException('语音转写未完成，请检查 ASR 节点后重新说话。');
    } on AsrTranscriptionException {
      rethrow;
    } catch (_) {
      throw const AsrTranscriptionException('语音转写未完成，请检查 ASR 节点后重新说话。');
    }
  }

  /// 3. 长音频异步任务提交 (POST /v1/jobs - 适用于会议录音与全天切片)
  Future<String?> submitJob(Uint8List audioBytes, {String filename = "meeting.opus"}) async {
    try {
      final url = "${serverBaseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/jobs";
      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(audioBytes, filename: filename),
        'diarize': true, // 请求说话人分离
      });

      final options = Options(headers: {
        if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      });

      final response = await _dio.post(url, data: formData, options: options);
      if (response.statusCode == 200 || response.statusCode == 202) {
        final data = response.data;
        return data['job_id'] ?? data['id'];
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// 从已校验的本机归档流式上传，长录音不整份读入内存。
  Future<String?> submitJobFile(String path, {required String filename}) async {
    try {
      final response = await _dio.post(
        "${serverBaseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/jobs",
        data: FormData.fromMap({
          'file': await MultipartFile.fromFile(path, filename: filename),
          'diarize': true,
        }),
        options: Options(headers: {
          if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        }),
      );
      if ([200, 202].contains(response.statusCode) && response.data is Map) {
        final id = response.data['job_id'] ?? response.data['id'];
        if (id is String && id.isNotEmpty) return id;
      }
    } catch (_) { /* 保留本机文件，允许用户重试。 */ }
    return null;
  }

  /// 4. 轮询异步任务状态与结果 (GET /v1/jobs/{id})
  Future<AsrResult> pollJobResult(String jobId, {
    Duration pollInterval = const Duration(seconds: 2),
    int maxAttempts = 150,
  }) async {
    final url = "${serverBaseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/jobs/$jobId";
    final options = Options(headers: {
      if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    });

    for (int i = 0; i < maxAttempts; i++) {
      try {
        final response = await _dio.get(url, options: options);
        if (response.statusCode == 200 && response.data is Map) {
          final data = response.data as Map<String, dynamic>;
          final status = (data['status'] ?? '').toString().toLowerCase();

          if (status == 'completed' || status == 'success' || status == 'done') {
            final rawText = data['text'] ?? data['result']?['text'] ?? '';
            final rawSegments = (data['segments'] ?? data['result']?['segments'] ?? []) as List;
            final segments = rawSegments
                .whereType<Map<String, dynamic>>()
                .map((s) => DiarizedSegment.fromJson(s))
                .toList();

            return AsrResult(
              success: true,
              rawText: rawText,
              segments: segments,
            );
          } else if (status == 'failed' || status == 'error') {
            return AsrResult(
              success: false,
              error: data['error'] ?? "ASR 任务处理失败",
            );
          }
        }
      } catch (e) {
        // 网络短暂重试
      }
      await Future.delayed(pollInterval);
    }
    return AsrResult(success: false, error: "等待 MOSS-ASR 超时");
  }

  /// 保持向后兼容的通用接口
  Future<String> transcribe(Uint8List audioBytes, {String filename = "speech.opus"}) {
    return transcribeShortAudio(audioBytes, filename: filename);
  }
}

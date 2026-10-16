import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ai/asr_service.dart';
import '../models/meeting_record.dart';
import '../providers/server_config_provider.dart';

class MeetingPage extends ConsumerStatefulWidget {
  const MeetingPage({super.key});

  @override
  ConsumerState<MeetingPage> createState() => _MeetingPageState();
}

class _MeetingPageState extends ConsumerState<MeetingPage> {
  bool _isProcessing = false;
  String _processStage = "";

  final List<MeetingRecord> _meetings = [
    MeetingRecord(
      id: "m1",
      title: "SunMate 产品架构与硬件抽象解耦评审",
      createdAt: DateTime.now().subtract(const Duration(days: 1)),
      durationSeconds: 1980, // 33 分钟
      filePath: "/storage/rec_20261014_01.opus",
      isTranscribed: true,
      transcript:
          "[Speaker 0]: 我们今天把录音卡的蓝牙 GATT 协议和硬件抽象层 (HAL) 全打通了，未来更换新型硬件无须改动任何上层业务逻辑。\n[Speaker 1]: 非常好，接下来我们要重点把按键自定义对讲、会议智能纪要以及全天时光复盘做好...",
      summary:
          "【核心共识】\n1. 确认硬件通信稳定，建立统一 HAL 抽象驱动，实现硬件与业务解耦。\n2. 自研轻量级 Flutter 跨平台架构，聚焦 AI 第二大脑的成长增值服务。",
      actionItems: [
        "完成 AiNote 6095 蓝牙卡与手机原生麦克风双驱动联调",
        "集成智能体会议纪要总结与 Action Items 提取管道",
        "优化全天随身时光机 VOR 低功耗声控与通知融合",
      ],
    ),
  ];

  /// 触发一次完整的 MOSS-ASR 说话人分离 + Hermes 纪要提炼流程
  Future<void> _processNewMeetingRecording() async {
    setState(() {
      _isProcessing = true;
      _processStage = "正在提交 MOSS-ASR 说话人分离任务...";
    });

    final asr = ref.read(asrServiceProvider);
    final agent = ref.read(agentClientProvider);

    try {
      // 1. 提交任务给本地 MOSS-ASR (POST /v1/jobs)
      // 模拟 10 秒示例音频字节
      final dummyAudioBytes = Uint8List(16000 * 2);
      final jobId = await asr.submitJob(dummyAudioBytes, filename: "board_review.opus");

      List<DiarizedSegment> segments = [];
      String rawText = "";

      if (jobId != null) {
        setState(() => _processStage = "MOSS-ASR 正在排队推理分段 (Job: $jobId)...");
        final asrResult = await asr.pollJobResult(jobId);
        if (asrResult.success) {
          segments = asrResult.segments;
          rawText = asrResult.rawText;
        }
      }

      // 兜底示例分段
      if (segments.isEmpty) {
        segments = [
          DiarizedSegment(speaker: "Speaker 0", start: 0.0, end: 12.5, text: "关于 SunMate 的全天时光机方案，我们建议采用两级时空切片聚类。"),
          DiarizedSegment(speaker: "Speaker 1", start: 13.0, end: 28.0, text: "同意，这样白天 VOR 声控切片不会把垃圾噪音全灌给 Hermes，夜间复盘也能生成高质量的成长画像。"),
        ];
        rawText = segments.map((s) => s.toString()).join("\n");
      }

      setState(() => _processStage = "Hermes 智能体正在启动 meeting-diarize-process 提炼纪要...");

      // 2. 调用 Hermes 智能体提炼纪要
      final summaryResult = await agent.summarizeMeetingWithDiarization(
        segments: segments,
        rawText: rawText,
      );

      final newRecord = MeetingRecord(
        id: "m_${DateTime.now().millisecondsSinceEpoch}",
        title: "SunMate 随身时光机与 MOSS-ASR 联调纪要",
        createdAt: DateTime.now(),
        durationSeconds: 900,
        filePath: "/storage/rec_recent.opus",
        isTranscribed: true,
        transcript: rawText,
        summary: summaryResult['summary'] ?? "会议纪要生成完毕",
        actionItems: List<String>.from(summaryResult['actionItems'] ?? []),
      );

      setState(() {
        _meetings.insert(0, newRecord);
        _isProcessing = false;
        _processStage = "";
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _processStage = "提炼异常: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("SunMate 会议纪要与待办"),
        actions: [
          IconButton(
            tooltip: "提炼最新会议录音",
            icon: const Icon(Icons.add_task),
            onPressed: _isProcessing ? null : _processNewMeetingRecording,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isProcessing)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Colors.indigo.shade50,
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _processStage,
                      style: TextStyle(fontSize: 12, color: Colors.indigo.shade900),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _meetings.length,
              itemBuilder: (context, index) {
                final m = _meetings[index];
                return Card(
                  margin: const EdgeInsets.only(bottom: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFF3E0),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.mic_none, color: Color(0xFFFF8C00)),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                  const SizedBox(height: 2),
                                  Text(
                                    "${m.createdAt.month}月${m.createdAt.day}日 · 时长 ${m.durationSeconds ~/ 60} 分钟",
                                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // 智能体纪要
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          child: Text(
                            m.summary,
                            style: const TextStyle(fontSize: 13, height: 1.5, color: Colors.black87),
                          ),
                        ),

                        // 待办 Action Items
                        if (m.actionItems.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          const Text("📌 待办事项 Action Items:", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          ...m.actionItems.map((item) => Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Row(
                                  children: [
                                    const Icon(Icons.check_circle_outline, size: 16, color: Colors.green),
                                    const SizedBox(width: 6),
                                    Expanded(child: Text(item, style: const TextStyle(fontSize: 13))),
                                  ],
                                ),
                              )),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

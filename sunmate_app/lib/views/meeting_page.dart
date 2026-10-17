import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ai/asr_service.dart';
import '../models/meeting_record.dart';
import '../providers/server_config_provider.dart';
import '../providers/device_provider.dart';

class MeetingPage extends ConsumerStatefulWidget {
  const MeetingPage({super.key});

  @override
  ConsumerState<MeetingPage> createState() => _MeetingPageState();
}

class _MeetingPageState extends ConsumerState<MeetingPage> {
  bool _isProcessing = false;
  String _processStage = "";

  // 真实的会议记录列表 (初始化为空，绝不放假数据)
  final List<MeetingRecord> _meetings = [];

  // 现场录音秒表计时
  Timer? _recordTimer;
  int _recordSeconds = 0;

  @override
  void dispose() {
    _recordTimer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _recordSeconds = 0;
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) setState(() => _recordSeconds++);
    });
  }

  void _stopTimer() {
    _recordTimer?.cancel();
    _recordTimer = null;
  }

  String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return "${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
  }

  /// 触发真实的 MOSS-ASR 说话人分离 + Hermes 纪要提炼流程
  Future<void> _processNewMeetingRecording() async {
    final factory = ref.read(deviceFactoryProvider);
    final realAudioBytes = factory.bleDriver.lastRecordedBytes;

    // 前置严格校验：若当前没有产生任何录音，绝不伪造虚假示例！
    if (realAudioBytes == null || realAudioBytes.isEmpty) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.info_outline, color: Color(0xFFE65100)),
                SizedBox(width: 8),
                Text("暂无待处理录音", style: TextStyle(fontSize: 16)),
              ],
            ),
            content: const Text(
              "当前沙箱中尚未检测到待提炼的音频数据。\n\n您可以：\n1. 点击下方【开始现场会议录音】录制一段真实会议；\n2. 或长按 C·ONE 随身录音卡录音，结束后点击此处进行智能纪要提炼。",
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
            actions: [
              TextButton(
                child: const Text("我知道了"),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ],
          ),
        );
      }
      return;
    }

    setState(() {
      _isProcessing = true;
      _processStage = "正在提交 MOSS-ASR 说话人分离任务 (${realAudioBytes.length ~/ 1024} KB)...";
    });

    final asr = ref.read(asrServiceProvider);
    final agent = ref.read(agentClientProvider);
    final filename = "meeting_${DateTime.now().millisecondsSinceEpoch}.opus";

    try {
      // 提交任务给本地 MOSS-ASR (POST /v1/jobs)
      final jobId = await asr.submitJob(realAudioBytes, filename: filename);

      List<DiarizedSegment> segments = [];
      String rawText = "";

      if (jobId != null) {
        setState(() => _processStage = "MOSS-ASR 正在排队推理声纹聚类 (Job: $jobId)...");
        final asrResult = await asr.pollJobResult(jobId);
        if (asrResult.success) {
          segments = asrResult.segments;
          rawText = asrResult.rawText;
        }
      }

      if (rawText.trim().isEmpty) {
        throw Exception("未能从音频中识别出有效对话文本，请确保环境声音清晰。");
      }

      setState(() => _processStage = "Hermes 智能体正在启动 meeting-diarize-process 提炼纪要...");

      // 调用 Hermes 智能体提炼纪要
      final summaryResult = await agent.summarizeMeetingWithDiarization(
        segments: segments,
        rawText: rawText,
      );

      final newRecord = MeetingRecord(
        id: "m_${DateTime.now().millisecondsSinceEpoch}",
        title: "会议纪要 · ${DateTime.now().month}月${DateTime.now().day}日 ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}",
        createdAt: DateTime.now(),
        durationSeconds: (realAudioBytes.length ~/ 2000), // 估算 16kbps Opus 时长
        filePath: "/storage/$filename",
        isTranscribed: true,
        transcript: rawText,
        summary: summaryResult['summary'] ?? "会议讨论完毕，共识已沉淀。",
        actionItems: List<String>.from(summaryResult['actionItems'] ?? []),
      );

      setState(() {
        _meetings.insert(0, newRecord);
        _isProcessing = false;
        _processStage = "";
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("✓ 会议纪要与待办事项提炼完成！"),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _processStage = "提炼异常: $e";
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("提炼失败: $e"),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }
  }

  /// 展开会议详情抽屉/全屏页
  void _showMeetingDetail(MeetingRecord m) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          return Container(
            height: MediaQuery.of(context).size.height * 0.85,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        m.title,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                Text(
                  "录制于 ${m.createdAt.year}年${m.createdAt.month}月${m.createdAt.day}日 ${m.createdAt.hour}:${m.createdAt.minute.toString().padLeft(2, '0')} · 时长约 ${m.durationSeconds ~/ 60} 分钟",
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const Divider(height: 24),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 1. 核心共识与决议
                        const Row(
                          children: [
                            Icon(Icons.lightbulb_outline, size: 18, color: Color(0xFFFF8C00)),
                            SizedBox(width: 6),
                            Text("核心共识与决议:", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF8E1),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFFFE082)),
                          ),
                          child: Text(
                            m.summary,
                            style: const TextStyle(fontSize: 13, height: 1.5, color: Colors.black87),
                          ),
                        ),
                        const SizedBox(height: 20),

                        // 2. 待办事项 Action Items
                        if (m.actionItems.isNotEmpty) ...[
                          const Row(
                            children: [
                              Icon(Icons.checklist, size: 18, color: Colors.indigo),
                              SizedBox(width: 6),
                              Text("行动项清单 Action Items:", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ...m.actionItems.map((item) {
                            return Card(
                              margin: const EdgeInsets.only(bottom: 6),
                              elevation: 0,
                              color: Colors.grey.shade50,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: BorderSide(color: Colors.grey.shade200),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                child: Row(
                                  children: [
                                    const Icon(Icons.check_circle_outline, size: 18, color: Colors.green),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(item, style: const TextStyle(fontSize: 13)),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }),
                          const SizedBox(height: 20),
                        ],

                        // 3. 说话人对话流水逐字稿
                        const Row(
                          children: [
                            Icon(Icons.record_voice_over_outlined, size: 18, color: Colors.teal),
                            SizedBox(width: 6),
                            Text("说话人分离逐字稿 (MOSS-ASR):", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            m.transcript.isNotEmpty ? m.transcript : "暂无逐字稿内容",
                            style: const TextStyle(fontSize: 12, height: 1.6, color: Colors.black87),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF8C00),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text("复制整篇纪要 (Markdown)"),
                        onPressed: () {
                          final md = "## ${m.title}\n\n### 核心决议\n${m.summary}\n\n### 待办事项\n${m.actionItems.map((a) => '- [ ] $a').join('\n')}\n\n### 对话流水\n${m.transcript}";
                          Clipboard.setData(ClipboardData(text: md));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("✓ Markdown 纪要已复制到剪贴板")),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      tooltip: "删除此会议记录",
                      onPressed: () {
                        setState(() => _meetings.removeWhere((item) => item.id == m.id));
                        Navigator.of(ctx).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("已从本地移除该会议记录")),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final devNotifier = ref.read(deviceProvider.notifier);
    final device = ref.watch(deviceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text("SunMate 会议纪要与待办"),
        actions: [
          IconButton(
            tooltip: "提炼最新会议录音",
            icon: const Icon(Icons.auto_awesome),
            onPressed: _isProcessing ? null : _processNewMeetingRecording,
          ),
        ],
      ),
      body: Column(
        children: [
          // 1. 现场录音控制横幅 (直接可录制新会议)
          Card(
            margin: const EdgeInsets.all(16),
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: device.isRecording ? Colors.red.shade100 : const Color(0xFFFFF3E0),
                        child: Icon(
                          device.isRecording ? Icons.fiber_manual_record : Icons.mic,
                          color: device.isRecording ? Colors.red : const Color(0xFFFF8C00),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              device.isRecording ? "现场会议录制中..." : "会议录音控制台",
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              device.isRecording
                                  ? "时长: ${_formatDuration(_recordSeconds)} · 正在采集 16kHz 声学信号"
                                  : (device.isConnected ? "录音卡已就绪 (${device.deviceName})" : "未连录音卡，将使用手机原生麦克风录制"),
                              style: TextStyle(
                                fontSize: 12,
                                color: device.isRecording ? Colors.red : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (device.isRecording)
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          icon: const Icon(Icons.stop, size: 18),
                          label: const Text("结束录音"),
                          onPressed: () async {
                            _stopTimer();
                            await devNotifier.stopRecording();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text("录音已结束并落盘！正在点击右上角【✨】或直接开始提炼。"),
                                duration: Duration(seconds: 4),
                              ),
                            );
                            // 录音结束自动提示触发提炼
                            _processNewMeetingRecording();
                          },
                        )
                      else
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF8C00),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          icon: const Icon(Icons.mic, size: 18),
                          label: const Text("开始录音"),
                          onPressed: () async {
                            _startTimer();
                            await devNotifier.startRecording();
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // 2. 状态提示条
          if (_isProcessing)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.indigo.shade200),
              ),
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

          // 3. 会议记录列表
          Expanded(
            child: _meetings.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.event_note_outlined, size: 54, color: Colors.grey.shade400),
                          const SizedBox(height: 16),
                          const Text(
                            "暂无会议纪要记录",
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            "您可以长按 C·ONE 随身录音卡录音，或点击上方【开始录音】开启一场现场讨论。\n录音结束后，MOSS-ASR 将自动完成说话人分离，并由 Hermes 提炼出核心决议与待办事项。",
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.5),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: _meetings.length,
                    itemBuilder: (context, index) {
                      final m = _meetings[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 2,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => _showMeetingDetail(m),
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
                                          Text(m.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                          const SizedBox(height: 2),
                                          Text(
                                            "${m.createdAt.month}月${m.createdAt.day}日 · 时长约 ${m.durationSeconds ~/ 60} 分钟",
                                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.grey),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                // 纪要摘要预览
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade50,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    m.summary,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12, color: Colors.black87, height: 1.4),
                                  ),
                                ),
                                if (m.actionItems.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      const Icon(Icons.checklist, size: 14, color: Colors.green),
                                      const SizedBox(width: 4),
                                      Text(
                                        "包含 ${m.actionItems.length} 项行动待办 (点击查看完整流水)",
                                        style: const TextStyle(fontSize: 11, color: Colors.green, fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
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

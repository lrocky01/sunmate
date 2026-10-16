import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/timeline_entry.dart';
import '../providers/timeline_provider.dart';

class TimelinePage extends ConsumerWidget {
  const TimelinePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timelineState = ref.watch(timelineProvider);
    final notifier = ref.read(timelineProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text("SunMate 随身时光机 & 画像"),
        actions: [
          IconButton(
            tooltip: "一键生成今日画像复盘",
            icon: timelineState.isGeneratingReport
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome),
            onPressed: timelineState.isGeneratingReport
                ? null
                : () => notifier.generateDailyReport(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. 全天随身记录开关横幅
            Card(
              color: timelineState.isLifeLogActive
                  ? const Color(0xFFE0F2F1)
                  : Colors.grey.shade100,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: SwitchListTile(
                title: const Text("全天随身记录模式 (低功耗 VOR)", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                subtitle: Text(
                  timelineState.isLifeLogActive
                      ? "已开启低功耗声控录音 + 手机通知对齐，持续分析中"
                      : "未开启，点击开启全天随身语音捕捉",
                  style: const TextStyle(fontSize: 12),
                ),
                value: timelineState.isLifeLogActive,
                activeColor: Colors.teal.shade700,
                onChanged: (val) => notifier.toggleLifeLog(),
              ),
            ),
            const SizedBox(height: 16),

            // 2. 今日智能画像复盘卡片
            if (timelineState.latestReport != null) ...[
              Card(
                elevation: 3,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.psychology, color: Colors.purple.shade700, size: 24),
                          const SizedBox(width: 8),
                          const Text("今日第二大脑成长复盘", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text("💡 认知与决策: ${timelineState.latestReport!.cognitiveReflection}", style: const TextStyle(fontSize: 13, height: 1.4)),
                      const SizedBox(height: 6),
                      Text("💬 沟通与情绪: ${timelineState.latestReport!.communicationScore}", style: const TextStyle(fontSize: 13, height: 1.4)),
                      const SizedBox(height: 6),
                      Text("⚡ 时间与精力: ${timelineState.latestReport!.energyDistribution}", style: const TextStyle(fontSize: 13, height: 1.4)),
                      const Divider(height: 24),
                      const Text("🌱 针对性能力提升建议:", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      ...timelineState.latestReport!.growthAdvice.map((adv) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("• ", style: TextStyle(color: Colors.teal, fontWeight: FontWeight.bold)),
                            Expanded(child: Text(adv, style: const TextStyle(fontSize: 12, color: Colors.teal, height: 1.3))),
                          ],
                        ),
                      )),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],

            // 3. 全天时光轴流水与快捷模拟打标
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("今日时光轴流水 (语音 + 通知融合)", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                TextButton.icon(
                  icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                  label: const Text("灵感打标", style: TextStyle(fontSize: 12)),
                  onPressed: () => notifier.addBookmark("随手灵感速记"),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...timelineState.entries.map((entry) {
              final isVoice = entry.sourceType == TimelineSourceType.audioVoice;
              final isBookmark = entry.sourceType == TimelineSourceType.systemNote;

              Color bgCol = Colors.blue.shade100;
              Color iconCol = Colors.blue.shade800;
              IconData iconData = Icons.notifications_none;

              if (isVoice) {
                bgCol = const Color(0xFFFFE0B2);
                iconCol = const Color(0xFFE65100);
                iconData = Icons.mic;
              } else if (isBookmark) {
                bgCol = Colors.purple.shade100;
                iconCol = Colors.purple.shade800;
                iconData = Icons.bookmark;
              }

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: bgCol,
                        child: Icon(iconData, size: 18, color: iconCol),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(entry.sourceApp, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                Text(
                                  "${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}",
                                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(entry.content, style: const TextStyle(fontSize: 13, height: 1.4)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

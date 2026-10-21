import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/hardware/recorder_long_recordings.dart';
import '../core/recordings/recording_processing_models.dart';
import '../providers/device_provider.dart';
import '../providers/recording_processing_provider.dart';
import 'meeting_recording_overview.dart';
import 'recording_processing_pages.dart';
import 'recorder_long_files_page.dart';
import 'recorder_management_page.dart';

class MeetingPage extends ConsumerWidget {
  const MeetingPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(recordingProcessingProvider);
    final driver = ref.read(deviceFactoryProvider).bleDriver;
    return StreamBuilder<void>(
        stream: driver.stateChanges,
        builder: (context, snapshot) {
          final archives = driver.longFileLibrary.recordings
              .where((r) => r.purpose == LongRecordingPurpose.meeting)
              .toList();
          final meetings = <String, (String, int)>{
            for (final s in c.sessions
                .where((s) => s.purpose == LongRecordingPurpose.meeting))
              s.id: (s.sn, s.session),
            for (final r in archives)
              sessionKey(r.serialNumber, r.sessionId): (
                r.serialNumber,
                r.sessionId
              ),
          }.entries.toList()
            ..sort((a, b) => b.value.$2.compareTo(a.value.$2));
          return Scaffold(
              appBar: AppBar(title: const Text('会议录音与纪要')),
              body: ListView(padding: const EdgeInsets.all(16), children: [
                Text('会议长录音', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text('一场会议，一份完整录音、逐字稿和纪要。分段操作可在详情中查看。'),
                Wrap(spacing: 8, children: [
                  TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  const RecorderRecordingSettingsPage())),
                      icon: const Icon(Icons.tune),
                      label: const Text('选择下次录音用途')),
                  TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  const RecordingProcessingSettingsPage())),
                      icon: const Icon(Icons.auto_mode),
                      label: const Text('自动处理设置')),
                  TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const RecorderLongFilesPage(
                                  purposeFilter:
                                      LongRecordingPurpose.meeting))),
                      icon: const Icon(Icons.folder_open),
                      label: const Text('下载与归档管理')),
                ]),
                if (!c.loaded && c.message == null)
                  const LinearProgressIndicator(),
                if (c.message != null)
                  Text(c.message!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                if (c.loaded && meetings.isEmpty)
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text('尚无会议录音。先选择会议用途，再用卡片按键录制。')),
                for (final meeting in meetings) ...[
                  const Divider(height: 24),
                  MeetingRecordingOverview(
                      key: ValueKey(meeting.key),
                      serialNumber: meeting.value.$1,
                      sessionId: meeting.value.$2,
                      archive: archives
                          .where((r) =>
                              sessionKey(r.serialNumber, r.sessionId) ==
                              meeting.key)
                          .firstOrNull),
                ],
              ]));
        });
  }
}

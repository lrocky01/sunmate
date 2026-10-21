import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ai/agent_client.dart';
import 'package:sunmate_app/core/sync/archive_models.dart';

void main() {
  test('capture synthetic current App requests over loopback HTTP', () async {
    final records = <Map<String, dynamic>>[];
    var label = '';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      records.add({'case': label, 'request': body});
      var text = '合成答复';
      if (label.startsWith('reference_')) {
        final prompt = body['messages'].last['content'] as String;
        final value =
            jsonDecode(prompt.substring(prompt.indexOf('{"schemaVersion"')));
        text = jsonEncode({
          'status': 'complete',
          'libraryId': value['archive']['libraryId'],
          'used': value['archive']['records'],
          'text': '合成引用结果'
        });
      }
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write('data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': text},
                'finish_reason': null
              }
            ]
          })}\n\n');
      request.response.write('data: ${jsonEncode({
            'choices': [
              {'index': 0, 'delta': {}, 'finish_reason': 'stop'}
            ]
          })}\n\ndata: [DONE]\n\n');
      await request.response.close();
    });
    final agent =
        AgentClient(hermesBaseUrl: 'http://127.0.0.1:${server.port}/v1');
    try {
      label = 'chat';
      await agent.chatStream('合成追问', history: [
        {'role': 'user', 'content': '合成首问'},
        {'role': 'assistant', 'content': '合成首答'}
      ]).drain<void>();
      label = 'meeting';
      await agent.summarizeMeetingWithDiarization(
          segments: const [],
          rawText:
              '以下是同一场会议各段；段内说话人编号不代表跨段同一人，不确定时间只作相对顺序。\n[片段1, 相对0ms；连续录音时间估算]\n[0.0-2.0s 段1-0] 合成会议文本');
      label = 'intermediate';
      await agent.summarizeMeetingWithDiarization(
          segments: const [],
          rawText:
              '这是供最终汇总的局部资料，请只整理已提供事实、时间及来源，保留不确定性，不推断跨段说话人身份。\n[2026-10-18T09:05:00.000] [合成通知来源] 合成局部资料');
      label = 'lifelog';
      await agent.generateDailyLifelogReview(timeBlockEvents: [
        '[2026-10-18T09:00:00.000] [录音卡] [连续录音时间估算] 合成随身转写'
      ], notifications: [
        '[2026-10-18T09:05:00.000] [合成通知来源] [外部通知] 合成通知正文'
      ]);
      label = 'notification';
      await agent.generateNotificationDigest(notifications: [
        {
          'id': 'fixture-notice-1',
          'timestamp': '2026-10-18T01:05:00Z',
          'appName': '合成通知来源',
          'packageName': 'com.example.fixture',
          'content': '合成正文第一部分',
          'fragment': '1/2'
        },
        {
          'id': 'fixture-notice-1',
          'timestamp': '2026-10-18T01:05:00Z',
          'appName': '合成通知来源',
          'content': '合成正文第二部分',
          'fragment': '2/2'
        },
        {
          'id': 'batch-fixture',
          'timestamp': '2026-10-18T00:00:00Z',
          'appName': '批次摘要',
          'content': '合成局部简报，原始ID fixture-notice-2',
          'sourceType': 'notification_digest_batch'
        }
      ]);
      for (final task in ['meeting', 'notification', 'lifelog']) {
        label = 'reference_$task';
        await agent.summarizeArchiveReferences(
            ArchiveReferences('fixture-server', 'fixture-library', 'default',
                'fixture-client', [
              {'id': 'fixture-$task-source', 'sha': 'fixture-source-version'}
            ]),
            task: task,
            from: '2026-10-21T00:00:00Z',
            to: '2026-10-22T00:00:00Z');
      }
      label = 'archive_chat';
      final archiveAgent = AgentClient(
          hermesBaseUrl: agent.hermesBaseUrl,
          archiveContext: {
            'libraryId': 'fixture-library',
            'profile': 'default'
          });
      await archiveAgent.chatStream('帮我查昨天的通知').drain<void>();
      expect(records.length, 9);
      final output = Platform.environment['SUNMATE_CAPTURE_OUTPUT'];
      if (output != null)
        await File(output)
            .writeAsString(const JsonEncoder.withIndent('  ').convert(records));
    } finally {
      await server.close(force: true);
    }
  });
}

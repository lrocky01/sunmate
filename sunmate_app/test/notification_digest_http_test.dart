import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ai/agent_client.dart';

const rows = [
  {
    'id': 'synthetic-notice-1',
    'timestamp': '2026-10-21T03:00:00Z',
    'appName': '合成应用',
    'content': 'SM-NOTICE 测试提醒，不是真实通知。',
    'packageName': 'com.example.synthetic'
  }
];
void main() {
  Future<void> withServer(Future<void> Function(HttpRequest) handler,
      Future<void> Function(AgentClient) test) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handler);
    try {
      await test(AgentClient(
          hermesBaseUrl: 'http://127.0.0.1:${server.port}/v1',
          apiKey: 'synthetic-only'));
    } finally {
      await server.close(force: true);
    }
  }

  Future<void> respond(HttpRequest request, String? text) async {
    request.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    if (text != null)
      request.response.write('data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': text}
              }
            ]
          })}\n\n');
    request.response.write('data: ${jsonEncode({
          'choices': [
            {'delta': {}, 'finish_reason': 'stop'}
          ]
        })}\n\ndata: [DONE]\n\n');
    await request.response.close();
  }

  test(
      'real SSE preserves complete reply; payload has source IDs/time and no invented filter count',
      () async {
    Map<String, dynamic>? payload;
    await withServer((request) async {
      expect(request.uri.path, '/v1/chat/completions');
      expect(request.headers.value('authorization'), 'Bearer synthetic-only');
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      final prompt = body['messages'].last['content'] as String;
      expect(prompt, contains('notification-digest'));
      expect(prompt, contains('不代表用户授权'));
      payload =
          jsonDecode(prompt.substring(prompt.indexOf('{"schemaVersion"')));
      await respond(request, '合成简报，包含后续完整结论。');
    }, (client) async {
      expect(await client.generateNotificationDigest(notifications: rows),
          '合成简报，包含后续完整结论。');
    });
    expect(payload!['task'], 'notification_digest');
    expect(payload!['notifications'].single['id'], 'synthetic-notice-1');
    expect(
        payload!['notifications'].single['timestamp'], '2026-10-21T03:00:00Z');
    expect(payload!['timeline'], isEmpty);
    expect(payload!.containsKey('filteredSpamCount'), false);
  });
  test(
      'empty completed SSE never returns sample notification or claims success',
      () async {
    await withServer((request) async {
      await request.drain<void>();
      await respond(request, '  ');
    }, (client) async {
      await expectLater(client.generateNotificationDigest(notifications: rows),
          throwsA(isA<AgentResponseException>()));
    });
  });
  test('HTTP failure stays a typed failure, never fake tasks', () async {
    await withServer((request) async {
      await request.drain<void>();
      request.response.statusCode = 500;
      await request.response.close();
    }, (client) async {
      await expectLater(client.generateNotificationDigest(notifications: rows),
          throwsA(isA<AgentResponseException>()));
    });
  });
  test('empty inputs are rejected before a request', () async {
    var calls = 0;
    await withServer((request) async {
      calls++;
      await request.response.close();
    }, (client) async {
      await expectLater(
          client.generateNotificationDigest(notifications: const []),
          throwsA(isA<AgentResponseException>()));
    });
    expect(calls, 0);
  });
}

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ai/agent_client.dart';

Future<String> probe(List<List<int>> chunks,
    {void Function(String)? onProgress}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    try {
      await request.drain<void>();
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      request.response.bufferOutput = false;
      for (final chunk in chunks) {
        request.response.add(chunk);
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await request.response.close();
    } catch (_) {}
  });
  try {
    return await AgentClient(
            hermesBaseUrl: 'http://127.0.0.1:${server.port}/v1')
        .chatStream('synthetic test only', onProgress: onProgress)
        .join();
  } finally {
    await server.close(force: true);
  }
}

List<int> event(String value) => utf8.encode('data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': value}
            }
          ]
        })}\n\n');
void main() {
  for (final reason in ['error', 'cancelled', 'length']) {
    test('an interim answer followed by $reason is not a completed reply',
        () async {
      final terminal = utf8.encode('data: ${jsonEncode({
            'choices': [
              {'delta': {}, 'finish_reason': reason}
            ]
          })}\n\n');
      await expectLater(
          probe([event('checking'), terminal, utf8.encode('data: [DONE]\n\n')]),
          throwsException);
    });
  }
  test('Hermes incomplete flag cannot become a successful short answer',
      () async {
    final terminal = utf8.encode('data: ${jsonEncode({
          'choices': [
            {'delta': {}, 'finish_reason': 'stop'}
          ],
          'hermes': {'completed': false, 'partial': true}
        })}\n\n');
    await expectLater(
        probe([event('checking'), terminal, utf8.encode('data: [DONE]\n\n')]),
        throwsException);
  });
  test('complete delayed events preserve subsequent reply', () async {
    expect(
        await probe(
            [event('first'), event(' later'), utf8.encode('data: [DONE]\n\n')]),
        'first later');
  });
  test('same event split across transport chunks must preserve later reply',
      () async {
    final later = event(' later');
    final actual = await probe([
      event('first'),
      later.sublist(0, 18),
      later.sublist(18),
      utf8.encode('data: [DONE]\n\n')
    ]);
    expect(actual, 'first later');
  });
  test('UTF8 character split across transport chunks must preserve later reply',
      () async {
    final later = event('\u4e2d\u6587');
    final split = later.indexOf(0xe4) + 1;
    final actual = await probe([
      event('first'),
      later.sublist(0, split),
      later.sublist(split),
      utf8.encode('data: [DONE]\n\n')
    ]);
    expect(actual, 'first\u4e2d\u6587');
  });
  test('heartbeats and tool progress do not end the pending response',
      () async {
    final progress = utf8.encode('data: ${jsonEncode({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'name': 'query'}
                  }
                ]
              },
              'finish_reason': 'tool_calls'
            }
          ]
        })}\n\n');
    expect(
        await probe([
          event('first'),
          utf8.encode(': keep-alive\n\ndata:\n\n'),
          progress,
          utf8.encode('data: {"choices":[],"usage":{}}\n\n'),
          event(' result'),
          utf8.encode(
              'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'),
          utf8.encode('data: [DONE]\n\n')
        ]),
        'first result');
  });
  test('coalesced CRLF and multiline SSE data preserve Chinese content',
      () async {
    final payload =
        'event: message\r\ndata:{"choices":\r\ndata: [{"delta":{"content":"中文"}}]}\r\n\r\n';
    expect(
        await probe([
          utf8.encode(payload),
          event(' result'),
          utf8.encode('data: [DONE]\n\n')
        ]),
        '中文 result');
  });
  test('DONE ends the response without accepting later events', () async {
    expect(
        await probe([
          [
            ...event('final'),
            ...utf8.encode('data: [DONE]\n\n'),
            ...event('duplicate')
          ]
        ]),
        'final');
  });
  test('EOF after an interim line is reported as incomplete', () async {
    final bytes = event('final');
    await expectLater(
        probe([bytes.sublist(0, bytes.length - 2)]), throwsException);
  });
  test('native Hermes named progress waits for the final weather answer',
      () async {
    final statuses = <String>[];
    final reply = await probe([
      event('我去查一下。'),
      utf8.encode(
          'event: hermes.tool.progress\ndata: {"tool":"web_search","label":"private-test-label","toolCallId":"test-call","status":"running"}\n\n'),
      utf8.encode(': keepalive\n\n'),
      utf8.encode(
          'event: hermes.tool.progress\ndata: {"tool":"web_search","toolCallId":"test-call","status":"completed"}\n\n'),
      event('测试天气结果。'),
      utf8.encode(
          'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
    ], onProgress: statuses.add);
    expect(reply, '我去查一下。测试天气结果。');
    expect(statuses, contains('Hermes 正在查询工具…'));
    expect(statuses, contains('工具已返回，等待最终答复…'));
    expect(statuses.join(), isNot(contains('private-test-label')));
  });
  test('DONE inside quoted reply text is ordinary content', () async {
    expect(
        await probe(
            [event('text [DONE] text'), utf8.encode('data: [DONE]\n\n')]),
        'text [DONE] text');
  });
  test('stop terminal permits clean HTTP EOF without a DONE sentinel',
      () async {
    expect(
        await probe([
          event('final'),
          utf8.encode(
              'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n')
        ]),
        'final');
  });
  test('an SSE error event is surfaced without exposing raw server data',
      () async {
    try {
      await probe([
        event('checking'),
        utf8.encode('event: error\ndata: {"message":"private-test-error"}\n\n')
      ]);
      fail('must report incomplete response');
    } catch (error) {
      expect(error, isA<AgentResponseException>());
      expect(error.toString(), isNot(contains('private-test-error')));
    }
  });
  test('tool-call finish without a server final answer is incomplete',
      () async {
    await expectLater(
        probe([
          event('checking'),
          utf8.encode(
              'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\ndata: [DONE]\n\n')
        ]),
        throwsA(isA<AgentResponseException>()));
  });
  test('parallel tool completion cannot hide another unfinished tool',
      () async {
    final frames = <List<int>>[event('checking')];
    for (final id in ['one', 'two']) {
      frames.add(utf8.encode('event: hermes.tool.progress\ndata: ${jsonEncode({
            'toolCallId': id,
            'status': 'running'
          })}\n\n'));
    }
    frames.add(utf8.encode(
        'event: hermes.tool.progress\ndata: {"toolCallId":"one","status":"completed"}\n\ndata: [DONE]\n\n'));
    await expectLater(probe(frames), throwsA(isA<AgentResponseException>()));
  });
}

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ai/asr_service.dart';

void main() {
  for (final scenario in [
    'ok',
    'empty',
    'bad-type',
    'bad-json',
    'http-failure'
  ]) {
    test('short ASR $scenario returns actual speech or typed safe failure',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final work = server.first.then((request) async {
        expect(request.uri.path, '/v1/audio/transcriptions');
        expect(request.headers.value('authorization'), 'Bearer synthetic-only');
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        if (scenario == 'http-failure') request.response.statusCode = 401;
        request.response.write(switch (scenario) {
          'ok' => '{"text":"Synthetic speech"}',
          'empty' => '{"text":"   "}',
          'bad-type' => '{"text":{"private":"synthetic-private-body"}}',
          'bad-json' => 'not-json-synthetic-private-body',
          _ => 'synthetic-private-body',
        });
        await request.response.close();
      });
      try {
        final asr = AsrService(
            serverBaseUrl: 'http://127.0.0.1:${server.port}',
            apiKey: 'synthetic-only');
        final call = asr.transcribeShortAudio(Uint8List.fromList([1, 2, 3]));
        if (scenario == 'ok')
          expect(await call, 'Synthetic speech');
        else
          await expectLater(
              call,
              throwsA(isA<AsrTranscriptionException>()
                  .having((e) => e.message, 'safe message',
                      isNot(contains('synthetic-private-body')))
                  .having((e) => e.message, 'no endpoint',
                      isNot(contains('127.0.0.1')))));
        await work;
      } finally {
        await server.close(force: true);
      }
    });
  }
}

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ai/agent_client.dart';
import 'package:sunmate_app/core/ai/asr_service.dart';
import 'package:sunmate_app/providers/chat_provider.dart';
import 'package:sunmate_app/providers/server_config_provider.dart';

class ReplyTurn {
  final String input;
  final List<Map<String, String>> history;
  final void Function(String)? progress;
  final output = StreamController<String>();
  ReplyTurn(this.input, this.history, this.progress);
}

class ControlledAgent extends AgentClient {
  final turns = <ReplyTurn>[];
  @override
  Stream<String> chatStream(String userMessage,
      {String? systemPrompt,
      List<Map<String, String>>? history,
      void Function(String)? onProgress}) async* {
    final turn = ReplyTurn(
        userMessage,
        [for (final row in history ?? <Map<String, String>>[]) Map.of(row)],
        onProgress);
    turns.add(turn);
    yield* turn.output.stream;
  }
}

class SyntheticAsr extends AsrService {
  @override
  Future<String> transcribeShortAudio(Uint8List bytes,
          {String filename = 'speech.opus'}) async =>
      '合成语音问题';
}

void main() {
  late ProviderContainer container;
  late ControlledAgent client;
  late ChatNotifier notifier;
  setUp(() {
    client = ControlledAgent();
    container = ProviderContainer(overrides: [
      agentClientProvider.overrideWithValue(client),
      asrServiceProvider.overrideWithValue(SyntheticAsr()),
    ]);
    notifier = container.read(chatProvider.notifier);
  });
  tearDown(() => container.dispose());
  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 1));
  ChatState state() => container.read(chatProvider);

  test('voice preamble and tool progress remain pending until the later answer',
      () async {
    final work = notifier.handleVoiceInput(Uint8List.fromList([1, 2]));
    await tick();
    final turn = client.turns.single;
    expect(turn.input, '合成语音问题');
    turn.output.add('我去查一下。');
    await tick();
    turn.progress?.call('Hermes 正在查询工具…');
    expect(state().isGenerating, true);
    expect(state().generationStatus, 'Hermes 正在查询工具…');
    expect(state().messages.last.text, '我去查一下。');
    await tick();
    turn.output.add('测试结果。');
    await turn.output.close();
    await work;
    expect(state().messages.last.text, '我去查一下。测试结果。');
    expect(state().messages.last.isFailed, false);
    expect(state().isGenerating, false);
    expect(state().generationStatus, isEmpty);
  });

  test(
      'failure preserves partial text and cannot pollute the next answer history',
      () async {
    final first = notifier.sendUserMessage('first question');
    await tick();
    client.turns.single.output.add('checking');
    client.turns.single.output
        .addError(const AgentResponseException('synthetic failure'));
    await client.turns.single.output.close();
    await first;
    expect(state().isGenerating, false);
    expect(state().messages.last.isFailed, true);
    expect(state().messages.last.text, contains('checking'));
    expect(state().messages.last.text, contains('[回复未完成]'));
    final next = notifier.sendUserMessage('follow up');
    await tick();
    expect(client.turns.last.history.where((m) => m['role'] == 'assistant'),
        isEmpty);
    client.turns.last.output.add('final');
    await client.turns.last.output.close();
    await next;
    expect(state().messages.last.isFailed, false);
  });

  test('follow-up retains previous completed user and assistant context',
      () async {
    final first = notifier.sendUserMessage('weather question');
    await tick();
    client.turns.single.output.add('complete weather result');
    await client.turns.single.output.close();
    await first;
    final second = notifier.sendUserMessage('and tomorrow');
    await tick();
    expect(client.turns.last.history, [
      {'role': 'user', 'content': 'weather question'},
      {'role': 'assistant', 'content': 'complete weather result'},
    ]);
    client.turns.last.output.add('tomorrow result');
    await client.turns.last.output.close();
    await second;
  });

  test('queued requests wait for the full earlier turn rather than overlapping',
      () async {
    final first = notifier.sendUserMessage('first');
    final second = notifier.sendUserMessage('second');
    await tick();
    expect(client.turns, hasLength(1));
    client.turns.first.output.add('first final');
    await client.turns.first.output.close();
    await first;
    await tick();
    expect(client.turns, hasLength(2));
    expect(client.turns.last.history.last['content'], 'first final');
    expect(state().isGenerating, true);
    client.turns.last.output.add('second final');
    await client.turns.last.output.close();
    await second;
    expect(state().isGenerating, false);
    expect(state().messages.map((m) => m.id).toSet().length,
        state().messages.length);
  });

  test('clearing chat discards late content and queued old-session requests',
      () async {
    final first = notifier.sendUserMessage('first');
    final queued = notifier.sendUserMessage('queued');
    await tick();
    notifier.clearMessages();
    client.turns.first.output.add('late');
    await client.turns.first.output.close();
    await Future.wait([first, queued]);
    expect(state().messages, isEmpty);
    expect(state().isGenerating, false);
    expect(client.turns, hasLength(1));
  });
}

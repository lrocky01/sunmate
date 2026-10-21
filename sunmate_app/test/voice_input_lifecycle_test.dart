import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ai/asr_service.dart';
import 'package:sunmate_app/providers/chat_provider.dart';
import 'package:sunmate_app/providers/server_config_provider.dart';
import 'chat_reply_lifecycle_test.dart' show ControlledAgent;

class PendingAsr extends AsrService {
  final calls = <Completer<String>>[];
  final audio = <Uint8List>[];
  @override
  Future<String> transcribeShortAudio(Uint8List bytes,
      {String filename = 'speech.opus'}) {
    audio.add(Uint8List.fromList(bytes));
    final call = Completer<String>();
    calls.add(call);
    return call.future;
  }
}

void main() {
  late ProviderContainer container;
  late ChatNotifier chat;
  late PendingAsr asr;
  late ControlledAgent agent;
  ChatState state() => container.read(chatProvider);
  ChatMessage voice(String id) =>
      state().messages.singleWhere((m) => m.id == id);
  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 1));
  setUp(() {
    asr = PendingAsr();
    agent = ControlledAgent();
    container = ProviderContainer(overrides: [
      asrServiceProvider.overrideWithValue(asr),
      agentClientProvider.overrideWithValue(agent)
    ]);
    chat = container.read(chatProvider.notifier);
  });
  tearDown(() => container.dispose());
  Future<void> answer([String text = 'Synthetic answer']) async {
    agent.turns.last.output.add(text);
    await agent.turns.last.output.close();
    await tick();
  }

  test(
      'press creates visible item; release and ASR replace that same id before full tool reply',
      () async {
    final id = chat.beginVoiceInput()!;
    expect(state().isListening, true);
    expect(voice(id).voicePhase, VoiceInputPhase.recording);
    expect(asr.calls, isEmpty);
    expect(chat.finishVoiceInput(), id);
    expect(voice(id).voicePhase, VoiceInputPhase.preparing);
    expect(state().isListening, false);
    final work =
        chat.handleVoiceInput(Uint8List.fromList([1, 2]), voiceMessageId: id);
    await tick();
    expect(voice(id).voicePhase, VoiceInputPhase.transcribing);
    asr.calls.single.complete('Synthetic question');
    await tick();
    expect(voice(id).text, 'Synthetic question');
    expect(voice(id).voicePhase, VoiceInputPhase.ready);
    expect(state().messages.where((m) => m.isUser), hasLength(1));
    agent.turns.single.output.add('Checking…');
    agent.turns.single.progress?.call('Hermes 正在查询工具…');
    await tick();
    expect(state().isGenerating, true);
    expect(state().generationStatus, contains('工具'));
    await answer('Final result');
    await work;
    expect(state().messages.last.text, 'Checking…Final result');
    expect(voice(id).voiceDuration, isNotNull);
  });
  test('cancelling recording does not upload and never becomes model history',
      () async {
    final id = chat.beginVoiceInput()!;
    chat.cancelVoiceInput(id);
    expect(voice(id).voicePhase, VoiceInputPhase.cancelled);
    expect(state().isListening, false);
    await chat.handleVoiceInput(Uint8List.fromList([1]), voiceMessageId: id);
    expect(asr.calls, isEmpty);
    final next = chat.sendUserMessage('Next');
    await tick();
    expect(agent.turns.single.history, isEmpty);
    await answer();
    await next;
  });
  test('empty capture shows failure without calling either endpoint', () async {
    final id = chat.beginVoiceInput()!;
    chat.finishVoiceInput();
    await chat.handleVoiceInput(Uint8List(0), voiceMessageId: id);
    expect(voice(id).voicePhase, VoiceInputPhase.failed);
    expect(voice(id).text, contains('有效音频'));
    expect(asr.calls, isEmpty);
    expect(agent.turns, isEmpty);
  });
  test('ASR failure is not sent as user speech and queue recovers', () async {
    final id = chat.beginVoiceInput()!;
    chat.finishVoiceInput();
    final failed =
        chat.handleVoiceInput(Uint8List.fromList([1]), voiceMessageId: id);
    await tick();
    asr.calls.single.completeError(StateError('synthetic-private-server-url'));
    await failed;
    expect(voice(id).voicePhase, VoiceInputPhase.failed);
    expect(voice(id).text, isNot(contains('private-server')));
    expect(agent.turns, isEmpty);
    final next = chat.sendUserMessage('Valid text');
    await tick();
    expect(agent.turns.single.history, isEmpty);
    await answer();
    await next;
  });
  test('clearing while ASR runs cannot resurrect late text or start Hermes',
      () async {
    final id = chat.beginVoiceInput()!;
    chat.finishVoiceInput();
    final work =
        chat.handleVoiceInput(Uint8List.fromList([1]), voiceMessageId: id);
    await tick();
    chat.clearMessages();
    asr.calls.single.complete('Late synthetic transcript');
    await work;
    expect(state().messages, isEmpty);
    expect(state().isListening, false);
    expect(agent.turns, isEmpty);
  });
  test('clearing while still held discards old release payload', () async {
    final id = chat.beginVoiceInput()!;
    chat.clearMessages();
    chat.finishVoiceInput();
    await chat.handleVoiceInput(Uint8List.fromList([1]), voiceMessageId: id);
    expect(state().messages, isEmpty);
    expect(asr.calls, isEmpty);
  });
  test(
      'two voice turns remain ordered, keep reply adjacent, and preserve complete history',
      () async {
    final a = chat.beginVoiceInput()!;
    chat.finishVoiceInput();
    final first =
        chat.handleVoiceInput(Uint8List.fromList([1]), voiceMessageId: a);
    await tick();
    final b = chat.beginVoiceInput()!;
    chat.finishVoiceInput();
    final second =
        chat.handleVoiceInput(Uint8List.fromList([2]), voiceMessageId: b);
    expect(voice(b).voicePhase, VoiceInputPhase.queued);
    expect(asr.calls, hasLength(1));
    asr.calls.first.complete('First voice');
    await tick();
    expect(state().messages.map((m) => m.id).toList().indexOf('${a}_reply'),
        state().messages.map((m) => m.id).toList().indexOf(a) + 1);
    expect(asr.calls, hasLength(1));
    await answer('First full answer');
    await first;
    await tick();
    expect(asr.calls, hasLength(2));
    asr.calls.last.complete('Second voice');
    await tick();
    expect(agent.turns.last.history, [
      {'role': 'user', 'content': 'First voice'},
      {'role': 'assistant', 'content': 'First full answer'}
    ]);
    await answer('Second answer');
    await second;
  });
  test('new held recording remains listening while earlier ASR finishes',
      () async {
    final a = chat.beginVoiceInput()!;
    chat.finishVoiceInput();
    final first =
        chat.handleVoiceInput(Uint8List.fromList([1]), voiceMessageId: a);
    await tick();
    final b = chat.beginVoiceInput()!;
    asr.calls.single.complete('First');
    await tick();
    expect(state().isListening, true);
    expect(voice(b).voicePhase, VoiceInputPhase.recording);
    await answer();
    await first;
    expect(state().isListening, true);
    chat.cancelVoiceInput(b);
  });
  test('new chat can proceed while an old cleared ASR request is still pending',
      () async {
    final old = chat.handleVoiceInput(Uint8List.fromList([1]));
    await tick();
    chat.clearMessages();
    final next = chat.sendUserMessage('New session question');
    await tick();
    expect(agent.turns.single.input, 'New session question');
    await answer('New session answer');
    await next;
    asr.calls.single.complete('Discarded old voice');
    await old;
    expect(agent.turns, hasLength(1));
    expect(state().messages.map((m) => m.text).toList(),
        ['New session question', 'New session answer']);
  });

  test('duplicate release cannot submit the same voice twice', () async {
    final id = chat.beginVoiceInput()!;
    expect(chat.beginVoiceInput(), id);
    chat.finishVoiceInput();
    final first =
        chat.handleVoiceInput(Uint8List.fromList([1]), voiceMessageId: id);
    await chat.handleVoiceInput(Uint8List.fromList([1]), voiceMessageId: id);
    await tick();
    expect(asr.calls, hasLength(1));
    asr.calls.single.complete('Once');
    await tick();
    await answer();
    await first;
  });
  test('text follow-up waits for voice ASR and full reply', () async {
    final voiceWork = chat.handleVoiceInput(Uint8List.fromList([1]));
    final textWork = chat.sendUserMessage('Follow-up');
    await tick();
    expect(agent.turns, isEmpty);
    asr.calls.single.complete('Voice');
    await tick();
    await answer('Full voice answer');
    await voiceWork;
    await tick();
    expect(agent.turns.last.input, 'Follow-up');
    expect(agent.turns.last.history.last['content'], 'Full voice answer');
    await answer();
    await textWork;
  });
}

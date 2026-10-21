import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'package:sunmate_app/core/hardware/hardware_device_driver.dart';
import 'package:sunmate_app/core/hardware/hardware_device_factory.dart';
import 'package:sunmate_app/providers/button_action_provider.dart';
import 'package:sunmate_app/providers/device_provider.dart';
import 'package:sunmate_app/providers/server_config_provider.dart';
import 'package:sunmate_app/views/chat_page.dart';
import 'package:sunmate_app/views/voice_input_bubble.dart';
import 'chat_reply_lifecycle_test.dart' show ControlledAgent;
import 'voice_input_lifecycle_test.dart' show PendingAsr;
import 'recorder_management_widget_test.dart' show captureUi, screenshot;

class InputDriver implements AiNote6095Driver {
  final buttons = StreamController<DeviceButtonEvent>.broadcast(sync: true);
  final audio = StreamController<AudioDataPacket>.broadcast(sync: true);
  final changes = StreamController<void>.broadcast(sync: true);
  @override
  Stream<DeviceButtonEvent> get buttonEvents => buttons.stream;
  @override
  Stream<AudioDataPacket> get audioStream => audio.stream;
  @override
  Stream<void> get stateChanges => changes.stream;
  @override
  bool get isConnected => true;
  @override
  bool get isRecording => false;
  @override
  bool get isPaused => false;
  @override
  int get batteryLevel => 76;
  @override
  String get displayName => 'Synthetic card';
  @override
  String get snNumber => 'AB00000000000001';
  @override
  HardwareDeviceType get deviceType => HardwareDeviceType.ainote6095Ble;
  @override
  void simulateButtonEvent(ButtonActionType action) => press(action);
  void press(ButtonActionType action) =>
      buttons.add(DeviceButtonEvent(buttonId: 1, action: action));
  void packet() => audio.add(AudioDataPacket(
      bytes: Uint8List.fromList([1, 2, 3]),
      format: AudioEncodingFormat.oggOpus));
  Future<void> close() async {
    await buttons.close();
    await audio.close();
    await changes.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class InputFactory implements HardwareDeviceFactory {
  @override
  final AiNote6095Driver bleDriver;
  InputFactory(this.bleDriver);
  @override
  HardwareDeviceDriver get activeDriver => bleDriver;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (captureUi)
      for (final font in {
        'ManagementFixture':
            '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
        'MaterialIcons':
            '/private/tmp/sunmate-flutter-sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries)
        await (FontLoader(font.key)
              ..addFont(File(font.value)
                  .readAsBytes()
                  .then((b) => b.buffer.asByteData())))
            .load();
  });
  late InputDriver driver;
  late PendingAsr asr;
  late ControlledAgent agent;
  late ProviderContainer container;
  setUp(() {
    driver = InputDriver();
    asr = PendingAsr();
    agent = ControlledAgent();
    container = ProviderContainer(overrides: [
      deviceFactoryProvider.overrideWithValue(InputFactory(driver)),
      asrServiceProvider.overrideWithValue(asr),
      agentClientProvider.overrideWithValue(agent),
    ]);
  });
  tearDown(() async {
    container.dispose();
    await driver.close();
  });
  Future<GlobalKey> open(WidgetTester tester,
      {Brightness brightness = Brightness.light,
      double scale = 1,
      bool reduceMotion = false,
      Size size = const Size(390, 844)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: ThemeData(
                useMaterial3: true,
                fontFamily: captureUi ? 'ManagementFixture' : null,
                colorScheme: ColorScheme.fromSeed(
                    seedColor: const Color(0xffff8c00),
                    brightness: brightness)),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: reduceMotion),
                child: child!),
            home: RepaintBoundary(key: key, child: const ChatPage()))));
    await tester.pump();
    return key;
  }

  Future<void> step(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
  }

  testWidgets(
      'physical press shows animation; release stays visible during ASR then replaces same bubble',
      (tester) async {
    final key = await open(tester);
    driver.press(ButtonActionType.pressDown);
    await step(tester);
    expect(find.text('正在录音'), findsOneWidget);
    expect(find.text('正在录音，松开发送'), findsOneWidget);
    final element = tester.element(find.byType(VoiceInputBubble));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)));
    await tester.pump(const Duration(seconds: 1));
    final counter = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(VoiceInputBubble), matching: find.byType(Text)))
        .map((t) => t.data ?? '')
        .singleWhere((text) => RegExp(r'^\d+:\d\d$').hasMatch(text));
    expect(counter, isNot('00:00'));

    await screenshot(tester, key, 'ptt-physical-recording');
    driver.packet();
    driver.press(ButtonActionType.release);
    await step(tester);
    expect(find.text('正在转成文字…'), findsOneWidget);
    expect(tester.element(find.byType(VoiceInputBubble)), same(element));
    await screenshot(tester, key, 'ptt-transcribing');
    asr.calls.single.complete('Synthetic weather question');
    await step(tester);
    expect(find.text('Synthetic weather question'), findsOneWidget);
    expect(tester.element(find.byType(VoiceInputBubble)), same(element));
    agent.turns.single.output.add('Checking weather…');
    agent.turns.single.progress?.call('Hermes 正在查询工具…');
    await step(tester);
    expect(find.text('Hermes 正在查询工具…'), findsNWidgets(2));
    await screenshot(tester, key, 'ptt-tool-wait');
    agent.turns.single.output.add('Complete synthetic result');
    await agent.turns.single.output.close();
    await step(tester);
    expect(find.text('Checking weather…Complete synthetic result'),
        findsOneWidget);
    expect(find.text('Hermes 正在查询工具…'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'screen button uses same lifecycle and empty capture explicitly fails',
      (tester) async {
    await open(tester);
    final gesture =
        await tester.startGesture(tester.getCenter(find.text('按住说话')));
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.text('正在录音'), findsOneWidget);
    await gesture.up();
    await step(tester);
    expect(find.text('语音未发送'), findsOneWidget);
    expect(asr.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'large text dark recording, cancellation and reduced motion remain usable',
      (tester) async {
    final key = await open(tester,
        brightness: Brightness.dark,
        scale: 1.5,
        reduceMotion: true,
        size: const Size(360, 740));
    driver.press(ButtonActionType.pressDown);
    await step(tester);
    expect(find.text('正在录音'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await screenshot(tester, key, 'ptt-dark-large-recording');
    driver.press(ButtonActionType.cancel);
    await step(tester);
    expect(find.text('录音已取消'), findsOneWidget);
    expect(asr.calls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'ASR failure shows error bubble; clearing pending ASR discards late result',
      (tester) async {
    final key = await open(tester);
    driver.press(ButtonActionType.pressDown);
    driver.packet();
    driver.press(ButtonActionType.release);
    await step(tester);
    asr.calls.single.completeError(StateError('synthetic-private-detail'));
    await step(tester);
    expect(find.text('语音未发送'), findsOneWidget);
    expect(agent.turns, isEmpty);
    await screenshot(tester, key, 'ptt-asr-failure');
    driver.press(ButtonActionType.pressDown);
    driver.packet();
    driver.press(ButtonActionType.release);
    await step(tester);
    await tester.tap(find.byTooltip('清空对话'));
    await step(tester);
    asr.calls.last.complete('Late synthetic speech');
    await step(tester);
    expect(find.byType(VoiceInputBubble), findsNothing);
    expect(agent.turns, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'driver rebind cancels unfinished recording and rejects stale audio',
      (tester) async {
    await open(tester);
    driver.press(ButtonActionType.pressDown);
    await step(tester);
    container.read(buttonActionProvider.notifier).rebindDriver();
    driver.packet();
    driver.press(ButtonActionType.release);
    await step(tester);
    expect(find.text('录音已取消'), findsOneWidget);
    expect(asr.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}

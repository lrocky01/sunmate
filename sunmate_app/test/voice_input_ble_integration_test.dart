import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmate_app/core/ble/ble_constants.dart';
import 'package:sunmate_app/core/hardware/ainote_6095_driver.dart';
import 'package:sunmate_app/providers/button_action_provider.dart';
import 'package:sunmate_app/providers/chat_provider.dart';
import 'package:sunmate_app/providers/device_provider.dart';
import 'package:sunmate_app/providers/server_config_provider.dart';
import 'ble_connection_test.dart' show TestBlePlatform;
import 'recorder_authentication_test.dart' show MemoryKeyStore, shared;
import 'telink_recording_test.dart' show start, frame;
import 'chat_reply_lifecycle_test.dart' show ControlledAgent;
import 'voice_input_lifecycle_test.dart' show PendingAsr;
import 'voice_input_widget_test.dart' show InputFactory;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = TestBlePlatform();
  late AiNote6095Driver driver;
  late ProviderContainer container;
  late PendingAsr asr;
  late ControlledAgent agent;
  late MemoryKeyStore keys;
  late BluetoothDevice device;
  setUpAll(() => FlutterBluePlusPlatform.instance = platform);
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 25));
  void event(List<int> bytes) =>
      platform.notify(device.remoteId, BleConstants.charDeviceEvent, bytes);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    platform.reset();
    keys = MemoryKeyStore()..value = base64Encode(shared);
    driver = AiNote6095Driver(
        keyStore: keys,
        authenticationTimeout: const Duration(milliseconds: 150));
    asr = PendingAsr();
    agent = ControlledAgent();
    container = ProviderContainer(overrides: [
      deviceFactoryProvider.overrideWithValue(InputFactory(driver)),
      asrServiceProvider.overrideWithValue(asr),
      agentClientProvider.overrideWithValue(agent)
    ]);
    container.read(buttonActionProvider);
    platform.authenticate = true;
    device = BluetoothDevice.fromId('57000000-0000-0000-0000-000000000001');
    expect(await driver.connectDevice(device), true);
    await settle();
  });
  tearDown(() async {
    container.dispose();
    await driver.dispose();
  });
  test(
      'AES-authenticated binary recording reaches visible phase and passes the exact full Ogg to ASR',
      () async {
    event(start(1792496000000));
    await settle();
    expect(container.read(chatProvider).isListening, true);
    expect(container.read(chatProvider).messages.last.voicePhase,
        VoiceInputPhase.recording);
    platform.notify(device.remoteId, BleConstants.charOpusAudioData, frame);
    event([0xaa, 0x55, 2, 0]);
    await settle();
    expect(asr.calls, hasLength(1));
    expect(asr.audio.single, driver.lastRecordedBytes);
    expect(ascii.decode(asr.audio.single.take(4).toList()), 'OggS');
    expect(container.read(chatProvider).messages.last.voicePhase,
        VoiceInputPhase.transcribing);
    asr.calls.single.complete('Synthetic speech');
    await settle();
    agent.turns.single.output.add('Complete synthetic answer');
    await agent.turns.single.output.close();
    await settle();
    expect(container.read(chatProvider).messages.last.text,
        'Complete synthetic answer');
    expect(keys.writes, 0);
    expect(driver.isConnected, true);
  });
  test(
      'empty or truncated real driver recording cancels UI and never starts ASR',
      () async {
    event(start(1792496000001));
    await settle();
    event([0xaa, 0x55, 2, 0]);
    await settle();
    final state = container.read(chatProvider);
    expect(state.isListening, false);
    expect(state.messages.last.voicePhase, VoiceInputPhase.cancelled);
    expect(asr.calls, isEmpty);
    expect(agent.turns, isEmpty);
    expect(keys.writes, 0);
  });
}

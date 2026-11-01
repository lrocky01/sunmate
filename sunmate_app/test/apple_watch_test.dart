import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/hardware/apple_watch_driver.dart';
import 'package:sunmate_app/core/hardware/hardware_device_driver.dart';
import 'package:sunmate_app/core/recordings/apple_watch_controller.dart';

class FakeWatchNative implements AppleWatchNative {
  @override
  bool supported = true;
  VoidCallback? changed;
  final calls = <String>[];
  final args = <Map<String, dynamic>?>[];
  Map<String, dynamic> state = {
    'supported': true,
    'enabled': false,
    'reachable': false,
    'backgroundSync': false,
    'sessions': []
  };
  Map<String, dynamic> health = {
    'enabled': false,
    'types': [],
    'samples': [],
    'externalSharing': false
  };
  Uint8List bytes = Uint8List(0);
  Completer<dynamic>? healthGate;
  @override
  void onChanged(VoidCallback? callback) {
    changed = callback;
  }

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? value]) async {
    calls.add(method);
    args.add(value);
    switch (method) {
      case 'snapshot':
        return state;
      case 'configure':
        state = {...state, ...value!};
        return true;
      case 'healthSnapshot':
        return healthGate?.future ?? health;
      case 'healthConfigure':
        health = {...health, ...value!};
        return true;
      case 'readPart':
        return bytes;
      default:
        return true;
    }
  }
}

Map<String, dynamic> watchPart({int part = 0, int offset = 0}) => {
      'source': 'WATCH_${'a' * 32}',
      'session': 1793491200000,
      'purpose': 'meeting',
      'part': part,
      'frames': 160,
      'offsetFrames': offset,
      'bytes': 364,
      'sha256': 'b' * 64,
      'started': '2026-11-01T00:00:00Z',
    };

void main() {
  test(
      'default receive is off and initialization sends no settings or network request',
      () async {
    final n = FakeWatchNative();
    final driver = AppleWatchDriver(native: n);
    final controller = AppleWatchController(driver);
    await controller.refresh();
    expect(controller.enabled, false);
    expect(controller.backgroundSync, false);
    expect(n.calls, ['snapshot']);
    expect(driver.deviceType, HardwareDeviceType.appleWatch);
    expect(await driver.startRecording(), false);
    expect(await driver.sendAncsConfig(enable: true), false);
    expect(n.calls, ['snapshot']);
    controller.dispose();
    await driver.dispose();
  });
  test('paired or installed does not imply immediate reachability or recording',
      () async {
    final n = FakeWatchNative()
      ..state = {
        'supported': true,
        'enabled': true,
        'paired': true,
        'watchAppInstalled': true,
        'reachable': false,
        'sessions': []
      };
    final d = AppleWatchDriver(native: n);
    await d.refresh();
    expect(d.isConnected, false);
    expect(d.isRecording, false);
    n.state['reachable'] = true;
    await d.refresh();
    expect(d.isConnected, true);
    expect(d.isRecording, false);
    await d.dispose();
  });
  test('manifest requires contiguous sample positions and matching purpose',
      () {
    final v = {
      'source': 'WATCH_${'a' * 32}',
      'session': 1793491200000,
      'purpose': 'meeting',
      'started': '2026-11-01T00:00:00Z',
      'ended': '2026-11-01T00:01:00Z',
      'interrupted': false,
      'parts': [watchPart(), watchPart(part: 1, offset: 160)]
    };
    expect(WatchSession(v).complete, true);
    expect(WatchSession({...v, 'interrupted': true}).complete, false);
    expect(
        () => WatchSession({
              ...v,
              'parts': [watchPart(), watchPart(part: 1, offset: 161)]
            }),
        throwsFormatException);
    expect(() => WatchPart({...watchPart(), 'source': '../outside'}),
        throwsFormatException);
    expect(
        () => WatchPart({...watchPart(), 'frames': -1}), throwsFormatException);
  });
  test('health has no external-sharing path and missing samples stay missing',
      () async {
    final n = FakeWatchNative();
    final driver = AppleWatchDriver(native: n);
    final controller = AppleWatchController(driver);
    await controller.refresh();
    expect(await controller.configureHealth(true, {}), false);
    expect(await controller.configureHealth(true, {'heart'}), true);
    expect(controller.healthEnabled, true);
    expect(controller.healthSamples, isEmpty);
    expect(
        n.calls.where((v) =>
            v.contains('upload') || v.contains('asr') || v.contains('hermes')),
        isEmpty);
    final args = n.args[n.calls.indexOf('healthConfigure')]!;
    expect(args, {
      'enabled': true,
      'types': ['heart']
    });
    expect(await controller.configureHealth(false, {'heart'}), true);
    expect(controller.healthSamples, isEmpty);
    controller.dispose();
    await driver.dispose();
  });
  test('invalid health values are not presented as real readings', () async {
    final n = FakeWatchNative()
      ..health = {
        'enabled': true,
        'types': ['heart'],
        'samples': [
          {
            'kind': 'pressure',
            'value': 99,
            'to': '2026-11-01T00:00:00Z',
            'source': 'synthetic'
          }
        ]
      };
    final driver = AppleWatchDriver(native: n);
    final controller = AppleWatchController(driver);
    await controller.refresh();
    await controller.refreshHealth();
    expect(controller.healthSamples, isEmpty);
    expect(controller.message, contains('暂不可读'));
    controller.dispose();
    await driver.dispose();
  });
  test('bad WAV hash is rejected before sending to chat', () async {
    final n = FakeWatchNative()..bytes = Uint8List(364);
    final d = AppleWatchDriver(native: n);
    final controller = AppleWatchController(d);
    await controller.refresh();
    await expectLater(
        controller.audio(WatchPart(watchPart())), throwsFormatException);
    controller.dispose();
    await d.dispose();
  });
  test('disabling health ignores a late outstanding sample response', () async {
    final n = FakeWatchNative();
    final d = AppleWatchDriver(native: n);
    final c = AppleWatchController(d);
    await c.refresh();
    await c.configureHealth(true, {'heart'});
    n.healthGate = Completer<dynamic>();
    final pending = c.refreshHealth();
    await Future<void>.delayed(Duration.zero);
    await c.configureHealth(false, {'heart'});
    n.healthGate!.complete({
      'enabled': true,
      'types': ['heart'],
      'samples': []
    });
    await pending;
    expect(c.healthEnabled, false);
    expect(c.healthSamples, isEmpty);
    c.dispose();
    await d.dispose();
  });
}

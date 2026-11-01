import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'hardware_device_driver.dart';

abstract interface class AppleWatchNative {
  bool get supported;
  Future<dynamic> call(String method, [Map<String, dynamic>? args]);
  void onChanged(VoidCallback? callback);
}

class MethodChannelAppleWatch implements AppleWatchNative {
  static const _channel = MethodChannel('sunmate/apple_watch');
  @override
  bool get supported => !kIsWeb && Platform.isIOS;
  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? args]) => _channel
      .invokeMethod<dynamic>(method, args)
      .timeout(const Duration(seconds: 15));
  @override
  void onChanged(VoidCallback? callback) {
    if (supported) {
      _channel.setMethodCallHandler(callback == null
          ? null
          : (call) async {
              if (call.method == 'changed') callback();
            });
    }
  }
}

/// Apple-managed paired application transport, never the card's BLE protocol.
class AppleWatchDriver implements HardwareDeviceDriver {
  final AppleWatchNative native;
  final _state = StreamController<void>.broadcast();
  final _buttons = StreamController<DeviceButtonEvent>.broadcast();
  final _audio = StreamController<AudioDataPacket>.broadcast();
  Map<String, dynamic> snapshot = {};
  bool disposed = false;
  AppleWatchDriver({AppleWatchNative? native})
      : native = native ?? MethodChannelAppleWatch() {
    this.native.onChanged(() => unawaited(refresh()));
  }
  Future<void> refresh() async {
    if (disposed || !native.supported) return;
    try {
      final result = await native.call('snapshot');
      if (result is! Map) throw const FormatException();
      if (!disposed) snapshot = Map<String, dynamic>.from(result);
    } catch (_) {
      if (!disposed)
        snapshot = {...snapshot, 'reachable': false, 'message': '手表原生接收尚未就绪。'};
    }
    if (!disposed) _state.add(null);
  }

  @override
  HardwareDeviceType get deviceType => HardwareDeviceType.appleWatch;
  @override
  String get displayName => 'Apple Watch';
  @override
  String get snNumber =>
      '--'; // No access to or invented hardware serial number.
  @override
  bool get isConnected =>
      snapshot['enabled'] == true && snapshot['reachable'] == true;
  @override
  int get batteryLevel =>
      0; // Not reported: UI must not label this a measured 0%.
  @override
  bool get isRecording =>
      false; // Remote acquisition is not inferred from reachability.
  @override
  bool get isPaused => false;
  @override
  Stream<void> get stateChanges => _state.stream;
  @override
  Stream<DeviceButtonEvent> get buttonEvents => _buttons.stream;
  @override
  Stream<AudioDataPacket> get audioStream => _audio.stream;
  @override
  Future<bool> connect() async {
    await refresh();
    return isConnected;
  }

  @override
  Future<void> disconnect() async {
    snapshot = {...snapshot, 'reachable': false};
    if (!disposed) _state.add(null);
  }

  // Start/stop on the watch. Never report command delivery as actual recording.
  @override
  Future<bool> startRecording() async => false;
  @override
  Future<bool> stopRecording() async => false;
  @override
  Future<bool> pauseRecording() async => false;
  @override
  Future<bool> resumeRecording() async => false;
  @override
  Future<bool> syncTime() async => false;
  @override
  Future<bool> sendAncsConfig({required bool enable, int mode = 3}) async =>
      false;
  @override
  Future<void> dispose() async {
    disposed = true;
    native.onChanged(null);
    unawaited(_state.close());
    unawaited(_buttons.close());
    unawaited(_audio.close());
  }
}

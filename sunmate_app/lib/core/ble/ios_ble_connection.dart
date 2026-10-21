import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

/// 与本地 darwin 插件共享 CBCentralManager，不建立第二条原生连接。
class IosBleConnection {
  static const _methods = MethodChannel('sunmate/ble_connection');
  static const _events = EventChannel('sunmate/ble_connection_events');
  final bool isSupported;
  final Duration timeout;
  IosBleConnection(
      {bool? isSupported, this.timeout = const Duration(seconds: 5)})
      : isSupported = isSupported ?? Platform.isIOS;

  Stream<Map<String, dynamic>> get events => isSupported
      ? _events
          .receiveBroadcastStream()
          .map((value) => Map<String, dynamic>.from(value as Map))
      : const Stream.empty();

  Future<void> configure(String remoteId, {required bool requiresAncs}) async {
    if (!isSupported) return;
    await _methods.invokeMethod<void>('configure', {
      'remote_id': remoteId,
      'requires_ancs': requiresAncs,
    }).timeout(timeout);
  }

  Future<Map<String, dynamic>> diagnostics(String remoteId) async {
    if (!isSupported) return {};
    final value = await _methods.invokeMapMethod<String, dynamic>(
        'diagnostics', {'remote_id': remoteId}).timeout(timeout);
    return value ?? {};
  }

  Future<void> armBackground(String remoteId, Map<String, dynamic> plan) async {
    if (!isSupported) return;
    await _methods.invokeMethod<void>('background_arm', {'remote_id': remoteId, ...plan}).timeout(timeout);
  }
  Future<void> enableRestoration(bool enabled) async {
    if (!isSupported) return;
    await _methods.invokeMethod<void>('background_restore', {'enabled': enabled}).timeout(timeout);
  }
}

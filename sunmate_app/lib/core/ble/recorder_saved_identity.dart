import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'ble_protocol.dart';

/// 仅保存重连路由元数据；不包含业务密钥，也不能替代本次 AES 验证。
class RecorderSavedIdentity {
  final String remoteId;
  final String serialNumber;
  final String deviceName;
  final RecorderProtocol protocol;
  final bool previouslyVerified;

  RecorderSavedIdentity({
    required this.remoteId,
    required this.serialNumber,
    required this.deviceName,
    required this.protocol,
    this.previouslyVerified = false,
  }) {
    if (remoteId.isEmpty ||
        remoteId.length > 128 ||
        RegExp(r'[\x00-\x20]').hasMatch(remoteId) ||
        !RegExp(r'^[A-Z]{2}[0-9]{14}$').hasMatch(serialNumber) ||
        deviceName.isEmpty ||
        deviceName.length > 64 ||
        RegExp(r'[\x00-\x1f]').hasMatch(deviceName)) {
      throw const FormatException('已保存设备身份格式无效');
    }
  }

  bool sameDevice(RecorderSavedIdentity other) =>
      remoteId.toLowerCase() == other.remoteId.toLowerCase() &&
      serialNumber == other.serialNumber &&
      protocol == other.protocol;

  Map<String, Object> toJson() => {
        'remoteId': remoteId,
        'sn': serialNumber,
        'name': deviceName,
        'protocol': protocol.name,
        'verified': previouslyVerified,
      };

  static RecorderSavedIdentity fromJson(Object? value) {
    if (value is! Map ||
        value['remoteId'] is! String ||
        value['sn'] is! String ||
        value['name'] is! String ||
        value['verified'] is! bool ||
        !RecorderProtocol.values.any((p) => p.name == value['protocol'])) {
      throw const FormatException('已保存设备身份格式无效');
    }
    return RecorderSavedIdentity(
        remoteId: value['remoteId'],
        serialNumber: value['sn'],
        deviceName: value['name'],
        protocol: RecorderProtocol.values
            .singleWhere((p) => p.name == value['protocol']),
        previouslyVerified: value['verified']);
  }
}

class RecorderRecoveryCandidate {
  final RecorderSavedIdentity identity;
  final bool systemConnected;
  const RecorderRecoveryCandidate(this.identity,
      {required this.systemConnected});
}

class RecorderIdentityStore {
  static const storageKey = 'sunmate_recorder_identity_routes_v1';
  Future<void> _writes = Future.value();

  Future<List<RecorderSavedIdentity>> readAll() async {
    final prefs = await SharedPreferences.getInstance();
    final records = prefs.getStringList(storageKey) ?? [];
    if (records.length > 32) throw StateError('本机设备身份记录过多，未自动选择');
    try {
      final result = records
          .map((s) => RecorderSavedIdentity.fromJson(jsonDecode(s)))
          .toList();
      if (result.map((r) => r.remoteId.toLowerCase()).toSet().length !=
          result.length) {
        throw const FormatException('本机设备身份记录重复');
      }
      return List.unmodifiable(result);
    } catch (_) {
      throw const FormatException('本机设备身份记录损坏，未自动选择；业务密钥保持');
    }
  }

  Future<void> save(RecorderSavedIdentity identity) {
    final operation = _writes.then((_) async {
      final records = await readAll();
      final existing = records
          .where((r) =>
              r.remoteId.toLowerCase() == identity.remoteId.toLowerCase())
          .toList();
      if (existing.isNotEmpty && !existing.single.sameDevice(identity)) {
        throw StateError('本机 UUID 对应的 SN 或协议冲突，未覆盖身份记录');
      }
      if (existing.isEmpty && records.length >= 32) {
        throw StateError('本机设备身份记录已满，未覆盖其它设备');
      }
      final keptVerified = identity.previouslyVerified ||
          (existing.isNotEmpty && existing.single.previouslyVerified);
      final saved = RecorderSavedIdentity(
          remoteId: identity.remoteId,
          serialNumber: identity.serialNumber,
          deviceName: identity.deviceName,
          protocol: identity.protocol,
          previouslyVerified: keptVerified);
      final next = [
        ...records.where(
            (r) => r.remoteId.toLowerCase() != identity.remoteId.toLowerCase()),
        saved
      ];
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setStringList(
          storageKey, next.map((r) => jsonEncode(r.toJson())).toList())) {
        throw StateError('保存设备重连信息失败；未改动业务密钥');
      }
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }
}

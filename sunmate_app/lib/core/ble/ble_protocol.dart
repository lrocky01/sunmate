import 'dart:convert';
import 'dart:typed_data';
import 'ble_constants.dart';

enum RecorderProtocol { telink, aiNote6095 }

class RecorderProfile {
  final RecorderProtocol protocol;
  final String service;
  final String command;
  final String event;
  final String audio;
  final bool withoutResponse;

  const RecorderProfile(this.protocol, this.service, this.command, this.event,
      this.audio, this.withoutResponse);

  static const telink = RecorderProfile(
      RecorderProtocol.telink,
      BleConstants.serviceOpus,
      BleConstants.charAppCmdWrite,
      BleConstants.charDeviceEvent,
      BleConstants.charOpusAudioData,
      true);
  static const aiNote = RecorderProfile(
      RecorderProtocol.aiNote6095,
      BleConstants.serviceAiNote,
      BleConstants.charAiNoteCommand,
      BleConstants.charAiNoteEvent,
      BleConstants.charAiNoteAudio,
      false);

  static RecorderProfile? identify(Map<String, Set<String>> services) {
    final matches = [telink, aiNote].where((profile) {
      final chars = services[profile.service];
      return chars != null &&
          [profile.command, profile.event, profile.audio].every(chars.contains);
    }).toList();
    return matches.length == 1 ? matches.single : null;
  }

  List<Uint8List> encodeJson(Uint8List payload, int maxWriteLength) {
    if (protocol == RecorderProtocol.telink) {
      // 官方 Telink 未定义 JSON 的应用层分片，禁止任意拆成独立命令。
      if (payload.length + 2 > maxWriteLength) {
        throw StateError('Telink 命令超过单次写入上限 $maxWriteLength');
      }
      return [
        Uint8List.fromList([0x11, 0x30, ...payload])
      ];
    }
    if (maxWriteLength < 5 || payload.length > 65535) {
      throw ArgumentError('AiNote TLV 长度或 MTU 无效');
    }
    final frames = <Uint8List>[];
    final firstSize = (maxWriteLength - 4).clamp(0, payload.length);
    frames.add(Uint8List.fromList([
      0xfc,
      0x01,
      payload.length >> 8,
      payload.length & 0xff,
      ...payload.sublist(0, firstSize),
    ]));
    var offset = firstSize;
    while (offset < payload.length) {
      final end = (offset + maxWriteLength - 2).clamp(0, payload.length);
      frames.add(
          Uint8List.fromList([0xfc, 0x88, ...payload.sublist(offset, end)]));
      offset = end;
    }
    return frames;
  }

  Uint8List encodeTime(DateTime now) {
    if (protocol == RecorderProtocol.telink) {
      final data = ByteData(6)
        ..setUint8(0, 0x11)
        ..setUint8(1, 0x29);
      data.setUint32(2, now.millisecondsSinceEpoch ~/ 1000, Endian.little);
      return data.buffer.asUint8List();
    }
    final data = ByteData(9)..setUint8(0, 0xe5);
    data.setUint32(1, now.millisecondsSinceEpoch ~/ 1000, Endian.big);
    data.setUint32(5, now.millisecondsSinceEpoch % 1000, Endian.big);
    return data.buffer.asUint8List();
  }
}

/// 只接受明确的官方 JSON 帧边界，不在任意二进制数据内搜索关键字。
class RecorderEventDecoder {
  final RecorderProtocol protocol;
  final List<int> _pending = [];
  int? _expectedLength;
  RecorderEventDecoder(this.protocol);

  void reset() {
    _pending.clear();
    _expectedLength = null;
  }

  Map<String, dynamic>? feed(List<int> packet) {
    if (packet.isEmpty) return null;
    if (protocol == RecorderProtocol.telink) {
      if (packet.length >= 5 &&
          packet[0] == 0xaa &&
          packet[1] == 0x55 &&
          packet[2] == 0x30) {
        reset();
        _pending.addAll(packet.sublist(5));
      } else if (_pending.isNotEmpty) {
        _pending.addAll(packet);
      } else {
        return null;
      }
    } else {
      if (packet.length >= 4 && packet[0] == 0xfc && packet[1] == 0x01) {
        reset();
        _expectedLength = (packet[2] << 8) | packet[3];
        _pending.addAll(packet.sublist(4));
      } else if (packet.length >= 2 &&
          packet[0] == 0xfc &&
          packet[1] == 0x88 &&
          _expectedLength != null) {
        _pending.addAll(packet.sublist(2));
      } else {
        return null;
      }
    }
    if (_pending.length > 8192 ||
        (_expectedLength != null && _pending.length > _expectedLength!)) {
      reset();
      throw const FormatException('设备事件长度超限');
    }
    if (_expectedLength != null && _pending.length < _expectedLength!)
      return null;
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(_pending));
    } on FormatException {
      if (_expectedLength != null ||
          (_pending.isNotEmpty && _pending.last == 0x7d)) {
        reset();
        rethrow;
      }
      return null;
    }
    reset();
    if (decoded is! Map<String, dynamic> || decoded['method'] is! String) {
      throw const FormatException('设备事件不是带 method 的 JSON 对象');
    }
    return decoded;
  }
}

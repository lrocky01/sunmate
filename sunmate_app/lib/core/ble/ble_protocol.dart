import 'dart:convert';
import 'dart:typed_data';
import 'ble_constants.dart';

enum RecorderProtocol { telink, aiNote6095 }

/// 失败详情只输出有限描述词和状态码，不序列化设备原始响应或凭据。
class RecorderFailureSummary {
  static final _words = {
    ...('already bound bind binding bond bonded paired pair device is has not '
            'need needs must please unbind first to this request failed failure '
            'error invalid param params parameter parameters timestamp time out '
            'timeout busy in progress mode denied rejected unsupported support '
            'unbound success identity authentication auth required mismatch '
            'missing user other owner different connected disconnect encrypted '
            'encryption active expired new old no permission verification code '
            'sign signature key secret shared local memory storage full bad value '
            'state unknown same remote protocol limit length format cancel '
            'cancelled canceled confirm account factory locked lock operation '
            'init ready unpair ble card registered false true null fail cannot '
            'can be a the of for with without by on and or reset')
        .split(' '),
    '设备已绑定',
    '已绑定',
    '重复绑定',
    '请求无效',
    '参数错误',
    '设备忙',
    '需要先解绑',
    '绑定失败',
    '已配对',
    '未进入配对模式',
  };

  static String describe(Map<String, dynamic> params) {
    final fields = <String>[];
    // 官方 Telink 依次取 error / reason / message / status；同时保留数字 code。
    for (final field in ['error', 'reason', 'message', 'status', 'code']) {
      if (!params.containsKey(field)) continue;
      final value = params[field];
      String summary;
      if (value == null) {
        summary = 'null';
      } else if (value is bool) {
        summary = '$value';
      } else if ((field == 'status' || field == 'code') &&
          (value is num || value is String) &&
          RegExp(r'^-?[0-9]{1,6}$').hasMatch('$value')) {
        summary = '$value';
      } else if (value is String && value.length <= 256) {
        summary = value
            .replaceAllMapped(
                RegExp(r'([a-z])([A-Z])'), (match) => '${match[1]} ${match[2]}')
            .replaceAll(RegExp(r'[^A-Za-z0-9_ .:\-\u4e00-\u9fff]'), ' ')
            .replaceAllMapped(
                RegExp(r'[A-Za-z0-9]+|[\u4e00-\u9fff]+'),
                (match) => _words.contains(match[0]!.toLowerCase())
                    ? match[0]!
                    : '[已隐藏]')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (summary.isEmpty) summary = '空文本';
      } else {
        summary = '内容已隐藏';
      }
      fields.add('$field=$summary');
    }
    return fields.isEmpty
        ? '设备未提供 error/reason/message/status/code'
        : fields.join('；');
  }
}

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

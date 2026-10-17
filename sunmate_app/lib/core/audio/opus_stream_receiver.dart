import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// Telink 实时流：两个 uint32 长度 + Opus + 扩展数据，可以跨 BLE 通知。
/// 与官方 OpusFrameAssembler 相同；不是 session/seq 四字节头。
class TelinkOpusFrames {
  final List<int> _pending = [];
  int get pendingBytes => _pending.length;
  void reset() => _pending.clear();

  List<Uint8List> feed(List<int> bytes) {
    if (_pending.length + bytes.length > 65536) {
      reset();
      throw const FormatException('音频分帧缓冲超限');
    }
    _pending.addAll(bytes);
    final frames = <Uint8List>[];
    final data = ByteData.sublistView(Uint8List.fromList(_pending));
    var offset = 0;
    while (_pending.length - offset >= 8) {
      bool plausible(int length, int extra) =>
          length > 0 && length <= 8192 && extra >= 0 && extra <= 8192;
      var length = data.getUint32(offset, Endian.little);
      var extra = data.getUint32(offset + 4, Endian.little);
      if (!plausible(length, extra)) {
        length = data.getUint32(offset, Endian.big);
        extra = data.getUint32(offset + 4, Endian.big);
      }
      if (!plausible(length, extra)) {
        offset++;
        continue;
      }
      final end = offset + 8 + length + extra;
      if (end > _pending.length) break;
      frames.add(Uint8List.fromList(
          _pending.sublist(offset + 8, offset + 8 + length)));
      offset = end;
    }
    if (offset > 0) _pending.removeRange(0, offset);
    return frames;
  }
}

/// 单声道 16k 输入，Ogg granule 统一用 48k 时钟。每包 960 样本、pre-skip
/// 312 与官方 nativeWritePacket/nativeCreate 参数一致。
class OggOpusStream {
  final int serial;
  int _sequence = 0;
  int _granule = 0;
  bool _started = false;
  bool _finished = false;
  OggOpusStream(this.serial);

  Uint8List start() {
    if (_started) throw StateError('音频容器已开始');
    _started = true;
    final head = ByteData(19);
    head.buffer.asUint8List().setRange(0, 8, ascii.encode('OpusHead'));
    head.setUint8(8, 1);
    head.setUint8(9, 1);
    head.setUint16(10, 312, Endian.little);
    head.setUint32(12, 16000, Endian.little);
    final vendor = utf8.encode('SunMate');
    final tags = BytesBuilder()..add(ascii.encode('OpusTags'));
    tags.add((ByteData(4)..setUint32(0, vendor.length, Endian.little))
        .buffer
        .asUint8List());
    tags.add(vendor);
    tags.add(Uint8List(4));
    return (BytesBuilder()
          ..add(_page(head.buffer.asUint8List(), 2))
          ..add(_page(tags.toBytes(), 0)))
        .toBytes();
  }

  Uint8List packet(Uint8List opus) {
    if (!_started || _finished || opus.isEmpty || opus.length > 8192) {
      throw StateError('音频包或容器状态无效');
    }
    _granule += 960;
    return _page(opus, 0);
  }

  Uint8List finish() {
    if (!_started || _finished) throw StateError('音频容器已结束或尚未开始');
    _finished = true;
    return _page(Uint8List(0), 4, emptyPage: true);
  }

  Uint8List _page(Uint8List payload, int flags, {bool emptyPage = false}) {
    final segments = emptyPage ? 0 : payload.length ~/ 255 + 1;
    final page = Uint8List(27 + segments + payload.length);
    final data = ByteData.sublistView(page);
    page.setRange(0, 4, ascii.encode('OggS'));
    page[5] = flags;
    data.setUint64(6, _granule, Endian.little);
    data.setUint32(14, serial & 0xffffffff, Endian.little);
    data.setUint32(18, _sequence++, Endian.little);
    page[26] = segments;
    for (var i = 0; i < segments; i++) {
      page[27 + i] = i == segments - 1 ? payload.length % 255 : 255;
    }
    page.setRange(27 + segments, page.length, payload);
    var crc = 0;
    for (final byte in page) {
      crc ^= byte << 24;
      for (var bit = 0; bit < 8; bit++) {
        crc = ((crc << 1) ^ ((crc & 0x80000000) != 0 ? 0x04c11db7 : 0)) &
            0xffffffff;
      }
    }
    data.setUint32(22, crc, Endian.little);
    return page;
  }
}

/// 仅在真实 voiceCmd start/release 会话内收集，并输出完整 Ogg/Opus 字节流。
class OpusStreamReceiver {
  final _audio = StreamController<Uint8List>.broadcast(sync: true);
  final _frames = TelinkOpusFrames();
  final _buffer = BytesBuilder();
  OggOpusStream? _ogg;
  int _packets = 0;
  int get packetCount => _packets;
  Stream<Uint8List> get audioStream => _audio.stream;

  void startCollecting({required int sessionId}) {
    cancel();
    _ogg = OggOpusStream(sessionId);
    _emit(_ogg!.start());
  }

  void feedBlePacket(Uint8List bytes) {
    final ogg = _ogg;
    if (ogg == null) return;
    for (final opus in _frames.feed(bytes)) {
      if (_buffer.length + opus.length + 128 > 32 * 1024 * 1024) {
        cancel();
        throw const FormatException('实时录音超过 32 MiB 限制');
      }
      _packets++;
      _emit(ogg.packet(opus));
    }
  }

  void _emit(Uint8List bytes) {
    _buffer.add(bytes);
    _audio.add(bytes);
  }

  Uint8List stopAndExport() {
    final ogg = _ogg;
    if (ogg == null) return Uint8List(0);
    if (_packets == 0 || _frames.pendingBytes != 0) {
      cancel();
      throw const FormatException('音频为空或末尾帧不完整，不提交转写');
    }
    _emit(ogg.finish());
    _ogg = null;
    return _buffer.takeBytes();
  }

  void cancel() {
    _ogg = null;
    _packets = 0;
    _frames.reset();
    _buffer.clear();
  }

  void dispose() {
    cancel();
    _audio.close();
  }
}

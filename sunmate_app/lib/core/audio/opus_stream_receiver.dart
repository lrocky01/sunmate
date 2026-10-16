import 'dart:async';
import 'dart:typed_data';

/// 实时音频帧解析模型
class OpusAudioPacket {
  final int sessionId;
  final int seq;
  final Uint8List opusData;

  OpusAudioPacket({
    required this.sessionId,
    required this.seq,
    required this.opusData,
  });
}

/// 录音卡实时 Opus 音频流重组器
class OpusStreamReceiver {
  final _audioPacketController = StreamController<OpusAudioPacket>.broadcast();
  Stream<OpusAudioPacket> get audioStream => _audioPacketController.stream;

  final List<Uint8List> _currentBuffer = [];
  bool _isCollecting = false;

  /// 开始采集音频流
  void startCollecting() {
    _currentBuffer.clear();
    _isCollecting = true;
  }

  /// 停止采集并返回合并的 Opus 裸流数据
  Uint8List stopAndExport() {
    _isCollecting = false;
    final builder = BytesBuilder();
    for (final chunk in _currentBuffer) {
      builder.add(chunk);
    }
    return builder.toBytes();
  }

  /// 处理来自 2B31 特征值 Notify 的原始蓝牙数据包
  void feedBlePacket(Uint8List rawBytes) {
    if (rawBytes.length < 4) return;
    final byteData = ByteData.sublistView(rawBytes);
    final sessionId = byteData.getUint16(0, Endian.little);
    final seq = byteData.getUint16(2, Endian.little);
    final opusPayload = rawBytes.sublist(4);

    final packet = OpusAudioPacket(
      sessionId: sessionId,
      seq: seq,
      opusData: opusPayload,
    );

    if (_isCollecting) {
      _currentBuffer.add(opusPayload);
    }
    _audioPacketController.add(packet);
  }

  void dispose() {
    _audioPacketController.close();
  }
}

import 'dart:typed_data';

/// 录音卡底层 TLV (Type-Length-Value) 协议封包与解包器
class BleTlvPacket {
  final int type;
  final Uint8List value;

  BleTlvPacket({required this.type, required this.value});

  /// 封装为二进制报文字节流: [2 字节 Type (小端)] + [2 字节 Length (小端)] + [Value 载荷]
  Uint8List toBytes() {
    final builder = BytesBuilder();
    final header = ByteData(4);
    header.setUint16(0, type, Endian.little);
    header.setUint16(2, value.length, Endian.little);
    builder.add(header.buffer.asUint8List());
    builder.add(value);
    return builder.toBytes();
  }

  /// 从二进制字节流中解析 TLV
  static BleTlvPacket? parse(Uint8List data) {
    if (data.length < 4) return null;
    final byteData = ByteData.sublistView(data);
    final type = byteData.getUint16(0, Endian.little);
    final length = byteData.getUint16(2, Endian.little);
    if (data.length < 4 + length) return null; // 长度不足
    final value = data.sublist(4, 4 + length);
    return BleTlvPacket(type: type, value: value);
  }
}

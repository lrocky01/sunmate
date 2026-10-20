import 'dart:convert';
import 'dart:typed_data';

/// 已实测的 AA5541 帧：长度 + ANCS Source(8) + ANCS Data Source。
/// 不含业务授权；调用方必须另行校验当前连接的真实身份。
class TelinkNotificationFrame {
  final int eventId;
  final int uid;
  final String appIdentifier;
  final String title;
  final String subtitle;
  final String message;
  final DateTime? timestamp;

  const TelinkNotificationFrame._(this.eventId, this.uid, this.appIdentifier,
      this.title, this.subtitle, this.message, this.timestamp);

  List<int> get deduplicationBytes => utf8.encode(jsonEncode(
      [appIdentifier, title, subtitle, message, timestamp?.toIso8601String()]));

  static TelinkNotificationFrame decode(List<int> bytes) {
    if (bytes.length < 18 ||
        bytes.length > 65540 ||
        bytes.any((b) => b < 0 || b > 255) ||
        !TelinkNotificationDecoder.isStart(bytes)) {
      throw const FormatException('notification_frame_size_or_header');
    }
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    if (data.getUint16(3, Endian.little) != bytes.length - 5) {
      throw const FormatException('notification_frame_length');
    }
    final uid = data.getUint32(9, Endian.little);
    if (bytes[13] != 0 || data.getUint32(14, Endian.little) != uid) {
      throw const FormatException('notification_command_or_uid');
    }
    final attributes = <int, List<int>>{};
    var offset = 18;
    while (offset < bytes.length) {
      if (bytes.length - offset < 3) {
        throw const FormatException('notification_attribute_header');
      }
      final id = bytes[offset];
      final length = data.getUint16(offset + 1, Endian.little);
      offset += 3;
      if (length > bytes.length - offset) {
        throw const FormatException('notification_attribute_length');
      }
      // 固件实测会重复返回 255/0；未知属性按长度跳过。
      if (id <= 5) {
        if (attributes.containsKey(id)) {
          throw const FormatException('notification_duplicate_attribute');
        }
        attributes[id] = bytes.sublist(offset, offset + length);
      }
      offset += length;
    }
    // 修改/移除没有实测语义，不将它们转换成新的正文通知。
    if (bytes[5] != 0) {
      return TelinkNotificationFrame._(bytes[5], uid, '', '', '', '', null);
    }
    String text(int id) {
      try {
        return utf8.decode(attributes[id] ?? const []);
      } on FormatException {
        // utf8 的原始异常可能携带输入内容，不向日志传播。
        throw const FormatException('notification_invalid_utf8');
      }
    }

    final app = text(0);
    if (app.trim().isEmpty) {
      throw const FormatException('notification_missing_app');
    }
    return TelinkNotificationFrame._(
        0, uid, app, text(1), text(2), text(3), _date(text(5)));
  }

  static DateTime? _date(String value) {
    if (!RegExp(r'^\d{8}T\d{6}$').hasMatch(value)) return null;
    final year = int.parse(value.substring(0, 4));
    if (year < 1) return null;
    final month = int.parse(value.substring(4, 6));
    final day = int.parse(value.substring(6, 8));
    final hour = int.parse(value.substring(9, 11));
    final minute = int.parse(value.substring(11, 13));
    final second = int.parse(value.substring(13, 15));
    // ANCS Date 无时区，保留为手机本地时间；无效日期退回接收时间。
    final date = DateTime(year, month, day, hour, minute, second);
    return date.year == year &&
            date.month == month &&
            date.day == day &&
            date.hour == hour &&
            date.minute == minute &&
            date.second == second
        ? date
        : null;
  }
}

/// 仅重组以 AA5541 开头的顺序分片（首片至少含3字节类型头）。
/// 新的其它 AA55 事件会中止未完成帧，避免吞掉鉴权或录音事件。
/// 固件是否发送跨 GATT 分片尚待实卡验证，不猜测交错的无头续片。
class TelinkNotificationDecoder {
  final List<int> _pending = [];
  DateTime? _startedAt;
  static const maximumAge = Duration(seconds: 5);

  static bool isStart(List<int> bytes) =>
      bytes.length >= 3 &&
      bytes[0] == 0xaa &&
      bytes[1] == 0x55 &&
      bytes[2] == 0x41;

  bool accepts(List<int> bytes) {
    if (isStart(bytes)) return true;
    if (bytes.length >= 2 && bytes[0] == 0xaa && bytes[1] == 0x55) {
      reset();
      return false;
    }
    return _pending.isNotEmpty;
  }

  TelinkNotificationFrame? feed(List<int> bytes, {DateTime? now}) {
    final time = now ?? DateTime.now();
    final start = isStart(bytes);
    if (start) {
      reset();
      _startedAt = time;
    } else if (_startedAt == null ||
        time.difference(_startedAt!) > maximumAge) {
      reset();
      throw const FormatException('notification_fragment_expired');
    }
    if (bytes.any((b) => b < 0 || b > 255) ||
        _pending.length + bytes.length > 65540) {
      reset();
      throw const FormatException('notification_fragment_size');
    }
    _pending.addAll(bytes);
    if (_pending.length < 5) return null;
    final expected = 5 + _pending[3] + (_pending[4] << 8);
    if (expected < 18 || _pending.length > expected) {
      reset();
      throw const FormatException('notification_fragment_length');
    }
    if (_pending.length < expected) return null;
    final complete = List<int>.of(_pending);
    reset();
    return TelinkNotificationFrame.decode(complete);
  }

  void reset() {
    _pending.clear();
    _startedAt = null;
  }
}

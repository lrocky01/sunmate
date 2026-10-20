import 'dart:convert';
import 'dart:typed_data';
import '../hardware/recorder_long_file_models.dart';

sealed class TelinkLongFileEvent {
  const TelinkLongFileEvent();
  static bool isFileEvent(List<int> bytes) =>
      bytes.length >= 3 &&
      bytes[0] == 0xaa &&
      bytes[1] == 0x55 &&
      const [5, 6, 8].contains(bytes[2]);
  static TelinkLongFileEvent decode(List<int> bytes) {
    if (!isFileEvent(bytes) || bytes.any((b) => b < 0 || b > 255)) {
      throw const FormatException('file_event_header');
    }
    if (bytes[2] == 5) {
      if (bytes.length != 7) throw const FormatException('file_size_length');
      final size = ByteData.sublistView(Uint8List.fromList(bytes))
          .getInt32(3, Endian.big);
      if (size <= 0 || size > maximumSegmentBytes)
        throw const FormatException('file_size_limit');
      return TelinkFileSize(size);
    }
    if (bytes[2] == 6) {
      if (bytes.length != 3)
        throw const FormatException('file_complete_length');
      return const TelinkFileComplete();
    }
    if (bytes.length == 3) return const TelinkFileListEnd();
    if (bytes.length > 512) throw const FormatException('file_entry_limit');
    String text;
    try {
      text = utf8.decode(bytes.sublist(3)).trim();
    } on FormatException {
      throw const FormatException('file_entry_utf8');
    }
    final fields = text.split(RegExp(r'\s+'));
    if (fields.length < 2) throw const FormatException('file_entry_fields');
    final match = RegExp(r'^/?longops_s([0-9]{1,19})_p([0-9]{1,6})\.ops$')
        .firstMatch(fields[0]);
    // 目录可以同时列出其它类型文件；不下载、不改写它们。
    if (match == null) return const TelinkOtherFile();
    final session = int.tryParse(match[1]!);
    final part = int.tryParse(match[2]!);
    final size = int.tryParse(fields[1]);
    if (session == null ||
        session <= 0 ||
        session > 0x7fffffffffffffff ||
        part == null ||
        part > 99999 ||
        size == null ||
        size < 0 ||
        size > maximumSegmentBytes) {
      throw const FormatException('file_entry_values');
    }
    return TelinkFileListEntry(RecorderLongFileEntry(session, part, size));
  }

  // 本地资源界限，不宣称是固件容量。
  static const maximumSegmentBytes = 256 * 1024 * 1024;
  static Uint8List listCommand() => Uint8List.fromList([0x11, 0x22]);
  static Uint8List readCommand(RecorderLongFileEntry file) =>
      Uint8List.fromList([0x11, 0x26, ...utf8.encode(file.remoteName)]);
}

class TelinkFileSize extends TelinkLongFileEvent {
  final int size;
  TelinkFileSize(this.size);
}

class TelinkFileComplete extends TelinkLongFileEvent {
  const TelinkFileComplete();
}

class TelinkFileListEnd extends TelinkLongFileEvent {
  const TelinkFileListEnd();
}

class TelinkOtherFile extends TelinkLongFileEvent {
  const TelinkOtherFile();
}

class TelinkFileListEntry extends TelinkLongFileEvent {
  final RecorderLongFileEntry entry;
  TelinkFileListEntry(this.entry);
}

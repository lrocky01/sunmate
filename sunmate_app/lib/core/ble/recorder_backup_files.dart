import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'recorder_portable_backup.dart';

/// 系统文件选择器只收发密文；不写明文临时文件，不申请媒体/蓝牙权限。
class RecorderBackupFiles {
  Future<bool> save(Uint8List encrypted) async {
    if (encrypted.isEmpty ||
        encrypted.length > RecorderBackupCodec.maximumFileBytes) {
      throw const FormatException('备份文件长度无效');
    }
    final path = await FilePicker.platform.saveFile(
        dialogTitle: '保存加密录音卡备份',
        fileName:
            'SunMate-recorder-${DateTime.now().microsecondsSinceEpoch}.sunmate',
        type: FileType.any,
        bytes: encrypted);
    if (path == null) return false;
    // 移动端插件负责写bytes，桌面saveFile只返回用户选择的路径。
    if (!Platform.isIOS && !Platform.isAndroid) {
      await File(path).writeAsBytes(encrypted, flush: true);
    }
    return true;
  }

  Future<Uint8List?> pick() async {
    final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: false,
        withReadStream: true,
        dialogTitle: '选择SunMate加密备份');
    if (result == null) return null;
    final file = result.files.single;
    if (file.size > RecorderBackupCodec.maximumFileBytes) {
      throw const FormatException('备份文件超过16KB，请选择SunMate加密备份');
    }
    final stream = file.readStream ??
        (file.path != null ? File(file.path!).openRead() : null);
    if (stream == null) throw StateError('无法读取所选文件，请重选');
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (builder.length + chunk.length >
          RecorderBackupCodec.maximumFileBytes) {
        throw const FormatException('备份文件超过16KB');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

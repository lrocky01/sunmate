import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ble/recorder_backup_files.dart';

class BackupPicker extends FilePicker {
  FilePickerResult? result;
  Uint8List? sent;
  String? name;
  @override
  Future<FilePickerResult?> pickFiles(
      {String? dialogTitle,
      String? initialDirectory,
      FileType type = FileType.any,
      List<String>? allowedExtensions,
      Function(FilePickerStatus)? onFileLoading,
      bool allowCompression = false,
      int compressionQuality = 0,
      bool allowMultiple = false,
      bool withData = false,
      bool withReadStream = false,
      bool lockParentWindow = false,
      bool readSequential = false}) async {
    expect(withData, false);
    expect(withReadStream, true);
    expect(allowMultiple, false);
    return result;
  }

  @override
  Future<String?> saveFile(
      {String? dialogTitle,
      String? fileName,
      String? initialDirectory,
      FileType type = FileType.any,
      List<String>? allowedExtensions,
      Uint8List? bytes,
      bool lockParentWindow = false}) async {
    sent = bytes;
    name = fileName;
    return null; // 取消，不能写入任何桌面路径。
  }
}

void main() {
  late BackupPicker picker;
  final files = RecorderBackupFiles();
  setUp(() {
    picker = BackupPicker();
    FilePicker.platform = picker;
  });
  test(
      'picker cancellation returns no data and save passes only supplied ciphertext',
      () async {
    expect(await files.pick(), isNull);
    final encrypted = Uint8List.fromList([1, 2, 3]);
    expect(await files.save(encrypted), false);
    expect(picker.sent, encrypted);
    expect(picker.name, matches(r'^SunMate-recorder-[0-9]+\.sunmate$'));
  });
  test('file reader consumes bounded stream and does not require a raw path',
      () async {
    picker.result = FilePickerResult([
      PlatformFile(
          name: 'test.sunmate',
          size: 3,
          readStream: Stream.fromIterable([
            [1],
            [2, 3]
          ]))
    ]);
    expect(await files.pick(), [1, 2, 3]);
  });
  test('oversized declared size and understated actual stream are rejected',
      () async {
    picker.result =
        FilePickerResult([PlatformFile(name: 'oversized', size: 16385)]);
    await expectLater(files.pick(), throwsFormatException);
    picker.result = FilePickerResult([
      PlatformFile(
          name: 'understated',
          size: 0,
          readStream: Stream.fromIterable([
            List.filled(16384, 0),
            [1]
          ]))
    ]);
    await expectLater(files.pick(), throwsFormatException);
  });
  test('unreadable file and invalid export size fail without writing',
      () async {
    picker.result =
        FilePickerResult([PlatformFile(name: 'unreadable', size: 0)]);
    await expectLater(files.pick(), throwsStateError);
    await expectLater(files.save(Uint8List(16385)), throwsFormatException);
    expect(picker.sent, isNull);
  });
}

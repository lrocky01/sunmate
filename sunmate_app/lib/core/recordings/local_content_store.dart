import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

abstract interface class RecordingContentStore {
  Future<List<Map<String, dynamic>>> readAll(String collection);
  Future<void> put(String collection, String id, Map<String, dynamic> record);
}

Future<String> contentFingerprint(Object value) async =>
    (await Sha256().hash(utf8.encode(jsonEncode(value))))
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

/// App私有目录中的版本化结果，不保存Token或业务密钥。原子替换仅更新结果记录。
class FileRecordingContentStore implements RecordingContentStore {
  final Future<Directory> Function() root;
  Future<void> _writes = Future<void>.value();
  FileRecordingContentStore({Future<Directory> Function()? root})
      : root = root ??
            (() async => Directory(
                '${(await getApplicationSupportDirectory()).path}/sunmate_content_v1'));
  static const _collections = {
    'parts',
    'sessions',
    'transcripts',
    'summaries',
    'notifications',
    'notes',
    'settings',
    'hidden',
    'attempts',
    'notification_jobs'
  };
  Future<Directory> _directory(String collection) async {
    if (!_collections.contains(collection))
      throw const FormatException('本机结果分类无效');
    final base = (await root()).absolute;
    for (final dir in [base, Directory('${base.path}/$collection')]) {
      final type = await FileSystemEntity.type(dir.path, followLinks: false);
      if (type == FileSystemEntityType.notFound)
        await dir.create(recursive: true);
      else if (type != FileSystemEntityType.directory)
        throw const FileSystemException('结果目录类型无效');
    }
    return Directory('${base.path}/$collection');
  }

  Future<Map<String, dynamic>> _read(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > 2 * 1024 * 1024)
      throw const FormatException('结果记录类型或大小无效');
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['id'] is! String) {
      throw const FormatException('本机结果格式不匹配，原记录保留');
    }
    if ('${await contentFingerprint(value['id'])}.json' !=
        file.uri.pathSegments.last) {
      throw const FormatException('本机结果来源不匹配');
    }
    return value;
  }

  @override
  Future<List<Map<String, dynamic>>> readAll(String collection) async {
    await _writes;
    final directory = await _directory(collection);
    final result = <Map<String, dynamic>>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (!RegExp(r'^[a-f0-9]{64}\.json$')
          .hasMatch(entry.uri.pathSegments.last)) continue;
      result.add(await _read(File(entry.path)));
      if (result.length > 100000) throw const FormatException('本机结果数量超出本轮支持范围');
    }
    return result;
  }

  @override
  Future<void> put(String collection, String id, Map<String, dynamic> record) {
    final value = jsonDecode(jsonEncode({...record, 'version': 1, 'id': id}))
        as Map<String, dynamic>;
    final task = _writes.then((_) async {
      final encoded = jsonEncode(value);
      if (encoded.length > 1024 * 1024) throw const FormatException('本机结果过大');
      final directory = await _directory(collection);
      final file =
          File('${directory.path}/${await contentFingerprint(id)}.json');
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound)
        await _read(file); // 不覆盖损坏或链接记录。
      final temporary = File('${directory.path}/${const Uuid().v4()}.partial');
      await temporary.create(exclusive: true);
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(file.path);
    });
    _writes = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }
}

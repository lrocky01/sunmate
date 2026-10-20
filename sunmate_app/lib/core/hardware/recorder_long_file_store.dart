import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'recorder_long_file_models.dart';
import 'recorder_long_recordings.dart';

/// 长录本地归档。所有输入都须已通过真实设备身份验证；这里不访问 BLE、账号或网络。
/// 接收临时段、OPS 源段和可播放音频分开保存，失败不会删除任何已提交段。
class RecorderLongFileStore {
  static const directoryName = 'recorder_long_audio_v1';
  static const maxSegmentBytes = 256 * 1024 * 1024;
  static const maxParts = 10000;
  final Future<Directory> Function() _rootDirectory;
  Future<void> _recordWork = Future.value();

  RecorderLongFileStore({Future<Directory> Function()? rootDirectory})
      : _rootDirectory = rootDirectory ?? _defaultRoot;

  static Future<Directory> _defaultRoot() async => Directory(
      '${(await getApplicationSupportDirectory()).path}/$directoryName');

  void _identity(String sn, int session, [int? part]) {
    if (!RecorderLongSession.validSerial(sn) ||
        session <= 0 ||
        (part != null && (part < 0 || part >= maxParts))) {
      throw const FormatException('录音来源身份无效');
    }
  }

  Future<Directory> _root() async {
    final root = (await _rootDirectory()).absolute;
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await root.create(recursive: true);
    } else if (type != FileSystemEntityType.directory) {
      throw const FileSystemException('录音目录不是安全目录');
    }
    return root;
  }

  /// 返回相对于 ApplicationSupport 的路径；测试注入目录仍表示 recorder_long_audio_v1 根。
  Future<File> resolveRelative(String path) async {
    final parts = path.split('/');
    if (parts.length < 4 ||
        parts.first != directoryName ||
        parts.any(
            (s) => s.isEmpty || s == '.' || s == '..' || s.contains('\\')) ||
        !RecorderLongSession.validSerial(parts[1]) ||
        !RegExp(r'^s[1-9][0-9]*$').hasMatch(parts[2])) {
      throw const FormatException('录音文件路径无效');
    }
    final root = await _root();
    var current = root.path;
    for (var i = 1; i < parts.length; i++) {
      current = '$current/${parts[i]}';
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link ||
          (i < parts.length - 1 &&
              type != FileSystemEntityType.directory &&
              type != FileSystemEntityType.notFound) ||
          (i == parts.length - 1 &&
              type != FileSystemEntityType.file &&
              type != FileSystemEntityType.notFound)) {
        throw const FileSystemException('录音路径包含链接或类型冲突');
      }
    }
    return File(current);
  }

  String _relative(String sn, int session, String name) =>
      '$directoryName/$sn/s$session/$name';

  Future<Directory> _sessionDirectory(String sn, int session) async {
    _identity(sn, session);
    final probe = await resolveRelative(_relative(sn, session, 'record.json'));
    final root = await _root();
    for (final directory in [Directory('${root.path}/$sn'), probe.parent]) {
      final type =
          await FileSystemEntity.type(directory.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await directory.create();
      } else if (type != FileSystemEntityType.directory) {
        throw const FileSystemException('录音来源目录无效');
      }
    }
    return probe.parent;
  }

  Future<File> createTemporarySegment(String sn, int session, int part) async {
    _identity(sn, session, part);
    await _sessionDirectory(sn, session);
    final file = await resolveRelative(
        _relative(sn, session, 'p$part-${const Uuid().v4()}.ops.partial'));
    await file.create(exclusive: true);
    return file;
  }

  Future<String> _hash(File file) async {
    final sink = Sha256().toSync().newHashSink();
    await for (final bytes in file.openRead()) {
      sink.add(bytes);
    }
    sink.close();
    return (await sink.hash())
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<Uint8List> _readExact(RandomAccessFile input, int length) async {
    final result = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      final count = await input.readInto(result, offset, length);
      if (count == 0) throw const FormatException('OPS 文件被截断');
      offset += count;
    }
    return result;
  }

  /// 严格完整文件格式，绝不使用实时流的 resync/大小端猜测。
  Stream<Uint8List> _packets(File file) async* {
    final size = await file.length();
    if (size <= 8 || size > maxSegmentBytes) {
      throw const FormatException('OPS 文件为空或超过本地资源限制');
    }
    final input = await file.open();
    try {
      var consumed = 0;
      while (consumed < size) {
        if (size - consumed < 8) throw const FormatException('OPS 末尾头不完整');
        final header = ByteData.sublistView(await _readExact(input, 8));
        final length = header.getUint32(0, Endian.little);
        if (length < 1 ||
            length > 65536 ||
            header.getUint32(4, Endian.little) != 0 ||
            consumed + 8 + length > size) {
          throw const FormatException('OPS 帧长度或保留字节无效');
        }
        yield await _readExact(input, length);
        consumed += 8 + length;
      }
      if (await input.length() != size)
        throw const FormatException('OPS 校验期间大小发生变化');
    } finally {
      await input.close();
    }
  }

  Future<void> _validate(File file, int expectedSize) async {
    if (expectedSize <= 8 ||
        expectedSize > maxSegmentBytes ||
        await file.length() != expectedSize) {
      throw const FormatException('录音分段大小不匹配');
    }
    await for (final _ in _packets(file)) {/* 完整耗尽并校验结构。 */}
  }

  Future<RecorderCommittedSegment?> findSegment(
      String sn, int session, int part, int expectedSize) async {
    _identity(sn, session, part);
    final directory = await _sessionDirectory(sn, session);
    final expression = RegExp('^p$part-([a-f0-9]{64})\\.ops\$');
    await for (final entity in directory.list(followLinks: false)) {
      final name = entity.path.split('/').last;
      final match = expression.firstMatch(name);
      if (match == null) continue;
      final relative = _relative(sn, session, name);
      final file = await resolveRelative(relative);
      if (!await file.exists() || await file.length() != expectedSize) continue;
      try {
        await _validate(file, expectedSize);
        final hash = await _hash(file);
        if (hash != match.group(1)) continue;
        return RecorderCommittedSegment(
            part: part,
            size: expectedSize,
            sha256: hash,
            relativePath: relative);
      } on FormatException {/* 保留损坏源段，由下载新建唯一临时文件。 */}
    }
    return null;
  }

  Future<RecorderCommittedSegment> commitSegment(String sn, int session,
      int part, int expectedSize, File temporary) async {
    _identity(sn, session, part);
    final directory = await _sessionDirectory(sn, session);
    final name = temporary.path.split('/').last;
    if (!RegExp('^p$part-[a-f0-9-]{36}\\.ops\\.partial\$').hasMatch(name) ||
        temporary.absolute.path != '${directory.absolute.path}/$name') {
      throw const FormatException('临时录音文件来源无效');
    }
    final checked = await resolveRelative(_relative(sn, session, name));
    await _validate(checked, expectedSize);
    final hash = await _hash(checked);
    final relative = _relative(sn, session, 'p$part-$hash.ops');
    final destination = await resolveRelative(relative);
    // 落盘前刷新数据；不覆盖已有损坏文件，更不覆盖不同内容的旧段。
    final output = await checked.open(mode: FileMode.append);
    try {
      await output.flush();
    } finally {
      await output.close();
    }
    if (await destination.exists()) {
      var valid = false;
      try {
        await _validate(destination, expectedSize);
        valid = await _hash(destination) == hash;
      } on FormatException {/* 损坏文件隔离留存，不覆盖或删除。 */}
      if (valid) {
        await checked.delete(); // 仅清理内容完全相同的未提交临时副本。
      } else {
        await destination
            .rename('${destination.path}.invalid-${const Uuid().v4()}');
        await checked.rename(destination.path);
      }
    } else {
      await checked.rename(destination.path);
    }
    return RecorderCommittedSegment(
        part: part, size: expectedSize, sha256: hash, relativePath: relative);
  }

  Future<RecorderOggAudio> assemble(
      String sn, int session, List<RecorderCommittedSegment> segments) async {
    _identity(sn, session);
    if (segments.isEmpty || segments.length > maxParts) {
      throw const FormatException('长录分段为空或超过本地资源限制');
    }
    // 调用方须给出从 p0 起的完整顺序，不默默跳过或重排缺失段。
    final inventory = StringBuffer();
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (segment.part != i ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(segment.sha256) ||
          segment.relativePath !=
              _relative(sn, session, 'p$i-${segment.sha256}.ops')) {
        throw const FormatException('长录分段不连续或来源不匹配');
      }
      final source = await resolveRelative(segment.relativePath);
      await _validate(source, segment.size);
      if (await _hash(source) != segment.sha256)
        throw const FormatException('长录源段指纹不匹配');
      inventory.write('$i:${segment.size}:${segment.sha256}\n');
    }
    final inventoryHash =
        (await Sha256().hash(utf8.encode(inventory.toString())))
            .bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
    final relative = _relative(sn, session, 'audio-$inventoryHash.ogg');
    final destination = await resolveRelative(relative);
    final temporary = await resolveRelative(
        _relative(sn, session, 'audio-${const Uuid().v4()}.ogg.partial'));
    await temporary.create(exclusive: true);
    final output = await temporary.open(mode: FileMode.writeOnly);
    final muxer = _LongOggMuxer(session);
    var packets = 0;
    var samples = 0;
    try {
      for (final bytes in muxer.start()) {
        await output.writeFrom(bytes);
      }
      for (final segment in segments) {
        final source = await resolveRelative(segment.relativePath);
        await for (final packet in _packets(source)) {
          samples += _opusSamples(packet);
          await output.writeFrom(muxer.packet(packet, samples));
          packets++;
        }
        // 再核对一次：校验与读取之间被改写的文件不能提交为最终音频。
        if (await _hash(source) != segment.sha256)
          throw const FormatException('合成期间源段发生变化');
      }
      if (packets == 0) throw const FormatException('长录没有有效音频包');
      await output.writeFrom(muxer.finish(samples));
      await output.flush();
    } finally {
      await output.close();
    }
    if (await destination.exists()) {
      if (await _hash(destination) != await _hash(temporary)) {
        await destination
            .rename('${destination.path}.invalid-${const Uuid().v4()}');
        await temporary.rename(destination.path);
      } else {
        await temporary.delete(); // 不删除任何已提交音频或 OPS。
      }
    } else {
      await temporary.rename(destination.path);
    }
    return RecorderOggAudio(relative, packets, samples * 1000 ~/ 48000);
  }

  /// 仅计算 Opus packet TOC 的真实时长；最终可播放结果仍必须经过完整解码验收。
  int _opusSamples(Uint8List packet) {
    if (packet.isEmpty || packet.length > 65024) {
      throw const FormatException('Opus 包为空或超出本轮 Ogg 单页支持范围');
    }
    final toc = packet[0];
    if ((toc & 0x04) != 0) {
      throw const FormatException('本轮仅支持单声道 Opus，保留立体声源段等待兼容处理');
    }
    final config = toc >> 3;
    final perFrame = config >= 16
        ? 120 << (config & 3)
        : config >= 12
            ? 480 << (config & 1)
            : (config & 3) == 3
                ? 2880
                : 480 << (config & 3);
    final code = toc & 3;
    final count = code == 0
        ? 1
        : code < 3
            ? 2
            : packet.length >= 2
                ? packet[1] & 63
                : 0;
    if (count <= 0 || count > 48 || perFrame * count > 5760) {
      throw const FormatException('Opus 包时长无效或超过 120ms');
    }
    return perFrame * count;
  }

  Future<void> saveRecord(RecorderLongAudioRecord record) {
    final task = _recordWork.then((_) => _saveRecord(record));
    _recordWork =
        task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  Future<void> _saveRecord(RecorderLongAudioRecord record) async {
    _identity(record.serialNumber, record.sessionId);
    final directory =
        await _sessionDirectory(record.serialNumber, record.sessionId);
    final path =
        _relative(record.serialNumber, record.sessionId, 'record.json');
    final destination = await resolveRelative(path);
    _checkRecord(record);
    if (!await _referencesPresent(record) && record.canPlay) {
      throw const FormatException('可播放录音的本地文件缺失，未标记保存成功');
    }
    if (await destination.exists()) await _readRecord(destination);
    final temporary =
        File('${directory.path}/record-${const Uuid().v4()}.json.partial');
    await temporary.create(exclusive: true);
    await temporary.writeAsString(jsonEncode(_recordJson(record)), flush: true);
    await temporary.rename(destination.path);
  }

  void _checkRecord(RecorderLongAudioRecord r) {
    _identity(r.serialNumber, r.sessionId);
    if (r.inventoryFingerprint != null &&
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(r.inventoryFingerprint!)) {
      throw const FormatException('录音目录指纹格式无效');
    }
    if ([r.totalParts, r.downloadedParts, r.sourceBytes, r.receivedBytes]
            .any((n) => n < 0) ||
        r.totalParts > maxParts ||
        r.downloadedParts > maxParts ||
        (r.durationMs != null && r.durationMs! < 0)) {
      throw const FormatException('录音归档数据无效');
    }
    for (final path in [r.relativeOggPath, r.relativePlayablePath]) {
      if (path == null) continue;
      final prefix = '$directoryName/${r.serialNumber}/s${r.sessionId}/';
      if (!path.startsWith(prefix) ||
          path.substring(prefix.length).contains('/') ||
          !RegExp(r'^[A-Za-z0-9._-]+$')
              .hasMatch(path.substring(prefix.length))) {
        throw const FormatException('录音归档路径与身份不匹配');
      }
    }
    if (r.stage == RecorderLongFileStage.saved &&
        (r.relativeOggPath == null ||
            r.relativePlayablePath == null ||
            r.durationMs == null)) {
      throw const FormatException('可播放录音缺少来源或时长');
    }
  }

  Map<String, Object?> _recordJson(RecorderLongAudioRecord r) => {
        'version': 1,
        'sn': r.serialNumber,
        'session': r.sessionId,
        'purpose': r.purpose?.name,
        'stage': r.stage.name,
        'totalParts': r.totalParts,
        'downloadedParts': r.downloadedParts,
        'sourceBytes': r.sourceBytes,
        'receivedBytes': r.receivedBytes,
        'ogg': r.relativeOggPath,
        'playable': r.relativePlayablePath,
        'inventoryFingerprint': r.inventoryFingerprint,
        'durationMs': r.durationMs,
        'savedAt': r.savedAt?.toUtc().toIso8601String(),
        'message': r.message,
      };

  Future<bool> _referencesPresent(RecorderLongAudioRecord record) async {
    var present = true;
    for (final path in [record.relativeOggPath, record.relativePlayablePath]) {
      if (path == null) continue;
      final file = await resolveRelative(path);
      if (!await file.exists() || await file.length() == 0) present = false;
    }
    return present;
  }

  Future<RecorderLongAudioRecord> _readRecord(File file) async {
    if (await file.length() > 65536) throw const FormatException('录音归档元数据超限');
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map || raw['version'] != 1)
      throw const FormatException('录音归档格式无效');
    try {
      final record = RecorderLongAudioRecord(
          serialNumber: raw['sn'] as String,
          sessionId: raw['session'] as int,
          purpose: raw['purpose'] == null
              ? null
              : LongRecordingPurpose.values.byName(raw['purpose'] as String),
          stage: RecorderLongFileStage.values.byName(raw['stage'] as String),
          totalParts: raw['totalParts'] as int,
          downloadedParts: raw['downloadedParts'] as int,
          sourceBytes: raw['sourceBytes'] as int,
          receivedBytes: raw['receivedBytes'] as int,
          relativeOggPath: raw['ogg'] as String?,
          relativePlayablePath: raw['playable'] as String?,
          inventoryFingerprint: raw['inventoryFingerprint'] as String?,
          durationMs: raw['durationMs'] as int?,
          savedAt: raw['savedAt'] == null
              ? null
              : DateTime.parse(raw['savedAt'] as String),
          message: raw['message'] as String?);
      _checkRecord(record);
      final expected = await resolveRelative(
          _relative(record.serialNumber, record.sessionId, 'record.json'));
      if (file.absolute.path != expected.absolute.path)
        throw const FormatException('录音归档存放身份不匹配');
      if (!await _referencesPresent(record) && record.canPlay) {
        // 保留原 JSON，运行时如实显示待恢复，而不是显示可播放。
        return record.copyWith(
            stage: RecorderLongFileStage.incomplete,
            message: '本地音频文件缺失，保留归档等待恢复');
      }
      return record;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('录音归档元数据损坏，已保留原文件');
    }
  }

  Future<List<RecorderLongAudioRecord>> loadRecords() async {
    final root = await _root();
    final records = <RecorderLongAudioRecord>[];
    await for (final sn in root.list(followLinks: false)) {
      if (!RecorderLongSession.validSerial(sn.path.split('/').last)) continue;
      if (await FileSystemEntity.type(sn.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FileSystemException('录音来源目录包含链接或类型冲突');
      }
      await for (final session in Directory(sn.path).list(followLinks: false)) {
        if (!RegExp(r'^s[1-9][0-9]*$').hasMatch(session.path.split('/').last))
          continue;
        if (await FileSystemEntity.type(session.path, followLinks: false) !=
            FileSystemEntityType.directory) {
          throw const FileSystemException('录音会话目录包含链接或类型冲突');
        }
        final relative =
            '$directoryName/${sn.path.split('/').last}/${session.path.split('/').last}/record.json';
        final file = await resolveRelative(relative);
        if (await file.exists()) records.add(await _readRecord(file));
        if (records.length > maxParts)
          throw const FormatException('本地录音归档数量超限');
      }
    }
    records.sort((a, b) => b.sessionId.compareTo(a.sessionId));
    return records;
  }
}

/// 长录专用封装；不改变实时通道的容器状态机。
class _LongOggMuxer {
  final int serial;
  var sequence = 0;
  _LongOggMuxer(this.serial);

  List<Uint8List> start() {
    final head = ByteData(19);
    head.buffer.asUint8List().setRange(0, 8, ascii.encode('OpusHead'));
    head.setUint8(8, 1);
    head.setUint8(9, 1);
    // 原始 OPS 没有可信 encoder-delay 元数据，保留所有原始样本。
    head.setUint16(10, 0, Endian.little);
    head.setUint32(12, 16000, Endian.little);
    final vendor = utf8.encode('SunMate Long Recorder');
    final tags = BytesBuilder()
      ..add(ascii.encode('OpusTags'))
      ..add((ByteData(4)..setUint32(0, vendor.length, Endian.little))
          .buffer
          .asUint8List())
      ..add(vendor)
      ..add(Uint8List(4));
    return [
      _page(head.buffer.asUint8List(), 2, 0),
      _page(tags.toBytes(), 0, 0)
    ];
  }

  Uint8List packet(Uint8List packet, int samples) => _page(packet, 0, samples);
  Uint8List finish(int samples) => _page(Uint8List(0), 4, samples, empty: true);
  Uint8List _page(Uint8List payload, int flags, int granule,
      {bool empty = false}) {
    final segments = empty ? 0 : payload.length ~/ 255 + 1;
    if (segments > 255) throw const FormatException('Opus 包超过单页范围');
    final result = Uint8List(27 + segments + payload.length);
    final data = ByteData.sublistView(result);
    result.setRange(0, 4, ascii.encode('OggS'));
    result[5] = flags;
    data.setUint64(6, granule, Endian.little);
    data.setUint32(14, serial & 0xffffffff, Endian.little);
    data.setUint32(18, sequence++, Endian.little);
    result[26] = segments;
    for (var i = 0; i < segments; i++) {
      result[27 + i] = i == segments - 1 ? payload.length % 255 : 255;
    }
    result.setRange(27 + segments, result.length, payload);
    var crc = 0;
    for (final b in result) {
      crc ^= b << 24;
      for (var bit = 0; bit < 8; bit++) {
        crc = ((crc << 1) ^ ((crc & 0x80000000) != 0 ? 0x04c11db7 : 0)) &
            0xffffffff;
      }
    }
    data.setUint32(22, crc, Endian.little);
    return result;
  }
}

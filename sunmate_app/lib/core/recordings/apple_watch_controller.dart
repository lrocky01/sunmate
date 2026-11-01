import 'dart:async';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import '../hardware/apple_watch_driver.dart';

class WatchPart {
  final String source, purpose, sha;
  final int session, part, frames, offset, bytes;
  final DateTime started;
  WatchPart(Map<String, dynamic> v)
      : source = v['source'] as String,
        purpose = v['purpose'] as String,
        sha = v['sha256'] as String,
        session = v['session'] as int,
        part = v['part'] as int,
        frames = v['frames'] as int,
        offset = v['offsetFrames'] as int,
        bytes = v['bytes'] as int,
        started = DateTime.parse(v['started'] as String) {
    if (!RegExp(r'^WATCH_[a-f0-9]{32}$').hasMatch(source) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha) ||
        !['voice', 'meeting', 'lifelog'].contains(purpose) ||
        session < 1577836800000 ||
        session > 4102444800000 ||
        part < 0 ||
        part >= 10000 ||
        frames < 1 ||
        frames > 1920000 ||
        offset < 0 ||
        offset > 1382400000 ||
        bytes != 44 + frames * 2) {
      throw const FormatException('手表来源无效');
    }
  }
  String get id => '$source:$session:$part:$sha';
  Duration get duration => Duration(microseconds: frames * 1000000 ~/ 16000);
}

class WatchSession {
  final String id, purpose;
  final DateTime started;
  final bool complete, interrupted;
  final List<WatchPart> parts;
  WatchSession(Map<String, dynamic> v)
      : id = '${v['source']}:${v['session']}',
        purpose = v['purpose'] as String,
        started = DateTime.parse(v['started'] as String),
        interrupted = v['interrupted'] as bool,
        complete = v['ended'] != null &&
            v['interrupted'] == false &&
            (v['parts'] as List).isNotEmpty,
        parts = (v['parts'] as List)
            .map((p) => WatchPart(Map<String, dynamic>.from(p)))
            .toList() {
    if (v['source'] is! String ||
        !RegExp(r'^WATCH_[a-f0-9]{32}$').hasMatch(v['source']) ||
        v['session'] is! int ||
        v['session'] < 1577836800000 ||
        v['session'] > 4102444800000) {
      throw const FormatException('手表会话身份无效');
    }
    var offset = 0;
    for (var i = 0; i < parts.length; i++) {
      final p = parts[i];
      if ('${p.source}:${p.session}' != id ||
          p.part != i ||
          p.offset != offset ||
          p.purpose != purpose ||
          p.started != started) {
        throw const FormatException('手表分段不连续');
      }
      offset += p.frames;
    }
    if (!['voice', 'meeting', 'lifelog'].contains(purpose))
      throw const FormatException();
  }
  Duration get duration => Duration(
      microseconds:
          parts.fold<int>(0, (v, p) => v + p.frames) * 1000000 ~/ 16000);
}

/// Source acquisition and local HealthKit views only. Has no server/token fields.
class AppleWatchController extends ChangeNotifier {
  final AppleWatchDriver driver;
  StreamSubscription<void>? _changes;
  bool loaded = false, busy = false, disposed = false;
  bool supported = false, enabled = false, backgroundSync = false;
  bool reachable = false, paired = false, installed = false;
  bool healthEnabled = false;
  Set<String> healthTypes = {};
  List<Map<String, dynamic>> healthSamples = [];
  List<WatchSession> sessions = [];
  String? message;
  int _generation = 0, _healthGeneration = 0;
  AppleWatchController(this.driver) {
    _changes = driver.stateChanges.listen((_) => _accept());
  }
  void _changed() {
    if (!disposed) notifyListeners();
  }

  Future<void> refresh() async {
    if (!driver.native.supported) {
      loaded = true;
      supported = false;
      _changed();
      return;
    }
    await driver.refresh();
    _accept();
  }

  void _accept() {
    if (disposed) return;
    final v = driver.snapshot;
    try {
      supported = v['supported'] == true;
      enabled = v['enabled'] == true;
      backgroundSync = v['backgroundSync'] == true;
      reachable = v['reachable'] == true;
      paired = v['paired'] == true;
      installed = v['watchAppInstalled'] == true;
      if (v['sessions'] is List) {
        final values = (v['sessions'] as List)
            .map((s) => WatchSession(Map<String, dynamic>.from(s)))
            .toList();
        sessions = values;
      }
      loaded = true;
      message = v['message'] as String?;
    } catch (_) {
      loaded = true;
      message = '手表目录未通过校验，原音频保留。';
    }
    _changed();
  }

  Future<bool> configure(
      {required bool enabled, required bool backgroundSync}) async {
    if (busy || !supported) return false;
    final generation = ++_generation;
    busy = true;
    _changed();
    try {
      final ok = await driver.native.call('configure',
              {'enabled': enabled, 'backgroundSync': backgroundSync}) ==
          true;
      if (!ok) throw const FormatException();
      if (!disposed && generation == _generation) await refresh();
      return true;
    } catch (_) {
      message = '接收设置未确认保存，原设置保留。';
      return false;
    } finally {
      if (!disposed && generation == _generation) {
        busy = false;
        _changed();
      }
    }
  }

  Future<Uint8List> audio(WatchPart part) async {
    final value = await driver.native.call('readPart', {'id': part.id});
    if (value is! Uint8List || value.length != part.bytes || value.length < 44)
      throw const FormatException('手表音频无效');
    final sha = (await Sha256().hash(value))
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final b = ByteData.sublistView(value);
    if (sha != part.sha ||
        String.fromCharCodes(value.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(value.sublist(8, 16)) != 'WAVEfmt ' ||
        b.getUint32(4, Endian.little) != value.length - 8 ||
        b.getUint32(16, Endian.little) != 16 ||
        b.getUint16(20, Endian.little) != 1 ||
        b.getUint16(22, Endian.little) != 1 ||
        b.getUint32(24, Endian.little) != 16000 ||
        b.getUint32(28, Endian.little) != 32000 ||
        b.getUint16(32, Endian.little) != 2 ||
        b.getUint16(34, Endian.little) != 16 ||
        String.fromCharCodes(value.sublist(36, 40)) != 'data' ||
        b.getUint32(40, Endian.little) != part.frames * 2) {
      throw const FormatException('手表音频内容与来源不匹配');
    }
    return value;
  }

  Future<void> play(WatchPart part) async {
    await driver.native.call('playPart', {'id': part.id});
  }

  Future<void> stopPlayback() async {
    await driver.native.call('stopPlayback');
  }

  Future<bool> configureHealth(bool enable, Set<String> types) async {
    if (!supported ||
        busy ||
        !types.every(['heart', 'hrv', 'steps', 'sleep'].contains) ||
        enable && types.isEmpty) return false;
    final generation = ++_healthGeneration;
    busy = true;
    _changed();
    try {
      if (await driver.native.call('healthConfigure',
              {'enabled': enable, 'types': types.toList()..sort()}) !=
          true) throw const FormatException();
      if (!disposed && generation == _healthGeneration) {
        healthSamples = [];
        healthEnabled = enable;
        healthTypes = Set.of(types);
        if (enable) await refreshHealth();
      }
      return true;
    } catch (_) {
      message = '健康读取设置未完成；不会上传健康数据。';
      return false;
    } finally {
      if (!disposed && generation == _healthGeneration) {
        busy = false;
        _changed();
      }
    }
  }

  Future<void> refreshHealth() async {
    final generation = _healthGeneration;
    if (!supported) return;
    try {
      final v = Map<String, dynamic>.from(
          await driver.native.call('healthSnapshot') as Map);
      if (disposed || generation != _healthGeneration) return;
      healthEnabled = v['enabled'] == true;
      healthTypes = (v['types'] as List? ?? []).whereType<String>().toSet();
      final samples = <Map<String, dynamic>>[];
      for (final item in v['samples'] as List? ?? []) {
        final row = Map<String, dynamic>.from(item as Map);
        if (!['heartRate', 'restingHeartRate', 'hrvSDNN', 'steps', 'sleep']
                .contains(row['kind']) ||
            row['value'] is! num ||
            !(row['value'] as num).isFinite ||
            DateTime.tryParse(row['to']?.toString() ?? '') == null ||
            row['source'] is! String) throw const FormatException();
        samples.add(row);
      }
      healthSamples = healthEnabled ? samples : [];
    } catch (_) {
      healthSamples = [];
      message = '健康数据暂不可读，请解锁后重试；无数据不代表未授权。';
    }
    _changed();
  }

  @override
  void dispose() {
    disposed = true;
    _generation++;
    _healthGeneration++;
    unawaited(_changes?.cancel());
    super.dispose();
  }
}

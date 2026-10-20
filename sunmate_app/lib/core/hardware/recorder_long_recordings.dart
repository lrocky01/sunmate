import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

enum LongRecordingPurpose { meeting, lifelog }

extension LongRecordingPurposeLabel on LongRecordingPurpose {
  String get label => this == LongRecordingPurpose.meeting ? '会议' : '随身记录';
}

enum LongRecordingObservation {
  recording,
  connectionLost,
  unconfirmed,
  stopped
}

/// 这里只保存会话元数据，不代表音频分段已经下载或保存。
class RecorderLongSession {
  final String serialNumber;
  final int sessionId;
  final LongRecordingPurpose? purpose;
  final DateTime firstObservedAt;
  final DateTime? stopObservedAt;
  final LongRecordingObservation observation;
  const RecorderLongSession(
      {required this.serialNumber,
      required this.sessionId,
      required this.purpose,
      required this.firstObservedAt,
      this.stopObservedAt,
      required this.observation});

  String get purposeLabel => purpose?.label ?? '用途未确认';
  String get observationLabel => switch (observation) {
        LongRecordingObservation.recording => '卡片正在长录',
        LongRecordingObservation.connectionLost => '连接已断开，录音状态待确认',
        LongRecordingObservation.unconfirmed => '录音状态待卡片确认',
        LongRecordingObservation.stopped => '已收到结束事件，音频未同步',
      };

  RecorderLongSession withObservation(LongRecordingObservation value,
          {DateTime? stop}) =>
      RecorderLongSession(
          serialNumber: serialNumber,
          sessionId: sessionId,
          purpose: purpose,
          firstObservedAt: firstObservedAt,
          stopObservedAt: stop ?? stopObservedAt,
          observation: value);

  Map<String, Object?> toJson() => {
        'sn': serialNumber,
        'session': sessionId,
        'purpose': purpose?.name,
        'firstObserved': firstObservedAt.toUtc().toIso8601String(),
        'stopObserved': stopObservedAt?.toUtc().toIso8601String(),
        'observation': observation.name
      };

  static RecorderLongSession parse(Object? raw) {
    if (raw is! Map ||
        !validSerial(raw['sn']) ||
        raw['session'] is! int ||
        (raw['session'] as int) <= 0 ||
        raw['firstObserved'] is! String ||
        (raw['stopObserved'] != null && raw['stopObserved'] is! String)) {
      throw const FormatException('会话资料无效');
    }
    final purpose = raw['purpose'] == null
        ? null
        : LongRecordingPurpose.values
            .where((v) => v.name == raw['purpose'])
            .single;
    final observation = LongRecordingObservation.values
        .where((v) => v.name == raw['observation'])
        .single;
    return RecorderLongSession(
        serialNumber: raw['sn'] as String,
        sessionId: raw['session'] as int,
        purpose: purpose,
        firstObservedAt: DateTime.parse(raw['firstObserved'] as String),
        stopObservedAt: raw['stopObserved'] == null
            ? null
            : DateTime.parse(raw['stopObserved'] as String),
        observation: observation);
  }

  static bool validSerial(Object? value) =>
      value is String && RegExp(r'^[A-Z]{2}[0-9]{14}$').hasMatch(value);
}

abstract interface class RecorderLongSessionStore {
  Future<String?> read();
  Future<void> write(String value);
}

class PreferenceLongSessionStore implements RecorderLongSessionStore {
  static const storageKey = 'sunmate_long_recording_sessions_v1';
  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(storageKey);
  @override
  Future<void> write(String value) async {
    if (!await (await SharedPreferences.getInstance())
        .setString(storageKey, value)) {
      throw StateError('本机会话资料未保存');
    }
  }
}

class RecorderLongRecordings {
  final bool loaded;
  final bool saving;
  final LongRecordingPurpose preferred;
  final RecorderLongSession? active;
  final List<RecorderLongSession> sessions;
  final String? message;
  final bool failed;
  final bool cardRecording;
  final bool unsavedSessions;
  const RecorderLongRecordings(
      {this.loaded = false,
      this.saving = false,
      this.preferred = LongRecordingPurpose.meeting,
      this.active,
      this.sessions = const [],
      this.message,
      this.failed = false,
      this.cardRecording = false,
      this.unsavedSessions = false});
  bool get canChoose =>
      loaded &&
      !saving &&
      !cardRecording &&
      active?.observation != LongRecordingObservation.recording;
}

/// 按接收到的事件顺序保存归属。持久化异常局限于此，不影响真实AES连接。
class RecorderLongRecordingController {
  static const maximumSessions = 1000;
  static const maximumStoredCharacters = 512 * 1024;
  final RecorderLongSessionStore store;
  final bool Function() isCardRecording;
  final void Function() onChanged;
  final DateTime Function() now;
  Future<void>? _loading;
  Future<void> _work = Future.value();
  bool _loaded = false;
  bool _saving = false;
  bool _failed = false;
  bool _unsavedSessions = false;
  bool _disposed = false;
  String? _message;
  LongRecordingPurpose _preferred = LongRecordingPurpose.meeting;
  LongRecordingPurpose _initialPreferred = LongRecordingPurpose.meeting;
  List<RecorderLongSession> _sessions = [];
  RecorderLongSession? _active;

  RecorderLongRecordingController(
      {required this.store,
      required this.isCardRecording,
      required this.onChanged,
      DateTime Function()? now})
      : now = now ?? DateTime.now;

  RecorderLongRecordings get snapshot => RecorderLongRecordings(
      loaded: _loaded,
      saving: _saving,
      preferred: _preferred,
      active: _active,
      sessions: List.unmodifiable(_sessions.reversed),
      message: _message,
      failed: _failed,
      cardRecording: isCardRecording(),
      unsavedSessions: _unsavedSessions);

  void _changed() {
    if (!_disposed) onChanged();
  }

  Future<void> initialize() {
    if (_loaded || _disposed) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    try {
      final raw = await store.read();
      if (_disposed) return;
      var preferred = LongRecordingPurpose.meeting;
      var records = <RecorderLongSession>[];
      if (raw != null) {
        if (raw.length > maximumStoredCharacters)
          throw const FormatException('会话资料过大');
        final value = jsonDecode(raw);
        if (value is! Map ||
            value['version'] != 1 ||
            value['sessions'] is! List ||
            (value['sessions'] as List).length > maximumSessions) {
          throw const FormatException('会话资料版本或列表无效');
        }
        preferred = LongRecordingPurpose.values
            .where((v) => v.name == value['preferred'])
            .single;
        records =
            (value['sessions'] as List).map(RecorderLongSession.parse).toList();
        final seen = <String>{};
        for (final record in records) {
          if (!seen.add('${record.serialNumber}:${record.sessionId}')) {
            throw const FormatException('会话身份重复');
          }
        }
      }
      _preferred = preferred;
      _initialPreferred = preferred;
      // 上次进程中的“正在录音”不是本次卡片状态证明。
      _sessions = records
          .map((record) =>
              record.observation == LongRecordingObservation.recording
                  ? record.withObservation(LongRecordingObservation.unconfirmed)
                  : record)
          .toList();
      _active = null;
      _loaded = true;
      _message = null;
      _failed = false;
    } catch (_) {
      _failed = true;
      _message = '本机会话资料读取失败，原资料保留；请重试读取。';
    }
    _changed();
  }

  Future<bool> _enqueue(Future<bool> Function() action) {
    final result = Completer<bool>();
    _work = _work.then((_) async {
      await initialize();
      if (!_loaded || _disposed) {
        result.complete(false);
        return;
      }
      try {
        result.complete(await action());
      } catch (_) {
        _failed = true;
        _message = '本机会话资料保存未完成，请重试当前操作；卡片连接和业务密钥保持。';
        result.complete(false);
      }
      _changed();
    });
    return result.future;
  }

  Future<void> _persist({LongRecordingPurpose? preferred}) async {
    final value = jsonEncode({
      'version': 1,
      'preferred': (preferred ?? _preferred).name,
      'sessions': _sessions.map((s) => s.toJson()).toList()
    });
    if (value.length > maximumStoredCharacters)
      throw const FormatException('会话资料过大');
    _saving = true;
    _changed();
    try {
      await store.write(value);
      _unsavedSessions = false;
    } finally {
      _saving = false;
    }
  }

  Future<bool> choose(LongRecordingPurpose purpose) => _enqueue(() async {
        if (!snapshot.canChoose) {
          _failed = true;
          _message = '请先结束当前录音；本次会话用途不会被更改。';
          return false;
        }
        await _persist(preferred: purpose);
        if (_disposed) return false;
        _preferred = purpose;
        _failed = false;
        _message = '已保存，下次新长录用于${purpose.label}。';
        return true;
      });

  int _index(String sn, int session) => _sessions
      .indexWhere((r) => r.serialNumber == sn && r.sessionId == session);

  Future<bool> started(String sn, int session, {bool observedStart = true}) {
    final observedAt = now();
    // 保存下一次用途的异步操作不能追溯改变已经发生的开始事件。
    final fixedPurpose = _loaded ? _preferred : null;
    return _enqueue(() async {
      if (!RecorderLongSession.validSerial(sn) || session <= 0) {
        _failed = true;
        _message = '设备身份资料不完整，本次会话用途未保存；连接与业务密钥保持。';
        return false;
      }
      final index = _index(sn, session);
      // 重复开始/重连同会话，不修改已固定用途或首次观察时间。
      if (index >= 0 &&
          _sessions[index].observation == LongRecordingObservation.stopped)
        return !_unsavedSessions;
      if (index >= 0 &&
          _sessions[index].observation == LongRecordingObservation.recording &&
          _active?.serialNumber == sn &&
          _active?.sessionId == session) return !_unsavedSessions;
      if (index < 0 && _sessions.length >= maximumSessions) {
        _failed = true;
        _message = '本机会话记录已达上限，未删除已有记录。';
        return false;
      }
      if (_active != null &&
          (_active!.serialNumber != sn || _active!.sessionId != session)) {
        final old = _index(_active!.serialNumber, _active!.sessionId);
        if (old >= 0 &&
            _sessions[old].observation == LongRecordingObservation.recording) {
          _sessions[old] = _sessions[old]
              .withObservation(LongRecordingObservation.unconfirmed);
        }
      }
      final record = index < 0
          ? RecorderLongSession(
              serialNumber: sn,
              sessionId: session,
              purpose: observedStart ? fixedPurpose ?? _initialPreferred : null,
              firstObservedAt: observedAt,
              observation: LongRecordingObservation.recording)
          : _sessions[index]
              .withObservation(LongRecordingObservation.recording);
      if (index < 0)
        _sessions.add(record);
      else
        _sessions[index] = record;
      _active = record;
      _unsavedSessions = true;
      await _persist();
      _failed = false;
      _message = '已记录本次长录用途；音频文件尚未同步。';
      return true;
    });
  }

  Future<bool> stopped(String sn, int session) {
    final observedAt = now();
    return _enqueue(() async {
      final index = _index(sn, session);
      if (index < 0) return false;
      if (_sessions[index].observation == LongRecordingObservation.stopped)
        return !_unsavedSessions;
      final record = _sessions[index]
          .withObservation(LongRecordingObservation.stopped, stop: observedAt);
      _sessions[index] = record;
      if (_active?.serialNumber == sn && _active?.sessionId == session)
        _active = null;
      _unsavedSessions = true;
      await _persist();
      _failed = false;
      _message = '已记录长录结束；音频文件尚未同步。';
      return true;
    });
  }

  Future<bool> connectionLost() => _enqueue(() async {
        final active = _active;
        if (active == null) return true;
        final index = _index(active.serialNumber, active.sessionId);
        if (index < 0 ||
            _sessions[index].observation != LongRecordingObservation.recording)
          return true;
        final record =
            active.withObservation(LongRecordingObservation.connectionLost);
        _sessions[index] = record;
        _active = record;
        _unsavedSessions = true;
        await _persist();
        _failed = false;
        _message = '连接已断开，未将本次长录标为已结束或已保存音频。';
        return true;
      });

  Future<bool> retrySave() => _enqueue(() async {
        await _persist();
        _failed = false;
        _message = '本机会话用途资料已保存；不代表音频文件已同步。';
        return true;
      });

  Future<void> dispose() async {
    await _work;
    _disposed = true;
  }
}

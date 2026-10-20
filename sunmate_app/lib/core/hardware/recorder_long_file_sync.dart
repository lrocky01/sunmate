import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../audio/recorder_local_audio.dart';
import '../ble/telink_long_files.dart';
import 'recorder_long_file_models.dart';
import 'recorder_long_file_store.dart';
import 'recorder_long_recordings.dart';

class _FileSyncFailure implements Exception {
  final String message;
  const _FileSyncFailure(this.message);
}

class _Download {
  final RecorderLongFileEntry entry;
  final RandomAccessFile output;
  final Completer<void> finished = Completer<void>();
  bool metadataSeen = false;
  bool completionSeen = false;
  int received = 0;
  int queuedBytes = 0;
  final bool live;
  _Download(this.entry, this.output, {this.live = false});
}

/// Telink没有wire传输ID；一个物理连接只允许一个目录/文件操作。
/// 超时/污染后锁住文件通道直到新连接，不猜测停止命令或offset重试。
class RecorderLongFileSync {
  final RecorderLongFileStore store;
  final RecorderLocalAudio audio;
  final Future<void> Function(List<int>) send;
  final bool Function() isReady;
  final bool Function() isIdle;
  final String Function() serialNumber;
  final LongRecordingPurpose? Function(int) purpose;
  final void Function() onChanged;
  final Duration progressTimeout;
  final Duration tailInterval;
  final int maximumTailScans;
  final Duration autoSyncDelay;
  final Duration livePollInterval;
  final Future<void> Function()? requestStatus;
  final Map<String, RecorderLongAudioRecord> _records = {};
  final Map<String, int> _knownLastParts = {};
  final Set<int> _closedParts = {};
  final Set<int> _pendingFinal = {};
  final Set<int> _stoppedSessions = {};
  bool _pendingLive = false;
  int? _activeSession;
  int? _activePart;
  final Map<int, Future<void>> _sessionPreparations = {};
  Timer? _autoTimer;
  Timer? _livePoll;
  bool _statusQueryPending = false;
  bool _automaticPaused = false;
  Completer<List<RecorderLongFileEntry>>? _listing;
  final Map<String, RecorderLongFileEntry> _listEntries = {};
  _Download? _download;
  Future<void> _receiveWork = Future.value();
  Future<void>? _loading;
  Future<bool>? _operation;
  Timer? _watchdog;
  int _generation = 0;
  bool _loaded = false;
  bool _failed = false;
  bool _poisoned = false;
  bool _disposed = false;
  String? _message;

  RecorderLongFileSync(
      {required this.store,
      required this.audio,
      required this.send,
      required this.isReady,
      required this.isIdle,
      required this.serialNumber,
      required this.purpose,
      required this.onChanged,
      this.progressTimeout = const Duration(seconds: 15),
      this.tailInterval = const Duration(seconds: 1),
      this.autoSyncDelay = const Duration(milliseconds: 250),
      this.livePollInterval = const Duration(seconds: 5),
      this.requestStatus,
      this.maximumTailScans = 5});

  RecorderLongFileLibrary get snapshot => RecorderLongFileLibrary(
      loaded: _loaded,
      busy: _operation != null,
      failed: _failed,
      needsReconnect: _poisoned,
      message: _message,
      activeSessionId: _activeSession,
      recordings: List.unmodifiable(_records.values.toList()
        ..sort((a, b) => b.sessionId.compareTo(a.sessionId))));

  void _changed() {
    if (!_disposed) onChanged();
  }

  String _key(String sn, int session) => '$sn:$session';

  Future<void> initialize() =>
      _loading ??= _load().whenComplete(() => _loading = null);
  Future<void> _load() async {
    try {
      final records = await store.loadRecords();
      if (_disposed) return;
      for (final record in records) {
        final key = _key(record.serialNumber, record.sessionId);
        // 旧进程的活动状态不是本次设备状态证明；不覆盖正在运行的增量进度。
        final current = _records[key];
        if (current != null) {
          _records[key] =
              current.copyWith(purpose: current.purpose ?? record.purpose);
          continue;
        }
        _records.putIfAbsent(
            key,
            () => record.stage == RecorderLongFileStage.recording
                ? record.copyWith(
                    stage: RecorderLongFileStage.incomplete,
                    message: '上次长录状态待确认，已同步分段保留。')
                : record);
      }
      _loaded = true;
      _failed = false;
      _message = null;
    } catch (_) {
      _failed = true;
      _message = '本地长录资料读取失败，原文件保留；请重试读取。';
    }
    _changed();
  }

  /// 仅在新GATT物理连接真实AES验证完成后调用。
  void connected() {
    connectionLost();
    _poisoned = false;
    _changed();
  }

  void connectionLost() {
    _markActiveUnconfirmed();
    ++_generation;
    _watchdog?.cancel();
    _autoTimer?.cancel();
    _autoTimer = null;
    _livePoll?.cancel();
    _livePoll = null;
    _pendingLive = false;
    _pendingFinal.clear();
    _stoppedSessions.clear();
    _activeSession = null;
    _activePart = null;
    _closedParts.clear();
    _sessionPreparations.clear();
    _statusQueryPending = false;
    _automaticPaused = false;
    _failWaiters(const _FileSyncFailure('连接已变化；已保存分段保留，重连验证后可继续。'));
  }

  void transferError() => _poison('文件接收失败，已暂停同步；普通重连后可继续。');

  /// 来自已鉴权状态回报/明确段关闭提示的最小尾段锚点；不猜测不存在的总段数。
  void observePart(int session, int part) {
    if (!isReady() || session <= 0 || part < 0 || part >= 10000) return;
    final key = _key(serialNumber(), session);
    if (part > (_knownLastParts[key] ?? -1)) _knownLastParts[key] = part;
  }

  /// LONG start 和带会话身份的当前状态；恢复时不能借用上次连接的闭合证明。
  void recordingStarted(int session,
      {int? activePart, Future<void>? preparation}) {
    if (!isReady() || session <= 0 || _stoppedSessions.contains(session))
      return;
    if (preparation != null) _sessionPreparations[session] = preparation;
    if (_activeSession != session) {
      _markActiveUnconfirmed();
      _activeSession = session;
      _activePart = null;
      _closedParts.clear();
      _pendingLive = false;
      final key = _key(serialNumber(), session);
      final record = _records[key] ??
          RecorderLongAudioRecord(
              serialNumber: serialNumber(),
              sessionId: session,
              purpose: purpose(session));
      _setRecord(record.copyWith(
          stage: RecorderLongFileStage.recording,
          message: '录音继续进行；仅同步已确认关闭的分段，停止后完整归档。'));
    }
    var advanced = false;
    if (activePart != null && activePart >= 0 && activePart < 10000) {
      observePart(session, activePart);
      if (_activePart == null || activePart > _activePart!) {
        _activePart = activePart;
        advanced = true;
      } else if (activePart < _activePart!) {
        // 不能把回退状态当成已经关闭，撤销本次推断并等待新的可靠提示。
        _activePart = null;
        _closedParts.clear();
        _pendingLive = false;
        _message = '卡片段号发生回退，已暂停推断关闭的分段；等待新状态。';
      }
    }
    if (advanced && activePart! > 0) {
      _pendingLive = true;
      _automaticPaused = false;
      _scheduleAutomatic();
    }
    _livePoll ??= Timer.periodic(livePollInterval, (_) {
      if (_disposed ||
          !isReady() ||
          _poisoned ||
          _automaticPaused ||
          _activeSession == null) return;
      if (_operation == null && requestStatus != null && !_statusQueryPending) {
        final generation = _generation;
        _statusQueryPending = true;
        unawaited(requestStatus!().catchError((Object _) {}).whenComplete(() {
          if (generation == _generation) _statusQueryPending = false;
        }));
      }
      if (_closedParts.isNotEmpty || (_activePart ?? 0) > 0) {
        _pendingLive = true;
        _scheduleAutomatic();
      }
    });
    _changed();
  }

  void segmentClosed(int session, int part) {
    observePart(session, part);
    if (!isReady() || session != _activeSession || part < 0 || part >= 10000)
      return;
    if (_closedParts.add(part)) {
      _pendingLive = true;
      _automaticPaused = false;
      _scheduleAutomatic();
    }
  }

  bool wasStopped(int session) => _stoppedSessions.contains(session);

  void recordingStopped(int session) {
    if (!isReady() || session != _activeSession) return;
    _activeSession = null;
    _activePart = null;
    _closedParts.clear();
    _pendingLive = false;
    _livePoll?.cancel();
    _livePoll = null;
    _pendingFinal.add(session);
    _stoppedSessions.add(session);
    final record = _records[_key(serialNumber(), session)];
    if (record != null) {
      _setRecord(record.copyWith(
          stage: RecorderLongFileStage.waitingForTail,
          message: '已停止录音，当前分段提交后补扫尾段并确认完整性。'));
    }
    _automaticPaused = false;
    _scheduleAutomatic();
    _changed();
  }

  /// 实时录音或无法匹配当前会话的状态不能借用LONG闭合证明。
  void recordingStateUnknown() {
    _markActiveUnconfirmed();
    _activeSession = null;
    _activePart = null;
    _closedParts.clear();
    _pendingLive = false;
    _livePoll?.cancel();
    _livePoll = null;
    _changed();
  }

  void _markActiveUnconfirmed() {
    final session = _activeSession;
    if (session == null) return;
    final key = _key(serialNumber(), session);
    final record = _records[key];
    if (record != null && !record.canPlay) {
      _records[key] = record.copyWith(
          stage: RecorderLongFileStage.incomplete,
          message: '当前录音状态待确认，已提交分段保留；确认状态后可继续。');
    }
  }

  void _scheduleAutomatic() {
    if (_disposed ||
        _poisoned ||
        _automaticPaused ||
        !isReady() ||
        _autoTimer != null) return;
    if (_operation != null) return; // 完成回调会恢复排队，不并行提交命令。
    if (!((_pendingFinal.isNotEmpty && isIdle()) ||
        (_pendingLive && _activeSession != null))) return;
    _autoTimer = Timer(autoSyncDelay, () {
      _autoTimer = null;
      unawaited(_drainAutomatic());
    });
  }

  Future<void> _drainAutomatic() async {
    if (_disposed ||
        _operation != null ||
        _poisoned ||
        _automaticPaused ||
        !isReady()) return;
    int? session;
    if (isIdle() && _pendingFinal.isNotEmpty) {
      session = _pendingFinal.first;
      _pendingFinal.remove(session);
    } else if (_pendingLive && _activeSession != null) {
      session = _activeSession;
      _pendingLive = false;
    }
    if (session == null) return;
    final generation = _generation;
    final ok = await sync(session);
    if (generation != _generation) return;
    if (!ok) _automaticPaused = true;
    _scheduleAutomatic();
  }

  void _failWaiters(Object error) {
    final listing = _listing;
    if (listing != null && !listing.isCompleted) listing.completeError(error);
    final downloading = _download;
    if (downloading != null && !downloading.finished.isCompleted) {
      downloading.finished.completeError(error);
    }
  }

  void _poison(String message) {
    if (_disposed) return;
    _poisoned = true;
    _failed = true;
    _message = message;
    _watchdog?.cancel();
    _failWaiters(_FileSyncFailure(message));
    _changed();
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(
        progressTimeout, () => _poison('文件同步超时，已暂停接收；请普通断开并重连后继续，已保存分段保留。'));
  }

  void _check(int generation, {bool idle = true}) {
    if (_disposed || generation != _generation || !isReady()) {
      throw const _FileSyncFailure('连接已变化；重连验证后可继续，原分段保留。');
    }
    if (_poisoned) throw const _FileSyncFailure('文件通道待重新连接，未在旧链路盲目重试。');
    if (idle && !isIdle()) {
      throw const _FileSyncFailure('卡片尚未确认停止录音；请结束录音并读取状态后再保存。');
    }
  }

  Future<bool> _run(Future<void> Function(int) work,
      {bool allowRecording = false}) {
    if (_operation != null) return Future.value(false);
    final operation = _execute(work, allowRecording: allowRecording);
    _operation = operation;
    _changed();
    unawaited(operation.whenComplete(() {
      if (identical(_operation, operation)) _operation = null;
      _changed();
      _scheduleAutomatic();
    }));
    return operation;
  }

  Future<bool> _execute(Future<void> Function(int) work,
      {bool allowRecording = false}) async {
    final generation = _generation;
    try {
      if (!_loaded) await initialize();
      if (!_loaded) throw const _FileSyncFailure('本地长录资料未能读取，原资料保留。');
      _check(generation, idle: !allowRecording || _activeSession == null);
      if (!RecorderLongSession.validSerial(serialNumber())) {
        throw const _FileSyncFailure('尚无本次已验证的卡片身份，未读取文件。');
      }
      _failed = false;
      await work(generation);
      return true;
    } catch (error) {
      if (generation != _generation || _disposed) return false;
      _failed = true;
      _message = error is _FileSyncFailure
          ? error.message
          : '长录保存未完成，原录音及已提交分段保留；请检查本地存储后重试。';
      _changed();
      return false;
    }
  }

  Future<bool> refresh() => _run((generation) async {
        _message = '正在读取卡片录音目录…';
        _changed();
        final entries = await _readList(generation);
        _check(generation, idle: false);
        await _publishCatalog(entries);
        _message = entries.isEmpty
            ? '卡片暂未列出长录文件，本地已保存音频仍保留。'
            : _activeSession != null
                ? '目录已读取；正在录音，仅同步已确认关闭的分段。'
                : '目录已读取；可选择录音保存到手机。';
        _changed();
      }, allowRecording: true);

  Future<List<RecorderLongFileEntry>> _readList(int generation) async {
    _check(generation, idle: false);
    final completion = Completer<List<RecorderLongFileEntry>>();
    final future = completion.future;
    // 写命令等待期间也可能先收到异步失败；立即注册错误观察者。
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    _listing = completion;
    _listEntries.clear();
    _armWatchdog();
    try {
      await Future.any<void>([
        send(TelinkLongFileEvent.listCommand()),
        future.then<void>((_) {}),
      ]);
      final result = await future;
      _check(generation, idle: false);
      return result;
    } catch (error) {
      if (generation == _generation && !_poisoned) {
        _poison('目录读取未完成；请普通断开并重连后继续，未清除任何录音。');
      }
      rethrow;
    } finally {
      _watchdog?.cancel();
      if (identical(_listing, completion)) _listing = null;
      _listEntries.clear();
    }
  }

  Future<String> _fingerprint(List<RecorderLongFileEntry> entries) async =>
      (await Sha256()
              .hash(utf8.encode(entries.map((e) => e.signature).join('\n'))))
          .bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

  Future<void> _publishCatalog(List<RecorderLongFileEntry> entries) async {
    final sn = serialNumber();
    final sessions = entries.map((e) => e.sessionId).toSet();
    for (final session in sessions) {
      final parts = entries.where((e) => e.sessionId == session).toList()
        ..sort((a, b) => a.part.compareTo(b.part));
      final key = _key(sn, session);
      final previous = _records[key];
      final fingerprint = await _fingerprint(parts);
      if (previous?.canPlay == true) {
        if (previous!.inventoryFingerprint == fingerprint) continue;
        final incomplete = previous.copyWith(
            stage: RecorderLongFileStage.incomplete,
            message: '卡片目录已变化，旧音频保留；请继续恢复以补齐当前版本。');
        _records[key] = incomplete;
        await store.saveRecord(incomplete);
        continue;
      }
      _records[key] = RecorderLongAudioRecord(
          serialNumber: sn,
          sessionId: session,
          purpose: previous?.purpose ?? purpose(session),
          stage: previous?.stage ?? RecorderLongFileStage.discovered,
          totalParts: parts.length,
          sourceBytes: parts.fold(0, (a, b) => a + b.size),
          downloadedParts: previous?.downloadedParts ?? 0,
          inventoryFingerprint: fingerprint);
    }
  }

  void _setRecord(RecorderLongAudioRecord record) {
    _records[_key(record.serialNumber, record.sessionId)] = record;
    _changed();
  }

  Future<bool> sync(int session) {
    _automaticPaused = false;
    return _run((generation) async {
      if (_activeSession != null && _activeSession != session && !isIdle()) {
        throw const _FileSyncFailure('正在录制其它会话，未切换文件接收器。');
      }
      if (_activeSession == session) {
        await _syncClosed(session, generation);
      } else {
        await _syncFinal(session, generation);
      }
    }, allowRecording: true);
  }

  bool _closedForCurrent(int session, int part) =>
      _activeSession == session &&
      (_activePart != null ? part < _activePart! : _closedParts.contains(part));

  bool _mayRead(_Download download) =>
      isIdle() ||
      (download.live &&
          _closedForCurrent(download.entry.sessionId, download.entry.part));

  void _checkDownload(int generation, RecorderLongFileEntry entry, bool live) {
    _check(generation, idle: false);
    if (!isIdle() &&
        !(live && _closedForCurrent(entry.sessionId, entry.part))) {
      throw const _FileSyncFailure('分段关闭依据或当前会话已变化，未继续读取活动段。');
    }
  }

  Future<void> _syncClosed(int session, int generation) async {
    _check(generation, idle: false);
    await _sessionPreparations[session]?.timeout(progressTimeout);
    _check(generation, idle: false);
    // 等待准备期间收到stop时，让已排队的最终流程处理，不在这里猜测尾段。
    if (_activeSession != session) return;
    final sn = serialNumber();
    final previous = _records[_key(sn, session)];
    var record = (previous ??
            RecorderLongAudioRecord(serialNumber: sn, sessionId: session))
        .copyWith(
            purpose: previous?.purpose ?? purpose(session),
            stage: RecorderLongFileStage.recording,
            downloadedParts: 0,
            receivedBytes: 0);
    final committed = <int, RecorderCommittedSegment>{};
    try {
      final all = await _readList(generation);
      _check(generation, idle: false);
      if (_activeSession != session) return;
      await _publishCatalog(all);
      final entries = all.where((e) => e.sessionId == session).toList()
        ..sort((a, b) => a.part.compareTo(b.part));
      record = record.copyWith(
          totalParts: entries.length,
          sourceBytes: entries.fold<int>(0, (a, e) => a + e.size));
      if (record.sourceBytes > 4 * 1024 * 1024 * 1024) {
        throw const _FileSyncFailure('录音超过本地4GiB处理上限，原始录音保留。');
      }
      for (final entry in entries) {
        if (_activeSession != session) break;
        // 关闭提示只证明该part，不将高段关闭扩展为所有低段已关闭。
        if (entry.size <= 0 || !_closedForCurrent(session, entry.part))
          continue;
        _checkDownload(generation, entry, true);
        var segment =
            await store.findSegment(sn, session, entry.part, entry.size);
        _checkDownload(generation, entry, true);
        if (segment == null) {
          record = record.copyWith(
              stage: RecorderLongFileStage.downloading,
              message: '录音继续进行，正在保存已关闭的第${entry.part}段。');
          _setRecord(record);
          segment = await _readSegment(sn, entry, generation, (received) {
            record = record.copyWith(
                receivedBytes:
                    committed.values.fold<int>(0, (a, e) => a + e.size) +
                        received);
            _setRecord(record);
          }, live: true);
        }
        _check(generation, idle: false);
        committed[entry.part] = segment;
        record = record.copyWith(
            downloadedParts: committed.length,
            receivedBytes: committed.values.fold<int>(0, (a, e) => a + e.size),
            stage: _activeSession == session
                ? RecorderLongFileStage.recording
                : RecorderLongFileStage.waitingForTail,
            message: _activeSession == session
                ? '已保存${committed.length}个已关闭分段，整场录音仍在进行。'
                : '已停止录音，已关闭分段保留；正在等待补扫尾段。');
        await store.saveRecord(record);
        _check(generation, idle: false);
        _setRecord(record);
      }
      if (_activeSession == session) {
        record = record.copyWith(
            stage: RecorderLongFileStage.recording,
            message: '已保存${committed.length}个已关闭分段；当前写入段等待关闭，停止后完整归档。');
        await store.saveRecord(record);
        _check(generation, idle: false);
        _setRecord(record);
        _message = '已同步可确认关闭的分段，录音继续进行；尚未确认整场完整。';
      }
    } catch (_) {
      final incomplete = record.copyWith(
          stage: RecorderLongFileStage.incomplete,
          message: '增量同步暂停，已提交分段保留；未将录音标记为结束或完整。');
      _setRecord(incomplete);
      try {
        await store.saveRecord(incomplete);
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _syncFinal(int session, int generation) async {
    _check(generation);
    if (session <= 0) throw const _FileSyncFailure('录音会话无效。');
    await _sessionPreparations[session]?.timeout(progressTimeout);
    _check(generation);
    final sn = serialNumber();
    final existing = _records[_key(sn, session)];
    var record = (existing ??
            RecorderLongAudioRecord(serialNumber: sn, sessionId: session))
        .copyWith(purpose: existing?.purpose ?? purpose(session));
    final committed = <int, RecorderCommittedSegment>{};
    try {
      List<RecorderLongFileEntry>? previous;
      List<RecorderLongFileEntry>? settled;
      // 停止后的首扫不能当最终清单；最多5轮，至少连续两轮一致。
      for (var scan = 0; scan < maximumTailScans; scan++) {
        _check(generation);
        record = record.copyWith(
            stage: RecorderLongFileStage.waitingForTail,
            message: '正在补扫尾段（${scan + 1}/$maximumTailScans）');
        _setRecord(record);
        final all = await _readList(generation);
        await _publishCatalog(all);
        final entries = all.where((e) => e.sessionId == session).toList()
          ..sort((a, b) => a.part.compareTo(b.part));
        final knownTail = _knownLastParts[_key(sn, session)];
        final contiguous = entries.isNotEmpty &&
            entries.every((e) => e.size > 0) &&
            (knownTail == null || entries.last.part >= knownTail) &&
            List.generate(entries.length, (i) => entries[i].part == i)
                .every((v) => v);
        if (contiguous &&
            previous != null &&
            _sameInventory(entries, previous)) {
          settled = entries;
          break;
        }
        previous = entries;
        if (scan + 1 < maximumTailScans)
          await Future<void>.delayed(tailInterval);
      }
      _check(generation);
      if (settled == null) {
        throw const _FileSyncFailure('目录尚未稳定、尾段未关闭或存在缺段；未将整场录音标为已保存。');
      }
      final bytes = settled.fold<int>(0, (sum, e) => sum + e.size);
      if (bytes > 4 * 1024 * 1024 * 1024) {
        throw const _FileSyncFailure('本次录音超过本地4GiB处理上限，未删除原录音。');
      }
      record = record.copyWith(
          totalParts: settled.length,
          sourceBytes: bytes,
          stage: RecorderLongFileStage.downloading,
          downloadedParts: 0,
          receivedBytes: 0,
          inventoryFingerprint: await _fingerprint(settled));
      _setRecord(record);
      for (final entry in settled) {
        _check(generation);
        var part = await store.findSegment(sn, session, entry.part, entry.size);
        _check(generation);
        part ??= await _readSegment(sn, entry, generation, (received) {
          record = record.copyWith(
              receivedBytes:
                  committed.values.fold<int>(0, (sum, p) => sum + p.size) +
                      received);
          _setRecord(record);
        });
        _check(generation);
        committed[entry.part] = part;
        record = record.copyWith(
            downloadedParts: committed.length,
            receivedBytes:
                committed.values.fold<int>(0, (sum, p) => sum + p.size));
        _setRecord(record);
      }
      // 下载期间仍可能有尾段关闭，最终再读目录，变化则保留已提交段等待下一次恢复。
      for (var scan = 0; scan < 2; scan++) {
        if (scan != 0) await Future<void>.delayed(tailInterval);
        final finalList = (await _readList(generation))
            .where((e) => e.sessionId == session)
            .toList()
          ..sort((a, b) => a.part.compareTo(b.part));
        if (!_sameInventory(settled, finalList)) {
          throw const _FileSyncFailure('保存过程中目录已变化；已完成分段保留，请继续恢复补齐尾段。');
        }
      }
      _check(generation);
      record = record.copyWith(stage: RecorderLongFileStage.preparing);
      _setRecord(record);
      final ogg = await store.assemble(sn, session,
          committed.values.toList()..sort((a, b) => a.part.compareTo(b.part)));
      _check(generation);
      record = record.copyWith(relativeOggPath: ogg.relativePath);
      _setRecord(record);
      final playable = await audio.prepare(ogg.relativePath);
      _check(generation);
      if (playable.frames <= 0 ||
          playable.durationMs <= 0 ||
          playable.sampleRate != 16000 ||
          (playable.durationMs - ogg.durationMs).abs() > 1 ||
          playable.frames * 1000 ~/ playable.sampleRate !=
              playable.durationMs) {
        throw const _FileSyncFailure('音频未通过本地实际解码，原始分段保留。');
      }
      // 原生解码路径还需由存储层验证位于同卡同会话的沙箱子目录。
      final playableFile = await store.resolveRelative(playable.relativePath);
      if (await playableFile.length() <= 44 ||
          !playable.relativePath
              .startsWith('recorder_long_audio_v1/$sn/s$session/')) {
        throw const _FileSyncFailure('本地播放文件无效，未报告保存成功。');
      }
      _check(generation);
      record = record.copyWith(
          stage: RecorderLongFileStage.saved,
          relativePlayablePath: playable.relativePath,
          durationMs: playable.durationMs,
          savedAt: DateTime.now(),
          message: '已校验分段并完成本地音频解码。');
      await store.saveRecord(record);
      _check(generation);
      _setRecord(record);
      _message = '录音已保存到手机，可离线播放；卡片原始录音保留。';
    } catch (_) {
      final incomplete = record.copyWith(
          stage: RecorderLongFileStage.incomplete,
          message: '保存未完成，已校验分段保留；重连或重试后可继续。');
      _setRecord(incomplete);
      try {
        await store.saveRecord(incomplete);
      } catch (_) {/* 原始段仍独立保留。 */}
      rethrow;
    }
    _changed();
  }

  bool _sameInventory(
          List<RecorderLongFileEntry> a, List<RecorderLongFileEntry> b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => a[i].signature == b[i].signature)
          .every((v) => v);

  Future<RecorderCommittedSegment> _readSegment(String sn,
      RecorderLongFileEntry entry, int generation, void Function(int) progress,
      {bool live = false}) async {
    final temporary =
        await store.createTemporarySegment(sn, entry.sessionId, entry.part);
    _checkDownload(generation, entry, live);
    final output = await temporary.open(mode: FileMode.write);
    final download = _Download(entry, output, live: live);
    final future = download.finished.future;
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    _download = download;
    _lastProgressBytes = 0;
    _receiveWork = Future.value();
    _progress = progress;
    _armWatchdog();
    try {
      await Future.any<void>([
        send(TelinkLongFileEvent.readCommand(entry)),
        future.then<void>((_) {}),
      ]);
      await future;
      await _receiveWork;
      _checkDownload(generation, entry, live);
      await output.flush();
    } catch (error) {
      if (generation == _generation && !_poisoned) {
        _poison('分段读取未完成；请普通重连后继续，未在旧通道重试。');
      }
      rethrow;
    } finally {
      _watchdog?.cancel();
      await _receiveWork;
      await output.close();
      if (identical(_download, download)) _download = null;
      _progress = null;
    }
    _checkDownload(generation, entry, live);
    try {
      return await store.commitSegment(
          sn, entry.sessionId, entry.part, entry.size, temporary);
    } on FormatException {
      _poison('分段未通过完整性校验；原始字节保留，请普通重连后恢复。');
      rethrow;
    }
  }

  void Function(int)? _progress;
  int _lastProgressBytes = 0;

  void acceptEvent(List<int> bytes) {
    if (_disposed || _poisoned || !isReady()) return;
    try {
      final event = TelinkLongFileEvent.decode(bytes);
      if ((_listing != null &&
              (event is TelinkFileSize || event is TelinkFileComplete)) ||
          (_download != null &&
              (event is TelinkFileListEntry || event is TelinkFileListEnd))) {
        _poison('文件通道出现跨操作事件，已暂停同步；普通重连后可继续。');
        return;
      }
      if (event is TelinkFileListEntry && _listing != null) {
        if (_listEntries.length >= 10000)
          throw const FormatException('catalog_limit');
        final entry = event.entry;
        final old = _listEntries[entry.remoteName];
        if (old != null && old.size != entry.size)
          throw const FormatException('catalog_conflict');
        _listEntries[entry.remoteName] = entry;
        _armWatchdog();
      } else if (event is TelinkFileListEnd && _listing != null) {
        if (!_listing!.isCompleted) {
          _listing!.complete(_listEntries.values.toList());
        }
      } else if (event is TelinkOtherFile && _listing != null) {
        _armWatchdog();
      } else if (event is TelinkFileSize && _download != null) {
        final download = _download!;
        if (event.size != download.entry.size)
          throw const FormatException('download_size_conflict');
        download.metadataSeen = true;
        _armWatchdog();
        _finishDownloadIfComplete(download);
      } else if (event is TelinkFileComplete && _download != null) {
        _download!.completionSeen = true;
        _finishDownloadIfComplete(_download!);
      }
    } on FormatException {
      if (_listing != null || _download != null) {
        _poison('设备文件事件无效或大小冲突，已暂停同步；重连后可继续。');
      }
    }
  }

  void acceptData(List<int> bytes) {
    if (_disposed || _poisoned || !isReady()) return;
    final download = _download;
    if (download == null) {
      if (_operation != null) _poison('收到不属于当前分段的数据，已隔离文件通道；请重连后继续。');
      return;
    }
    if (!_mayRead(download) ||
        bytes.isEmpty ||
        bytes.any((b) => b < 0 || b > 255) ||
        download.received + bytes.length > download.entry.size ||
        download.queuedBytes + bytes.length > 4 * 1024 * 1024) {
      _poison('文件数据超过预期或录音状态变化，已暂停同步；原分段保留。');
      return;
    }
    final packet = Uint8List.fromList(bytes);
    final generation = _generation;
    download.received += packet.length;
    download.queuedBytes += packet.length;
    _receiveWork = _receiveWork.then((_) async {
      try {
        if (generation != _generation || _poisoned) return;
        await download.output.writeFrom(packet);
      } finally {
        download.queuedBytes -= packet.length;
      }
    }).catchError((Object _) {
      if (generation == _generation) _poison('本地分段写入失败，已暂停同步；原录音保留。');
    });
    if (download.received - _lastProgressBytes >= 64 * 1024 ||
        download.received == download.entry.size) {
      _lastProgressBytes = download.received;
      _progress?.call(download.received);
    }
    _armWatchdog();
    _finishDownloadIfComplete(download);
  }

  void _finishDownloadIfComplete(_Download download) {
    if (download.metadataSeen &&
        download.completionSeen &&
        download.received == download.entry.size &&
        !download.finished.isCompleted) {
      download.finished.complete();
    }
  }

  Future<void> dispose() async {
    connectionLost();
    _disposed = true;
    await _operation;
    await _receiveWork;
  }
}

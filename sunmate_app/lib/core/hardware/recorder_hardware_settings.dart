import 'dart:async';

/// 可选硬件能力；手机麦克风等HAL驱动无需实现录音卡固件设置。
abstract interface class RecorderSettingsDevice {
  RecorderHardwareSettings get hardwareSettings;
  Future<bool> refreshHardwareSettings();
  Future<bool> setMeetingRecordingClicks(int count);
  Future<bool> setMeetingRecordingLed(bool enabled);
}

class RecorderHardwareSettings {
  final bool connected;
  final bool capabilitiesKnown;
  final bool supportsClicks;
  final bool supportsLed;
  final bool confirmed;
  final int? meetingClicks;
  final bool? meetingLed;
  final bool? recording;
  final bool busy;
  final String? message;
  final bool failed;
  const RecorderHardwareSettings({
    this.connected = false,
    this.capabilitiesKnown = false,
    this.supportsClicks = false,
    this.supportsLed = false,
    this.confirmed = false,
    this.meetingClicks,
    this.meetingLed,
    this.recording,
    this.busy = false,
    this.message,
    this.failed = false,
  });

  bool get canEdit => connected && confirmed && recording == false && !busy;
}

class _SettingsOperation {
  final int generation;
  final Map<String, Object>? change;
  final done = Completer<bool>();
  final capabilities = Completer<void>();
  Timer? timer;
  bool readingBack = false;
  bool submitted = false;
  _SettingsOperation(this.generation, this.change);
}

/// 仅处理已经通过AES的当前连接；写入成功必须由主动回读匹配确认。
/// 固件未提供请求ID，不能将ATT写完成或setUserSettings回执当保存成功。
class RecorderSettingsController {
  final bool Function() isReady;
  final Future<void> Function(String method, Map<String, Object> params) send;
  final void Function() onChanged;
  final Duration timeout;
  Set<int>? _capabilities;
  int? _clicks;
  bool? _led;
  bool? _recording;
  bool _confirmed = false;
  String? _message;
  bool _failed = false;
  int _generation = 0;
  _SettingsOperation? _pending;

  RecorderSettingsController(
      {required this.isReady,
      required this.send,
      required this.onChanged,
      this.timeout = const Duration(seconds: 5)});

  RecorderHardwareSettings get snapshot => RecorderHardwareSettings(
      connected: isReady(),
      capabilitiesKnown: _capabilities != null,
      supportsClicks: _capabilities?.contains(2001) ?? false,
      supportsLed: _capabilities?.contains(3001) ?? false,
      confirmed: _confirmed,
      meetingClicks: _clicks,
      meetingLed: _led,
      recording: _recording,
      busy: _pending != null,
      message: _message,
      failed: _failed);

  void reset() {
    _generation++;
    final old = _pending;
    _pending = null;
    old?.timer?.cancel();
    if (old != null && !old.done.isCompleted) old.done.complete(false);
    // 释放仍在等待capabilities的异步读取，后续由代次检查阻断。
    if (old != null && !old.capabilities.isCompleted)
      old.capabilities.complete();
    _capabilities = null;
    _clicks = null;
    _led = null;
    _recording = null;
    _confirmed = false;
    _message = null;
    _failed = false;
    onChanged();
  }

  bool _current(_SettingsOperation op) =>
      identical(op, _pending) && op.generation == _generation && isReady();

  Future<bool> refresh() {
    if (_pending != null)
      return _pending!.change == null
          ? _pending!.done.future
          : Future.value(false);
    if (!isReady()) return _reject('请先连接录音卡并完成身份验证。');
    return _start(null);
  }

  Future<bool> setClicks(int count) {
    if (count != 2 && count != 3) return _reject('会议录音触发方式仅支持双击或三击。');
    if (!snapshot.canEdit || !snapshot.supportsClicks) {
      return _reject('请先读取卡片当前设置，并在停止录音后修改。');
    }
    return _start({'mainKeyMultiClick': count});
  }

  Future<bool> setLed(bool enabled) {
    if (!snapshot.canEdit || !snapshot.supportsLed) {
      return _reject('请先读取卡片当前设置，并在停止录音后修改。');
    }
    return _start({'longRecordingLedEnabled': enabled});
  }

  Future<bool> _reject(String message) {
    // 并发点击不能覆盖正在进行的操作及其最终结果。
    if (_pending == null) {
      _message = message;
      _failed = true;
      onChanged();
    }
    return Future.value(false);
  }

  Future<bool> _start(Map<String, Object>? change) {
    final op = _SettingsOperation(_generation, change);
    if (change == null) {
      _confirmed = false;
      _clicks = null;
      _led = null;
      _recording = null;
    }
    _pending = op;
    _message = change == null ? '正在读取卡片设置…' : '正在保存，等待卡片回读确认…';
    _failed = false;
    op.timer = Timer(
        timeout,
        () => _finish(
            op,
            false,
            change == null
                ? '未收到完整设置回报，请重新读取。'
                : '未确认保存结果，请重新读取卡片设置；不会自动重试写入。'));
    onChanged();
    unawaited(_execute(op));
    return op.done.future;
  }

  Future<void> _execute(_SettingsOperation op) async {
    try {
      if (op.change == null) {
        await send('getCapabilities', {});
        if (!_current(op)) return;
        await op.capabilities.future;
        if (!_current(op)) return;
        if (!snapshot.supportsClicks && !snapshot.supportsLed) {
          _finish(op, false, '当前卡片未报告会议录音按键或指示灯设置能力。');
          return;
        }
        await send('getStatus', {});
      } else {
        if (!_current(op) ||
            !snapshot.confirmed ||
            _recording != false ||
            (op.change!.containsKey('mainKeyMultiClick') &&
                !snapshot.supportsClicks) ||
            (op.change!.containsKey('longRecordingLedEnabled') &&
                !snapshot.supportsLed)) {
          _finish(op, false, '当前无法修改，请停止录音并重新读取设置。');
          return;
        }
        op.submitted = true;
        await send('setUserSettings', op.change!);
      }
      if (!_current(op)) return;
      op.readingBack = true;
      await send('getUserSettings', {});
      // 结果由reportUserSettings完成，ATT写完成不报成功。
    } catch (_) {
      _finish(op, false, '设备设置通信未完成，请重新读取卡片设置。');
    }
  }

  void _finish(_SettingsOperation op, bool ok, String message) {
    if (!identical(op, _pending) || op.generation != _generation) return;
    op.timer?.cancel();
    _pending = null;
    if (!op.capabilities.isCompleted) op.capabilities.complete();
    if (!ok) {
      _confirmed = false;
      if (op.submitted) {
        // 卡片可能已经接受写入，不能把旧值冒充回滚后的当前值。
        _clicks = null;
        _led = null;
      }
    }
    _message = message;
    _failed = !ok;
    if (!op.done.isCompleted) op.done.complete(ok);
    onChanged();
  }

  void acceptCapabilities(Map<String, dynamic> params) {
    if (!isReady()) return;
    final values = params['capabilities'];
    if (values is! List || values.length > 256 || values.any((v) => v is! int))
      return;
    final next = values.cast<int>().toSet();
    if (_capabilities != null &&
        (_capabilities!.length != next.length ||
            !_capabilities!.containsAll(next))) {
      _confirmed = false;
      _clicks = null;
      _led = null;
    }
    _capabilities = next;
    if (!snapshot.supportsClicks) _clicks = null;
    if (!snapshot.supportsLed) _led = null;
    final op = _pending;
    if (op != null && !op.capabilities.isCompleted) op.capabilities.complete();
    onChanged();
  }

  void acceptSettings(Map<String, dynamic> params) {
    if (!isReady() || _capabilities == null) return;
    final op = _pending;
    // 只接受本次主动读取之后的设置；不接受写入期间的提前回报或迟到回报。
    if (op == null || !op.readingBack || !_current(op)) return;
    if (params['success'] == false) {
      _finish(op, false, '卡片未确认设置，请重新读取后重试。');
      return;
    }
    final clicks = params['mainKeyMultiClick'];
    final led = params['longRecordingLedEnabled'];
    _clicks =
        snapshot.supportsClicks && clicks is int && (clicks == 2 || clicks == 3)
            ? clicks
            : null;
    _led = snapshot.supportsLed && led is bool ? led : null;
    final complete = (!snapshot.supportsClicks || _clicks != null) &&
        (!snapshot.supportsLed || _led != null);
    final matches = op.change == null ||
        op.change!.entries.every((entry) => entry.key == 'mainKeyMultiClick'
            ? _clicks == entry.value
            : _led == entry.value);
    if (complete && matches) {
      _confirmed = true;
      _finish(op, true, op.change == null ? '已读取卡片当前设置。' : '已保存，卡片回读已确认。');
    } else {
      onChanged(); // 不完整或不匹配时继续等；超时后要求重新读取。
    }
  }

  void acceptRecording(bool recording) {
    if (!isReady()) return;
    _recording = recording;
    final op = _pending;
    if (recording && op?.change != null) {
      _finish(op!, false, '卡片已开始录音，未确认设置结果；停止后请重新读取。');
    } else {
      onChanged();
    }
  }

  void acceptStatus(Map<String, dynamic> params) {
    if (!isReady()) return;
    final nested = params['recording'];
    final general = [
      if (nested is Map) nested['is_recording'],
      params['is_recording'],
      params['isRecording'],
    ].whereType<bool>().toList();
    final long = [
      if (nested is Map) nested['is_long_recording'],
      params['is_long_recording'],
      params['isLongRecording'],
    ].whereType<bool>().toList();
    if (general.any((value) => value) || long.any((value) => value)) {
      acceptRecording(true);
    } else if (general.isNotEmpty) {
      acceptRecording(false);
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class NotificationPolicyStore {
  Future<String?> read();
  Future<void> write(String value);
}

class PreferencesNotificationPolicyStore implements NotificationPolicyStore {
  static const key = 'sunmate_notification_app_policy_v1';
  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String value) async {
    if (!await (await SharedPreferences.getInstance()).setString(key, value)) {
      throw const FormatException('notification_settings_write');
    }
  }
}

class ObservedNotificationApp {
  final String id;
  final String name;
  final int count;
  final int lastSeen;
  final bool enabled;
  const ObservedNotificationApp(
      this.id, this.name, this.count, this.lastSeen, this.enabled);
  ObservedNotificationApp copy({int? count, int? lastSeen, bool? enabled}) =>
      ObservedNotificationApp(id, name, count ?? this.count,
          lastSeen ?? this.lastSeen, enabled ?? this.enabled);
}

/// 只保存应用标识、接收计数和选择，不保存通知标题、正文或UID。
class NotificationAppPolicy extends ChangeNotifier {
  final NotificationPolicyStore _store;
  late final Future<void> ready;
  final Map<String, ObservedNotificationApp> _apps = {};
  bool loaded = false;
  bool enabled = true;
  String? message;
  bool _disposed = false;
  Future<void> _writes = Future<void>.value();
  Timer? _saveTimer;
  NotificationAppPolicy({NotificationPolicyStore? store})
      : _store = store ?? PreferencesNotificationPolicyStore() {
    ready = reload();
  }
  List<ObservedNotificationApp> get apps => List.unmodifiable(
      _apps.values.toList()..sort((a, b) => b.lastSeen.compareTo(a.lastSeen)));
  bool allows(String id) =>
      loaded && enabled && _apps.containsKey(id) && _apps[id]!.enabled;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  static bool validId(String id) =>
      RegExp(r'^[A-Za-z0-9_.-]{1,255}$').hasMatch(id);

  Future<void> reload() {
    final operation = _writes.then((_) async {
      try {
        final raw = await _store.read().timeout(const Duration(seconds: 5));
        final found = <String, ObservedNotificationApp>{};
        var active = true;
        if (raw != null) {
          if (raw.length > 256 * 1024) throw const FormatException();
          final data = jsonDecode(raw);
          if (data is! Map ||
              data['version'] != 1 ||
              data['enabled'] is! bool ||
              data['apps'] is! List ||
              data['apps'].length > 500) throw const FormatException();
          active = data['enabled'];
          for (final row in data['apps']) {
            if (row is! Map ||
                row['id'] is! String ||
                !validId(row['id']) ||
                row['name'] is! String ||
                row['name'].length > 128 ||
                row['count'] is! int ||
                row['count'] < 0 ||
                row['count'] > 0x7fffffff ||
                row['lastSeen'] is! int ||
                row['lastSeen'] < 0 ||
                row['lastSeen'] > 8640000000000000 ||
                row['enabled'] is! bool ||
                found.containsKey(row['id'])) throw const FormatException();
            found[row['id']] = ObservedNotificationApp(row['id'], row['name'],
                row['count'], row['lastSeen'], row['enabled']);
          }
        }
        if (_disposed) return;
        _apps
          ..clear()
          ..addAll(found);
        enabled = active;
        loaded = true;
        message = null;
      } catch (_) {
        loaded = false;
        message = '通知采集设置读取失败，已暂停本地采集；请重试。';
      }
      _changed();
    });
    _writes = operation;
    return operation;
  }

  void observe(String id, String name, DateTime time) {
    if (!loaded || _disposed || !validId(id)) return;
    final old = _apps[id];
    if (old == null && _apps.length >= 500) return;
    _apps[id] = old == null
        ? ObservedNotificationApp(
            id,
            name.substring(0, name.length > 128 ? 128 : name.length),
            1,
            time.millisecondsSinceEpoch.clamp(0, 8640000000000000),
            true)
        : old.copy(
            count: (old.count + 1).clamp(0, 0x7fffffff),
            lastSeen: time.millisecondsSinceEpoch.clamp(0, 8640000000000000));
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(flush());
    });
    _changed();
  }

  String _encode({bool? active, String? app, bool? appEnabled}) => jsonEncode({
        'version': 1,
        'enabled': active ?? enabled,
        'apps': [
          for (final row in _apps.values)
            {
              'id': row.id,
              'name': row.name,
              'count': row.count,
              'lastSeen': row.lastSeen,
              'enabled': row.id == app ? appEnabled : row.enabled
            }
        ]
      });

  Future<bool> _save({bool? active, String? app, bool? appEnabled}) {
    final result = Completer<bool>();
    _writes = _writes.then((_) async {
      await ready;
      if (!loaded || _disposed || (app != null && !_apps.containsKey(app))) {
        result.complete(false);
        return;
      }
      try {
        final text = _encode(active: active, app: app, appEnabled: appEnabled);
        await _store.write(text).timeout(const Duration(seconds: 5));
        if (await _store.read().timeout(const Duration(seconds: 5)) != text)
          throw const FormatException();
        if (active != null) enabled = active;
        if (app != null) _apps[app] = _apps[app]!.copy(enabled: appEnabled);
        message = null;
        result.complete(true);
      } catch (_) {
        message = '通知采集设置未确认保存，请重试。';
        result.complete(false);
      }
      _changed();
    });
    return result.future;
  }

  Future<bool> setEnabled(bool value) => _save(active: value);
  Future<bool> setAppEnabled(String id, bool value) =>
      _save(app: id, appEnabled: value);
  Future<bool> flush() {
    _saveTimer?.cancel();
    return _save();
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    super.dispose();
  }
}

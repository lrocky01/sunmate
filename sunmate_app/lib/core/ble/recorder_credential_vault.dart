import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'ble_protocol.dart';
import 'recorder_authentication.dart';
import 'recorder_saved_identity.dart';

/// UI只接收身份和来源摘要，不持有归档密钥。
class RecorderCredentialSummary {
  final RecorderSavedIdentity identity;
  final String versionId;
  final String source;
  final bool active;
  final bool verified;
  final DateTime createdAt;
  const RecorderCredentialSummary(this.identity, this.versionId, this.source,
      this.active, this.verified, this.createdAt);
}

class RecorderCredentialSelection {
  final String _slot;
  final String _version;
  final int _revision;
  const RecorderCredentialSelection._(
      this._slot, this._version, this._revision);
  @override
  String toString() => 'RecorderCredentialSelection(redacted)';
}

/// 一次连接的隔离候选。写入只允许一次，不访问或替换活动密钥。
class RecorderCandidateKeyStore implements RecorderKeyStore {
  final String deviceId;
  final RecorderProtocol protocol;
  String? _value;
  bool _closed = false;
  RecorderCandidateKeyStore(this.deviceId, this.protocol);
  void _check(String id, RecorderProtocol p) {
    if (_closed ||
        id.toLowerCase() != deviceId.toLowerCase() ||
        p != protocol) {
      throw StateError('候选凭据会话已变化');
    }
  }

  @override
  Future<String?> read(String id, RecorderProtocol p) async {
    _check(id, p);
    return _value;
  }

  @override
  Future<void> write(String id, RecorderProtocol p, String value) async {
    _check(id, p);
    RecorderCryptography.decode32(value).fillRange(0, 32, 0);
    if (_value != null) throw StateError('候选资料已装载，拒绝改写');
    _value = value;
  }

  void close() {
    _closed = true;
    _value = null;
  }
}

/// 旧v1密钥保持原位；新的凭据版本和活动引用放在独立Keychain条目。
/// 单条设备记录保存所有版本。切换前写回滚日志，进程中断后先恢复旧引用。
class RecorderCredentialVault implements RecorderKeyStore {
  static const _prefix = 'sunmate_credential_versions_v1_';
  static const _journalPrefix = 'sunmate_credential_switch_v1_';
  Future<void> _work = Future.value();
  final RecorderKeyStore legacy;
  final FlutterSecureStorage storage;
  RecorderCredentialVault(
      {RecorderKeyStore? legacy, FlutterSecureStorage? storage})
      : legacy = legacy ?? SecureRecorderKeyStore(),
        storage = storage ??
            const FlutterSecureStorage(
                iOptions: IOSOptions(
                    accessibility:
                        KeychainAccessibility.first_unlock_this_device),
                aOptions: AndroidOptions(encryptedSharedPreferences: true));

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _work.then((_) => operation());
    _work = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  String _slot(String id, RecorderProtocol p) {
    if (id.isEmpty || id.length > 128 || RegExp(r'\s').hasMatch(id)) {
      throw StateError('设备身份无效');
    }
    return '$_prefix${p.name}_${Uri.encodeComponent(id.toLowerCase())}';
  }

  String _journal(String slot) =>
      '$_journalPrefix${slot.substring(_prefix.length)}';
  static bool _same(String a, String b) {
    final x = RecorderCryptography.decode32(a),
        y = RecorderCryptography.decode32(b);
    try {
      var difference = 0;
      for (var i = 0; i < 32; i++) {
        difference |= x[i] ^ y[i];
      }
      return difference == 0;
    } finally {
      x.fillRange(0, 32, 0);
      y.fillRange(0, 32, 0);
    }
  }

  Future<void> _put(String key, String value) async {
    await storage.write(key: key, value: value);
    if (await storage.read(key: key) != value) throw StateError('凭据安全保存未完成');
  }

  Future<void> _removeJournal(String slot) async {
    await storage.delete(key: _journal(slot));
    if (await storage.read(key: _journal(slot)) != null)
      throw StateError('凭据切换确认未完成');
  }

  Map<String, dynamic> _decode(String value, String slot) {
    try {
      if (value.length > 32768) throw const FormatException();
      final m = Map<String, dynamic>.from(jsonDecode(value) as Map);
      final identity = RecorderSavedIdentity.fromJson(m['identity']);
      if (m['version'] != 1 ||
          _slot(identity.remoteId, identity.protocol) != slot ||
          m['revision'] is! int ||
          m['revision'] < 0 ||
          m['revision'] > 2147483646 ||
          m['entries'] is! List) {
        throw const FormatException();
      }
      final entries = m['entries'] as List;
      if (entries.isEmpty || entries.length > 32) throw const FormatException();
      final ids = <String>{};
      for (final entry in entries) {
        if (entry is! Map ||
            entry['id'] is! String ||
            !RegExp(r'^[a-f0-9]{32}$').hasMatch(entry['id']) ||
            !ids.add(entry['id']) ||
            !['旧本机凭据', '官方账号资料', '历史凭据'].contains(entry['source']) ||
            entry['verified'] is! bool ||
            entry['created'] is! String ||
            DateTime.tryParse(entry['created']) == null ||
            entry['secret'] is! String) {
          throw const FormatException();
        }
        RecorderCryptography.decode32(entry['secret']).fillRange(0, 32, 0);
      }
      if (m['active'] != null && !ids.contains(m['active']))
        throw const FormatException();
      return m;
    } catch (_) {
      throw StateError('凭据版本资料无效；未替换现有密钥');
    }
  }

  Future<void> _recover(String slot) async {
    final before = await storage.read(key: _journal(slot));
    if (before == null) return;
    _decode(before, slot);
    await _put(slot, before);
    await _removeJournal(slot);
  }

  Future<Map<String, dynamic>?> _readSlot(String slot) async {
    await _recover(slot);
    final raw = await storage.read(key: slot);
    return raw == null ? null : _decode(raw, slot);
  }

  String? _active(Map<String, dynamic> m) {
    if (m['active'] == null) return null;
    return (m['entries'] as List)
        .singleWhere((e) => e['id'] == m['active'])['secret'] as String;
  }

  @override
  Future<String?> read(String id, RecorderProtocol p) => _serial(() async {
        final m = await _readSlot(_slot(id, p));
        return m == null ? await legacy.read(id, p) : _active(m);
      });
  @override
  Future<void> write(String id, RecorderProtocol p, String value) =>
      _serial(() async {
        RecorderCryptography.decode32(value).fillRange(0, 32, 0);
        final m = await _readSlot(_slot(id, p));
        final previous = m == null ? await legacy.read(id, p) : _active(m);
        if (previous != null) {
          if (!_same(previous, value))
            throw StateError('已有不同活动密钥，请使用显式候选验证；未覆盖');
          return;
        }
        // 有候选版本但无活动引用时，不允许首次协商绕开候选确认。
        if (m != null) throw StateError('已有待验证凭据，请使用候选验证；未重新协商');
        await legacy.write(id, p, value);
      });
  Map<String, Object> _entry(String value, String source, bool verified) => {
        'id': List.generate(
            16,
            (_) => Random.secure()
                .nextInt(256)
                .toRadixString(16)
                .padLeft(2, '0')).join(),
        'source': source,
        'verified': verified,
        'created': DateTime.now().toUtc().toIso8601String(),
        'secret': value,
      };
  Future<RecorderCredentialSelection> prepare(
          RecorderSavedIdentity identity, String value,
          {required String source}) =>
      _serial(() async {
        if (!['官方账号资料', '历史凭据'].contains(source) ||
            identity.protocol != RecorderProtocol.telink) {
          throw StateError('候选来源或协议无效');
        }
        RecorderCryptography.decode32(value).fillRange(0, 32, 0);
        final slot = _slot(identity.remoteId, identity.protocol);
        var m = await _readSlot(slot);
        if (m == null) {
          final old = await legacy.read(identity.remoteId, identity.protocol);
          final entries = <Map<String, Object>>[];
          if (old != null) entries.add(_entry(old, '旧本机凭据', false));
          m = {
            'version': 1,
            'identity': identity.toJson(),
            'revision': 0,
            'active': entries.isEmpty ? null : entries.first['id'],
            'entries': entries
          };
        } else if (!RecorderSavedIdentity.fromJson(m['identity'])
            .sameDevice(identity)) {
          throw StateError('归档SN或协议不匹配；未切换');
        }
        final entries = m['entries'] as List;
        final same =
            entries.where((e) => _same(e['secret'] as String, value)).toList();
        Map entry;
        if (same.isNotEmpty) {
          entry = same.single as Map;
        } else {
          if (entries.length >= 32) throw StateError('本机凭据归档已满；未删除旧资料');
          entry = _entry(value, source, false);
          entries.add(entry);
        }
        m['revision'] = (m['revision'] as int) + 1;
        final encoded = jsonEncode(m);
        _decode(encoded, slot);
        await _put(slot, encoded);
        return RecorderCredentialSelection._(
            slot, entry['id'] as String, m['revision'] as int);
      });

  /// 调用者必须先完成当前连接AES；此回调同时防止取消、断连或账号过期后提交。
  Future<void> activateVerified(RecorderCredentialSelection selected,
          {required void Function() ensureCurrent}) =>
      _serial(() async {
        ensureCurrent();
        final m = await _readSlot(selected._slot);
        if (m == null || m['revision'] != selected._revision)
          throw StateError('候选版本已变化；未切换');
        final before = jsonEncode(m);
        final entry = (m['entries'] as List)
            .singleWhere((e) => e['id'] == selected._version);
        entry['verified'] = true;
        m['active'] = selected._version;
        m['revision'] = (m['revision'] as int) + 1;
        ensureCurrent();
        await _put(_journal(selected._slot), before);
        try {
          ensureCurrent();
          await _put(selected._slot, jsonEncode(m));
          ensureCurrent();
          await _removeJournal(selected._slot);
          ensureCurrent();
        } catch (_) {
          try {
            await _put(selected._slot, before);
            await _removeJournal(selected._slot);
          } catch (_) {
            // 尽力保留回滚日志；后续read在恢复成功前拒绝交付活动密钥。
            try {
              await _put(_journal(selected._slot), before);
            } catch (_) {}
          }
          throw StateError('候选切换未完成；请重新读取本机资料，旧凭据保留');
        }
      });

  Future<List<RecorderCredentialSummary>> history() => _serial(() async {
        final keys = (await storage.readAll())
            .keys
            .where((k) => k.startsWith(_prefix))
            .toList();
        if (keys.length > 32) throw StateError('设备凭据记录过多');
        final result = <RecorderCredentialSummary>[];
        for (final key in keys) {
          final m = await _readSlot(key);
          if (m == null) continue;
          final identity = RecorderSavedIdentity.fromJson(m['identity']);
          for (final entry in m['entries'] as List) {
            result.add(RecorderCredentialSummary(
                identity,
                entry['id'] as String,
                entry['source'] as String,
                m['active'] == entry['id'],
                entry['verified'] as bool,
                DateTime.parse(entry['created'] as String)));
          }
        }
        return List.unmodifiable(result);
      });

  Future<void> loadArchived(RecorderCredentialSummary selected,
          RecorderCandidateKeyStore destination) =>
      _serial(() async {
        final identity = selected.identity;
        if (destination.protocol != identity.protocol)
          throw StateError('历史凭据协议不匹配');
        final m = await _readSlot(_slot(identity.remoteId, identity.protocol));
        if (m == null ||
            !RecorderSavedIdentity.fromJson(m['identity'])
                .sameDevice(identity)) {
          throw StateError('历史凭据身份已变化');
        }
        final entries = (m['entries'] as List)
            .where((e) => e['id'] == selected.versionId)
            .toList();
        if (entries.length != 1) throw StateError('历史凭据不存在');
        await destination.write(destination.deviceId, destination.protocol,
            entries.single['secret'] as String);
      });
}

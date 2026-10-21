import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../config/server_config_store.dart';
import '../recordings/local_content_store.dart';
import 'archive_models.dart';
import 'archive_transport.dart';

class SecureArchiveConfigStore implements ServerConfigStore {
  final FlutterSecureStorage storage = const FlutterSecureStorage(
      iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device),
      aOptions: AndroidOptions(encryptedSharedPreferences: true));
  static const key = 'sunmate_archive_config_v1';
  @override
  Future<String?> read() => storage.read(key: key);
  @override
  Future<void> write(String value) => storage.write(key: key, value: value);
}

class ArchiveSyncConfig {
  final String url, token;
  final Map<String, dynamic> identity;
  final Set<String> automatic;
  const ArchiveSyncConfig(
      {this.url = '',
      this.token = '',
      this.identity = const {},
      this.automatic = const {}});
  bool get paired => identity.length == 4 && url.isNotEmpty && token.isNotEmpty;
  Map<String, dynamic> toJson() => {
        'version': 1,
        'url': url,
        'token': token,
        'identity': identity,
        'automatic': automatic.toList()..sort()
      };
  factory ArchiveSyncConfig.fromJson(Map<String, dynamic> value) {
    if (value['version'] != 1 ||
        value['url'] is! String ||
        value['token'] is! String ||
        value['identity'] is! Map ||
        value['automatic'] is! List ||
        (value['automatic'] as List).any((v) => !categories.contains(v)))
      throw const FormatException();
    final config = ArchiveSyncConfig(
        url: value['url'],
        token: value['token'],
        identity: Map<String, dynamic>.from(value['identity']),
        automatic: Set<String>.from(value['automatic']));
    if (config.url.isNotEmpty) validateEndpoint(config.url, config.token);
    if (config.identity.isNotEmpty &&
        (config.identity.length != 4 ||
            ['serverId', 'libraryId', 'clientId', 'profile'].any((k) =>
                config.identity[k] is! String ||
                (config.identity[k] as String).isEmpty)))
      throw const FormatException();
    return config;
  }
  static const categories = {'meeting', 'lifelog', 'notification', 'summary'};
  static void validateEndpoint(String url, String token) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.path.replaceAll(RegExp(r'/+$'), '').endsWith('/sunmate/v1') ||
        url.length > 4096 ||
        token.isEmpty ||
        token.length > 16384 ||
        token.contains(RegExp(r'[\r\n]'))) {
      throw const ArchiveSyncException('请填写私有归档 /sunmate/v1 地址及独立同步凭据。',
          pause: true);
    }
  }
}

/// Source commit and queue commit are separate. Reconciliation repairs a crash between them.
class ArchiveSyncController extends ChangeNotifier
    implements ArchiveReferenceResolver {
  final RecordingContentStore store;
  final ServerConfigStore secure;
  final Future<List<ArchiveSource>> Function() sources;
  final ArchiveTransport Function(String, String) transport;
  final DateTime Function() clock;
  final Object Function()? sourceGeneration;
  Object? _snapshotGeneration;
  late final Future<void> ready;
  ArchiveSyncConfig config = const ArchiveSyncConfig();
  final Map<String, Map<String, dynamic>> _outbox = {};
  final Map<String, String> _seen = {};
  final Map<String, int> _revisions = {};
  final Map<String, String> _savedSeen = {};
  final Map<String, int> _savedRevisions = {};
  Future<void>? _refreshPending;
  Future<void> _serial = Future<void>.value();
  bool loaded = false,
      busy = false,
      foreground = true,
      paused = false,
      _disposed = false;
  String? message;
  DateTime? lastSuccess, retryAt;
  int _failures = 0;
  List<ArchiveSource> current = [];
  ArchiveSyncController(
      {required this.store,
      required this.sources,
      this.sourceGeneration,
      ServerConfigStore? secure,
      ArchiveTransport Function(String, String)? transport,
      DateTime Function()? clock})
      : secure = secure ?? SecureArchiveConfigStore(),
        transport =
            transport ?? ((url, token) => HttpArchiveTransport(url, token)),
        clock = clock ?? DateTime.now {
    ready = _load();
  }
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  int get received => current.where((v) => v.kind == 'notification').length;
  int get pending => entries.where((v) => v['status'] == 'pending').length;
  int get confirmed => entries.where((v) => v['status'] == 'confirmed').length;
  List<Map<String, dynamic>> get entries =>
      _outbox.values.where((v) => v['target'] == _target).toList();
  String get _target =>
      jsonEncode(canonicalValue([config.url, config.identity]));
  @override
  bool get referenceEnabled => loaded && config.paired;
  @override
  bool get automaticMeetingSync => config.automatic.contains('meeting');

  /// Automatic summaries may read existing archives without opting the user into uploads.
  @override
  Future<ArchiveReferences?> existingReferences(Set<String> sourceIds) =>
      _lock(() async {
        await ready;
        if (!referenceEnabled) return null;
        if (!foreground || paused)
          throw const ArchiveSyncException('归档引用暂不可用，请恢复前台并核对同步状态。');
        await _observe();
        final selected =
            current.where((v) => v.aliases.any(sourceIds.contains)).toList();
        if (!selected.expand((v) => v.aliases).toSet().containsAll(sourceIds) ||
            selected.any((v) => !v.visible)) return null;
        final refs = <Map<String, dynamic>>[];
        for (final source in selected) {
          final sha = await source.sha;
          final rows = entries
              .where((v) =>
                  v['record']['id'] == source.id && v['record']['sha'] == sha)
              .toList();
          if (rows.isEmpty) return null;
          rows.sort((a, b) => (b['record']['revision'] as int)
              .compareTo(a['record']['revision']));
          final record = rows.first['record'] as Map;
          final ref = {
            for (final key in ['id', 'revision', 'sha']) key: record[key]
          };
          final receipts = await transport(config.url, config.token)
              .exchange('receipts', config.identity, [ref]);
          if (receipts.length != 1 ||
              ref.keys.any((k) => receipts.single[k] != ref[k]))
            throw const ArchiveSyncException('归档回执不匹配，未继续自动纪要。', pause: true);
          if (receipts.single['status'] == 'missing') return null;
          if (!['accepted', 'already_present']
              .contains(receipts.single['status']))
            throw const ArchiveSyncException('归档版本不一致，未继续自动纪要。', pause: true);
          refs.add({'id': source.id, 'sha': sha});
        }
        return ArchiveReferences(
            config.identity['serverId'],
            config.identity['libraryId'],
            config.identity['profile'],
            config.identity['clientId'],
            refs);
      });

  Future<T> _lock<T>(Future<T> Function() work) {
    final task = _serial.then((_) => work());
    _serial = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  Future<void> _load() async {
    try {
      final raw = await secure.read();
      if (raw != null) config = ArchiveSyncConfig.fromJson(jsonDecode(raw));
      for (final row in await store.readAll('archive_outbox')) {
        if (row['record'] is! Map ||
            row['target'] is! String ||
            row['status'] is! String) throw const FormatException();
        final record = row['record'] as Map;
        if (!['pending', 'confirmed', 'conflict', 'invalid', 'superseded']
                .contains(row['status']) ||
            record['id'] is! String ||
            record['revision'] is! int ||
            record['revision'] < 1 ||
            record['visible'] is! bool ||
            record['payload'] is! Map ||
            record['sha'] !=
                await contentFingerprint(canonicalValue({
                  for (final key in [
                    'id',
                    'kind',
                    'timestamp',
                    'payload',
                    'visible'
                  ])
                    key: record[key]
                })!)) throw const FormatException();
        _outbox[row['id']] = row;
      }
      for (final row in await store.readAll('archive_state')) {
        if (row['id'] == 'sources') {
          _seen.addAll(Map<String, String>.from(row['seen']));
          _revisions.addAll(Map<String, int>.from(row['revisions']));
        } else if ((row['id'] as String).startsWith('source:')) {
          if (row['sourceId'] is! String ||
              row['seen'] is! String ||
              row['revision'] is! int) throw const FormatException();
          _seen[row['sourceId']] = row['seen'];
          _revisions[row['sourceId']] = row['revision'];
          _savedSeen[row['sourceId']] = row['seen'];
          _savedRevisions[row['sourceId']] = row['revision'];
        } else if (row['id'] == 'status') {
          lastSuccess = row['lastSuccess'] == null
              ? null
              : DateTime.parse(row['lastSuccess']);
        }
      }
      loaded = true;
    } catch (_) {
      message = '同步设置或队列读取失败，已暂停；本机原资料保留。';
      paused = true;
    }
    _changed();
  }

  Future<void> _saveConfig(ArchiveSyncConfig next) async {
    final raw = jsonEncode(next.toJson());
    await secure.write(raw);
    if (await secure.read() != raw)
      throw const ArchiveSyncException('同步设置尚未安全保存。', pause: true);
    config = next;
  }

  Future<Map<String, dynamic>> probe(String url, String token) async {
    ArchiveSyncConfig.validateEndpoint(url, token);
    final result = await transport(url, token).capabilities();
    if (result['schema'] != archiveSchema || result['rawAudio'] != false)
      throw const ArchiveSyncException('归档服务版本不兼容。', pause: true);
    return {
      for (final k in ['serverId', 'libraryId', 'clientId', 'profile'])
        k: result[k]
    };
  }

  Future<void> pair(String url, String token, Map<String, dynamic> expected) =>
      _lock(() async {
        await ready;
        if (!loaded) throw const ArchiveSyncException('请先恢复同步设置。', pause: true);
        final identity = await probe(url, token);
        if (jsonEncode(canonicalValue(identity)) !=
            jsonEncode(canonicalValue(expected)))
          throw const ArchiveSyncException('确认期间服务器身份发生变化，请重试。', pause: true);
        await _saveConfig(
            ArchiveSyncConfig(url: url, token: token, identity: identity));
        // Switching endpoints never implicitly sends the old queue to the new server.
        paused = false;
        retryAt = null;
        message = null;
        await _observe(baseline: true);
        _changed();
      });
  Future<void> setAutomatic(Set<String> categories) => _lock(() async {
        await ready;
        if (!loaded ||
            !config.paired ||
            !ArchiveSyncConfig.categories.containsAll(categories))
          throw const ArchiveSyncException('请先确认归档服务连接。');
        // Persist current fingerprints before enabling. Existing history needs explicit backfill.
        await _observe();
        await _saveConfig(ArchiveSyncConfig(
            url: config.url,
            token: config.token,
            identity: config.identity,
            automatic: categories));
        _changed();
      });
  Future<void> _saveSourceState() async {
    for (final entry in _seen.entries) {
      final revision = _revisions[entry.key] ?? 0;
      if (_savedSeen[entry.key] == entry.value &&
          _savedRevisions[entry.key] == revision) continue;
      await store.put('archive_state', 'source:${entry.key}',
          {'sourceId': entry.key, 'seen': entry.value, 'revision': revision});
      _savedSeen[entry.key] = entry.value;
      _savedRevisions[entry.key] = revision;
    }
  }

  Future<void> _put(Map<String, dynamic> row) async {
    await store.put('archive_outbox', row['id'], row);
    _outbox[row['id']] = row;
  }

  Future<Map<String, dynamic>> _enqueue(ArchiveSource source,
      {bool manual = false}) async {
    final sha = await source.sha;
    // Derive revision from durable queue as well: repair a crash before state save.
    var rev = _revisions[source.id] ?? 0;
    for (final row in _outbox.values.where(
        (v) => v['target'] == _target && v['record']['id'] == source.id)) {
      if (row['record']['revision'] > rev) rev = row['record']['revision'];
    }
    final latest = _outbox.values
        .where((v) =>
            v['target'] == _target &&
            v['record']['id'] == source.id &&
            v['record']['revision'] == rev)
        .toList();
    if (latest.isNotEmpty && latest.single['record']['sha'] == sha) {
      if (manual && latest.single['manual'] != true) {
        final promoted = {...latest.single, 'manual': true};
        await _put(promoted);
        return promoted;
      }
      return latest.single;
    }
    final key = await contentFingerprint([_target, source.id, sha, rev + 1]);
    final row = <String, dynamic>{
      'id': key,
      'target': _target,
      'category': source.category,
      'manual': manual,
      'status': 'pending',
      'record': {...source.body, 'sha': sha, 'revision': rev + 1}
    };
    await _put(row);
    _revisions[source.id] = rev + 1;
    return row;
  }

  /// A server-created version already starts at revision 1. Seed that receipt
  /// before the phone can publish a visibility change as revision 2.
  Future<void> adoptServerRecord(Map<String, dynamic> body, String target) => _lock(() async {
    await ready;
    if (!loaded || !config.paired || _target != target ||
        !['transcript', 'summary'].contains(body['kind']) || body['visible'] != true ||
        body['id'] is! String || body['payload'] is! Map<String, dynamic>) throw const ArchiveSyncException('服务器资料来源或目标不匹配。');
    final kind = body['kind'] as String;
    final source = ArchiveSource(body['id'], kind,
        kind == 'summary' ? 'summary' : body['payload']['purpose'],
        DateTime.parse(body['timestamp']), Map<String, dynamic>.from(body['payload']));
    if (!['meeting', 'lifelog', 'summary'].contains(source.category) ||
        jsonEncode(canonicalValue(source.body)) != jsonEncode(canonicalValue(body))) throw const ArchiveSyncException('服务器资料格式不匹配。');
    final known = _outbox.values.where((r) => r['target'] == _target && r['record']['id'] == source.id).toList();
    final sha = await source.sha;
    final base = known.where((r) => r['record']['revision'] == 1 && r['record']['sha'] == sha).toList();
    if (known.isNotEmpty && base.length != 1) throw const ArchiveSyncException('服务器起始版本冲突，已有版本保留。');
    final row = base.isEmpty ? await _enqueue(source) : base.single;
    if (row['status'] == 'confirmed') return;
    final record = row['record'] as Map;
    final ref = {for (final k in ['id', 'revision', 'sha']) k: record[k]};
    final receipt = await transport(config.url, config.token).exchange('receipts', config.identity, [ref]);
    if (receipt.length != 1 || ref.keys.any((k) => receipt.single[k] != ref[k]) ||
        !['accepted', 'already_present'].contains(receipt.single['status'])) throw const ArchiveSyncException('服务器结果回执尚未确认。');
    await _put({...row, 'status': 'confirmed'});
    _seen.putIfAbsent(source.id, () => record['sha']);
    await _saveSourceState();
  });

  Future<void> _observe({bool baseline = false}) async {
    final before = sourceGeneration?.call();
    current = await sources();
    if (sourceGeneration != null && before != sourceGeneration!()) {
      throw const ArchiveSyncException('本机资料正在更新，下一轮继续核对。');
    }
    _snapshotGeneration = before;
    for (final source in current) {
      final sha = await source.sha;
      final old = entries.where((v) => v['record']['id'] == source.id).toList();
      for (final row in old.where(
          (v) => v['status'] == 'pending' && v['record']['sha'] != sha)) {
        await _put({...row, 'status': 'superseded'});
      }
      final revoke =
          !source.visible && old.any((v) => v['record']['visible'] == true);
      final changed = _seen[source.id] != sha;
      if (config.paired &&
          (revoke ||
              !baseline &&
                  changed &&
                  source.visible &&
                  config.automatic.contains(source.category))) {
        await _enqueue(source);
      }
      _seen[source.id] = sha;
    }
    await _saveSourceState();
  }

  Future<void> refresh({bool retry = false}) {
    if (_refreshPending != null) return _refreshPending!;
    final task = _refresh(retry: retry);
    _refreshPending = task;
    task.whenComplete(() => _refreshPending = null);
    return task;
  }

  Future<void> _refresh({bool retry = false}) => _lock(() async {
        await ready;
        if (!loaded || _disposed) return;
        busy = true;
        _changed();
        try {
          await _observe();
          if (retry) {
            paused = false;
            retryAt = null;
          }
          if (config.paired &&
              foreground &&
              !paused &&
              (retryAt == null || !clock().isBefore(retryAt!))) {
            for (final row
                in entries.where((v) => v['status'] == 'pending').toList()) {
              final record = row['record'] as Map<String, dynamic>;
              if (record['visible'] == true &&
                  !config.automatic.contains(row['category']) &&
                  row['manual'] != true) continue;
              // Never transmit a queued body after its source permission/version changed.
              final matches = current.where((v) => v.id == record['id']);
              if (matches.isEmpty || await matches.single.sha != record['sha'])
                continue;
              try {
                await _deliver(row);
              } on ArchiveSyncException catch (error) {
                if (!error.isolated) rethrow;
              }
            }
          }
          final rejected = entries.any((v) =>
              ['invalid', 'conflict'].contains(v['status']) &&
              !entries.any((other) =>
                  other['record']['id'] == v['record']['id'] &&
                  other['record']['revision'] > v['record']['revision']));
          message = paused
              ? message
              : rejected
                  ? '有资料版本被拒绝，其他资料继续同步；请查看最近回执。'
                  : null;
        } catch (error) {
          _failed(error);
        } finally {
          busy = false;
          _changed();
        }
      });
  void _failed(Object error) {
    paused = error is FileSystemException ||
        error is ArchiveSyncException && error.pause;
    message = error is ArchiveSyncException
        ? error.message
        : '同步状态未安全保存或服务暂不可用，原资料保留。';
    _failures = (_failures + 1).clamp(1, 8);
    retryAt = clock().add(Duration(seconds: 5 * (1 << _failures)));
  }

  Future<void> _deliver(Map<String, dynamic> row) async {
    if (!foreground || _disposed)
      throw const ArchiveSyncException('App恢复前台后继续同步。');
    final record = Map<String, dynamic>.from(row['record']);
    final ref = {
      for (final k in ['id', 'sha', 'revision']) k: record[k]
    };
    final client = transport(config.url, config.token);
    var receipts = await client.exchange('receipts', config.identity, [ref]);
    void validate(List<Map<String, dynamic>> values) {
      if (values.length != 1 || ref.keys.any((k) => values.single[k] != ref[k]))
        throw const ArchiveSyncException('归档回执与资料不匹配，已暂停。', pause: true);
    }

    validate(receipts);
    Future<void> checkSource() async {
      if (sourceGeneration == null ||
          sourceGeneration!() != _snapshotGeneration) {
        final before = sourceGeneration?.call();
        current = await sources();
        if (sourceGeneration != null && before != sourceGeneration!()) {
          throw const ArchiveSyncException('本机资料正在更新，下一轮继续核对。');
        }
        _snapshotGeneration = before;
      }
      final fresh = current.where((v) => v.id == record['id']).toList();
      if (!foreground ||
          _disposed ||
          fresh.length != 1 ||
          await fresh.single.sha != record['sha']) {
        throw const ArchiveSyncException('资料或采集许可已变化，暂停本条同步并等待重新核对。');
      }
    }

    await checkSource();
    if (receipts.single['status'] == 'missing') {
      receipts = await client.exchange('ingest', config.identity, [record]);
      validate(receipts);
    }
    final status = receipts.single['status'];
    if (!['accepted', 'already_present'].contains(status)) {
      await _put(
          {...row, 'status': status == 'conflict' ? 'conflict' : 'invalid'});
      throw const ArchiveSyncException('部分资料被服务器拒绝，请查看逐条回执；未覆盖服务器资料。',
          isolated: true);
    }
    await _put({...row, 'status': 'confirmed'});
    await checkSource();
    lastSuccess = clock();
    _failures = 0;
    retryAt = null;
    await store.put('archive_state', 'status',
        {'lastSuccess': lastSuccess!.toUtc().toIso8601String()});
  }

  List<ArchiveSource> history(DateTime from, DateTime to) => current
      .where((v) => v.visible && !v.time.isBefore(from) && v.time.isBefore(to))
      .toList();
  Future<void> backfill(DateTime from, DateTime to, Set<String> categories) =>
      _lock(() async {
        await ready;
        if (!loaded ||
            !config.paired ||
            !to.isAfter(from) ||
            to.difference(from) > const Duration(days: 31))
          throw const ArchiveSyncException('请选择31天以内的补传范围并确认连接。');
        await _observe();
        for (final source in history(from, to)
            .where((v) => categories.contains(v.category))) {
          await _enqueue(source, manual: true);
        }
        await _saveSourceState();
        _changed();
      });
  @override
  Future<ArchiveReferences> ensureReferences(Set<String> sourceIds) =>
      _lock(() async {
        await ready;
        if (!referenceEnabled || !foreground || paused)
          throw const ArchiveSyncException('归档引用暂不可用，请恢复前台并检查同步连接。');
        await _observe();
        final selected =
            current.where((v) => v.aliases.any(sourceIds.contains)).toList();
        final matched = selected.expand((v) => v.aliases).toSet();
        if (sourceIds.isEmpty ||
            !matched.containsAll(sourceIds) ||
            selected.any((v) => !v.visible))
          throw const ArchiveSyncException('所选来源缺失或已停用，未发送引用处理。');
        final refs = <Map<String, dynamic>>[];
        try {
          for (final source in selected) {
            final row = await _enqueue(source, manual: true);
            // Check server even for a local confirmed receipt (e.g. restored server backup).
            await _deliver(row);
            refs.add({'id': source.id, 'sha': await source.sha});
          }
          await _saveSourceState();
          _changed();
          return ArchiveReferences(
              config.identity['serverId'],
              config.identity['libraryId'],
              config.identity['profile'],
              config.identity['clientId'],
              refs);
        } catch (error) {
          _failed(error);
          _changed();
          rethrow;
        }
      });
  void setForeground(bool active) {
    foreground = active;
    if (active) unawaited(refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

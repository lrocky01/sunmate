import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../ble/ios_ble_connection.dart';
import '../hardware/ainote_6095_driver.dart';
import '../hardware/recorder_long_recordings.dart';
import '../hardware/recorder_long_file_models.dart';
import '../sync/archive_sync.dart';
import '../sync/archive_models.dart';
import 'local_content_store.dart';
import 'recording_processing_models.dart';
import 'recording_processing_controller.dart';

const backgroundFlags = [
  'receive',
  'meetingUpload',
  'lifelogUpload',
  'meetingAsr',
  'lifelogAsr',
  'meetingSummary',
  'lifelogSummary',
  'cellular'
];

class RecordingBackgroundPolicy {
  final Map<String, bool> flags;
  final int revision;
  RecordingBackgroundPolicy(
      {Map<String, bool> flags = const {}, this.revision = 1})
      : flags = {for (final key in backgroundFlags) key: flags[key] ?? false};
  bool operator [](String key) => flags[key] == true;
  bool get any => flags.values.any((v) => v);
  RecordingBackgroundPolicy changed(String key, bool value) {
    if (!backgroundFlags.contains(key)) throw const FormatException('后台策略无效');
    final next = {...flags, key: value};
    for (final kind in ['meeting', 'lifelog']) {
      if (key == '${kind}Summary' && value) next['${kind}Asr'] = true;
      if (key == '${kind}Upload' && !value) {
        next['${kind}Asr'] = false;
        next['${kind}Summary'] = false;
      }
      if (key == '${kind}Asr' && !value) next['${kind}Summary'] = false;
      if (next['${kind}Asr'] == true) next['${kind}Upload'] = true;
    }
    return RecordingBackgroundPolicy(flags: next, revision: revision + 1);
  }

  Map<String, dynamic> toJson() => {'revision': revision, 'policy': flags};
  factory RecordingBackgroundPolicy.fromJson(Map<String, dynamic> v) {
    final f = Map<String, bool>.from(v['policy']);
    if (f.length != backgroundFlags.length ||
        f.keys.any((k) => !backgroundFlags.contains(k)) ||
        v['revision'] is! int ||
        v['revision'] < 1) throw const FormatException('后台设置损坏，保持关闭');
    for (final kind in ['meeting', 'lifelog']) {
      if (f['${kind}Summary']! && !f['${kind}Asr']! ||
          f['${kind}Asr']! && !f['${kind}Upload']!)
        throw const FormatException('后台设置依赖无效');
    }
    return RecordingBackgroundPolicy(flags: f, revision: v['revision']);
  }
}

/// A session's owner is captured before the legacy ASR queue sees its first part.
/// Switching policy later cannot steal a running phone job or silently backfill.
class RecordingWorkOwnership {
  final RecordingContentStore store;
  final Map<String, Map<String, dynamic>> sessions = {};
  late final Future<void> ready;
  RecordingBackgroundPolicy policy = RecordingBackgroundPolicy();
  bool loaded = false;
  String target = '', policyTarget = '';
  RecordingWorkOwnership(this.store) {
    ready = _load();
  }
  Future<void> _load() async {
    final rows = await store.readAll('background_policy');
    if (rows.isNotEmpty) {
      policy = RecordingBackgroundPolicy.fromJson(rows.single);
      policyTarget = rows.single['target'] as String? ?? '';
    }
    for (final v in await store.readAll('background_owners')) {
      sessions[v['id']] = v;
    }
    loaded = true;
  }

  Future<void> capture(RecordingSegmentSignal signal,
      {Map<String, dynamic>? snapshot, String? targetOverride}) async {
    await ready;
    if (signal.kind != SegmentSignalKind.started) return;
    final id = sessionKey(signal.sn, signal.session);
    if (sessions.containsKey(id)) return;
    final p = snapshot == null
        ? policy
        : RecordingBackgroundPolicy.fromJson(snapshot);
    final kind = signal.purpose?.name;
    final capturedTarget = targetOverride ?? target;
    final value = {
      'owner': capturedTarget.isNotEmpty && kind != null && p['${kind}Upload']
          ? 'server'
          : 'phone',
      'target': capturedTarget,
      'policy': p.toJson(),
      'purpose': kind,
      'started': signal.observed.toUtc().toIso8601String()
    };
    await store.put('background_owners', id, value);
    sessions[id] = value;
  }

  bool server(String session) => sessions[session]?['owner'] == 'server';
  bool serverAsr(String session) {
    final row = sessions[session];
    return server(session) &&
        (row?['policy']?['policy']?['${row['purpose']}Asr'] == true);
  }

  bool current(String session) =>
      server(session) && sessions[session]?['target'] == target;
}

typedef BackgroundNativeCall = Future<dynamic> Function(
    String method, Map<String, dynamic>? args);
typedef BackgroundExchange = Future<Map<String, dynamic>> Function(
    ArchiveSyncConfig config, String action, Map<String, dynamic> value);

Future<Map<String, dynamic>> backgroundExchange(
    ArchiveSyncConfig config, String action, Map<String, dynamic> value) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request =
        await client.postUrl(Uri.parse('${config.url}/audio/$action'));
    request.followRedirects = false;
    request.headers.set('Authorization', 'Bearer ${config.token}');
    request.headers.contentType = ContentType.json;
    for (final key in ['serverId', 'libraryId'])
      request.headers.set('X-Sunmate-$key', config.identity[key]);
    request
        .add(utf8.encode(jsonEncode({'schema': 'sunmate.audio.v1', ...value})));
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200)
      throw const RecordingProcessingException('服务器后台接口未就绪或权限已变化；已有录音保留。');
    var size = 0;
    final builder = BytesBuilder();
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      size += chunk.length;
      if (size > 2 * 1024 * 1024) throw const FormatException('结果过大');
      builder.add(chunk);
    }
    final result = jsonDecode(utf8.decode(builder.takeBytes()));
    if (result is! Map<String, dynamic> ||
        result['schema'] != 'sunmate.audio.v1')
      throw const FormatException('后台协议不匹配');
    return result;
  } finally {
    client.close(force: true);
  }
}

class RecordingBackgroundController extends ChangeNotifier {
  final RecordingContentStore store;
  final RecordingWorkOwnership ownership;
  final ArchiveSyncController archive;
  final RecordingProcessingController processing;
  final AiNote6095Driver driver;
  final BackgroundNativeCall native;
  final BackgroundExchange exchange;
  final bool supported;
  late final Future<void> ready;
  bool loaded = false, busy = false, foreground = true, disposed = false;
  Future<void> _lifecycle = Future.value();
  int cursor = 0;
  String? message;
  bool processorEnabled = false;
  final Map<String, Map<String, dynamic>> serverStates = {};
  List<Map<String, dynamic>> transfers = [];
  Set<String> _imported = {};
  Future<void> _serial = Future.value();
  static const channel = MethodChannel('sunmate/recorder_background');
  RecordingBackgroundController(
      {required this.store,
      required this.ownership,
      required this.archive,
      required this.processing,
      required this.driver,
      BackgroundNativeCall? native,
      this.exchange = backgroundExchange,
      bool? supported})
      : native =
            native ?? ((method, args) => channel.invokeMethod(method, args)),
        supported = supported ?? Platform.isIOS {
    ready = _load();
  }
  RecordingBackgroundPolicy get policy => ownership.policy;
  Future<void> _load() async {
    try {
      await Future.wait([ownership.ready, archive.ready, processing.ready]);
      _target();
      for (final row in await store.readAll('background_state')) {
        if (row['id'] == 'events') _imported = Set<String>.from(row['ids']);
        if (row['id'] == ownership.target) cursor = row['cursor'] as int;
      }
      for (final row in await store.readAll('background_results')) {
        if (row['target'] == ownership.target && row['body'] is Map)
          serverStates[row['remoteId'] ?? row['id']] = {
            'kind': row['kind'],
            ...Map<String, dynamic>.from(row['body'])
          };
      }
      loaded = true;
    } catch (_) {
      message = '后台设置未能安全读取；新增任务保持关闭，已有资料保留。';
    }
    if (!disposed) notifyListeners();
  }

  void _target() {
    final next = archive.config.paired
        ? jsonEncode(
            canonicalValue([archive.config.url, archive.config.identity]))
        : '';
    if (ownership.policy.any && ownership.policyTarget != next) {
      ownership.policy =
          RecordingBackgroundPolicy(revision: policy.revision + 1);
      message = '资料库已变化，后台开关已关闭；旧队列保持原资料库归属。';
    }
    ownership.target = next;
  }

  Future<void> archiveConfigurationChanged() async {
    await ready;
    final previous = ownership.target;
    _target();
    if (!loaded || previous == ownership.target) return;
    cursor = 0;
    serverStates.clear();
    transfers = [];
    ownership.policy = RecordingBackgroundPolicy(revision: policy.revision + 1);
    await store.put('background_policy', 'policy',
        {...policy.toJson(), 'target': ownership.target});
    ownership.policyTarget = ownership.target;
    if (supported) {
      final clean = await native('pause', null) == true;
      if (foreground) await driver.resumeAfterNativeBackground(clean);
      await _configureRestoration(false);
    }
    message = '资料库已变化，后台开关已关闭，旧队列保持原归属。旧服务器已接收的任务需在原服务器停用。';
    if (!disposed) notifyListeners();
  }

  Future<void> setFlag(String key, bool enabled) => _lock(() async {
        await ready;
        if (!loaded || !supported || !archive.config.paired)
          throw const RecordingProcessingException(
              '请先核对私有资料库连接；原生后台收段仅支持 iOS。');
        _target();
        final next = policy.changed(key, enabled);
        // Persist first so a failed network update remains visibly pending, never reset consent.
        await store.put('background_policy', 'policy',
            {...next.toJson(), 'target': ownership.target});
        ownership.policyTarget = ownership.target;
        ownership.policy = next;
        await configure();
        message = processorEnabled
            ? '设置已保存并经服务器确认。仅作用于之后新开始的录音；已有任务保留原归属。'
            : '设置已保存。服务器尚未启用处理：可上传归档，ASR 和总结将等待服务器配置。';
      });
  Future<void> configure() async {
    _target();
    if (!supported || !archive.config.paired) return;
    final c = archive.config;
    await store.put('background_policy', 'policy',
        {...policy.toJson(), 'target': ownership.target});
    ownership.policyTarget = ownership.target;
    // Native cancellation happens before a network revocation attempt.
    await native('configure', {
      'url': c.url,
      'token': c.token,
      'identity': c.identity,
      'target': ownership.target,
      ...policy.toJson()
    });
    await _configureRestoration(policy['receive']);
    final result = await exchange(c, 'policy', policy.toJson());
    processorEnabled = result['processorEnabled'] == true;
    if (result['revision'] != policy.revision ||
        jsonEncode(result['policy']) != jsonEncode(policy.flags)) {
      // Python canonical key ordering may differ; compare key/value pairs.
      if (result['revision'] != policy.revision ||
          result['policy'] is! Map ||
          backgroundFlags.any((k) => result['policy'][k] != policy[k]))
        throw const FormatException('服务器策略回执不一致');
    }
  }

  Future<void> _configureRestoration(bool enabled) =>
      IosBleConnection().enableRestoration(enabled);
  Future<void> _lock(Future<void> Function() work) {
    final task = _serial.then((_) async {
      busy = true;
      if (!disposed) notifyListeners();
      try {
        await work();
      } catch (_) {
        message = '后台队列未完成；请核对服务器配置、连接和本机存储后重试。原音频保留。';
        rethrow;
      } finally {
        busy = false;
        if (!disposed) notifyListeners();
      }
    });
    _serial = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  Future<void> refresh() => _lock(() async {
        await ready;
        _target();
        if (!loaded ||
            !supported ||
            !foreground ||
            !archive.config.paired ||
            !policy.any &&
                !ownership.sessions.values.any((v) => v['owner'] == 'server'))
          return;
        await configure();
        final boundTarget = ownership.target;
        final boundConfig = archive.config;
        await _importNative();
        for (final s in processing.sessions) {
          if (!ownership.current(s.id)) continue;
          for (final p in processing.partsOf(s.id)) {
            if (!p.ready || p.offsetSamples48 == null) continue;
            _checkTarget(boundTarget);
            await native('enqueue', {
              'sn': p.sn,
              'session': p.session,
              'part': p.source.part,
              'sha': p.source.sha256,
              'previousSha': p.contextSha,
              'purpose': p.purpose!.name,
              'observedStart':
                  (s.estimatedAnchor ?? s.observedStart ?? DateTime.now())
                      .toUtc()
                      .toIso8601String(),
              'timeConfidence':
                  s.estimatedAnchor == null ? 'unknown' : 'estimated',
              'policy': {
                ...Map<String, dynamic>.from(
                    ownership.sessions[s.id]!['policy']),
                'target': ownership.target
              }
            });
          }
        }
        await native('recover', null);
        final snapshot =
            Map<String, dynamic>.from(await native('snapshot', null) as Map);
        transfers = [
          for (final row in snapshot['transfers'] ?? [])
            if (row['target'] == boundTarget) Map<String, dynamic>.from(row)
        ];
        _checkTarget(boundTarget);
        await _manifests();
        for (var page = 0; page < 50; page++) {
          final result =
              await exchange(boundConfig, 'results', {'cursor': cursor});
          _checkTarget(boundTarget);
          final rows = result['changes'] as List;
          for (final raw in rows) {
            final row = Map<String, dynamic>.from(raw);
            if (row['cursor'] is! int || row['cursor'] <= cursor)
              throw const FormatException('结果游标无效');
            await _saveResult(row, boundTarget);
            _checkTarget(boundTarget);
            cursor = row['cursor'];
            await store
                .put('background_state', ownership.target, {'cursor': cursor});
          }
          if (rows.isEmpty) break;
        }
        message = '后台队列与服务器结果已核对。';
      });
  Future<void> _importNative() async {
    final snapshot =
        Map<String, dynamic>.from(await native('snapshot', null) as Map);
    if (snapshot['owner'] == true)
      throw const RecordingProcessingException('原生收段尚在完成当前文件，暂不并行读取。');
    for (final raw in snapshot['events'] ?? []) {
      final row = Map<String, dynamic>.from(raw);
      if (_imported.contains(row['eventId'])) continue;
      validateIdentity(row['sn'], row['session']);
      final purpose = row['purpose'] == null
          ? null
          : LongRecordingPurpose.values.byName(row['purpose']);
      final kind = switch (row['kind']) {
        'started' => SegmentSignalKind.started,
        'source' => SegmentSignalKind.source,
        'finalized' => SegmentSignalKind.finalized,
        'uncertain' => SegmentSignalKind.uncertain,
        _ => null
      };
      if (kind != null) {
        final signal = RecordingSegmentSignal(kind, row['sn'], row['session'],
            purpose: purpose,
            source: kind == SegmentSignalKind.source
                ? RecorderCommittedSegment(
                    part: row['part'],
                    size: row['size'],
                    sha256: row['sha'],
                    relativePath: row['source'])
                : null,
            totalParts: row['totalParts'],
            observed: DateTime.parse(row['observed']));
        await ownership.capture(signal,
            snapshot: row['policy'] == null
                ? null
                : Map<String, dynamic>.from(row['policy']),
            targetOverride: row['target'] as String?);
        await processing.accept(signal);
        if (kind == SegmentSignalKind.finalized)
          await processing
              .archiveImportedSession(sessionKey(signal.sn, signal.session));
      }
      _imported.add(row['eventId']);
      await store
          .put('background_state', 'events', {'ids': _imported.toList()});
    }
    await driver.reloadLocalLongFiles();
  }

  Future<void> _manifests() async {
    for (final s in processing.sessions) {
      if (!ownership.current(s.id) ||
          !processing.sessionComplete(s) ||
          s.observedEnd == null) continue;
      final parts = processing.partsOf(s.id);
      final ids = <String>[];
      for (final p in parts) {
        final matches = transfers
            .where((r) =>
                r['state'] == 'received' &&
                r['metadata']?['session'] == s.id &&
                r['metadata']?['part'] == p.source.part &&
                r['metadata']?['sourceSha'] == p.source.sha256)
            .toList();
        if (matches.length != 1) break;
        ids.add(matches.single['id']);
      }
      if (ids.length != parts.length || ids.isEmpty) continue;
      await exchange(archive.config, 'manifest', {
        'session': s.id,
        'purpose': s.purpose!.name,
        'parts': ids,
        'stopped': true,
        'tailConfirmed': true,
        'observedEnd': s.observedEnd!.toUtc().toIso8601String()
      });
    }
  }

  void _checkTarget(String expected) {
    if (expected !=
        jsonEncode(
            canonicalValue([archive.config.url, archive.config.identity])))
      throw const FormatException('资料库已变化，旧队列保留');
  }

  Future<void> _saveResult(Map<String, dynamic> row, String target) async {
    _checkTarget(target);
    final body = Map<String, dynamic>.from(row['body']);
    serverStates[row['remoteId'] ?? row['id']] = {'kind': row['kind'], ...body};
    // Preserve the complete server version before advancing the cursor.
    await store.put('background_results', '$target:${row['cursor']}',
        {'target': target, ...row, 'remoteId': row['id'], 'applied': false});
    if (body['archiveRecord'] is Map<String, dynamic>)
      await archive.adoptServerRecord(
          Map<String, dynamic>.from(body['archiveRecord']), target);
    if (row['kind'] == 'audio' && body['state'] == 'complete') {
      final meta = Map<String, dynamic>.from(body['metadata']);
      if (!ownership.current(meta['session']))
        throw const FormatException('结果资料库或会话归属不匹配');
      final active = processing
          .partsOf(meta['session'])
          .where((p) => p.source.part == meta['part'])
          .firstOrNull;
      if (active != null &&
          (active.source.sha256 != meta['sourceSha'] ||
              active.contextSha != meta['contextSha'])) {
        // The saved server version remains available for audit, never overwrites a new source.
      } else {
        await processing.acceptServerTranscript(
            meta, Map<String, dynamic>.from(body['result']));
      }
    } else if (row['kind'] == 'summary') {
      if (!ownership.current(body['session']))
        throw const FormatException('总结会话归属不匹配');
      final current = processing.partsOf(body['session']);
      final references = body['parts'] as List;
      final matching = references.length == current.length &&
          references.every((id) {
            final meta = serverStates[id]?['metadata'];
            return meta is Map &&
                current.any((p) =>
                    p.source.part == meta['part'] &&
                    p.source.sha256 == meta['sourceSha'] &&
                    p.contextSha == meta['contextSha']);
          });
      if (matching) await processing.acceptServerSummary(row['id'], body);
    }
    await store.put('background_results', '$target:${row['cursor']}',
        {'target': target, ...row, 'remoteId': row['id'], 'applied': true});
  }

  Future<void> setForeground(bool active) {
    foreground = active;
    final work = _lifecycle.then((_) => _transition(active));
    _lifecycle = work.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return work;
  }

  Future<void> _transition(bool active) async {
    await ready;
    if (!loaded || !supported) return;
    try {
      if (!active && policy['receive']) {
        final session = driver.longFileLibrary.activeSessionId;
        final sn = driver.longRecordings.active?.serialNumber;
        final owner = sn == null || session == null
            ? null
            : ownership.sessions[sessionKey(sn, session)];
        final activePolicy =
            owner?['owner'] == 'server' && owner?['target'] == ownership.target
                ? {
                    ...Map<String, dynamic>.from(owner!['policy']),
                    'target': ownership.target
                  }
                : RecordingBackgroundPolicy().toJson();
        if (await driver.prepareNativeBackground(activePolicy: activePolicy)) {
          if (foreground) {
            await driver.resumeAfterNativeBackground(true);
            return;
          }
          await native('acquire', null);
          message = '已交给原生收段；执行时机由 iOS 决定。';
        } else {
          message = '当前连接或文件事务不支持交接，保留音频等待前台恢复。';
        }
      } else if (active) {
        final clean = await native('release', null) == true;
        await _importNative();
        await driver.resumeAfterNativeBackground(clean);
        if (policy.any ||
            ownership.sessions.values.any((v) => v['owner'] == 'server'))
          await refresh();
      }
    } catch (_) {
      message = '后台交接未完成，已有音频保留；请在前台核对队列。';
    } finally {
      if (!disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

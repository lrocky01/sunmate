import asyncio
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import sqlite3
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from archive_runtime.store import Archive, fingerprint, SCHEMA
from archive_runtime.service import initialize, make_server, load_config, change_client
from archive_runtime.plugin import invoke, register
from prepare_archive import prepare


def record(id='notification:test', revision=1, text='合成通知', visible=True, kind='notification'):
    body = {'id': id, 'kind': kind, 'timestamp': '2026-10-21T10:00:00.000Z',
            'payload': {'text': text, 'scope': 'synthetic-meeting', 'appIdentifier': 'com.test'}, 'visible': visible}
    return {**body, 'revision': revision, 'sha': fingerprint(body)}


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sunmate-archive-test-')
        self.root = Path(self.temp.name) / 'sunmate-archive'
        initialize(self.root, 'default')
        self.archive = Archive(self.root / 'records.sqlite')
        self.client = next(iter(load_config(self.root)['clients']))

    def tearDown(self):
        self.temp.cleanup()

    def test_idempotent_exact_references_and_versions(self):
        a = record(); b = record(revision=2, text='第二版本')
        self.assertEqual(self.archive.ingest(self.client, [a])[0]['status'], 'accepted')
        self.assertEqual(self.archive.ingest(self.client, [a])[0]['status'], 'already_present')
        self.archive.ingest(self.client, [b])
        self.assertEqual(self.archive.search()['records'][0]['preview'], '第二版本')
        self.assertEqual(self.archive.get(self.client, a['id'], a['sha'])['payload']['text'], '合成通知')

    def test_old_revision_never_replaces_current_head(self):
        self.archive.ingest(self.client, [record(revision=3, text='最新')])
        self.assertEqual(self.archive.ingest(self.client, [record()])[0]['status'], 'conflict')
        self.assertEqual(self.archive.search()['records'][0]['revision'], 3)

    def test_same_revision_conflict_and_invalid_hash(self):
        self.archive.ingest(self.client, [record()])
        self.assertEqual(self.archive.ingest(self.client, [record(text='different')])[0]['status'], 'conflict')
        invalid = record(revision=2); invalid['sha'] = '0' * 64
        self.assertEqual(self.archive.ingest(self.client, [invalid])[0]['status'], 'invalid')

    def test_visibility_withdrawal_blocks_old_references(self):
        a = record(); self.archive.ingest(self.client, [a])
        self.archive.ingest(self.client, [record(revision=2, visible=False)])
        self.assertEqual(self.archive.search()['records'], [])
        self.assertIsNone(self.archive.get(self.client, a['id'], a['sha']))
        self.archive.ingest(self.client, [record(revision=3)])
        self.assertEqual(len(self.archive.search()['records']), 1)

    def test_literal_chinese_search_filters_and_pagination(self):
        self.archive.ingest(self.client, [record(id=str(n), text='会议_%测试' if n < 3 else 'else') for n in range(4)])
        page = self.archive.search(keyword='_%', kind='notification', app='com.test', scope='synthetic-meeting', limit=2)
        self.assertEqual(len(page['records']), 2)
        self.assertEqual(page['nextOffset'], 2)
        self.assertEqual(len(self.archive.search(keyword='_%', offset=2)['records']), 1)
        self.assertEqual(self.archive.search(keyword="' OR 1=1 --")['records'], [])

    def test_receipt_is_client_scoped(self):
        a = record(); self.archive.ingest(self.client, [a])
        ref = {k: a[k] for k in ('id', 'revision', 'sha')}
        self.assertEqual(self.archive.receipts('other-client', [ref])[0]['status'], 'missing')
        self.assertIsNone(self.archive.get('other-client', a['id'], a['sha']))

    def test_restart_and_backup_preserve_archive(self):
        a = record(); self.archive.ingest(self.client, [a])
        backup = Path(self.temp.name) / 'backup.sqlite'
        self.archive.backup(backup)
        self.assertEqual(Archive(backup, readonly=True).stats()['counts']['notification'], 1)
        with self.assertRaises(ValueError): self.archive.backup(backup)
        self.assertEqual(Archive(self.root / 'records.sqlite').get(self.client, a['id'], a['sha'])['sha'], a['sha'])

    def test_limits_and_readonly(self):
        with self.assertRaises(ValueError): self.archive.ingest(self.client, [record()] * 51)
        with self.assertRaises(ValueError): self.archive.search(limit=51)
        with self.assertRaises(Exception): Archive(self.root / 'records.sqlite', readonly=True).ingest(self.client, [record()])

    def test_long_text_and_span_pages_are_bounded_and_traceable(self):
        row = record(text='文' * 19000)
        row['payload']['spans'] = [{'text': '合成', 'startMs': n, 'endMs': n + 1} for n in range(250)]
        row['sha'] = fingerprint({k:v for k,v in row.items() if k not in ('sha','revision')})
        self.archive.ingest(self.client, [row])
        args = {'clientId': self.client, 'id': row['id'], 'sha': row['sha']}
        result = json.loads(invoke('sunmate_get', args, Path(self.temp.name)))
        self.assertEqual(len(result['record']['payload']['text']), 8000)
        self.assertEqual(len(result['record']['payload']['spans']), 100)
        self.assertEqual(result['nextTextOffset'], 8000)
        last = json.loads(invoke('sunmate_get', {**args, 'textOffset':16000, 'spanOffset':200}, Path(self.temp.name)))
        self.assertEqual(len(last['record']['payload']['text']), 3000)
        self.assertIsNone(last['nextTextOffset'])
        self.assertEqual(len(last['record']['payload']['spans']), 50)
        self.assertLess(len(json.dumps(self.archive.search(), ensure_ascii=False)), 1500)

    def test_explicit_client_creation_and_revocation_preserves_data(self):
        self.archive.ingest(self.client, [record()])
        token_file = change_client(self.root)
        self.assertEqual(token_file.stat().st_mode & 0o077, 0)
        self.assertEqual(len(load_config(self.root)['clients']), 2)
        change_client(self.root, self.client)
        self.assertNotIn(self.client, load_config(self.root)['clients'])
        self.assertEqual(self.archive.stats()['counts']['notification'], 1)

    def test_float_times_and_oversize_or_unknown_wire_fields_are_rejected(self):
        row = record(); row['payload']['start'] = .5
        row['sha'] = fingerprint({k:v for k,v in row.items() if k not in ('sha','revision')})
        self.assertEqual(self.archive.ingest(self.client, [row])[0]['status'], 'invalid')
        row = record(); row['token'] = 'synthetic-should-not-exist'
        self.assertEqual(self.archive.ingest(self.client, [row])[0]['status'], 'invalid')
        self.assertEqual(self.archive.ingest(self.client, [record(text='a' * (1024*1024))])[0]['status'], 'invalid')

    def test_transaction_failure_has_no_partial_committed_receipts(self):
        original = Archive.validate
        calls = []
        def fail_second(row):
            calls.append(row)
            if len(calls) == 2:
                raise sqlite3.OperationalError('database or disk is full')
            return original(row)
        with patch.object(Archive, 'validate', side_effect=fail_second), self.assertRaises(sqlite3.OperationalError):
            self.archive.ingest(self.client, [record('one'), record('two')])
        self.assertEqual(self.archive.stats()['counts'], {})

    def test_capacity_limit_refuses_content_and_keeps_receipt_missing(self):
        config = load_config(self.root); config['maxDatabaseBytes'] = 1
        (self.root/'config.json').write_text(json.dumps(config))
        server = make_server(self.root)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        token = (self.root/'client-token.txt').read_text()
        request = urllib.request.Request('http://127.0.0.1:%d/sunmate/v1/ingest'%server.server_port,
          data=json.dumps({'schema':SCHEMA,'records':[record()]}).encode(),
          headers={'Authorization':'Bearer '+token,'X-Sunmate-serverId':config['serverId'], 'X-Sunmate-libraryId':config['libraryId']})
        with self.assertRaises(urllib.error.HTTPError) as failure: urllib.request.urlopen(request)
        self.assertEqual(failure.exception.code, 507)
        self.assertEqual(self.archive.stats()['counts'], {})

    def test_plugin_readonly_profile_isolation_and_registration(self):
        self.archive.ingest(self.client, [record()])
        home = Path(self.temp.name)
        self.assertEqual(json.loads(invoke('sunmate_stats', {}, home))['counts']['notification'], 1)
        other = home / 'profiles' / 'other'
        initialize(other / 'sunmate-archive', 'other')
        self.assertEqual(json.loads(invoke('sunmate_stats', {}, other))['counts'], {})
        self.assertIn('error', json.loads(invoke('sunmate_search', {'sql': 'SELECT *'}, home)))
        calls = []
        class Context:
            def register_tool(self, **kwargs): calls.append(kwargs)
        register(Context())
        self.assertEqual(len(calls), 4)
        self.assertTrue(all(c['schema']['parameters']['additionalProperties'] is False for c in calls))
        self.assertTrue(all(c['is_async'] for c in calls))
        with patch.dict('os.environ', {'HERMES_HOME': str(home)}):
            result = asyncio.run(calls[2]['handler']({}))
        self.assertEqual(json.loads(result)['counts']['notification'], 1)

    def test_preparation_preserves_existing_plugin(self):
        target = prepare(Path(self.temp.name))
        self.assertTrue((target / 'plugin.yaml').is_file())
        with self.assertRaises(ValueError): prepare(Path(self.temp.name))

    def test_http_auth_identity_and_token_revocation(self):
        server = make_server(self.root)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        url = 'http://127.0.0.1:%d/sunmate/v1/' % server.server_port
        token = (self.root / 'client-token.txt').read_text()
        def request(route, body=None, headers=None):
            req = urllib.request.Request(url + route, data=None if body is None else json.dumps(body).encode(),
                    headers={'Authorization': 'Bearer ' + token, **(headers or {})})
            return json.loads(urllib.request.urlopen(req, timeout=2).read())
        identity = request('capabilities')
        self.assertFalse(identity['rawAudio'])
        with self.assertRaises(urllib.error.HTTPError) as failure: request('ingest', {'schema': SCHEMA, 'records': [record()]})
        self.assertEqual(failure.exception.code, 409)
        headers = {'X-Sunmate-serverId': identity['serverId'], 'X-Sunmate-libraryId': identity['libraryId']}
        self.assertEqual(request('ingest', {'schema': SCHEMA, 'records': [record()]}, headers)['receipts'][0]['status'], 'accepted')
        config = load_config(self.root); config['clients'] = {}
        (self.root / 'config.json').write_text(json.dumps(config))
        with self.assertRaises(urllib.error.HTTPError) as failure: request('capabilities')
        self.assertEqual(failure.exception.code, 401)


if __name__ == '__main__':
    unittest.main()

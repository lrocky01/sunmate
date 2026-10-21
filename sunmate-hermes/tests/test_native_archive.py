"""Synthetic aiohttp integration, no user Hermes home, model or credentials."""
import asyncio
import json
import io
import os
from pathlib import Path
import tempfile
import threading
import sys
import types
import unittest
from unittest.mock import patch

try:
    from aiohttp import web
    from aiohttp.test_utils import TestClient, TestServer
except ImportError:
    web = None

from test_archive import record
from archive_runtime.native_api import mount
from archive_runtime.plugin import register, invoke
from archive_runtime.service import ArchiveAPI, MAX_BODY, initialize, load_config, change_client
from archive_runtime.store import Archive, SCHEMA


@unittest.skipIf(web is None, 'Native integration requires the Hermes aiohttp dependency')
class NativeArchiveTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sunmate-native-test-')
        self.home = Path(self.temp.name)
        self.root = self.home / 'sunmate-archive'
        initialize(self.root, 'default')
        self.config = load_config(self.root)
        self.token = (self.root / 'client-token.txt').read_text()
        self.environment = patch.dict(os.environ, {'HERMES_HOME': str(self.home)})
        self.environment.start()
        self.headers = {'Authorization': 'Bearer ' + self.token,
            'X-Sunmate-serverId': self.config['serverId'],
            'X-Sunmate-libraryId': self.config['libraryId']}
        self.calls = []
        class Context:
            def register_platform_handler(_, platform, factory):
                self.calls.append((platform, factory))
            def register_tool(_, **kwargs):
                pass
        with patch.dict(os.environ, {'HERMES_HOME': str(self.home)}):
            register(Context())
        self.assertEqual(self.calls[0][0], 'api_server')
        self.app = web.Application()
        async def chat(request):
            if request.headers.get('Authorization') != 'Bearer synthetic-hermes-api-key':
                return web.json_response({'error': 'chat_auth'}, status=401)
            response = web.StreamResponse(headers={'Content-Type': 'text/event-stream'})
            await response.prepare(request)
            await response.write(b'data: {"choices":[{"delta":{"content":"synthetic-final"},"finish_reason":"stop"}]}\n\n')
            await response.write(b'data: [DONE]\n\n')
            return response
        self.app.router.add_post('/v1/chat/completions', chat)
        self.calls[0][1](self.app, object())
        self.client = TestClient(TestServer(self.app))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        self.environment.stop()
        self.temp.cleanup()

    async def post(self, path, value, headers=None):
        return await self.client.post('/sunmate/v1/' + path, json=value,
            headers=self.headers if headers is None else headers)

    async def test_shared_listener_chat_and_archive_have_separate_credentials(self):
        response = await self.client.get('/sunmate/v1/capabilities', headers=self.headers)
        self.assertEqual(response.status, 200)
        self.assertEqual((await response.json())['libraryId'], self.config['libraryId'])
        rejected = await self.client.get('/sunmate/v1/capabilities',
            headers={'Authorization': 'Bearer synthetic-hermes-api-key'})
        self.assertEqual(rejected.status, 401)
        rejected = await self.client.post('/v1/chat/completions', headers=self.headers)
        self.assertEqual(rejected.status, 401)
        chat = await self.client.post('/v1/chat/completions',
            headers={'Authorization': 'Bearer synthetic-hermes-api-key'})
        self.assertEqual(chat.status, 200)
        self.assertIn('synthetic-final', await chat.text())
        self.assertTrue((await chat.text()).endswith('data: [DONE]\n\n'))

    async def test_receipts_versions_and_tools_share_same_archive(self):
        row = record()
        for expected in ('accepted', 'already_present'):
            result = await self.post('ingest', {'schema': SCHEMA, 'records': [row]})
            self.assertEqual(result.status, 200)
            self.assertEqual((await result.json())['receipts'][0]['status'], expected)
        ref = {key: row[key] for key in ('id', 'revision', 'sha')}
        receipt = await self.post('receipts', {'schema': SCHEMA, 'refs': [ref]})
        self.assertEqual((await receipt.json())['receipts'][0]['status'], 'accepted')
        client = next(iter(self.config['clients']))
        fetched = json.loads(invoke('sunmate_get', {'clientId': client, 'id': row['id'], 'sha': row['sha']}, self.home))
        self.assertEqual(fetched['record']['payload']['text'], row['payload']['text'])
        await self.post('ingest', {'schema': SCHEMA, 'records': [record(revision=2, visible=False)]})
        self.assertIsNone(json.loads(invoke('sunmate_get', {'clientId': client, 'id': row['id'], 'sha': row['sha']}, self.home))['record'])

    async def test_wrong_identity_and_invalid_body_never_write(self):
        wrong = {**self.headers, 'X-Sunmate-libraryId': 'another-library'}
        result = await self.post('ingest', {'schema': SCHEMA, 'records': [record()]}, wrong)
        self.assertEqual(result.status, 409)
        for body in ([], {'schema': 'wrong'}, {'schema': SCHEMA, 'records': []}):
            result = await self.post('ingest', body)
            self.assertEqual(result.status, 400)
        malformed = await self.client.post('/sunmate/v1/ingest', data=b'{invalid', headers=self.headers)
        self.assertEqual(malformed.status, 400)
        self.assertEqual(Archive(self.root / 'records.sqlite', readonly=True).stats()['counts'], {})

    async def test_limits_apply_to_known_and_chunked_body(self):
        result = await self.client.post('/sunmate/v1/ingest', data=io.BytesIO(b'x' * (MAX_BODY + 1)), headers=self.headers)
        self.assertEqual(result.status, 400)
        async def chunks():
            for _ in range(MAX_BODY // 65536 + 1):
                yield b'x' * 65536
        result = await self.client.post('/sunmate/v1/ingest', data=chunks(), headers=self.headers)
        self.assertEqual(result.status, 400)
        self.assertEqual(Archive(self.root / 'records.sqlite', readonly=True).stats()['counts'], {})

    async def test_valid_chunked_body_and_revocation_during_upload(self):
        async def chunks():
            data = json.dumps({'schema': SCHEMA, 'records': [record()]}).encode()
            yield data[:10]
            await asyncio.sleep(0)
            yield data[10:]
        response = await self.client.post('/sunmate/v1/ingest', data=chunks(), headers=self.headers)
        self.assertEqual(response.status, 200)
        original = ArchiveAPI.handle
        def revoked(api, *args):
            change_client(self.root, next(iter(self.config['clients'])))
            return original(api, *args)
        with patch.object(ArchiveAPI, 'handle', revoked):
            response = await self.post('ingest', {'schema': SCHEMA, 'records': [record('second')]})
        self.assertEqual(response.status, 401)
        self.assertEqual(Archive(self.root / 'records.sqlite', readonly=True).stats()['counts']['notification'], 1)

    async def test_revocation_and_second_client_are_checked_per_request(self):
        row = record()
        await self.post('ingest', {'schema': SCHEMA, 'records': [row]})
        token_file = change_client(self.root)
        other = {**self.headers, 'Authorization': 'Bearer ' + token_file.read_text()}
        result = await self.post('receipts', {'schema': SCHEMA,
            'refs': [{k: row[k] for k in ('id', 'revision', 'sha')}]}, other)
        self.assertEqual((await result.json())['receipts'][0]['status'], 'missing')
        change_client(self.root, next(iter(self.config['clients'])))
        result = await self.client.get('/sunmate/v1/capabilities', headers=self.headers)
        self.assertEqual(result.status, 401)
        self.assertEqual(Archive(self.root / 'records.sqlite', readonly=True).stats()['counts']['notification'], 1)

    async def test_profile_is_fixed_at_registration_and_request_cannot_override(self):
        other = self.home / 'profiles' / 'other'
        initialize(other / 'sunmate-archive', 'other')
        with patch.dict(os.environ, {'HERMES_HOME': str(other)}):
            result = await self.client.get('/sunmate/v1/capabilities', headers=self.headers)
        self.assertEqual(result.status, 409)
        self.assertEqual((await result.json())['error'], 'profile_mismatch')
        result = await self.client.get('/p/other/sunmate/v1/capabilities', headers=self.headers)
        self.assertEqual(result.status, 404)
        result = await self.client.get('/sunmate/v1/capabilities?profile=other', headers=self.headers)
        self.assertEqual(result.status, 404)
        config = load_config(self.root); config['profile'] = 'other'
        (self.root / 'config.json').write_text(json.dumps(config))
        result = await self.client.get('/sunmate/v1/capabilities', headers=self.headers)
        self.assertEqual(result.status, 400)

    async def test_hermes_runtime_profile_override_is_used_without_env_mutation(self):
        other = self.home / 'profiles' / 'other'
        initialize(other / 'sunmate-archive', 'other')
        constants = types.ModuleType('hermes_constants')
        constants.get_hermes_home = lambda: other
        with patch.dict(sys.modules, {'hermes_constants': constants}):
            response = await self.client.get('/sunmate/v1/capabilities', headers=self.headers)
            self.assertEqual(response.status, 409)
            stats = json.loads(invoke('sunmate_stats', {}))
            self.assertEqual(stats['counts'], {})
            self.assertEqual(stats['libraryId'], load_config(other / 'sunmate-archive')['libraryId'])

    async def test_missing_config_and_missing_database_do_not_initialize(self):
        missing = self.home / 'not-created'
        app = web.Application()
        mount(app, missing, 'default')
        async with TestClient(TestServer(app)) as client:
            result = await client.get('/sunmate/v1/capabilities', headers=self.headers)
            self.assertEqual(result.status, 503)
        self.assertFalse(missing.exists())
        # A configured but incomplete restore cannot silently create a fresh DB.
        with patch.object(Path, 'is_file', return_value=False):
            result = await self.post('ingest', {'schema': SCHEMA, 'records': [record()]})
        self.assertEqual(result.status, 503)

    async def test_capacity_error_and_storage_failure_are_explicit(self):
        config = load_config(self.root); config['maxDatabaseBytes'] = 1
        (self.root / 'config.json').write_text(json.dumps(config))
        result = await self.post('ingest', {'schema': SCHEMA, 'records': [record()]})
        self.assertEqual(result.status, 507)
        with patch.object(ArchiveAPI, 'authorize', side_effect=OSError('synthetic-private-detail')):
            result = await self.client.get('/sunmate/v1/capabilities', headers=self.headers)
        self.assertEqual(result.status, 503)
        self.assertNotIn('synthetic-private-detail', await result.text())

    async def test_slow_archive_does_not_block_same_listener_chat(self):
        started, release = threading.Event(), threading.Event()
        original = ArchiveAPI.handle
        def slow(api, *args):
            started.set()
            release.wait(3)
            return original(api, *args)
        with patch.object(ArchiveAPI, 'handle', slow):
            pending = asyncio.create_task(self.client.get('/sunmate/v1/capabilities', headers=self.headers))
            try:
                self.assertTrue(await asyncio.to_thread(started.wait, 1))
                response = await asyncio.wait_for(self.client.post('/v1/chat/completions',
                    headers={'Authorization': 'Bearer synthetic-hermes-api-key'}), timeout=1)
                self.assertIn('synthetic-final', await response.text())
            finally:
                release.set()
                await pending

    async def test_native_reconnect_uses_new_router_and_preserves_existing_routes(self):
        with self.assertRaises(ValueError):
            mount(self.app, self.root, 'default')  # Already running/frozen.
        fresh = web.Application()
        self.calls[0][1](fresh, object())
        with self.assertRaises(ValueError):
            mount(fresh, self.root, 'default')  # Never shadow a prior owner.
        self.assertEqual(len(list(fresh.router.routes())), 8)
        async with TestClient(TestServer(fresh)) as client:
            response = await client.get('/sunmate/v1/capabilities', headers=self.headers)
            self.assertEqual(response.status, 200)


if __name__ == '__main__':
    unittest.main()

"""Durable worker and native HTTP tests using synthetic audio and temporary homes."""
import asyncio
import hashlib
import json
import tempfile
import shutil
import sys
import threading
import time
from unittest.mock import patch
from pathlib import Path
import unittest
from archive_runtime.audio_jobs import AudioJobs, FLAGS, SCHEMA
from archive_runtime.service import initialize, load_config, change_client
from archive_runtime.store import Archive


class Processor:
    def __init__(self):
        self.submits = 0
        self.polls = 0
        self.summaries = []
        self.unknown = False

    async def submit(self, source, metadata):
        self.submits += 1
        if self.unknown: raise TimeoutError()
        return 'synthetic-job'

    async def poll(self, job):
        self.polls += 1
        return {'text': '合成文字', 'spans': [{'startMs': 0, 'endMs': 20, 'speaker': '0', 'text': '合成文字'}]}

    async def summarize(self, evidence):
        self.summaries.append(evidence)
        return '合成总结'


class AudioTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sunmate-audio-test-')
        self.root = Path(self.temp.name) / 'archive'
        initialize(self.root, 'default')
        self.config = load_config(self.root)
        self.headers = {'Authorization': 'Bearer ' + (self.root / 'client-token.txt').read_text(),
                        **{'X-Sunmate-' + key: self.config[key] for key in ('serverId', 'libraryId')}}
        self.client = next(iter(self.config['clients']))
        self.jobs = AudioJobs(self.root, 'default')
        self.flags = {key: False for key in FLAGS}
        self.payload = b'OggS' + b'synthetic-only-no-real-audio'
        self.processor = Processor()

    async def asyncTearDown(self):
        self.temp.cleanup()

    def server_enabled(self):
        config = load_config(self.root)
        config['audioProcessing'] = {'enabled': True, 'asrUrl': 'http://127.0.0.1:1', 'hermesUrl': 'http://127.0.0.1:2'}
        (self.root / 'config.json').write_text(json.dumps(config))

    def enable(self, kind='meeting', summary=True):
        self.flags.update({kind + 'Upload': True, kind + 'Asr': True, kind + 'Summary': summary})
        self.jobs.policy(self.headers, {'revision': 1, 'policy': self.flags})

    def metadata(self, part=0, kind='meeting'):
        return {'session': 'SZ_SYNTHETIC_' + kind + ':1792496000000', 'part': part, 'sourceSha': 'a' * 64,
                'sha': hashlib.sha256(self.payload).hexdigest(), 'bytes': len(self.payload), 'purpose': kind,
                'lead48': 0, 'samples48': getattr(self, 'duration48', 960), 'offset48': part * getattr(self, 'duration48', 960),
                'observedStart': '2026-10-20T19:00:00.000Z', 'timeConfidence': 'estimated',
                'contextSha': None if part == 0 else 'a' * 64, 'processAsr': True, 'processSummary': self.flags[kind + 'Summary']}

    def upload(self, part=0, kind='meeting'):
        ticket = self.jobs.ticket(self.headers, self.metadata(part, kind))
        path = self.jobs.audio_dir() / ('synthetic-' + str(part) + '.partial')
        path.write_bytes(self.payload)
        self.jobs.commit_upload(ticket['id'], ticket['uploadToken'], path)
        return ticket['id']

    def manifest(self, ids, kind='meeting'):
        return self.jobs.manifest(self.headers, {'session': self.metadata(kind=kind)['session'], 'purpose': kind, 'parts': ids,
            'stopped': True, 'tailConfirmed': True, 'observedEnd': '2026-10-20T19:01:00.000Z'})

    async def test_all_defaults_off_no_worker_or_upload(self):
        with self.assertRaises(PermissionError): self.jobs.ticket(self.headers, self.metadata())
        await self.jobs.tick(self.processor)
        self.assertEqual(self.processor.submits, 0)
        self.assertFalse((self.root / 'audio.sqlite').exists() and self.processor.polls)

    async def test_both_purposes_stop_tail_and_restart_summary(self):
        for kind in ('meeting', 'lifelog'):
            with self.subTest(kind=kind):
                # Independent temp identity across purposes avoids reusing a manifest.
                self.jobs.policy(self.headers, {'revision': 2 if kind == 'lifelog' else 1,
                    'policy': {key: key.startswith(kind) for key in FLAGS}})
                self.flags = {key: key.startswith(kind) for key in FLAGS}
                self.server_enabled()
                one = self.upload(kind=kind)
                two = self.upload(part=1, kind=kind)
                await self.jobs.tick(self.processor)  # Persist real job ids.
                restored = AudioJobs(self.root, 'default')
                await restored.tick(self.processor)  # Resume polling, not POST.
                self.assertEqual(len(self.processor.summaries), 0 if kind == 'meeting' else 1)
                self.manifest([one, two], kind)
                await restored.tick(self.processor)
                expected = 1 if kind == 'meeting' else 2
                self.assertEqual(len(self.processor.summaries), expected)
                await restored.tick(self.processor)
                self.assertEqual(len(self.processor.summaries), expected)

    async def test_unknown_submission_never_blindly_reposts(self):
        self.enable(); self.server_enabled(); identity = self.upload()
        self.processor.unknown = True
        await self.jobs.tick(self.processor)
        await AudioJobs(self.root).tick(self.processor)
        self.assertEqual(self.processor.submits, 1)
        states = self.jobs.results(self.headers, 0)['changes']
        self.assertEqual(states[-1]['body']['state'], 'submission_unknown')
        self.assertTrue((self.jobs.audio_dir() / (identity + '.ogg')).exists())

    async def test_duplicate_receipt_never_uploads_or_submits_twice(self):
        self.enable(); self.server_enabled(); identity = self.upload()
        again = self.jobs.ticket(self.headers, self.metadata())
        self.assertTrue(again['received']); self.assertEqual(again['id'], identity)
        await self.jobs.tick(self.processor); await self.jobs.tick(self.processor); await self.jobs.tick(self.processor)
        self.assertEqual(self.processor.submits, 1)
        self.assertEqual(len(Archive(self.root / 'records.sqlite').search(kind='transcript')['records']), 1)

    async def test_revocation_before_commit_and_before_asr(self):
        self.enable(); ticket = self.jobs.ticket(self.headers, self.metadata())
        path = self.jobs.audio_dir() / 'pending.partial'; path.write_bytes(self.payload)
        self.jobs.policy(self.headers, {'revision': 2, 'policy': {key: False for key in FLAGS}})
        with self.assertRaises(PermissionError): self.jobs.commit_upload(ticket['id'], ticket['uploadToken'], path)
        self.server_enabled(); await self.jobs.tick(self.processor)
        self.assertEqual(self.processor.submits, 0)

    async def test_snapshot_does_not_grant_asr_retroactively(self):
        self.flags['meetingUpload'] = True
        self.jobs.policy(self.headers, {'revision': 1, 'policy': self.flags})
        meta = self.metadata(); meta['processAsr'] = False
        ticket = self.jobs.ticket(self.headers, meta)
        path = self.jobs.audio_dir() / 'pending.partial'; path.write_bytes(self.payload)
        self.jobs.commit_upload(ticket['id'], ticket['uploadToken'], path)
        self.jobs.policy(self.headers, {'revision': 2, 'policy': {key: key.startswith('meeting') for key in FLAGS}})
        self.server_enabled(); await self.jobs.tick(self.processor)
        self.assertEqual(self.processor.submits, 0)

    async def test_wrong_hash_manifest_gap_and_identity_are_rejected(self):
        self.enable(); ticket = self.jobs.ticket(self.headers, self.metadata())
        file = self.jobs.audio_dir() / 'bad.partial'; file.write_bytes(b'OggSbad')
        with self.assertRaises(ValueError): self.jobs.commit_upload(ticket['id'], ticket['uploadToken'], file)
        one = self.upload(); two = self.upload(part=2)
        with self.assertRaises(ValueError): self.manifest([one, two])
        with self.assertRaises(ValueError): self.jobs.ticket({**self.headers, 'X-Sunmate-libraryId': 'other'}, self.metadata())
        with self.assertRaises(PermissionError): self.jobs.upload_identity(ticket['id'], 'wrong')
        config = load_config(self.root); config['clients'] = {}; (self.root / 'config.json').write_text(json.dumps(config))
        with self.assertRaises(PermissionError): self.jobs.upload_identity(ticket['id'], ticket['uploadToken'])

    async def test_concurrent_reservations_respect_capacity(self):
        self.enable(); config = load_config(self.root); config['maxAudioBytes'] = len(self.payload)
        (self.root / 'config.json').write_text(json.dumps(config))
        self.jobs.ticket(self.headers, self.metadata())
        with self.assertRaises(ValueError): self.jobs.ticket(self.headers, self.metadata(part=1))

    async def test_long_summary_batches_survive_restart_without_repeating_model_calls(self):
        self.enable(); self.server_enabled(); identity = self.upload(); self.manifest([identity])
        await self.jobs.tick(self.processor)
        large = {'text': '合成资料' * 20000, 'spans': []}
        self.processor.poll = lambda job: asyncio.sleep(0, result=large)
        for _ in range(15):
            await AudioJobs(self.root).tick(self.processor)
            with self.jobs.connect() as db:
                if db.execute('SELECT state FROM manifests').fetchone()[0] == 'complete': break
        with self.jobs.connect() as db:
            self.assertEqual(db.execute('SELECT state FROM manifests').fetchone()[0], 'complete')
            count = db.execute('SELECT count(*) FROM summary_batches').fetchone()[0]
        self.assertGreater(count, 0)
        self.assertEqual(len(self.processor.summaries), count + 1)
        await self.jobs.tick(self.processor)
        self.assertEqual(len(self.processor.summaries), count + 1)

    async def test_lifelog_summary_uses_only_own_visible_notifications_in_range(self):
        from archive_runtime.store import fingerprint
        self.enable('lifelog'); self.server_enabled(); identity = self.upload(kind='lifelog'); self.manifest([identity], 'lifelog')
        archive = Archive(self.root / 'records.sqlite')
        def notification(name, visible=True):
            body = {'id': name, 'kind': 'notification', 'timestamp': '2026-10-20T19:00:30.000Z', 'payload': {'text': '合成通知'}, 'visible': visible}
            return {**body, 'revision': 1, 'sha': fingerprint(body)}
        archive.ingest(self.client, [notification('notification:allowed'), notification('notification:hidden', False)])
        archive.ingest('other-synthetic-client', [notification('notification:other')])
        await self.jobs.tick(self.processor); await self.jobs.tick(self.processor)
        evidence = self.processor.summaries[0]
        self.assertEqual([x['id'] for x in evidence['notifications']], ['notification:allowed'])


try:
    from aiohttp import web
    from aiohttp.test_utils import TestClient, TestServer
except ImportError:
    web = None


@unittest.skipIf(web is None, 'requires Hermes aiohttp')
class AudioHTTPTests(AudioTests):
    async def test_slow_worker_does_not_block_native_chat_listener(self):
        from archive_runtime.native_api import mount
        entered = threading.Event()
        async def slow(_):
            entered.set(); time.sleep(.5)
        app = web.Application()
        async def ping(request): return web.json_response({'ok': True})
        app.router.add_get('/synthetic-chat', ping)
        mount(app, self.root, 'default')
        with patch.object(AudioJobs, 'tick', slow):
            begin = time.monotonic()
            async with TestClient(TestServer(app)) as client:
                self.assertTrue(await asyncio.to_thread(entered.wait, 1))
                response = await client.get('/synthetic-chat')
                self.assertEqual(response.status, 200)
                self.assertLess(time.monotonic() - begin, .4)
    async def test_existing_audio_route_is_preserved_before_any_mount_mutation(self):
        from archive_runtime.native_api import mount
        app = web.Application()
        app.router.add_put('/sunmate/v1/audio/upload/{identity}', lambda request: web.Response(text='existing'))
        before = list(app.router.routes())
        with self.assertRaises(ValueError): mount(app, self.root, 'default')
        self.assertEqual(list(app.router.routes()), before)
    async def test_native_file_upload_receipt_and_process_restart(self):
        if sys.platform != 'darwin' or not shutil.which('swiftc'): self.skipTest('requires macOS URLSession')
        from archive_runtime.native_api import mount
        source = Path(__file__).resolve().parents[2] / 'sunmate_app'
        exe = self.root / 'native-upload'
        process = await asyncio.create_subprocess_exec(shutil.which('swiftc'), '-swift-version', '5',
            str(source / 'ios/Runner/RecorderBackgroundFiles.swift'), str(source / 'ios/Runner/RecorderBackgroundTransfer.swift'),
            str(source / 'test/native_background_upload/main.swift'), '-o', str(exe), stderr=asyncio.subprocess.PIPE)
        _, error = await process.communicate()
        self.assertEqual(process.returncode, 0, error.decode())
        self.enable()
        app = web.Application(); mount(app, self.root, 'default')
        async with TestClient(TestServer(app)) as client:
            (self.root / 'synthetic.ogg').write_bytes(self.payload)
            plan = {'url': str(client.make_url('/sunmate/v1')), 'token': self.headers['Authorization'][7:],
                    'identity': {key: self.config[key] for key in ('serverId', 'libraryId')}, 'policy': self.flags, 'target': 'synthetic-target'}
            (self.root / 'fixture.json').write_text(json.dumps({'plan': plan, 'metadata': self.metadata()}))
            for _ in range(2):
                run = await asyncio.create_subprocess_exec(str(exe), str(self.root), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                output, error = await asyncio.wait_for(run.communicate(), 20)
                self.assertEqual(run.returncode, 0, error.decode())
                self.assertEqual(json.loads(output)['accepted'], 1)
            results = self.jobs.results(self.headers, 0)['changes']
            self.assertEqual(len(results), 1, 'Restart must recover the receipt, not upload bytes again')

    async def test_real_private_processor_wav_asr_poll_and_hermes_complete(self):
        if not shutil.which('ffmpeg'): self.skipTest('requires local ffmpeg synthetic encoder')
        from archive_runtime.audio_jobs import PrivateProcessor
        encoded = self.root / 'synthetic.ogg'
        process = await asyncio.create_subprocess_exec(shutil.which('ffmpeg'), '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=437:duration=0.1:sample_rate=16000', '-c:a', 'libopus', str(encoded), stderr=asyncio.subprocess.DEVNULL)
        self.assertEqual(await process.wait(), 0)
        self.payload = encoded.read_bytes()
        self.duration48 = 4800
        calls = []
        async def submit(request):
            form = await request.multipart()
            file = await form.next()
            data = await file.read()
            self.assertTrue(data.startswith(b'RIFF')); self.assertEqual(file.filename, 'recording.wav')
            calls.append('submit')
            return web.json_response({'job_id': 'synthetic-job'}, status=202)
        async def poll(request):
            calls.append('poll')
            return web.json_response({'status': 'done', 'result': {'text': '合成转写', 'segments': [{'speaker': '0', 'start': 0, 'end': .02, 'text': '合成转写'}]}})
        async def summary(request):
            value = await request.json()
            evidence = json.loads(value['messages'][1]['content'])
            self.assertEqual(evidence['purpose'], 'meeting')
            self.assertEqual(len(evidence['parts']), 1)
            calls.append('summary')
            return web.json_response({'choices': [{'message': {'content': '合成完整纪要'}}]})
        app = web.Application(); app.router.add_post('/v1/jobs', submit); app.router.add_get('/v1/jobs/{id}', poll); app.router.add_post('/v1/chat/completions', summary)
        async with TestClient(TestServer(app)) as client:
            self.enable(); identity = self.upload(); self.manifest([identity])
            config = load_config(self.root)
            config['audioProcessing'] = {'enabled': True, 'asrUrl': str(client.make_url('')).rstrip('/'), 'hermesUrl': str(client.make_url('')).rstrip('/'), 'ffmpeg': shutil.which('ffmpeg')}
            (self.root / 'config.json').write_text(json.dumps(config))
            await self.jobs.tick()  # Real PrivateProcessor -> actual local HTTP.
            await AudioJobs(self.root).tick()
            await self.jobs.tick()
            self.assertEqual(calls, ['submit', 'poll', 'summary'])
            results = self.jobs.results(self.headers, 0)['changes']
            self.assertEqual(results[-1]['body']['text'], '合成完整纪要')
            self.assertTrue((self.jobs.audio_dir() / (identity + '.ogg')).exists())

    async def test_native_stream_upload_and_client_result_isolation(self):
        from archive_runtime.native_api import mount
        app = web.Application(); mount(app, self.root, 'default')
        async with TestClient(TestServer(app)) as client:
            capabilities = await client.get('/sunmate/v1/capabilities', headers=self.headers)
            self.assertTrue((await capabilities.json())['audioJobs']['nativeRoutes'])
            p = {key: key.startswith('meeting') for key in FLAGS}
            response = await client.post('/sunmate/v1/audio/policy', headers=self.headers, json={'schema': SCHEMA, 'revision': 1, 'policy': p})
            self.assertEqual(response.status, 200)
            self.flags = p
            response = await client.post('/sunmate/v1/audio/tickets', headers=self.headers, json={'schema': SCHEMA, **self.metadata()})
            self.assertEqual(response.status, 200); ticket = await response.json()
            async def chunks():
                for byte in self.payload: yield bytes([byte])
            response = await client.put('/sunmate/v1/audio/upload/' + ticket['id'], headers={'Authorization': 'Bearer ' + ticket['uploadToken'], 'Content-Length': str(len(self.payload))}, data=chunks())
            self.assertEqual(response.status, 200); self.assertTrue((await response.json())['received'])
            other_token_path = change_client(self.root)
            other_headers = {**self.headers, 'Authorization': 'Bearer ' + other_token_path.read_text()}
            response = await client.post('/sunmate/v1/audio/results', headers=other_headers, json={'schema': SCHEMA, 'cursor': 0})
            self.assertEqual((await response.json())['changes'], [])
            response = await client.post('/sunmate/v1/audio/results', headers=self.headers, json={'schema': SCHEMA, 'cursor': 0})
            self.assertEqual(len((await response.json())['changes']), 1)
            response = await client.post('/sunmate/v1/audio/tickets', headers=self.headers, json={'schema': SCHEMA, **self.metadata(), 'asrUrl': 'http://example.invalid'})
            self.assertEqual(response.status, 400)

"""Check declared compatibility against synthetic HTTP requests from real App code."""
import hashlib
import json
import unittest
from pathlib import Path

from test_installer import SOURCE, installer


class AppCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.contract = json.loads((SOURCE / "compatibility.json").read_text())
        self.fixture = json.loads((SOURCE / "tests/fixtures/current-app-requests.json").read_text())
        self.cases = {row["case"]: row["request"] for row in self.fixture["cases"]}

    def test_captured_evidence_matches_current_app_source_and_version(self):
        app = SOURCE.parent / "sunmate_app"
        self.assertEqual(hashlib.sha256((app / "lib/core/ai/agent_client.dart").read_bytes()).hexdigest(), self.fixture["agentSourceSha256"], "App请求代码变化后需重新从回环HTTP捕获合成请求，重新核对兼容范围")
        self.assertIn("version: " + self.fixture["appVersion"], (app / "pubspec.yaml").read_text())
        self.assertEqual(self.contract["appVersion"], self.fixture["appVersion"])
        self.assertEqual(self.contract["version"], installer.VERSION)

    def test_declared_routes_cover_all_real_request_cases(self):
        self.assertEqual(set(self.contract["requests"]), set(self.cases))
        for name, body in self.cases.items():
            with self.subTest(name=name):
                self.assertTrue(body["stream"])
                self.assertEqual(body["model"], "hermes-agent")
                self.assertEqual(body["messages"][0]["role"], "system")
                self.assertEqual(body["messages"][-1]["role"], "user")
                self.assertNotIn("tools", body)
                self.assertNotIn("Authorization", body)
        for name in ["meeting", "lifelog", "notification"]:
            self.assertIn(self.contract["requests"][name]["skill"], installer.SKILLS)

    def test_notification_original_ids_fragments_and_batch_are_preserved(self):
        text = self.cases["notification"]["messages"][-1]["content"]
        payload = json.loads(text[text.index('{"schemaVersion"'):])
        self.assertEqual(payload["schemaVersion"], self.contract["requests"]["notification"]["format"])
        self.assertEqual(payload["task"], "notification_digest")
        self.assertEqual(payload["timeline"], [])
        self.assertNotIn("filteredSpamCount", payload)
        self.assertNotIn("range", payload)  # Current App does not send the selected range explicitly.
        originals = [n for n in payload["notifications"] if n.get("sourceType") != "notification_digest_batch"]
        self.assertEqual({n["id"] for n in originals}, {"fixture-notice-1"})
        self.assertEqual({n["fragment"] for n in originals}, {"1/2", "2/2"})
        batch = payload["notifications"][-1]
        self.assertEqual(batch["sourceType"], self.contract["requests"]["notification"]["batchSourceType"])
        self.assertTrue(all(n["timestamp"].endswith("Z") for n in payload["notifications"]))

    def test_legacy_metadata_is_not_claimed_to_exist(self):
        for name in ["meeting", "lifelog", "intermediate"]:
            with self.subTest(name=name):
                prompt = self.cases[name]["messages"][-1]["content"]
                self.assertEqual(self.contract["requests"][name]["format"], "legacy_text")
                self.assertNotIn('"schemaVersion"', prompt)
                self.assertNotIn('"meeting"', prompt)
        partial = self.cases["intermediate"]["messages"][-1]["content"]
        self.assertIn(self.contract["requests"]["intermediate"]["marker"], partial)
        self.assertEqual(self.contract["requests"]["intermediate"]["phase"], "partial")
        self.assertTrue(self.contract["requests"]["meeting"]["acceptMissingMetadata"])
        self.assertTrue(self.contract["requests"]["lifelog"]["acceptMissingMetadata"])

    def test_chat_history_is_not_a_phone_database_sync(self):
        messages = self.cases["chat"]["messages"]
        self.assertEqual([m["role"] for m in messages], ["system", "user", "assistant", "user"])
        self.assertFalse(self.contract["requests"]["chat"]["includesPhoneDatabase"])
        self.assertTrue(self.contract["boundaries"]["serverArchiveApi"])
        self.assertTrue(self.contract["boundaries"]["notificationAutoUpload"])
        for key in ("automaticMemoryWrites", "asrManagedByInstaller", "bluetoothManagedByInstaller", "appChangesRequiredToAcceptCurrentRequests"):
            self.assertFalse(self.contract["boundaries"][key])

    def test_all_installed_skills_link_the_same_packaged_contract(self):
        contracts = set()
        for name in installer.SKILLS:
            base = SOURCE / "skills" / name
            self.assertIn("references/data-contract.md", (base / "SKILL.md").read_text())
            contracts.add((base / "references/data-contract.md").read_bytes())
        self.assertEqual(len(contracts), 1)

    def test_archive_requests_use_references_not_repeated_bodies(self):
        fixture = json.loads((SOURCE / 'tests/fixtures/archive-app-requests.json').read_text())
        source = SOURCE.parent / 'sunmate_app/lib/core/ai/agent_client.dart'
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), fixture['agentSourceSha256'])
        self.assertFalse(fixture['unreleasedSource'])
        self.assertEqual(fixture['appVersion'], self.contract['appVersion'])
        cases = {row['case']:row['request'] for row in fixture['cases']}
        for task in ('meeting','lifelog','notification'):
            text = cases['reference_' + task]['messages'][-1]['content']
            request = json.loads(text[text.index('{"schemaVersion"'):])
            self.assertEqual(request['schemaVersion'], 'sunmate.reference.v1')
            self.assertEqual(request['archive']['libraryId'], 'fixture-library')
            self.assertEqual(request['task'], task)
            self.assertIn('from', request)
            self.assertEqual(set(request['archive']['records'][0]), {'id','sha'})
            self.assertNotIn('合成通知正文', text)
            self.assertIn('nextTextOffset', text)
        context = cases['archive_chat']['messages'][0]['content']
        self.assertIn('sunmate_search/get', context)
        self.assertIn('fixture-library', context)

    def test_default_installer_and_optional_archive_are_separate(self):
        archive = self.contract['archive']
        self.assertTrue(archive['implementedLocally'])
        self.assertFalse(archive['defaultInstalled'])
        self.assertFalse(archive['deployed'])
        self.assertFalse(archive['rawAudioUpload'])
        audio = self.contract['audio']
        self.assertTrue(audio['rawAudioUpload'])
        self.assertFalse(audio['uploadDefault'])
        self.assertFalse(audio['serverProcessingDefault'])
        self.assertFalse(audio['cardOriginalsDeleted'])
        self.assertEqual(audio['resultDelivery'], 'foreground_cursor_pull')

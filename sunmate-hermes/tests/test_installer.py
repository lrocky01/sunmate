import contextlib
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("sunmate_installer", SOURCE / "installer.py")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sunmate-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "hermes-home"
        self.home.mkdir()
        (self.home / ".env").write_text("API_SERVER_KEY=fixture-key-for-offline-tests\n", encoding="utf-8")

    def args(self, **kwargs):
        values = dict(hermes_home=str(self.home), profile=None)
        values.update(kwargs)
        return type("Args", (), values)()

    def install(self, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            installer.install_skills(self.home, SOURCE, **kwargs)

    def fake_hermes(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir(exist_ok=True)
        hermes = bin_dir / "hermes"
        hermes.write_text('#!/bin/sh\n[ "$1" = "--version" ] && exit 0\nexit 2\n')
        hermes.chmod(0o755)
        return bin_dir

    def test_complete_source_integrity(self):
        installer.verify_source(SOURCE)

    def test_corrupt_source_is_rejected(self):
        copy = self.root / "source"
        shutil.copytree(SOURCE, copy)
        (copy / "skills" / installer.SKILLS[0] / "SKILL.md").write_text("truncated")
        with self.assertRaises(installer.InstallError):
            installer.verify_source(copy)

    def test_unlisted_file_is_rejected(self):
        copy = self.root / "source"
        shutil.copytree(SOURCE, copy)
        (copy / "skills" / "unlisted.py").write_text("unexpected")
        with self.assertRaises(installer.InstallError):
            installer.verify_source(copy)

    def test_install_is_idempotent(self):
        self.install()
        marker = self.home / "skills/sunmate/.sunmate-managed"
        old_stat = marker.stat().st_mtime_ns
        self.install()
        self.assertEqual(marker.stat().st_mtime_ns, old_stat)
        self.assertFalse((self.home / "sunmate-backups").exists())
        self.assertEqual(len(list((self.home / "skills/sunmate").glob("*/SKILL.md"))), 5)

    def test_modified_skill_is_preserved(self):
        self.install()
        file = self.home / "skills/sunmate" / installer.SKILLS[0] / "SKILL.md"
        file.write_text("user content")
        with self.assertRaises(installer.InstallError):
            self.install()
        self.assertEqual(file.read_text(), "user content")

    def test_explicit_replacement_backs_up_outside_skills(self):
        self.install()
        relative = installer.SKILLS[0] + "/SKILL.md"
        (self.home / "skills/sunmate" / relative).write_text("user content")
        self.install(replace_modified=True)
        backups = list((self.home / "sunmate-backups").iterdir())
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / relative).read_text(), "user content")
        self.assertNotEqual((self.home / "skills/sunmate" / relative).read_text(), "user content")
        self.assertFalse(list((self.home / "skills").glob("*.bak*")))

    def test_unmanaged_directory_never_overwritten(self):
        target = self.home / "skills/sunmate"
        target.mkdir(parents=True)
        (target / "notes").write_text("keep")
        with self.assertRaises(installer.InstallError):
            self.install(replace_modified=True)
        self.assertEqual((target / "notes").read_text(), "keep")

    def test_old_root_skills_never_overwritten(self):
        old = self.home / "skills" / installer.SKILLS[0]
        old.mkdir(parents=True)
        (old / "SKILL.md").write_text("old content")
        with self.assertRaises(installer.InstallError):
            self.install()
        self.assertEqual((old / "SKILL.md").read_text(), "old content")
        self.assertFalse((self.home / "skills/sunmate").exists())

    def test_root_conflict_is_detected_on_rerun(self):
        self.install()
        (self.home / "skills" / installer.SKILLS[0]).mkdir()
        with self.assertRaises(installer.InstallError):
            self.install()

    def test_failed_swap_restores_existing_version(self):
        self.install()
        file = self.home / "skills/sunmate" / installer.SKILLS[0] / "SKILL.md"
        file.write_text("user content")
        original_rename = Path.rename
        def fail_staged(path, target):
            if path.parent.name.startswith(".sunmate-stage-"):
                raise OSError("simulated filesystem failure")
            return original_rename(path, target)
        with patch.object(Path, "rename", fail_staged), self.assertRaises(OSError):
            self.install(replace_modified=True)
        self.assertEqual(file.read_text(), "user content")
        self.assertFalse(list(self.home.glob(".sunmate-stage-*")))

    def test_symlink_target_rejected(self):
        (self.home / "skills").symlink_to(self.root / "somewhere")
        with self.assertRaises(installer.InstallError):
            self.install()

    def test_lock_excludes_concurrent_install_and_is_released(self):
        with installer.install_lock(self.home):
            with self.assertRaises(installer.InstallError):
                with installer.install_lock(self.home):
                    pass
        self.assertFalse((self.home / ".sunmate-install.lock").exists())

    def test_profiles_require_explicit_selection(self):
        (self.home / "profiles/work").mkdir(parents=True)
        (self.home / "profiles/work/.env").write_text("fixture")
        with patch.dict(os.environ, {}, clear=True), patch.object(Path, "home", return_value=self.root):
            standard = self.root / ".hermes"
            self.home.rename(standard)
            with self.assertRaises(installer.InstallError):
                installer.select_home(self.args(hermes_home=None))
            self.assertEqual(installer.select_home(self.args(hermes_home=str(standard), profile="work")), (standard / "profiles/work").resolve())

    def test_sticky_profile_is_respected(self):
        (self.home / "profiles/work").mkdir(parents=True)
        (self.home / "profiles/work/.env").write_text("fixture")
        (self.home / "active_profile").write_text("work\n")
        standard = self.root / ".hermes"
        self.home.rename(standard)
        with patch.dict(os.environ, {}, clear=True), patch.object(Path, "home", return_value=self.root):
            self.assertEqual(installer.select_home(self.args(hermes_home=None)), (standard / "profiles/work").resolve())

    def test_explicit_profile_home_is_not_nested_twice(self):
        home = self.home / "profiles/work"
        home.mkdir(parents=True)
        (home / ".env").write_text("fixture")
        selected = installer.select_home(self.args(hermes_home=str(home), profile="work"))
        self.assertEqual(selected, home.resolve())

    def test_custom_port_and_inherited_environment(self):
        (self.home / ".env").write_text("API_SERVER_ENABLED=true\nAPI_SERVER_PORT=9721\nAPI_SERVER_KEY=fixture-key-for-offline-tests\n")
        with patch.object(installer, "read_yaml", return_value={}), patch.dict(os.environ, {}, clear=True):
            settings = installer.native_settings(self.home, "unused")
            self.assertEqual(settings["url"], "http://127.0.0.1:9721/v1")
        with patch.object(installer, "read_yaml", return_value={}), patch.dict(os.environ, {"API_SERVER_PORT": "9732"}, clear=True):
            self.assertIn(":9732/", installer.native_settings(self.home, "unused")["url"])

    def test_yaml_profile_and_ipv6(self):
        config = {"gateway": {"platforms": {"api_server": {"enabled": True, "extra": {"port": 9743, "host": "::"}}}}}
        with patch.object(installer, "read_yaml", return_value=config), patch.dict(os.environ, {}, clear=True):
            self.assertEqual(installer.native_settings(self.home, "unused")["url"], "http://[::1]:9743/v1")

    def test_dotenv_does_not_execute_shell(self):
        sentinel = self.root / "sentinel"
        (self.home / ".env").write_text(f'API_SERVER_KEY="$(touch {sentinel})"\n')
        with self.assertRaises(installer.InstallError):
            installer.read_api_env(self.home / ".env")
        self.assertFalse(sentinel.exists())

    def test_missing_key_and_disabled_service_fail(self):
        for content in ("API_SERVER_ENABLED=true\n", "API_SERVER_ENABLED=false\nAPI_SERVER_KEY=fixture-key-for-offline-tests\n"):
            (self.home / ".env").write_text(content)
            with patch.object(installer, "read_yaml", return_value={}), patch.dict(os.environ, {}, clear=True):
                with self.assertRaises(installer.InstallError):
                    installer.native_settings(self.home, "unused")

    def test_url_rejects_plaintext_remote_and_credentials(self):
        for url in ("http://192.0.2.1:8642/v1", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com", "https://[invalid/v1", "https://example.com:wrong/v1", "https://example.com/\nv1"):
            with self.assertRaises(installer.InstallError):
                installer.normalize_url(url)
        self.assertEqual(installer.normalize_url("https://example.com/p/work/v1/"), ("https://example.com/p/work/v1", False))

    def test_restart_is_never_implicit(self):
        calls = []
        binary = str(self.fake_hermes() / "hermes")
        with patch.dict(os.environ, {}, clear=True), patch.object(shutil, "which", return_value=binary), patch.object(installer, "run_hermes", side_effect=lambda *a, **kw: calls.append(a)), contextlib.redirect_stdout(io.StringIO()):
            installer.main(["--hermes-home", str(self.home), "--skills-only"])
        self.assertEqual(calls, [(binary, ["--version"])])

    def test_check_mode_installs_nothing(self):
        binary = str(self.fake_hermes() / "hermes")
        settings = {"url": "http://127.0.0.1:8642/v1", "key": "fixture-key-for-offline-tests", "host": "127.0.0.1"}
        output = io.StringIO()
        with patch.object(shutil, "which", return_value=binary), patch.object(installer, "native_settings", return_value=settings), patch.object(installer, "check_api", return_value="fixture-model"), contextlib.redirect_stdout(output):
            installer.main(["--hermes-home", str(self.home), "--check"])
        self.assertFalse((self.home / "skills").exists())
        self.assertFalse((self.home / ".sunmate-install.lock").exists())
        self.assertNotIn(settings["key"], output.getvalue())
        self.assertIn("手机可访问端点尚未配置", output.getvalue())

    def test_explicit_restart_delegates_only_to_native_gateway(self):
        binary = str(self.fake_hermes() / "hermes")
        with patch.object(shutil, "which", return_value=binary), patch.object(installer, "run_hermes") as command, contextlib.redirect_stdout(io.StringIO()):
            installer.main(["--hermes-home", str(self.home), "--skills-only", "--restart-native"])
        self.assertEqual(command.call_args_list[0].args, (binary, ["--version"]))
        self.assertEqual(command.call_args_list[1].args, (binary, ["gateway", "restart"]))
        self.assertEqual(command.call_args_list[1].kwargs["home"], self.home.resolve())

    def test_preflight_failure_installs_nothing(self):
        binary = str(self.fake_hermes() / "hermes")
        settings = {"url": "http://127.0.0.1:8642/v1", "key": "fixture-key-for-offline-tests", "host": "127.0.0.1"}
        with patch.object(shutil, "which", return_value=binary), patch.object(installer, "native_settings", return_value=settings), patch.object(installer, "check_api", side_effect=installer.InstallError("auth failed")), self.assertRaises(installer.InstallError):
            installer.main(["--hermes-home", str(self.home)])
        self.assertFalse((self.home / "skills").exists())
        self.assertFalse((self.home / ".sunmate-install.lock").exists())

    def test_missing_hermes_makes_no_target_directory(self):
        absent = self.root / "not-created"
        with patch.object(shutil, "which", return_value=None):
            with self.assertRaises(installer.InstallError):
                installer.main(["--hermes-home", str(absent), "--skills-only"])
        self.assertFalse(absent.exists())

    def test_wrapper_and_local_script_work_from_other_cwd(self):
        env = {**os.environ, "PATH": str(self.fake_hermes()) + os.pathsep + os.environ["PATH"], "SUNMATE_PYTHON": sys.executable}
        for name in ("setup_hermes.sh", "install_to_hermes.sh"):
            result = subprocess.run(["bash", str(SOURCE / name), "--hermes-home", str(self.home), "--skills-only"], cwd=self.root, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("fixture-key-for-offline-tests", result.stdout + result.stderr)

    def test_pipe_bootstrap_downloads_complete_pinned_package(self):
        modules = self.root / "bootstrap-modules"
        modules.mkdir()
        log = self.root / "downloads.jsonl"
        # Replace network at the Python transport boundary. The actual Bash
        # stdin entry and child installer execute against a disposable home.
        (modules / "sitecustomize.py").write_text('''
import io, json, os
from pathlib import Path
import urllib.request
def fixture_urlopen(request, timeout=None):
    url = request.full_url
    with open(os.environ['FIXTURE_LOG'], 'a') as f:
        f.write(json.dumps(url) + '\\n')
    if url.endswith('/commits/main'):
        return io.BytesIO(json.dumps({'sha': 'a' * 40}).encode())
    prefix = 'https://raw.githubusercontent.com/lrocky01/sunmate/' + 'a' * 40 + '/sunmate-hermes/'
    if not url.startswith(prefix):
        raise AssertionError('unexpected download URL')
    return io.BytesIO((Path(os.environ['FIXTURE_SOURCE']) / url[len(prefix):]).read_bytes())
urllib.request.urlopen = fixture_urlopen
''')
        env = {**os.environ, "PATH": str(self.fake_hermes()) + os.pathsep + os.environ["PATH"], "SUNMATE_PYTHON": sys.executable, "PYTHONPATH": str(modules), "FIXTURE_SOURCE": str(SOURCE), "FIXTURE_LOG": str(log)}
        env.pop("SUNMATE_REF", None)
        result = subprocess.run(["bash", "-s", "--", "--hermes-home", str(self.home), "--skills-only"], input=(SOURCE / "setup_hermes.sh").read_text(), cwd=self.root, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        urls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(sum(url.endswith("/commits/main") for url in urls), 1)
        self.assertTrue(all("/" + "a" * 40 + "/" in url for url in urls if not url.endswith("/commits/main")))
        self.assertEqual(len(list((self.home / "skills/sunmate").glob("*/references/data-contract.md"))), 5)

        # Tamper a downloaded source file without changing its declared digest.
        corrupted = self.root / "corrupted-package"
        shutil.copytree(SOURCE, corrupted)
        (corrupted / "installer.py").write_text("raise SystemExit(99)")
        untouched = self.root / "untouched-home"
        untouched.mkdir()
        (untouched / ".env").write_text("fixture")
        env["FIXTURE_SOURCE"] = str(corrupted)
        result = subprocess.run(["bash", "-s", "--", "--hermes-home", str(untouched), "--skills-only"], input=(SOURCE / "setup_hermes.sh").read_text(), cwd=self.root, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("完整性校验失败", result.stderr)
        self.assertFalse((untouched / "skills").exists())


class APITests(unittest.TestCase):
    def setUp(self):
        self.key = "fixture-key-for-offline-tests"
        self.mode = "ok"
        self.requests = []
        test = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass
            def respond(self, status, body):
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(body).encode())
            def do_GET(self):
                test.requests.append(("GET", self.path, self.headers.get("Authorization")))
                if self.headers.get("Authorization") != "Bearer " + test.key and test.mode != "open":
                    self.respond(401, {"error": "unauthorized"})
                elif test.mode == "redirect":
                    self.send_response(302)
                    self.send_header("Location", "/stolen")
                    self.end_headers()
                elif self.path.endswith("/skills"):
                    self.respond(200, {"skills": [{"name": name} for name in installer.SKILLS]})
                else:
                    self.respond(200, {"data": [{"id": "profile-model"}]})
            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                test.requests.append(("POST", self.path, self.headers.get("Authorization")))
                text = payload["messages"][0]["content"].split("：")[-1]
                if test.mode == "mock":
                    text = "已完成记忆关联"
                if test.mode == "empty":
                    text = ""
                self.respond(200, {"choices": [{"message": {"content": text}, "finish_reason": "error" if test.mode == "error" else "stop"}]})
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = f"http://127.0.0.1:{self.server.server_port}/v1"

    def test_real_protocol_probe_and_secret_redaction(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(installer.check_api(self.url, self.key, 5), "profile-model")
        self.assertEqual(len([r for r in self.requests if r[0] == "POST"]), 1)
        self.assertNotIn(self.key, output.getvalue())

    def test_invalid_token_is_failure_without_inference(self):
        with self.assertRaises(installer.InstallError):
            installer.check_api(self.url, "wrong-key", 5)
        self.assertFalse(any(r[0] == "POST" for r in self.requests))

    def test_authentication_bypass_is_failure(self):
        self.mode = "open"
        with self.assertRaises(installer.InstallError):
            installer.check_api(self.url, self.key, 5)
        self.assertEqual(len(self.requests), 1)

    def test_templates_empty_and_http200_errors_fail(self):
        for self.mode in ("mock", "empty", "error"):
            with self.subTest(mode=self.mode), self.assertRaises(installer.InstallError):
                installer.check_api(self.url, self.key, 5)

    def test_redirect_does_not_forward_key(self):
        self.mode = "redirect"
        status, _ = installer.api_request(self.url, "/models", self.key)
        self.assertEqual(status, 302)
        self.assertEqual(len(self.requests), 1)
        self.assertNotIn("/stolen", [r[1] for r in self.requests])

    def test_connection_failure_does_not_leak_key(self):
        self.server.shutdown()
        self.server.server_close()
        with self.assertRaises(installer.InstallError) as raised:
            installer.api_request(self.url, "/models", self.key, timeout=1)
        self.assertNotIn(self.key, str(raised.exception))

    def test_full_install_with_auth_inference_and_discovery(self):
        with tempfile.TemporaryDirectory(prefix="sunmate-full-install-") as directory:
            root = Path(directory)
            home = root / "home"
            home.mkdir()
            (home / ".env").write_text(f"API_SERVER_KEY={self.key}\nAPI_SERVER_PORT={self.server.server_port}\n")
            binary = root / "hermes"
            binary.write_text('#!/bin/sh\n[ "$1" = "--version" ] && exit 0\nexit 2\n')
            binary.chmod(0o755)
            output = io.StringIO()
            with patch.dict(os.environ, {}, clear=True), patch.object(shutil, "which", return_value=str(binary)), contextlib.redirect_stdout(output):
                installer.main(["--hermes-home", str(home), "--timeout", "5"])
            self.assertEqual(len(list((home / "skills/sunmate").glob("*/SKILL.md"))), 5)
            self.assertTrue(any(row[1] == "/v1/skills" for row in self.requests))
            self.assertNotIn(self.key, output.getvalue())
            self.assertIn("已发现全部五个", output.getvalue())
            self.assertFalse((home / ".sunmate-install.lock").exists())


if __name__ == "__main__":
    unittest.main()

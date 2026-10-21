"""Offline/loopback checks; no real Hermes profile, credentials or model."""
import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import threading
import unittest
from unittest.mock import patch
import zipfile

from test_installer import installer, SOURCE


def frame(value, event=None):
    return (("event: " + event + "\r\n") if event else "") + "data: " + json.dumps(value, ensure_ascii=False) + "\r\n\r\n"


def content(value, reason=None):
    return {"choices": [{"index": 0, "delta": {"content": value}, "finish_reason": reason}]}


def turn(challenge):
    return (frame(content("先检查一下。")) +
        frame({"toolCallId": "fixture-call", "status": "running"}, "hermes.tool.progress") +
        frame({"choices": [{"index": 0, "delta": {"tool_calls": [{"id": "fixture-call"}]}, "finish_reason": "tool_calls"}]}) +
        frame({"toolCallId": "fixture-call", "status": "completed"}, "hermes.tool.progress") +
        frame(content(challenge)) + frame(content(None, "stop")) + "data: [DONE]\r\n\r\n")


class SSETests(unittest.TestCase):
    def test_progress_preamble_and_complete_final_response(self):
        self.assertEqual(installer.validate_sse(turn("fixture-result").splitlines(), "fixture-result"), {"tool_progress_events": 2})

    def test_first_done_without_final_or_stop_is_rejected(self):
        for stream in [frame(content("前置说明")), frame(content("fixture-result"))]:
            with self.subTest(stream=stream), self.assertRaises(installer.InstallError):
                installer.validate_sse((stream + "data: [DONE]\n\n").splitlines(), "fixture-result")

    def test_stop_without_done_and_done_without_blank_boundary_fail(self):
        for tail in ["", "data: [DONE]"]:
            with self.subTest(tail=tail), self.assertRaises(installer.InstallError):
                installer.validate_sse((frame(content("fixture-result", "stop")) + tail).splitlines(), "fixture-result")

    def test_error_cancelled_invalid_json_and_invalid_frames_fail_safely(self):
        cases = [frame({"error": "fixture sensitive response"}),
            frame({}, "error"), frame(content("fixture-result", "cancelled")),
            frame(content("fixture-result", "length")), "data: {invalid\n\n", frame([]),
            frame({"choices": [{"delta": {"content": 42}}]}),
            frame(content("fixture-result", "stop")) + frame(content("late content"))]
        for stream in cases:
            with self.subTest(stream=stream), self.assertRaises(installer.InstallError) as raised:
                installer.validate_sse((stream + "data: [DONE]\n\n").splitlines(), "fixture-result")
            self.assertNotIn("fixture sensitive response", str(raised.exception))

    def test_comments_multiline_data_and_usage_do_not_become_reply(self):
        stream = ': heartbeat\n\nevent: message\ndata: {"choices":\ndata: [{"delta":{"content":"fixture-result"},"finish_reason":"stop"}]}\n\n'
        stream += frame({"choices": [], "usage": {"total_tokens": 1}}) + 'data: [DONE]\n\n'
        self.assertEqual(installer.validate_sse(stream.splitlines(), "fixture-result"), {"tool_progress_events": 0})

    def test_hermes_incomplete_flags_override_stop_and_done(self):
        for flags in [{"completed": False}, {"partial": True}, {"failed": True}]:
            with self.subTest(flags=flags), self.assertRaises(installer.InstallError):
                value = {**content("fixture-result", "stop"), "hermes": flags}
                installer.validate_sse((frame(value) + "data: [DONE]\n\n").splitlines(), "fixture-result")

    def test_status_is_not_content_and_approval_is_not_automatically_accepted(self):
        stream = frame({"status": "waiting"}, "hermes.status") + turn("fixture-result")
        self.assertEqual(installer.validate_sse(stream.splitlines(), "fixture-result"), {"tool_progress_events": 2})
        with self.assertRaises(installer.InstallError):
            installer.validate_sse(frame({"id": "synthetic-approval"}, "approval.request").splitlines(), "fixture-result")


class StreamHTTPTests(unittest.TestCase):
    def setUp(self):
        self.mode, self.requests = "ok", []
        self.key = "fixture-stream-key-only"
        test = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass
            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                test.requests.append((self.path, self.headers.get("Authorization"), payload))
                if test.mode == "redirect":
                    self.send_response(302)
                    self.send_header("Location", "/stolen")
                    self.end_headers()
                    return
                if self.headers.get("Authorization") != "Bearer " + test.key:
                    self.send_response(401)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/json" if test.mode == "json" else "text/event-stream; charset=utf-8")
                self.end_headers()
                challenge = payload["messages"][0]["content"].split("：")[-1]
                response = turn(challenge).encode()
                if test.mode == "early":
                    response = (frame(content("只说前置说明")) + "data: [DONE]\n\n").encode()
                elif test.mode == "truncated":
                    response = frame(content(challenge, "stop")).encode()
                elif test.mode == "invalid_utf8":
                    response = b"data: \xff\n\n"
                elif test.mode == "oversize":
                    response = b":" + b"x" * (installer.MAX_RESPONSE + 1)
                # Split UTF-8/CRLF and JSON arbitrarily at the transport boundary.
                try:
                    size = 4096 if test.mode == "oversize" else 11
                    for i in range(0, len(response), size):
                        self.wfile.write(response[i:i + size])
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = f"http://127.0.0.1:{self.server.server_port}/p/fixture/v1"

    def test_real_http_sse_keeps_profile_prefix_and_redacts_output(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(installer.check_stream(self.url, self.key, "fixture-model", 5), {"tool_progress_events": 2})
        self.assertEqual(len(self.requests), 1)
        path, auth, payload = self.requests[0]
        self.assertEqual(path, "/p/fixture/v1/chat/completions")
        self.assertEqual(auth, "Bearer " + self.key)
        self.assertTrue(payload["stream"])
        self.assertEqual(payload["model"], "fixture-model")
        self.assertNotIn(self.key, output.getvalue())
        self.assertNotIn(payload["messages"][0]["content"].split("：")[-1], output.getvalue())

    def test_failures_never_retry_or_leak_credentials(self):
        for mode in ["redirect", "early", "truncated", "invalid_utf8", "oversize", "json"]:
            self.mode = mode
            self.requests.clear()
            with self.subTest(mode=mode), contextlib.redirect_stdout(io.StringIO()), self.assertRaises(installer.InstallError) as raised:
                installer.check_stream(self.url, self.key, "fixture-model", 5)
            self.assertEqual(len(self.requests), 1)
            self.assertNotIn("/stolen", [r[0] for r in self.requests])
            self.assertNotIn(self.key, str(raised.exception))


class ReleaseTests(unittest.TestCase):
    def test_check_stream_is_explicit_read_only_and_not_retried(self):
        with tempfile.TemporaryDirectory(prefix="sm-check-stream-test-") as tmp:
            home = Path(tmp)
            (home / "config.yaml").write_text("{}")
            settings = {"url": "http://127.0.0.1:8642/v1", "key": "fixture-only-key"}
            with patch.object(installer.shutil, "which", return_value="fixture-hermes"), \
                 patch.object(installer, "run_hermes"), \
                 patch.object(installer, "native_settings", return_value=settings), \
                 patch.object(installer, "check_api", return_value="fixture-model"), \
                 patch.object(installer, "check_stream") as stream, \
                 patch.object(installer, "install_skills") as install, \
                 contextlib.redirect_stdout(io.StringIO()):
                installer.main(["--check", "--hermes-home", str(home)])
                stream.assert_not_called()
                installer.main(["--check", "--check-stream", "--hermes-home", str(home), "--timeout", "5"])
                stream.assert_called_once_with(settings["url"], settings["key"], "fixture-model", 5)
                install.assert_not_called()
                self.assertFalse((home / "skills").exists())

    def test_failed_stream_preflight_does_not_install_files(self):
        with tempfile.TemporaryDirectory(prefix="sm-stream-preflight-") as tmp:
            home = Path(tmp)
            (home / "config.yaml").write_text("{}")
            settings = {"url": "http://127.0.0.1:8642/v1", "key": "fixture-only-key"}
            with patch.object(installer.shutil, "which", return_value="fixture-hermes"), \
                 patch.object(installer, "run_hermes"), \
                 patch.object(installer, "native_settings", return_value=settings), \
                 patch.object(installer, "check_api", return_value="fixture-model"), \
                 patch.object(installer, "check_stream", side_effect=installer.InstallError("synthetic failure")) as stream, \
                 patch.object(installer, "install_skills") as install, \
                 contextlib.redirect_stdout(io.StringIO()), self.assertRaises(installer.InstallError):
                installer.main(["--check-stream", "--hermes-home", str(home), "--timeout", "5"])
            stream.assert_called_once()
            install.assert_not_called()
            self.assertFalse((home / "skills").exists())
            self.assertFalse((home / ".sunmate-install.lock").exists())

    def test_stream_is_opt_in_and_skills_only_conflict_fails_before_host_access(self):
        self.assertFalse(installer.parser().parse_args([]).check_stream)
        with patch.object(installer.shutil, "which", side_effect=AssertionError("must not access host")), self.assertRaises(installer.InstallError):
            installer.main(["--skills-only", "--check-stream"])

    def test_existing_20_archive_upgrades_with_backup(self):
        old_zip = SOURCE.parent / "build_output/hermes-release/sunmate-hermes-2.0.0.zip"
        with tempfile.TemporaryDirectory(prefix="sm-old-package-test-") as tmp:
            root = Path(tmp)
            with zipfile.ZipFile(old_zip) as z:
                for name in z.namelist():
                    self.assertFalse(Path(name).is_absolute())
                    self.assertNotIn("..", Path(name).parts)
                z.extractall(root)
            old_source = root / "sunmate-hermes"
            spec = importlib.util.spec_from_file_location("old_sunmate_installer", old_source / "installer.py")
            old = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(old)
            old.verify_source(old_source)
            home = root / "home"
            home.mkdir()
            with contextlib.redirect_stdout(io.StringIO()):
                old.install_skills(home, old_source)
                installer.install_skills(home, SOURCE)
            backups = list((home / "sunmate-backups").iterdir())
            self.assertEqual(len(backups), 1)
            previous = json.loads((backups[0] / ".sunmate-managed").read_text())
            current = json.loads((home / "skills/sunmate/.sunmate-managed").read_text())
            self.assertEqual(previous["version"], "2.0.0")
            self.assertEqual(current["version"], installer.VERSION)
            self.assertEqual((backups[0] / "notification-digest/SKILL.md").read_bytes(), (old_source / "skills/notification-digest/SKILL.md").read_bytes())

    def test_new_packages_match_manifest_and_preserve_old_artifacts(self):
        spec = importlib.util.spec_from_file_location("package_release", SOURCE / "package_release.py")
        package = importlib.util.module_from_spec(spec)
        # The packaging module shares the already inspected installer constants.
        import sys
        with patch.dict(sys.modules, {"installer": installer}):
            spec.loader.exec_module(package)
        with tempfile.TemporaryDirectory(prefix="sm-package-test-") as tmp:
            root = Path(tmp)
            source = root / "sunmate-hermes"
            shutil.copytree(SOURCE, source, ignore=shutil.ignore_patterns("__pycache__"))
            output = root / "build_output/hermes-release"
            output.mkdir(parents=True)
            old = {name: b"synthetic old archive retained" for name in ["sunmate-hermes-2.0.0.zip", "sunmate-hermes-2.0.0.tar.gz", "SHA256SUMS"]}
            for name, data in old.items():
                (output / name).write_bytes(data)
            with patch.object(package, "ROOT", source), contextlib.redirect_stdout(io.StringIO()):
                package.main()
            for name, data in old.items():
                self.assertEqual((output / name).read_bytes(), data)
            manifest = installer.verify_source(source)
            with zipfile.ZipFile(output / f"sunmate-hermes-{installer.VERSION}.zip") as z:
                self.assertIsNone(z.testzip())
                for name, digest in manifest["files"].items():
                    self.assertEqual(hashlib.sha256(z.read("sunmate-hermes/" + name)).hexdigest(), digest)
            with tarfile.open(output / f"sunmate-hermes-{installer.VERSION}.tar.gz") as t:
                for name, digest in manifest["files"].items():
                    self.assertEqual(hashlib.sha256(t.extractfile("sunmate-hermes/" + name).read()).hexdigest(), digest)
            for line in (output / f"SHA256SUMS-{installer.VERSION}").read_text().splitlines():
                digest, name = line.split()
                self.assertEqual(hashlib.sha256((output / name).read_bytes()).hexdigest(), digest)

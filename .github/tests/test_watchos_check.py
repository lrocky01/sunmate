"""Offline workflow/command checks. Does not compile an Apple platform target."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".github/scripts/check_watchos.sh"
WORKFLOW = ROOT / ".github/workflows/check_watchos.yml"


class WatchCompileCheck(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sunmate-watch-ci-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        developer = self.base / "Xcode_27.2.app/Contents/Developer"
        binary = developer / "usr/bin/xcodebuild"
        binary.parent.mkdir(parents=True)
        self.sdk = developer / "Platforms/WatchOS.platform/Developer/SDKs/WatchOS27.2.sdk"
        self.sdk.mkdir(parents=True)
        self.calls = self.base / "invocations.jsonl"
        binary.write_text("#!" + sys.executable + '''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["FAKE_CALLS"], "a") as f:
    f.write(json.dumps(args) + "\\n")
if args == ["-version"]:
    print("Xcode " + os.environ.get("FAKE_VERSION", "27.2"))
    print("Build version synthetic")
elif args == ["-version", "-sdk", "watchos27.2", "SDKVersion"]:
    print(os.environ.get("FAKE_SDK_VERSION", "27.2"))
elif args == ["-version", "-sdk", "watchos27.2", "Path"]:
    print(os.environ["FAKE_SDK_PATH"])
elif args[-1:] == ["build"]:
    print("synthetic compiler log", flush=True)
    sys.exit(int(os.environ.get("FAKE_BUILD_EXIT", "0")))
else:
    print("Unexpected compiler invocation", file=sys.stderr)
    sys.exit(99)
''')
        binary.chmod(0o755)
        self.env = {
            **os.environ,
            "DEVELOPER_DIR": str(developer),
            "WATCH_EXPECTED_XCODE": "27.2",
            "WATCH_SDK": "watchos27.2",
            "RUNNER_TEMP": str(self.base),
            "GITHUB_STEP_SUMMARY": str(self.base / "summary.md"),
            "FAKE_CALLS": str(self.calls),
            "FAKE_SDK_PATH": str(self.sdk),
        }

    def run_check(self, **changes):
        return subprocess.run(
            ["bash", str(SCRIPT)], env={**self.env, **changes},
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=15,
        )

    def builds(self):
        if not self.calls.exists():
            return []
        return [c for c in map(json.loads, self.calls.read_text().splitlines())
                if c[-1:] == ["build"]]

    def test_success_uses_device_sdk_disables_signing_and_keeps_only_text_logs(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout)
        args, = self.builds()
        self.assertEqual(args[args.index("-sdk") + 1], "watchos27.2")
        self.assertEqual(args[args.index("-destination") + 1], "generic/platform=watchOS")
        self.assertIn("CODE_SIGNING_ALLOWED=NO", args)
        self.assertIn("CODE_SIGNING_REQUIRED=NO", args)
        self.assertIn("CODE_SIGN_IDENTITY=", args)
        self.assertIn("DEVELOPMENT_TEAM=", args)
        self.assertIn("-disableAutomaticPackageResolution", args)
        self.assertIn("-skipPackageUpdates", args)
        self.assertNotIn("archive", args)
        self.assertNotIn("-exportArchive", args)
        self.assertNotIn("-allowProvisioningUpdates", args)
        logs = self.base / "sunmate-watch-compile-logs"
        self.assertEqual({p.name for p in logs.iterdir()}, {"check.log", "build.log", "status.log"})
        self.assertIn("synthetic compiler log", (logs / "build.log").read_text())

    def test_compiler_failure_survives_tee_and_remains_in_logs(self):
        result = self.run_check(FAKE_BUILD_EXIT="65")
        self.assertEqual(result.returncode, 65, result.stdout)
        logs = self.base / "sunmate-watch-compile-logs"
        self.assertIn("65", (logs / "status.log").read_text())
        self.assertIn("synthetic compiler log", (logs / "build.log").read_text())
        self.assertIn("`65`", (self.base / "summary.md").read_text())

    def test_missing_selected_xcode_stops_without_fallback(self):
        result = self.run_check(DEVELOPER_DIR=str(self.base / "absent"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no fallback or download", result.stdout)
        self.assertFalse(self.calls.exists())

    def test_wrong_xcode_stops_before_build(self):
        result = self.run_check(FAKE_VERSION="27.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.builds(), [])

    def test_wrong_or_absent_sdk_stops_before_build(self):
        for override in ({"FAKE_SDK_VERSION": "27.1"},
                         {"FAKE_SDK_PATH": str(self.base / "absent-sdk")}):
            with self.subTest(override=override):
                result = self.run_check(**override)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.builds(), [])

    def test_workflow_has_only_manual_trigger_and_logs_artifact(self):
        # System Ruby/Psych avoids adding any Python YAML dependency.
        result = subprocess.run([
            "ruby", "-rjson", "-ryaml", "-e",
            "puts JSON.generate(YAML.load_file(ARGV.fetch(0)))", str(WORKFLOW)
        ], check=True, text=True, stdout=subprocess.PIPE)
        workflow = json.loads(result.stdout)
        self.assertEqual(set(workflow["on"]), {"workflow_dispatch"})
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        job = workflow["jobs"]["watchos"]
        self.assertEqual(job["runs-on"], "xcode-27")
        self.assertEqual(job["env"]["WATCH_EXPECTED_XCODE"], "27.2")
        self.assertEqual(job["env"]["WATCH_SDK"], "watchos27.2")
        self.assertTrue(job["env"]["DEVELOPER_DIR"].endswith("Xcode_27.2.app/Contents/Developer"))
        self.assertEqual(len(job["steps"]), 3)
        self.assertEqual(job["steps"][0]["with"]["persist-credentials"], False)
        self.assertEqual(job["steps"][1]["run"], "bash .github/scripts/check_watchos.sh")
        logs = job["steps"][2]
        self.assertEqual(logs["if"], "always()")
        self.assertEqual(logs["with"]["path"], "${{ runner.temp }}/sunmate-watch-compile-logs/*.log")
        self.assertNotIn("secrets.", WORKFLOW.read_text())

    def test_legacy_ipa_workflow_cannot_run_on_source_push_or_tag(self):
        result = subprocess.run([
            "ruby", "-rjson", "-ryaml", "-e",
            "puts JSON.generate(YAML.load_file(ARGV.fetch(0)))",
            str(ROOT / ".github/workflows/build_ios.yml")
        ], check=True, text=True, stdout=subprocess.PIPE)
        legacy = json.loads(result.stdout)
        self.assertEqual(set(legacy["on"]), {"workflow_dispatch"})


if __name__ == "__main__":
    unittest.main()

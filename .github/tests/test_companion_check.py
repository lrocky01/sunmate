"""Local graph and verifier regressions; no Apple SDK, credentials or downloads."""
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('companion_verifier', ROOT / '.github/scripts/verify_companion.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def project(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)], text=True))


class CompanionCheck(unittest.TestCase):
    def test_runner_dependency_and_embed_reference_real_watch_product(self):
        runner = project(ROOT / 'sunmate_app/ios/Runner.xcodeproj/project.pbxproj')
        watch = project(ROOT / 'sunmate_app/apple_watch/SunMateWatch.xcodeproj/project.pbxproj')
        objects = runner['objects']
        target = objects['97C146ED1CF9000F007C117D']
        dependency = objects[target['dependencies'][0]]
        proxy = objects[dependency['targetProxy']]
        self.assertIn(proxy['remoteGlobalIDString'], watch['objects'][watch['rootObject']]['targets'])
        remote = objects[proxy['containerPortal']]
        self.assertEqual((ROOT / 'sunmate_app/ios' / remote['path']).resolve(),
                         ROOT / 'sunmate_app/apple_watch/SunMateWatch.xcodeproj')
        embed, = [objects[v] for v in target['buildPhases'] if objects[v].get('name') == 'Embed Watch Content']
        phases = [objects[v].get('name', '') for v in target['buildPhases']]
        self.assertLess(phases.index('Embed Watch Content'), phases.index('Thin Binary'))
        self.assertEqual(embed['dstPath'], '$(CONTENTS_FOLDER_PATH)/Watch')
        product = objects[objects[embed['files'][0]]['fileRef']]
        self.assertEqual(product['path'], 'SunMateWatch.app')
        product_proxy = objects[product['remoteRef']]
        self.assertEqual(product_proxy['remoteGlobalIDString'],
                         watch['objects'][proxy['remoteGlobalIDString']]['productReference'])
        # The iPhone also compiles both native bridge files and shared protocol.
        sources, = [objects[v] for v in target['buildPhases'] if objects[v]['isa'] == 'PBXSourcesBuildPhase']
        names = {objects[objects[v]['fileRef']]['path'].split('/')[-1] for v in sources['files']}
        self.assertTrue({'AppleWatchChannel.swift', 'WatchHealthReadOnly.swift',
                         'WatchRecordingStore.swift', 'WatchRecordingLink.swift'}.issubset(names))

    def test_companion_workflow_is_manual_unsigned_and_only_retains_logs(self):
        workflow = json.loads(subprocess.check_output([
            'ruby', '-rjson', '-ryaml', '-e', 'puts JSON.generate(YAML.load_file(ARGV.fetch(0)))',
            str(ROOT / '.github/workflows/check_companion.yml')], text=True))
        self.assertEqual(set(workflow['on']), {'workflow_dispatch'})
        self.assertEqual(workflow['permissions'], {'contents': 'read'})
        job = workflow['jobs']['companion']
        self.assertEqual(job['runs-on'], 'xcode-27')
        self.assertEqual(job['env']['IPHONE_SDK'], 'iphoneos27.2')
        self.assertEqual(job['env']['WATCH_SDK'], 'watchos27.2')
        artifacts = job['steps'][-1]
        self.assertEqual(artifacts['if'], 'always()')
        self.assertTrue(all(v.endswith('/*.log') for v in artifacts['with']['path'].splitlines()))
        script = (ROOT / '.github/scripts/check_companion.sh').read_text()
        self.assertIn('CODE_SIGNING_ALLOWED=NO', script)
        self.assertIn('CODE_SIGNING_REQUIRED=NO', script)
        self.assertNotIn('-allowProvisioningUpdates', script)
        self.assertNotIn('-exportArchive', script)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sunmate-companion-verify-')
        self.addCleanup(self.temp.cleanup)
        self.phone = Path(self.temp.name) / 'Runner.app'
        self.watch = self.phone / 'Watch/SunMateWatch.app'
        self.watch.mkdir(parents=True)
        self.p = {'CFBundleIdentifier': 'com.sunmate.app', 'CFBundleExecutable': 'Runner',
                  'CFBundleShortVersionString': '1.0.34', 'CFBundleVersion': '35', 'DTSDKName': 'iphoneos27.2'}
        self.w = {**self.p, 'CFBundleIdentifier': 'com.sunmate.app.watchkitapp',
                  'CFBundleExecutable': 'SunMateWatch', 'DTSDKName': 'watchos27.2',
                  'WKCompanionAppBundleIdentifier': 'com.sunmate.app', 'WKApplication': True}
        (self.phone / 'Runner').write_bytes(b'synthetic')
        (self.watch / 'SunMateWatch').write_bytes(b'synthetic')
        self.save()

    def save(self):
        for app, value in [(self.phone, self.p), (self.watch, self.w)]:
            (app / 'Info.plist').write_bytes(plistlib.dumps(value))

    def verify(self):
        # Real binary architectures are read by lipo on the cloud runner.
        with patch.object(module.subprocess, 'check_output', return_value='arm64'):
            return module.verify(self.phone, 'iphoneos27.2', 'watchos27.2')

    def test_matching_complete_unsigned_companion_is_accepted(self):
        result = self.verify()
        self.assertTrue(result['companion_embedded'])
        self.assertFalse(result['signed'])

    def test_missing_watch_is_not_reported_as_success(self):
        (self.watch / 'Info.plist').unlink()
        with self.assertRaises(FileNotFoundError):
            self.verify()

    def test_wrong_relationship_version_and_sdk_fail(self):
        for key, value in [('WKCompanionAppBundleIdentifier', 'different.app'),
                           ('CFBundleVersion', '34'), ('DTSDKName', 'iphoneos27.2')]:
            with self.subTest(key=key):
                old = self.w[key]
                self.w[key] = value
                self.save()
                with self.assertRaises(AssertionError):
                    self.verify()
                self.w[key] = old
                self.save()

    def test_signature_or_profile_is_rejected(self):
        for app in [self.phone, self.watch]:
            for name in ['embedded.mobileprovision', '_CodeSignature']:
                path = app / name
                path.touch()
                with self.assertRaises(AssertionError):
                    self.verify()
                path.unlink()


if __name__ == '__main__':
    unittest.main()

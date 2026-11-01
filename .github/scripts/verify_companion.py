"""Read-only validation of the actual companion build. No archive or signing."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess


def verify(phone, iphone_sdk, watch_sdk):
    watch = phone / 'Watch/SunMateWatch.app'
    def info(app):
        with (app / 'Info.plist').open('rb') as f:
            return plistlib.load(f)
    p, w = info(phone), info(watch)
    assert p['CFBundleIdentifier'] == 'com.sunmate.app'
    assert w['CFBundleIdentifier'] == 'com.sunmate.app.watchkitapp'
    assert w['WKCompanionAppBundleIdentifier'] == p['CFBundleIdentifier']
    assert w['WKApplication'] is True
    for key in ['CFBundleShortVersionString', 'CFBundleVersion']:
        assert p[key] == w[key], (key, p[key], w[key])
    assert p['DTSDKName'] == iphone_sdk, p['DTSDKName']
    assert w['DTSDKName'] == watch_sdk, w['DTSDKName']
    archs = {}
    for name, app, value in [('iphone', phone, p), ('watch', watch, w)]:
        assert not (app / 'embedded.mobileprovision').exists()
        assert not (app / '_CodeSignature').exists()
        binary = app / value['CFBundleExecutable']
        assert binary.is_file()
        archs[name] = subprocess.check_output(
            ['/usr/bin/lipo', '-archs', str(binary)], text=True).split()
        assert 'arm64' in archs[name], archs[name]
    return {
        'companion_embedded': True, 'bundle_relationship_valid': True,
        'version': p['CFBundleShortVersionString'], 'build': p['CFBundleVersion'],
        'iphone_sdk': p['DTSDKName'], 'watch_sdk': w['DTSDKName'],
        'architectures': archs, 'signed': False, 'ipa_generated': False,
        'scope': 'Compile and embedding only; installation and runtime not tested',
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('phone', type=Path)
    parser.add_argument('--iphone-sdk', required=True)
    parser.add_argument('--watch-sdk', required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.phone, args.iphone_sdk, args.watch_sdk), ensure_ascii=False))

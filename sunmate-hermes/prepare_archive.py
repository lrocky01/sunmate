#!/usr/bin/env python3
"""Explicit offline preparation only. Never starts services or changes Hermes config."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
from archive_runtime.service import initialize
from installer import verify_source


def prepare(home, source=None):
    home = Path(home).absolute()
    source = Path(source or Path(__file__).parent / 'archive_runtime')
    verify_source(source.parent)
    target = home / 'plugins' / 'sunmate_archive'
    if target.exists() or target.is_symlink() or home.is_symlink() or target.parent.is_symlink():
        raise ValueError('existing_plugin_preserved')
    names = ['__init__.py', 'store.py', 'service.py', 'native_api.py', 'plugin.py', 'plugin.yaml']
    if any((source / name).is_symlink() for name in names):
        raise ValueError('unsafe_source')
    target.mkdir(parents=True, mode=0o700)
    for name in names:
        shutil.copyfile(source / name, target / name)
    (target / 'sunmate-files.json').write_text(json.dumps({name: hashlib.sha256((target / name).read_bytes()).hexdigest() for name in names}))
    return target


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--hermes-home', type=Path, required=True)
    parser.add_argument('--initialize-archive', action='store_true')
    args = parser.parse_args()
    verify_source(Path(__file__).parent)
    target = args.hermes_home / 'plugins' / 'sunmate_archive'
    if target.exists() or target.is_symlink() or target.parent.is_symlink():
        raise ValueError('existing_plugin_preserved')
    profile = args.hermes_home.name if args.hermes_home.parent.name == 'profiles' else 'default'
    if args.initialize_archive:
        initialize(args.hermes_home / 'sunmate-archive', profile)
    prepare(args.hermes_home)


if __name__ == '__main__':
    main()

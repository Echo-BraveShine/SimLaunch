#!/usr/bin/env python3
"""Apply version and updater metadata without shell/XML interpolation."""
import base64
import argparse
import os
from pathlib import Path
import plistlib
import re


def read_info(path, tag=None):
    with open(path, 'rb') as stream:
        info = plistlib.load(stream)
    version = info.get('CFBundleShortVersionString', '')
    if not isinstance(version, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Info.plist CFBundleShortVersionString must be MAJOR.MINOR.PATCH')
    if tag is not None and tag != 'v' + version:
        raise ValueError(f'Release tag {tag!r} must match Info.plist version v{version}')
    return info


def configure(path, environment):
    info = read_info(path)
    version = info['CFBundleShortVersionString']
    if 'APP_VERSION' in environment and environment['APP_VERSION'] != version:
        raise ValueError('APP_VERSION must match Info.plist; edit the source Info.plist to change the version')
    build = environment.get('APP_BUILD', info.get('CFBundleVersion', ''))
    if not re.fullmatch(r'[1-9]\d*', build):
        raise ValueError('APP_BUILD must be a positive, increasing integer')
    info['CFBundleVersion'] = build
    if environment.get('SIMLAUNCH_ENABLE_SPARKLE') == '1':
        key = environment.get('SPARKLE_PUBLIC_ED_KEY', '')
        if len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError('A valid 32-byte SPARKLE_PUBLIC_ED_KEY is required')
        info.update(SUPublicEDKey=key, SUFeedURL='https://github.com/Echo-BraveShine/SimLaunch/releases/latest/download/appcast.xml', SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False)
    with open(path, 'wb') as stream:
        plistlib.dump(info, stream)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--print-version', action='store_true')
    parser.add_argument('--tag', help='Require this release tag to match the source version')
    args = parser.parse_args()
    if args.print_version:
        source = Path(__file__).resolve().parents[1] / 'Info.plist'
        print(read_info(source, args.tag)['CFBundleShortVersionString'])
    else:
        if args.tag is not None:
            parser.error('--tag requires --print-version')
        configure(Path('dist/SimLaunch.app/Contents/Info.plist'), os.environ)

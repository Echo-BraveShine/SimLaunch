#!/usr/bin/env python3
"""Apply version and updater metadata without shell/XML interpolation."""
import base64
import os
from pathlib import Path
import plistlib
import re


def configure(path, environment):
    version = environment.get('APP_VERSION', '0.1.0')
    build = environment.get('APP_BUILD', '1')
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('APP_VERSION must be MAJOR.MINOR.PATCH')
    if not re.fullmatch(r'[1-9]\d*', build):
        raise ValueError('APP_BUILD must be a positive, increasing integer')
    with open(path, 'rb') as stream:
        info = plistlib.load(stream)
    info.update(CFBundleIdentifier="dev.ekko.simlaunch", CFBundleShortVersionString=version, CFBundleVersion=build)
    if environment.get('SIMLAUNCH_ENABLE_SPARKLE') == '1':
        key = environment.get('SPARKLE_PUBLIC_ED_KEY', '')
        if len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError('A valid 32-byte SPARKLE_PUBLIC_ED_KEY is required')
        info.update(SUPublicEDKey=key, SUFeedURL='https://github.com/Echo-BraveShine/SimLaunch/releases/latest/download/appcast.xml', SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False)
    with open(path, 'wb') as stream:
        plistlib.dump(info, stream)


if __name__ == '__main__':
    configure(Path('dist/SimLaunch.app/Contents/Info.plist'), os.environ)

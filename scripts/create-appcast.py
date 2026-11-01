#!/usr/bin/env python3
"""Sign one release archive and generate a Sparkle appcast. Never print key material."""
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import os
from pathlib import Path
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET


def generate(archive, info, signature):
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Invalid Ed25519 update signature')
    namespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
    ET.register_namespace('sparkle', namespace)
    root = ET.Element('rss', version='2.0')
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'SimLaunch Updates'
    item = ET.SubElement(channel, 'item')
    version = info['CFBundleShortVersionString']
    ET.SubElement(item, 'title').text = 'SimLaunch ' + version
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f'{{{namespace}}}version').text = info['CFBundleVersion']
    ET.SubElement(item, f'{{{namespace}}}shortVersionString').text = version
    ET.SubElement(item, f'{{{namespace}}}minimumSystemVersion').text = info['LSMinimumSystemVersion']
    ET.SubElement(item, f'{{{namespace}}}releaseNotesLink').text = f'https://github.com/Echo-BraveShine/SimLaunch/releases/tag/v{version}'
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/Echo-BraveShine/SimLaunch/releases/download/v{version}/{archive.name}',
        'length': str(archive.stat().st_size), 'type': 'application/octet-stream',
        f'{{{namespace}}}edSignature': signature,
    })
    ET.indent(root)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


if __name__ == '__main__':
    with open('dist/SimLaunch.app/Contents/Info.plist', 'rb') as stream:
        info = plistlib.load(stream)
    archive = Path(f'dist/SimLaunch-{info["CFBundleShortVersionString"]}-universal.zip')
    tools = list(Path('.build/artifacts').rglob('sign_update'))
    tool = next((p for p in tools if os.access(p, os.X_OK)), None)
    if not tool:
        raise SystemExit('Sparkle sign_update tool not found')
    key = os.environ.get('SPARKLE_PRIVATE_KEY')
    if not key:
        raise SystemExit('SPARKLE_PRIVATE_KEY is required')
    result = subprocess.run([str(tool), '--ed-key-file', '-', str(archive)], input=key + '\n', text=True, capture_output=True)
    if result.returncode:
        raise SystemExit('Sparkle update signing failed; check key configuration')
    match = re.search(r'sparkle:edSignature="([^"]+)"', result.stdout)
    if not match:
        raise SystemExit('Unexpected sign_update output')
    # Verify that the signing private key matches the public key embedded in the app.
    verifier = '''import CryptoKit
import Foundation
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let signature = Data(base64Encoded: CommandLine.arguments[2])!
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: CommandLine.arguments[3])!)
guard key.isValidSignature(signature, for: archive) else { exit(1) }
'''
    subprocess.run(['swift', '-e', verifier, str(archive), match[1], info['SUPublicEDKey']], check=True)
    Path('dist/appcast.xml').write_bytes(generate(archive, info, match[1]))

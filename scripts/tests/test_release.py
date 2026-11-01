import base64
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class ReleaseTests(unittest.TestCase):
    def test_cask_uses_archive_checksum_and_bundle_metadata(self):
        generate = module('create-cask').generate
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'SimLaunch-1.2.3-universal.zip'
            info = {'CFBundleIdentifier': 'dev.ekko.simlaunch',
                    'CFBundleShortVersionString': '1.2.3',
                    'LSMinimumSystemVersion': '13.0'}
            with zipfile.ZipFile(archive, 'w') as bundle:
                bundle.writestr('SimLaunch.app/Contents/Info.plist', plistlib.dumps(info))
            cask = generate(archive)
            self.assertIn('version "1.2.3"', cask)
            self.assertIn(hashlib.sha256(archive.read_bytes()).hexdigest(), cask)
            self.assertIn('depends_on macos: :ventura', cask)
            self.assertIn('app "SimLaunch.app"', cask)
            self.assertIn('/v#{version}/SimLaunch-#{version}-universal.zip', cask)
            self.assertNotIn(':no_check', cask)
            wrong_name = archive.with_name('SimLaunch-2.0.0-universal.zip')
            archive.rename(wrong_name)
            with self.assertRaises(ValueError):
                generate(wrong_name)
            info['CFBundleShortVersionString'] = '1.2.3"; system("bad")'
            with zipfile.ZipFile(archive, 'w') as bundle:
                bundle.writestr('SimLaunch.app/Contents/Info.plist', plistlib.dumps(info))
            with self.assertRaises(ValueError):
                generate(archive)

    def test_local_bundle_has_no_updater_key(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Info.plist'
            path.write_bytes((ROOT / 'Info.plist').read_bytes())
            module('configure-bundle').configure(path, {})
            info = plistlib.loads(path.read_bytes())
            self.assertEqual(info['CFBundleIdentifier'], 'dev.ekko.simlaunch')
            source = plistlib.loads((ROOT / 'Info.plist').read_bytes())
            self.assertEqual(info['CFBundleShortVersionString'], source['CFBundleShortVersionString'])
            self.assertEqual(info['CFBundleVersion'], source['CFBundleVersion'])
            self.assertNotIn('SUPublicEDKey', info)

    def test_release_requires_key_and_versions(self):
        configure = module('configure-bundle').configure
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Info.plist'
            path.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '1'}))
            with self.assertRaises(ValueError):
                configure(path, {'SIMLAUNCH_ENABLE_SPARKLE': '1'})
            with self.assertRaises(ValueError):
                configure(path, {'APP_VERSION': 'v1.0.0'})
            key = base64.b64encode(bytes(32)).decode()
            configure(path, {'SIMLAUNCH_ENABLE_SPARKLE': '1', 'SPARKLE_PUBLIC_ED_KEY': key, 'APP_VERSION': '1.2.3', 'APP_BUILD': '42'})
            info = plistlib.loads(path.read_bytes())
            self.assertEqual(info['SUPublicEDKey'], key)
            self.assertEqual(info['CFBundleVersion'], '42')
            self.assertFalse(info['SUAutomaticallyUpdate'])
            self.assertTrue(info['SUFeedURL'].startswith('https://github.com/Echo-BraveShine/SimLaunch/'))

    def test_release_tag_must_match_source_version(self):
        read_info = module('configure-bundle').read_info
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Info.plist'
            path.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '2.3.4'}))
            self.assertEqual(read_info(path, 'v2.3.4')['CFBundleShortVersionString'], '2.3.4')
            for tag in ('v2.3.5', '2.3.4', 'v2.3.4-beta'):
                with self.assertRaises(ValueError):
                    read_info(path, tag)
            with self.assertRaises(ValueError):
                module('configure-bundle').configure(path, {'APP_VERSION': '9.9.9'})

    def test_appcast_identifies_exact_archive_and_version(self):
        generate = module('create-appcast').generate
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'SimLaunch-1.2.3-universal.zip'
            archive.write_bytes(b'release archive fixture')
            signature = base64.b64encode(bytes(64)).decode()
            info = {'CFBundleVersion': '42', 'CFBundleShortVersionString': '1.2.3', 'LSMinimumSystemVersion': '13.0'}
            root = ET.fromstring(generate(archive, info, signature))
            ns = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
            self.assertEqual(root.findtext('./channel/item/s:version', namespaces=ns), '42')
            enclosure = root.find('./channel/item/enclosure')
            self.assertEqual(int(enclosure.attrib['length']), archive.stat().st_size)
            self.assertIn('/releases/download/v1.2.3/SimLaunch-1.2.3-universal.zip', enclosure.attrib['url'])
            self.assertEqual(enclosure.attrib['{'+ns['s']+'}edSignature'], signature)
            with self.assertRaises(ValueError):
                generate(archive, info, 'not a signature')


if __name__ == '__main__':
    unittest.main()

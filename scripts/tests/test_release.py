import base64
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class ReleaseTests(unittest.TestCase):
    def test_local_bundle_has_no_updater_key(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Info.plist'
            path.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'dev.ekko.simlaunch'}))
            module('configure-bundle').configure(path, {})
            info = plistlib.loads(path.read_bytes())
            self.assertEqual(info['CFBundleIdentifier'], 'dev.ekko.simlaunch')
            self.assertEqual(info['CFBundleVersion'], '1')
            self.assertNotIn('SUPublicEDKey', info)

    def test_release_requires_key_and_versions(self):
        configure = module('configure-bundle').configure
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Info.plist'
            path.write_bytes(plistlib.dumps({}))
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

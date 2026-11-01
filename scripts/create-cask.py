"""Generate a Homebrew cask from the exact ZIP uploaded to a release."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import zipfile


def generate(archive):
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read('SimLaunch.app/Contents/Info.plist'))
    version = info['CFBundleShortVersionString']
    minimum = info['LSMinimumSystemVersion']
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Stable semantic version required')
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', minimum):
        raise ValueError('Invalid minimum macOS version')
    macos_names = {'11': 'big_sur', '12': 'monterey', '13': 'ventura',
                   '14': 'sonoma', '15': 'sequoia', '26': 'tahoe'}
    components = minimum.split('.')
    if components[0] not in macos_names or any(int(part) for part in components[1:]):
        raise ValueError('Update the Cask macOS requirement mapping for this minimum version')
    macos = macos_names[components[0]]
    if info.get('CFBundleIdentifier') != 'dev.ekko.simlaunch':
        raise ValueError('Unexpected application bundle identifier')
    if archive.name != f'SimLaunch-{version}-universal.zip':
        raise ValueError('Archive filename must match the release version')
    checksum = hashlib.sha256()
    with archive.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(chunk)
    digest = checksum.hexdigest()
    return f'''cask "simlaunch" do
  version "{version}"
  sha256 "{digest}"

  url "https://github.com/Echo-BraveShine/SimLaunch/releases/download/v#{{version}}/SimLaunch-#{{version}}-universal.zip"
  name "SimLaunch"
  desc "Manage iOS, Android, and HarmonyOS simulators from the menu bar"
  homepage "https://github.com/Echo-BraveShine/SimLaunch"

  auto_updates true
  depends_on macos: :{macos}

  app "SimLaunch.app"

  uninstall quit: "dev.ekko.simlaunch"
end
'''


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--output', type=Path, default=Path('dist/simlaunch.rb'))
    args = parser.parse_args()
    content = generate(args.archive)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(content, encoding='utf-8')

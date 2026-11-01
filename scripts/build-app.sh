#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
./scripts/build-icon.sh
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
APP="$PWD/dist/SimLaunch.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/SimLaunch" "$APP/Contents/MacOS/SimLaunch"
mkdir -p "$APP/Contents/Resources"
ditto "$BIN_DIR/SimLaunch_SimLaunchCore.bundle" "$APP/Contents/Resources/SimLaunch_SimLaunchCore.bundle"
ditto "$BIN_DIR/SimLaunch_SimLaunch.bundle" "$APP/Contents/Resources/SimLaunch_SimLaunch.bundle"
cp .build/Branding/SimLaunch.icns "$APP/Contents/Resources/SimLaunch.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SimLaunch</string>
<key>CFBundleIconFile</key><string>SimLaunch.icns</string>
<key>CFBundleIdentifier</key><string>dev.simlaunch.app</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundleName</key><string>SimLaunch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
# Notify Finder / Launch Services when rebuilding an app at the same path.
touch "$APP"
REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$REGISTER" ]]; then
    "$REGISTER" -f "$APP" >/dev/null 2>&1 || true
fi
echo "Built: $APP"

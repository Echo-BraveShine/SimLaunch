#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
./scripts/build-icon.sh
BUILD_ARGS=(-c release)
if [[ "${APP_ARCHITECTURES:-native}" == "universal" ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)
APP="$PWD/dist/SimLaunch.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/SimLaunch" "$APP/Contents/MacOS/SimLaunch"
mkdir -p "$APP/Contents/Resources"
ditto "$BIN_DIR/SimLaunch_SimLaunchCore.bundle" "$APP/Contents/Resources/SimLaunch_SimLaunchCore.bundle"
ditto "$BIN_DIR/SimLaunch_SimLaunch.bundle" "$APP/Contents/Resources/SimLaunch_SimLaunch.bundle"
cp .build/Branding/SimLaunch.icns "$APP/Contents/Resources/SimLaunch.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp Info.plist "$APP/Contents/Info.plist"
python3 scripts/configure-bundle.py
if [[ "${SIMLAUNCH_ENABLE_SPARKLE:-0}" == "1" ]]; then
    FRAMEWORK=$(find .build/artifacts -type d -name Sparkle.framework -print -quit)
    [[ -n "$FRAMEWORK" ]] || { echo "Sparkle.framework missing" >&2; exit 1; }
    mkdir -p "$APP/Contents/Frameworks"
    ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
    LICENSE_FILE=$(find .build/checkouts -maxdepth 2 -type f -iname LICENSE -ipath '*sparkle*' -print -quit)
    [[ -n "$LICENSE_FILE" ]] || { echo "Sparkle license missing" >&2; exit 1; }
    mkdir -p "$APP/Contents/Resources/ThirdPartyNotices"
    cp "$LICENSE_FILE" "$APP/Contents/Resources/ThirdPartyNotices/Sparkle-LICENSE.txt"
else
    # A local build must not retain a framework from an earlier release build.
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
fi
python3 scripts/sign-app.py
# Notify Finder / Launch Services when rebuilding an app at the same path.
touch "$APP"
REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$REGISTER" ]]; then
    "$REGISTER" -f "$APP" >/dev/null 2>&1 || true
fi
echo "Built: $APP"

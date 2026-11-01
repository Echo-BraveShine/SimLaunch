#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
ICON_SOURCE="$PWD/Sources/SimLaunch/Resources/SimLaunchIcon.png"
ICON_WORK=$(mktemp -d)
trap 'rm -rf "$ICON_WORK"' EXIT
mkdir -p "$ICON_WORK/SimLaunch.iconset" .build/Branding
for ICON_SIZE in 16 32 128 256 512; do
    sips -z "$ICON_SIZE" "$ICON_SIZE" "$ICON_SOURCE" --out "$ICON_WORK/SimLaunch.iconset/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
    ICON_DOUBLE=$((ICON_SIZE * 2))
    sips -z "$ICON_DOUBLE" "$ICON_DOUBLE" "$ICON_SOURCE" --out "$ICON_WORK/SimLaunch.iconset/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_WORK/SimLaunch.iconset" -o .build/Branding/SimLaunch.icns

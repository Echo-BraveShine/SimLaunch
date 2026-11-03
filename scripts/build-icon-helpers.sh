#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
TASK_ANDROID_SDK="${SIMLAUNCH_ANDROID_SDK:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
TASK_JAVA_HOME="${SIMLAUNCH_JAVA_HOME:-/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home}"
TASK_PLATFORM=$(python3 - "$TASK_ANDROID_SDK/platforms" <<'PY'
import pathlib,re,sys
paths=[p for p in pathlib.Path(sys.argv[1]).glob('android-*') if (p/'android.jar').exists()]
print(max(paths,key=lambda p:int(re.search(r'android-(\d+)',p.name)[1]))/'android.jar')
PY
)
TASK_D8=$(python3 - "$TASK_ANDROID_SDK/build-tools" <<'PY'
import pathlib,re,sys
paths=[p for p in pathlib.Path(sys.argv[1]).glob('*') if (p/'lib/d8.jar').exists()]
print(max(paths,key=lambda p:tuple(map(int,re.findall(r'\d+',p.name))))/'lib/d8.jar')
PY
)
TASK_BUILD=$(mktemp -d /tmp/SimLaunch-icon-build.XXXXXX)
trap 'rm -rf "$TASK_BUILD"' EXIT
TASK_RESOURCES="$PWD/Sources/SimLaunchCore/Resources/IconHelpers"
mkdir -p "$TASK_BUILD/classes" "$TASK_BUILD/dex" "$TASK_RESOURCES"
"$TASK_JAVA_HOME/bin/javac" -source 8 -target 8 -Xlint:-options -cp "$TASK_PLATFORM" -d "$TASK_BUILD/classes" Tools/IconHelpers/AndroidIconExporter.java
"$TASK_JAVA_HOME/bin/java" -cp "$TASK_D8" com.android.tools.r8.D8 --min-api 23 --lib "$TASK_PLATFORM" --output "$TASK_BUILD/dex" "$TASK_BUILD/classes/dev/ekko/simlaunch/AndroidIconExporter.class"
cp "$TASK_BUILD/dex/classes.dex" "$TASK_RESOURCES/android-icon.dex"
for TASK_ARCH in arm64 x86_64; do
    xcrun --sdk iphonesimulator clang -arch "$TASK_ARCH" -mios-simulator-version-min=13.0 -fobjc-arc -framework Foundation -framework UIKit Tools/IconHelpers/SimulatorIconExporter.m -o "$TASK_BUILD/ios-$TASK_ARCH"
done
lipo -create "$TASK_BUILD/ios-arm64" "$TASK_BUILD/ios-x86_64" -output "$TASK_RESOURCES/ios-simulator-icon"
codesign --force --sign - "$TASK_RESOURCES/ios-simulator-icon"

#!/bin/zsh
# Builds build/SpaceMemory.app and build/libSpaceMemoryCore.dylib, which must stay side by side.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
bin=$(swift build -c release --show-bin-path)
mkdir -p build

# The library loads at launch from outside the bundle, so it can change freely.
cp "$bin/libSpaceMemoryCore.dylib" build/libSpaceMemoryCore.dylib
codesign --force --sign - build/libSpaceMemoryCore.dylib

# The app is only replaced when the launcher itself changes. That is the one case where its
# signature changes and macOS permissions have to be granted again.
app=build/SpaceMemory.app
if [[ -d "$app" ]] && cmp -s "$bin/SpaceMemory" build/launcher.unsigned; then
    echo "Launcher unchanged, permissions kept."
    exit 0
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/SpaceMemory" "$app/Contents/MacOS/SpaceMemory"
cp "$bin/SpaceMemory" build/launcher.unsigned
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --identifier local.spacememory.prototype "$app"
echo "Launcher rebuilt: grant permissions again."

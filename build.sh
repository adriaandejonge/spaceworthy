#!/bin/bash
# Build Spaceworthy.app with Command Line Tools only. Usage: ./build.sh [run]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Spaceworthy"
APP="build/Spaceworthy.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Spaceworthy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ ! -f Resources/AppIcon.icns ]]; then
    swift Tools/make-icon.swift Resources
    SET=Resources/AppIcon.iconset; mkdir -p "$SET"
    for s in 16 32 128 256 512; do
        sips -z $s $s Resources/icon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) Resources/icon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o Resources/AppIcon.icns
    rm -rf "$SET"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Stable designated requirement: macOS privacy grants (Desktop/Documents/Downloads, Full Disk Access)
# survive rebuilds instead of being re-prompted for every new ad-hoc signature.
codesign --force --deep -s - -r='designated => identifier "nl.adriaandejonge.Spaceworthy"' "$APP"

echo "Built: $(pwd)/$APP"
if [[ "${1:-}" == "run" ]]; then
    open "$APP"
fi

#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) ParaphraseTool.app on macOS. Needs Xcode or the Command Line Tools.
#   ./build.sh          # build dist/ParaphraseTool.app and launch it
#   ./build.sh nolaunch # build only
#   ./build.sh debug    # compile check only
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "error: the macOS app can only be built on macOS (needs the Swift toolchain)." >&2
    exit 1
fi

if [[ "${1:-}" == "debug" ]]; then
    swift build
    echo "Build OK."
    exit 0
fi

pkill -x ParaphraseTool 2>/dev/null && echo "Stopped running ParaphraseTool." || true

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ParaphraseTool"

APP="dist/ParaphraseTool.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ParaphraseTool"
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS keeps the Accessibility permission tied to this bundle.
codesign --force --deep --sign - "$APP"

echo "Done: $(pwd)/$APP"
if [[ "${1:-}" != "nolaunch" ]]; then open "$APP"; fi

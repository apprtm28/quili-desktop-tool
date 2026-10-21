#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) Quili.app on macOS. Needs Xcode or the Command Line Tools.
#   ./build.sh          # build ../dist/mac/Quili.app and launch it
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

pkill -x Quili 2>/dev/null && echo "Stopped running Quili." || true

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Quili"

OUT="../dist/mac"
APP="$OUT/Quili.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Quili"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
iconutil -c icns Icon/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
VERSION="$(tr -d '[:space:]' < ../VERSION)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# Sign with the stable "Quili Dev" certificate (see make-signing-cert.sh) so macOS keeps the Accessibility
# permission across rebuilds. Without it the bundle gets an ad-hoc signature, which changes with every build and
# makes macOS forget the permission.
IDENTITY="${SIGN_IDENTITY:-Quili Dev}"
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "Signed with \"$IDENTITY\"."
else
    codesign --force --deep --sign - "$APP"
    echo "warning: no \"$IDENTITY\" certificate found; signed ad-hoc, so Accessibility must be re-granted after each rebuild." >&2
    echo "         Run mac/make-signing-cert.sh once to fix that." >&2
fi

echo "Done: $(cd "$OUT" && pwd)/Quili.app (version $VERSION)"
if [[ "${1:-}" != "nolaunch" ]]; then open "$APP"; fi

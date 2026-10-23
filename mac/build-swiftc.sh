#!/usr/bin/env bash
# Builds Quili.app with swiftc directly, for Macs whose Command Line Tools can't run SwiftPM (no Xcode, a
# PackageDescription that doesn't link) or carry a stale usr/include/swift/module.modulemap that redefines
# SwiftBridging and breaks every framework import. Builds for this Mac's architecture only.
#   ./build-swiftc.sh          # build ../dist/mac/Quili.app and launch it
#   ./build-swiftc.sh nolaunch # build only
#   ./build-swiftc.sh debug    # compile check only
set -euo pipefail
cd "$(dirname "$0")"

BUILD=".build/swiftc"
mkdir -p "$BUILD"
FLAGS=(-swift-version 5 -module-name Quili -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$BUILD/module-cache")

# Hide the stale modulemap when both it and bridging.modulemap exist (Command Line Tools 16.4).
DUP=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [[ -f "$DUP" && -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]]; then
    : > "$BUILD/empty.modulemap"
    printf '{"version":0,"case-sensitive":"false","roots":[{"type":"file","name":"%s","external-contents":"%s"}]}' \
        "$DUP" "$PWD/$BUILD/empty.modulemap" > "$BUILD/overlay.yaml"
    FLAGS+=(-vfsoverlay "$PWD/$BUILD/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$PWD/$BUILD/overlay.yaml")
fi

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources/Quili -name '*.swift' | sort)

if [[ "${1:-}" == "debug" ]]; then
    swiftc "${FLAGS[@]}" -Onone -typecheck "${SOURCES[@]}"
    echo "Build OK."
    exit 0
fi

swiftc "${FLAGS[@]}" -O "${SOURCES[@]}" -o "$BUILD/Quili"

pkill -x Quili 2>/dev/null && echo "Stopped running Quili." || true
OUT="../dist/mac"
APP="$OUT/Quili.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Quili" "$APP/Contents/MacOS/Quili"
cp Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Icon/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
VERSION="$(tr -d '[:space:]' < ../VERSION)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-Quili Dev}"
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "Signed with \"$IDENTITY\"."
else
    codesign --force --deep --sign - "$APP"
    echo "warning: signed ad-hoc; re-grant Accessibility after each rebuild (or run make-signing-cert.sh once)." >&2
fi

echo "Done: $(cd "$OUT" && pwd)/Quili.app (version $VERSION)"
if [[ "${1:-}" != "nolaunch" ]]; then open "$APP"; fi

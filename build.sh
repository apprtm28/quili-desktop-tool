#!/usr/bin/env bash
# Builds ParaphraseTool for Windows (windows/) and macOS (mac/).
#
#   ./build.sh [windows|mac|all] [debug] [nolaunch]
#
#   (no args)     build every platform this machine can: Windows always (needs the .NET 8 SDK),
#                 macOS only when run on a Mac (needs Xcode / Command Line Tools)
#   windows       Release publish -> dist/windows/ParaphraseTool.exe
#   mac           Release build   -> dist/mac/ParaphraseTool.app
#   debug         compile-check only: no packaging, nothing is killed or launched
#   nolaunch      don't start the freshly built app
#
# A freshly built app is launched when it can run here: the .exe from WSL/Git Bash, the .app on macOS.
set -euo pipefail
cd "$(dirname "$0")"

TARGET=all; FLAGS=()
for arg in "$@"; do
    case "$arg" in
        windows|mac|all) TARGET="$arg" ;;
        debug|nolaunch) FLAGS+=("$arg") ;;
        *) echo "usage: $0 [windows|mac|all] [debug] [nolaunch]" >&2; exit 2 ;;
    esac
done

BUILT=(); SKIPPED=()

# build <name>: in `all` mode a platform that can't build here is skipped, not fatal.
build() {
    local name="$1"
    echo "=== $name ==="
    if "$name/build.sh" ${FLAGS[@]+"${FLAGS[@]}"}; then BUILT+=("$name"); return; fi
    if [[ "$TARGET" == all ]]; then SKIPPED+=("$name"); else exit 1; fi
}

if [[ "$TARGET" == windows || "$TARGET" == all ]]; then build windows; fi

if [[ "$TARGET" == mac || "$TARGET" == all ]]; then
    if [[ "$(uname)" != "Darwin" && "$TARGET" == all ]]; then
        echo "=== mac ==="; echo "Skipping: the macOS app can only be built on macOS."
        SKIPPED+=(mac)
    else
        build mac
    fi
fi

echo
echo "Built:   ${BUILT[*]:-none}"
echo "Skipped: ${SKIPPED[*]:-none}"
[[ ${#BUILT[@]} -gt 0 ]]

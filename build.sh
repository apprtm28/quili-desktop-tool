#!/usr/bin/env bash
# Builds ParaphraseTool for Windows (win-x64, .NET 8) and macOS (Swift, universal).
#
#   ./build.sh [windows|mac|all] [debug] [nolaunch]
#
#   (no args)     build every platform this machine can: Windows always (needs the .NET 8 SDK),
#                 macOS only when run on a Mac (needs Xcode / Command Line Tools)
#   windows       Release publish -> dist/ParaphraseTool.exe
#   mac           Release build   -> mac/dist/ParaphraseTool.app
#   debug         compile-check only: no packaging, nothing is killed or launched
#   nolaunch      don't start the freshly built app
#
# A freshly built app is launched when it can run here: the .exe from WSL/Git Bash, the .app on macOS.
set -euo pipefail
cd "$(dirname "$0")"

TARGET=all; DEBUG=0; LAUNCH=1
for arg in "$@"; do
    case "$arg" in
        windows|mac|all) TARGET="$arg" ;;
        debug) DEBUG=1 ;;
        nolaunch) LAUNCH=0 ;;
        *) echo "usage: $0 [windows|mac|all] [debug] [nolaunch]" >&2; exit 2 ;;
    esac
done

BUILT=(); SKIPPED=()

build_windows() {
    export PATH="$HOME/.dotnet:$PATH"
    export DOTNET_CLI_TELEMETRY_OPTOUT=1
    # Without libicu (and no sudo to install it) the SDK aborts; the build doesn't need globalization.
    if [[ "$(uname)" == "Linux" ]] && ! ldconfig -p 2>/dev/null | grep -q libicuuc; then
        export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
    fi

    if ! command -v dotnet >/dev/null 2>&1; then
        echo "error: 'dotnet' not found. Install the .NET 8 SDK: https://dotnet.microsoft.com/download/dotnet/8.0" >&2
        echo "  Ubuntu/WSL: sudo apt-get install -y dotnet-sdk-8.0" >&2
        return 1
    fi

    if (( DEBUG )); then
        dotnet build ParaphraseTool.csproj -c Debug -r win-x64 --self-contained false
        return
    fi

    # Kill any running copy first: it locks dist/ParaphraseTool.exe and would block the rebuild.
    local taskkill=""
    if command -v taskkill.exe >/dev/null 2>&1; then taskkill=taskkill.exe
    elif command -v taskkill >/dev/null 2>&1; then taskkill=taskkill; fi
    if [[ -n "$taskkill" ]]; then
        "$taskkill" /F /IM ParaphraseTool.exe >/dev/null 2>&1 && echo "Stopped running ParaphraseTool." || true
        sleep 1
    fi

    rm -rf dist
    dotnet publish ParaphraseTool.csproj -c Release -r win-x64 --self-contained true \
        -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o dist
    echo "Done: $(pwd)/dist/ParaphraseTool.exe"
    echo "Optional installer: compile installer.iss with Inno Setup on Windows."

    # Launch detached from this shell (needs a Windows path; cd away from any UNC cwd for cmd.exe).
    (( LAUNCH )) || return 0
    local exe=""
    if command -v wslpath >/dev/null 2>&1; then exe="$(wslpath -w "$(pwd)/dist/ParaphraseTool.exe")"
    elif command -v cygpath >/dev/null 2>&1; then exe="$(cygpath -w "$(pwd)/dist/ParaphraseTool.exe")"; fi
    if [[ -n "$exe" ]] && command -v cmd.exe >/dev/null 2>&1; then
        (cd /mnt/c 2>/dev/null || cd "$HOME"; cmd.exe /c start "" "$exe" >/dev/null 2>&1)
        echo "Launched ParaphraseTool."
    fi
}

build_mac() {
    local args=()
    (( DEBUG )) && args+=(debug)
    (( LAUNCH )) || args+=(nolaunch)
    mac/build.sh "${args[@]}"
}

run() {  # run <name> <function>: in `all` mode a platform that can't build here is skipped, not fatal
    local name="$1" fn="$2"
    echo "=== $name ==="
    if "$fn"; then BUILT+=("$name"); else
        if [[ "$TARGET" == all ]]; then SKIPPED+=("$name"); else exit 1; fi
    fi
}

if [[ "$TARGET" == windows || "$TARGET" == all ]]; then run windows build_windows; fi

if [[ "$TARGET" == mac || "$TARGET" == all ]]; then
    if [[ "$(uname)" != "Darwin" && "$TARGET" == all ]]; then
        echo "=== mac ==="; echo "Skipping: the macOS app can only be built on macOS."
        SKIPPED+=(mac)
    else
        run mac build_mac
    fi
fi

echo
echo "Built:   ${BUILT[*]:-none}"
echo "Skipped: ${SKIPPED[*]:-none}"
[[ ${#BUILT[@]} -gt 0 ]]

#!/usr/bin/env bash
# Builds the Windows app (win-x64, .NET 8). Works from WSL/Linux/macOS with the .NET 8 SDK
# (the csproj sets EnableWindowsTargeting), or from Git Bash on Windows.
#   ./build.sh            # Release publish -> ../dist/windows/ParaphraseTool.exe, then launch it (WSL / Git Bash)
#   ./build.sh debug      # compile check only: nothing is packaged, killed or launched
#   ./build.sh nolaunch   # build without launching
set -euo pipefail
cd "$(dirname "$0")"

DEBUG=0; LAUNCH=1
for arg in "$@"; do
    case "$arg" in
        debug) DEBUG=1 ;;
        nolaunch) LAUNCH=0 ;;
        *) echo "usage: $0 [debug] [nolaunch]" >&2; exit 2 ;;
    esac
done

export PATH="$HOME/.dotnet:$PATH"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
# Without libicu (and no sudo to install it) the SDK aborts; the build doesn't need globalization.
if [[ "$(uname)" == "Linux" ]] && ! ldconfig -p 2>/dev/null | grep -q libicuuc; then
    export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
fi

if ! command -v dotnet >/dev/null 2>&1; then
    echo "error: 'dotnet' not found. Install the .NET 8 SDK: https://dotnet.microsoft.com/download/dotnet/8.0" >&2
    echo "  Ubuntu/WSL: sudo apt-get install -y dotnet-sdk-8.0" >&2
    exit 1
fi

if (( DEBUG )); then
    dotnet build ParaphraseTool.csproj -c Debug -r win-x64 --self-contained false
    exit
fi

# Kill any running copy first: it locks dist/windows/ParaphraseTool.exe and would block the rebuild.
taskkill=""
if command -v taskkill.exe >/dev/null 2>&1; then taskkill=taskkill.exe
elif command -v taskkill >/dev/null 2>&1; then taskkill=taskkill; fi
if [[ -n "$taskkill" ]]; then
    "$taskkill" /F /IM ParaphraseTool.exe >/dev/null 2>&1 && echo "Stopped running ParaphraseTool." || true
    sleep 1
fi

OUT="../dist/windows"
rm -rf "$OUT"
dotnet publish ParaphraseTool.csproj -c Release -r win-x64 --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:EnableCompressionInSingleFile=true -p:DebugType=none -o "$OUT"
echo "Done: $(cd "$OUT" && pwd)/ParaphraseTool.exe"
echo "Optional installer: compile installer.iss with Inno Setup on Windows."

# Launch detached from this shell (needs a Windows path; cd away from any UNC cwd for cmd.exe).
(( LAUNCH )) || exit 0
exe=""
if command -v wslpath >/dev/null 2>&1; then exe="$(wslpath -w "$(cd "$OUT" && pwd)/ParaphraseTool.exe")"
elif command -v cygpath >/dev/null 2>&1; then exe="$(cygpath -w "$(cd "$OUT" && pwd)/ParaphraseTool.exe")"; fi
if [[ -n "$exe" ]] && command -v cmd.exe >/dev/null 2>&1; then
    (cd /mnt/c 2>/dev/null || cd "$HOME"; cmd.exe /c start "" "$exe" >/dev/null 2>&1)
    echo "Launched ParaphraseTool."
fi

# Quili

A tray / menu-bar app for **Windows** and **macOS**. When you focus a text field in any app (Chrome, Slack desktop, Notepad, …) a small ✦ button appears at the field's bottom-right. Click it and the selected text, or the full text of the field when nothing is selected, is paraphrased by the paraphrase API and replaced in place (Ctrl+Z / Cmd+Z undoes it). It can also translate to English and summarize a Slack thread.

## How it works
- **Detection:** Windows UI Automation polls the focused element (`Platform/FocusTracker`) and shows a non-activating, always-on-top overlay (`UI/OverlayWindow`) so the field keeps focus.
- **Read:** the selection first (UIA `TextPattern`, or Ctrl+C when UIA can't report a selection), otherwise the whole field via `TextPattern`/`ValuePattern`, falling back to Ctrl+A / Ctrl+C.
- **Write:** clipboard + Ctrl+V over the original selection (restored first; if it changed while the request ran, the result is copied to the clipboard instead), or Ctrl+A / Ctrl+V over the whole field when nothing was selected (works in Chromium/Electron editors). Your previous *text* clipboard is restored.
- **Paraphrase:** `POST {server}/api/paraphrase` with an `X-API-Key` header; the server detects the language and replies in it. The text streams into a small preview bubble next to the button while the model writes it, and the field is replaced once it is complete. Set the server URL and API key in Settings. The API key is stored encrypted with Windows DPAPI in `%APPDATA%\Quili\settings.json`.
- **Buttons:** the green round button (tooltip **Text Tool**) paraphrases on a click. Hovering it expands a pill with two actions: **EN** translates the text into natural, paraphrased English (`POST {server}/api/translate`, whatever the original language) and the sparkle **Paraphrase**, which follows the **Paraphrase instruction** from Settings (e.g. "make it formal", "shorter", "translate to Indonesian").
- Settings also shows a link to this repository.
- Text is only sent when you click the button. Password fields are ignored.

## Project layout
```
build.sh                  builds every platform this machine supports
windows/                  WPF / .NET 8 app
  build.sh, publish.ps1   build scripts (WSL/Git Bash, native PowerShell)
  installer.iss           Inno Setup script
  src/
    App.xaml(.cs)         startup, single instance, wiring
    ParaphraseController  focus → overlay button → read → paraphrase → replace
    Core/                 Settings, ParaphraseClient (server API), DebugLog
    Platform/             FocusTracker + TextAccess + ThreadReader (UI Automation, clipboard), Native, StartupRegistration
    UI/                   OverlayWindow (the ✦ button), SettingsWindow, TrayIcon
mac/                      native Swift menu-bar app, same structure
  build.sh, Package.swift, Info.plist
  Sources/Quili/
    App/                  main, AppDelegate (menus), ParaphraseController
    Accessibility/        AX helpers, FocusTracker, TextAccess, ThreadReader
    Services/             Settings, ParaphraseClient, DebugLog, Notifier
    UI/                   OverlayWindow, SettingsWindow
```

## Building

Both apps are built with `build.sh` scripts; there is one at the repo root and one inside each platform folder. They run on a plain `bash` (macOS, Linux/WSL, Git Bash on Windows).

### What you need

| To build | You need | Where it can be built |
| --- | --- | --- |
| **Windows app** (`Quili.exe`) | the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) | Windows, WSL/Linux or macOS (the project sets `EnableWindowsTargeting`); it can only *run* on Windows |
| **macOS app** (`Quili.app`) | Xcode or the Command Line Tools (`xcode-select --install`), Swift 5.9+ | macOS 13 or newer only (the app targets macOS 13+; the build is universal arm64 + x86_64) |
| Windows installer (optional) | [Inno Setup 6](https://jrsoftware.org/isinfo.php) | Windows only |

### Quick start

```bash
git clone <this repo> && cd quili-desktop-tool

./build.sh              # every platform this machine can build, then launch what can run here
./build.sh windows      # only the Windows app  -> dist/windows/Quili.exe
./build.sh mac          # only the macOS app    -> dist/mac/Quili.app
```

On a Mac, `./build.sh` builds the macOS app and also the Windows one if the .NET 8 SDK is installed. On Windows or WSL it builds the Windows app and skips macOS (it says so in the summary). Naming a platform explicitly (`windows` or `mac`) makes a failure fatal instead of skipped.

### `build.sh` usage

```
./build.sh [windows|mac|all] [debug] [nolaunch]
```

| Argument | Effect |
| --- | --- |
| *(none)* / `all` | build every platform this machine supports; a platform that can't build here is skipped, not an error |
| `windows` | Release publish of the Windows app: self-contained, single-file `win-x64` → `dist/windows/Quili.exe` |
| `mac` | Release build of the macOS app: universal binary, bundled and signed → `dist/mac/Quili.app` |
| `debug` | compile check only: nothing is packaged, killed or launched. Use it to check your changes build |
| `nolaunch` | build, but don't start the new app afterwards |

Examples:

```bash
./build.sh debug                # fast "does everything still compile?" on this machine
./build.sh mac nolaunch         # build the Mac app without restarting it
./build.sh windows debug        # compile-check the Windows app only
```

Notes:
- By default a release build **stops the running Quili first** (it would lock the output file) and **launches the new one** when it can run on this machine: the `.app` on macOS, the `.exe` from WSL or Git Bash. Pass `nolaunch` to skip the launch.
- Output goes to `dist/` (not tracked by git): `dist/windows/Quili.exe`, `dist/mac/Quili.app`. Each run replaces that platform's previous output.
- The version comes from the `VERSION` file at the repo root and is stamped into both apps.
- The platform scripts can also be run directly: `windows/build.sh [debug] [nolaunch]` and `mac/build.sh [nolaunch|debug]`. The root script just calls them.
- Exit status: non-zero if nothing could be built (or, with an explicit platform, if that build failed).

### Windows

Prerequisite: the .NET 8 SDK (`dotnet --version` should print 8.x). On WSL/Ubuntu: `sudo apt-get install -y dotnet-sdk-8.0`.

```bash
./build.sh windows            # from the repo root (bash / WSL / Git Bash)
cd windows && ./build.sh      # same thing
```
```powershell
cd windows
dotnet run                    # run from source while developing
./publish.ps1                 # release publish from native PowerShell -> dist\windows\Quili.exe
```

`build.sh` in a plain Linux shell without the ICU libraries falls back to invariant globalization automatically; the build doesn't need it. To make an installer, compile `windows\installer.iss` with Inno Setup (`ISCC.exe /DAppVersion=1.0.0 windows\installer.iss`) to get `dist\windows\QuiliSetup-<version>.exe`.

### macOS

Prerequisite: Xcode or the Command Line Tools (`xcode-select --install`).

```bash
./build.sh mac                # from the repo root
cd mac && ./build.sh          # same thing: build dist/mac/Quili.app and launch it
cd mac && ./build.sh nolaunch # build only
cd mac && ./build.sh debug    # compile check only
```

After a build, grant **System Settings → Privacy & Security → Accessibility** to Quili once; without it no fields are detected and paste is blocked. To keep that permission across rebuilds, create the stable signing certificate once with `mac/make-signing-cert.sh` (see *Signing* in the macOS section below).

## Releases
Downloads are on the repo's **Releases** page: `Quili-Setup-vX.Y.Z.exe` (Windows installer), `Quili-vX.Y.Z-win-x64.exe` (portable) and `Quili-vX.Y.Z-macos.zip` (universal app).

To publish a release (GitHub Actions builds both platforms with the same `build.sh` scripts, so you don't need a Mac):
```bash
echo 1.1.0 > VERSION            # bump the version
git commit -am "Release 1.1.0" && git push
git tag v$(cat VERSION) && git push origin v$(cat VERSION)
```
The workflow (`.github/workflows/release.yml`) refuses a tag that doesn't match `VERSION`. It can also be run by hand from the Actions tab to just build the artifacts.

The release builds aren't code-signed, so the OS shows a warning when you open them: on Windows choose *More info → Run anyway* (SmartScreen); on macOS right-click the app and choose *Open*, or run `xattr -dr com.apple.quarantine Quili.app`.

## Summarize a Slack thread
Open a thread in the Slack desktop app's side pane: a round green **✦** button appears just left of Slack's own "Summarize thread" button (hover it for the "Summarize thread on Quili" tooltip). Click it. Quili reads the thread text from Slack's window through the accessibility API (no Slack API, token or admin approval), sends it to `POST /api/summarize-thread` on your server, shows the summary in a bubble (a short briefing: the key discussion, the outcome classified into decisions, action items, open questions and risks, and the key details, with the most important points in bold; scrollable with the mouse wheel; it stays until you close it with the × at its top-right) and copies it to the clipboard. Nothing is written to Slack.

- Only what the window has rendered is read, so a very long thread may need scrolling to the top first; the oldest lines are dropped if the thread exceeds ~38,000 characters.
- Slack's accessibility layout isn't documented and may change between releases. If it says "No thread found", the debug log (`debug.log`) records how many lines were read and the shape of the window (control types only). When you click Summarize, the thread text that is sent is also written to `debug.log` in full, so the log then holds thread content (it is cleared once it passes 1 MB). Untick **Write debug log** in Settings to stop all logging.
- **Server down?** Tick **Mock server (offline)** in Settings and press Save: Quili starts a tiny built-in server on `127.0.0.1` and sends every action (paraphrase, translate and summarize) to it; it always answers with fixed sample text. Untick it and Save to stop the mock and go back to the real server. `tools/mock_server.py` is the same mock as a standalone script for other clients.
- Slack must be exposing its accessibility tree: on Windows start it with `--force-renderer-accessibility` if the first attempt finds nothing.

## Hermes (personal macOS fork)

This fork routes Quili's AI through tools on your own machines. Decisions and status: [`docs/hermes/decisions.md`](docs/hermes/decisions.md), [`docs/hermes/plan.md`](docs/hermes/plan.md).

- **Paraphrase / Translate** run through `opencode run` on the Mac (Settings → *Paraphrase with opencode on this Mac*, model `opencode-go/deepseek-v4.1-flash` by default). No server or API key needed.
- **Summarize** (the ✦ next to Slack's *Summarize thread*) goes to the Hermes `work` profile over SSH (`ssh apprtm hermes -p work chat …`). The bubble keeps one Hermes session per thread: reopen the thread later and the conversation is still there, with **Refresh** when new replies arrived. Type in **Ask Hermes…** to ask follow-ups (Return sends, Esc gives focus back to Slack).
- **Coverage:** when Quili can't confirm it read the whole thread (oldest messages left out, start not reached, fewer replies than Slack's count) an amber line says so, with **Retry read**.
- **Ranges from the main channel:** hover a message, click **Start here**, hover another, click **End here**. Quili scrolls Slack between them, then lists the messages to untick before **Summarize with Hermes**.
- **Save to work context:** Hermes drafts a note, you edit it in the bubble and **Approve and save**; Quili writes it over SSH to `~/ObsidianVault/03-resources/quili-work-context/` on the Hermes host (never overwriting). Blocked on an incomplete read unless you choose **Save anyway**.
- **Any app (Gmail, Chrome…):** select text and press **⌃⌥H** (or menu bar → *Ask Hermes about selection*). Hermes summarizes it in the bubble; then Ask or **Save to work context** as above. Everything selected goes to the `work` profile.
- **Hermes unreachable:** the bubble offers **Retry** or **Summarize directly this once** (opencode, not saved to Hermes).
- Hermes turns run with `-t file,skills,session_search,clarify,todo`; if Hermes writes a file anyway, the bubble shows a red warning.
- Build on a Mac without Xcode: `mac/build-swiftc.sh` (arm64, works around broken Command Line Tools).

## Notes / limitations
- Chrome and Electron expose UI Automation only when an accessibility client is detected; the tool triggers this automatically, but the first focus after launching Chrome/Slack may need a click or two. If Slack doesn't show the button, start it with `--force-renderer-accessibility`.
- Apps running as Administrator can't be read unless this tool is also run as Administrator.
- With nothing selected, replacing uses Ctrl+A, so the field is fully replaced (that's the intended "paraphrase everything" behavior). Select part of the text to change only that part.

## macOS version (`mac/`)
A native Swift menu-bar app with the same behavior (✦ button on the focused field, selection-only or whole-field paraphrase, same `/api/paraphrase` server). The Windows code above is WPF/UI Automation and can't run on macOS, so the Mac app is a separate implementation.

- **Build:** see [Building](#building) above (`cd mac && ./build.sh` → `dist/mac/Quili.app`, universal arm64 + x86_64).
- **Permission:** grant **System Settings → Privacy & Security → Accessibility** to Quili. Without it, no fields are detected and paste is blocked.
- **Optional permission:** **Screen Recording** lets the docked button snap to a field's visible border (the Windows version samples screen pixels for this). Without it the button uses a fixed offset below the field.
- **Detection:** the macOS Accessibility API (`AXUIElement`) instead of UI Automation; for Chromium/Electron apps it sets `AXEnhancedUserInterface`/`AXManualAccessibility` so Chrome and Slack expose their fields.
- **Write:** pasteboard + Cmd+A / Cmd+V. The original selection is restored before pasting. Your previous text clipboard is restored.
- **Storage:** server URL and style in UserDefaults, API key in the Keychain. Log: `~/Library/Logs/Quili/debug.log`.
- **Signing:** run `mac/make-signing-cert.sh` once to create a self-signed "Quili Dev" certificate; `mac/build.sh` then signs every build with it, so the Accessibility permission survives rebuilds (grant it once; it stays valid as long as the bundle id `com.ferdinandimas.quili` and the certificate do not change). Without the certificate the app is ad-hoc signed, and macOS forgets the permission after each rebuild (remove and re-add the app in the Accessibility list). `./make-signing-cert.sh --export` also prepares the `MACOS_CERT_P12` / `MACOS_CERT_PASSWORD` secrets that let the release workflow sign the same way.

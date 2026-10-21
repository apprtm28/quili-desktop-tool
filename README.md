# Quili

_Formerly "Paraphrase Tool". On first launch Quili copies the settings (server URL, API key, instruction, start-at-login) from the old location, so nothing needs re-entering._

Windows tray app. When you focus a text field in any app (Chrome, Slack desktop, Notepad, …) a small ✦ button appears at the field's bottom-right. Click it and the selected text, or the full text of the field when nothing is selected, is paraphrased by the paraphrase API and replaced in place (Ctrl+Z undoes it).

## How it works
- **Detection:** Windows UI Automation polls the focused element (`Platform/FocusTracker`) and shows a non-activating, always-on-top overlay (`UI/OverlayWindow`) so the field keeps focus.
- **Read:** the selection first (UIA `TextPattern`, or Ctrl+C when UIA can't report a selection), otherwise the whole field via `TextPattern`/`ValuePattern`, falling back to Ctrl+A / Ctrl+C.
- **Write:** clipboard + Ctrl+V over the original selection (restored first; if it changed while the request ran, the result is copied to the clipboard instead), or Ctrl+A / Ctrl+V over the whole field when nothing was selected (works in Chromium/Electron editors). Your previous *text* clipboard is restored.
- **Paraphrase:** `POST {server}/api/paraphrase` with an `X-API-Key` header; the server detects the language and replies in it. Set the server URL and API key in Settings. The API key is stored encrypted with Windows DPAPI in `%APPDATA%\Quili\settings.json`.
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
    Platform/             FocusTracker + TextAccess (UI Automation, clipboard), Native, StartupRegistration
    UI/                   OverlayWindow (the ✦ button), SettingsWindow, TrayIcon
mac/                      native Swift menu-bar app, same structure
  build.sh, Package.swift, Info.plist
  Sources/Quili/
    App/                  main, AppDelegate (menus), ParaphraseController
    Accessibility/        AX helpers, FocusTracker, TextAccess
    Services/             Settings, ParaphraseClient, DebugLog, Notifier
    UI/                   OverlayWindow, SettingsWindow
```

## Build & run (needs the .NET 8 SDK on Windows)
```powershell
cd windows
dotnet run
```

## Package for install
```powershell
cd windows
./publish.ps1        # produces dist\windows\Quili.exe (self-contained, single file)
```
Then compile `windows\installer.iss` with [Inno Setup](https://jrsoftware.org/isinfo.php) to get `dist\windows\QuiliSetup-<version>.exe`.

## Releases
Downloads are on the repo's **Releases** page: `Quili-Setup-vX.Y.Z.exe` (Windows installer), `Quili-vX.Y.Z-win-x64.exe` (portable) and `Quili-vX.Y.Z-macos.zip` (universal app).

To publish a release (GitHub Actions builds both platforms with the same `build.sh` scripts, so you don't need a Mac):
```bash
echo 1.1.0 > VERSION            # bump the version
git commit -am "Release 1.1.0" && git push
git tag v$(cat VERSION) && git push origin v$(cat VERSION)
```
The workflow (`.github/workflows/release.yml`) refuses a tag that doesn't match `VERSION`. It can also be run by hand from the Actions tab to just build the artifacts.

The builds aren't code-signed, so first launch shows a warning: on Windows choose *More info → Run anyway* (SmartScreen); on macOS right-click the app and choose *Open*, or run `xattr -dr com.apple.quarantine Quili.app`.

## Notes / limitations
- Chrome and Electron expose UI Automation only when an accessibility client is detected; the tool triggers this automatically, but the first focus after launching Chrome/Slack may need a click or two. If Slack doesn't show the button, start it with `--force-renderer-accessibility`.
- Apps running as Administrator can't be read unless this tool is also run as Administrator.
- With nothing selected, replacing uses Ctrl+A, so the field is fully replaced (that's the intended "paraphrase everything" behavior). Select part of the text to change only that part.

## Building both
`./build.sh` (repo root) builds every platform the current machine supports: Windows always (needs the .NET 8 SDK), macOS only on a Mac. Options: `./build.sh [windows|mac|all] [debug] [nolaunch]`. On WSL/Linux the macOS build is skipped.

## macOS version (`mac/`)
A native Swift menu-bar app with the same behavior (✦ button on the focused field, selection-only or whole-field paraphrase, same `/api/paraphrase` server). The Windows code above is WPF/UI Automation and can't run on macOS, so the Mac app is a separate implementation.

- **Build (on a Mac with Xcode or the Command Line Tools):** `cd mac && ./build.sh` → `dist/mac/Quili.app` (universal arm64 + x86_64), then it launches. `./build.sh nolaunch` only builds.
- **Permission:** on first launch grant **System Settings → Privacy & Security → Accessibility** to Quili. Without it, no fields are detected and paste is blocked.
- **Optional permission:** **Screen Recording** lets the docked button snap to a field's visible border (the Windows version samples screen pixels for this). Without it the button uses a fixed offset below the field.
- **Detection:** the macOS Accessibility API (`AXUIElement`) instead of UI Automation; for Chromium/Electron apps it sets `AXEnhancedUserInterface`/`AXManualAccessibility` so Chrome and Slack expose their fields.
- **Write:** pasteboard + Cmd+A / Cmd+V. The original selection is restored before pasting. Your previous text clipboard is restored.
- **Storage:** server URL and style in UserDefaults, API key in the Keychain. Log: `~/Library/Logs/Quili/debug.log`.
- **Signing:** run `mac/make-signing-cert.sh` once to create a self-signed "Quili Dev" certificate; `mac/build.sh` then signs every build with it, so the Accessibility permission survives rebuilds (grant it once; it stays valid as long as the bundle id `com.ferdinandimas.quili` and the certificate do not change). Without the certificate the app is ad-hoc signed, and macOS forgets the permission after each rebuild (remove and re-add the app in the Accessibility list). `./make-signing-cert.sh --export` also prepares the `MACOS_CERT_P12` / `MACOS_CERT_PASSWORD` secrets that let the release workflow sign the same way.

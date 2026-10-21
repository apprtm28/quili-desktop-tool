# Quili: instructions for coding agents

One app, implemented twice: **Windows** (`windows/`, C# / WPF, .NET 8) and **macOS** (`mac/`, Swift / AppKit). See `README.md` for what it does and how to build it.

## The rule: both platforms stay identical

**Any change made to the Windows code or the macOS code must be replicated exactly in the other one.** Behavior, defaults, text, constants, timings, colors, sizes, geometry, error messages and design all have to match. A change is not finished until both sides are updated.

- Treat the platform you were asked to change as the starting point and port the change to the other platform in the same piece of work. Don't leave the second platform for later.
- When the two disagree and you weren't asked to change either, report it; don't silently pick a side.
- Match the other platform's *outcome*, using each platform's own idiom (UI Automation vs Accessibility API, WPF vs AppKit, DPAPI vs Keychain). Don't invent new behavior on one side.
- If a platform genuinely can't do something the same way, do the closest equivalent and add it to the list of intentional differences below, in the same change.
- Keep user-facing strings, the default paraphrase instruction, endpoints, JSON fields, limits, timeouts and retry rules identical.
- Verify both: `./build.sh windows debug` and `./build.sh mac debug` compile-check without packaging (Windows needs the .NET 8 SDK; macOS needs Xcode). If you can only build one platform on this machine, say so explicitly in your summary.

### Where things live

| Concern | Windows (`windows/src/`) | macOS (`mac/Sources/Quili/`) |
|---|---|---|
| Startup, single instance, menus/tray | `App.xaml.cs`, `UI/TrayIcon.cs` | `App/main.swift`, `App/AppDelegate.swift` |
| Focus → read → request → replace flow | `ParaphraseController.cs` | `App/ParaphraseController.swift` |
| Server API | `Core/ParaphraseClient.cs` | `Services/ParaphraseClient.swift` |
| Settings model, defaults, secrets | `Core/Settings.cs`, `Platform/StartupRegistration.cs` | `Services/Settings.swift` |
| Actions (paraphrase / translate) | `Core/TextAction.cs` | `App/TextAction.swift` |
| Emoji / damaged-text checks | `Core/TextHygiene.cs` | `Services/TextHygiene.swift` |
| Debug log, version info | `Core/DebugLog.cs`, `Core/AppInfo.cs` | `Services/DebugLog.swift`, `Services/AppInfo.swift` |
| Field detection | `Platform/FocusTracker.cs` | `Accessibility/FocusTracker.swift`, `Accessibility/AX.swift` |
| Read / replace text | `Platform/TextAccess.cs`, `Platform/Native.cs` | `Accessibility/TextAccess.swift` |
| Visible field-edge measurement | `Platform/FieldEdge.cs` | `Accessibility/FieldEdge.swift` |
| Overlay button and pill | `UI/OverlayWindow.xaml(.cs)` | `UI/OverlayWindow.swift` |
| Settings window | `UI/SettingsWindow.xaml(.cs)` | `UI/SettingsWindow.swift` |
| Icon / glyph geometry, palette | XAML resources | `UI/Glyphs.swift` |
| Notifications | `UI/TrayIcon.cs` (balloon) | `Services/Notifier.swift` |

The icon geometry is shared as SVG path strings: when a glyph changes in the XAML, update the same string in `UI/Glyphs.swift`.

## Intentional platform differences

Keep this list current. Anything not listed here is expected to match.

- API key storage: DPAPI-encrypted in `settings.json` (Windows) vs Keychain (macOS); other settings in `settings.json` vs `UserDefaults`.
- Run at startup: the `Run` registry key vs `SMAppService`. The label reads "Start with Windows" vs "Start at login".
- Single instance: named mutex vs a bundle-identifier check.
- Tray icon vs menu-bar item: "Exit" vs "Quit"; Windows also opens Settings on tray double-click.
- Notifications: tray balloon vs `osascript` banner.
- Field detection: UI Automation vs the Accessibility API. macOS additionally enables the web accessibility tree of Chromium / Electron / Firefox apps.
- Permissions: macOS needs Accessibility, and optionally Screen Recording for `FieldEdge` (Windows samples pixels without a permission).
- Text-field fonts: Segoe UI vs the system font.
- Lone-surrogate cleanup exists only on Windows (Swift strings can't hold them).
- Overlay cursor: the macOS overlay always shows the regular arrow pointer (requested). Windows still shows a hand over the actions and a size-all cursor on the green button.
- One-time migration from the app's former name "Paraphrase Tool": Windows copies `%APPDATA%\ParaphraseTool\settings.json` and moves the old `Run` entry; macOS copies the old `UserDefaults` domain `com.ferdibot.paraphrasetool` and the old Keychain item (macOS asks once to allow reading it). These legacy names are the only places the old name should remain.
- Log location: `%APPDATA%\Quili\debug.log` vs `~/Library/Logs/Quili/debug.log`.

## Practical notes

- `mac/build.sh` signs with the self-signed "Quili Dev" certificate when it exists in the keychain (create it once with `mac/make-signing-cert.sh`), otherwise ad-hoc. With an ad-hoc signature macOS forgets the Accessibility permission after every rebuild: remove and re-add `dist/mac/Quili.app` in System Settings → Privacy & Security → Accessibility. Never commit `.p12` / `.pem` / `.key` files.
- `dist/` is build output and is not tracked.
- The version comes from the `VERSION` file; both build scripts stamp it into the app.
- Don't commit unless asked.

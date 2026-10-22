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
| Summarize button on the open thread pane | `Platform/ThreadWatcher.cs`, `UI/ThreadButtonWindow.xaml(.cs)`, `ParaphraseController` | `Accessibility/ThreadWatcher.swift`, `UI/ThreadButtonWindow.swift`, `ParaphraseController` |
| Mock server (offline demo toggle) | `Core/MockServer.cs`, `Core/Settings.cs` (`MockMode`), `UI/SettingsWindow.xaml(.cs)` | `Services/MockServer.swift`, `Services/Settings.swift` (`mockMode`), `UI/SettingsWindow.swift` |
| Message headers (`Author [time]`) in the thread text | `Platform/ThreadFormat.cs` | `Accessibility/ThreadFormat.swift` |
| Interface noise dropped from the thread text | `Platform/ThreadNoise.cs` | `Accessibility/ThreadNoise.swift` |
| Read a Slack thread (summarize action) | `Platform/ThreadReader.cs`, `ParaphraseController.StartSummary` | `Accessibility/ThreadReader.swift`, `ParaphraseController.summarizeThread` |
| Visible field-edge measurement | `Platform/FieldEdge.cs` | `Accessibility/FieldEdge.swift` |
| Overlay button and pill | `UI/OverlayWindow.xaml(.cs)` | `UI/OverlayWindow.swift` |
| Live preview bubble (streamed text) | `UI/BubbleWindow.xaml(.cs)` | `UI/BubbleWindow.swift` |
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
- Streaming: both clients send `"stream": true` and read server-sent events (`delta` = text so far, each replacing the previous; then `done` or `error`), showing the text in the click-through bubble above the button (below when there is no room) and only replacing the field once `done` arrives. Windows reads the stream with `StreamReader`, macOS with `URLSession.bytes(...).lines` (which skips blank lines, so an event is handled on its `data:` line). A server that answers plain JSON still works.
- Overlay cursor: the macOS overlay always shows the regular arrow pointer (requested). Windows still shows a hand over the actions and a size-all cursor on the green button.
- One-time migration from the app's former name "Paraphrase Tool": Windows copies `%APPDATA%\ParaphraseTool\settings.json` and moves the old `Run` entry; macOS copies the old `UserDefaults` domain `com.ferdibot.paraphrasetool` and the old Keychain item (macOS asks once to allow reading it). These legacy names are the only places the old name should remain.
- Summarize Slack thread (`/api/summarize-thread`, started from the Summarize button): both read the open thread pane of the Slack desktop app through the accessibility tree (UIA vs `AXUIElement`), send it to the server, show the summary in a tall, top-aligned bubble anchored to the button (closable once finished, and it closes by itself after 5 s) and copy it to the clipboard; Slack is never written to. Differences: macOS checks the Accessibility permission first; Slack is found by bundle id `com.tinyspeck.slackmacgap` vs process name `slack`. The reader is heuristic (Slack's tree is undocumented) and its own log lines carry only counts and roles, but when a summary is requested the whole thread text that is sent is written to the debug log (deliberate, as a debugging aid: the log then holds thread content, and it is cleared once it passes 1 MB).
- Summarize button: while Slack is in front and Slack's own "Summarize thread" button is on screen, a round green sparkle button (icon only; "Summarize thread on Quili" is its tooltip) sits just left of Slack's own icon-only "Summarize thread" button (a button whose short name says so, or whose direct child text does; 8 dip to its left, on its right when the screen has no room) and summarizes that thread when clicked. That button is the only "a thread is open" signal for showing Quili's button, and "thread" must match as a whole word so Slack's "Threads" view does not count; its frame only has to be at least 12 dip, as it is a small icon button (Slack's is 28). To find it quickly the search first locates the thread pane (a group/landmark labelled "Thread" or "Utas", only as a shortcut to a small subtree) and then looks inside it for a button whose name, help text or id says "summarize" (looser than the exact "summarize thread" used when there is no pane). When nothing is found it logs the header buttons' type|name|help|id|size (at most every 20 s, never message text) so an unexpected Slack layout can be diagnosed. There is no menu-bar / tray item for it: the button is the only way to start a summary. When reading, the order is: the smallest region of at least 6 lines around Slack's button, widened by climbing while the ancestor is still a side pane (at most 60% of the window wide) so the parent message that started the thread, which sits above the "N replies" divider, is included, then a group/landmark labelled "Thread" or "Utas", then the smallest region around the focused message box. A background watcher polls every second (searching the tree at most every 2 s while no pane is known, re-measuring the cached pane otherwise). The summary bubble anchors to the button; the summary bubble is closable from the first moment ("Reading the thread…", the streaming text, the finished summary; a × at its top-right, and the bubble then takes clicks; clicking it before the summary is done also cancels the request) and the finished summary closes by itself after 5 s (`summaryAutoCloseSeconds` / `SummaryAutoClose`; starting any other request cancels that timer); both ways of closing fade the bubble out over 0.25 s (`BubbleWindow.fadeOut()` / `FadeOut()`), and any new bubble or hide cancels a fade in progress, (paraphrase/translate previews stay click-through). Same on both platforms; only the UI toolkit differs (non-activating `NSPanel` vs a `WS_EX_NOACTIVATE` WPF window). Pause hides it. Tooltip: macOS draws its own small tooltip window 0.4 s after the pointer settles on the button (native tooltips don't show for a panel while another app is active); Windows uses the WPF `ToolTip`.
- Thread text format: each container of the Slack pane becomes one line; a message header, the author's name then its time (a few short runs, then a run like "Just now", "22 minutes ago" or "2:53 PM", the time not first), is written `Author [time]` so the summarizer can tell who said what (`/api/summarize-thread`'s prompt explains it). Font weight is not used: Slack's accessibility tree does not expose it. The name must come from a button (how Slack renders authors) or look like a name (capitalised words), and `@mentions` never count; a lone time is a hover time and stays as is. Slack (Chromium) only exposes the replies near the visible part of the pane, so a long thread is read by scrolling: the reader scrolls the pane to the top, reads a screenful, steps down about 70% of the pane at a time (at most 40 steps, 15 s), and merges the views by the lines they share (relative times such as "32 minutes ago" are ignored when matching, since they can roll over meanwhile). If the views stop overlapping it steps back and takes smaller steps; if nothing scrolls, what was visible is used. macOS scrolls smoothly with scroll-wheel events in small slices at the pane's position (it checks each move went the expected way by the views' overlap) and, when Slack ignores those, asks the accessibility tree to bring the first or last rendered message of the thread's list into view (`AXScrollToVisible`, which jumps); the log line says how many moves were smooth and how many were jumps. The pane always goes to the top first, is read downwards to the bottom, and is scrolled back to the top when done (wherever it started); Windows uses the UIA ScrollPattern the same way. The text sent is grouped per message: each message (its header line and the lines below, up to the next header) is wrapped in `{{` and `}}`, messages are separated by a blank line, and `{`/`}` inside a message are escaped as `\{`/`\}` (`ThreadFormat.messages` / `Messages`; a header is recognised by its `[time]` part). When the thread is too long the oldest whole messages are dropped. Interface controls and chrome are dropped by `ThreadNoise`, including the pane's title line ("Thread dbagroup"). The debug log also records a text-free outline of the captured region (roles/types, child counts, text lengths) to diagnose missing messages.
- "Write debug log" setting (on by default): when off, nothing is written to `debug.log` at all; switching it in Settings leaves one "debug log turned off/on in Settings" line, so the log shows when it was disabled. macOS reads it from the `loggingEnabled` preference inside `DebugLog` itself; Windows keeps it in `Settings.LoggingEnabled` and pushes it to `DebugLog.Enabled` at startup and on Save.
- "Mock server (offline)" setting: when on, Save starts a built-in loopback server (`127.0.0.1`, system-picked port, answers `/api/paraphrase`, `/api/translate` and `/api/summarize-thread` with fixed canned text, streaming `delta`/`done` events like the real server; 404 elsewhere) and every action is sent to it, needing neither a server URL nor an API key. Turning it off and saving stops the server and goes back to the real one; it is also started at launch while the setting is on. Differences: macOS uses `NWListener` (Network.framework) and shows a notification banner if it cannot start; Windows uses a `TcpListener` (so no URL reservation or admin rights are needed) and shows a message box.
- Log location: `%APPDATA%\Quili\debug.log` vs `~/Library/Logs/Quili/debug.log`.

## Practical notes

- `mac/build.sh` signs with the self-signed "Quili Dev" certificate when it exists in the keychain (create it once with `mac/make-signing-cert.sh`), otherwise ad-hoc. With an ad-hoc signature macOS forgets the Accessibility permission after every rebuild: remove and re-add `dist/mac/Quili.app` in System Settings → Privacy & Security → Accessibility. Never commit `.p12` / `.pem` / `.key` files.
- `dist/` is build output and is not tracked.
- The version comes from the `VERSION` file; both build scripts stamp it into the app.
- Don't commit unless asked.

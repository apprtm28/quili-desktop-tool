import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let tracker = FocusTracker()
    private let overlay = OverlayWindow()
    private lazy var settingsWindow = SettingsWindow(settings: settings)
    private var statusItem: NSStatusItem?
    private var current: TextTarget?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusItem()

        // Accessibility permission is required to read other apps' fields and to send Cmd+V.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)

        overlay.onClick = { [weak self] in Task { await self?.paraphrase() } }
        tracker.onChange = { [weak self] target in self?.targetChanged(target) }
        tracker.start()

        if settings.apiKey.isEmpty || settings.serverUrl.isEmpty { settingsWindow.show() }
    }

    private func targetChanged(_ target: TextTarget?) {
        // Keep the button where it is while a request is running; the result is validated afterwards.
        if overlay.isBusy { return }
        current = target
        if let target { overlay.show(at: target.frame) } else { overlay.hide() }
    }

    private func paraphrase() async {
        guard let target = current, !overlay.isBusy else { return }
        overlay.setBusy(true)
        defer { overlay.setBusy(false) }

        do {
            let field = await TextAccess.read(target.element)
            DebugLog.write("read \(field.text.count) chars (selection=\(field.isSelection))")
            guard !field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                notify("Nothing to paraphrase", "The text field is empty.")
                return
            }

            let result = try await ParaphraseClient.paraphrase(field.text, settings: settings)

            guard FocusTracker.stillFocused(target.element) else {
                TextAccess.setPasteboard(result)
                notify("Focus changed", "Paraphrased text was copied to the clipboard instead.")
                return
            }
            try await TextAccess.replace(field, in: target.element, with: result)
            DebugLog.write("field replaced")
        } catch {
            DebugLog.write("paraphrase failed: \(error.localizedDescription)")
            notify("Paraphrase failed", error.localizedDescription)
        }
    }

    // MARK: - UI

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "✦"
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        let pause = menu.addItem(withTitle: "Pause", action: #selector(togglePause(_:)), keyEquivalent: "")
        pause.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    /// An accessory app has no menu bar, but the Edit menu's key equivalents are what make Cmd+V work in Settings.
    private func buildMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    @objc private func openSettings() { settingsWindow.show() }

    @objc private func togglePause(_ sender: NSMenuItem) {
        tracker.paused.toggle()
        sender.state = tracker.paused ? .on : .off
        if tracker.paused { overlay.hide() }
    }

    private func notify(_ title: String, _ message: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(message))\" with title \"\(esc(title))\""]
        try? p.run()
    }
}

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Owns the app lifecycle and the menu-bar UI; the paraphrase behavior lives in `ParaphraseController`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private lazy var controller = ParaphraseController(settings: settings)
    private lazy var settingsWindow = SettingsWindow(settings: settings)
    private var statusItem: NSStatusItem?
    private var selectionHotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance at a time (the Windows app holds a named mutex for this).
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != NSRunningApplication.current }) {
            NSApp.terminate(nil)
            return
        }

        buildMainMenu()
        buildStatusItem()

        // Accessibility permission is required to read other apps' fields and to send Cmd+V.
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        DebugLog.write("started \(AppInfo.version); accessibility \(trusted ? "granted" : "NOT granted (System Settings → Privacy & Security → Accessibility)")")

        if settings.mockMode { Task { _ = try? await MockServer.shared.start() } }

        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        controller.start()
        // ⌃⌥H: ask Hermes about the selected text in any app (macOS-only fork).
        selectionHotKey = HotKey(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.controller.askHermesAboutSelection()
        }

        if !settings.useOpencode, settings.apiKey.isEmpty || settings.serverUrl.isEmpty { settingsWindow.show() }
    }

    // MARK: - Menus

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The robot icon from the app bundle; plain text when running outside a bundle (e.g. `swift run`).
        if Bundle.main.bundlePath.hasSuffix(".app"), let icon = NSApp.applicationIconImage?.copy() as? NSImage {
            icon.size = NSSize(width: 18, height: 18)
            item.button?.image = icon
        } else {
            item.button?.title = "✦"
        }
        item.button?.toolTip = "Quili \(AppInfo.version)"
        let menu = NSMenu()
        let ask = menu.addItem(withTitle: "Ask Hermes about selection", action: #selector(askAboutSelection), keyEquivalent: "h")
        ask.keyEquivalentModifierMask = [.control, .option]
        ask.target = self
        let history = menu.addItem(withTitle: "Recent Hermes conversations", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu(title: "Recent Hermes conversations")
        historyMenu.delegate = self // filled each time it opens
        history.submenu = historyMenu
        menu.addItem(.separator())
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

    /// From the menu the frontmost app is still the one with the selection (an accessory app doesn't activate).
    @objc private func askAboutSelection() { controller.askHermesAboutSelection() }

    /// The history submenu: the stored conversations, newest first, each with its kind, time, and whether a note was saved.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Recent Hermes conversations" else { return }
        menu.removeAllItems()
        let recent = HermesSessions.shared.recent()
        guard !recent.isEmpty else {
            menu.addItem(withTitle: "No conversations yet", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        let when = DateFormatter()
        when.dateFormat = "d MMM HH:mm"
        for source in recent {
            var title = source.title.hasPrefix("quili: ") ? String(source.title.dropFirst(7)) : source.title
            if title.count > 60 { title = String(title.prefix(59)) + "…" }
            let item = menu.addItem(withTitle: title, action: #selector(openHistory(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = source.key
            let detail = "\(source.kind.rawValue) · \(when.string(from: source.updated))\(source.savedNote != nil ? " · note saved" : "")"
            let text = NSMutableAttributedString(string: title + "\n", attributes: [.font: NSFont.menuFont(ofSize: 13)])
            text.append(NSAttributedString(string: detail, attributes: [.font: NSFont.menuFont(ofSize: 11),
                                                                       .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = text
        }
    }

    @objc private func openHistory(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let anchor = statusItem?.button?.window?.frame ?? NSRect(x: NSScreen.main?.visibleFrame.maxX ?? 800, y: NSScreen.main?.visibleFrame.maxY ?? 800, width: 1, height: 1)
        controller.openHermesHistory(key, near: anchor)
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        controller.paused.toggle()
        sender.state = controller.paused ? .on : .off
    }
}

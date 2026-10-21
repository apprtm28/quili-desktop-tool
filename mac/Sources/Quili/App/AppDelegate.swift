import AppKit
import ApplicationServices

/// Owns the app lifecycle and the menu-bar UI; the paraphrase behavior lives in `ParaphraseController`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private lazy var controller = ParaphraseController(settings: settings)
    private lazy var settingsWindow = SettingsWindow(settings: settings)
    private var statusItem: NSStatusItem?

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

        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        controller.start()

        if settings.apiKey.isEmpty || settings.serverUrl.isEmpty { settingsWindow.show() }
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
        controller.paused.toggle()
        sender.state = controller.paused ? .on : .off
    }
}

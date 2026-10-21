import AppKit

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let settings: Settings
    private let window: NSWindow
    private let server = NSTextField()
    private let key = NSSecureTextField()
    private let style = NSTextField()
    private let styleHint: NSTextField = {
        let hint = NSTextField(wrappingLabelWithString:
            "Sent to the AI as the command for every paraphrase. Examples: Make it more formal · Shorter and punchier · Friendly and casual · Translate to English · Make it 3 bullet points")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 408
        return hint
    }()
    private let startup = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private let repoLink: NSTextField = {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let text = NSMutableAttributedString(string: "Repository: ",
                                             attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        text.append(NSAttributedString(string: "github.com/ferdinandimas/desktop-tools",
                                       attributes: [.font: font, .link: URL(string: AppInfo.repoUrl)!]))
        let field = NSTextField(labelWithAttributedString: text)
        field.allowsEditingTextAttributes = true
        field.isSelectable = true
        return field
    }()

    init(settings: Settings) {
        self.settings = settings
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Paraphrase Tool – Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let versionLabel = NSTextField(labelWithString: "Version \(AppInfo.version)")
        versionLabel.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [versionLabel, NSView(), cancel, save])
        footer.spacing = 8
        footer.widthAnchor.constraint(equalToConstant: 408).isActive = true

        let stack = NSStackView(views: [
            label("Server URL"), server, label("API key"), key, label("Paraphrase instruction"), styleHint, style, startup, repoLink, footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.setCustomSpacing(14, after: server)
        stack.setCustomSpacing(14, after: key)
        stack.setCustomSpacing(14, after: style)
        stack.setCustomSpacing(4, after: styleHint)
        stack.setCustomSpacing(8, after: startup)
        stack.setCustomSpacing(16, after: repoLink)
        for field in [server, key, style] { field.widthAnchor.constraint(equalToConstant: 408).isActive = true }

        window.contentView = stack
        window.setContentSize(stack.fittingSize)
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return l
    }

    func show() {
        server.stringValue = settings.serverUrl
        key.stringValue = settings.apiKey
        style.stringValue = settings.style
        startup.state = settings.runAtStartup ? .on : .off
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func saveClicked() {
        settings.apiKey = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.serverUrl = ParaphraseClient.normalize(server.stringValue)
        settings.style = style.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.runAtStartup = startup.state == .on
        window.close()
    }

    @objc private func cancelClicked() { window.close() }
}

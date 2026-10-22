import AppKit

// The Settings card mirrors windows/src/UI/SettingsWindow.xaml: a borderless rounded card with a green header,
// icon badges, pill-shaped fields and buttons. Sizes and colours are the XAML's.

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A view that reacts to hover, press and click. Subclasses draw themselves from `hovered` / `pressed`.
private class ClickView: NSView {
    var onClick: (() -> Void)?
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
    /// The clickable area; defaults to the whole view.
    var hitRect: NSRect { bounds }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { hitRect.contains(convert(point, from: superview)) ? self : nil }
    override func resetCursorRects() { addCursorRect(hitRect, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = hitRect.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onClick?() }
    }
}

/// The round tinted badge in front of each section title.
private final class BadgeView: NSView {
    private let path: NSBezierPath
    init(_ path: NSBezierPath) {
        self.path = path
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        Brand.greenTint.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        Glyph.fill(path, in: bounds.insetBy(dx: 8.5, dy: 8.5), color: Brand.greenInk)
    }
}

/// The green round robot badge in the header.
private final class RobotBadge: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Brand.green.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        Glyph.drawRobot(in: bounds.insetBy(dx: 11, dy: 11))
    }
}

/// A flat glyph button with a soft round highlight on hover (the XAML's IconButton).
private final class IconButton: ClickView {
    var path: NSBezierPath { didSet { needsDisplay = true } }
    private let glyphSize: CGFloat, color: NSColor
    init(path: NSBezierPath, side: CGFloat, glyph: CGFloat, color: NSColor) {
        self.path = path; glyphSize = glyph; self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            Brand.hex(0x000000, alpha: 0.10).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
        }
        Glyph.fill(path, in: NSRect(x: bounds.midX - glyphSize / 2, y: bounds.midY - glyphSize / 2, width: glyphSize, height: glyphSize),
                   color: color)
    }
}

/// The Save (green, with a glow) and Cancel (white, outlined) buttons. The view is larger than the button so the
/// glow has room; only the button itself is clickable.
private final class PillButton: ClickView {
    static let glow: CGFloat = 24
    private let title: String, primary: Bool
    private var visual: NSRect { bounds.insetBy(dx: Self.glow, dy: Self.glow) }
    override var hitRect: NSRect { visual }

    init(title: String, primary: Bool, size: NSSize) {
        self.title = title; self.primary = primary
        super.init(frame: NSRect(x: 0, y: 0, width: size.width + 2 * Self.glow, height: size.height + 2 * Self.glow))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = visual
        let shape = NSBezierPath(roundedRect: rect, xRadius: min(24, rect.height / 2), yRadius: min(24, rect.height / 2))
        let text: NSColor
        if primary {
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = Brand.greenDeep.withAlphaComponent(0.35)
            glow.shadowBlurRadius = 14
            glow.shadowOffset = NSSize(width: 0, height: -4)
            glow.set()
            (pressed ? Brand.hex(0x198A3A) : hovered ? Brand.hex(0x1F9E43) : Brand.greenDeep).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            text = .white
        } else {
            (pressed ? Brand.hex(0xE6ECE8) : hovered ? Brand.hex(0xF1F5F2) : NSColor.white).setFill()
            shape.fill()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: min(24, rect.height / 2), yRadius: min(24, rect.height / 2))
            border.lineWidth = 1.5
            Brand.line.setStroke()
            border.stroke()
            text = Brand.ink
        }

        let label = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: text,
        ])
        let size = label.size()
        let iconWidth: CGFloat = primary ? 18 + 12 : 0
        var x = rect.midX - (iconWidth + size.width) / 2
        if primary {
            Glyph.fill(Glyph.save, in: NSRect(x: x, y: rect.midY - 9, width: 18, height: 18), color: .white)
            x += iconWidth
        }
        label.draw(at: NSPoint(x: x, y: rect.midY - size.height / 2))
    }
}

/// The "Start at login" row: a rounded green box with a tick, then the label.
private final class CheckRow: ClickView {
    var checked = false { didSet { needsDisplay = true } }
    private let title: NSAttributedString

    init(title: String) {
        self.title = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: Brand.ink,
        ])
        super.init(frame: NSRect(x: 0, y: 0, width: 26 + 14 + self.title.size().width + 4, height: 26))
        onClick = { [weak self] in self?.checked.toggle() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 0, y: (bounds.height - 26) / 2, width: 26, height: 26)
        let shape = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: 8, yRadius: 8)
        (checked ? Brand.greenDeep : NSColor.white).setFill()
        shape.fill()
        shape.lineWidth = 1.5
        (checked || hovered ? Brand.greenDeep : Brand.hex(0xB5C0B9)).setStroke()
        shape.stroke()
        if checked {
            Glyph.fill(Glyph.check, in: NSRect(x: box.midX - 8, y: box.midY - 8, width: 16, height: 16), color: .white)
        }
        title.draw(at: NSPoint(x: 26 + 14, y: (bounds.height - title.size().height) / 2))
    }
}

/// The repository hyperlink.
private final class LinkView: ClickView {
    private let text: NSAttributedString
    init(title: String) {
        text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: Brand.greenInk,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        super.init(frame: NSRect(x: 0, y: 0, width: text.size().width + 1, height: text.size().height))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { text.draw(at: .zero) }
}

/// The rounded input frame; the text control inside is drawn bare. The border turns green while focused.
private final class FieldFrame: NSView {
    var focused = false { didSet { if focused != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 22, yRadius: 22)
        NSColor.white.setFill()
        shape.fill()
        shape.lineWidth = 1.5
        (focused ? Brand.green : Brand.line).setStroke()
        shape.stroke()
    }
}

/// The header strip: a soft green gradient that also drags the borderless window.
private final class HeaderView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(rect: bounds).addClip() // layer-backed views don't clip their own drawing
        NSGradient(starting: Brand.hex(0xE7F5EC), ending: Brand.hex(0xF3FAF6))?
            .draw(from: .zero, to: NSPoint(x: bounds.width, y: bounds.height), options: [])
    }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

private final class SettingsPanel: NSWindow {
    var fieldFrames: [FieldFrame] = []
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        let focus = firstResponder as? NSView
        for frame in fieldFrames { frame.focused = focus?.isDescendant(of: frame) ?? false }
        return accepted
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class SettingsWindow: NSObject, NSTextViewDelegate {
    private let settings: Settings
    private let window: SettingsPanel
    private let server = NSTextField()
    private let keySecure = NSSecureTextField()
    private let keyPlain = NSTextField()
    private let eye = IconButton(path: Glyph.eyeOff, side: 32, glyph: 19, color: Brand.hex(0x55625B))
    private let styleView = NSTextView()
    private let startup = CheckRow(title: "Start at login")
    private let mock = CheckRow(title: "Mock server (offline)")
    private let logging = CheckRow(title: "Write debug log")
    private var revealed = false

    init(settings: Settings) {
        self.settings = settings

        let width: CGFloat = 520, pad: CGFloat = 28, inner: CGFloat = 464, labelX: CGFloat = 76, fieldWidth: CGFloat = 416

        func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: size, weight: weight)
            l.textColor = color
            l.sizeToFit()
            return l
        }
        func bare(_ field: NSTextField) {
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .systemFont(ofSize: 15)
            field.textColor = Brand.ink
            field.cell?.isScrollable = true
            field.cell?.usesSingleLineMode = true
            field.cell?.lineBreakMode = .byClipping
        }

        let content = FlippedView(frame: .zero)
        var frames: [FieldFrame] = []

        // Header: 90 tall.
        let header = HeaderView(frame: NSRect(x: 0, y: 0, width: width, height: 90))
        let robot = RobotBadge(frame: NSRect(x: pad, y: 20, width: 50, height: 50))
        let title = label("Quili", size: 23, weight: .bold, color: Brand.ink)
        let subtitle = label("Settings", size: 15, color: Brand.muted)
        let titleTop = 20 + (50 - (title.frame.height + subtitle.frame.height)) / 2
        title.setFrameOrigin(NSPoint(x: pad + 50 + 16, y: titleTop))
        subtitle.setFrameOrigin(NSPoint(x: pad + 50 + 16, y: titleTop + title.frame.height))
        let close = IconButton(path: Glyph.close, side: 34, glyph: 14, color: Brand.hex(0x44514A))
        close.frame.origin = NSPoint(x: width - 18 - 34, y: 20)
        [robot, title, subtitle, close].forEach(header.addSubview)
        content.addSubview(header)

        var y: CGFloat = 90 + 24

        /// A badge and its title in one row; returns the row's bottom.
        func sectionRow(_ path: NSBezierPath, _ text: String) -> CGFloat {
            let badge = BadgeView(path)
            badge.frame.origin = NSPoint(x: pad, y: y)
            let l = label(text, size: 17, weight: .semibold, color: Brand.ink)
            l.setFrameOrigin(NSPoint(x: labelX, y: y + (34 - l.frame.height) / 2))
            content.addSubview(badge); content.addSubview(l)
            return y + 34
        }
        func frame(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> FieldFrame {
            let f = FieldFrame(frame: NSRect(x: x, y: y, width: width, height: height))
            frames.append(f)
            content.addSubview(f)
            return f
        }

        // Server URL
        y = sectionRow(Glyph.link, "Server URL") + 10
        let serverFrame = frame(x: labelX, y: y, width: fieldWidth, height: 46)
        bare(server)
        server.frame = NSRect(x: 18, y: 0, width: fieldWidth - 36, height: 20)
        server.frame.origin.y = (46 - server.frame.height) / 2
        serverFrame.addSubview(server)
        y += 46 + 22

        // API key
        y = sectionRow(Glyph.key, "API key") + 10
        let keyFrame = frame(x: labelX, y: y, width: fieldWidth, height: 46)
        let keyWidth = fieldWidth - 18 - 8 - 32 - 3
        for field in [keySecure, keyPlain] {
            bare(field)
            field.frame = NSRect(x: 18, y: (46 - 20) / 2, width: keyWidth, height: 20)
            keyFrame.addSubview(field)
        }
        keyPlain.isHidden = true
        eye.frame.origin = NSPoint(x: fieldWidth - 8 - 32 - 1.5, y: (46 - 32) / 2)
        keyFrame.addSubview(eye)
        y += 46 + 22

        // Paraphrase instruction
        let docBadge = BadgeView(Glyph.doc)
        docBadge.frame.origin = NSPoint(x: pad, y: y)
        let docTitle = label("Paraphrase instruction", size: 17, weight: .semibold, color: Brand.ink)
        docTitle.setFrameOrigin(NSPoint(x: labelX, y: y + 3))
        let hint = NSTextField(wrappingLabelWithString:
            "Sent to the AI as the command for every paraphrase. Examples: Make it more formal · Shorter and punchier · Friendly and casual · Translate to English · Make it 3 bullet points")
        hint.font = .systemFont(ofSize: 13.5)
        hint.textColor = Brand.muted
        let hintHeight = ceil(hint.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: fieldWidth, height: 10_000)).height ?? 36)
        hint.frame = NSRect(x: labelX, y: y + 3 + docTitle.frame.height + 4, width: fieldWidth, height: hintHeight)
        [docBadge, docTitle, hint].forEach(content.addSubview)
        y = max(y + 34, hint.frame.maxY) + 12

        let styleFrame = frame(x: pad, y: y, width: inner, height: 148)
        let scroll = NSScrollView(frame: NSRect(x: 18, y: 12, width: inner - 18 - 10, height: 124))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        styleView.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 124)
        styleView.minSize = NSSize(width: 0, height: 124)
        styleView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        styleView.isVerticallyResizable = true
        styleView.isHorizontallyResizable = false
        styleView.autoresizingMask = [.width]
        styleView.textContainer?.widthTracksTextView = true
        styleView.textContainer?.lineFragmentPadding = 0
        styleView.textContainerInset = .zero
        styleView.isRichText = false
        styleView.allowsUndo = true
        styleView.drawsBackground = false
        styleView.font = .systemFont(ofSize: 15)
        styleView.textColor = Brand.ink
        styleView.insertionPointColor = Brand.ink
        styleView.isAutomaticQuoteSubstitutionEnabled = false
        styleView.isAutomaticDashSubstitutionEnabled = false
        scroll.documentView = styleView
        styleFrame.addSubview(scroll)
        y += 148 + 20

        // Start at login
        startup.frame.origin = NSPoint(x: pad + 2, y: y)
        content.addSubview(startup)
        y += 26 + 16

        // Mock server
        mock.frame.origin = NSPoint(x: pad + 2, y: y)
        content.addSubview(mock)
        y += 26 + 16

        // Debug log
        logging.frame.origin = NSPoint(x: pad + 2, y: y)
        content.addSubview(logging)
        y += 26 + 16

        // Repository
        let gitBadge = BadgeView(Glyph.github)
        gitBadge.frame.origin = NSPoint(x: pad, y: y)
        let repoLabel = label("Repository", size: 15, color: Brand.muted)
        repoLabel.setFrameOrigin(NSPoint(x: labelX, y: y + (34 - repoLabel.frame.height) / 2))
        let link = LinkView(title: "github.com/ferdinandimas/quili-desktop-tool")
        link.setFrameOrigin(NSPoint(x: repoLabel.frame.maxX + 18, y: y + (34 - link.frame.height) / 2))
        let openIcon = GlyphLabel(path: Glyph.openNew, color: Brand.greenInk, side: 14)
        openIcon.frame.origin = NSPoint(x: link.frame.maxX + 8, y: y + 10)
        [gitBadge, repoLabel, link, openIcon].forEach(content.addSubview)
        y += 34 + 22

        // Divider and footer
        let divider = NSView(frame: NSRect(x: pad, y: y, width: inner, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Brand.hex(0xE6ECE8).cgColor
        content.addSubview(divider)
        y += 1 + 18

        let version = label("Version \(AppInfo.version)", size: 14, color: Brand.muted)
        version.setFrameOrigin(NSPoint(x: pad, y: y + (46 - version.frame.height) / 2))
        content.addSubview(version)
        let cancelButton = PillButton(title: "Cancel", primary: false, size: NSSize(width: 108, height: 46))
        let saveButton = PillButton(title: "Save", primary: true, size: NSSize(width: 150, height: 46))
        let glow = PillButton.glow
        cancelButton.frame.origin = NSPoint(x: pad + inner - 108 - glow, y: y - glow)
        saveButton.frame.origin = NSPoint(x: pad + inner - 108 - 12 - 150 - glow, y: y - glow)
        content.addSubview(saveButton); content.addSubview(cancelButton)
        y += 46 + 22

        // The card, with its soft green shadow, inside a transparent window with room for it.
        let cardHeight = y
        let margin: CGFloat = 30
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width + 2 * margin, height: cardHeight + 2 * margin))
        let card = NSView(frame: NSRect(x: margin, y: margin, width: width, height: cardHeight))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 26
        card.layer?.shadowColor = Brand.greenInk.cgColor
        card.layer?.shadowOpacity = 0.20
        card.layer?.shadowRadius = 16
        card.layer?.shadowOffset = CGSize(width: 0, height: -8)
        content.frame = card.bounds
        content.wantsLayer = true
        content.layer?.cornerRadius = 26
        content.layer?.masksToBounds = true
        card.addSubview(content)
        root.addSubview(card)

        window = SettingsPanel(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = root
        window.title = "Quili – Settings"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.fieldFrames = frames
        super.init()

        window.onCancel = { [weak self] in self?.window.close() }
        close.onClick = { [weak self] in self?.window.close() }
        cancelButton.onClick = { [weak self] in self?.window.close() }
        saveButton.onClick = { [weak self] in self?.save() }
        eye.onClick = { [weak self] in self?.toggleKey() }
        link.onClick = { NSWorkspace.shared.open(URL(string: AppInfo.repoUrl)!) }
        for field in [server, keySecure, keyPlain] { field.target = self; field.action = #selector(saveFromReturn) }
        styleView.delegate = self
    }

    func show() {
        server.stringValue = settings.serverUrl
        let key = settings.apiKey
        keySecure.stringValue = key
        keyPlain.stringValue = key
        setKeyRevealed(false)
        styleView.string = settings.style
        startup.checked = settings.runAtStartup
        mock.checked = settings.mockMode
        logging.checked = settings.loggingEnabled
        window.center()
        // Opened from the overlay, the app isn't frontmost: raise the window above everything and focus it.
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        _ = window.makeFirstResponder(server)
    }

    /// Switches the API key between dots and plain text, carrying what was typed across.
    private func toggleKey() { setKeyRevealed(!revealed, focus: true) }

    private func setKeyRevealed(_ reveal: Bool, focus: Bool = false) {
        if reveal != revealed {
            if reveal { keyPlain.stringValue = keySecure.stringValue } else { keySecure.stringValue = keyPlain.stringValue }
        }
        revealed = reveal
        keyPlain.isHidden = !reveal
        keySecure.isHidden = reveal
        eye.path = reveal ? Glyph.eye : Glyph.eyeOff
        guard focus else { return }
        let field = reveal ? keyPlain : keySecure
        _ = window.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
    }

    @objc private func saveFromReturn() { save() }

    private func save() {
        let key = revealed ? keyPlain.stringValue : keySecure.stringValue
        settings.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.serverUrl = ParaphraseClient.normalize(server.stringValue)
        settings.style = styleView.string.trimmingCharacters(in: .whitespacesAndNewlines) // empty falls back to the default
        settings.runAtStartup = startup.checked
        applyMock(mock.checked)
        applyLogging(logging.checked)
        window.close()
    }

    /// Turns the debug log on or off, leaving a note in the log either way (the last line before it goes quiet).
    private func applyLogging(_ on: Bool) {
        guard on != settings.loggingEnabled else { return }
        if !on { DebugLog.write("debug log turned off in Settings") }
        settings.loggingEnabled = on
        if on { DebugLog.write("debug log turned on in Settings") }
    }

    /// Turns the built-in mock server on (and starts it) or off (and stops it).
    private func applyMock(_ on: Bool) {
        settings.mockMode = on
        guard on else { MockServer.shared.stop(); return }
        Task {
            do { _ = try await MockServer.shared.start() }
            catch {
                self.settings.mockMode = false
                DebugLog.write("mock server failed to start: \(error)")
                Notifier.show("Mock server failed", error.localizedDescription)
            }
        }
    }

    // The instruction box is capped like the XAML's MaxLength: typing stops at the limit and a long paste is cut.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard let text else { return true }
        let current = textView.string as NSString
        let room = Settings.maxStyleLength - (current.length - range.length)
        if (text as NSString).length <= room { return true }
        // Cut on a character boundary so a long paste never ends in half an emoji.
        let pasted = text as NSString
        var cut = max(room, 0)
        if cut > 0, cut < pasted.length {
            let sequence = pasted.rangeOfComposedCharacterSequence(at: cut)
            if sequence.location < cut { cut = sequence.location }
        }
        if cut > 0 { textView.insertText(pasted.substring(to: cut), replacementRange: range) }
        return false
    }
}

/// A small fixed-colour glyph (the open-in-new mark next to the repository link).
private final class GlyphLabel: NSView {
    private let path: NSBezierPath, color: NSColor
    init(path: NSBezierPath, color: NSColor, side: CGFloat) {
        self.path = path; self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { Glyph.fill(path, in: bounds, color: color) }
}

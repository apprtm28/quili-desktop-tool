import AppKit

/// A button in the conversation bubble's action row.
struct ConversationAction {
    let id: String
    let title: String
    var primary = false
}

/// One message of a collected range in the pick list.
struct PickItem {
    let header: String
    let preview: String
    var included: Bool
}

enum ConversationBody {
    /// A single status line ("Reading the thread…").
    case message(String)
    /// The conversation so far, plus Hermes' reply while it is being written.
    case transcript([HermesSource.Entry], streaming: String?)
    /// Messages collected from a channel, each with a tick box.
    case pick([PickItem])
    /// An editable note draft and where it will be saved.
    case draft(text: String, target: String)
}

struct ConversationState {
    var title: String
    /// Small text at the top right: "Hermes · 14 s", "Thinking… 8 s".
    var status: String?
    /// The coverage line (Q8), in amber.
    var notice: String?
    /// Something that needs attention (a failure, the write guard), in red.
    var alert: String?
    var body: ConversationBody
    var actions: [ConversationAction] = []
    /// The Ask row's placeholder; nil hides the row.
    var askPlaceholder: String?
    /// A request is running: the Ask row is disabled meanwhile.
    var busy = false
    /// The Ask box holds longer text being edited (a ⌃⌥H selection): it may grow taller.
    var largeAsk = false
}

// MARK: - Pieces

private enum Style {
    static let width: CGFloat = 440, maxHeight: CGFloat = 560, pad: CGFloat = 14
    static let minSize = NSSize(width: 340, height: 220)
    static let body = NSFont.systemFont(ofSize: 13)
    static let bold = NSFont.boldSystemFont(ofSize: 13)
    static let small = NSFont.systemFont(ofSize: 11.5)
    static let label = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let amber = Brand.hex(0xB26A00)

    static func paragraph(spacing: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 18
        style.maximumLineHeight = 18
        style.paragraphSpacing = spacing
        return style
    }

    /// Text with `**bold**` drawn bold and the markers hidden; an unclosed `**` (still streaming) stays bold to the end.
    static func markdown(_ text: String, color: NSColor = Brand.robotInk) -> NSAttributedString {
        let plain: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: color, .paragraphStyle: paragraph()]
        var strong = plain
        strong[.font] = bold
        let result = NSMutableAttributedString()
        var isBold = false
        for (index, piece) in text.components(separatedBy: "**").enumerated() {
            if index > 0 { isBold.toggle() }
            result.append(NSAttributedString(string: piece, attributes: isBold ? strong : plain))
        }
        return result
    }

    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height)
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Hover / press / click, drawn by subclasses.
private class Clickable: NSView {
    var onClick: (() -> Void)?
    var enabled = true { didSet { needsDisplay = true } }
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }
    override func mouseDown(with event: NSEvent) { if enabled { pressed = true } }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside, enabled { onClick?() }
    }
}

/// The small pill buttons of the action row: green for the main action, outlined white for the others.
private final class Pill: Clickable {
    static let height: CGFloat = 26
    private let title: NSAttributedString
    private let primary: Bool

    init(_ action: ConversationAction) {
        primary = action.primary
        title = NSAttributedString(string: action.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: primary ? NSColor.white : Brand.ink,
        ])
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(title.size().width) + 24, height: Self.height))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.height / 2, yRadius: Self.height / 2)
        if primary {
            (pressed ? Brand.hex(0x198A3A) : hovered ? Brand.hex(0x1F9E43) : Brand.greenDeep).setFill()
            shape.fill()
        } else {
            (pressed ? Brand.hex(0xE6ECE8) : hovered ? Brand.hex(0xF1F5F2) : NSColor.white).setFill()
            shape.fill()
            shape.lineWidth = 1
            Brand.line.setStroke()
            shape.stroke()
        }
        let size = title.size()
        title.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// The × at the top right.
private final class CloseButton: Clickable {
    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            Brand.hex(0x000000, alpha: 0.07).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        let x = bounds.insetBy(dx: 6.5, dy: 6.5)
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: x.minX, y: x.minY)); cross.line(to: NSPoint(x: x.maxX, y: x.maxY))
        cross.move(to: NSPoint(x: x.maxX, y: x.minY)); cross.line(to: NSPoint(x: x.minX, y: x.maxY))
        cross.lineWidth = 1.6
        cross.lineCapStyle = .round
        Brand.muted.setStroke()
        cross.stroke()
    }
}

/// The green round sparkle in front of the title, like the Summarize button.
private final class SparkleDot: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Brand.greenDeep.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        Glyph.fill(Glyph.sparkle, in: bounds.insetBy(dx: 4, dy: 4), color: .white)
    }
}

/// One row of the pick list: a tick box, the message header and its first line.
private final class PickRow: Clickable {
    static let height: CGFloat = 40
    var included: Bool { didSet { needsDisplay = true } }
    private let header: NSAttributedString, preview: NSAttributedString

    init(_ item: PickItem, width: CGFloat) {
        included = item.included
        header = NSAttributedString(string: item.header, attributes: [.font: Style.label, .foregroundColor: Brand.ink])
        let line = item.preview.replacingOccurrences(of: "\n", with: " ")
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        preview = NSAttributedString(string: line, attributes: [.font: Style.small, .foregroundColor: Brand.muted, .paragraphStyle: style])
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if hovered { Brand.hex(0xF3FAF6).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
        let box = NSRect(x: 6, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let shape = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
        (included ? Brand.greenDeep : NSColor.white).setFill()
        shape.fill()
        shape.lineWidth = 1.5
        (included ? Brand.greenDeep : Brand.hex(0xB5C0B9)).setStroke()
        shape.stroke()
        if included { Glyph.fillFlipped(Glyph.check, in: box.insetBy(dx: 3, dy: 3), color: .white) }
        let textX = box.maxX + 10, textWidth = bounds.width - textX - 6
        header.draw(with: NSRect(x: textX, y: 4, width: textWidth, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        preview.draw(with: NSRect(x: textX, y: 21, width: textWidth, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// A text control that asks the panel for keyboard focus when clicked (the panel is otherwise never key, so Slack
/// keeps its focus).
/// The Ask box: Return sends, ⌘↩ (or ⇧↩) starts a new line, so pasted context and longer questions fit. It grows
/// to a few lines, then scrolls.
private final class AskTextView: NSTextView {
    var onEngage: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onEngage?()
        super.mouseDown(with: event)
    }

    private static func isReturn(_ event: NSEvent) -> Bool { event.keyCode == 36 || event.keyCode == 76 }

    override func keyDown(with event: NSEvent) {
        guard Self.isReturn(event) else { return super.keyDown(with: event) }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) {
            insertNewlineIgnoringFieldEditor(nil)
        } else {
            onSubmit?()
        }
    }

    // ⌘↩ can arrive as a key equivalent before keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, Self.isReturn(event), event.modifierFlags.contains(.command) {
            insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        NSAttributedString(string: placeholder, attributes: [.font: Style.body, .foregroundColor: Brand.muted])
            .draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height))
    }
}

private final class DraftTextView: NSTextView {
    var onEngage: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onEngage?()
        super.mouseDown(with: event)
    }
}

/// The Ask row: a rounded field with a round green send button, like Settings' fields.
private final class AskFrame: NSView {
    var focused = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let radius = min(18, bounds.height / 2)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
        NSColor.white.setFill()
        shape.fill()
        shape.lineWidth = 1.2
        (focused ? Brand.green : Brand.line).setStroke()
        shape.stroke()
    }
}

private final class SendButton: Clickable {
    override func draw(_ dirtyRect: NSRect) {
        (enabled ? (pressed || hovered ? Brand.greenInk : Brand.greenDeep) : Brand.line).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        // An up arrow.
        let arrow = NSBezierPath()
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        arrow.move(to: NSPoint(x: c.x, y: c.y + 5)); arrow.line(to: NSPoint(x: c.x, y: c.y - 5))
        arrow.move(to: NSPoint(x: c.x - 4, y: c.y - 1)); arrow.line(to: NSPoint(x: c.x, y: c.y - 5)); arrow.line(to: NSPoint(x: c.x + 4, y: c.y - 1))
        arrow.lineWidth = 1.8
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        NSColor.white.setStroke()
        arrow.stroke()
    }
}

/// The header strip: dragging it moves the bubble, double-clicking it puts the bubble back to automatic placement and size.
private final class DragStrip: NSView {
    var onMoved: (() -> Void)?
    var onReset: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?(); return }
        window?.performDrag(with: event)
        onMoved?()
    }
}

/// The resize grip at the bottom-right corner: drags the corner, the top-left stays put.
private final class ResizeGrip: NSView {
    var onResize: ((NSPoint) -> Void)?
    var onDone: (() -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDragged(with event: NSEvent) { onResize?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { onDone?() }
    override func draw(_ dirtyRect: NSRect) {
        let lines = NSBezierPath()
        for offset: CGFloat in [4, 8] {
            lines.move(to: NSPoint(x: bounds.maxX - 3, y: bounds.maxY - 3 - offset))
            lines.line(to: NSPoint(x: bounds.maxX - 3 - offset, y: bounds.maxY - 3))
        }
        lines.lineWidth = 1.2
        lines.lineCapStyle = .round
        Brand.muted.withAlphaComponent(0.7).setStroke()
        lines.stroke()
    }
}

/// Never key unless the Ask row or the draft editor asked for it; Esc hands focus back.
private final class ConversationPanel: NSPanel {
    var wantsKey = false
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { wantsKey }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - Window

/// The summary / conversation bubble (Q6): white rounded card in Quili's style, anchored to the Summarize button or a
/// range chip. Click-through parts stay out of Slack's way; it takes keyboard focus only when the Ask row (or the note
/// editor) is clicked, and Esc gives it back to Slack.
@MainActor
final class ConversationWindow: NSObject, NSTextViewDelegate {
    private static let gap: CGFloat = 6
    private let panel: ConversationPanel
    private let card = FlippedView()
    private let close = CloseButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    private let dot = SparkleDot(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let alertLabel = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let transcript = NSTextView()
    private let draft = DraftTextView()
    private let draftScroll = NSScrollView()
    private let targetLabel = NSTextField(wrappingLabelWithString: "")
    private let pickList = FlippedView()
    private let askFrame = AskFrame()
    private let askField = AskTextView()
    private let askScroll = NSScrollView()
    private let send = SendButton(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
    private var pills: [Pill] = []
    private var rows: [PickRow] = []
    private var anchor: NSRect = .zero
    private var state: ConversationState?
    /// Placed against the anchor (or where the user put it) only when shown; later updates keep it where it is, so it
    /// doesn't jump while being dragged or while Hermes writes.
    private var placeOnLayout = true
    private let dragStrip = DragStrip()
    private let grip = ResizeGrip(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    /// Where and how big the user made the bubble (top-left in Cocoa screen coordinates); nil = automatic. Remembered.
    private var userTopLeft: NSPoint? = UserDefaults.standard.string(forKey: "conversationTopLeft").map(NSPointFromString)
    private var userSize: NSSize? = UserDefaults.standard.string(forKey: "conversationSize").map(NSSizeFromString)
    private var fadeID = 0
    private var previousApp: NSRunningApplication?

    var onAction: ((String) -> Void)?
    var onAsk: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onPickToggle: ((Int, Bool) -> Void)?

    var isVisible: Bool { panel.isVisible }
    /// The note draft as edited in the bubble.
    var draftText: String { draft.string }

    override init() {
        panel = ConversationPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.onEscape = { [weak self] in self?.releaseFocus() }

        let root = FlippedView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        card.layer?.masksToBounds = true
        root.addSubview(card)
        panel.contentView = root

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = Brand.ink
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = Style.small
        statusLabel.textColor = Brand.muted
        statusLabel.alignment = .right
        for (label, color) in [(noticeLabel, Style.amber), (alertLabel, Brand.red), (targetLabel, Brand.muted)] {
            label.font = Style.small
            label.textColor = color
        }

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.textContainerInset = .zero
        transcript.textContainer?.lineFragmentPadding = 0
        transcript.textContainer?.widthTracksTextView = true
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]
        configure(scroll, document: transcript)

        draft.isRichText = false
        draft.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        draft.textColor = Brand.ink
        draft.drawsBackground = false
        draft.allowsUndo = true
        draft.textContainerInset = NSSize(width: 4, height: 6)
        draft.textContainer?.widthTracksTextView = true
        draft.isVerticallyResizable = true
        draft.autoresizingMask = [.width]
        draft.isAutomaticQuoteSubstitutionEnabled = false
        draft.isAutomaticDashSubstitutionEnabled = false
        draft.onEngage = { [weak self] in self?.engage(self?.draft) }
        configure(draftScroll, document: draft)
        draftScroll.wantsLayer = true
        draftScroll.layer?.cornerRadius = 8
        draftScroll.layer?.borderWidth = 1
        draftScroll.layer?.borderColor = Brand.line.cgColor

        askField.isRichText = false
        askField.drawsBackground = false
        askField.font = Style.body
        askField.textColor = Brand.ink
        askField.insertionPointColor = Brand.ink
        askField.textContainerInset = .zero
        askField.textContainer?.lineFragmentPadding = 0
        askField.textContainer?.widthTracksTextView = true
        askField.isVerticallyResizable = true
        askField.isHorizontallyResizable = false
        askField.autoresizingMask = [.width]
        askField.allowsUndo = true
        askField.isAutomaticQuoteSubstitutionEnabled = false
        askField.isAutomaticDashSubstitutionEnabled = false
        askField.delegate = self
        askField.onSubmit = { [weak self] in self?.submit() }
        askField.onEscape = { [weak self] in self?.releaseFocus() }
        askField.onEngage = { [weak self] in self?.engage(self?.askField) }
        configure(askScroll, document: askField)
        askFrame.addSubview(askScroll)
        askFrame.addSubview(send)
        send.onClick = { [weak self] in self?.submit() }
        close.onClick = { [weak self] in self?.onClose?() }

        [dot, titleLabel, statusLabel, dragStrip, close, noticeLabel, alertLabel, scroll, draftScroll, targetLabel, pickList,
         askFrame, grip].forEach(card.addSubview)
        dragStrip.onMoved = { [weak self] in self?.rememberPosition() }
        dragStrip.onReset = { [weak self] in self?.resetPlacement() }
        grip.onResize = { [weak self] point in self?.resize(to: point) }
        grip.onDone = { [weak self] in self?.rememberSize() }
    }

    private func configure(_ scroll: NSScrollView, document: NSTextView) {
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay // the scroller floats over the text instead of narrowing it
        scroll.documentView = document
    }

    // MARK: Showing

    /// Shows `state` next to `anchor` (Cocoa screen coordinates): below it, or above when there is no room.
    func show(_ state: ConversationState, near anchor: NSRect) {
        self.anchor = anchor
        placeOnLayout = true
        apply(state)
    }

    /// Puts `text` in the Ask box with the cursor at its end, and takes keyboard focus so it can be edited right away.
    func prefillAsk(_ text: String) {
        askField.string = text
        layout()
        engage(askField)
        askField.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        askField.scrollToEndOfDocument(nil)
    }

    /// Replaces the content, keeping the anchor.
    func update(_ state: ConversationState) {
        guard panel.isVisible else { return }
        apply(state)
    }

    private func apply(_ state: ConversationState) {
        cancelFade()
        let previousBody = self.state.map { String(describing: $0.body) }
        self.state = state
        titleLabel.stringValue = state.title
        statusLabel.stringValue = state.status ?? ""
        noticeLabel.stringValue = state.notice ?? ""
        alertLabel.stringValue = state.alert ?? ""
        askField.placeholder = (state.askPlaceholder ?? "") + (state.busy ? "" : "  (⌘↩ new line)")
        askField.isEditable = !state.busy
        send.enabled = !state.busy

        pills.forEach { $0.removeFromSuperview() }
        pills = state.actions.map { action in
            let pill = Pill(action)
            pill.onClick = { [weak self] in self?.onAction?(action.id) }
            card.addSubview(pill)
            return pill
        }
        // A new draft replaces the editor's text; an unchanged body keeps the user's edits and scroll position.
        if case .draft(let text, let target) = state.body, previousBody != String(describing: state.body) {
            draft.string = text
            targetLabel.stringValue = "Saves to \(target)"
        }
        if case .pick(let items) = state.body { buildRows(items) } else { rows.forEach { $0.removeFromSuperview() }; rows = [] }
        layout()
    }

    private func buildRows(_ items: [PickItem]) {
        rows.forEach { $0.removeFromSuperview() }
        let width = currentWidth - 2 * Style.pad
        rows = items.enumerated().map { index, item in
            let row = PickRow(item, width: width)
            row.frame.origin.y = CGFloat(index) * PickRow.height
            row.onClick = { [weak self, weak row] in
                guard let row else { return }
                row.included.toggle()
                self?.onPickToggle?(index, row.included)
            }
            pickList.addSubview(row)
            return row
        }
        pickList.frame.size = NSSize(width: width, height: CGFloat(items.count) * PickRow.height)
    }

    /// Lays the card out top to bottom and sizes the panel to fit (scrolling parts take what is left).
    private func layout() {
        guard let state else { return }
        let width = currentWidth, pad = Style.pad, inner = width - 2 * pad
        let screen = (NSScreen.screens.first { $0.frame.contains(userTopLeft ?? NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main)?.visibleFrame ?? .zero
        // A size the user chose is kept exactly; otherwise the bubble fits its content up to 75% of the screen.
        let target = userSize.map { min($0.height, screen.height) } ?? max(Style.maxHeight, screen.height * 0.75)
        var y: CGFloat = 12

        dot.frame.origin = NSPoint(x: pad, y: y)
        close.frame.origin = NSPoint(x: width - 10 - 24, y: y - 2)
        statusLabel.sizeToFit()
        let statusWidth = min(150, statusLabel.frame.width)
        statusLabel.frame = NSRect(x: close.frame.minX - 6 - statusWidth, y: y + 2, width: statusWidth, height: 16)
        titleLabel.frame = NSRect(x: dot.frame.maxX + 8, y: y + 1, width: statusLabel.frame.minX - dot.frame.maxX - 14, height: 18)
        y += 20 + 10

        func wrapped(_ label: NSTextField, _ text: String?) {
            label.isHidden = (text ?? "").isEmpty
            guard !label.isHidden else { return }
            let height = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 1000)).height ?? 16)
            label.frame = NSRect(x: pad, y: y, width: inner, height: height)
            y += height + 6
        }
        wrapped(noticeLabel, state.notice)
        wrapped(alertLabel, state.alert)

        // Fixed parts below the body: the Ask row and the action pills.
        let askBox = askBoxHeight(width: inner, max: state.largeAsk ? max(112, target * 0.45) : 112)
        let askHeight: CGFloat = state.askPlaceholder == nil ? 0 : askBox + 10
        let pillRows = arrangePills(width: inner)
        let pillsHeight = pillRows.isEmpty ? 0 : CGFloat(pillRows.count) * (Pill.height + 6) + 4
        let room = target - y - askHeight - pillsHeight - 12
        let fill = userSize != nil // the body takes all the room the user gave it

        scroll.isHidden = true; draftScroll.isHidden = true; targetLabel.isHidden = true; pickList.isHidden = true
        switch state.body {
        case .message, .transcript:
            let text = attributedBody(state.body)
            // Wrap to the scroll view's visible width, so no line runs past the card's edge.
            scroll.isHidden = false
            scroll.frame = NSRect(x: pad, y: y, width: inner, height: max(18, room))
            let textWidth = scroll.contentSize.width
            transcript.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
            transcript.frame = NSRect(x: 0, y: 0, width: textWidth, height: 18)
            transcript.textStorage?.setAttributedString(text)
            var full = Style.height(of: text, width: textWidth)
            if let manager = transcript.layoutManager, let container = transcript.textContainer {
                manager.ensureLayout(for: container)
                full = ceil(manager.usedRect(for: container).height)
            }
            let height = max(18, fill ? room : min(full, room))
            scroll.frame.size.height = height
            transcript.frame = NSRect(x: 0, y: 0, width: textWidth, height: max(full, height))
            if case .transcript(_, let streaming) = state.body, streaming != nil {
                transcript.scrollToEndOfDocument(nil) // follow the reply as it is written
            }
            y += height + 10
        case .pick:
            let height = fill ? max(PickRow.height * 3, room) : min(pickList.frame.height, max(PickRow.height * 3, room))
            let pickScroll = scrollFor(pickList)
            pickScroll.frame = NSRect(x: pad, y: y, width: inner, height: height)
            pickList.isHidden = false
            y += height + 10
        case .draft:
            targetLabel.isHidden = false
            let targetHeight = ceil(targetLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 100)).height ?? 16)
            targetLabel.frame = NSRect(x: pad, y: y, width: inner, height: targetHeight)
            y += targetHeight + 6
            let height = fill ? room - targetHeight - 6 : min(300, room - targetHeight - 6)
            draftScroll.isHidden = false
            draftScroll.frame = NSRect(x: pad, y: y, width: inner, height: height)
            draft.frame.size.width = inner
            y += height + 10
        }

        askFrame.isHidden = state.askPlaceholder == nil
        if !askFrame.isHidden {
            askFrame.frame = NSRect(x: pad, y: y, width: inner, height: askBox)
            send.frame.origin = NSPoint(x: inner - 5 - 26, y: askBox - 5 - 26)
            askScroll.frame = NSRect(x: 14, y: 9, width: inner - 14 - 36, height: askBox - 18)
            askField.frame.size.width = askScroll.contentSize.width
            y += askBox + 10
        }
        for (index, row) in pillRows.enumerated() {
            for (pill, x) in row { pill.frame.origin = NSPoint(x: pad + x, y: y + CGFloat(index) * (Pill.height + 6)) }
        }
        y += pillsHeight
        let height = y + 4

        // Where the user put it; otherwise against the anchor: below it when there is room, otherwise above.
        let visible = screen
        var x = anchor.maxX - width
        var top = anchor.minY - Self.gap // Cocoa: the panel's top edge
        if top - height < visible.minY { top = anchor.maxY + Self.gap + height }
        if let userTopLeft { x = userTopLeft.x; top = userTopLeft.y }
        if !placeOnLayout, panel.isVisible { x = panel.frame.minX; top = panel.frame.maxY } // stay where it is
        placeOnLayout = false
        x = max(visible.minX, min(x, visible.maxX - width))
        top = max(visible.minY + height, min(top, visible.maxY))
        let margin: CGFloat = 0
        panel.setFrame(NSRect(x: x.rounded(), y: (top - height).rounded(), width: width + margin, height: height), display: true)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        card.frame = NSRect(x: 0, y: 0, width: width, height: height)
        dragStrip.frame = NSRect(x: 0, y: 0, width: close.frame.minX - 4, height: 40)
        grip.frame.origin = NSPoint(x: width - 16, y: height - 16)
        panel.orderFrontRegardless()
    }

    private var currentWidth: CGFloat { max(Style.minSize.width, userSize?.width ?? Style.width) }

    // MARK: Moving and resizing

    private func rememberPosition() {
        userTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        UserDefaults.standard.set(NSStringFromPoint(userTopLeft!), forKey: "conversationTopLeft")
    }

    /// The grip follows the pointer (Cocoa screen coordinates) with the top-left corner fixed.
    private func resize(to point: NSPoint) {
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let visible = (NSScreen.screens.first { $0.frame.contains(topLeft) } ?? NSScreen.main)?.visibleFrame ?? .zero
        userTopLeft = topLeft
        userSize = NSSize(width: min(max(Style.minSize.width, point.x - topLeft.x), visible.width),
                          height: min(max(Style.minSize.height, topLeft.y - point.y), visible.height))
        layout()
    }

    private func rememberSize() {
        guard let userSize, let userTopLeft else { return }
        UserDefaults.standard.set(NSStringFromSize(userSize), forKey: "conversationSize")
        UserDefaults.standard.set(NSStringFromPoint(userTopLeft), forKey: "conversationTopLeft")
    }

    /// Double-click on the header: back to automatic placement next to the button and a size that fits the content.
    private func resetPlacement() {
        userTopLeft = nil
        userSize = nil
        UserDefaults.standard.removeObject(forKey: "conversationTopLeft")
        UserDefaults.standard.removeObject(forKey: "conversationSize")
        placeOnLayout = true
        layout()
    }

    /// The pick list lives in its own scroll view, made on first use.
    private var pickScrollView: NSScrollView?
    private func scrollFor(_ list: NSView) -> NSScrollView {
        if let pickScrollView { pickScrollView.isHidden = false; return pickScrollView }
        let view = NSScrollView()
        view.drawsBackground = false
        view.borderType = .noBorder
        view.hasVerticalScroller = true
        view.autohidesScrollers = true
        view.documentView = list
        card.addSubview(view)
        pickScrollView = view
        return view
    }

    /// The pills in rows that fit `width`, with each pill's x offset.
    private func arrangePills(width: CGFloat) -> [[(Pill, CGFloat)]] {
        pickScrollView?.isHidden = { if case .pick = state?.body { return false }; return true }()
        var rows: [[(Pill, CGFloat)]] = []
        var x: CGFloat = 0
        for pill in pills {
            if rows.isEmpty || x + pill.frame.width > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((pill, x))
            x += pill.frame.width + 6
        }
        return rows
    }

    private func attributedBody(_ body: ConversationBody) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func label(_ text: String, color: NSColor) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 6)])) }
            out.append(NSAttributedString(string: text + "\n", attributes: [.font: Style.label, .foregroundColor: color,
                                                                           .paragraphStyle: Style.paragraph()]))
        }
        switch body {
        case .message(let text):
            out.append(NSAttributedString(string: text, attributes: [.font: Style.body, .foregroundColor: Brand.muted,
                                                                     .paragraphStyle: Style.paragraph()]))
        case .transcript(let entries, let streaming):
            for (index, entry) in entries.enumerated() {
                switch entry.role {
                case .summary:
                    if index > 0 { label("Updated summary", color: Brand.greenInk) }
                    out.append(Style.markdown(entry.text))
                case .question:
                    label("You", color: Brand.greenInk)
                    out.append(Style.markdown(entry.text, color: Brand.ink))
                case .answer:
                    label("Hermes", color: Brand.muted)
                    out.append(Style.markdown(entry.text))
                case .note:
                    label("Saved to work context", color: Brand.greenInk)
                    out.append(NSAttributedString(string: entry.text, attributes: [.font: Style.small, .foregroundColor: Brand.muted]))
                }
            }
            if let streaming {
                if !entries.isEmpty { label("Hermes", color: Brand.muted) }
                out.append(Style.markdown(streaming.isEmpty ? "…" : streaming))
            }
        case .pick, .draft:
            break
        }
        return out
    }

    // MARK: Focus

    /// The Ask row or the editor was clicked: take keyboard focus without activating Quili's other windows.
    private func engage(_ responder: NSResponder?) {
        guard !panel.isKeyWindow else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        panel.wantsKey = true
        panel.makeKey()
        if let responder { panel.makeFirstResponder(responder) }
        askFrame.focused = responder === askField
    }

    /// Esc: hand keyboard focus back to the app that had it (Slack).
    func releaseFocus() {
        guard panel.wantsKey else { return }
        panel.wantsKey = false
        askFrame.focused = false
        panel.makeFirstResponder(nil)
        panel.resignKey()
        previousApp?.activate()
    }

    /// The Ask box's height for its text: one line (36) up to about five, then it scrolls.
    private func askBoxHeight(width: CGFloat, max limit: CGFloat) -> CGFloat {
        let textWidth = width - 14 - 36
        let text = NSAttributedString(string: askField.string.isEmpty ? " " : askField.string + (askField.string.hasSuffix("\n") ? " " : ""),
                                      attributes: [.font: Style.body])
        return min(limit, max(36, Style.height(of: text, width: textWidth) + 18))
    }

    private func submit() {
        let question = askField.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, state?.busy == false else { return }
        askField.string = ""
        layout()
        onAsk?(question)
    }

    func textDidBeginEditing(_ notification: Notification) { askFrame.focused = true }
    func textDidEndEditing(_ notification: Notification) { askFrame.focused = false }
    /// The box grows with its text.
    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === askField else { return }
        layout()
        askField.scrollToEndOfDocument(nil)
    }

    // MARK: Hiding

    func fadeOut() {
        guard panel.isVisible else { return }
        releaseFocus()
        fadeID += 1
        let id = fadeID
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.fadeID == id else { return }
                self.hide()
            }
        })
    }

    private func cancelFade() {
        fadeID += 1
        panel.alphaValue = 1
    }

    func hide() {
        cancelFade()
        releaseFocus()
        state = nil
        panel.orderOut(nil)
    }
}

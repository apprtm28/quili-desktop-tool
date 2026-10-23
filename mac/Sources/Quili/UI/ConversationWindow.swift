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
}

// MARK: - Pieces

private enum Style {
    static let width: CGFloat = 400, maxHeight: CGFloat = 560, pad: CGFloat = 14
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
private final class AskField: NSTextField {
    var onEngage: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onEngage?()
        super.mouseDown(with: event)
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
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
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
final class ConversationWindow: NSObject, NSTextFieldDelegate {
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
    private let askField = AskField()
    private let send = SendButton(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
    private var pills: [Pill] = []
    private var rows: [PickRow] = []
    private var anchor: NSRect = .zero
    private var state: ConversationState?
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

        askField.isBordered = false
        askField.drawsBackground = false
        askField.focusRingType = .none
        askField.font = Style.body
        askField.textColor = Brand.ink
        askField.cell?.isScrollable = true
        askField.cell?.usesSingleLineMode = true
        askField.delegate = self
        askField.target = self
        askField.action = #selector(submit)
        askField.onEngage = { [weak self] in self?.engage(self?.askField) }
        askFrame.addSubview(askField)
        askFrame.addSubview(send)
        send.onClick = { [weak self] in self?.submit() }
        close.onClick = { [weak self] in self?.onClose?() }

        [dot, titleLabel, statusLabel, close, noticeLabel, alertLabel, scroll, draftScroll, targetLabel, pickList, askFrame]
            .forEach(card.addSubview)
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
        apply(state)
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
        askField.placeholderAttributedString = NSAttributedString(string: state.askPlaceholder ?? "",
                                                                  attributes: [.font: Style.body, .foregroundColor: Brand.muted])
        askField.isEnabled = !state.busy
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
        let width = Style.width - 2 * Style.pad
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
        let width = Style.width, pad = Style.pad, inner = width - 2 * pad
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
        let askHeight: CGFloat = state.askPlaceholder == nil ? 0 : 36 + 10
        let pillRows = arrangePills(width: inner)
        let pillsHeight = pillRows.isEmpty ? 0 : CGFloat(pillRows.count) * (Pill.height + 6) + 4
        let room = Style.maxHeight - y - askHeight - pillsHeight - 12

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
            let height = max(18, min(full, room))
            scroll.frame.size.height = height
            transcript.frame = NSRect(x: 0, y: 0, width: textWidth, height: max(full, height))
            if case .transcript(_, let streaming) = state.body, streaming != nil {
                transcript.scrollToEndOfDocument(nil) // follow the reply as it is written
            }
            y += height + 10
        case .pick:
            let height = min(pickList.frame.height, max(PickRow.height * 3, room))
            let pickScroll = scrollFor(pickList)
            pickScroll.frame = NSRect(x: pad, y: y, width: inner, height: height)
            pickList.isHidden = false
            y += height + 10
        case .draft:
            targetLabel.isHidden = false
            let targetHeight = ceil(targetLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 100)).height ?? 16)
            targetLabel.frame = NSRect(x: pad, y: y, width: inner, height: targetHeight)
            y += targetHeight + 6
            let height = min(300, room - targetHeight - 6)
            draftScroll.isHidden = false
            draftScroll.frame = NSRect(x: pad, y: y, width: inner, height: height)
            draft.frame.size.width = inner
            y += height + 10
        }

        askFrame.isHidden = state.askPlaceholder == nil
        if !askFrame.isHidden {
            askFrame.frame = NSRect(x: pad, y: y, width: inner, height: 36)
            send.frame.origin = NSPoint(x: inner - 5 - 26, y: 5)
            askField.frame = NSRect(x: 14, y: (36 - 20) / 2, width: inner - 14 - 36, height: 20)
            y += 36 + 10
        }
        for (index, row) in pillRows.enumerated() {
            for (pill, x) in row { pill.frame.origin = NSPoint(x: pad + x, y: y + CGFloat(index) * (Pill.height + 6)) }
        }
        y += pillsHeight
        let height = y + 4

        // Place against the anchor: below it when there is room, otherwise above.
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = anchor.maxX - width
        var top = anchor.minY - Self.gap // Cocoa: the panel's top edge
        if top - height < visible.minY { top = anchor.maxY + Self.gap + height }
        x = max(visible.minX, min(x, visible.maxX - width))
        top = max(visible.minY + height, min(top, visible.maxY))
        let margin: CGFloat = 0
        panel.setFrame(NSRect(x: x.rounded(), y: (top - height).rounded(), width: width + margin, height: height), display: true)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        card.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.orderFrontRegardless()
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

    @objc private func submit() {
        let question = askField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, state?.busy == false else { return }
        askField.stringValue = ""
        onAsk?(question)
    }

    func controlTextDidBeginEditing(_ obj: Notification) { askFrame.focused = true }
    func controlTextDidEndEditing(_ obj: Notification) { askFrame.focused = false }

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

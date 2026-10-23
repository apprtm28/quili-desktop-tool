import AppKit

private final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The card's content: white rounded rect with the text, showing the newest lines when it is too long.
private final class BubbleView: NSView {
    static let maxTextWidth: CGFloat = 320, maxTextHeight: CGFloat = 150, tallTextHeight: CGFloat = 440
    static let padX: CGFloat = 12, padY: CGFloat = 9
    private static let attributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 18
        style.maximumLineHeight = 18
        return [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Brand.robotInk, .paragraphStyle: style]
    }()

    var text = "" { didSet { needsDisplay = true } }
    /// A tall bubble (a summary) reads from its first line instead of following the newest ones.
    var tall = false { didSet { needsDisplay = true } }
    /// A closable bubble (the finished summary) reserves room for, and draws, a × at its top-right.
    var closable = false { didSet { needsDisplay = true } }
    var onClose: (() -> Void)?
    /// How far a tall bubble whose text is longer than the card has been scrolled with the mouse wheel.
    private var scrollOffset: CGFloat = 0
    static let closeExtra: CGFloat = 16, closeSize: CGFloat = 16
    private var closeRect: NSRect { NSRect(x: bounds.maxX - 8 - Self.closeSize, y: 8, width: Self.closeSize, height: Self.closeSize) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if closable, closeRect.insetBy(dx: -5, dy: -5).contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }
    override var isFlipped: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard tall else { return }
        scrollOffset -= event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8)
        needsDisplay = true // draw() clamps the offset to the text
    }

    func resetScroll() {
        scrollOffset = 0
        needsDisplay = true
    }

    private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        ceil((text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin], attributes: attributes).height)
    }

    /// The card size that fits `text`.
    static func size(for text: String, tall: Bool = false, closable: Bool = false) -> NSSize {
        let bounding = (text as NSString).boundingRect(with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                                                        options: [.usesLineFragmentOrigin], attributes: attributes)
        let height = min(tall ? tallTextHeight : maxTextHeight, textHeight(text, width: ceil(bounding.width)))
        return NSSize(width: ceil(bounding.width) + padX * 2 + (closable ? closeExtra : 0), height: height + padY * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.white.setFill()
        card.fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        card.lineWidth = 1
        card.stroke()

        var inner = bounds.insetBy(dx: Self.padX, dy: Self.padY)
        if closable {
            inner.size.width -= Self.closeExtra
            let x = closeRect.insetBy(dx: 3.5, dy: 3.5)
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: x.minX, y: x.minY)); cross.line(to: NSPoint(x: x.maxX, y: x.maxY))
            cross.move(to: NSPoint(x: x.maxX, y: x.minY)); cross.line(to: NSPoint(x: x.minX, y: x.maxY))
            cross.lineWidth = 1.6
            cross.lineCapStyle = .round
            Brand.muted.setStroke()
            cross.stroke()
        }
        let full = Self.textHeight(text, width: inner.width)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: inner).addClip()
        // Too long to fit: keep the newest lines in view.
        scrollOffset = max(0, min(scrollOffset, max(0, full - inner.height)))
        let top = tall ? inner.minY - scrollOffset : inner.minY + min(0, inner.height - full)
        (text as NSString).draw(with: NSRect(x: inner.minX, y: top, width: inner.width, height: full),
                                options: [.usesLineFragmentOrigin], attributes: Self.attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A small always-on-top card next to the overlay button that shows the rewritten text as it streams in,
/// before it replaces the field's text. Click-through and never activated, so focus stays in the field.
@MainActor
final class BubbleWindow {
    private static let gap: CGFloat = 6
    private let panel: BubblePanel
    private let view = BubbleView(frame: .zero)
    private static let fadeSeconds: TimeInterval = 0.25
    private var fadeID = 0 // bumped by show/hide so a fade that was overtaken does not hide the new bubble

    init() {
        panel = BubblePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    /// Called when the × of a closable bubble is clicked.
    var onClose: (() -> Void)? { didSet { view.onClose = onClose } }

    /// Shows `text` above `anchor` (Cocoa screen coordinates), or below it when there is no room. A `closable`
    /// bubble has a × and takes clicks (it stays until closed); the others are click-through.
    func show(_ text: String, above anchor: NSRect, tall: Bool = false, closable: Bool = false) {
        cancelFade()
        panel.ignoresMouseEvents = !closable
        view.closable = closable
        view.tall = tall
        view.text = text
        let size = BubbleView.size(for: text, tall: tall, closable: closable)
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = anchor.maxX - size.width
        var y = anchor.maxY + Self.gap
        if y + size.height > visible.maxY { y = anchor.minY - Self.gap - size.height }
        x = max(visible.minX, min(x, visible.maxX - size.width))
        y = max(visible.minY, min(y, visible.maxY - size.height))
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    /// Fades the bubble out, then hides it (the × and the 5 s auto-close); a `show` or `hide` meanwhile cancels the fade.
    func fadeOut() {
        guard panel.isVisible else { return }
        fadeID += 1
        let id = fadeID
        panel.ignoresMouseEvents = true // already closing: no more clicks
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeSeconds
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.fadeID == id else { return }
                self.hide()
            }
        })
    }

    /// Stops a running fade and makes the panel fully opaque again.
    private func cancelFade() {
        fadeID += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        cancelFade()
        view.resetScroll()
        view.closable = false
        view.text = ""
        panel.orderOut(nil)
    }
}

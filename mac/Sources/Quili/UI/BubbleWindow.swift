import AppKit

private final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The card's content: white rounded rect with the text, showing the newest lines when it is too long.
private final class BubbleView: NSView {
    static let maxTextWidth: CGFloat = 320, maxTextHeight: CGFloat = 150
    static let padX: CGFloat = 12, padY: CGFloat = 9
    private static let attributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 18
        style.maximumLineHeight = 18
        return [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Brand.robotInk, .paragraphStyle: style]
    }()

    var text = "" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        ceil((text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin], attributes: attributes).height)
    }

    /// The card size that fits `text`.
    static func size(for text: String) -> NSSize {
        let bounding = (text as NSString).boundingRect(with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                                                        options: [.usesLineFragmentOrigin], attributes: attributes)
        let height = min(maxTextHeight, textHeight(text, width: ceil(bounding.width)))
        return NSSize(width: ceil(bounding.width) + padX * 2, height: height + padY * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.white.setFill()
        card.fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        card.lineWidth = 1
        card.stroke()

        let inner = bounds.insetBy(dx: Self.padX, dy: Self.padY)
        let full = Self.textHeight(text, width: inner.width)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: inner).addClip()
        // Too long to fit: keep the newest lines in view.
        let top = inner.minY + min(0, inner.height - full)
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

    /// Shows `text` above `anchor` (Cocoa screen coordinates), or below it when there is no room.
    func show(_ text: String, above anchor: NSRect) {
        view.text = text
        let size = BubbleView.size(for: text)
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = anchor.maxX - size.width
        var y = anchor.maxY + Self.gap
        if y + size.height > visible.maxY { y = anchor.minY - Self.gap - size.height }
        x = max(visible.minX, min(x, visible.maxX - size.width))
        y = max(visible.minY, min(y, visible.maxY - size.height))
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        view.text = ""
        panel.orderOut(nil)
    }
}

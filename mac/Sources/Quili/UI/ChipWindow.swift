import AppKit

extension Glyph {
    /// `fill` for a flipped view (y down): `fill` assumes Cocoa's y-up, so the glyph would come out upside down.
    static func fillFlipped(_ path: NSBezierPath, in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: rect.minY + rect.maxY)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        fill(path, in: rect, color: color)
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class ChipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The range chip's look: a small green pill with the sparkle (like the Summarize button), or white with a green
/// outline once it marks the start; the marked chip ends in a × that unmarks it.
private final class ChipView: NSView {
    static let height: CGFloat = 24, closeWidth: CGFloat = 22
    var label = "" { didSet { needsDisplay = true } }
    var marked = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }

    static func width(for label: String, marked: Bool) -> CGFloat {
        ceil(NSAttributedString(string: label, attributes: [.font: font]).size().width) + 12 + 14 + 6 + 12
            + (marked ? closeWidth - 4 : 0)
    }
    private var closeRect: NSRect { NSRect(x: bounds.maxX - Self.closeWidth, y: 0, width: Self.closeWidth, height: bounds.height) }
    private static let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if marked, closeRect.contains(point) { onClose?() } else { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.height / 2, yRadius: Self.height / 2)
        let ink: NSColor
        if marked {
            (hovered ? Brand.greenTint : NSColor.white).setFill()
            shape.fill()
            shape.lineWidth = 1.2
            Brand.greenDeep.setStroke()
            shape.stroke()
            ink = Brand.greenInk
        } else {
            (hovered ? Brand.greenInk : Brand.greenDeep).setFill()
            shape.fill()
            ink = .white
        }
        Glyph.fillFlipped(Glyph.sparkle, in: NSRect(x: 9, y: (bounds.height - 14) / 2, width: 14, height: 14), color: ink)
        let text = NSAttributedString(string: label, attributes: [.font: Self.font, .foregroundColor: ink])
        text.draw(at: NSPoint(x: 9 + 14 + 5, y: (bounds.height - text.size().height) / 2))
        if marked {
            // A thin divider, then the × that unmarks.
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: closeRect.minX + 0.5, y: 5)); divider.line(to: NSPoint(x: closeRect.minX + 0.5, y: bounds.height - 5))
            Brand.greenDeep.withAlphaComponent(0.4).setStroke()
            divider.stroke()
            let x = NSRect(x: closeRect.midX - 4, y: bounds.midY - 4, width: 8, height: 8)
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: x.minX, y: x.minY)); cross.line(to: NSPoint(x: x.maxX, y: x.maxY))
            cross.move(to: NSPoint(x: x.maxX, y: x.minY)); cross.line(to: NSPoint(x: x.minX, y: x.maxY))
            cross.lineWidth = 1.5
            cross.lineCapStyle = .round
            ink.setStroke()
            cross.stroke()
        }
    }
}

/// The small chip on the hovered channel message (Q4): "Start here", then "End here" on another message; on the
/// marked message "Only this one" (summarize just that message) with a × to unmark. Never takes focus from Slack.
@MainActor
final class ChipWindow {
    private let panel: ChipPanel
    private let view = ChipView(frame: .zero)

    var onClick: (() -> Void)? { didSet { view.onClick = onClick } }
    var onClose: (() -> Void)? { didSet { view.onClose = onClose } }
    var frame: NSRect { panel.frame }
    var isVisible: Bool { panel.isVisible }

    init() {
        panel = ChipPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    /// Places the chip inside the message row `row` (global AX coordinates) at its bottom-right, clear of Slack's
    /// hover toolbar at the row's top-right. Returns the chip's frame in AX coordinates.
    @discardableResult
    func show(_ label: String, marked: Bool, onRow row: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return .null }
        view.label = label
        view.marked = marked
        let width = ChipView.width(for: label, marked: marked), height = ChipView.height
        let axX = row.maxX - 16 - width
        let axY = row.height >= height + 12 ? row.maxY - 6 - height : row.midY - height / 2
        let cocoa = NSRect(x: axX.rounded(), y: (primary.frame.height - axY - height).rounded(), width: width, height: height)
        panel.setFrame(cocoa, display: true)
        view.frame = NSRect(origin: .zero, size: cocoa.size)
        panel.orderFrontRegardless()
        return CGRect(x: axX, y: axY, width: width, height: height)
    }

    func hide() { panel.orderOut(nil) }
}

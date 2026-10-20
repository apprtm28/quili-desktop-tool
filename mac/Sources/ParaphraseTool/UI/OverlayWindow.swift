import AppKit

/// A panel that never becomes key or main, so clicking it leaves keyboard focus in the field below.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ChipView: NSView {
    var busy = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { if !busy { onClick?() } }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        NSColor(red: 0x4F / 255.0, green: 0x46 / 255.0, blue: 0xE5 / 255.0, alpha: busy ? 0.6 : 1).setFill()
        circle.fill()
        NSColor.white.setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let glyph = (busy ? "…" : "✦") as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white]
        let size = glyph.size(withAttributes: attrs)
        glyph.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

@MainActor
final class OverlayWindow {
    private static let size: CGFloat = 22, margin: CGFloat = 6
    private let panel: OverlayPanel
    private let chip: ChipView

    var onClick: (() -> Void)? { didSet { chip.onClick = onClick } }
    private(set) var isBusy = false

    init() {
        let rect = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        chip = ChipView(frame: rect)
        chip.toolTip = "Paraphrase text"
        panel = OverlayPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = chip
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        chip.busy = busy
    }

    func hide() { panel.orderOut(nil) }

    /// Places the button at the bottom-right inside `axFrame` (global coordinates, top-left origin).
    func show(at axFrame: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let s = Self.size
        // AX y grows downward from the primary screen's top edge; Cocoa y grows upward from its bottom edge.
        var x = axFrame.maxX - s - Self.margin
        var y = primary.frame.height - (axFrame.maxY - Self.margin)

        let probe = NSRect(x: x, y: y, width: s, height: s)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(probe) }) {
            let v = screen.visibleFrame
            x = max(v.minX, min(x, v.maxX - s))
            y = max(v.minY, min(y, v.maxY - s))
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }
}

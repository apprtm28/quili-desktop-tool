import AppKit

/// A panel that never becomes key or main, so clicking it leaves keyboard focus in the field below.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum Palette {
    static let green = NSColor(red: 0x3D / 255.0, green: 0xBE / 255.0, blue: 0x4A / 255.0, alpha: 1)
    static let dark = NSColor(red: 0x1F / 255.0, green: 0x2A / 255.0, blue: 0x24 / 255.0, alpha: 1)
}

/// Draws the collapsed round button, and — as `expansion` goes 0 → 1 — a white pill growing to its left
/// with the action buttons (Translate to English, Paraphrase).
private final class OverlayView: NSView {
    static let actionWidth: CGFloat = 36
    var onAction: ((TextAction) -> Void)?
    var onHover: ((Bool) -> Void)?
    var busy = false {
        didSet {
            needsDisplay = true
            if busy { startSpinning() } else { spinTimer?.invalidate(); spinTimer = nil }
        }
    }
    private var spinAngle: CGFloat = 90
    private var spinTimer: Timer?
    var expansion: CGFloat = 0 { didSet { needsDisplay = true } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The round button ("Text Tool") and the Paraphrase action both paraphrase; EN translates to English.
    override func mouseUp(with event: NSEvent) {
        guard !busy else { return }
        onAction?(action(at: convert(event.locationInWindow, from: nil)))
    }

    private var paraphraseMinX: CGFloat { bounds.width - bounds.height - Self.actionWidth }

    private func action(at point: NSPoint) -> TextAction {
        let translateMinX = paraphraseMinX - Self.actionWidth
        if expansion > 0.5, point.x >= translateMinX, point.x < paraphraseMinX { return .translateToEnglish }
        return .paraphrase
    }

    // One tooltip over the whole view whose text depends on which part is hovered.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        registerToolTip()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerToolTip()
    }
    private func registerToolTip() {
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height

        if expansion > 0.01 {
            let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: h / 2, yRadius: h / 2)
            NSColor.white.withAlphaComponent(expansion).setFill()
            pill.fill()
            NSColor.black.withAlphaComponent(0.15 * expansion).setStroke()
            pill.lineWidth = 1
            pill.stroke()

            // Actions are anchored to the round button, so they slide out with the pill.
            let paraphrase = NSRect(x: paraphraseMinX, y: 0, width: Self.actionWidth, height: h)
            Palette.green.withAlphaComponent(expansion).setFill()
            Self.star(center: NSPoint(x: paraphrase.midX - 1, y: paraphrase.midY - 1), radius: 7).fill()
            Self.star(center: NSPoint(x: paraphrase.midX + 6, y: paraphrase.midY + 6), radius: 3).fill()

            let translate = paraphrase.offsetBy(dx: -Self.actionWidth, dy: 0)
            let label = NSAttributedString(string: "EN", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: Palette.green.withAlphaComponent(expansion),
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: translate.midX - size.width / 2, y: translate.midY - size.height / 2))
        }

        let circle = NSRect(x: bounds.width - h, y: 0, width: h, height: h).insetBy(dx: 1, dy: 1)
        Palette.green.setFill()
        NSBezierPath(ovalIn: circle).fill()

        if busy {
            let spinner = circle.insetBy(dx: 6, dy: 6)
            let center = NSPoint(x: spinner.midX, y: spinner.midY)
            let radius = spinner.width / 2

            let track = NSBezierPath(ovalIn: spinner)
            track.lineWidth = 2
            Palette.dark.withAlphaComponent(0.2).setStroke()
            track.stroke()

            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: spinAngle, endAngle: spinAngle + 100, clockwise: false)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            Palette.dark.setStroke()
            arc.stroke()
        } else {
            Self.drawRobot(in: circle.insetBy(dx: 5, dy: 5))
        }
    }

    private func startSpinning() {
        guard spinTimer == nil else { return }
        spinTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.spinAngle -= 7 // clockwise
                self.needsDisplay = true
            }
        }
    }

    /// Four-point sparkle.
    private static func star(center c: NSPoint, radius r: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        let t = NSPoint(x: c.x, y: c.y + r), right = NSPoint(x: c.x + r, y: c.y)
        let b = NSPoint(x: c.x, y: c.y - r), left = NSPoint(x: c.x - r, y: c.y)
        p.move(to: t)
        p.curve(to: right, controlPoint1: NSPoint(x: c.x + 0.12 * r, y: c.y + 0.45 * r), controlPoint2: NSPoint(x: c.x + 0.45 * r, y: c.y + 0.12 * r))
        p.curve(to: b, controlPoint1: NSPoint(x: c.x + 0.45 * r, y: c.y - 0.12 * r), controlPoint2: NSPoint(x: c.x + 0.12 * r, y: c.y - 0.45 * r))
        p.curve(to: left, controlPoint1: NSPoint(x: c.x - 0.12 * r, y: c.y - 0.45 * r), controlPoint2: NSPoint(x: c.x - 0.45 * r, y: c.y - 0.12 * r))
        p.curve(to: t, controlPoint1: NSPoint(x: c.x - 0.45 * r, y: c.y + 0.12 * r), controlPoint2: NSPoint(x: c.x - 0.12 * r, y: c.y + 0.45 * r))
        p.close()
        return p
    }

    /// Little robot head, designed on a 24×24 canvas with a top-left origin.
    private static func drawRobot(in rect: NSRect) {
        func map(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 0, _ h: CGFloat = 0) -> NSRect {
            NSRect(x: rect.minX + x / 24 * rect.width, y: rect.minY + (24 - y - h) / 24 * rect.height,
                   width: w / 24 * rect.width, height: h / 24 * rect.height)
        }
        Palette.dark.setFill()
        NSBezierPath(ovalIn: map(10.4, 1.6, 3.2, 3.2)).fill()
        NSBezierPath(rect: map(11.2, 4, 1.6, 3.5)).fill()
        NSBezierPath(roundedRect: map(2, 11, 3, 5), xRadius: 1.2, yRadius: 1.2).fill()
        NSBezierPath(roundedRect: map(19, 11, 3, 5), xRadius: 1.2, yRadius: 1.2).fill()
        NSBezierPath(roundedRect: map(4.5, 7, 15, 13), xRadius: 3.5, yRadius: 3.5).fill()
        Palette.green.setFill()
        NSBezierPath(ovalIn: map(8, 10.8, 3.2, 3.2)).fill()
        NSBezierPath(ovalIn: map(12.8, 10.8, 3.2, 3.2)).fill()
        NSBezierPath(roundedRect: map(9.5, 16.2, 5, 1.4), xRadius: 0.7, yRadius: 0.7).fill()
    }
}

extension OverlayView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        switch action(at: point) {
        case .translateToEnglish: return "Translate to English"
        case .paraphrase: return point.x < bounds.width - bounds.height ? "Paraphrase" : "Text Tool"
        }
    }
}

@MainActor
final class OverlayWindow {
    private static let size: CGFloat = 28, expandedWidth: CGFloat = 102, margin: CGFloat = 6
    private static let stepPerTick: CGFloat = 0.2

    private let panel: OverlayPanel
    private let view: OverlayView
    private var animation: Timer?

    // Origin of the round button (Cocoa coordinates); the pill grows to the left of it.
    private var anchor = NSPoint.zero
    private var expansion: CGFloat = 0
    private var hovered = false

    var onAction: ((TextAction) -> Void)? { didSet { view.onAction = onAction } }
    private(set) var isBusy = false

    init() {
        let rect = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        view = OverlayView(frame: rect)
        panel = OverlayPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        view.onHover = { [weak self] inside in
            self?.hovered = inside
            self?.startAnimating()
        }
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        view.busy = busy
        startAnimating() // collapse while busy, re-expand if still hovered afterwards
    }

    func hide() {
        animation?.invalidate()
        animation = nil
        hovered = false
        expansion = 0
        view.expansion = 0
        panel.orderOut(nil)
    }

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
        anchor = NSPoint(x: x, y: y)
        applyLayout()
        panel.orderFrontRegardless()
    }

    private func applyLayout() {
        let s = Self.size
        let width = s + (Self.expandedWidth - s) * expansion
        view.expansion = expansion
        panel.setFrame(NSRect(x: anchor.x - (width - s), y: anchor.y, width: width, height: s), display: true)
    }

    private func startAnimating() {
        guard animation == nil else { return }
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let target: CGFloat = hovered && !isBusy ? 1 : 0
        if abs(target - expansion) <= Self.stepPerTick {
            expansion = target
            animation?.invalidate()
            animation = nil
        } else {
            expansion += expansion < target ? Self.stepPerTick : -Self.stepPerTick
        }
        applyLayout()
    }
}

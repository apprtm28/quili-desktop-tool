import AppKit

/// A panel that never becomes key or main, so clicking it leaves keyboard focus in the field below.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum Palette {
    static let green = NSColor(red: 0x3D / 255.0, green: 0xBE / 255.0, blue: 0x4A / 255.0, alpha: 1)
    static let red = NSColor(red: 0xE5 / 255.0, green: 0x48 / 255.0, blue: 0x4D / 255.0, alpha: 1)
    static let dark = NSColor(red: 0x1F / 255.0, green: 0x2A / 255.0, blue: 0x24 / 255.0, alpha: 1)
}

/// Draws the collapsed round button, and — as `expansion` goes 0 → 1 — a white pill growing to its left
/// with the action buttons (Translate to English, Paraphrase).
private final class OverlayView: NSView {
    static let actionWidth: CGFloat = 36
    var onAction: ((TextAction) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    /// While busy, the round button turns into "Cancel" on hover. The click that started the request must
    /// not cancel it, so the pointer has to leave the button first.
    private var cancelReady = false
    var busy = false {
        didSet {
            needsDisplay = true
            if busy {
                hovered = nil
                pressed = nil
                let mouse = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
                cancelReady = mouse.map { region(at: $0) != .circle } ?? true
                startSpinning()
            } else {
                spinTimer?.invalidate()
                spinTimer = nil
            }
        }
    }

    // Hover / press feedback so the buttons read as clickable.
    private enum Region: CaseIterable { case translate, paraphrase, circle }
    private var hovered: Region? { didSet { if hovered != oldValue { startHoverAnimation(); updateCursor() } } }
    private var pressed: Region? { didSet { if pressed != oldValue { startHoverAnimation() } } }
    private var hoverAmount: [Region: CGFloat] = [:]   // 0…1, eased toward the target each frame
    private var pressAmount: [Region: CGFloat] = [:]
    private var hoverTimer: Timer?
    private var spinAngle: CGFloat = 90
    private var spinTimer: Timer?
    var expansion: CGFloat = 0 { didSet { needsDisplay = true } }
    /// Which edge of the field the pill is docked to; the corners touching the field are squared off.
    enum Dock { case floating, belowField, aboveField }
    /// Outer corner radius when docked: a slightly softened edge rather than a pill.
    static let dockedRadius: CGFloat = 5
    var dock = Dock.floating { didSet { needsDisplay = true } }
    /// The actions fade in a beat after the pill starts opening (and out first when closing).
    private var actionAlpha: CGFloat { min(1, max(0, (expansion - 0.3) / 0.7)) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The round button ("Text Tool") and the Paraphrase action both paraphrase; EN translates to English.
    override func mouseDown(with event: NSEvent) {
        if busy {
            if hovered == .circle { pressed = .circle }
            return
        }
        pressed = region(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        pressed = nil
        if busy {
            if hovered == .circle { onCancel?() }
            return
        }
        onAction?(action(at: convert(event.locationInWindow, from: nil)))
    }

    private func region(at point: NSPoint) -> Region? {
        if point.x >= bounds.width - bounds.height { return .circle }
        guard expansion > 0.5 else { return nil }
        if point.x >= paraphraseMinX { return .paraphrase }
        if point.x >= paraphraseMinX - Self.actionWidth { return .translate }
        return nil
    }

    private func updateCursor() { (hovered == nil ? NSCursor.arrow : NSCursor.pointingHand).set() }

    private func startHoverAnimation() {
        guard hoverTimer == nil else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepHover() }
        }
    }

    private func stepHover() {
        var settled = true
        for region in Region.allCases {
            if !approach(&hoverAmount[region, default: 0], to: hovered == region ? 1 : 0) { settled = false }
            if !approach(&pressAmount[region, default: 0], to: pressed == region ? 1 : 0) { settled = false }
        }
        needsDisplay = true
        if settled { hoverTimer?.invalidate(); hoverTimer = nil }
    }

    /// Moves `value` one step toward `target`; true once it has arrived.
    private func approach(_ value: inout CGFloat, to target: CGFloat) -> Bool {
        let step: CGFloat = 0.22
        if abs(target - value) <= step { value = target; return true }
        value += value < target ? step : -step
        return false
    }

    /// Grows a hovered button and shrinks a pressed one, around `center`.
    private func drawScaled(_ region: Region, around center: NSPoint, _ body: () -> Void) {
        let hover = hoverAmount[region] ?? 0, press = pressAmount[region] ?? 0
        // Docked to a field, the green button doesn't zoom.
        let still = region == .circle && dock != .floating
        let scale = still ? 1 : (1 + (region == .circle ? 0.08 : 0.14) * hover) * (1 - 0.12 * press)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.scale(by: scale)
        transform.translateX(by: -center.x, yBy: -center.y)
        transform.concat()
        body()
        NSGraphicsContext.restoreGraphicsState()
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
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
        mouseMoved(with: event)
    }
    override func mouseMoved(with event: NSEvent) {
        let region = region(at: convert(event.locationInWindow, from: nil))
        if busy {
            if region != .circle { cancelReady = true }
            hovered = cancelReady && region == .circle ? .circle : nil
        } else {
            hovered = region
        }
    }
    override func mouseExited(with event: NSEvent) {
        cancelReady = true
        hovered = nil
        pressed = nil
        onHover?(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height

        if expansion > 0.01 {
            let r = dock == .floating ? h / 2 : Self.dockedRadius
            let pill = Self.roundedPath(bounds.insetBy(dx: 0.5, dy: 0.5),
                                        top: dock == .belowField ? 0 : r, bottom: dock == .aboveField ? 0 : r)
            NSColor.white.withAlphaComponent(expansion).setFill()
            pill.fill()
            NSColor.black.withAlphaComponent(0.15 * expansion).setStroke()
            pill.lineWidth = 1
            pill.stroke()

            // Actions are anchored to the round button, so they slide out with the pill.
            let paraphrase = NSRect(x: paraphraseMinX, y: 0, width: Self.actionWidth, height: h)
            let translate = paraphrase.offsetBy(dx: -Self.actionWidth, dy: 0)

            // A soft green highlight fades in behind the hovered action.
            for (region, rect) in [(Region.paraphrase, paraphrase), (Region.translate, translate)] {
                Palette.green.withAlphaComponent(0.18 * (hoverAmount[region] ?? 0) * actionAlpha).setFill()
                // Same corner setting as the pill: square on the side docked to the field, soft on the other.
                let r = dock == .floating ? 11 : Self.dockedRadius
                Self.roundedPath(rect.insetBy(dx: 2, dy: 2),
                                 top: dock == .belowField ? 0 : r, bottom: dock == .aboveField ? 0 : r).fill()
            }

            drawScaled(.paraphrase, around: NSPoint(x: paraphrase.midX, y: paraphrase.midY)) {
                Palette.green.withAlphaComponent(actionAlpha).setFill()
                Self.star(center: NSPoint(x: paraphrase.midX - 1, y: paraphrase.midY - 1), radius: 7).fill()
                Self.star(center: NSPoint(x: paraphrase.midX + 6, y: paraphrase.midY + 6), radius: 3).fill()
            }

            drawScaled(.translate, around: NSPoint(x: translate.midX, y: translate.midY)) {
                let label = NSAttributedString(string: "EN", attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 12),
                    .foregroundColor: Palette.green.withAlphaComponent(actionAlpha),
                ])
                let size = label.size()
                label.draw(at: NSPoint(x: translate.midX - size.width / 2, y: translate.midY - size.height / 2))
            }
        }

        // The green button starts 1 point below the pill's top and is 2 points shorter than the pill.
        let circle = NSRect(x: bounds.width - h, y: 0, width: h, height: h).insetBy(dx: 1, dy: 1)
        drawScaled(.circle, around: NSPoint(x: circle.midX, y: circle.midY)) { drawCircleButton(circle) }
    }

    private func drawCircleButton(_ circle: NSRect) {
        let cancel = busy ? hoverAmount[.circle] ?? 0 : 0
        (Palette.green.blended(withFraction: cancel, of: Palette.red) ?? Palette.green).setFill()
        let radius = dock == .floating ? min(circle.width, circle.height) / 2 : Self.dockedRadius
        Self.roundedPath(circle, top: dock == .belowField ? 0 : radius, bottom: dock == .aboveField ? 0 : radius).fill()

        if busy {
            let spinner = circle.insetBy(dx: 6, dy: 6)
            let center = NSPoint(x: spinner.midX, y: spinner.midY)
            let radius = spinner.width / 2

            let track = NSBezierPath(ovalIn: spinner)
            track.lineWidth = 2
            Palette.dark.withAlphaComponent(0.2 * (1 - cancel)).setStroke()
            track.stroke()

            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: spinAngle, endAngle: spinAngle + 100, clockwise: false)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            Palette.dark.withAlphaComponent(1 - cancel).setStroke()
            arc.stroke()

            if cancel > 0 {
                let mark = circle.insetBy(dx: 9, dy: 9)
                let cross = NSBezierPath()
                cross.move(to: NSPoint(x: mark.minX, y: mark.minY)); cross.line(to: NSPoint(x: mark.maxX, y: mark.maxY))
                cross.move(to: NSPoint(x: mark.minX, y: mark.maxY)); cross.line(to: NSPoint(x: mark.maxX, y: mark.minY))
                cross.lineWidth = 2
                cross.lineCapStyle = .round
                NSColor.white.withAlphaComponent(cancel).setStroke()
                cross.stroke()
            }
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

    /// Rounded rect whose top corners share one radius and bottom corners another (Cocoa: y grows upward).
    private static func roundedPath(_ rect: NSRect, top: CGFloat, bottom: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: rect.minX + top, y: rect.maxY))
        p.line(to: NSPoint(x: rect.maxX - top, y: rect.maxY))
        if top > 0 { p.appendArc(from: NSPoint(x: rect.maxX, y: rect.maxY), to: NSPoint(x: rect.maxX, y: rect.maxY - top), radius: top) }
        p.line(to: NSPoint(x: rect.maxX, y: rect.minY + bottom))
        if bottom > 0 { p.appendArc(from: NSPoint(x: rect.maxX, y: rect.minY), to: NSPoint(x: rect.maxX - bottom, y: rect.minY), radius: bottom) }
        p.line(to: NSPoint(x: rect.minX + bottom, y: rect.minY))
        if bottom > 0 { p.appendArc(from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.minX, y: rect.minY + bottom), radius: bottom) }
        p.line(to: NSPoint(x: rect.minX, y: rect.maxY - top))
        if top > 0 { p.appendArc(from: NSPoint(x: rect.minX, y: rect.maxY), to: NSPoint(x: rect.minX + top, y: rect.maxY), radius: top) }
        p.close()
        return p
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
        if busy { return hovered == .circle ? "Cancel" : "" }
        switch action(at: point) {
        case .translateToEnglish: return "Translate to English"
        case .paraphrase: return point.x < bounds.width - bounds.height ? "Paraphrase" : "Text Tool"
        }
    }
}

@MainActor
final class OverlayWindow {
    private static let size: CGFloat = 28, expandedWidth: CGFloat = 102, margin: CGFloat = 6, wideFieldFactor: CGFloat = 10, dockOffset: CGFloat = 6
    // Time-based easing (not a fixed step per tick) so the pill glides at the display's frame rate.
    private static let expandDuration: TimeInterval = 0.23, collapseDuration: TimeInterval = 0.17

    private let panel: OverlayPanel
    private let view: OverlayView
    private var animation: Timer?
    private var animFrom: CGFloat = 0, animTarget: CGFloat = 0
    private var animStart = Date(), animDuration: TimeInterval = 0.2

    // Origin of the round button (Cocoa coordinates); the pill grows to the left of it.
    private var anchor = NSPoint.zero
    private var expansion: CGFloat = 0
    private var hovered = false

    var onAction: ((TextAction) -> Void)? { didSet { view.onAction = onAction } }
    var onCancel: (() -> Void)? { didSet { view.onCancel = onCancel } }
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
        animTarget = 0
        hovered = false
        expansion = 0
        view.expansion = 0
        panel.orderOut(nil)
    }

    /// Places the button at the right edge of `axFrame` (global coordinates, top-left origin): floating inside wide fields,
    /// docked below (or above) narrower ones.
    func show(at axFrame: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let s = Self.size
        // AX y grows downward from the primary screen's top edge; Cocoa y grows upward from its bottom edge.
        var x = axFrame.maxX - s - Self.margin
        var y: CGFloat
        var dock = OverlayView.Dock.floating

        if axFrame.width >= s * Self.wideFieldFactor {
            // Design 1, wide field: a free-floating pill inside it, centred on short fields and at the
            // bottom-right of taller ones.
            y = axFrame.height <= s * 3
                ? primary.frame.height - axFrame.midY - s / 2
                : primary.frame.height - (axFrame.maxY - Self.margin)
        } else {
            // Design 2, narrower field: the button would cover its text, so dock it to the bottom edge like a
            // tab (to the top edge when there is no room under it), with the corners that touch the field
            // squared off on both the green button and the pill.
            // The field's visible border sits a little outside the focused element's bounds (padding).
            y = primary.frame.height - (axFrame.maxY + Self.dockOffset + s)
            dock = .belowField
            let screenBottom = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: x, y: y + s)) })?.visibleFrame.minY ?? 0
            if y < screenBottom {
                y = primary.frame.height - (axFrame.minY - Self.dockOffset)
                dock = .aboveField
            }
        }
        view.dock = dock

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
        // Whole-pixel frame: a fractional width/origin makes the round button shimmer while the pill grows.
        let width = (s + (Self.expandedWidth - s) * expansion).rounded()
        view.expansion = expansion
        panel.setFrame(NSRect(x: (anchor.x - (width - s)).rounded(), y: anchor.y.rounded(), width: width, height: s),
                       display: true)
    }

    /// Eases the pill toward open (hovered, idle) or closed, starting from where it is now.
    private func startAnimating() {
        let target: CGFloat = hovered && !isBusy ? 1 : 0
        if animation != nil ? target == animTarget : target == expansion { return }

        animFrom = expansion
        animTarget = target
        animDuration = target > expansion ? Self.expandDuration : Self.collapseDuration
        animStart = Date()
        guard animation == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common) // keep animating while the mouse is tracked
        animation = timer
    }

    private func tick() {
        let t = min(1, Date().timeIntervalSince(animStart) / animDuration)
        let eased = 1 - pow(1 - CGFloat(t), 3) // ease-out cubic
        expansion = animFrom + (animTarget - animFrom) * eased
        applyLayout()
        if t >= 1 {
            animation?.invalidate()
            animation = nil
        }
    }
}

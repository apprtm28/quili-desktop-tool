import AppKit

/// A panel that never becomes key or main, so clicking it leaves Slack in front with its focus untouched.
private final class ThreadButtonPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The round green button with the sparkle; "Summarize thread on Quili" shows as its tooltip.
private final class ThreadButtonView: NSView {
    static let side: CGFloat = 28
    private static let glyph: CGFloat = 16

    var onClick: (() -> Void)?
    /// True when the pointer enters the button, false when it leaves or presses it (the tooltip follows this).
    var onHover: ((Bool) -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Only our own hover area is replaced: AppKit keeps its tooltip tracking areas in the same list, and removing
    // those would stop the tooltip from ever showing.
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }


    override func mouseEntered(with event: NSEvent) { hovered = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false; onHover?(false) }
    override func mouseDown(with event: NSEvent) { pressed = true; onHover?(false) }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        (pressed || hovered ? Brand.greenInk : Brand.greenDeep).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
        Glyph.fill(Glyph.sparkle, in: NSRect(x: (bounds.width - Self.glyph) / 2, y: (bounds.height - Self.glyph) / 2,
                                             width: Self.glyph, height: Self.glyph), color: .white)
    }
}

/// A small dark label under the button. macOS only shows native tooltips for a panel while its own app is active, and
/// the button sits over Slack, so it draws its own: click-through and never activated.
@MainActor
private final class TooltipWindow {
    private static let padX: CGFloat = 9, padY: CGFloat = 5, gap: CGFloat = 6
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = Brand.robotInk.cgColor
        box.layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 12)
        label.textColor = .white
        box.addSubview(label)
        panel.contentView = box
    }

    /// Shows `text` under `anchor` (Cocoa screen coordinates), or above it when there is no room.
    func show(_ text: String, near anchor: NSRect) {
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(width: ceil(label.frame.width) + 2 * Self.padX, height: ceil(label.frame.height) + 2 * Self.padY)
        label.frame.origin = NSPoint(x: Self.padX, y: Self.padY)
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var y = anchor.minY - Self.gap - size.height
        if y < visible.minY { y = anchor.maxY + Self.gap }
        let x = max(visible.minX, min(anchor.midX - size.width / 2, visible.maxX - size.width))
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

/// A small always-on-top round button that sits just left of Slack's own "Summarize thread" button, like the Windows
/// `ThreadButtonWindow`. Clicking it summarizes that thread; it never takes focus from Slack.
@MainActor
final class ThreadButtonWindow {
    // Beside Slack's button: this far to its left (to its right when there is no room).
    private static let besideGap: CGFloat = 8
    private static let tooltipText = "Summarize thread on Quili"
    private static let tooltipDelay: UInt64 = 400_000_000
    private let panel: ThreadButtonPanel
    private let view: ThreadButtonView
    private let tooltip = TooltipWindow()
    private var tooltipTask: Task<Void, Never>?

    var onClick: (() -> Void)? { didSet { view.onClick = onClick } }

    /// The button's current frame in Cocoa screen coordinates; the summary bubble anchors to it.
    var frame: NSRect { panel.frame }

    init() {
        let side = ThreadButtonView.side
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        view = ThreadButtonView(frame: rect)
        panel = ThreadButtonPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        view.onHover = { [weak self] inside in self?.hoverChanged(inside) }
    }

    /// The tooltip appears a moment after the pointer settles on the button, and goes when it leaves or presses.
    private func hoverChanged(_ inside: Bool) {
        tooltipTask?.cancel()
        tooltip.hide()
        guard inside else { return }
        tooltipTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.tooltipDelay)
            guard !Task.isCancelled, let self else { return }
            self.tooltip.show(Self.tooltipText, near: self.panel.frame)
        }
    }

    private var side: CGFloat { ThreadButtonView.side }

    /// Places the button just left of Slack's own button at `slackButton` (global AX coordinates), vertically
    /// centred on it; on its right instead when the screen has no room on the left.
    func show(besideButton slackButton: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let cocoa = NSRect(x: slackButton.minX, y: primary.frame.height - slackButton.maxY,
                           width: slackButton.width, height: slackButton.height)
        let visible = (NSScreen.screens.first { $0.frame.intersects(cocoa) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = cocoa.minX - Self.besideGap - side
        if x < visible.minX { x = cocoa.maxX + Self.besideGap }
        x = max(visible.minX, min(x, visible.maxX - side))
        let y = max(visible.minY, min(cocoa.midY - side / 2, visible.maxY - side))
        place(x: x, y: y)
    }

    private func place(x: CGFloat, y: CGFloat) {
        let frame = NSRect(x: x.rounded(), y: y.rounded(), width: side, height: side)
        if frame != panel.frame { hoverChanged(false) } // moved: a tooltip left behind would point at nothing
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        hoverChanged(false)
        panel.orderOut(nil)
    }
}

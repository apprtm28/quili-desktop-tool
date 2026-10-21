import AppKit
import ApplicationServices

struct TextTarget {
    let element: AXUIElement
    let frame: CGRect   // AX coordinates (top-left origin)
}

/// Polls the Accessibility API for the focused element and reports it when it is an editable text field.
final class FocusTracker {
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String,
    ]
    /// Controls that never take typed text, even when they expose a value (the Windows tracker's NeverText list).
    private static let neverTextRoles: Set<String> = [
        kAXButtonRole as String, kAXCheckBoxRole as String, kAXRadioButtonRole as String, kAXSliderRole as String,
        kAXScrollBarRole as String, kAXProgressIndicatorRole as String, kAXMenuItemRole as String,
        kAXMenuButtonRole as String, kAXPopUpButtonRole as String, kAXIncrementorRole as String,
        kAXRowRole as String, kAXOutlineRole as String, "AXLink", "AXTab",
    ]
    private let ownPid = ProcessInfo.processInfo.processIdentifier
    private let queue = DispatchQueue(label: "FocusTracker")
    private var timer: DispatchSourceTimer?
    private var last: TextTarget?
    private var lastReason: String?
    private var enhancedPids = Set<pid_t>()

    // Written on the main queue, read on the polling queue.
    private let pausedLock = NSLock()
    private var pausedValue = false
    var paused: Bool {
        get { pausedLock.lock(); defer { pausedLock.unlock() }; return pausedValue }
        set { pausedLock.lock(); pausedValue = newValue; pausedLock.unlock() }
    }
    /// Called on the main queue; nil means no editable field is focused.
    var onChange: ((TextTarget?) -> Void)?

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let current = (paused || !AXIsProcessTrusted()) ? nil : probe()
        if !Self.same(last, current) {
            last = current
            DispatchQueue.main.async { [onChange] in onChange?(current) }
        }
    }

    private static func same(_ a: TextTarget?, _ b: TextTarget?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.frame == b.frame && CFEqual(a.element, b.element)
    }

    static func focusedElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AX.focusedElement(ofApp: AXUIElementCreateApplication(app.processIdentifier))
    }

    static func stillFocused(_ element: AXUIElement) -> Bool {
        guard let focused = focusedElement() else { return false }
        return CFEqual(focused, element)
    }

    /// `stillFocused` and `isForeground` together, evaluated off the main thread (an unresponsive app can stall AX calls).
    static func focusState(of element: AXUIElement) async -> (focused: Bool, front: Bool) {
        await Task.detached { (stillFocused(element), isForeground(element)) }.value
    }

    /// Key presses (Cmd+A/C/V) go to the frontmost app, so only act when it owns the element.
    static func isForeground(_ element: AXUIElement) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return true }
        return front.processIdentifier == AX.pid(element)
    }

    /// Brings the app and field back to the front after the user switched away during the request.
    @MainActor
    static func restoreFocus(_ element: AXUIElement, app: NSRunningApplication?) async -> Bool {
        guard let app else { return false }
        app.activate(options: [.activateIgnoringOtherApps])
        await Pause.milliseconds(200)
        await Task.detached { _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }.value
        await Pause.milliseconds(200)
        let state = await focusState(of: element)
        return state.front && state.focused
    }

    private func report(_ reason: String) {
        guard reason != lastReason else { return }
        lastReason = reason
        DebugLog.write(reason)
    }

    /// Chromium, Electron and Firefox only build their accessibility tree once an assistive client asks for it.
    /// AXManualAccessibility is harmless everywhere; AXEnhancedUserInterface is known to disturb window animation
    /// and tiling window managers in native apps, so it is only set on web-engine apps.
    private func enableWebAccessibility(_ app: AXUIElement, running: NSRunningApplication) {
        guard enhancedPids.insert(running.processIdentifier).inserted else { return }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if Self.usesWebEngine(running) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private static func usesWebEngine(_ app: NSRunningApplication) -> Bool {
        if app.bundleIdentifier?.hasPrefix("org.mozilla.") == true { return true }
        guard let frameworks = app.bundleURL?.appendingPathComponent("Contents/Frameworks"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else { return false }
        return names.contains { name in
            if name.hasPrefix("Electron Framework") || name.hasPrefix("Chromium Embedded Framework") { return true }
            // Chrome, Edge, Brave, ...: "<Name> Framework.framework" carrying the browser helper apps.
            return name.hasSuffix("Framework.framework") && FileManager.default.fileExists(
                atPath: frameworks.appendingPathComponent(name).appendingPathComponent("Versions/Current/Helpers").path)
        }
    }

    private func probe() -> TextTarget? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = front.processIdentifier
        if pid == ownPid { report("skip own window"); return nil }

        let app = AXUIElementCreateApplication(pid)
        enableWebAccessibility(app, running: front)

        guard let el = AX.focusedElement(ofApp: app) else { report("no focused element in \(front.localizedName ?? "?")"); return nil }
        let role = AX.string(el, kAXRoleAttribute) ?? ""
        let subrole = AX.string(el, kAXSubroleAttribute) ?? ""
        let desc = "role=\(role) subrole=\(subrole) app=\(front.localizedName ?? "?")"

        if subrole == (kAXSecureTextFieldSubrole as String) { report("skip password: \(desc)"); return nil }
        guard Self.isEditable(el, role: role) else { report("skip not editable: \(desc)"); return nil }
        guard let frame = AX.frame(el), frame.width >= 40, frame.height >= 14 else {
            report("skip too small/no frame: \(desc)"); return nil
        }
        report("show button: \(desc) frame=\(frame)")
        return TextTarget(element: el, frame: frame)
    }

    private static func isEditable(_ el: AXUIElement, role: String) -> Bool {
        if textRoles.contains(role) {
            // Labels and read-only text areas expose the same roles but a non-settable value.
            return AX.isSettable(el, kAXValueAttribute) || AX.attr(el, kAXSelectedTextRangeAttribute) != nil
        }
        if neverTextRoles.contains(role) { return false }
        // Rich editors (contenteditable, Slack) can surface under other roles but still accept text input.
        return AX.isSettable(el, kAXValueAttribute) && AX.attr(el, kAXSelectedTextRangeAttribute) != nil
    }
}

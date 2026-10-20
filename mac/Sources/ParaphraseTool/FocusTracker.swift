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
    private let ownPid = ProcessInfo.processInfo.processIdentifier
    private let queue = DispatchQueue(label: "FocusTracker")
    private var timer: DispatchSourceTimer?
    private var last: TextTarget?
    private var lastReason: String?
    private var enhancedPids = Set<pid_t>()

    var paused = false
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

    private func report(_ reason: String) {
        guard reason != lastReason else { return }
        lastReason = reason
        DebugLog.write(reason)
    }

    /// Chromium and Electron only build their accessibility tree once an assistive client asks for it.
    private func enableWebAccessibility(_ app: AXUIElement, pid: pid_t) {
        guard enhancedPids.insert(pid).inserted else { return }
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func probe() -> TextTarget? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = front.processIdentifier
        if pid == ownPid { report("skip own window"); return nil }

        let app = AXUIElementCreateApplication(pid)
        enableWebAccessibility(app, pid: pid)

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
        // Rich editors (contenteditable, Slack) can surface under other roles but still accept text input.
        return AX.isSettable(el, kAXValueAttribute) && AX.attr(el, kAXSelectedTextRangeAttribute) != nil
    }
}

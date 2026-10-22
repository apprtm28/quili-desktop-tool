import AppKit
import ApplicationServices

/// The visible text of the chat thread open in a Slack window, read through the Accessibility tree.
struct ThreadText {
    let text: String
    let truncated: Bool   // older lines were dropped to stay under the server's size cap
}

/// Reads the thread pane of the Slack desktop app (an Electron app, so its web content is exposed as an AX tree
/// once `AXManualAccessibility` is set). Nothing is written to Slack and no Slack API or token is involved: it
/// sees only what the window renders. Deliberately not main-actor: AX calls can block for seconds on a busy app.
///
/// Slack's tree is not documented, so the reader is defensive: it looks for a landmark labelled "thread", and
/// otherwise takes the smallest region around the message box that holds several lines of text. The debug log
/// records counts and roles only, never message text.
enum ThreadReader {
    static let slackBundleId = "com.tinyspeck.slackmacgap"
    /// Under the server's SUMMARIZE_MAX_CHARS (40000).
    static let maxChars = 38_000
    private static let maxNodes = 25_000, maxDepth = 60, timeLimit: TimeInterval = 6
    private static let minLines = 3

    /// Roles that carry no conversation text, and whose subtrees are skipped.
    private static let skippedRoles: Set<String> = [
        kAXButtonRole as String, kAXImageRole as String, kAXScrollBarRole as String, kAXMenuRole as String,
        kAXMenuItemRole as String, kAXMenuButtonRole as String, kAXPopUpButtonRole as String,
        kAXCheckBoxRole as String, kAXRadioButtonRole as String, kAXSliderRole as String,
        kAXProgressIndicatorRole as String, "AXTab",
    ]

    private struct Budget {
        var nodes = ThreadReader.maxNodes
        let deadline = Date().addingTimeInterval(ThreadReader.timeLimit)
        mutating func spend() -> Bool {
            nodes -= 1
            return nodes > 0 && Date() < deadline
        }
    }

    static func read(pid: pid_t) -> ThreadText? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = (AX.attr(app, kAXFocusedWindowAttribute) ?? AX.attr(app, kAXMainWindowAttribute))
            .map({ $0 as! AXUIElement }) else {
            DebugLog.write("thread: no Slack window")
            return nil
        }
        let focused = AX.focusedElement(ofApp: app)

        var budget = Budget()
        var how = "landmark"
        var lines: [String]
        if let pane = findThreadPane(in: window, budget: &budget) {
            lines = collect(pane, skipping: focused)
        } else if let found = regionAround(focused, window: window) {
            how = "around the message box"
            lines = found
        } else {
            DebugLog.write("thread: no thread pane found; structure \(structure(of: window))")
            return nil
        }
        lines = dedupe(lines)
        DebugLog.write("thread: read \(lines.count) lines via \(how)")
        guard !lines.isEmpty else { return nil }

        // Keep the newest messages when the thread is longer than the server accepts.
        var total = lines.reduce(0) { $0 + $1.count + 1 }
        var dropped = 0
        while total > maxChars, dropped < lines.count - 1 {
            total -= lines[dropped].count + 1
            dropped += 1
        }
        if dropped > 0 { DebugLog.write("thread: dropped the oldest \(dropped) lines to fit \(maxChars) chars") }
        return ThreadText(text: lines[dropped...].joined(separator: "\n"), truncated: dropped > 0)
    }

    // MARK: - Finding the thread pane

    /// A landmark/region whose label says "Thread" (or the Indonesian "Utas").
    private static func findThreadPane(in window: AXUIElement, budget: inout Budget) -> AXUIElement? {
        var queue = [window]
        var index = 0
        while index < queue.count, budget.spend() {
            let el = queue[index]
            index += 1
            let subrole = AX.string(el, kAXSubroleAttribute) ?? ""
            if subrole.contains("Landmark") || subrole == "AXApplicationGroup" {
                let label = [AX.string(el, kAXDescriptionAttribute), AX.string(el, kAXTitleAttribute)]
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                if label.contains("thread") || label.contains("utas") { return el }
            }
            queue.append(contentsOf: AX.children(el))
        }
        return nil
    }

    /// Fallback: climb from the focused message box to the smallest enclosing region with enough text.
    private static func regionAround(_ focused: AXUIElement?, window: AXUIElement) -> [String]? {
        guard var el = focused else { return nil }
        for _ in 0..<14 {
            guard let up = AX.parent(el) else { return nil }
            el = up
            if (AX.string(el, kAXRoleAttribute) ?? "") == "AXWebArea" || CFEqual(el, window) { return nil }
            let lines = collect(el, skipping: focused)
            if lines.count >= minLines { return lines }
        }
        return nil
    }

    // MARK: - Collecting text

    /// Text runs under `root` in document order, one line per container. Skips the message box and controls.
    private static func collect(_ root: AXUIElement, skipping skip: AXUIElement?) -> [String] {
        var budget = Budget()
        var lines: [String] = []
        var runs: [String] = []

        func flush() {
            let line = runs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
            runs.removeAll()
        }

        func visit(_ el: AXUIElement, depth: Int) {
            guard depth < maxDepth, budget.spend() else { return }
            if let skip, CFEqual(el, skip) { return }
            let role = AX.string(el, kAXRoleAttribute) ?? ""
            if skippedRoles.contains(role) { return }
            // An editable field is a message box, not part of the conversation.
            if (role == kAXTextAreaRole as String || role == kAXTextFieldRole as String),
               AX.isSettable(el, kAXValueAttribute) { return }

            let kids = AX.children(el)
            if kids.isEmpty {
                if let text = leafText(el, role: role) { runs.append(text) }
                return
            }
            for kid in kids { visit(kid, depth: depth + 1) }
            flush()
        }

        visit(root, depth: 0)
        flush()
        return lines
    }

    /// The text of an element without children: static text, or a link such as an author name or timestamp.
    private static func leafText(_ el: AXUIElement, role: String) -> String? {
        let candidates: [String?]
        switch role {
        case kAXStaticTextRole as String, kAXTextAreaRole as String, kAXTextFieldRole as String:
            candidates = [AX.string(el, kAXValueAttribute), AX.string(el, kAXDescriptionAttribute)]
        case "AXLink", "AXHeading", kAXGroupRole as String:
            candidates = [AX.string(el, kAXTitleAttribute), AX.string(el, kAXDescriptionAttribute),
                          AX.string(el, kAXValueAttribute)]
        default:
            return nil
        }
        let text = candidates.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Chromium often exposes a link's title and its text child separately, so adjacent duplicates are dropped.
    private static func dedupe(_ lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines where line != out.last { out.append(line) }
        return out
    }

    // MARK: - Debugging

    /// Roles only (no text), a few levels deep, so an unexpected Slack layout can be diagnosed from the log.
    private static func structure(of root: AXUIElement, depth: Int = 0, maxLevels: Int = 5) -> String {
        let role = (AX.string(root, kAXRoleAttribute) ?? "?").replacingOccurrences(of: "AX", with: "")
        let subrole = (AX.string(root, kAXSubroleAttribute) ?? "").replacingOccurrences(of: "AX", with: "")
        let name = subrole.isEmpty ? role : "\(role)/\(subrole)"
        guard depth < maxLevels else { return name }
        let kids = AX.children(root)
        if kids.isEmpty { return name }
        let shown = kids.prefix(8).map { structure(of: $0, depth: depth + 1, maxLevels: maxLevels) }
        return "\(name)[\(shown.joined(separator: ","))\(kids.count > 8 ? ",+\(kids.count - 8)" : "")]"
    }
}

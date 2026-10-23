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
/// otherwise takes the smallest region around the message box that holds several lines of text. The reader's own
/// log lines record counts and roles only; the controller writes the thread text to the debug log when a summary is
/// requested.
enum ThreadReader {
    static let slackBundleId = "com.tinyspeck.slackmacgap"
    /// Under the server's SUMMARIZE_MAX_CHARS (40000).
    static let maxChars = 38_000
    private static let maxNodes = 25_000, maxDepth = 60, timeLimit: TimeInterval = 6
    private static let minLines = 3
    /// Around Slack's own button the header (title, channel name) holds a few lines too, so ask for more.
    private static let buttonRegionLines = 6
    /// Scrolling the pane to read all of a long thread: how far each step goes (of the pane's height), the most steps in
    /// either direction, and the time allowed for the whole pass.
    private static let scrollStepFraction = 0.7, maxScrollSteps = 40, scrollTimeLimit: TimeInterval = 15

    /// Roles that carry no conversation text, and whose subtrees are skipped. Buttons are handled separately: Slack
    /// makes author names buttons, so their label is kept unless it is a known interface button.
    private static let skippedRoles: Set<String> = [
        kAXImageRole as String, kAXScrollBarRole as String, kAXMenuRole as String,
        kAXMenuItemRole as String, kAXMenuButtonRole as String, kAXPopUpButtonRole as String,
        kAXCheckBoxRole as String, kAXRadioButtonRole as String, kAXSliderRole as String,
        kAXProgressIndicatorRole as String, "AXTab",
    ]

    private struct Budget {
        var nodes: Int
        let deadline: Date
        init(nodes: Int = ThreadReader.maxNodes, limit: TimeInterval = ThreadReader.timeLimit) {
            self.nodes = nodes
            deadline = Date().addingTimeInterval(limit)
        }
        mutating func spend() -> Bool {
            nodes -= 1
            return nodes > 0 && Date() < deadline
        }
    }

    static func read(pid: pid_t) -> ThreadText? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = focusedWindow(app) else {
            DebugLog.write("thread: no Slack window")
            return nil
        }
        // Only the message box is left out of the text. Slack often focuses a message (a plain group) in the thread
        // pane, and skipping that would drop it: the parent message went missing exactly that way.
        let focusedNow = AX.focusedElement(ofApp: app)
        let focused = focusedNow.flatMap { isMessageBox($0) ? $0 : nil }
        if let focusedNow, focused == nil {
            DebugLog.write("thread: focused element is \(AX.string(focusedNow, kAXRoleAttribute) ?? "?"), not a message box; kept in the text")
        }

        var budget = Budget()
        let found = scan(window, budget: &budget)
        var how = "landmark"
        var lines: [String]
        var root: AXUIElement? // the element the lines were read from
        if let button = found.button,
           let region = regionAround(button, skipping: focused, window: window, minLines: buttonRegionLines) {
            how = "around Slack's Summarize thread button"
            (root, lines) = widen(region, skipping: focused, window: window)
        } else if let pane = found.pane {
            (root, lines) = (pane, collect(pane, skipping: focused))
        } else if let region = regionAround(focused, skipping: focused, window: window, minLines: minLines) {
            how = "around the message box"
            (root, lines) = (region.element, region.lines)
        } else {
            DebugLog.write("thread: no thread pane found; structure \(structure(of: window))")
            return nil
        }
        lines = cleaned(lines)
        DebugLog.write("thread: read \(lines.count) lines via \(how)")
        if let root, !lines.isEmpty {
            lines = gatherByScrolling(root: root, pid: pid, skipping: focused, visible: lines)
        }
        if let root, DebugLog.enabled { DebugLog.write("thread structure (roles and text lengths only):\n\(outline(of: root))") }
        guard !lines.isEmpty else { return nil }

        // One {{ ... }} group per message; keep the newest messages when the thread is longer than the server accepts.
        let messages = ThreadFormat.messages(from: lines)
        var total = messages.reduce(0) { $0 + $1.count + 2 } // plus the blank line between messages
        var dropped = 0
        while total > maxChars, dropped < messages.count - 1 {
            total -= messages[dropped].count + 2
            dropped += 1
        }
        if dropped > 0 { DebugLog.write("thread: dropped the oldest \(dropped) messages to fit \(maxChars) chars") }
        return ThreadText(text: messages[dropped...].joined(separator: "\n\n"), truncated: dropped > 0)
    }

    /// An editable text field: where the user types a message, never part of the conversation.
    private static func isMessageBox(_ el: AXUIElement) -> Bool {
        let role = AX.string(el, kAXRoleAttribute) ?? ""
        return role == kAXTextAreaRole as String || role == kAXTextFieldRole as String
            || AX.isSettable(el, kAXValueAttribute)
    }

    private static func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        (AX.attr(app, kAXFocusedWindowAttribute) ?? AX.attr(app, kAXMainWindowAttribute)).map { $0 as! AXUIElement }
    }

    /// Slack's own "Summarize thread" button, which the floating Summarize button goes beside; its presence is what
    /// says a thread is open. Global AX coordinates.
    struct Anchor {
        let element: AXUIElement
        let frame: CGRect
    }

    /// Slack's "Summarize thread" button in its window, nil when no thread is open. Cheap enough to poll: a
    /// still-valid `cached` button is just re-measured. A fresh search finds the thread pane first (a landmark labelled
    /// "Thread", quick to reach) and then looks for the button inside it with its own budget and a looser match; with no
    /// pane it looks for the exact button anywhere in the window. When nothing is found it logs the labels of the
    /// buttons in the header, so an unexpected Slack layout can be diagnosed from the log.
    static func detectAnchor(pid: pid_t, cached: Anchor?) -> Anchor? {
        if let cached, let frame = liveFrame(of: cached.element) { return Anchor(element: cached.element, frame: frame) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = focusedWindow(app) else { return nil }
        var budget = Budget(nodes: 12_000, limit: 2.5)
        let found = scan(window, budget: &budget, stopAtPane: true)
        if let button = found.button, let frame = liveFrame(of: button) { return Anchor(element: button, frame: frame) }
        if let pane = found.pane {
            var inner = Budget(nodes: 6_000, limit: 1.5)
            if let button = findSummarizeButton(in: pane, budget: &inner, loose: true), let frame = liveFrame(of: button) {
                return Anchor(element: button, frame: frame)
            }
            diagnose(root: pane, what: "thread pane")
        } else {
            diagnose(root: window, what: "window")
        }
        return nil
    }

    /// Whether Slack has a visible (not minimized) window. Two cheap lookups, with a short timeout so a busy Slack can't
    /// stall the watcher.
    static func isWindowShowing(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let window = focusedWindow(app) else { return false }
        return (AX.attr(window, kAXMinimizedAttribute) as? Bool) != true
    }

    /// The button's frame while the element is still alive. Slack's is a small icon button, so only reject slivers.
    private static func liveFrame(of button: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(button, 0.3)
        guard AX.string(button, kAXRoleAttribute) != nil, let frame = AX.frame(button),
              frame.width >= 12, frame.height >= 12 else { return nil }
        return frame
    }

    private static let buttonRoles: Set<String> = [
        kAXButtonRole as String, kAXMenuButtonRole as String, kAXPopUpButtonRole as String,
    ]

    /// Breadth-first search under `root` for Slack's "Summarize thread" button. `loose` (used inside the thread pane,
    /// where the context already says it is a thread) accepts any button labelled "summarize".
    private static func findSummarizeButton(in root: AXUIElement, budget: inout Budget, loose: Bool = false) -> AXUIElement? {
        var queue = [root]
        var index = 0
        while index < queue.count, budget.spend() {
            let el = queue[index]
            index += 1
            if buttonRoles.contains(AX.string(el, kAXRoleAttribute) ?? ""), isSummarizeButton(el, loose: loose) { return el }
            queue.append(contentsOf: AX.children(el))
        }
        return nil
    }

    private static var lastDiagnosis = Date.distantPast

    /// Logs (at most every 20 s) the buttons near the top of `root` as role|title|description|help|id|size, so the log
    /// shows how Slack labels its header buttons. Only controls in the header strip are listed, never message text.
    private static func diagnose(root: AXUIElement, what: String) {
        guard Date().timeIntervalSince(lastDiagnosis) >= 20 else { return }
        lastDiagnosis = Date()
        guard let top = AX.frame(root)?.minY else { return }
        func cut(_ s: String?) -> String { String((s ?? "").prefix(30)).replacingOccurrences(of: "|", with: "/") }
        var budget = Budget(nodes: 4_000, limit: 1.0)
        var queue = [root]
        var index = 0
        var entries: [String] = []
        while index < queue.count, budget.spend(), entries.count < 24 {
            let el = queue[index]
            index += 1
            let role = AX.string(el, kAXRoleAttribute) ?? ""
            if buttonRoles.contains(role) || role == "AXLink", let frame = AX.frame(el), frame.minY - top < 140 {
                entries.append("\(role.replacingOccurrences(of: "AX", with: ""))|\(cut(AX.string(el, kAXTitleAttribute)))|"
                    + "\(cut(AX.string(el, kAXDescriptionAttribute)))|\(cut(AX.string(el, kAXHelpAttribute)))|"
                    + "\(cut(AX.string(el, "AXIdentifier")))|\(Int(frame.width))x\(Int(frame.height))")
            }
            queue.append(contentsOf: AX.children(el))
        }
        DebugLog.write("thread: no Summarize thread button in the \(what); header controls: \(entries.isEmpty ? "none" : entries.joined(separator: " ; "))")
    }

    // MARK: - Finding the thread

    /// One breadth-first pass over the window for the thread pane (a landmark/region labelled "Thread", or the
    /// Indonesian "Utas") and Slack's own "Summarize thread" button. The pane is an ancestor of the button, so it
    /// has been seen by the time the button turns up, and the search stops there.
    private static func scan(_ window: AXUIElement, budget: inout Budget,
                             stopAtPane: Bool = false) -> (pane: AXUIElement?, button: AXUIElement?) {
        var pane: AXUIElement?
        var queue = [window]
        var index = 0
        while index < queue.count, budget.spend() {
            let el = queue[index]
            index += 1
            if pane == nil {
                let subrole = AX.string(el, kAXSubroleAttribute) ?? ""
                if subrole.contains("Landmark") || subrole == "AXApplicationGroup" {
                    let label = [AX.string(el, kAXDescriptionAttribute), AX.string(el, kAXTitleAttribute)]
                        .compactMap { $0 }.joined(separator: " ").lowercased()
                    if hasWord(label, "thread") || hasWord(label, "utas") {
                        pane = el
                        if stopAtPane { return (el, nil) }
                    }
                }
            }
            if buttonRoles.contains(AX.string(el, kAXRoleAttribute) ?? ""), isSummarizeButton(el) { return (pane, el) }
            queue.append(contentsOf: AX.children(el))
        }
        return (pane, nil)
    }

    /// Whether `text` (lowercased) contains `word` as a whole word, so "thread" matches "Thread" and "Thread in #general"
    /// but not Slack's "Threads" view.
    static func hasWord(_ text: String, _ word: String) -> Bool {
        text.range(of: "(?<![\\p{L}\\p{N}])\(word)(?![\\p{L}\\p{N}])", options: .regularExpression) != nil
    }

    /// Slack's own "Summarize thread" button: a short label saying so, on the button or on a direct child (the text
    /// inside it). Only buttons count, so a message that happens to say "summarize thread" can't match.
    private static func isSummarizeButton(_ button: AXUIElement, loose: Bool = false) -> Bool {
        func matches(_ el: AXUIElement) -> Bool {
            let label = [AX.string(el, kAXTitleAttribute), AX.string(el, kAXDescriptionAttribute), AX.string(el, kAXValueAttribute),
                         AX.string(el, kAXHelpAttribute), AX.string(el, "AXIdentifier")]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            guard label.count <= 80 else { return false }
            if loose { return label.contains("summar") || label.contains("ringkas") }
            return (label.contains("summar") && hasWord(label, "thread")) || (label.contains("ringkas") && hasWord(label, "utas"))
        }
        return matches(button) || AX.children(button).contains(where: matches)
    }

    /// Fallback: climb from `start` to the smallest enclosing region with at least `minLines` lines of text.
    private static func regionAround(_ start: AXUIElement?, skipping skip: AXUIElement?, window: AXUIElement,
                                     minLines: Int) -> (element: AXUIElement, lines: [String])? {
        guard var el = start else { return nil }
        for _ in 0..<14 {
            guard let up = AX.parent(el) else { return nil }
            el = up
            if (AX.string(el, kAXRoleAttribute) ?? "") == "AXWebArea" || CFEqual(el, window) { return nil }
            let lines = collect(el, skipping: skip)
            if lines.count >= minLines { return (el, lines) }
        }
        return nil
    }

    /// The thread's first message (the one that started it) sits above the replies, often in a sibling of the smallest
    /// region that holds several lines. So keep climbing while the ancestor is still a side pane (at most 60% of the
    /// window wide), and read from the widest one; the channel list and the main conversation are wider than that.
    private static func widen(_ region: (element: AXUIElement, lines: [String]), skipping skip: AXUIElement?,
                              window: AXUIElement) -> (element: AXUIElement, lines: [String]) {
        guard let windowWidth = AX.frame(window)?.width, windowWidth > 0 else { return region }
        var best = region
        var el = region.element
        for _ in 0..<8 {
            guard let up = AX.parent(el) else { break }
            el = up
            if (AX.string(el, kAXRoleAttribute) ?? "") == "AXWebArea" || CFEqual(el, window) { break }
            if let width = AX.frame(el)?.width, width > windowWidth * 0.6 { break }
            let lines = collect(el, skipping: skip)
            if lines.count >= best.lines.count { best = (el, lines) }
        }
        if !CFEqual(best.element, region.element) {
            DebugLog.write("thread: widened the region from \(region.lines.count) to \(best.lines.count) lines")
        }
        return best
    }

    // MARK: - Scrolling

    /// Slack (Chromium) only puts the messages near the viewport into the accessibility tree, so a long thread has to be
    /// scrolled through. This scrolls the pane to its top, reads a screenful, scrolls down a step at a time reading each,
    /// and merges the views by their overlap. Scrolling is smooth (scroll-wheel events in small slices); when Slack
    /// ignores those, the accessibility tree is asked to bring the first/last rendered message into view instead, which
    /// works but jumps. Any problem (no scrolling happens, no overlap) just leaves what was read. The pane always goes
    /// to the top first and is back at the top when done.
    private static func gatherByScrolling(root: AXUIElement, pid: pid_t, skipping skip: AXUIElement?,
                                          visible: [String]) -> [String] {
        guard let frame = AX.frame(root), frame.height > 200 else { return visible }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let deadline = Date().addingTimeInterval(scrollTimeLimit)
        let list = findList(in: root)
        var step = frame.height * scrollStepFraction
        var wheelUsable = true // until the accessibility action moves the pane where the wheel did not
        var wheelSign: CGFloat = 1 // flips if Slack scrolls the opposite way to what was asked
        var wheelMoves = 0, jumpMoves = 0

        /// Scroll-wheel events in small slices so the pane glides like under a trackpad. Positive = towards the top.
        func smoothScroll(_ dy: CGFloat) {
            let slices = 10
            for _ in 0..<slices {
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: Int32((dy / CGFloat(slices)).rounded()), wheel2: 0, wheel3: 0) else { return }
                event.location = point
                event.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.012)
            }
        }
        /// Where the list's rendered items are on screen. It shifts whenever the pane really scrolls, even when the text read
        /// stays the same (Slack renders a buffer of messages beyond the viewport), and stays put at the top or bottom, so
        /// it is what tells a scroll that moved from one that hit the end.
        func positions() -> [Int] {
            guard let list else { return [] }
            return AX.children(list).compactMap { AX.frame($0).map { Int($0.minY.rounded()) } }
        }
        /// The view once scrolling has settled (smooth scrolling and rendering take a moment).
        func settledView() -> [String] {
            var previous: [String]?
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 0.12)
                let view = cleaned(collect(root, skipping: skip))
                if let previous, sameView(previous, view) { return view }
                previous = view
            }
            return previous ?? []
        }
        /// Moves the pane one step towards the top (`up`) or bottom and returns the new view, nil when it did not move
        /// (the end of the thread). The wheel is tried first; a move that overshoots (no overlap with what was read) is
        /// undone and retried with a smaller step, and one that went the wrong way flips the direction.
        func advance(up: Bool, from current: [String]) -> [String]? {
            let name = up ? "up" : "down"
            var wheelDidMove = false
            let before = positions()
            if wheelUsable {
                for _ in 0..<4 {
                    let delta = (up ? step : -step) * wheelSign
                    smoothScroll(delta)
                    let view = settledView()
                    if view.isEmpty || (sameView(view, current) && positions() == before) { break } // not moved
                    wheelDidMove = true
                    let forward = up ? merge(view, current).overlapped : merge(current, view).overlapped
                    if forward { wheelMoves += 1; return view }
                    let backward = up ? merge(current, view).overlapped : merge(view, current).overlapped
                    smoothScroll(-delta) // undo, then try again
                    _ = settledView()
                    if backward { wheelSign = -wheelSign } else { step = max(100, step / 2) }
                }
            }
            let items = list.map { AX.children($0) } ?? []
            guard let list, let item = up ? items.first : items.last else {
                DebugLog.write("thread: scroll \(name) stopped (wheel moved: \(wheelDidMove), no list item to scroll to)")
                return nil
            }
            let result = AXUIElementPerformAction(item, "AXScrollToVisible" as CFString)
            guard result == .success else {
                DebugLog.write("thread: scroll \(name) stopped (wheel moved: \(wheelDidMove), AXScrollToVisible error \(result.rawValue))")
                return nil
            }
            let view = settledView()
            guard !view.isEmpty, !sameView(view, current) || positions() != before else {
                DebugLog.write("thread: scroll \(name) stopped (wheel moved: \(wheelDidMove), AXScrollToVisible changed nothing)")
                return nil
            }
            if !wheelDidMove, wheelMoves == 0 { wheelUsable = false } // the wheel is ignored, only the jump works
            jumpMoves += 1
            return view
        }

        // Up to the top.
        var current = visible
        var upSteps = 0
        while upSteps < maxScrollSteps, Date() < deadline, let next = advance(up: true, from: current) {
            current = next
            upSteps += 1
        }

        // Down to the bottom, merging.
        var all = current
        var downSteps = 0
        while downSteps < maxScrollSteps, Date() < deadline, let next = advance(up: false, from: current) {
            let merged = merge(all, next)
            all = merged.lines
            current = next
            downSteps += 1
        }

        // Done: scroll back to the top, where the thread starts. Big wheel moves while the items still shift, then the
        // normal step to be sure of the top.
        if downSteps > 0 {
            if wheelUsable {
                for _ in 0..<maxScrollSteps {
                    let before = positions()
                    smoothScroll(step * 3 * wheelSign)
                    Thread.sleep(forTimeInterval: 0.25)
                    if positions() == before { break }
                }
            }
            var back = 0
            while back < maxScrollSteps, let next = advance(up: true, from: current) {
                current = next
                back += 1
            }
        }
        DebugLog.write("thread: scrolled \(upSteps) steps up and \(downSteps) down (\(wheelMoves) smooth, \(jumpMoves) jumps); "
            + "\(visible.count) → \(all.count) lines")
        return all
    }

    /// The message list inside the pane: the first list with several items.
    private static func findList(in root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var seen = 0
        while !queue.isEmpty, seen < 3000 {
            let el = queue.removeFirst()
            seen += 1
            let kids = AX.children(el)
            if (AX.string(el, kAXRoleAttribute) ?? "") == "AXList", kids.count >= 3 { return el }
            queue.append(contentsOf: kids)
        }
        return nil
    }

    /// Lines as compared across views: a message's relative time ("32 minutes ago") may roll over while scrolling.
    private static func normalized(_ line: String) -> String {
        line.replacingOccurrences(of: #" \[[^\]]*\]"#, with: "", options: .regularExpression)
    }

    private static func sameView(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { normalized($0) == normalized($1) }
    }

    /// `next` appended to `all` without the lines they share: the longest tail of `all` that is also the head of `next`.
    /// `overlapped` is false when there is none.
    private static func merge(_ all: [String], _ next: [String]) -> (lines: [String], overlapped: Bool) {
        let a = all.map(normalized), n = next.map(normalized)
        var k = min(a.count, n.count)
        while k > 0, Array(a.suffix(k)) != Array(n.prefix(k)) { k -= 1 }
        return (all + next.dropFirst(k), k > 0)
    }

    /// One read's lines with duplicates, interface chrome and the pane's title line removed.
    private static func cleaned(_ lines: [String]) -> [String] {
        var out = dedupe(lines).filter { !ThreadNoise.isInterfaceLine($0) }
        if let first = out.first, ThreadNoise.isPaneTitle(first) { out.removeFirst() }
        return out
    }

    // MARK: - Collecting text

    /// Text runs under `root` in document order, one line per container. Skips the message box and controls.
    private static func collect(_ root: AXUIElement, skipping skip: AXUIElement?) -> [String] {
        var budget = Budget()
        var lines: [String] = []
        var runs: [String] = []
        var firstIsButton = false // whether the first run of the current line came from a button (an author's name)

        func flush() {
            if !runs.isEmpty { lines.append(ThreadFormat.line(from: runs, firstIsButton: firstIsButton)) }
            runs.removeAll()
        }

        func visit(_ el: AXUIElement, depth: Int) {
            guard depth < maxDepth, budget.spend() else { return }
            if let skip, CFEqual(el, skip) { return }
            let role = AX.string(el, kAXRoleAttribute) ?? ""
            if role == kAXButtonRole as String {
                if let label = buttonLabel(el), !ThreadNoise.isInterfaceButton(label) {
                    if runs.isEmpty { firstIsButton = true }
                    runs.append(label)
                }
                return
            }
            if skippedRoles.contains(role) { return }
            // An editable field is a message box, not part of the conversation.
            if (role == kAXTextAreaRole as String || role == kAXTextFieldRole as String),
               AX.isSettable(el, kAXValueAttribute) { return }

            let kids = AX.children(el)
            if kids.isEmpty {
                if let text = leafText(el, role: role) {
                    if runs.isEmpty { firstIsButton = false }
                    runs.append(text)
                }
                return
            }
            for kid in kids { visit(kid, depth: depth + 1) }
            flush()
        }

        visit(root, depth: 0)
        flush()
        return lines
    }

    /// A button's label: its own title/description/value, else the text inside it (Slack's author names are buttons).
    private static func buttonLabel(_ button: AXUIElement) -> String? {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.count <= 300 else { return nil }
            return t
        }
        func label(_ el: AXUIElement) -> String? {
            clean(AX.string(el, kAXTitleAttribute)) ?? clean(AX.string(el, kAXDescriptionAttribute))
                ?? clean(AX.string(el, kAXValueAttribute))
        }
        if let own = label(button) { return own }
        for child in AX.children(button) { if let inner = label(child) { return inner } }
        return nil
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

    /// The tree under `root` as indented lines (role/subrole, child count, and the lengths of title, description and
    /// value): enough to see what a message is made of and what the reader skipped, without any message text.
    private static func outline(of root: AXUIElement, maxNodes: Int = 250, maxDepth: Int = 16) -> String {
        var out: [String] = []
        func visit(_ el: AXUIElement, _ depth: Int) {
            guard out.count < maxNodes, depth <= maxDepth else { return }
            let role = (AX.string(el, kAXRoleAttribute) ?? "?").replacingOccurrences(of: "AX", with: "")
            let sub = (AX.string(el, kAXSubroleAttribute) ?? "").replacingOccurrences(of: "AX", with: "")
            let kids = AX.children(el)
            func length(_ attribute: String) -> Int { AX.string(el, attribute)?.count ?? 0 }
            out.append("\(String(repeating: " ", count: depth))\(role)\(sub.isEmpty ? "" : "/\(sub)") kids=\(kids.count) "
                + "title=\(length(kAXTitleAttribute)) desc=\(length(kAXDescriptionAttribute)) value=\(length(kAXValueAttribute))")
            for kid in kids { visit(kid, depth + 1) }
        }
        visit(root, 0)
        return out.joined(separator: "\n")
    }

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

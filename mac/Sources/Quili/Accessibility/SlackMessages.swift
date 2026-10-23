import AppKit
import ApplicationServices

/// One message of Slack's main channel list, read through the DOM classes Chromium exposes (`AXDOMClassList`).
struct SlackMessage {
    /// Slack's `ts` when the permalink is readable, otherwise a hash of author, time and text.
    let key: String
    let author: String
    let time: String
    let text: String
    let replyCount: Int?
    /// Global AX coordinates (top-left origin).
    let frame: CGRect?

    /// The message as Hermes gets it, the same shape as a thread's (`ThreadFormat.messages`).
    var formatted: String {
        var lines = ["\(author) [\(time.isEmpty ? "?" : time)]"] + text.components(separatedBy: "\n")
        if let replyCount, replyCount > 0 { lines.append("(\(replyCount) \(replyCount == 1 ? "reply" : "replies") in thread)") }
        let escaped = lines.map { $0.replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}") }
        return "{{" + escaped.joined(separator: "\n") + "}}"
    }
}

/// Reads Slack's main conversation (the channel, not the thread pane) by Slack's own CSS classes, as calibrated in
/// slack-to-hermes (2026-10-23). Used for the range chips (Q4); the thread summary keeps `ThreadReader`.
/// Not main-actor: AX calls into Slack can block.
enum SlackMessages {
    static let channelPane = ["p-message_pane", "p-workspace__primary_view_body"]
    static let threadPane = ["p-threads_flexpane_container", "p-threads_flexpane", "p-flexpane"]
    static let item = "c-virtual_list__item"
    static let sender = ["c-message__sender_button", "c-message_kit__sender"]
    static let timestamp = "c-timestamp"
    static let text = ["p-rich_text_section", "c-message_kit__blocks", "p-rich_text_block", "c-message__body"]
    static let replyBar = ["c-message__reply_count", "c-message__reply_bar"]
    static let scroller = "c-scrollbar__hider"

    static func classes(_ el: AXUIElement) -> [String] { (AX.attr(el, "AXDOMClassList") as? [String]) ?? [] }

    static func hasClass(_ el: AXUIElement, _ prefix: String) -> Bool {
        classes(el).contains { $0 == prefix || $0.hasPrefix(prefix) }
    }

    static func window(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return (AX.attr(app, kAXFocusedWindowAttribute) ?? AX.attr(app, kAXMainWindowAttribute)).map { $0 as! AXUIElement }
    }

    /// The channel pane's message list and the pane's frame, for hover lookups. Found by a tree search (~75 ms), so
    /// callers keep it and only look again when it goes stale.
    static func messageList(pid: pid_t) -> (list: AXUIElement, paneFrame: CGRect)? {
        guard let pane = channel(pid: pid), let paneFrame = AX.frame(pane),
              let row = first(in: pane, limit: 30_000, where: { hasClass($0, item) }), let list = AX.parent(row) else { return nil }
        return (list, paneFrame)
    }

    /// The channel message whose row contains `point` (global AX coordinates). Asking the system what is under the
    /// point is unreliable for Slack (it can answer with the menu bar), so the rows' frames are compared instead: one
    /// cheap frame read per rendered row. A message without its own author line takes the author above it.
    static func message(at point: CGPoint, list: AXUIElement, paneFrame: CGRect) -> SlackMessage? {
        guard paneFrame.contains(point) else { return nil }
        let rows = AX.children(list).filter { hasClass($0, item) }
        // Dividers ("Today", "New messages") are rows too and can overlap a message's edge: take the first message.
        var found: (index: Int, message: SlackMessage)?
        for (index, row) in rows.enumerated() where AX.frame(row)?.contains(point) ?? false {
            if let message = read(row, lastSender: nil) { found = (index, message); break }
        }
        guard let (index, first) = found else { return nil }
        var message = first
        if message.author == "Unknown" {
            for row in rows[..<index].reversed().prefix(15) {
                if let above = read(row, lastSender: nil), above.author != "Unknown" {
                    message = SlackMessage(key: message.key, author: above.author, time: message.time, text: message.text,
                                           replyCount: message.replyCount, frame: message.frame)
                    break
                }
            }
        }
        return message
    }

    /// The channel pane of the focused Slack window.
    static func channel(pid: pid_t) -> AXUIElement? {
        guard let window = window(pid: pid) else { return nil }
        return first(in: window, limit: 20_000) { el in classes(el).contains { channelPane.contains($0) } }
    }

    /// The messages the channel pane renders now, oldest first.
    static func visible(in pane: AXUIElement) -> [SlackMessage] {
        var lastSender: String?
        return all(in: pane, limit: 30_000) { hasClass($0, item) }.compactMap { el in
            let message = read(el, lastSender: lastSender)
            if let message { lastSender = message.author }
            return message
        }
    }

    /// Where the pane's items are on screen; it shifts when the pane really scrolls.
    static func positions(in pane: AXUIElement) -> [Int] {
        all(in: pane, limit: 30_000) { hasClass($0, item) }.compactMap { AX.frame($0).map { Int($0.minY.rounded()) } }
    }

    static func read(_ item: AXUIElement, lastSender: String?) -> SlackMessage? {
        let stamp = first(in: item) { hasClass($0, timestamp) }
        let body = first(in: item) { el in text.contains { hasClass(el, $0) } }
        guard stamp != nil || body != nil else { return nil } // date dividers, "new messages" markers
        let senderNode = first(in: item) { el in sender.contains { hasClass(el, $0) } }
        let author = senderNode.flatMap { AX.string($0, kAXTitleAttribute) ?? plainText($0) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? lastSender ?? "Unknown"
        let time = stamp.flatMap { AX.string($0, kAXDescriptionAttribute) ?? AX.string($0, kAXTitleAttribute) ?? plainText($0) } ?? ""
        let permalink = stamp.flatMap { (AX.attr($0, kAXURLAttribute) as? URL)?.absoluteString }
        let blocks = all(in: item) { el in classes(el).contains { $0.hasPrefix("p-rich_text_") } }
        var content = blocks.map(plainText).filter { !$0.isEmpty }.joined(separator: "\n")
        if content.isEmpty { content = body.map(plainText) ?? "" }
        let reply = first(in: item) { el in replyBar.contains { hasClass(el, $0) } }
        let replies = reply.flatMap { AX.string($0, kAXTitleAttribute) ?? plainText($0) }.flatMap { Int($0.filter(\.isNumber)) }
        let key = permalink.flatMap(ts(fromPermalink:)) ?? heuristicKey(author: author, time: time, text: content)
        return SlackMessage(key: key, author: author, time: time, text: content, replyCount: replies, frame: AX.frame(item))
    }

    /// Slack permalinks end with `/p<ts without the dot>`.
    static func ts(fromPermalink link: String) -> String? {
        guard let range = link.range(of: #"/p(\d{10})(\d{6})"#, options: .regularExpression) else { return nil }
        let digits = link[range].dropFirst(2)
        return "\(digits.prefix(10)).\(digits.suffix(6))"
    }

    static func heuristicKey(author: String, time: String, text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a
        for byte in "\(author)\u{1F}\(time)\u{1F}\(text)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return "h:" + String(hash, radix: 16)
    }

    // MARK: - Tree helpers

    /// The visible text under `root`: static texts, and childless links (names, URLs).
    static func plainText(_ root: AXUIElement) -> String {
        var parts: [String] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (el, depth) = stack.popLast(), parts.count < 2_000 {
            let role = AX.string(el, kAXRoleAttribute) ?? ""
            let kids = AX.children(el)
            if role == kAXStaticTextRole as String {
                if let value = [AX.string(el, kAXValueAttribute), AX.string(el, kAXTitleAttribute), AX.string(el, kAXDescriptionAttribute)]
                    .compactMap({ $0 }).first(where: { !$0.isEmpty }) { parts.append(value) }
            } else if role == "AXLink", kids.isEmpty, let title = AX.string(el, kAXTitleAttribute), !title.isEmpty {
                parts.append(title)
            }
            if depth < 30 { stack.append(contentsOf: kids.reversed().map { ($0, depth + 1) }) }
        }
        return parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func first(in root: AXUIElement, limit: Int = 5_000, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        all(in: root, limit: limit, max: 1, where: match).first
    }

    /// Depth-first, not descending into matches, bounded so a huge tree can't hang the caller.
    static func all(in root: AXUIElement, limit: Int = 5_000, max: Int = .max, where match: (AXUIElement) -> Bool) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while let (el, depth) = stack.popLast(), found.count < max, visited < limit {
            visited += 1
            if match(el) { found.append(el); continue }
            if depth < 60 { stack.append(contentsOf: AX.children(el).reversed().map { ($0, depth + 1) }) }
        }
        return found
    }
}

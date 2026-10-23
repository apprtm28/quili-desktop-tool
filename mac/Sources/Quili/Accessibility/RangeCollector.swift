import AppKit
import ApplicationServices

/// The messages between two anchors of Slack's main channel, and what is known about the read's completeness.
struct CollectedRange {
    let messages: [SlackMessage]
    let foundStart: Bool
    let foundEnd: Bool
    /// Neighbouring messages never seen next to each other: places where messages may be missing.
    let gaps: Int

    var coverage: ReadCoverage {
        ReadCoverage(messages: messages.count, droppedOldest: 0, reachedStart: foundStart && foundEnd,
                     stoppedEarly: gaps > 0, expectedReplies: nil)
    }
}

/// Collects a range of Slack's virtualised channel list (Q4, ported from slack-to-hermes' RangeCollector): it scrolls
/// until both anchors have been seen, merges the overlapping screens, and scrolls back to where the user was. The
/// anchor clicked last is on screen; the other one is usually above it (older), otherwise below. Blocking: call it off
/// the main thread.
enum RangeCollector {
    private static let maxSteps = 60, timeLimit: TimeInterval = 60, stepFraction: CGFloat = 0.5

    static func collect(pid: pid_t, startKey: String, endKey: String) -> CollectedRange? {
        guard let pane = SlackMessages.channel(pid: pid), let frame = AX.frame(pane) else {
            DebugLog.write("range: no channel pane")
            return nil
        }
        let scroller = SlackMessages.first(in: pane, limit: 20_000) { SlackMessages.hasClass($0, SlackMessages.scroller) }
        let area = scroller.flatMap(AX.frame) ?? frame
        let point = CGPoint(x: area.midX, y: area.midY)
        let deadline = Date().addingTimeInterval(timeLimit)
        var merger = MessageMerger()
        var net = 0 // wheel steps away from where the user was; negative = up
        var steps = 0

        func read() -> [SlackMessage] { SlackMessages.visible(in: pane) }
        func wheel(up: Bool) -> Bool {
            let before = SlackMessages.positions(in: pane)
            let pixels = Int32(max(120, area.height * stepFraction)) * (up ? 1 : -1)
            for _ in 0..<8 {
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: pixels / 8, wheel2: 0, wheel3: 0) else { return false }
                event.location = point
                event.postToPid(pid)
                Thread.sleep(forTimeInterval: 0.015)
            }
            Thread.sleep(forTimeInterval: 0.35)
            var moved = SlackMessages.positions(in: pane) != before
            if !moved { Thread.sleep(forTimeInterval: 0.6); moved = SlackMessages.positions(in: pane) != before }
            if moved { net += up ? -1 : 1 }
            return moved
        }
        /// Scrolls one way until both anchors are known or the list stops moving.
        func sweep(up: Bool) {
            var quiet = 0
            while !(merger.contains(startKey) && merger.contains(endKey)), steps < maxSteps, quiet < 3, Date() < deadline {
                let moved = wheel(up: up)
                steps += 1
                let window = read()
                let hasNew = window.contains { !merger.contains($0.key) }
                merger.merge(window, up: up)
                quiet = moved || hasNew ? 0 : quiet + 1
            }
        }

        merger.merge(read(), up: false)
        sweep(up: true)
        if !(merger.contains(startKey) && merger.contains(endKey)) {
            // Not above: go back down past the starting point and look below.
            while net < 0, Date() < deadline, wheel(up: false) {}
            sweep(up: false)
        }
        // Back to where the user was.
        var back = 0
        while net != 0, back < maxSteps * 2, Date().timeIntervalSince(deadline) < 15 {
            if !wheel(up: net > 0) { break }
            back += 1
        }

        let all = merger.messages
        let a = all.firstIndex { $0.key == startKey }, b = all.firstIndex { $0.key == endKey }
        var slice = all
        if let a, let b { slice = Array(all[min(a, b)...max(a, b)]) }
        else if let a { slice = Array(all[a...]) }
        else if let b { slice = Array(all[...b]) }
        DebugLog.write("range: \(slice.count) messages in \(steps) steps (start \(a != nil), end \(b != nil), gaps \(merger.gaps), back \(net == 0))")
        return CollectedRange(messages: slice, foundStart: a != nil, foundEnd: b != nil, gaps: merger.gaps)
    }
}

/// Merges overlapping windows of a virtualised list into one ordered list without duplicates (from slack-to-hermes).
struct MessageMerger {
    private(set) var messages: [SlackMessage] = []
    private(set) var gaps = 0
    private var index: [String: Int] = [:]
    private var neighbours: Set<[String]> = []

    func contains(_ key: String) -> Bool { index[key] != nil }

    mutating func merge(_ window: [SlackMessage], up: Bool) {
        var unique: [SlackMessage] = []
        for message in window where !unique.contains(where: { $0.key == message.key }) { unique.append(message) }
        guard !unique.isEmpty else { return }
        for (left, right) in zip(unique, unique.dropFirst()) { neighbours.insert([left.key, right.key]) }
        if messages.isEmpty { messages = unique; reindex(); return }

        // Real Slack timestamps give a total order.
        if (messages + unique).allSatisfy({ !$0.key.hasPrefix("h:") }) {
            for message in unique {
                if let existing = index[message.key] { messages[existing] = message } else { messages.append(message) }
            }
            messages.sort { (Double($0.key) ?? 0) < (Double($1.key) ?? 0) }
            reindex()
            return
        }
        // Otherwise place by overlap with what is known.
        guard let anchor = unique.firstIndex(where: { contains($0.key) }) else {
            messages = up ? unique + messages : messages + unique
            reindex()
            return
        }
        messages.insert(contentsOf: unique[..<anchor], at: index[unique[anchor].key]!)
        reindex()
        var cursor = index[unique[anchor].key]!
        for message in unique[anchor...] {
            if let existing = index[message.key] {
                messages[existing] = message
                cursor = existing
            } else {
                messages.insert(message, at: cursor + 1)
                reindex()
                cursor += 1
            }
        }
        reindex()
    }

    private mutating func reindex() {
        index = Dictionary(messages.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        gaps = zip(messages, messages.dropFirst()).filter { !neighbours.contains([$0.0.key, $0.1.key]) }.count
    }
}

import AppKit
import ApplicationServices

/// The channel message under the pointer: where its row is (global AX coordinates) and which conversation it is in.
struct ChannelHover {
    let key: String
    let frame: CGRect
    let message: SlackMessage
    let channel: String
    let pid: pid_t
}

/// Follows the pointer over Slack's main channel so a range chip can sit on the hovered message (Q4). Polls on a
/// background queue while Slack is in front, and only looks again when the pointer moved or every 0.4 s (Slack's list
/// can scroll under a still pointer). The thread pane and the sidebar never count.
final class ChannelWatcher {
    private let queue = DispatchQueue(label: "ChannelWatcher", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var lastPoint = CGPoint(x: -1, y: -1)
    private var lastCheck = Date.distantPast
    private var last: ChannelHover?
    /// The channel's message list, found again when it goes stale or every few seconds (Slack swaps it on navigation).
    private var list: (element: AXUIElement, paneFrame: CGRect, pid: pid_t, found: Date)?
    private var lastListSearch = Date.distantPast
    private static let interval: TimeInterval = 0.1, recheck: TimeInterval = 0.4

    private let lock = NSLock()
    private var pausedValue = false
    private var chipValue: CGRect = .null
    /// Written on the main queue, read on the polling queue.
    var paused: Bool {
        get { lock.withLock { pausedValue } }
        set { lock.withLock { pausedValue = newValue } }
    }
    /// The chip's frame (global AX coordinates): while the pointer is on it, the hovered message stays as it is.
    var chipFrame: CGRect {
        get { lock.withLock { chipValue } }
        set { lock.withLock { chipValue = newValue } }
    }
    /// Called on the main queue; nil when the pointer is not over a channel message.
    var onChange: ((ChannelHover?) -> Void)?

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard !paused, AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == ThreadReader.slackBundleId,
              let point = CGEvent(source: nil)?.location else { report(nil); return }
        if chipFrame.insetBy(dx: -4, dy: -4).contains(point) { return } // on the chip: keep the message it belongs to
        let moved = point != lastPoint
        guard moved || Date().timeIntervalSince(lastCheck) >= Self.recheck else { return }
        lastPoint = point
        lastCheck = Date()
        let pid = front.processIdentifier
        if let cached = list, cached.pid != pid || Date().timeIntervalSince(cached.found) > 3 || AX.frame(cached.element) == nil {
            list = nil
        }
        if list == nil, Date().timeIntervalSince(lastListSearch) >= 1 {
            lastListSearch = Date()
            if let found = SlackMessages.messageList(pid: pid) {
                list = (found.list, found.paneFrame, pid, Date())
            }
        }
        guard let list, let message = SlackMessages.message(at: point, list: list.element, paneFrame: list.paneFrame),
              let frame = message.frame else { report(nil); return }
        if let last, last.key == message.key, last.frame == frame { return }
        let channel = SlackMessages.window(pid: pid).map(ThreadReader.channelName) ?? ""
        report(ChannelHover(key: message.key, frame: frame, message: message, channel: channel, pid: pid))
    }

    private func report(_ hover: ChannelHover?) {
        if hover == nil && last == nil { return }
        last = hover
        DispatchQueue.main.async { [onChange] in onChange?(hover) }
    }
}

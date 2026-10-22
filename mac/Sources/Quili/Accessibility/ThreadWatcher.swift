import AppKit
import ApplicationServices

/// The open Slack thread, marked by Slack's own "Summarize thread" button: `frame` is that button (AX coordinates,
/// top-left origin), and the floating Summarize button goes beside it.
struct ThreadPane {
    let frame: CGRect
    let app: NSRunningApplication
}

/// Follows the open thread's Summarize-thread button while Slack is in front, so the floating button can sit beside it.
/// Polling runs on a background queue because Accessibility calls into another process can be slow.
///
/// Staying smooth: once the button is found only that one element is re-measured (a couple of cheap lookups), every
/// 30 ms while it is moving and every 120 ms otherwise, so a dragged window is followed closely. The found element is
/// kept while Slack is behind another app or minimized (the floating button just hides), so coming back is instant
/// instead of a fresh search of Slack's whole tree. Only when no button is known is the tree searched, at most every
/// couple of seconds (at once when Slack comes to the front).
final class ThreadWatcher {
    private let queue = DispatchQueue(label: "ThreadWatcher", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var last: ThreadPane?
    private var cached: ThreadReader.Anchor?
    private var lastSearch = Date.distantPast
    private var wasFront = false
    private var activeUntil = Date.distantPast
    private var fast = false
    private static let searchInterval: TimeInterval = 2
    private static let moving: TimeInterval = 0.03, idle: TimeInterval = 0.12

    // Written on the main queue, read on the polling queue.
    private let pausedLock = NSLock()
    private var pausedValue = false
    var paused: Bool {
        get { pausedLock.lock(); defer { pausedLock.unlock() }; return pausedValue }
        set { pausedLock.lock(); pausedValue = newValue; pausedLock.unlock() }
    }
    /// Called on the main queue; nil means no thread is open (or Slack is hidden or not in front).
    var onChange: ((ThreadPane?) -> Void)?

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.idle)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let current = (paused || !AXIsProcessTrusted()) ? nil : probe()
        if !Self.same(last, current) {
            last = current
            activeUntil = Date().addingTimeInterval(1) // something moved: keep polling fast for a moment
            DispatchQueue.main.async { [onChange] in onChange?(current) }
        }
        let wantFast = Date() < activeUntil
        if wantFast != fast {
            fast = wantFast
            let interval = wantFast ? Self.moving : Self.idle
            timer?.schedule(deadline: .now() + interval, repeating: interval)
        }
    }

    private func probe() -> ThreadPane? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == ThreadReader.slackBundleId else {
            wasFront = false // hide, but keep the found button for when Slack is back
            return nil
        }
        let pid = front.processIdentifier
        if !wasFront {
            wasFront = true
            lastSearch = .distantPast // Slack just came to the front: look at once if nothing is known
        }
        guard ThreadReader.isWindowShowing(pid: pid) else { return nil } // minimized: hide, keep the button

        if cached == nil {
            guard Date().timeIntervalSince(lastSearch) >= Self.searchInterval else { return nil }
            lastSearch = Date()
        }
        guard let found = ThreadReader.detectAnchor(pid: pid, cached: cached) else {
            cached = nil
            return nil
        }
        cached = found
        return ThreadPane(frame: found.frame, app: front)
    }

    private static func same(_ a: ThreadPane?, _ b: ThreadPane?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.frame == b.frame && a.app.processIdentifier == b.app.processIdentifier
    }
}

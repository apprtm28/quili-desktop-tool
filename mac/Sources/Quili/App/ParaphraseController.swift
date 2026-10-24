import AppKit

/// Ties the pieces together: tracks the focused field, shows the overlay button on it, and runs
/// read → paraphrase → replace when the button is clicked.
@MainActor
final class ParaphraseController {
    private let settings: Settings
    private let tracker = FocusTracker()
    private let overlay = OverlayWindow()
    private let bubble = BubbleWindow()
    private let threadWatcher = ThreadWatcher()
    private let threadButton = ThreadButtonWindow()
    private var threadPane: ThreadPane?
    /// Thread summaries, questions and work-context notes go through Hermes (macOS-only fork, docs/hermes).
    private let hermes: HermesController
    /// Range chips on Slack's main channel (Q4): the hovered message, the marked start, and a running collection.
    private let channelWatcher = ChannelWatcher()
    private let chip = ChipWindow()
    private var hovered: ChannelHover?
    private var rangeStart: ChannelHover?
    private var collecting = false
    private var current: TextTarget?
    private var request: Task<Void, Never>?
    private var previewing = false // late streamed updates must not re-show the bubble after the request ended
    private var writing = false // once the field is being written, cancelling would leave it half-replaced

    init(settings: Settings) {
        self.settings = settings
        hermes = HermesController(settings: settings)
        overlay.onAction = { [weak self] action in
            guard let self, self.request == nil, self.current != nil, !self.overlay.isBusy else { return }
            self.request = Task { await self.run(action) }
        }
        overlay.onSettings = { [weak self] in self?.onOpenSettings?() }
        overlay.onCancel = { [weak self] in
            guard let self, !self.writing else { return }
            DebugLog.write("cancel requested; dropping the connection")
            self.request?.cancel()
        }
        tracker.onChange = { [weak self] target in self?.targetChanged(target) }
        threadWatcher.onChange = { [weak self] pane in self?.threadPaneChanged(pane) }
        threadButton.onClick = { [weak self] in
            guard let self, let pane = self.threadPane else { return }
            self.summarizeThread(in: pane.app, below: self.threadButton.frame)
        }
        channelWatcher.onChange = { [weak self] hover in self?.channelHoverChanged(hover) }
        chip.onClick = { [weak self] in self?.chipClicked() }
        chip.onClose = { [weak self] in
            guard let self, !self.collecting else { return }
            self.rangeStart = nil
            DebugLog.write("range: start unmarked")
            self.channelHoverChanged(self.hovered)
        }
    }

    /// The gear in the pill was clicked.
    var onOpenSettings: (() -> Void)?

    func start() {
        tracker.start()
        threadWatcher.start()
        channelWatcher.start()
    }

    var paused: Bool {
        get { tracker.paused }
        set {
            tracker.paused = newValue
            threadWatcher.paused = newValue
            channelWatcher.paused = newValue
            if newValue { overlay.hide(); bubble.hide(); threadButton.hide(); hermes.hide(); chip.hide(); rangeStart = nil }
        }
    }

    /// A thread pane opened, moved or closed in Slack: keep the Summarize button on it.
    private func threadPaneChanged(_ pane: ThreadPane?) {
        let appeared = (pane != nil) != (threadPane != nil)
        threadPane = pane
        guard let pane else { if appeared { DebugLog.write("thread button: hidden") }; threadButton.hide(); return }
        if appeared { DebugLog.write("thread button: beside Slack's Summarize thread button, frame=\(pane.frame)") }
        threadButton.show(besideButton: pane.frame)
    }

    // MARK: - Ask Hermes about the selection (⌃⌥H)

    /// Sends the text selected in the frontmost app (an email in Gmail, a page in Chrome…) to Hermes `work`, in the
    /// conversation bubble near the pointer.
    func askHermesAboutSelection() {
        guard AXIsProcessTrusted() else {
            Notifier.show("Accessibility permission needed",
                          "Allow Quili in System Settings → Privacy & Security → Accessibility.")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current else { return }
        let mouse = NSEvent.mouseLocation
        let anchor = NSRect(x: mouse.x + 200, y: mouse.y - 4, width: 1, height: 8) // the bubble's right edge near the pointer
        Task {
            // Let go of ⌃⌥ first, so the copy isn't read as ⌃⌥⌘C.
            for _ in 0..<25 where !CGEventSource.flagsState(.combinedSessionState).intersection([.maskControl, .maskAlternate]).isEmpty {
                await Pause.milliseconds(20)
            }
            let text = await TextAccess.selectedText(in: app)
            guard text.count >= 3 else {
                Notifier.show("Nothing selected", "Select some text first, then press ⌃⌥H.")
                return
            }
            let window = AXUIElementCreateApplication(app.processIdentifier)
            let title = (AX.attr(window, kAXFocusedWindowAttribute).map { $0 as! AXUIElement })
                .flatMap { AX.string($0, kAXTitleAttribute) } ?? ""
            let source = [app.localizedName ?? "App", title.isEmpty ? nil : title].compactMap { $0 }.joined(separator: " – ")
            DebugLog.write("selection: \(text.count) chars from \(app.bundleIdentifier ?? "?")")
            self.hermes.askAboutSelection(text, source: String(source.prefix(120)), near: anchor)
        }
    }

    /// Reopens a stored Hermes conversation (menu bar → Recent Hermes conversations).
    func openHermesHistory(_ key: String, near anchor: NSRect) {
        hermes.openHistory(key: key, near: anchor)
    }

    // MARK: - Range chips

    private func channelHoverChanged(_ hover: ChannelHover?) {
        if collecting { return }
        hovered = hover
        // A start marked in another conversation no longer applies.
        if let start = rangeStart, let hover, hover.channel != start.channel {
            DebugLog.write("range: start cleared (conversation changed)")
            rangeStart = nil
        }
        guard let hover else { chip.hide(); channelWatcher.chipFrame = .null; return }
        let label: String, marked: Bool
        if let start = rangeStart {
            (label, marked) = start.key == hover.key ? ("Only this one", true) : ("End here", false)
        } else {
            (label, marked) = ("Start here", false)
        }
        channelWatcher.chipFrame = chip.show(label, marked: marked, onRow: hover.frame)
    }

    private func chipClicked() {
        guard let hover = hovered, !collecting else { return }
        guard let start = rangeStart else {
            rangeStart = hover
            DebugLog.write("range: start marked")
            channelHoverChanged(hover)
            return
        }
        if start.key == hover.key {
            // Just this message: nothing to scroll for.
            rangeStart = nil
            chip.hide()
            channelWatcher.chipFrame = .null
            DebugLog.write("range: single message")
            let m = hover.message
            hermes.pickRange(messages: [m.formatted], headers: [("\(m.author) · \(m.time)", m.text.isEmpty ? "(no text)" : m.text)],
                             channel: hover.channel, coverage: ReadCoverage(messages: 1), near: chip.frame)
            return
        }
        collect(from: start, to: hover)
    }

    /// Scrolls Slack between the two marked messages, reads them, and opens the pick bubble.
    private func collect(from start: ChannelHover, to end: ChannelHover) {
        collecting = true
        channelWatcher.chipFrame = chip.show("Collecting…", marked: true, onRow: end.frame)
        let anchor = chip.frame
        DebugLog.write("range: collecting")
        Task {
            let range = await Task.detached { RangeCollector.collect(pid: end.pid, startKey: start.key, endKey: end.key) }.value
            self.collecting = false
            self.rangeStart = nil
            self.chip.hide()
            self.channelWatcher.chipFrame = .null
            guard let range, !range.messages.isEmpty else {
                Notifier.show("Couldn't collect the messages", "Keep both messages in the same conversation and try again.")
                return
            }
            let headers = range.messages.map { m in ("\(m.author) · \(m.time)", m.text.isEmpty ? "(no text)" : m.text) }
            self.hermes.pickRange(messages: range.messages.map(\.formatted), headers: headers, channel: end.channel,
                                  coverage: range.coverage, near: anchor)
        }
    }

    private func targetChanged(_ target: TextTarget?) {
        // Keep the button where it is while a request is running; the result is validated afterwards.
        if overlay.isBusy { return }
        // Same field as before (just moved or resized): a button the user dragged stays where they put it.
        let sameField = target != nil && current != nil && CFEqual(current!.element, target!.element)
        current = target
        if let target { overlay.show(at: target.frame, sameField: sameField) } else { overlay.hide() }
    }

    /// Reads the Slack thread open in `app`'s window and shows its Hermes summary under `anchor` (the Summarize button,
    /// Cocoa screen coordinates). Never writes to Slack; the summary is also copied.
    func summarizeThread(in app: NSRunningApplication?, below anchor: NSRect) {
        guard AXIsProcessTrusted() else {
            Notifier.show("Accessibility permission needed",
                          "Allow Quili in System Settings → Privacy & Security → Accessibility.")
            return
        }
        guard let app, app.bundleIdentifier == ThreadReader.slackBundleId else {
            Notifier.show("Open a Slack thread first", "Switch to Slack, open the thread, then click the Summarize button.")
            return
        }
        DebugLog.write("summarize clicked (Slack pid \(app.processIdentifier))")
        hermes.summarizeThread(pid: app.processIdentifier, below: anchor)
    }

    private func run(_ action: TextAction) async {
        DebugLog.write("\(action) clicked (target=\(current == nil ? "none" : "set"), busy=\(overlay.isBusy))")
        // Declared first so every exit, including the guard below, frees the controller for the next click.
        defer { request = nil }
        guard let target = current, !overlay.isBusy else { return }
        overlay.setBusy(true)
        writing = false
        let targetApp = NSWorkspace.shared.frontmostApplication
        previewing = true
        defer {
            previewing = false
            bubble.hide()
            writing = false
            overlay.setBusy(false)
        }

        do {
            let field = await TextAccess.read(target.element)
            DebugLog.write("read \(field.text.count) chars from field")
            guard !field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Notifier.show("Nothing to \(action.verb.lowercased())", "The text field is empty.")
                return
            }

            // The text streams into a bubble beside the button while the model writes it; the field itself is
            // only touched once the final text is in.
            let result = try await ParaphraseClient.run(field.text, settings: settings, action: action) { [weak self] partial in
                guard let self, self.previewing else { return }
                self.bubble.show(partial, above: self.overlay.frame)
            }
            previewing = false
            bubble.hide()

            let (focused, front) = await FocusTracker.focusState(of: target.element)
            if !focused || !front {
                DebugLog.write("target lost focus (focused=\(focused), foreground=\(front)); bringing it back")
                if await FocusTracker.restoreFocus(target.element, app: targetApp) {
                    DebugLog.write("focus restored")
                } else {
                    DebugLog.write("could not restore focus; result left on the clipboard")
                    TextAccess.setPasteboard(result)
                    Notifier.show("Focus changed", "The \(action.verb.lowercased())d text was copied to the clipboard instead.")
                    return
                }
            }
            writing = true
            try await TextAccess.replace(field, in: target.element, with: result)
            DebugLog.write("field replaced")
        } catch is CancellationError {
            DebugLog.write("\(action) cancelled by the user")
        } catch let error as URLError where error.code == .cancelled {
            DebugLog.write("\(action) cancelled by the user")
        } catch {
            DebugLog.write("\(action) failed: \(error.localizedDescription)")
            Notifier.show("\(action.verb) failed", error.localizedDescription)
        }
    }
}

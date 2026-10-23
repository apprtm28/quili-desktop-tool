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
    private var summaryDismissed = false // the × was clicked while the summary was still being made
    private var current: TextTarget?
    private var request: Task<Void, Never>?
    private var previewing = false // late streamed updates must not re-show the bubble after the request ended
    private var writing = false // once the field is being written, cancelling would leave it half-replaced

    init(settings: Settings) {
        self.settings = settings
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
        bubble.onClose = { [weak self] in
            guard let self else { return }
            DebugLog.write("summary bubble closed (previewing=\(self.previewing))")
            // Clicked before the summary finished: stop the request too, and let the fade finish the job. Streamed
            // updates that are still on their way must not bring the bubble back.
            if self.previewing { self.summaryDismissed = true; self.request?.cancel() }
            self.bubble.fadeOut()
        }
        threadWatcher.onChange = { [weak self] pane in self?.threadPaneChanged(pane) }
        threadButton.onClick = { [weak self] in
            guard let self, let pane = self.threadPane else { return }
            self.summarizeThread(in: pane.app, below: self.threadButton.frame)
        }
    }

    /// The gear in the pill was clicked.
    var onOpenSettings: (() -> Void)?

    func start() {
        tracker.start()
        threadWatcher.start()
    }

    var paused: Bool {
        get { tracker.paused }
        set {
            tracker.paused = newValue
            threadWatcher.paused = newValue
            if newValue { overlay.hide(); bubble.hide(); threadButton.hide() }
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

    private func targetChanged(_ target: TextTarget?) {
        // Keep the button where it is while a request is running; the result is validated afterwards.
        if overlay.isBusy { return }
        // Same field as before (just moved or resized): a button the user dragged stays where they put it.
        let sameField = target != nil && current != nil && CFEqual(current!.element, target!.element)
        current = target
        if let target { overlay.show(at: target.frame, sameField: sameField) } else { overlay.hide() }
    }

    /// Reads the Slack thread open in `app`'s window and shows its summary under `anchor` (the Summarize button, Cocoa
    /// screen coordinates). Never writes to Slack; the summary is also copied.
    func summarizeThread(in app: NSRunningApplication?, below anchor: NSRect) {
        guard request == nil, !overlay.isBusy else { return }
        request = Task { await self.runSummary(in: app, below: anchor) }
    }

    private func runSummary(in app: NSRunningApplication?, below anchor: NSRect) async {
        defer { request = nil }
        summaryDismissed = false
        let action = TextAction.summarizeThread
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
        previewing = true
        defer { previewing = false }
        // Closable from the start, so a slow summary can be dismissed (which also cancels it).
        bubble.show("Reading the thread…", above: anchor, tall: true, closable: true)

        do {
            let pid = app.processIdentifier
            let thread = await Task.detached { ThreadReader.read(pid: pid) }.value
            try Task.checkCancellation()
            guard let thread, thread.text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else {
                bubble.hide()
                Notifier.show("No thread found", "Open the thread in Slack's side pane (click its replies link) and try again.")
                return
            }
            DebugLog.write("read \(thread.text.count) chars from the thread\(thread.truncated ? " (oldest messages dropped)" : "")")
            DebugLog.write("thread text to summarize:\n\(thread.text)")

            let result = try await ParaphraseClient.run(thread.text, settings: settings, action: action) { [weak self] partial in
                guard let self, self.previewing, !self.summaryDismissed else { return }
                self.bubble.show(partial, above: anchor, tall: true, closable: true)
            }
            guard !summaryDismissed else { return } // closed while the last of it was arriving
            TextAccess.setPasteboard(TextHygiene.slackMarkup(result))
            // The summary stays until it is closed with its ×.
            bubble.show(result, above: anchor, tall: true, closable: true)
            Notifier.show("Thread summarized", "The summary was copied to the clipboard.")
        } catch is CancellationError {
            if !summaryDismissed { bubble.hide() } // a dismissed bubble is already fading out
        } catch let error as URLError where error.code == .cancelled {
            if !summaryDismissed { bubble.hide() }
        } catch {
            bubble.hide()
            DebugLog.write("\(action) failed: \(error.localizedDescription)")
            Notifier.show("\(action.verb) failed", error.localizedDescription)
        }
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

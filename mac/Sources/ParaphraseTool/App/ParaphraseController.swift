import AppKit

/// Ties the pieces together: tracks the focused field, shows the overlay button on it, and runs
/// read → paraphrase → replace when the button is clicked.
@MainActor
final class ParaphraseController {
    private let settings: Settings
    private let tracker = FocusTracker()
    private let overlay = OverlayWindow()
    private var current: TextTarget?
    private var request: Task<Void, Never>?
    private var writing = false // once the field is being written, cancelling would leave it half-replaced

    init(settings: Settings) {
        self.settings = settings
        overlay.onAction = { [weak self] action in
            guard let self, self.request == nil else { return }
            self.request = Task { await self.run(action) }
        }
        overlay.onSettings = { [weak self] in self?.onOpenSettings?() }
        overlay.onCancel = { [weak self] in
            guard let self, !self.writing else { return }
            DebugLog.write("cancel requested; dropping the connection")
            self.request?.cancel()
        }
        tracker.onChange = { [weak self] target in self?.targetChanged(target) }
    }

    /// The gear in the pill was clicked.
    var onOpenSettings: (() -> Void)?

    func start() { tracker.start() }

    var paused: Bool {
        get { tracker.paused }
        set {
            tracker.paused = newValue
            if newValue { overlay.hide() }
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

    private func run(_ action: TextAction) async {
        guard let target = current, !overlay.isBusy else { return }
        overlay.setBusy(true)
        writing = false
        defer {
            request = nil
            writing = false
            overlay.setBusy(false)
        }

        do {
            let field = await TextAccess.read(target.element)
            DebugLog.write("read \(field.text.count) chars (selection=\(field.isSelection))")
            guard !field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Notifier.show("Nothing to \(action.verb.lowercased())", "The text field is empty.")
                return
            }

            let result = try await ParaphraseClient.run(field.text, settings: settings, action: action)

            guard FocusTracker.stillFocused(target.element) else {
                TextAccess.setPasteboard(result)
                Notifier.show("Focus changed", "The \(action.verb.lowercased())d text was copied to the clipboard instead.")
                return
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

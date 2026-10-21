import AppKit

/// Ties the pieces together: tracks the focused field, shows the overlay button on it, and runs
/// read → paraphrase → replace when the button is clicked.
@MainActor
final class ParaphraseController {
    private let settings: Settings
    private let tracker = FocusTracker()
    private let overlay = OverlayWindow()
    private var current: TextTarget?

    init(settings: Settings) {
        self.settings = settings
        overlay.onAction = { [weak self] action in Task { await self?.run(action) } }
        tracker.onChange = { [weak self] target in self?.targetChanged(target) }
    }

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
        current = target
        if let target { overlay.show(at: target.frame) } else { overlay.hide() }
    }

    private func run(_ action: TextAction) async {
        guard let target = current, !overlay.isBusy else { return }
        overlay.setBusy(true)
        defer { overlay.setBusy(false) }

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
            try await TextAccess.replace(field, in: target.element, with: result)
            DebugLog.write("field replaced")
        } catch {
            DebugLog.write("\(action) failed: \(error.localizedDescription)")
            Notifier.show("\(action.verb) failed", error.localizedDescription)
        }
    }
}

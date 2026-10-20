import AppKit
import ApplicationServices

struct FieldText {
    let text: String
    let isSelection: Bool
    let range: AXValue?   // original selection, used to restore it before pasting
}

/// Reads and replaces text in the focused field. Reading prefers the Accessibility API; replacing goes
/// through the pasteboard + Cmd+A/V, which works in web and Electron editors where setting AXValue does not
/// trigger the page's input handlers. Must run on the main actor.
@MainActor
enum TextAccess {
    private static let keyA: CGKeyCode = 0, keyC: CGKeyCode = 8, keyV: CGKeyCode = 9

    static func read(_ el: AXUIElement) async -> FieldText {
        let selectionAttr = AX.attr(el, kAXSelectedTextAttribute)
        if let sel = selectionAttr as? String, !isBlank(sel) {
            return FieldText(text: sel, isSelection: true, range: AX.attr(el, kAXSelectedTextRangeAttribute).map { $0 as! AXValue })
        }

        // No AX selection support: probe with Cmd+C.
        if selectionAttr == nil {
            let copied = await copySelection()
            if !isBlank(copied) { return FieldText(text: copied, isSelection: true, range: nil) }
        }

        if let whole = AX.string(el, kAXValueAttribute), !isBlank(whole) {
            return FieldText(text: whole, isSelection: false, range: nil)
        }

        pressCommand(keyA)
        return FieldText(text: await copySelection(), isSelection: false, range: nil)
    }

    /// Pastes over the original selection, or over the whole field when nothing was selected.
    static func replace(_ field: FieldText, in el: AXUIElement, with text: String) async throws {
        // The user may have moved the selection while the request ran; put it back or give up.
        if field.isSelection, !(await restoreSelection(field, in: el)) {
            setPasteboard(text)
            throw ParaphraseError(message: "The selection changed while paraphrasing. The result was copied to the clipboard.")
        }

        let backup = NSPasteboard.general.string(forType: .string)
        setPasteboard(text)
        if !field.isSelection { pressCommand(keyA) }
        pressCommand(keyV)
        try? await Task.sleep(nanoseconds: 300_000_000) // let the target read the pasteboard before restoring it
        if let backup { setPasteboard(backup) }
    }

    private static func restoreSelection(_ field: FieldText, in el: AXUIElement) async -> Bool {
        if let range = field.range,
           AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, range) == .success,
           let now = AX.string(el, kAXSelectedTextAttribute), normalize(now) == normalize(field.text) {
            return true
        }
        // No usable range: only proceed if the current selection is still the same text.
        return normalize(await copySelection()) == normalize(field.text)
    }

    /// Cmd+C and return what landed on the pasteboard (empty if nothing was selected).
    private static func copySelection() async -> String {
        let pb = NSPasteboard.general
        let backup = pb.string(forType: .string)
        pb.clearContents()
        let before = pb.changeCount
        pressCommand(keyC)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let text = pb.changeCount != before ? (pb.string(forType: .string) ?? "") : ""
        if let backup { setPasteboard(backup) }
        return text
    }

    static func setPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func pressCommand(_ key: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

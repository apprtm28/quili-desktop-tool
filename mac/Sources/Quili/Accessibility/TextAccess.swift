import AppKit
import ApplicationServices

struct FieldText {
    let text: String
    let isSelection: Bool
    let range: AXValue?   // original selection, used to restore it before pasting
}

/// Reads and replaces text in the focused field. Reading prefers the Accessibility API; replacing goes
/// through the pasteboard + Cmd+A/V, which works in web and Electron editors where setting AXValue does not
/// trigger the page's input handlers. Deliberately not main-actor: the Accessibility calls can block for seconds
/// on an unresponsive target app, and that must not freeze the overlay's spinner and Cancel button.
enum TextAccess {
    static func read(_ el: AXUIElement) async -> FieldText {
        let selectionAttr = AX.attr(el, kAXSelectedTextAttribute)
        if let sel = selectionAttr as? String, !isBlank(sel) {
            let range = AX.attr(el, kAXSelectedTextRangeAttribute).map { $0 as! AXValue }
            // Web editors report emoji images as U+FFFC; the pasteboard copy carries the real characters.
            if TextHygiene.isUnreliable(sel) {
                DebugLog.write("AX selection damaged (\(TextHygiene.describe(sel))); reading via pasteboard")
                let copied = await copySelection()
                if !isBlank(copied) { return FieldText(text: copied, isSelection: true, range: range) }
            }
            return FieldText(text: sel, isSelection: true, range: range)
        }

        // No AX selection support: probe with Cmd+C.
        if selectionAttr == nil {
            let copied = await copySelection()
            if !isBlank(copied) { return FieldText(text: copied, isSelection: true, range: nil) }
        }

        if let whole = AX.string(el, kAXValueAttribute), !isBlank(whole) {
            if !TextHygiene.isUnreliable(whole) { return FieldText(text: whole, isSelection: false, range: nil) }
            DebugLog.write("AX text damaged (\(TextHygiene.describe(whole))); reading via pasteboard")
            pressCommand("a")
            let copied = await copySelection()
            return FieldText(text: isBlank(copied) ? whole : copied, isSelection: false, range: nil)
        }

        pressCommand("a")
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
        DebugLog.write("pasting (selectionOnly=\(field.isSelection))")
        if !field.isSelection { pressCommand("a") }
        pressCommand("v")
        await Pause.milliseconds(400) // let the target app read the pasteboard before restoring it

        // Confirm the paste landed; if not, leave the result on the pasteboard so it isn't lost.
        if let after = AX.string(el, kAXValueAttribute), !after.isEmpty, !key(after).contains(key(text, max: 15)) {
            DebugLog.write("paste did not land (field text unchanged)")
            throw ParaphraseError(message:
                "The text could not be replaced in this field. The result was copied to the clipboard; paste it with Cmd+V.")
        }
        DebugLog.write("paste verified")
        if let backup { setPasteboard(backup) }
    }

    private static func restoreSelection(_ field: FieldText, in el: AXUIElement) async -> Bool {
        if let range = field.range {
            if AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, range) == .success {
                if let now = AX.string(el, kAXSelectedTextAttribute), !now.isEmpty, key(now, max: 30) == key(field.text, max: 30) {
                    DebugLog.write("selection restored via AX range")
                    return true
                }
                DebugLog.write("AX range select did not reproduce the selection; comparing via pasteboard")
            } else {
                DebugLog.write("range select failed")
            }
        }
        // No usable range: only proceed if the current selection is still the same text.
        let same = normalize(await copySelection()) == normalize(field.text)
        DebugLog.write("selection still the same via pasteboard: \(same)")
        return same
    }

    /// Letters/digits only, so emoji placeholders and whitespace differences don't matter when comparing.
    private static func key(_ s: String, max: Int = .max) -> String {
        String(s.filter { $0.isLetter || $0.isNumber }.prefix(max)).lowercased()
    }

    /// Cmd+C and return what landed on the pasteboard (empty if nothing was selected); the pasteboard is restored.
    static func copySelection() async -> String {
        let pb = NSPasteboard.general
        let backup = pb.string(forType: .string)
        pb.clearContents()
        let before = pb.changeCount
        pressCommand("c")
        await Pause.milliseconds(200)
        let text = pb.changeCount != before ? (pb.string(forType: .string) ?? "") : ""
        if let backup { setPasteboard(backup) }
        return text
    }

    static func setPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Presses Cmd+letter, resolving the key from the current keyboard layout.
    private static func pressCommand(_ letter: Character) {
        let key = KeyboardLayout.keyCode(for: letter)
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    /// The text selected in the frontmost app, for "Ask Hermes about selection": the Accessibility selection when the
    /// app reports one (and it isn't damaged around emoji), otherwise Cmd+C.
    static func selectedText(in app: NSRunningApplication) async -> String {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        if let focused = AX.focusedElement(ofApp: element), let sel = AX.string(focused, kAXSelectedTextAttribute),
           !isBlank(sel), !TextHygiene.isUnreliable(sel) {
            return normalize(sel)
        }
        return normalize(await copySelection())
    }

    private static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

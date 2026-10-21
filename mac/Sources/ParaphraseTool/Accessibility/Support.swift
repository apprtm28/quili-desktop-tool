import Carbon.HIToolbox
import Foundation

enum Pause {
    /// A fixed delay that survives cancellation of the calling task. The waits around key presses and clipboard
    /// reads give the target app time to react, so cancelling a request must not shorten them
    /// (the Windows app likewise only lets cancel interrupt the HTTP call).
    static func milliseconds(_ ms: UInt64) async {
        await Task.detached { try? await Task.sleep(nanoseconds: ms * 1_000_000) }.value
    }
}

/// Finds which physical key types a letter on the current keyboard layout, so Cmd+A / Cmd+C / Cmd+V are sent as the
/// right shortcut on layouts that aren't QWERTY (on AZERTY the "A" key has the code QWERTY uses for "Q").
enum KeyboardLayout {
    /// The key code that types `letter` unshifted. Uses the ASCII-capable layout, which is what Command shortcuts
    /// follow when the active layout (Cyrillic, Arabic, ...) has no Latin letters. Falls back to QWERTY positions.
    static func keyCode(for letter: Character) -> CGKeyCode {
        let qwerty: [Character: CGKeyCode] = ["a": 0, "c": 8, "v": 9]
        let fallback = qwerty[letter] ?? 0
        guard let wanted = letter.utf16.first,
              let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }

        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return fallback }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        for code in 0..<128 {
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            if status == noErr, length == 1, chars[0] == wanted { return CGKeyCode(code) }
        }
        return fallback
    }
}

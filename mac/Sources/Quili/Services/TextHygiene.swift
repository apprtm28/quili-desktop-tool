import Foundation

/// Guards against text the Accessibility API hands back damaged around emoji: U+FFFC (an embedded image such
/// as a web editor's emoji) or U+FFFD (a failed decode). Swift strings cannot hold unpaired surrogates.
enum TextHygiene {
    private static let objectReplacement: Unicode.Scalar = "\u{FFFC}"
    private static let replacement: Unicode.Scalar = "\u{FFFD}"

    /// True when the text visibly lost something and the pasteboard copy should be used instead.
    static func isUnreliable(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 == objectReplacement || $0 == replacement }
    }

    /// A summary's `**bold**` as Slack writes bold (`*bold*`), for the copy that goes to the clipboard.
    static func slackMarkup(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "*")
    }

    /// Counts only (never the text itself) for the debug log.
    static func describe(_ text: String) -> String {
        var symbols = 0, objects = 0, replacements = 0
        for scalar in text.unicodeScalars {
            if scalar == objectReplacement { objects += 1 }
            else if scalar == replacement { replacements += 1 }
            else if scalar.value >= 0x1F000 || (0x2600...0x27BF).contains(scalar.value) { symbols += 1 }
        }
        return "chars=\(text.count) emoji~\(symbols) objectReplacement=\(objects) replacement=\(replacements)"
    }
}

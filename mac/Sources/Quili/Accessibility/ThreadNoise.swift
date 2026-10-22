import Foundation

/// What is dropped from a captured Slack thread: interface controls and chrome that are not conversation text.
/// Two lists, applied in two places. Buttons are filtered while reading (Slack makes author names buttons too, so a
/// button is kept unless its label is listed here), which also stops merged lines such as "Open in channel Add to-do"
/// from forming. Lines are filtered afterwards, for chrome that arrives as plain text. Both are deliberately narrow: a
/// real message must never be dropped.
enum ThreadNoise {
    // MARK: Buttons

    /// Labels that are noise only as the whole label (a lone word that could be part of a real name).
    private static let exactButtons: Set<String> = ["reply", "close"]

    /// Fragments that mark a button as interface wherever they appear in its label (all lowercase).
    private static let buttonFragments = [
        "summariz", "more actions", "add reaction", "reaction", "download", "forward", "save for later", "copy link",
        "also send to", "add to-do", "open in channel", "emoji", "mention someone", "record video clip",
        "record audio clip", "run shortcut", "send now",
    ]

    static func isInterfaceButton(_ label: String) -> Bool {
        let t = label.lowercased()
        return exactButtons.contains(t) || buttonFragments.contains { t.contains($0) }
    }

    // MARK: Lines

    /// Whole lines that are noise (all lowercase).
    private static let exactLines: Set<String> = [
        "thread", "reply…", "reply...", "add to-do", "send now",
        "emoji mention someone record video clip record audio clip run shortcut",
    ]

    /// Lines that are noise by shape: "4 replies New", "Also send to #channel", "Download file.png".
    private static let linePatterns = [
        #"^\d+ repl(y|ies)\b.*$"#,
        #"^also send to .+$"#,
        #"^download .+\.[a-z0-9]{1,5}$"#,
    ]

    /// The pane's title line, "Thread dbagroup" (or "Utas dbagroup"): the label and the channel name, not a message.
    static func isPaneTitle(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .range(of: #"^(thread|utas) \S{1,60}$"#, options: .regularExpression) != nil
    }

    static func isInterfaceLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return exactLines.contains(t) || linePatterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }
}

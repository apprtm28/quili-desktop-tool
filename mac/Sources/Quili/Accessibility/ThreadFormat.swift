import Foundation

/// Turns the text runs of one container of a captured Slack thread into a line, marking message headers so the
/// summarizer can tell who said what. A header is the author's name followed by its time ("Rahman Just now",
/// "Deka Dwi 20 minutes ago"); it is written `Author [time]`, and the message text follows on the lines below.
/// Slack's accessibility tree has no font weight to measure, so the header is recognised by its shape instead: a few
/// short runs, then a run that is a time, with the time not first (a lone "15:21" is a hover time, not a header), and
/// the name coming from a button (Slack makes author names buttons) or at least looking like a name.
enum ThreadFormat {
    /// The author part may be a name plus a status or badge, but never a long run of text.
    private static let maxNameRuns = 3, maxNameLength = 100

    /// Times as Slack shows them (lowercased): "just now", "22 minutes ago", "2:53 pm", "14:08", "yesterday at 14:08".
    private static let timePattern = #"^(just now|(yesterday|today)( at .+)?|\d+ (second|minute|hour|day|week|month|year)s? ago|\d{1,2}:\d{2}(\s?[ap]m)?|(mon|tue|wed|thu|fri|sat|sun)[a-z]*( at .+)?|[a-z]{3,9} \d{1,2}(st|nd|rd|th)?(,? \d{4})?( at .+)?)$"#

    static func isTime(_ run: String) -> Bool {
        run.lowercased().range(of: timePattern, options: .regularExpression) != nil
    }

    /// Capitalised words, so a message fragment such as "see you at" is not mistaken for an author.
    private static func looksLikeName(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        return words.count <= 6 && words.allSatisfy { $0.first.map { !$0.isLetter || $0.isUppercase } ?? false }
    }

    /// A line that starts a message: `Author [time]`, optionally followed by the first words of the message.
    static func isHeader(_ line: String) -> Bool {
        guard let open = line.range(of: " ["), open.lowerBound != line.startIndex,
              let close = line.range(of: "]", range: open.upperBound..<line.endIndex) else { return false }
        return line.distance(from: line.startIndex, to: open.lowerBound) <= maxNameLength
            && isTime(String(line[open.upperBound..<close.lowerBound]))
    }

    /// The lines as one string per message, each wrapped in `{{` and `}}`: a message runs from its header line to the
    /// next header. Braces inside a message are escaped (`\{`, `\}`) so they cannot be mistaken for the wrapper. Lines
    /// before the first header (no known author) form a message of their own.
    static func messages(from lines: [String]) -> [String] {
        var groups: [[String]] = []
        for line in lines {
            if groups.isEmpty || isHeader(line) { groups.append([]) }
            groups[groups.count - 1].append(line.replacingOccurrences(of: "{", with: "\\{")
                .replacingOccurrences(of: "}", with: "\\}"))
        }
        return groups.map { "{{" + $0.joined(separator: "\n") + "}}" }
    }

    /// One line for `runs` (already trimmed, non-empty), as a header when it has the shape of one.
    /// `firstIsButton` says the first run came from a button, which is how Slack renders an author's name.
    static func line(from allRuns: [String], firstIsButton: Bool) -> String {
        // "Also sent to the channel" is a label above the author's name, not part of it.
        let runs = allRuns.filter { $0.lowercased() != "also sent to the channel" }
        guard !runs.isEmpty else { return allRuns.joined(separator: " ") }
        guard let t = runs.firstIndex(where: isTime), (1...maxNameRuns).contains(t), !runs[0].hasPrefix("@") else {
            return runs.joined(separator: " ")
        }
        let name = runs[..<t].joined(separator: " ")
        guard name.count <= maxNameLength, firstIsButton || looksLikeName(name) else { return runs.joined(separator: " ") }
        let rest = runs[(t + 1)...].joined(separator: " ")
        return "\(name) [\(runs[t])]" + (rest.isEmpty ? "" : " \(rest)")
    }
}

import Foundation

/// What the server can be asked to do with text: the overlay's buttons act on the focused field, and the menu-bar
/// item summarizes a chat thread read from another app's window.
enum TextAction {
    /// Rewrite in the same language, following the Paraphrase instruction from Settings.
    case paraphrase
    /// Translate into natural, paraphrased English whatever the original language.
    case translateToEnglish
    /// Summarize the Slack thread that is open in the Slack window (never written back to a field).
    case summarizeThread

    var verb: String {
        switch self {
        case .paraphrase: return "Paraphrase"
        case .translateToEnglish: return "Translate"
        case .summarizeThread: return "Summarize"
        }
    }

    var path: String {
        switch self {
        case .paraphrase: return "/api/paraphrase"
        case .translateToEnglish: return "/api/translate"
        case .summarizeThread: return "/api/summarize-thread"
        }
    }
}

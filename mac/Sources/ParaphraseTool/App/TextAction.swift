import Foundation

/// What the overlay's buttons can ask the server to do with the field text.
enum TextAction {
    /// Rewrite in the same language, following the Paraphrase instruction from Settings.
    case paraphrase
    /// Translate into natural, paraphrased English whatever the original language.
    case translateToEnglish

    var verb: String { self == .translateToEnglish ? "Translate" : "Paraphrase" }
    var path: String { self == .translateToEnglish ? "/api/translate" : "/api/paraphrase" }
}

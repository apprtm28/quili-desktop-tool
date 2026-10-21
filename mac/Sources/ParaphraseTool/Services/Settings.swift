import Foundation
import Security
import ServiceManagement

/// Server URL and style live in UserDefaults; the API key lives in the Keychain.
final class Settings {
    static let defaultStyle =
        "Polish the provided text to improve grammar, verb tenses, clarity, and natural flow while preserving the original meaning, tone, and intent.\n\nKeep the wording and sentence structure as close to the original as possible, making only necessary adjustments. Use natural, conversational English without making it overly formal or complicated.\n\nReturn only the revised text, without explanations or additional commentary."
    // Earlier defaults: anyone still on one of these never customised it and moves to the current default.
    private static let legacyDefaultStyles = [
        "Keep the meaning, improve clarity and flow, and keep a natural tone.",
        "Paraphrase it with clearly different wording while keeping the meaning and a natural tone.",
    ]
    static let maxStyleLength = 1000
    private let defaults = UserDefaults.standard
    private let service = "ParaphraseTool", account = "apiKey"

    var serverUrl: String {
        get { defaults.string(forKey: "serverUrl") ?? "" }
        set { defaults.set(newValue, forKey: "serverUrl") }
    }

    var style: String {
        get {
            // Move users who never changed the default to the current one.
            let stored = (defaults.string(forKey: "style") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return stored.isEmpty || Settings.legacyDefaultStyles.contains(stored) ? Settings.defaultStyle : stored
        }
        set { defaults.set(newValue.isEmpty ? Settings.defaultStyle : newValue, forKey: "style") }
    }

    /// The instruction sent to the server as the paraphrase command (never empty, length-capped).
    var effectiveStyle: String { String(style.prefix(Settings.maxStyleLength)) }

    var runAtStartup: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { DebugLog.write("login item change failed: \(error)") }
        }
    }

    var apiKey: String {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecReturnData as String: true,
            ]
            var out: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(base as CFDictionary)
            guard !newValue.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

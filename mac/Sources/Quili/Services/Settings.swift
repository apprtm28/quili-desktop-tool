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
    private let service = "Quili", account = "apiKey"
    // Quili was called "Paraphrase Tool" before; its preferences and Keychain item live under these names.
    private static let legacyDefaultsDomain = "com.ferdibot.paraphrasetool", legacyService = "ParaphraseTool"

    init() { migrateFromParaphraseTool() }

    /// First launch after the rename: carry the old app's server URL, instruction and API key over, once.
    /// Reading the old Keychain item makes macOS ask once for permission (it belongs to the old app): choose Always Allow.
    private func migrateFromParaphraseTool() {
        let flag = "migratedFromParaphraseTool"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)

        if defaults.object(forKey: "serverUrl") == nil, defaults.object(forKey: "style") == nil,
           let old = defaults.persistentDomain(forName: Self.legacyDefaultsDomain) {
            for key in ["serverUrl", "style"] { if let value = old[key] { defaults.set(value, forKey: key) } }
            DebugLog.write("migrated settings from the old Paraphrase Tool app")
        }
        if apiKey.isEmpty, let legacyKey = readKey(service: Self.legacyService), !legacyKey.isEmpty {
            apiKey = legacyKey
            DebugLog.write("migrated the API key from the old Paraphrase Tool app")
        }
    }

    private func readKey(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

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

    /// Whether `DebugLog` writes anything (the "Write debug log" setting); on by default.
    var loggingEnabled: Bool {
        get { DebugLog.enabled }
        set { defaults.set(newValue, forKey: "loggingEnabled") }
    }

    /// Offline demo: every request goes to the built-in `MockServer` instead of the real server.
    var mockMode: Bool {
        get { defaults.bool(forKey: "mockMode") }
        set { defaults.set(newValue, forKey: "mockMode") }
    }

    var runAtStartup: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            let service = SMAppService.mainApp
            do {
                // register() throws when already registered, so only act on a real change.
                if newValue { if service.status != .enabled { try service.register() } }
                else if service.status == .enabled { try service.unregister() }
            } catch {
                DebugLog.write("login item change failed: \(error)")
                Notifier.show("Start at login failed", error.localizedDescription)
            }
        }
    }

    var apiKey: String {
        get { readKey(service: service) ?? "" }
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

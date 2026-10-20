import Foundation
import Security
import ServiceManagement

/// Server URL and style live in UserDefaults; the API key lives in the Keychain.
final class Settings {
    static let defaultStyle = "Keep the meaning, improve clarity and flow, and keep a natural tone."
    private let defaults = UserDefaults.standard
    private let service = "ParaphraseTool", account = "apiKey"

    var serverUrl: String {
        get { defaults.string(forKey: "serverUrl") ?? "" }
        set { defaults.set(newValue, forKey: "serverUrl") }
    }

    var style: String {
        get { defaults.string(forKey: "style") ?? Settings.defaultStyle }
        set { defaults.set(newValue.isEmpty ? Settings.defaultStyle : newValue, forKey: "style") }
    }

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

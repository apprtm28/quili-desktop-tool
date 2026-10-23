import CryptoKit
import Foundation
import Security

/// One Slack source (a thread, or a range collected from a channel) and its Hermes session (Q7).
struct HermesSource: Codable {
    enum Kind: String, Codable { case thread, range, selection }
    struct Entry: Codable {
        enum Role: String, Codable { case summary, question, answer, note }
        var role: Role
        var text: String
        var date: Date
    }

    var key: String
    var kind: Kind
    var channel: String
    var title: String
    var sessionId: String?
    /// The messages Hermes has seen (normalized), so a refresh sends only new ones.
    var sentMessages: [String]
    var transcript: [Entry]
    var updated: Date
}

/// The sources discussed with Hermes, kept in an AES-GCM sealed file whose key lives in the Keychain, and forgotten
/// after 30 days without use (as slack-to-hermes D15). Main-actor: the controller is its only user.
@MainActor
final class HermesSessions {
    static let shared = HermesSessions()
    private static let retention: TimeInterval = 30 * 24 * 3600
    private let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Quili/hermes-sessions.sealed")
    private var sources: [String: HermesSource]?
    private var cachedKey: SymmetricKey?

    func source(_ key: String) -> HermesSource? { load()[key] }

    func save(_ source: HermesSource) {
        var all = load()
        var updated = source
        updated.updated = Date()
        all[source.key] = updated
        sources = all
        persist(all)
    }

    func forget(_ key: String) {
        var all = load()
        all[key] = nil
        sources = all
        persist(all)
    }

    /// A stable key for a source: its kind, channel and first message, with relative times ("5 minutes ago") removed
    /// because they change between reads.
    static func key(kind: HermesSource.Kind, channel: String, firstMessage: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a
        for byte in "\(kind.rawValue)\u{1F}\(channel)\u{1F}\(normalized(firstMessage))".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return "\(kind.rawValue):" + String(hash, radix: 16)
    }

    /// A message as compared across reads: without its `[time]` part and surrounding whitespace.
    static func normalized(_ message: String) -> String {
        message.replacingOccurrences(of: #" \[[^\]\n]*\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Storage

    private func load() -> [String: HermesSource] {
        if let sources { return sources }
        var loaded: [String: HermesSource] = [:]
        if let sealed = try? Data(contentsOf: url), let key = try? key(),
           let box = try? AES.GCM.SealedBox(combined: sealed), let plain = try? AES.GCM.open(box, using: key) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            loaded = (try? decoder.decode([String: HermesSource].self, from: plain)) ?? [:]
        }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let fresh = loaded.filter { $0.value.updated > cutoff }
        sources = fresh
        if fresh.count != loaded.count {
            DebugLog.write("hermes sessions: forgot \(loaded.count - fresh.count) unused for 30 days")
            persist(fresh)
        }
        return fresh
    }

    private func persist(_ all: [String: HermesSource]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let sealed = try AES.GCM.seal(try encoder.encode(all), using: try key())
            guard let combined = sealed.combined else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try combined.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            DebugLog.write("hermes sessions: could not save (\(error.localizedDescription))")
        }
    }

    /// The store key, read from the Keychain at most once per launch (each read can prompt on an ad-hoc signed build).
    private func key() throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Quili",
            kSecAttrAccount as String: "hermesStoreKey",
        ]
        var query = base
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            cachedKey = SymmetricKey(data: data)
            return cachedKey!
        }
        guard status == errSecItemNotFound else { throw HermesError(message: "Keychain error \(status)", unreachable: false) }
        let key = SymmetricKey(size: .bits256)
        var add = base
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw HermesError(message: "Keychain error \(added)", unreachable: false) }
        cachedKey = key
        return key
    }
}

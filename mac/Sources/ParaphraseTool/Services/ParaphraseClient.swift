import Foundation

struct ParaphraseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ParaphraseClient {
    /// Accepts either the base URL or the full endpoint URL and returns the base URL.
    static func normalize(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        let endpoint = "/api/paraphrase"
        if u.lowercased().hasSuffix(endpoint) {
            u = String(u.dropLast(endpoint.count))
            while u.hasSuffix("/") { u.removeLast() }
        }
        return u
    }

    static func paraphrase(_ text: String, settings: Settings) async throws -> String {
        let apiKey = settings.apiKey
        let server = normalize(settings.serverUrl)
        guard !apiKey.isEmpty, let url = URL(string: server + "/api/paraphrase"), !server.isEmpty else {
            throw ParaphraseError(message: "Server URL or API key not set. Open Settings from the menu bar icon.")
        }

        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "style": settings.effectiveStyle])

        DebugLog.write("paraphrase request: POST \(url) (\(TextHygiene.describe(text)))")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        DebugLog.write("paraphrase response: HTTP \(status)")

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            var msg = String(data: data, encoding: .utf8) ?? ""
            if let detail = json?["detail"] { msg = (detail as? String) ?? "\(detail)" }
            throw ParaphraseError(message: "Paraphrase server error \(status): \(msg)")
        }
        guard let out = (json?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
            throw ParaphraseError(message: "Paraphrase server returned an empty response.")
        }
        DebugLog.write("paraphrase result: \(TextHygiene.describe(out))")
        return out
    }
}

import Foundation

struct ParaphraseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ParaphraseClient {
    // A dead connection fails fast and is retried once, so a server restart costs seconds, not a long hang.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Accepts either the base URL or the full endpoint URL and returns the base URL.
    static func normalize(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        for endpoint in ["/api/paraphrase", "/api/translate"] where u.lowercased().hasSuffix(endpoint) {
            u = String(u.dropLast(endpoint.count))
            while u.hasSuffix("/") { u.removeLast() }
        }
        return u
    }

    static func paraphrase(_ text: String, settings: Settings) async throws -> String {
        try await run(text, settings: settings, action: .paraphrase)
    }

    static func run(_ text: String, settings: Settings, action: TextAction) async throws -> String {
        let apiKey = settings.apiKey
        let server = normalize(settings.serverUrl)
        guard !apiKey.isEmpty, let url = URL(string: server + action.path), !server.isEmpty else {
            throw ParaphraseError(message: "Server URL or API key not set. Open Settings from the menu bar icon.")
        }

        var req = URLRequest(url: url, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        // Paraphrase carries the user's instruction; translate always targets English.
        let body: [String: String] = action == .translateToEnglish
            ? ["text": text, "target_language": "English"]
            : ["text": text, "style": settings.effectiveStyle]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        DebugLog.write("\(action) request: POST \(url) (\(TextHygiene.describe(text)))")
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await send(req, action: action)
        } catch let error as URLError where error.code == .timedOut {
            throw ParaphraseError(message: "The server took too long to respond.")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        DebugLog.write("\(action) response: HTTP \(status)")

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            var msg = String(data: data, encoding: .utf8) ?? ""
            if let detail = json?["detail"] {
                if let text = detail as? String { msg = text }
                else if let raw = try? JSONSerialization.data(withJSONObject: detail, options: [.fragmentsAllowed]),
                        let text = String(data: raw, encoding: .utf8) { msg = text }
            }
            throw ParaphraseError(message: "\(action.verb) server error \(status): \(msg)")
        }
        guard let out = (json?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
            throw ParaphraseError(message: "Paraphrase server returned an empty response.")
        }
        DebugLog.write("\(action) result: \(TextHygiene.describe(out))")
        return out
    }

    /// One try, plus one more after a connection-level failure (no HTTP response at all).
    private static func send(_ req: URLRequest, action: TextAction) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch let error as URLError where [.networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                                              .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed].contains(error.code) {
            DebugLog.write("\(action) connection failed (\(error.localizedDescription)); retrying once")
            return try await session.data(for: req)
        }
    }
}

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
        config.timeoutIntervalForResource = 75 // whole streamed response; the server stops at 60s
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Accepts either the base URL or the full endpoint URL and returns the base URL.
    static func normalize(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        for endpoint in ["/api/paraphrase", "/api/translate", "/api/summarize-thread"] where u.lowercased().hasSuffix(endpoint) {
            u = String(u.dropLast(endpoint.count))
            while u.hasSuffix("/") { u.removeLast() }
        }
        return u
    }

    static func paraphrase(_ text: String, settings: Settings) async throws -> String {
        try await run(text, settings: settings, action: .paraphrase)
    }

    /// Runs the action on the server. `onText` (optional) receives the rewritten text so far while the model is
    /// still writing it (each call replaces the previous one); the return value is the final, authoritative text.
    static func run(_ text: String, settings: Settings, action: TextAction,
                    onText: (@MainActor (String) -> Void)? = nil) async throws -> String {
        let apiKey = settings.apiKey
        let server = normalize(settings.serverUrl)
        guard !apiKey.isEmpty, let url = URL(string: server + action.path), !server.isEmpty else {
            throw ParaphraseError(message: "Server URL or API key not set. Open Settings from the menu bar icon.")
        }

        var req = URLRequest(url: url, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        // Paraphrase carries the user's instruction; translate always targets English; a summary has no instruction.
        let body: [String: Any]
        switch action {
        case .translateToEnglish: body = ["text": text, "target_language": "English", "stream": true]
        case .summarizeThread: body = ["text": text, "stream": true]
        case .paraphrase: body = ["text": text, "style": settings.effectiveStyle, "stream": true]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        DebugLog.write("\(action) request: POST \(url) (\(TextHygiene.describe(text)))")
        do {
            let (bytes, resp) = try await send(req, action: action)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DebugLog.write("\(action) response: HTTP \(status)")
            if (200..<300).contains(status), resp.mimeType == "text/event-stream" {
                return try await readStream(bytes, action: action, onText: onText)
            }
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            return try parseJSON(data, status: status, action: action)
        } catch let error as URLError where error.code == .timedOut {
            throw ParaphraseError(message: "The server took too long to respond.")
        }
    }

    /// Reads server-sent events: `delta` (text so far), then `done` (final result) or `error`.
    private static func readStream(_ bytes: URLSession.AsyncBytes, action: TextAction,
                                   onText: (@MainActor (String) -> Void)?) async throws -> String {
        var event = ""
        // `lines` skips blank lines, so an event is handled when its (single-line) data arrives.
        for try await line in bytes.lines {
            if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces); continue }
            guard line.hasPrefix("data:"),
                  let payload = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
            else { continue }
            switch event {
            case "delta":
                let partial = (payload["text"] as? String ?? "")
                if !partial.isEmpty, let onText { await onText(partial) }
            case "done":
                let out = (payload["text"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !out.isEmpty else { throw ParaphraseError(message: "Paraphrase server returned an empty response.") }
                DebugLog.write("\(action) result: \(TextHygiene.describe(out))")
                return out
            case "error":
                throw ParaphraseError(message: "\(action.verb) server error: \(payload["detail"] ?? "unknown")")
            default:
                break
            }
        }
        throw ParaphraseError(message: "The connection closed before the result arrived.")
    }

    private static func parseJSON(_ data: Data, status: Int, action: TextAction) throws -> String {
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
    private static func send(_ req: URLRequest, action: TextAction) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await session.bytes(for: req)
        } catch let error as URLError where [.networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                                              .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed].contains(error.code) {
            DebugLog.write("\(action) connection failed (\(error.localizedDescription)); retrying once")
            return try await session.bytes(for: req)
        }
    }
}

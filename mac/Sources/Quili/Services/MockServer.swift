import Foundation
import Network

/// A built-in stand-in for the Senwich server, for when the real one is down: answers every Quili endpoint
/// (`/api/paraphrase`, `/api/translate`, `/api/summarize-thread`) with fixed, pre-written text whatever it is sent,
/// on a loopback port picked by the system. It speaks the real server's wire format: with `"stream": true` it
/// sends `delta` events (the text so far, each replacing the previous) and one `done`, otherwise plain JSON. Any
/// other path answers 404. Started and stopped by the "Mock server (offline)" setting.
final class MockServer: @unchecked Sendable {
    static let shared = MockServer()

    static let summary = """
    The team handled a failed deploy of the order service and agreed on a rollback plan.

    Key discussion:
    - [Today at 14:10] Rina: the order-service release caused checkout 5xx errors; she rolled it back at 14:25.
    - [Today at 14:40] Dani: root cause was a config change that cut the database connection pool **from 50 to 5**.

    Outcome:
    Decisions:
    - Ship the one-line config revert behind a **10% canary** first.
    Action items:
    - **Dani**: ship the revert to the 10% canary and report back **before full rollout**.
    - Rina: add an alert for connection pool saturation.
    Open questions:
    - Should the pool size be added to the pre-deploy checklist?

    Key information:
    - db.pool.size: 50 -> 5
    - order-service 2.14.0 (rolled back)
    """

    /// The canned answer for each endpoint.
    private static let replies: [String: String] = [
        "/api/paraphrase": "This is a pre-generated paraphrase returned by Quili's offline mock server.",
        "/api/translate": "This is a pre-generated English translation returned by Quili's offline mock server.",
        "/api/summarize-thread": summary,
    ]
    private let chunk = 12
    private let chunkDelay: UInt64 = 50_000_000
    private let queue = DispatchQueue(label: "MockServer")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16?

    /// `http://127.0.0.1:<port>` while the server is running.
    var baseURL: String? {
        lock.lock(); defer { lock.unlock() }
        return port.map { "http://127.0.0.1:\($0)" }
    }

    /// Starts listening (a no-op when already running) and returns the base URL.
    func start() async throws -> String {
        if let url = baseURL { return url }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue, once.first() else { return }
                    self?.lock.lock(); self?.listener = listener; self?.port = port; self?.lock.unlock()
                    DebugLog.write("mock server listening on 127.0.0.1:\(port)")
                    continuation.resume(returning: "http://127.0.0.1:\(port)")
                case .failed(let error):
                    if once.first() { continuation.resume(throwing: error) }
                    self?.stop()
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        lock.lock()
        let running = listener
        listener = nil
        port = nil
        lock.unlock()
        guard let running else { return }
        running.cancel()
        DebugLog.write("mock server stopped")
    }

    /// True the first time it is asked, so the start continuation is resumed exactly once.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func first() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }

    // MARK: - Connections

    private struct Request {
        let path: String
        let stream: Bool
        let textLength: Int
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffered: Data())
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                Task { await self.respond(connection, to: request) }
            } else if isComplete || error != nil || buffer.count > 2_000_000 {
                connection.cancel()
            } else {
                self.receive(connection, buffered: buffer)
            }
        }
    }

    /// The request once its headers and whole body have arrived, else nil.
    private static func parse(_ data: Data) -> Request? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var length = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let body = data[split.upperBound...]
        guard body.count >= length else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: body.prefix(length))) as? [String: Any]
        return Request(path: String(parts[1]), stream: json?["stream"] as? Bool ?? false,
                       textLength: (json?["text"] as? String)?.count ?? 0)
    }

    private func respond(_ connection: NWConnection, to request: Request) async {
        defer { connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() }) }
        guard let reply = Self.replies[request.path] else {
            let known = Self.replies.keys.sorted().joined(separator: ", ")
            _ = await send(connection, Self.http(404, json: ["detail": "mock server only implements \(known)"]))
            return
        }
        DebugLog.write("mock server: \(request.path) with \(request.textLength) chars; replying with the canned text")
        let final: [String: Any] = ["text": reply, "language": "English", "model": "mock"]
        guard request.stream else {
            _ = await send(connection, Self.http(200, json: final))
            return
        }

        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        guard await send(connection, Data(head.utf8)) else { return }
        let text = Array(reply)
        var end = chunk
        while end < text.count {
            guard await send(connection, Self.event("delta", ["text": String(text[..<end])])) else { return }
            try? await Task.sleep(nanoseconds: chunkDelay)
            end += chunk
        }
        _ = await send(connection, Self.event("done", final))
    }

    private func send(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { continuation.resume(returning: $0 == nil) })
        }
    }

    // ASCII-escaped like the real server, so emoji can't be mis-decoded by a client.
    private static func asciiJSON(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        var out = ""
        for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
            if scalar.isASCII { out.unicodeScalars.append(scalar); continue }
            for unit in String(scalar).utf16 { out += String(format: "\\u%04x", unit) }
        }
        return out
    }

    private static func event(_ name: String, _ object: [String: Any]) -> Data {
        Data("event: \(name)\ndata: \(asciiJSON(object))\n\n".utf8)
    }

    private static func http(_ status: Int, json object: [String: Any]) -> Data {
        let body = Data(asciiJSON(object).utf8)
        let reason = status == 200 ? "OK" : "Not Found"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

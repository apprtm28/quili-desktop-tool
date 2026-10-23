import Foundation

/// Runs an action through `opencode run` on this Mac (Q13): the fast path for paraphrase and translate, and the
/// one-off direct summary when Hermes can't be reached (Q12).
///
/// opencode's free models refuse a replaced system prompt, so the instructions go at the start of the message. Every
/// tool is denied, which also keeps the tool definitions out of the request (≈400 input tokens instead of ≈15k).
enum OpencodeClient {
    private static let timeout: TimeInterval = 60
    private static let executable: String? = ProcessLines.locate("opencode", extra: [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode/bin/opencode").path,
    ])
    /// An empty folder, so no project instructions (AGENTS.md) are picked up.
    private static let workdir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quili-opencode", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func message(for action: TextAction, text: String, style: String) -> String {
        switch action {
        case .paraphrase:
            return "\(Prompts.paraphrase)\n\n<instruction>\n\(style)\n</instruction>\n\n<text>\n\(text)\n</text>"
        case .translateToEnglish:
            return "\(Prompts.translate(to: "English"))\n\n<text>\n\(text)\n</text>"
        case .summarizeThread:
            return "\(Prompts.summarizeDirect)\n\n<thread>\n\(text)\n</thread>"
        }
    }

    /// The final text; `onText` receives the text so far while it is written (each call replaces the previous one).
    /// `instructions` replaces the action's own prompt (the direct summary of a selection).
    static func run(_ text: String, action: TextAction, settings: Settings, instructions: String? = nil,
                    onText: (@MainActor (String) -> Void)? = nil) async throws -> String {
        guard let executable else {
            throw ParaphraseError(message: "opencode was not found. Install it, or switch to the server in Settings.")
        }
        var arguments = ["run", "--format", "json"]
        let model = settings.opencodeModel
        if !model.isEmpty { arguments += ["--model", model] }
        arguments.append(instructions.map { "\($0)\n\n<text>\n\(text)\n</text>" }
            ?? message(for: action, text: text, style: settings.effectiveStyle))
        var environment = ProcessInfo.processInfo.environment
        environment["OPENCODE_CONFIG_CONTENT"] = #"{"permission":{"*":"deny"}}"#

        DebugLog.write("\(action) request: opencode run --model \(model) (\(TextHygiene.describe(text)))")
        let collected = Collected()
        let exit = try await ProcessLines.run(executable, arguments, environment: environment, directory: workdir,
                                              timeout: timeout) { line in
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            switch event["type"] as? String {
            case "text":
                // Text arrives as whole parts; a part can be re-sent as it grows, so keep the latest per id.
                guard let part = event["part"] as? [String: Any], let id = part["id"] as? String else { return }
                let soFar = collected.set(id, part["text"] as? String ?? "")
                if let onText, !soFar.isEmpty { Task { @MainActor in onText(soFar) } }
            case "error":
                let error = event["error"] as? [String: Any]
                let detail = (error?["data"] as? [String: Any])?["message"] as? String ?? error?["name"] as? String
                collected.fail(detail ?? "opencode failed")
            default:
                break
            }
        }
        if exit.timedOut { throw ParaphraseError(message: "opencode took longer than \(Int(timeout)) seconds.") }
        if let failure = collected.failure { throw ParaphraseError(message: "\(action.verb) failed: \(failure)") }
        let out = collected.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard exit.status == 0, !out.isEmpty else {
            let detail = exit.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(exit.status)"
            throw ParaphraseError(message: "opencode returned no text (\(detail)).")
        }
        DebugLog.write("\(action) result: \(TextHygiene.describe(out))")
        return out
    }

    /// Text parts in arrival order, filled from the reader thread.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var order: [String] = [], parts: [String: String] = [:], _failure: String?

        var text: String { lock.withLock { order.compactMap { parts[$0] }.joined() } }
        var failure: String? { lock.withLock { _failure } }

        func set(_ id: String, _ value: String) -> String {
            lock.withLock {
                if parts[id] == nil { order.append(id) }
                parts[id] = value
                return order.compactMap { parts[$0] }.joined()
            }
        }

        func fail(_ message: String) { lock.withLock { _failure = message } }
    }
}

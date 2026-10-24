import Foundation

/// A Hermes failure, worded for the bubble. `unreachable` failures offer the direct fallback (Q12).
struct HermesError: LocalizedError {
    let message: String
    let unreachable: Bool
    var errorDescription: String? { message }
}

/// Which Hermes session a turn goes to.
enum HermesTarget {
    /// First turn of a source: create the session with this title.
    case create(title: String)
    /// Later turns: resume it by id.
    case resume(sessionId: String)
}

struct HermesReply {
    let sessionId: String
    let text: String
    /// Files Hermes wrote or patched during the turn despite the preamble (the write guard, Q10).
    let writes: [String]
    let seconds: Double
}

/// Talks to the Hermes agent on the home lab: one `ssh … hermes -p work chat` process per turn, the turn's text on
/// stdin, stream-json events on stdout (contract verified in slack-to-hermes D5). SSH connections are reused for 10
/// minutes so a follow-up skips the handshake (Q11). Turns run with a restricted toolset (Q10).
enum HermesClient {
    static let toolsets = "file,skills,session_search,clarify,todo"
    private static let turnTimeout: TimeInterval = 180, runBudget = 170
    private static let controlDirectory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Quili", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }()

    static func sshArguments(host: String, remoteCommand: String) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=4",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDirectory.path)/cm-%C",
            "-o", "ControlPersist=10m",
            "-T", host, remoteCommand,
        ]
    }

    static func chatCommand(settings: Settings, target: HermesTarget) -> String {
        var parts = [Shell.path(settings.hermesPath), "-p", Shell.quote(settings.hermesProfile), "chat",
                     "--query-file", "-", "--format", "stream-json", "-t", Shell.quote(toolsets),
                     "--run-budget", String(runBudget)]
        switch target {
        case .create(let title): parts += ["-c", Shell.quote(title), "--create-if-missing"]
        case .resume(let id): parts += ["--resume", Shell.quote(id)]
        }
        return "exec " + parts.joined(separator: " ")
    }

    /// Runs one turn. `onText` receives the reply so far while Hermes writes it.
    static func turn(_ input: String, target: HermesTarget, settings: Settings,
                     onText: (@MainActor (String) -> Void)? = nil) async throws -> HermesReply {
        let started = Date()
        let arguments = sshArguments(host: settings.hermesHost, remoteCommand: chatCommand(settings: settings, target: target))
        let state = TurnState()
        DebugLog.write("hermes turn: \(target.logName) on \(settings.hermesHost) (\(input.count) chars)")
        let exit = try await ProcessLines.run("/usr/bin/ssh", arguments, stdin: input, timeout: turnTimeout) { line in
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            switch event["type"] as? String {
            case "system":
                if let id = event["session_id"] as? String { state.update { $0.sessionId = id } }
            case "text":
                let soFar = state.update { s -> String in s.text += event["text"] as? String ?? ""; return s.text }
                if let onText { let shown = cleaned(soFar); Task { @MainActor in onText(shown) } }
            case "tool_use":
                let name = event["name"] as? String ?? ""
                guard ["write_file", "patch"].contains(name) else { return }
                let input = event["input"] as? [String: Any]
                let path = input?["path"] as? String ?? input?["file_path"] as? String ?? "?"
                state.update { $0.writes.append("\(name) \(path)") }
            case "result":
                state.update { s in
                    s.finished = true
                    if let id = event["session_id"] as? String, !id.isEmpty { s.sessionId = id }
                    if let text = event["text"] as? String, !text.isEmpty { s.text = text }
                    let code = event["exit_code"] as? Int ?? 0
                    if code != 0 || event["error"] != nil { s.failure = event["error"] as? String ?? "exit code \(code)" }
                }
            default:
                break
            }
        }
        let s = state.snapshot()
        if exit.timedOut { throw HermesError(message: "Hermes took longer than \(Int(turnTimeout)) seconds.", unreachable: false) }
        guard s.finished, s.failure == nil, exit.status == 0, let sessionId = s.sessionId else {
            throw classify(status: exit.status, stderr: exit.stderr, failure: s.failure, target: target, settings: settings)
        }
        if !s.writes.isEmpty { DebugLog.write("hermes turn: WROTE FILES despite the preamble: \(s.writes.joined(separator: "; "))") }
        let seconds = Date().timeIntervalSince(started)
        DebugLog.write("hermes turn: done in \(String(format: "%.1f", seconds)) s, session \(sessionId), \(s.text.count) chars")
        return HermesReply(sessionId: sessionId, text: cleaned(s.text), writes: s.writes, seconds: seconds)
    }

    /// Writes an approved note into the vault folder on the Hermes host, never overwriting (Q9). `name` must already be
    /// a plain file name; the folder comes from Settings. Returns the remote path.
    static func writeNote(_ markdown: String, name: String, settings: Settings) async throws -> String {
        guard name.range(of: #"^[a-z0-9][a-z0-9-]{0,90}\.md$"#, options: .regularExpression) != nil else {
            throw HermesError(message: "Refused to write an unexpected file name: \(name)", unreachable: false)
        }
        let folder = settings.vaultFolder
        // noclobber (set -C) makes `>` fail when the file exists.
        let command = "set -C; dir=\(Shell.path(folder)); mkdir -p \"$dir\" && cat > \"$dir\"/\(Shell.quote(name))"
        let exit = try await ProcessLines.run("/usr/bin/ssh", sshArguments(host: settings.hermesHost, remoteCommand: command),
                                              stdin: markdown, timeout: 30) { _ in }
        guard exit.status == 0 else {
            if exit.stderr.lowercased().contains("exist") || exit.stderr.lowercased().contains("overwrite") {
                throw HermesError(message: "A note named \(name) already exists; nothing was overwritten.", unreachable: false)
            }
            throw classify(status: exit.status, stderr: exit.stderr, failure: nil, target: nil, settings: settings)
        }
        DebugLog.write("note written: \(folder)/\(name) (\(markdown.count) chars)")
        return "\(folder)/\(name)"
    }

    /// Appends an approved update to a note written earlier (Q9: still never overwrites). The file must exist inside the
    /// notes folder from Settings.
    static func appendNote(_ markdown: String, to path: String, settings: Settings) async throws {
        let folder = settings.vaultFolder
        let name = (path as NSString).lastPathComponent
        guard path == "\(folder)/\(name)",
              name.range(of: #"^[a-z0-9][a-z0-9-]{0,90}\.md$"#, options: .regularExpression) != nil else {
            throw HermesError(message: "Refused to add to a note outside the notes folder: \(path)", unreachable: false)
        }
        let command = "f=\(Shell.path(folder))/\(Shell.quote(name)); [ -f \"$f\" ] || { echo 'note not found' >&2; exit 3; }; "
            + "{ printf '\\n'; cat; } >> \"$f\""
        let exit = try await ProcessLines.run("/usr/bin/ssh", sshArguments(host: settings.hermesHost, remoteCommand: command),
                                              stdin: markdown, timeout: 30) { _ in }
        guard exit.status == 0 else {
            if exit.status == 3 { throw HermesError(message: "The saved note \(name) is no longer there.", unreachable: false) }
            throw classify(status: exit.status, stderr: exit.stderr, failure: nil, target: nil, settings: settings)
        }
        DebugLog.write("note updated: \(path) (+\(markdown.count) chars)")
    }

    /// Drops Hermes' notes about its own memory configuration ("Honcho memory is off …"), which aren't part of the answer.
    static func cleaned(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        let kept = paragraphs.filter { !$0.lowercased().contains("honcho") }
        return kept.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hermes reports the real reason on stderr; ssh uses exit code 255 for its own failures.
    private static func classify(status: Int32, stderr: String, failure: String?, target: HermesTarget?,
                                 settings: Settings) -> HermesError {
        let lower = stderr.lowercased()
        let last = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("session_id:") }
        if lower.contains("session_not_owned") || lower.contains("open in another hermes window") {
            return HermesError(message: "This Hermes session is busy in another window. Try again when it finishes.", unreachable: false)
        }
        if lower.contains("session not found") {
            return HermesError(message: "The Hermes session for this conversation no longer exists.", unreachable: false)
        }
        if status == 255, failure == nil {
            if lower.contains("permission denied") || lower.contains("host key verification failed") {
                return HermesError(message: "SSH to \(settings.hermesHost) was refused. Check your SSH key.", unreachable: true)
            }
            return HermesError(message: "Can't reach Hermes on \(settings.hermesHost). Check Tailscale and SSH. (\(last ?? "ssh failed"))",
                               unreachable: true)
        }
        if lower.contains("profile") && (lower.contains("not found") || lower.contains("does not exist")) {
            return HermesError(message: "Hermes profile '\(settings.hermesProfile)' was not found on \(settings.hermesHost).", unreachable: true)
        }
        if lower.contains("command not found") {
            return HermesError(message: "Hermes was not found at \(settings.hermesPath) on \(settings.hermesHost).", unreachable: true)
        }
        return HermesError(message: "Hermes failed: \(last ?? failure ?? "exit code \(status)")", unreachable: false)
    }

    private struct Turn {
        var sessionId: String?
        var text = ""
        var writes: [String] = []
        var finished = false
        var failure: String?
    }

    private final class TurnState: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Turn()
        @discardableResult
        func update<T>(_ body: (inout Turn) -> T) -> T { lock.withLock { body(&value) } }
        func snapshot() -> Turn { lock.withLock { value } }
    }
}

private extension HermesTarget {
    var logName: String {
        switch self {
        case .create: return "new session"
        case .resume(let id): return "resume \(id)"
        }
    }
}

/// POSIX shell quoting for the remote command line.
enum Shell {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quotes a path but leaves a leading `~/` unquoted so the remote shell expands it.
    static func path(_ value: String) -> String {
        value.hasPrefix("~/") ? "~/" + quote(String(value.dropFirst(2))) : quote(value)
    }
}

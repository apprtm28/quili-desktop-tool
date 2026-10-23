import Foundation

/// Runs a command-line tool and hands its stdout to the caller line by line, for the two CLIs Quili talks to
/// (`opencode run` and `ssh … hermes chat`). Input goes on stdin only, never on the command line. Cancelling the
/// calling task terminates the process; `timeout` kills it.
enum ProcessLines {
    struct Exit {
        let status: Int32
        let stderr: String
        let timedOut: Bool
    }

    /// Calls `onLine` (on a background thread) for every stdout line, then returns how the process ended.
    static func run(_ executable: String, _ arguments: [String], stdin: String? = nil, environment: [String: String]? = nil,
                    directory: URL? = nil, timeout: TimeInterval, onLine: @escaping @Sendable (String) -> Void) async throws -> Exit {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        process.standardOutput = output
        process.standardError = errors

        let state = State()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Exit, Error>) in
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                state.started(process)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { state.timeOut() }

                if let stdin {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let handle = input.fileHandleForWriting
                        try? handle.write(contentsOf: Data(stdin.utf8))
                        try? handle.close()
                    }
                }
                let stderrDone = DispatchGroup()
                stderrDone.enter()
                DispatchQueue.global(qos: .utility).async {
                    state.stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    stderrDone.leave()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let reader = output.fileHandleForReading
                    var buffer = Data()
                    while true {
                        let chunk = reader.availableData
                        if chunk.isEmpty { break }
                        buffer.append(chunk)
                        while let newline = buffer.firstIndex(of: 0x0A) {
                            onLine(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                            buffer.removeSubrange(buffer.startIndex...newline)
                        }
                    }
                    if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
                    stderrDone.wait()
                    process.waitUntilExit()
                    state.finished()
                    if state.cancelled { continuation.resume(throwing: CancellationError()); return }
                    continuation.resume(returning: Exit(status: process.terminationStatus, stderr: state.stderr,
                                                        timedOut: state.timedOut))
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// Where a command-line tool lives. A GUI app doesn't get the login shell's PATH, so the usual install folders are
    /// tried first, then the login shell is asked.
    static func locate(_ name: String, extra: [String] = []) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = extra + ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v \(name)"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var _cancelled = false, _timedOut = false, _done = false, _stderr = ""

        var cancelled: Bool { lock.withLock { _cancelled } }
        var timedOut: Bool { lock.withLock { _timedOut } }
        var stderr: String {
            get { lock.withLock { _stderr } }
            set { lock.withLock { _stderr = newValue } }
        }

        func started(_ process: Process) {
            let cancelNow = lock.withLock { () -> Bool in self.process = process; return _cancelled }
            if cancelNow, process.isRunning { process.terminate() }
        }

        func finished() { lock.withLock { _done = true } }

        /// The timeout fired: stop the process unless it already ended.
        func timeOut() {
            let running = lock.withLock { () -> Process? in
                guard !_done else { return nil }
                _timedOut = true
                return process
            }
            if let running, running.isRunning { running.terminate() }
        }

        func cancel() {
            let running = lock.withLock { () -> Process? in _cancelled = true; return process }
            if let running, running.isRunning { running.terminate() }
        }
    }
}

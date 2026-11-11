// Headless controller regression tests. The runner combines this with the production controller,
// value types and prompts; only external services, persistence and the window are replaced.
import AppKit

final class Settings { var vaultFolder = "/notes" }
enum DebugLog { static func write(_ text: String) {} }
enum Notifier { static func show(_ title: String, _ body: String) {} }
enum TextAccess { static func setPasteboard(_ text: String) {} }
enum TextHygiene { static func slackMarkup(_ text: String) -> String { text } }
enum ThreadReader {
    static let maxChars = 38_000
    static func read(pid: pid_t) -> ThreadText? { nil }
}
@MainActor final class ConversationWindow {
    var onClose: (() -> Void)?
    var onAction: ((String) -> Void)?
    var onAsk: ((String) -> Void)?
    var onPickToggle: ((Int, Bool) -> Void)?
    var isVisible = false
    var draftText = ""
    var composerText = ""
    var current: ConversationState?
    func show(_ state: ConversationState, near: NSRect) { isVisible = true; update(state) }
    func update(_ state: ConversationState) {
        current = state
        if case .draft(let text, _) = state.body { draftText = text }
    }
    func updateStatus(_ text: String?) { current?.status = text }
    func prefillAsk(_ text: String) { composerText = text }
    func hide() { isVisible = false }
    func fadeOut() { hide() }
}
@MainActor enum HermesClient {
    static var calls = 0
    static var handler: ((String) async throws -> HermesReply)?
    static func turn(_ input: String, target: HermesTarget, settings: Settings,
                     onText: (@MainActor (String) -> Void)?) async throws -> HermesReply {
        calls += 1
        onText?("Partial reply")
        if let handler { return try await handler(input) }
        return HermesReply(sessionId: "session", text: "Completed reply", writes: [], seconds: 1)
    }
    static func appendNote(_ text: String, to: String, settings: Settings) async throws {}
    static func writeNote(_ text: String, name: String, settings: Settings) async throws -> String { "/notes/" + name }
}
enum TextAction { case summarizeThread }
@MainActor enum OpencodeClient {
    static func run(_ text: String, action: TextAction, settings: Settings, instructions: String?,
                    onText: (@MainActor (String) -> Void)?) async throws -> String { "Direct reply" }
}

extension HermesController {
    @MainActor static func regressionTests() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        func settle(_ controller: HermesController) async {
            for _ in 0..<200 {
                await Task.yield()
                if controller.busySince == nil, !controller.mode.isReading { return }
            }
            preconditionFailure("Controller did not settle")
        }
        func fixture(_ coverage: ReadCoverage? = ReadCoverage(messages: 2)) -> HermesSource {
            HermesSource(key: HermesSessions.key(kind: .thread, channel: "team", firstMessage: "parent"),
                         kind: .thread, channel: "team", title: "Topic", sessionId: "session",
                         sentMessages: ["parent", "reply"],
                         transcript: [.init(role: .summary, text: "Summary", date: Date())],
                         updated: Date(), coverage: coverage)
        }
        func reopen(_ source: HermesSource) -> HermesController {
            HermesSessions.shared.save(source)
            let controller = HermesController(settings: Settings())
            controller.openHistory(key: source.key, near: .zero)
            return controller
        }

        // Actual Codable types must read old records and preserve incomplete capture metadata.
        let incomplete = fixture(ReadCoverage(messages: 2, droppedOldest: 3, expectedReplies: 8))
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let decoded = try decoder.decode(HermesSource.self, from: encoder.encode(incomplete))
        check(decoded.coverage?.isClean == false, "Coverage lost in round trip")
        var legacy = try JSONSerialization.jsonObject(with: encoder.encode(incomplete)) as! [String: Any]
        legacy.removeValue(forKey: "coverage")
        legacy.removeValue(forKey: "composerDraft")
        let old = try decoder.decode(HermesSource.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(old.coverage == nil, "Old records must remain unknown, not clean")

        let history = reopen(incomplete)
        check(history.notice?.contains("Read 1 of 8") == true, "History lost warning")
        history.perform("save")
        check(history.window.current?.actions.contains { $0.id == "saveAnyway" } == true, "Incomplete history bypassed save gate")
        let unknown = reopen(old)
        unknown.perform("save")
        check(unknown.window.current?.actions.contains { $0.id == "saveAnyway" } == true, "Legacy history bypassed save gate")
        check(unknown.notice != nil, "Unknown coverage must be visible")

        // One refresh both reads Slack and sends fresh messages; no duplicates on a second check.
        let refresh = reopen(fixture())
        var reads = 0
        refresh.slack = SlackSource(kind: .thread, channel: "team", messages: ["parent", "reply"], coverage: ReadCoverage(messages: 2), reread: {
            reads += 1
            return SlackSource(kind: .thread, channel: "team", messages: ["parent", "reply", "new"], coverage: ReadCoverage(messages: 3), reread: refresh.slack?.reread)
        })
        let before = HermesClient.calls
        refresh.perform("refresh")
        await settle(refresh)
        check(reads == 1 && HermesClient.calls == before + 1, "Refresh must read and update in one action")
        check(refresh.record?.sentMessages.contains("new") == true, "New message not recorded")
        refresh.perform("refresh")
        await settle(refresh)
        check(HermesClient.calls == before + 1, "Repeated refresh resent old messages")
        check(refresh.notice?.contains("Already up to date") == true, "Missing up-to-date feedback")

        refresh.slack = SlackSource(kind: .thread, channel: "team", messages: [], coverage: ReadCoverage(), reread: {
            SlackSource(kind: .thread, channel: "other", messages: ["different parent"], coverage: ReadCoverage(), reread: nil)
        })
        refresh.perform("refresh")
        await settle(refresh)
        check(refresh.alert?.contains("different thread") == true, "Refresh mixed sources")
        check(HermesClient.calls == before + 1, "Wrong source was sent")

        // Retrying a failed question must not append the question twice.
        HermesClient.handler = { _ in throw HermesError(message: "Offline", unreachable: true) }
        refresh.ask("What changed?")
        await settle(refresh)
        check(refresh.actions().contains { $0.id == "retryTurn" }, "Failed follow-up has no retry")
        HermesClient.handler = nil
        refresh.perform("retryTurn")
        await settle(refresh)
        check(refresh.record?.transcript.filter { $0.role == .question }.count == 1, "Retry duplicated question")
        check(refresh.record?.transcript.last?.text == "Completed reply", "Retry did not complete")

        // Stop, immediately start another turn, then deliver the old result out of order.
        var pending: CheckedContinuation<HermesReply, Error>?
        HermesClient.handler = { _ in try await withCheckedThrowingContinuation { pending = $0 } }
        refresh.ask("Slow question")
        for _ in 0..<200 { if pending != nil { break }; await Task.yield() }
        check(pending != nil, "Slow turn did not start")
        check(refresh.actions().contains { $0.id == "stop" }, "No stop action")
        refresh.perform("stop")
        check(refresh.window.isVisible && refresh.busySince == nil, "Stop closed the window or stayed busy")
        check(refresh.partialResponse == "Partial reply", "Stop discarded partial response")
        HermesClient.handler = nil
        refresh.ask("Next question")
        await settle(refresh)
        pending?.resume(returning: HermesReply(sessionId: "old", text: "Stale reply", writes: [], seconds: 10))
        for _ in 0..<20 { await Task.yield() }
        check(refresh.record?.transcript.contains { $0.text == "Stale reply" } == false, "Cancelled turn polluted next conversation")
        check(refresh.record?.sessionId == "session", "Cancelled turn replaced session")

        refresh.window.composerText = "Unfinished question"
        let key = refresh.record!.key
        refresh.openHistory(key: key, near: .zero)
        check(refresh.window.composerText == "Unfinished question", "Reopening same conversation lost draft")
        refresh.close()
        let reopened = HermesController(settings: Settings())
        reopened.openHistory(key: key, near: .zero)
        check(reopened.window.composerText == "Unfinished question", "Close/reopen lost draft")
        let selection = HermesController(settings: Settings())
        selection.askAboutSelection("Copied context", source: "Browser", near: .zero)
        check(selection.actions().isEmpty, "New selection incorrectly offers Retry")
        selection.window.composerText = "Edited context and question"
        selection.close()
        selection.askAboutSelection("Copied context", source: "Browser", near: .zero)
        check(selection.window.composerText == "Edited context and question", "Unsent selection draft lost")

        print("PASS: coverage migration, history save gates, unified refresh, source isolation, retry, cancellation race, composer recovery")
    }
}
private extension HermesController.Mode {
    var isReading: Bool { if case .reading = self { return true }; return false }
}
@main struct RegressionMain {
    @MainActor static func main() async throws { try await HermesController.regressionTests() }
}

import AppKit

/// What Hermes is being asked about: a Slack thread, or a range of channel messages, as `{{ … }}` messages.
struct SlackSource {
    let kind: HermesSource.Kind
    let channel: String
    var messages: [String]
    var coverage: ReadCoverage
    /// Reads the source again (Retry read / Refresh); nil when it can't be re-read (a picked range).
    let reread: (() async -> SlackSource?)?

    var text: String { messages.joined(separator: "\n\n") }
}

/// Summaries, follow-up questions and work-context notes through the Hermes `work` profile (docs/hermes/decisions.md),
/// shown in the conversation bubble. One Hermes session per Slack source, resumed when the same thread comes back.
@MainActor
final class HermesController {
    private let settings: Settings
    private let window = ConversationWindow()
    private let store = HermesSessions.shared
    private var slack: SlackSource?
    private var record: HermesSource?
    private var task: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var busySince: Date?
    private var lastSeconds: Double?
    private var notice: String?
    private var alert: String?
    private var mode: Mode = .idle
    private var saveAnyway = false
    private var pick: [PickItem] = []
    private var pickedMessages: [String] = []
    private var pickChannel = ""
    private var pickCoverage = ReadCoverage()

    fileprivate enum Mode {
        case idle
        case reading
        case picking
        case conversation
        /// A summary made without Hermes (Q12): no session, no Ask, no Save.
        case direct(String?)
        case drafting(title: String)
        case unreachable
    }

    init(settings: Settings) {
        self.settings = settings
        window.onClose = { [weak self] in self?.close() }
        window.onAction = { [weak self] id in self?.perform(id) }
        window.onAsk = { [weak self] question in self?.ask(question) }
        window.onPickToggle = { [weak self] index, included in
            guard let self, self.pick.indices.contains(index) else { return }
            self.pick[index].included = included
            self.render()
        }
    }

    var isOpen: Bool { window.isVisible }
    private var anchor: NSRect = .zero

    func hide() {
        cancelWork()
        window.hide()
        mode = .idle
    }

    // MARK: Entry points

    /// ✦ on a thread: read it, then resume its session or start one.
    func summarizeThread(pid: pid_t, below anchor: NSRect) {
        cancelWork()
        self.anchor = anchor
        reset()
        mode = .reading
        window.show(state(body: .message("Reading the thread…")), near: anchor)
        task = Task { [weak self] in
            guard let self else { return }
            guard let source = await Self.readThread(pid: pid), !Task.isCancelled else {
                if !Task.isCancelled {
                    self.window.hide()
                    Notifier.show("No thread found", "Open the thread in Slack's side pane (click its replies link) and try again.")
                }
                return
            }
            self.open(source)
        }
    }

    /// A collected range: let the user untick noise first (Q4).
    func pickRange(messages: [String], headers: [(String, String)], channel: String, coverage: ReadCoverage, near anchor: NSRect) {
        cancelWork()
        self.anchor = anchor
        reset()
        pickedMessages = messages
        pickChannel = channel
        pickCoverage = coverage
        pick = headers.map { PickItem(header: $0.0, preview: $0.1, included: true) }
        mode = .picking
        notice = coverage.warning
        var initial = state(body: .pick(pick))
        initial.actions = actions()
        window.show(initial, near: anchor)
    }

    /// ⌃⌥H: text selected in another app (Gmail, Chrome…) becomes its own source, summarized by Hermes.
    func askAboutSelection(_ text: String, source: String, near anchor: NSRect) {
        cancelWork()
        self.anchor = anchor
        reset()
        var coverage = ReadCoverage(messages: 1)
        var body = text
        if body.count > ThreadReader.maxChars {
            body = String(body.prefix(ThreadReader.maxChars))
            coverage.stoppedEarly = true
        }
        mode = .reading
        window.show(state(body: .message("Reading the selection…")), near: anchor)
        open(SlackSource(kind: .selection, channel: source, messages: [body], coverage: coverage, reread: nil))
    }

    static func readThread(pid: pid_t) async -> SlackSource? {
        let thread = await Task.detached { ThreadReader.read(pid: pid) }.value
        guard let thread, thread.text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else { return nil }
        DebugLog.write("read \(thread.text.count) chars from the thread\(thread.truncated ? " (oldest messages dropped)" : "")")
        DebugLog.write("thread text to summarize:\n\(thread.text)")
        return SlackSource(kind: .thread, channel: thread.channel, messages: thread.messages, coverage: thread.coverage,
                           reread: { await HermesController.readThread(pid: pid) })
    }

    // MARK: Conversation

    /// Shows a source: its earlier conversation when there is one (new messages offer Refresh), else a new summary.
    private func open(_ source: SlackSource) {
        slack = source
        notice = source.coverage.warning
        let key = HermesSessions.key(kind: source.kind, channel: source.channel, firstMessage: source.messages.first ?? "")
        if let known = store.source(key), known.sessionId != nil, !known.transcript.isEmpty {
            record = known
            mode = .conversation
            let fresh = newMessages(in: source, for: known)
            DebugLog.write("hermes: resumed \(key) (\(fresh.count) new messages)")
            if !fresh.isEmpty {
                let count = "\(fresh.count) new message\(fresh.count == 1 ? "" : "s") since this summary"
                notice = [notice, count].compactMap { $0 }.joined(separator: " · ")
            }
            render()
            return
        }
        record = HermesSource(key: key, kind: source.kind, channel: source.channel, title: Self.title(for: source),
                              sessionId: nil, sentMessages: [], transcript: [], updated: Date())
        summarize()
    }

    private func summarize() {
        guard let slack, let record else { return }
        let input = slack.kind == .selection
            ? Prompts.hermesSelection(source: slack.channel, text: slack.text)
            : Prompts.hermesSummary(kind: slack.kind.rawValue, channel: slack.channel, text: slack.text,
                                    coverage: slack.coverage.warning)
        let target: HermesTarget = record.sessionId.map { .resume(sessionId: $0) } ?? .create(title: record.title)
        mode = .conversation
        runTurn(input, target: target, role: .summary, sending: slack.messages)
    }

    private func ask(_ question: String) {
        guard var record, let session = record.sessionId, busySince == nil else { return }
        record.transcript.append(.init(role: .question, text: question, date: Date()))
        self.record = record
        store.save(record)
        runTurn(question, target: .resume(sessionId: session), role: .answer, sending: [])
    }

    private func refresh() {
        guard let slack, let record, let session = record.sessionId else { return }
        let fresh = newMessages(in: slack, for: record)
        guard !fresh.isEmpty else { notice = slack.coverage.warning; render(); return }
        notice = slack.coverage.warning
        let input = Prompts.hermesRefresh(kind: slack.kind.rawValue, channel: slack.channel, newText: fresh.joined(separator: "\n\n"))
        runTurn(input, target: .resume(sessionId: session), role: .summary, sending: fresh)
    }

    private func newMessages(in source: SlackSource, for record: HermesSource) -> [String] {
        let sent = Set(record.sentMessages)
        return source.messages.filter { !sent.contains(HermesSessions.normalized($0)) }
    }

    /// One Hermes turn with live text and an elapsed-time status; the result joins the transcript.
    private func runTurn(_ input: String, target: HermesTarget, role: HermesSource.Entry.Role, sending: [String]) {
        alert = nil
        startBusy()
        render(streaming: "")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await HermesClient.turn(input, target: target, settings: self.settings) { [weak self] soFar in
                    guard let self, self.busySince != nil else { return }
                    self.lastStreamed = soFar
                    self.render(streaming: soFar)
                }
                try Task.checkCancellation()
                self.stopBusy(seconds: reply.seconds)
                guard var record = self.record else { return }
                record.sessionId = reply.sessionId
                record.sentMessages += sending.map(HermesSessions.normalized)
                if case .drafting = self.mode {
                    self.record = record
                    self.store.save(record)
                    self.showDraft(reply.text)
                } else {
                    record.transcript.append(.init(role: role, text: reply.text, date: Date()))
                    self.record = record
                    self.store.save(record)
                    if role == .summary {
                        TextAccess.setPasteboard(TextHygiene.slackMarkup(reply.text))
                        Notifier.show("Summarized with Hermes", "The summary was copied to the clipboard.")
                    }
                }
                if !reply.writes.isEmpty {
                    self.alert = "Hermes changed files despite being told not to: \(reply.writes.joined(separator: "; "))"
                }
                self.render()
            } catch is CancellationError {
                self.stopBusy(seconds: nil)
            } catch let error as HermesError {
                self.stopBusy(seconds: nil)
                self.failed(error)
            } catch {
                self.stopBusy(seconds: nil)
                self.failed(HermesError(message: error.localizedDescription, unreachable: false))
            }
        }
    }

    private func failed(_ error: HermesError) {
        DebugLog.write("hermes failed: \(error.message)")
        alert = error.message
        if case .drafting = mode { mode = .conversation }
        if error.unreachable, record?.sessionId == nil { mode = .unreachable }
        render()
    }

    // MARK: Fallback (Q12)

    private func summarizeDirectly() {
        guard let slack else { return }
        alert = nil
        mode = .direct(nil)
        startBusy()
        render(streaming: "")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let started = Date()
                let instructions = slack.kind == .selection ? Prompts.summarizeSelectionDirect : nil
                let text = try await OpencodeClient.run(slack.text, action: .summarizeThread, settings: self.settings,
                                                        instructions: instructions) { [weak self] soFar in
                    guard let self, self.busySince != nil else { return }
                    self.lastStreamed = soFar
                    self.render(streaming: soFar)
                }
                try Task.checkCancellation()
                self.stopBusy(seconds: Date().timeIntervalSince(started))
                self.mode = .direct(text)
                TextAccess.setPasteboard(TextHygiene.slackMarkup(text))
                Notifier.show("Summarized directly", "Not saved to Hermes. The summary was copied to the clipboard.")
                self.render()
            } catch is CancellationError {
                self.stopBusy(seconds: nil)
            } catch {
                self.stopBusy(seconds: nil)
                self.mode = .unreachable
                self.alert = error.localizedDescription
                self.render()
            }
        }
    }

    // MARK: Save to work context (Q5, Q8, Q9)

    private func saveToContext() {
        guard let slack, let record, let session = record.sessionId, busySince == nil else { return }
        if !slack.coverage.isClean && !saveAnyway {
            alert = "This read may be incomplete (\(slack.coverage.warning ?? "")). Retry the read, or save anyway."
            render(extra: [ConversationAction(id: "saveAnyway", title: "Save anyway")])
            return
        }
        mode = .drafting(title: record.title)
        runTurn(Prompts.hermesNoteDraft, target: .resume(sessionId: session), role: .note, sending: [])
    }

    private func showDraft(_ reply: String) {
        guard let parsed = Self.parseNote(reply) else {
            mode = .conversation
            alert = "Hermes didn't return a note draft. Try Save to work context again."
            return
        }
        let header = Self.frontMatter(channel: slack?.channel ?? "", session: record?.sessionId ?? "")
        mode = .drafting(title: parsed.title)
        window.show(state(body: .draft(text: "\(header)# \(parsed.title)\n\n\(parsed.body)\n", target: target(for: parsed.title))),
                    near: anchor)
    }

    private func approveDraft() {
        let markdown = window.draftText
        let title = markdown.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? record?.title ?? "note"
        let name = Self.fileName(for: title)
        startBusy()
        render()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let path = try await HermesClient.writeNote(markdown, name: name, settings: self.settings)
                self.stopBusy(seconds: nil)
                self.mode = .conversation
                self.saveAnyway = false
                if var record = self.record {
                    record.transcript.append(.init(role: .note, text: path, date: Date()))
                    self.record = record
                    self.store.save(record)
                }
                Notifier.show("Saved to work context", name)
                self.render()
            } catch {
                self.stopBusy(seconds: nil)
                self.alert = error.localizedDescription
                self.render() // stays in the draft so nothing typed is lost
            }
        }
    }

    // MARK: Actions

    private func perform(_ id: String) {
        switch id {
        case "summarizePick": summarizePick()
        case "cancel": close()
        case "refresh": refresh()
        case "save": saveToContext()
        case "saveAnyway": saveAnyway = true; saveToContext()
        case "retryRead": retryRead()
        case "retry":
            if record?.sessionId == nil { summarize() } else { alert = nil; render() }
        case "direct": summarizeDirectly()
        case "approve": approveDraft()
        case "discard": mode = .conversation; alert = nil; render()
        case "forget":
            if let key = record?.key { store.forget(key) }
            if let slack { record = nil; open(slack) }
        default: break
        }
    }

    private func summarizePick() {
        let chosen = zip(pickedMessages, pick).filter { $0.1.included }.map(\.0)
        guard !chosen.isEmpty else { alert = "Tick at least one message."; render(); return }
        var coverage = pickCoverage
        coverage.messages = chosen.count
        coverage.expectedReplies = nil
        open(SlackSource(kind: .range, channel: pickChannel, messages: chosen, coverage: coverage, reread: nil))
    }

    private func retryRead() {
        guard let reread = slack?.reread, busySince == nil else { return }
        alert = nil
        saveAnyway = false
        mode = .reading
        render()
        task = Task { [weak self] in
            guard let self else { return }
            guard let source = await reread(), !Task.isCancelled else {
                self.alert = "Couldn't read the thread again. Is it still open in Slack?"
                self.mode = .conversation
                self.render()
                return
            }
            if self.record?.sessionId == nil {
                self.open(source)
            } else {
                self.slack = source
                self.mode = .conversation
                self.notice = source.coverage.warning
                if let record = self.record {
                    let fresh = self.newMessages(in: source, for: record)
                    if !fresh.isEmpty {
                        let count = "\(fresh.count) new message\(fresh.count == 1 ? "" : "s") since this summary"
                        self.notice = [self.notice, count].compactMap { $0 }.joined(separator: " · ")
                    }
                }
                self.render()
            }
        }
    }

    private func close() {
        DebugLog.write("conversation bubble closed (busy=\(busySince != nil))")
        cancelWork()
        window.fadeOut()
        mode = .idle
    }

    // MARK: Rendering

    private func render(streaming: String? = nil, extra: [ConversationAction] = []) {
        guard window.isVisible else { return }
        var body: ConversationBody
        switch mode {
        case .idle, .reading:
            body = .message("Reading the thread…")
        case .picking:
            body = .pick(pick)
        case .direct(let text):
            body = .transcript(text.map { [.init(role: .summary, text: $0, date: Date())] } ?? [], streaming: text == nil ? streaming ?? "" : nil)
        case .drafting:
            if busySince != nil, streaming != nil {
                body = .message("Hermes is drafting the note…")
            } else {
                // Keep the draft on screen (an approve failure re-renders it).
                body = .draft(text: window.draftText, target: target(for: currentDraftTitle))
            }
        case .conversation, .unreachable:
            body = .transcript(record?.transcript ?? [], streaming: streaming)
        }
        if case .conversation = mode, record?.transcript.isEmpty ?? true, streaming == nil, busySince == nil {
            body = .message(alert == nil ? "Reading the thread…" : "No summary yet.")
        }
        var s = state(body: body)
        s.actions = actions() + extra
        window.update(s)
    }

    private var currentDraftTitle: String {
        if case .drafting(let title) = mode { return title }
        return record?.title ?? "note"
    }

    private func state(body: ConversationBody) -> ConversationState {
        let sourceKind = slack?.kind ?? (mode.isPicking ? .range : .thread)
        let kind = sourceKind.rawValue
        let channel = slack?.channel ?? pickChannel
        var title = channel.isEmpty ? "Slack \(kind)" : "#\(channel) · \(kind)"
        if sourceKind == .selection { title = channel.isEmpty ? "Selection" : channel }
        if case .direct = mode { title += " · direct" }
        var status: String?
        if let busySince { status = "Hermes · \(Int(Date().timeIntervalSince(busySince))) s" }
        else if let lastSeconds { status = "Hermes · \(String(format: "%.0f", lastSeconds)) s" }
        if case .direct = mode { status = busySince == nil ? "Not saved to Hermes" : status?.replacingOccurrences(of: "Hermes", with: "opencode") }
        if mode.isPicking { status = "\(pick.filter(\.included).count) of \(pick.count) messages" }
        var ask: String?
        if case .conversation = mode, record?.sessionId != nil { ask = "Ask Hermes…" }
        return ConversationState(title: title, status: status, notice: notice, alert: alert, body: body,
                                 actions: [], askPlaceholder: ask, busy: busySince != nil)
    }

    private func actions() -> [ConversationAction] {
        if busySince != nil { return [] }
        switch mode {
        case .idle, .reading: return []
        case .picking:
            return [ConversationAction(id: "summarizePick", title: "Summarize with Hermes", primary: true),
                    ConversationAction(id: "cancel", title: "Cancel")]
        case .direct:
            return slack?.reread == nil ? [] : [ConversationAction(id: "retryRead", title: "Retry read")]
        case .drafting:
            return [ConversationAction(id: "approve", title: "Approve and save", primary: true),
                    ConversationAction(id: "discard", title: "Discard")]
        case .unreachable:
            return [ConversationAction(id: "retry", title: "Retry", primary: true),
                    ConversationAction(id: "direct", title: "Summarize directly this once")]
        case .conversation:
            guard record?.sessionId != nil else {
                return [ConversationAction(id: "retry", title: "Retry", primary: true)]
            }
            var list: [ConversationAction] = []
            if let slack, let record, !newMessages(in: slack, for: record).isEmpty {
                list.append(ConversationAction(id: "refresh", title: "Refresh", primary: true))
            }
            list.append(ConversationAction(id: "save", title: "Save to work context", primary: list.isEmpty))
            if slack?.reread != nil { list.append(ConversationAction(id: "retryRead", title: "Retry read")) }
            list.append(ConversationAction(id: "forget", title: "Start over"))
            return list
        }
    }

    // MARK: Busy state

    private func startBusy() {
        busySince = Date()
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.busySince != nil, !Task.isCancelled else { return }
                self.refreshStatus()
            }
        }
    }

    /// Only the status text changes each second; the body stays as streamed.
    private var lastStreamed: String?
    private func refreshStatus() {
        render(streaming: lastStreamed ?? "")
    }

    private func stopBusy(seconds: Double?) {
        busySince = nil
        lastStreamed = nil
        if let seconds { lastSeconds = seconds }
        ticker?.cancel()
        ticker = nil
    }

    private func cancelWork() {
        task?.cancel()
        task = nil
        stopBusy(seconds: nil)
    }

    private func reset() {
        slack = nil
        record = nil
        notice = nil
        alert = nil
        lastSeconds = nil
        saveAnyway = false
        pick = []
    }

    // MARK: Helpers

    static func title(for source: SlackSource) -> String {
        let first = source.messages.first ?? ""
        let lines = first.replacingOccurrences(of: "{{", with: "").replacingOccurrences(of: "}}", with: "").split(separator: "\n")
        let body = (source.kind == .selection ? lines[...] : lines.dropFirst()).joined(separator: " ")
        let words = body.split(separator: " ").prefix(8).joined(separator: " ")
        let channel = source.channel.isEmpty ? "slack" : source.channel
        return String("quili: \(channel) – \(words.isEmpty ? source.kind.rawValue : words)".prefix(80))
    }

    private func target(for title: String) -> String { "\(settings.vaultFolder)/\(Self.fileName(for: title))" }

    /// `2026-10-23-checkout-5xx-rollback.md`: today's date and the title's words, lowercase ASCII.
    static func fileName(for title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US")).lowercased()
        let slug = folded.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // At most 60 characters, cut at a word boundary.
        var short = slug
        if short.count > 60 {
            short = String(short.prefix(61))
            short = short.range(of: "-", options: .backwards).map { String(short[..<$0.lowerBound]) } ?? String(short.prefix(60))
        }
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        return "\(date)-\(short.isEmpty ? "note" : short)" + ".md"
    }

    static func frontMatter(channel: String, session: String) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        return "---\nsource: quili\nchannel: \"\(channel.replacingOccurrences(of: "\"", with: "'"))\"\nsaved: \(now)\nhermes_session: \(session)\n---\n\n"
    }

    /// The `<quili_note title="…">…</quili_note>` block of a draft reply.
    static func parseNote(_ reply: String) -> (title: String, body: String)? {
        guard let open = reply.range(of: #"<quili_note\s+title="([^"]*)"\s*>"#, options: .regularExpression),
              let close = reply.range(of: "</quili_note>", range: open.upperBound..<reply.endIndex) else { return nil }
        let tag = String(reply[open])
        let title = tag.replacingOccurrences(of: #"^<quili_note\s+title=""#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #""\s*>$"#, with: "", options: .regularExpression)
        let body = String(reply[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return (title.isEmpty ? "Slack notes" : title, body)
    }
}

private extension HermesController.Mode {
    var isPicking: Bool { if case .picking = self { return true }; return false }
}

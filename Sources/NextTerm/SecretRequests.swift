import AppKit
import NextTermCore

/// Every use of a stored key goes through here (KTD9-KTD11): one queue for tool calls, tickets and wrapper requests,
/// one panel at a time, the limits, and the grants with their own values.
///
/// - A request a grant answers starts with no panel, from the grant's own values. A remote request never makes or
///   uses a grant.
/// - A request the limits refuse gets its reason at once: the hour pause, a stopped asker, a declined request
///   paused for 10 minutes, a reached count.
/// - An identical request (the same binding as one waiting, or as a pending card) takes over that panel or card. It
///   does not count and does not queue. Otherwise up to 5 wait, and more get `busy`.
/// - Allow asks `SecretsStore` to use the keys, which asks for Touch ID or the password. "Allow for 15 minutes" and
///   "Allow this command until the Mac locks" keep copies of exactly those keys' values in a grant.
/// - Grants end on a lock, a sleep, the session resigning, Revoke, a key's change, the hour pause, and for
///   `run_with_secrets` when its asking tab gets input from MCP. Values are dropped with them.
@MainActor
final class SecretRequests {
    static let shared = SecretRequests()
    /// Posted when the queue, the grants or the limits changed: Settings › Secrets and the panel refresh.
    static let changed = Notification.Name("NextTermSecretRequestsChanged")

    /// How long a pending card, and a tool request with no answer, waits before it is dropped (the self-test shortens it).
    static var dropAfter: Duration = .seconds(30 * 60)

    /// How long an approval lasts, as the panel's "How long" offers it.
    enum How: Equatable {
        case once, fifteenMinutes, untilLock

        var approval: SecretAudit.Approval {
            switch self {
            case .once: return .once
            case .fifteenMinutes: return .fifteenMinutes
            case .untilLock: return .untilLock
            }
        }

        var grantKind: SecretGrant.Kind? {
            switch self {
            case .once: return nil
            case .fifteenMinutes: return .fifteenMinutes
            case .untilLock: return .untilLock
            }
        }
    }

    /// Next Term's facts about who asks, as the panel's Asked by rows show them. None is the asker's own word but the
    /// agent's name, which is shown as "going by its program's name".
    struct AskedBy {
        /// The agent's name ("Codex"), from shell integration or the process tree; never shown as checked.
        var agent: String?
        /// A wrapper whose peer passed `PeerCode`.
        var checkedNxtrm = false
        /// "tab 3", and its project's path.
        var tab: String?
        var tabID: UUID?
        var project: String?
        /// The remote connection's name.
        var connection: String?
        /// The title a program set on the tab.
        var programTitle: String?
        /// Details: the process, its executable, every argument.
        var pid: pid_t?
        var executable: String?
        var arguments: [String] = []
    }

    /// One key a request uses, with what the panel shows of it.
    struct Key: Equatable {
        var name: String
        var envName: String
    }

    /// What a request is answered with.
    enum Decision {
        /// The keys' values, for that connection only. `how` is how it was approved.
        case allowed([String: SecretBytes], how: SecretAudit.Approval)
        /// The user declined: Decline, Decline and Stop Asking, or closing the panel.
        case declined(stopAsking: Bool)
        /// Refused before any panel.
        case refused(SecretLimits.Refusal)
        /// The vault can't open, was tampered with, or a key is gone.
        case failed(SecretsStore.Failure)
    }

    /// One request, waiting for its panel or in it.
    final class Request {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let binding: SecretBinding
        let keys: [Key]
        /// The command as the panel shows it: `run_with_secrets`' text, or the wrapper's argv after `--`, escaped.
        let command: String
        /// The full argv, for Details: `/bin/sh -c …` for `run_with_secrets`.
        let argv: [String]
        let folder: String
        var warnings: [String]
        /// The agent's reason, in its own words.
        let agentWords: String?
        let askedBy: AskedBy
        /// The program, for the title and the Touch ID reason: the command's first word.
        let program: String
        let isRemote: Bool
        /// Why the panel says what it says, beyond the usual (store_secret's replace line).
        var notice: String?
        /// A title of its own (store_secret's), instead of "… asks to run …".
        var titleOverride: String?
        let made: ContinuousClock.Instant
        /// A wrapper request whose wrapper stopped waiting: a pending card.
        fileprivate(set) var gone = false
        fileprivate var goneAt: ContinuousClock.Instant?
        fileprivate var replies: [(Decision) -> Void] = []
        fileprivate(set) var panel: SecretApprovalPanel?
        fileprivate(set) var isAnswered = false

        init(binding: SecretBinding, keys: [Key], command: String, argv: [String], folder: String, warnings: [String],
             agentWords: String?, askedBy: AskedBy, program: String, isRemote: Bool, made: ContinuousClock.Instant = .now) {
            self.binding = binding
            self.keys = keys
            self.command = command
            self.argv = argv
            self.folder = folder
            self.warnings = warnings
            self.agentWords = agentWords
            self.askedBy = askedBy
            self.program = program
            self.isRemote = isRemote
            self.made = made
        }

        var asker: String { binding.asker }
        var isWrapper: Bool { binding.source == .wrapper }
        var names: [String] { keys.map(\.name) }
    }

    /// Waiting requests, the one in the panel first.
    private(set) var queue: [Request] = []
    private(set) var limits = SecretLimits()
    private(set) var book = SecretGrantBook()
    /// Each grant's own values, by its id.
    private var held: [String: [String: SecretBytes]] = [:]
    /// The clock: the self-test moves it.
    var now: () -> ContinuousClock.Instant = { .now }
    private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(NotificationCenter.default.addObserver(forName: SecretsStore.locked, object: nil, queue: .main) { note in
            let event = note.userInfo?["event"] as? SecretsStore.LockEvent ?? .screenLocked
            MainActor.assumeIsolated { SecretRequests.shared.locked(event) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: SecretsStore.keysChanged, object: nil, queue: .main) { note in
            let names = note.userInfo?["names"] as? [String] ?? []
            MainActor.assumeIsolated { for name in names { SecretRequests.shared.end(.keyChanged(name)) } }
        })
    }

    // MARK: asking

    /// Answers `request` from a grant, refuses it, lets it take over an identical one, or queues it for the panel.
    func ask(_ request: Request, reply: @escaping (Decision) -> Void) {
        let now = now()
        expire(at: now)
        if !request.isRemote, let grant = book.take(request.binding, at: now), let values = held[grant.id] {
            limits.record(.answeredByGrant, asker: request.asker, binding: request.binding, at: now)
            if grant.isExpired(at: now) { drop(grant.id) }
            audit(.use, request, approval: .grant, outcome: "allowed")
            changedNow()
            return reply(.allowed(copies(values), how: .grant))
        }
        if let refusal = limits.admit(asker: request.asker, binding: request.binding, at: now) {
            limits.record(.refusedByLimits, asker: request.asker, binding: request.binding, at: now)
            audit(.refused, request, outcome: Self.word(refusal))
            return reply(.refused(refusal))
        }
        if let waiting = queue.first(where: { $0.binding == request.binding && !$0.isAnswered }) {
            limits.record(.tookOver, asker: request.asker, binding: request.binding, at: now)
            waiting.replies.append(reply)
            if waiting.gone {
                waiting.gone = false
                waiting.goneAt = nil
                waiting.panel?.markBack()
            }
            changedNow()
            return
        }
        if SecretLimits.isBusy(waiting: queue.count) { return reply(.refused(.busy)) }
        request.replies = [reply]
        queue.append(request)
        let drop = Self.dropAfter
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seconds(drop)) { [weak request] in
            MainActor.assumeIsolated {
                guard let request else { return }
                SecretRequests.shared.dropIfStale(request)
            }
        }
        showNext()
        changedNow()
    }

    /// The wrapper behind a request stopped waiting (after 25 seconds, or it left): its panel becomes a pending card.
    /// Nothing ends and nothing counts until the card is dropped.
    func wrapperLeft(_ request: Request) {
        guard !request.isAnswered, request.isWrapper else { return }
        request.replies.removeAll()
        request.gone = true
        request.goneAt = now()
        request.panel?.markGone()
        let drop = Self.dropAfter
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seconds(drop)) { [weak request] in
            MainActor.assumeIsolated {
                guard let request else { return }
                SecretRequests.shared.dropIfStale(request)
            }
        }
        changedNow()
    }

    /// A ticket's caller (U6) stopped waiting for a request that is not a wrapper's: it ends unanswered.
    func callerLeft(_ request: Request) {
        guard !request.isAnswered else { return }
        finish(request, outcome: .unanswered, decision: nil)
    }

    /// Drops a pending card after 30 minutes, and a tool request whose panel waited 30 minutes with no answer.
    func dropIfStale(_ request: Request) {
        guard !request.isAnswered, queue.contains(where: { $0 === request }) else { return }
        let start = request.goneAt ?? request.made
        guard now() - start >= Self.dropAfter else { return }
        finish(request, outcome: .unanswered, decision: nil)
    }

    /// A ticket's wrapper redeems it. `run_with_secrets` makes tickets (U6); until then none is known, so every
    /// ticket has expired.
    func redeem(ticket: String, peerTab: TerminalTab?, request: SecretRun.Request, reply: @escaping (SecretRun.Answer) -> Void) {
        reply(SecretRun.Answer(status: .expired, names: request.names))
    }

    /// The request in the panel now, if any.
    var showing: Request? { queue.first { $0.panel != nil } }

    private func showNext() {
        guard showing == nil, let next = queue.first(where: { !$0.isAnswered }) else { return }
        let panel = SecretApprovalPanel(content(of: next), onAllow: { [weak self, weak next] how in
            guard let self, let next else { return }
            self.allow(next, how: how)
        }, onDecline: { [weak self, weak next] stop in
            guard let self, let next else { return }
            self.decline(next, stopAsking: stop)
        }, onPause: { [weak self, weak next] in
            guard let self, let next else { return }
            self.pauseForAnHour(from: next)
        })
        next.panel = panel
        if next.gone { panel.markGone() }
        panel.present(urgent: next.isWrapper)
    }

    private func refreshWaitingLine() {
        showing?.panel?.setWaiting(max(0, queue.count - 1))
    }

    func content(of request: Request) -> SecretApprovalPanel.Content {
        let store = SecretsStore.shared
        let keys = request.keys.map { key -> SecretApprovalPanel.Content.KeyRow in
            let entry = store.index?.entry(named: key.name)
            let used = store.lastUse[key.name]
            return SecretApprovalPanel.Content.KeyRow(name: key.name, envName: key.envName, purpose: entry?.purpose ?? "",
                                                      purposeByAgent: entry?.purposeBy == .agent, writeOnly: entry?.writeOnly == true,
                                                      lastUsed: used.map { SecretApprovalPanel.lastUsedText($0) } ?? "Never used")
        }
        return SecretApprovalPanel.Content(
            title: SecretApprovalPanel.title(request), keys: keys, command: request.command, runsAsShell: !request.isWrapper,
            folder: request.folder, warnings: request.warnings, agentWords: request.agentWords, askedBy: request.askedBy,
            argv: request.argv, isWrapper: request.isWrapper, isRemote: request.isRemote, notice: request.notice,
            waiting: max(0, queue.count - 1))
    }

    // MARK: answers

    private func allow(_ request: Request, how: How) {
        guard !request.isAnswered, let panel = request.panel else { return }
        let how: How = request.isRemote ? .once : how
        panel.setBusy(true)
        let reason = SecretReason.use(request.names, program: request.program, folder: request.folder)
        let facts = SecretsStore.Facts(who: Self.who(request), command: request.command, folder: request.folder, approval: how.approval)
        Task { @MainActor in
            do {
                let values = try await SecretsStore.shared.perform(.use(names: request.names), reason: reason, facts: facts)
                self.allowed(request, how: how, values: values)
            } catch SecretsStore.Failure.cancelled {
                panel.setBusy(false)
                panel.notApproved()
            } catch {
                let failure = error as? SecretsStore.Failure ?? .keyring
                self.finish(request, outcome: .allowed, decision: .failed(failure))
            }
        }
    }

    private func allowed(_ request: Request, how: How, values: [String: SecretBytes]) {
        let now = now()
        var kind = how.grantKind
        // Q1: the wrapper left while the user was in the Touch ID sheet after "Allow once": a one-use grant for 2 minutes.
        let stoppedDuringApproval = request.isWrapper && request.gone && how == .once
        if stoppedDuringApproval { kind = .oneUse }
        if let kind, !request.isRemote {
            let grant = SecretGrant(kind: kind, binding: request.binding, made: now)
            book.add(grant)
            held[grant.id] = copies(values)
            audit(.grant, request, approval: how.approval, outcome: kind.rawValue)
        }
        if stoppedDuringApproval {
            request.isAnswered = true
            request.panel?.showStoppedDuringApproval()
            queue.removeAll { $0 === request }
            changedNow()
            return
        }
        finish(request, outcome: .allowed, decision: .allowed(values, how: how.approval))
    }

    private func decline(_ request: Request, stopAsking: Bool) {
        guard !request.isAnswered else { return }
        if stopAsking { limits.stop(request.asker) }
        audit(.decline, request, outcome: stopAsking ? "declined and stopped asking" : "declined")
        finish(request, outcome: .declined, decision: .declined(stopAsking: stopAsking))
    }

    /// "Pause Key Requests for 1 Hour…", after its confirm: this and every waiting request are declined, new ones are
    /// refused for an hour, and every grant ends.
    func pauseForAnHour(from request: Request?) {
        let now = now()
        limits.pauseForAnHour(at: now)
        end(.hourPause)
        audit(.pause, request, outcome: "paused for an hour")
        let until = limits.hourPause?.untilDate ?? Date().addingTimeInterval(3600)
        for waiting in queue where !waiting.isAnswered {
            finish(waiting, outcome: .refusedByLimits, decision: .refused(.declining(until: until)))
        }
        changedNow()
    }

    /// Ends a request: records its outcome once, answers whoever still waits, closes its panel, shows the next.
    private func finish(_ request: Request, outcome: SecretLimits.Outcome, decision: Decision?) {
        guard !request.isAnswered else { return }
        request.isAnswered = true
        limits.record(outcome, asker: request.asker, binding: request.binding, at: now())
        let replies = request.replies
        request.replies.removeAll()
        if let decision { for reply in replies { reply(decision) } }
        request.panel?.finish()
        request.panel = nil
        queue.removeAll { $0 === request }
        showNext()
        refreshWaitingLine()
        changedNow()
    }

    // MARK: grants

    /// MCP or a remote connection typed into a tab: the `run_with_secrets` grants it asked for end.
    func tabGotInput(_ tab: UUID) {
        end(.tabGotInput(tab.uuidString))
    }

    /// The hook in `MCPControl.sent(to:)`, which runs on the main thread.
    nonisolated static func tabGotInput(_ tab: UUID) {
        MainActor.assumeIsolated { shared.tabGotInput(tab) }
    }

    func revoke(_ id: String) { end(.revoke(id)) }
    func revokeAll() { end(.revokeAll) }

    func end(_ event: SecretGrantEvent) {
        let ended = book.end(event)
        guard !ended.isEmpty else { return }
        for grant in ended {
            drop(grant.id)
            let line = SecretAudit.Line(event: .grantEnd, names: grant.names, command: grant.binding.command.joined(separator: " "),
                                        folder: grant.binding.folder, outcome: "\(event)")
            SecretsStore.shared.record(line)
        }
        changedNow()
    }

    /// A lock, a sleep or the session resigning: every grant ends, and pending cards are dropped.
    private func locked(_ event: SecretsStore.LockEvent) {
        switch event {
        case .screenLocked: end(.screenLocked)
        case .systemSleep: end(.systemSleep)
        case .sessionResigned: end(.sessionResigned)
        case .displaySleep: return
        }
        for card in queue where card.gone && !card.isAnswered { finish(card, outcome: .unanswered, decision: nil) }
    }

    private func expire(at now: ContinuousClock.Instant) {
        for grant in book.expire(at: now) { drop(grant.id) }
    }

    private func drop(_ grantID: String) {
        held[grantID] = nil // the values go with their SecretBytes, wiped
    }

    private func copies(_ values: [String: SecretBytes]) -> [String: SecretBytes] {
        values.mapValues { value in value.withUnsafeBytes { SecretBytes([UInt8]($0)) } }
    }

    /// The grants in force, for Settings › Secrets.
    var grants: [SecretGrant] {
        book.grants.filter { !$0.isExpired(at: now()) }
    }

    // MARK: Settings' Resume

    func resume(_ binding: SecretBinding) {
        limits.resume(binding)
        changedNow()
    }

    func resume(asker: String) {
        limits.resume(asker: asker)
        changedNow()
    }

    func resumeAsking() {
        limits.resumeAsking()
        changedNow()
    }

    /// When the hour pause ends, while it runs.
    var pausedUntil: Date? {
        guard let pause = limits.hourPause, now() < pause.until else { return nil }
        return pause.untilDate
    }

    /// The self-test's clean slate: every waiting request answered as declined (its panel closed), the limits and
    /// grants as at launch.
    func resetForSelfTest() {
        for request in queue where !request.isAnswered {
            request.isAnswered = true
            request.replies.removeAll()
            request.panel?.finish()
            request.panel = nil
        }
        queue.removeAll()
        limits = SecretLimits()
        book = SecretGrantBook()
        held.removeAll()
        now = { .now }
        changedNow()
    }

    // MARK: helpers

    private func changedNow() {
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    private func audit(_ event: SecretAudit.Event, _ request: Request?, approval: SecretAudit.Approval? = nil, outcome: String) {
        let line = SecretAudit.Line(event: event, names: request?.names ?? [], who: request.map(Self.who),
                                    command: request?.command, folder: request?.folder,
                                    approval: request?.isRemote == true ? .remote : approval, outcome: outcome)
        SecretsStore.shared.record(line)
    }

    /// The panel's Asked by facts in one line, for the audit log.
    static func who(_ request: Request) -> String {
        let facts = request.askedBy
        var parts: [String] = []
        if let agent = facts.agent { parts.append("\(agent) (going by its program's name)") }
        if facts.checkedNxtrm { parts.append("through Next Term's own nxtrm") }
        if let connection = facts.connection { parts.append("the remote connection “\(connection)”") }
        if let tab = facts.tab { parts.append(tab + (facts.project.map { " of \($0)" } ?? "")) }
        if facts.tab == nil, facts.connection == nil { parts.append("a program outside Next Term's tabs") }
        return parts.joined(separator: ", ")
    }

    /// A refusal's word, for the audit log and the wrapper's status.
    static func word(_ refusal: SecretLimits.Refusal) -> String {
        switch refusal {
        case .busy: return "busy"
        case .paused: return "paused"
        case .stopped: return "stopped"
        case .limited: return "limited"
        case .declining: return "declining"
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

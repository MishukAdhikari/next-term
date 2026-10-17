import AppKit
import NextTermCore

/// Every use of a stored key goes through here: one queue for tool calls, tickets and wrapper requests,
/// one panel at a time, the limits, and the grants with their own values.
///
/// - A request a grant answers starts with no panel, from the grant's own values. A remote request never makes or
///   uses a grant.
/// - A request the limits refuse gets its reason at once: the hour pause, a stopped asker, a declined request
///   paused for 10 minutes, a reached count.
/// - An identical request (the same binding as one waiting, or as a pending card) takes over that panel or card. It
///   does not count and does not queue. Otherwise up to 5 wait, and more get `busy`. "Allow once" there still starts one
///   command: the first caller still waiting uses it, and the others hear it was used already.
/// - Allow asks `SecretsStore` to use the keys, which asks for Touch ID or the password. "Allow for 15 minutes" and
///   "Allow this command until the Mac locks" keep copies of exactly those keys' values in a grant.
/// - Grants end on a lock, a sleep, the session resigning, Revoke, a key's change, the hour pause, and for
///   `run_with_secrets` when its asking tab gets input from MCP. They also end on their own: after 15 minutes, and a
///   one-use grant at its use or after 2 minutes, by a timer, with no request after them. Values are dropped with them.
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
        /// request_secret or store_secret saved the key.
        case saved(name: String, replaced: Bool)
        /// A ticket's tab did not start nxtrm within 30 seconds.
        case notStarted
        /// Nobody answered: the panel or window waited 30 minutes, the Mac locked, or a ticket's wrapper left.
        case unanswered
        /// "Allow once" starts one command, and an identical request that waited on the same panel used it.
        case usedAlready
        /// import_secrets' own answer, made by `SecretImportAsk` (names and counts from `SecretSources.answer(for:)`).
        case answered([String: Any])
    }

    /// What a request asks for: to use keys (the panel's Allow), to save the agent's value (store_secret's panel), or
    /// for the user to type a key in (request_secret's window).
    enum Kind {
        case use
        /// The agent's value, held while the panel waits, wiped when the request ends.
        case store(SecretBytes)
        case add(SecretRequestWindow.Content)
        /// import_secrets: Import from a File's sheet, or a password manager's, with the agent's banner.
        case importKeys(SecretImportAsk)
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
        var kind: Kind = .use
        let made: ContinuousClock.Instant
        /// A wrapper request whose wrapper stopped waiting: a pending card.
        fileprivate(set) var gone = false
        fileprivate var goneAt: ContinuousClock.Instant?
        /// Who waits for the answer: its own caller, and each identical request that took it over.
        fileprivate var replies: [Caller] = []
        fileprivate(set) var panel: SecretApprovalPanel?
        /// request_secret's window, in place of the panel.
        fileprivate(set) var requestWindow: SecretRequestWindow?
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
        #if DEBUG
        /// The self-test's: how many callers wait on it, its own and each that took it over.
        var callers: Int { replies.count }
        #endif
        var names: [String] { keys.map(\.name) }
        var isUse: Bool {
            if case .use = kind { return true }
            return false
        }
        var importAsk: SecretImportAsk? {
            if case .importKeys(let ask) = kind { return ask }
            return nil
        }
    }

    /// One caller waiting on a request: its reply, and whether it has left as of now, though its leaving may not have
    /// reached here yet (a wrapper's closed connection).
    fileprivate typealias Caller = (id: UUID, reply: (Decision) -> Void, left: () -> Bool)

    /// Where a caller's reply waits: the request that holds it (its own, or the one it took over) and the reply's id.
    /// A caller that leaves takes only its own reply away.
    struct Waiting {
        let request: Request
        let reply: UUID
    }

    /// Waiting requests, the one in the panel first.
    private(set) var queue: [Request] = []
    /// Panels kept on screen after their wrapper left during Touch ID, saying so, until the user closes them.
    private var lingering: [SecretApprovalPanel] = []
    private(set) var limits = SecretLimits()
    private(set) var book = SecretGrantBook()
    /// Each grant's own values, by its id.
    private var held: [String: [String: SecretBytes]] = [:]
    /// Each grant's timer for its own end, by its id, until it fires or the grant ends otherwise.
    private var endTimers: [String: DispatchSourceTimer] = [:]
    /// The clock: the self-test moves it.
    var now: () -> ContinuousClock.Instant = { .now }
    private var observers: [NSObjectProtocol] = []
    #if DEBUG
    /// The self-test's: a grant's timer fires after this many seconds instead of at its end.
    static var grantTimer: Double?
    /// The self-test's: the grants whose values are held.
    var heldGrants: [String] { Array(held.keys) }
    #endif

    private init() {
        observers.append(NotificationCenter.default.addObserver(forName: SecretsStore.locked, object: nil, queue: .main) { note in
            let event = note.userInfo?["event"] as? SecretsStore.LockEvent ?? .screenLocked
            MainActor.assumeIsolated { SecretRequests.shared.locked(event) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: SecretsStore.keysChanged, object: nil, queue: .main) { note in
            let names = note.userInfo?["names"] as? [String] ?? []
            MainActor.assumeIsolated { for name in names { SecretRequests.shared.end(.keyChanged(name)) } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: SecretsStore.startedOver, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SecretRequests.shared.vaultStartedOver() }
        })
    }

    // MARK: asking

    /// Answers `request` from a grant, refuses it, lets it take over an identical one, or queues it for the panel.
    /// Returns where its reply waits, or nil when it was answered at once. `left` tells whether its caller has gone, as
    /// of now, before its leaving reaches here.
    @discardableResult
    func ask(_ request: Request, left: @escaping () -> Bool = { false }, reply: @escaping (Decision) -> Void) -> Waiting? {
        // A key another copy of Next Term replaced, renamed or deleted ends the grants holding it (`keysChanged`) before
        // a grant can answer with its old value.
        SecretsStore.shared.reloadIfChanged()
        let now = now()
        expire(at: now)
        if request.isUse, !request.isRemote, let grant = book.take(request.binding, at: now), let values = held[grant.id] {
            limits.record(.answeredByGrant, asker: request.asker, binding: request.binding, at: now)
            expire(at: now) // a one-use grant is over now, and its values go now
            audit(.use, request, approval: .grant, outcome: "allowed")
            changedNow()
            reply(.allowed(copies(values), how: .grant))
            return nil
        }
        if let refusal = limits.admit(asker: request.asker, binding: request.binding, at: now) {
            limits.record(.refusedByLimits, asker: request.asker, binding: request.binding, at: now)
            audit(.refused, request, outcome: Self.word(refusal))
            reply(.refused(refusal))
            return nil
        }
        let id = UUID()
        if let waiting = queue.first(where: { $0.binding == request.binding && !$0.isAnswered }) {
            limits.record(.tookOver, asker: request.asker, binding: request.binding, at: now)
            waiting.replies.append((id, reply, left))
            if waiting.gone {
                waiting.gone = false
                waiting.goneAt = nil
                waiting.panel?.markBack()
            }
            changedNow()
            return Waiting(request: waiting, reply: id)
        }
        if SecretLimits.isBusy(waiting: queue.count) {
            reply(.refused(.busy))
            return nil
        }
        request.replies = [(id, reply, left)]
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
        return Waiting(request: request, reply: id)
    }

    /// A wrapper stopped waiting (after 25 seconds, or it left): its reply goes. When no other wrapper that took the
    /// request over still waits, the panel becomes a pending card. Nothing ends and nothing counts until the card is
    /// dropped.
    func wrapperLeft(_ waiting: Waiting) {
        let request = waiting.request
        guard !request.isAnswered, request.isWrapper else { return }
        request.replies.removeAll { $0.id == waiting.reply }
        guard request.replies.isEmpty else { return changedNow() }
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

    /// The wrapper of a ticket's request left before the user answered (its 10 minutes ran out, or its tab closed):
    /// its tool call hears it was not answered. The request ends unanswered once no other ticket's wrapper that took
    /// it over still waits.
    func callerLeft(_ waiting: Waiting) {
        let request = waiting.request
        guard !request.isAnswered, let index = request.replies.firstIndex(where: { $0.id == waiting.reply }) else { return }
        let left = request.replies.remove(at: index)
        left.reply(.unanswered)
        guard request.replies.isEmpty else { return changedNow() }
        finish(request, outcome: .unanswered, decision: nil)
    }

    /// Drops a pending card after 30 minutes, and a tool request whose panel waited 30 minutes with no answer.
    func dropIfStale(_ request: Request) {
        guard !request.isAnswered, queue.contains(where: { $0 === request }) else { return }
        let start = request.goneAt ?? request.made
        guard now() - start >= Self.dropAfter else { return }
        finish(request, outcome: .unanswered, decision: .unanswered)
    }

    /// The request in the panel or the request window now, if any.
    var showing: Request? { queue.first { $0.panel != nil || $0.requestWindow != nil || $0.importAsk?.isOnScreen == true } }

    private func showNext() {
        // An import waiting for its tab's pipe has had its turn.
        let next: Request? = queue.first { (request: Request) -> Bool in
            !request.isAnswered && request.importAsk?.wasOpened != true
        }
        guard showing == nil, let next else { return }
        if let ask = next.importAsk {
            return ask.open(ended: { [weak self, weak next] (end: SecretImportAsk.End) in
                guard let self, let next else { return }
                self.importEnded(next, end)
            }, leftScreen: { [weak self] in
                self?.showNext()
            })
        }
        if case .add(let content) = next.kind {
            let window = SecretRequestWindow(content, onSave: { [weak self, weak next] form in
                guard let self, let next else { return }
                self.save(next, form: form)
            }, onDecline: { [weak self, weak next] stop in
                guard let self, let next else { return }
                self.decline(next, stopAsking: stop)
            })
            next.requestWindow = window
            window.present()
            return
        }
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
            // store_secret for a new name: what it will be for, the agent's reason.
            let purpose = entry?.purpose ?? (request.isUse ? "" : StoredSecretName.purpose(fromReason: request.agentWords ?? ""))
            return SecretApprovalPanel.Content.KeyRow(name: key.name, envName: key.envName, purpose: purpose,
                                                      purposeByAgent: entry.map { $0.purposeBy == .agent } ?? !request.isUse,
                                                      writeOnly: entry?.writeOnly == true,
                                                      lastUsed: used.map { SecretApprovalPanel.lastUsedText($0) } ?? "Never used")
        }
        var content = SecretApprovalPanel.Content(
            title: SecretApprovalPanel.title(request), keys: keys, command: request.command,
            runsAsShell: !request.isWrapper && request.isUse, folder: request.folder, warnings: request.warnings,
            agentWords: request.agentWords, askedBy: request.askedBy, argv: request.argv, isWrapper: request.isWrapper,
            isRemote: request.isRemote, notice: request.notice, waiting: max(0, queue.count - 1))
        if !request.isUse {
            content.offersHowLong = false
            content.allowTitle = "Save"
        }
        return content
    }

    // MARK: answers

    private func allow(_ request: Request, how: How) {
        guard !request.isAnswered, let panel = request.panel else { return }
        if case .store(let value) = request.kind { return saveStored(request, value: value, panel: panel) }
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
        // "Allow once" goes to one caller. One that left in the moment before, its leaving not heard here yet, is let go
        // now as its leaving would have been: the use passes to the next caller, or a wrapper's one-use grant is made.
        if how == .once { letGo(callersLeftOf: request) }
        guard !request.isAnswered else { return }
        let now = now()
        var kind = how.grantKind
        // The wrapper left while the user was in the Touch ID sheet after "Allow once": a one-use grant for 2 minutes.
        let stoppedDuringApproval = request.isWrapper && request.gone && how == .once
        if stoppedDuringApproval { kind = .oneUse }
        if let kind, !request.isRemote {
            let grant = SecretGrant(kind: kind, binding: request.binding, made: now)
            book.add(grant)
            held[grant.id] = copies(values)
            audit(.grant, request, approval: how.approval, outcome: kind.rawValue)
            endWhenDue(grant)
        }
        if stoppedDuringApproval {
            request.isAnswered = true
            if let panel = request.panel {
                // It stays up with its line until the user closes it, while the queue goes on.
                panel.showStoppedDuringApproval()
                linger(panel)
            }
            request.panel = nil
            queue.removeAll { $0 === request }
            showNext()
            refreshWaitingLine()
            changedNow()
            return
        }
        finish(request, outcome: .allowed, decision: .allowed(values, how: how.approval))
    }

    /// store_secret's Save: the agent's value, under its name. A new name takes the agent's reason as what it's for;
    /// a stored one keeps its purpose and write-only flag, and its audit line names the earlier origin.
    private func saveStored(_ request: Request, value: SecretBytes, panel: SecretApprovalPanel) {
        guard let name = request.names.first else { return }
        let store = SecretsStore.shared
        let stored = store.index?.entry(named: name)
        let action: SecretsStore.Action
        if let stored {
            action = .replace(name: name, value: value, writeOnly: stored.writeOnly, origin: .agent)
        } else {
            let purpose = StoredSecretName.purpose(fromReason: request.agentWords ?? "")
            action = .add(name: name, purpose: purpose, purposeBy: .agent, origin: .agent, writeOnly: false, value: value,
                          remindDays: SecretReminderRecords.newKeyDays)
        }
        let reason = stored == nil ? SecretReason.save(name) : SecretReason.replaceWithAgentsKey(name)
        let facts = SecretsStore.Facts(who: Self.who(request))
        panel.setBusy(true)
        Task { @MainActor in
            do {
                try await store.perform(action, reason: reason, facts: facts)
                self.finish(request, outcome: .allowed, decision: .saved(name: name, replaced: stored != nil))
            } catch SecretsStore.Failure.cancelled {
                panel.setBusy(false)
                panel.notApproved()
            } catch {
                self.finish(request, outcome: .allowed, decision: .failed(error as? SecretsStore.Failure ?? .keyring))
            }
        }
    }

    /// request_secret's Save: the key the user typed. A stored name has its value replaced, and keeps what it's for and
    /// its page. A new key's page is the one the user gave in the window, never the agent.
    private func save(_ request: Request, form: SecretRequestWindow.Form) {
        guard !request.isAnswered, let window = request.requestWindow else { return }
        let store = SecretsStore.shared
        let stored = store.index?.entry(named: form.name)
        let action: SecretsStore.Action
        if stored != nil {
            action = .replace(name: form.name, value: form.value, writeOnly: form.writeOnly, origin: .request)
        } else {
            action = .add(name: form.name, purpose: form.purpose, purposeBy: form.purposeBy, origin: .request, writeOnly: form.writeOnly,
                          value: form.value, link: form.link, linkFrom: form.linkFrom, remindDays: SecretReminderRecords.newKeyDays)
        }
        let reason = stored == nil ? SecretReason.save(form.name) : SecretReason.replace(form.name)
        let pasted = window.pastedAt
        window.setBusy(true)
        Task { @MainActor in
            do {
                try await store.perform(action, reason: reason, facts: SecretsStore.Facts(who: Self.who(request)))
                let cleared = SecretClipboard.shared.clearAfterSave(pastedAt: pasted)
                window.showSaved(form.name, clearedClipboard: cleared)
                request.requestWindow = nil // it stays open, saying so, until the user closes it
                self.finish(request, outcome: .allowed, decision: .saved(name: form.name, replaced: stored != nil))
            } catch SecretsStore.Failure.cancelled {
                window.notApproved()
            } catch {
                window.notApproved((error as? LocalizedError)?.errorDescription ?? "Next Term couldn’t save the key.")
            }
        }
    }

    private func decline(_ request: Request, stopAsking: Bool) {
        guard !request.isAnswered else { return }
        if stopAsking { limits.stop(request.asker) }
        audit(.decline, request, outcome: stopAsking ? "declined and stopped asking" : "declined")
        finish(request, outcome: .declined, decision: .declined(stopAsking: stopAsking))
    }

    /// import_secrets' sheet ended: a decline counts and pauses as any other, and Decline and Stop Asking stops the
    /// asker; any other end answers as it is, with an audit line when nothing was copied in (a copy-in writes its own).
    private func importEnded(_ request: Request, _ end: SecretImportAsk.End) {
        guard !request.isAnswered else { return }
        if case .declined(let stopAsking) = end { return decline(request, stopAsking: stopAsking) }
        if let line = end.audit { audit(line.event, request, outcome: line.outcome) }
        finish(request, outcome: .allowed, decision: .answered(end.answer))
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
        if let decision { answer(replies, with: decision, for: request) }
        request.panel?.finish()
        request.panel = nil
        request.requestWindow?.finish()
        request.requestWindow = nil
        request.importAsk?.close()
        request.kind = .use // store_secret's value goes with its SecretBytes, wiped
        queue.removeAll { $0 === request }
        showNext()
        refreshWaitingLine()
        changedNow()
    }

    /// Answers each caller waiting on one request, in turn. An Allow is used as `SecretApprovalUse` says: "Allow once"
    /// by the first caller alone, here, before any command starts; each later caller hears it was used already.
    private func answer(_ replies: [Caller], with decision: Decision, for request: Request) {
        guard case .allowed(_, let how) = decision else {
            for waiting in replies { waiting.reply(decision) }
            return
        }
        var use = SecretApprovalUse(how)
        for waiting in replies {
            if use.take() {
                waiting.reply(decision)
            } else {
                audit(.refused, request, approval: how, outcome: "its Allow once was used by an identical request")
                waiting.reply(.usedAlready)
            }
        }
    }

    /// Callers gone though their leaving has not reached here yet, let go as `wrapperLeft` and `callerLeft` do.
    private func letGo(callersLeftOf request: Request) {
        for caller in request.replies where caller.left() {
            let gone = Waiting(request: request, reply: caller.id)
            if request.isWrapper { wrapperLeft(gone) } else { callerLeft(gone) }
        }
    }

    /// Keeps an ended request's panel until its window closes.
    private func linger(_ panel: SecretApprovalPanel) {
        lingering.append(panel)
        panel.onClosed = { [weak self, weak panel] in
            // After the close: the panel is not let go inside its own delegate call.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.lingering.removeAll { $0 === panel || $0.window?.isVisible != true } }
            }
        }
    }

    // MARK: tickets

    /// `run_with_secrets`' ticket: what the tool call asked, held until the wrapper in its tab redeems it. It
    /// holds no value and is used once. Its 30 seconds start when its line is typed.
    final class Ticket {
        let id = SecretRun.newTicket()
        let asker: String
        let keys: [Key]
        /// The command text, run with `/bin/sh -c`.
        let command: String
        let folder: String
        /// "new", or the tab's id given as `tab_id`.
        let target: String
        let tabID: UUID
        let askedBy: AskedBy
        let agentWords: String?
        let program: String
        let isRemote: Bool
        let notice: String?
        fileprivate(set) var typedAt: ContinuousClock.Instant?
        fileprivate(set) var used = false
        /// The tool call's side: told the decision once, or `.notStarted`.
        fileprivate var decided: ((Decision) -> Void)?

        init(asker: String, keys: [Key], command: String, folder: String, target: String, tabID: UUID, askedBy: AskedBy,
             agentWords: String?, program: String, isRemote: Bool, notice: String?, decided: @escaping (Decision) -> Void) {
            self.asker = asker
            self.keys = keys
            self.command = command
            self.folder = folder
            self.target = target
            self.tabID = tabID
            self.askedBy = askedBy
            self.agentWords = agentWords
            self.program = program
            self.isRemote = isRemote
            self.notice = notice
            self.decided = decided
        }

        var argv: [String] { ["/bin/sh", "-c", command] }
        var map: [String: String] { Dictionary(keys.map { ($0.name, $0.envName) }, uniquingKeysWith: { first, _ in first }) }
        var names: [String] { keys.map(\.name) }

        /// The grant binding: the asker and its program, the keys and ENVNAMEs, the command, the folder, the target, the
        /// tab's warned variables and the folder's `.env`.
        func binding(warned: [String: String] = [:], envDigest: String) -> SecretBinding {
            SecretBinding(source: .tool, asker: asker, program: program, command: [command], keys: map, folder: folder, target: target,
                          warned: warned, envDigest: envDigest)
        }
    }

    /// Tickets not yet redeemed, by id.
    private(set) var tickets: [String: Ticket] = [:]
    /// How long a typed ticket line has to start nxtrm.
    static var ticketWindow: Duration = .seconds(30)

    /// The limits for a tool call before anything opens: the hour pause, a stopped asker, the same request declined
    /// within 10 minutes (whatever its tab warned about), a reached count, a full queue. Nil to go on.
    func precheck(asker: String, binding: SecretBinding, names: [String], command: String?, folder: String?) -> SecretLimits.Refusal? {
        let now = now()
        let refusal = limits.admitBeforeTab(asker: asker, binding: binding, at: now)
            ?? (SecretLimits.isBusy(waiting: queue.count) ? .busy : nil)
        guard let refusal else { return nil }
        limits.record(.refusedByLimits, asker: asker, binding: binding, at: now)
        SecretsStore.shared.record(SecretAudit.Line(event: .refused, names: names, command: command, folder: folder,
                                                    outcome: Self.word(refusal)))
        return refusal
    }

    func add(_ ticket: Ticket) {
        tickets[ticket.id] = ticket
    }

    /// Its line was typed: it has 30 seconds to be redeemed, or it ends unanswered.
    func typed(_ ticket: Ticket) {
        ticket.typedAt = now()
        let window = Self.ticketWindow
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seconds(window)) { [weak ticket] in
            MainActor.assumeIsolated {
                guard let ticket else { return }
                SecretRequests.shared.ticketNotStarted(ticket)
            }
        }
    }

    /// A ticket whose line was never typed (its tab could not take it): dropped, counting nothing.
    func drop(_ ticket: Ticket) {
        tickets[ticket.id] = nil
        ticket.decided = nil
    }

    private func ticketNotStarted(_ ticket: Ticket) {
        guard !ticket.used, tickets[ticket.id] === ticket else { return }
        tickets[ticket.id] = nil
        let binding = ticket.binding(envDigest: SecretRun.envFileDigest(directory: ticket.folder))
        limits.record(.unanswered, asker: ticket.asker, binding: binding, at: now())
        SecretsStore.shared.record(SecretAudit.Line(event: .refused, names: ticket.names, command: ticket.command, folder: ticket.folder,
                                                    outcome: "its tab did not start nxtrm within 30 seconds"))
        let decided = ticket.decided
        ticket.decided = nil
        decided?(.notStarted)
        changedNow()
    }

    /// A ticket's wrapper redeems it, from the tab Next Term typed its line in, within 30 seconds of the typing, once.
    /// The request is built from the ticket's facts, the wrapper's warned variables and the folder's `.env`, so the
    /// panel shows the tab's real environment before Allow, and a grant checks it too. Returns where its reply waits,
    /// for the socket to notice the wrapper leaving.
    @discardableResult
    func redeem(ticket id: String, peerTab: TerminalTab?, request: SecretRun.Request, left: @escaping () -> Bool = { false },
                reply: @escaping (SecretRun.Answer) -> Void) -> Waiting? {
        let now = now()
        guard let ticket = tickets[id], !ticket.used, let typedAt = ticket.typedAt, now - typedAt <= Self.ticketWindow else {
            reply(SecretRun.Answer(status: .expired, names: request.names))
            return nil
        }
        guard peerTab?.id == ticket.tabID else {
            // Another tab has the id: refused, and the ticket waits for its own tab.
            SecretsStore.shared.record(SecretAudit.Line(event: .refused, names: ticket.names, command: ticket.command,
                                                        folder: ticket.folder, outcome: "a ticket redeemed from another tab"))
            reply(SecretRun.Answer(status: .refused, names: ticket.names))
            return nil
        }
        ticket.used = true
        tickets[id] = nil
        var warnings = request.warn.keys.sorted().map(SecretRun.warningText)
        warnings += SecretRun.warnings(command: ticket.command)
        warnings += SecretRun.envFileWarnings(directory: ticket.folder)
        let binding = ticket.binding(warned: request.warn, envDigest: SecretRun.envFileDigest(directory: ticket.folder))
        let asking = Request(binding: binding, keys: ticket.keys, command: ticket.command, argv: ticket.argv, folder: ticket.folder,
                             warnings: warnings, agentWords: ticket.agentWords, askedBy: ticket.askedBy, program: ticket.program,
                             isRemote: ticket.isRemote)
        asking.notice = ticket.notice
        // The wrapper sent no names: its answer is built from the ticket's.
        var asked = request
        asked.names = ticket.names
        asked.map = ticket.map
        let argv = ticket.argv
        let folder = ticket.folder
        let decided = ticket.decided
        ticket.decided = nil
        return ask(asking, left: left) { decision in
            reply(SecretSocket.answer(for: decision, request: asked, argv: argv, directory: folder))
            decided?(decision)
        }
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
        for grant in ended { over(grant, outcome: "\(event)") }
        changedNow()
    }

    /// A grant is over: its values go, wiped, and the audit log says why.
    private func over(_ grant: SecretGrant, outcome: String) {
        drop(grant.id)
        endTimers.removeValue(forKey: grant.id)?.cancel()
        let line = SecretAudit.Line(event: .grantEnd, names: grant.names, command: grant.binding.command.joined(separator: " "),
                                    folder: grant.binding.folder, outcome: outcome)
        SecretsStore.shared.record(line)
    }

    /// A lock, a sleep or the session resigning: every grant ends, and pending cards are dropped.
    private func locked(_ event: SecretsStore.LockEvent) {
        switch event {
        case .screenLocked: end(.screenLocked)
        case .systemSleep: end(.systemSleep)
        case .sessionResigned: end(.sessionResigned)
        case .displaySleep: return
        }
        for card in queue where card.gone && !card.isAnswered { finish(card, outcome: .unanswered, decision: .unanswered) }
        // A one-use approval ended with the lock: its panel's line is over too.
        for panel in lingering { panel.finish() }
        lingering.removeAll()
    }

    /// Start Over: every grant holds values of the vault that is gone, so each ends, and a key added again under the
    /// same name asks again. A one-use approval's panel kept up says nothing true any more.
    private func vaultStartedOver() {
        end(.startedOver)
        for panel in lingering { panel.finish() }
        lingering.removeAll()
    }

    /// Ends the grants over at `now`: their time is up, or a one-use grant was used.
    @discardableResult
    private func expire(at now: ContinuousClock.Instant) -> [SecretGrant] {
        let ended = book.expire(at: now)
        for grant in ended { over(grant, outcome: grant.usesLeft == 0 ? "used" : "expired") }
        return ended
    }

    /// A grant with an end of its own ends right then, with no request after it, so its values never outlive it.
    private func endWhenDue(_ grant: SecretGrant) {
        guard let left = grant.timeLeft(at: now()) else { return }
        // Half a second after, so the clock has surely passed its end when the timer fires.
        #if DEBUG
        let delay = Self.grantTimer ?? Self.seconds(left) + 0.5
        #else
        let delay = Self.seconds(left) + 0.5
        #endif
        // A strict timer with a quarter second's leeway: a plain one may fire up to a tenth of its wait late (a minute
        // for 15 minutes), and later under App Nap, with the values still held.
        let id = grant.id
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(250))
        timer.setEventHandler {
            MainActor.assumeIsolated { SecretRequests.shared.endTimerFired(id) }
        }
        endTimers.removeValue(forKey: id)?.cancel()
        endTimers[id] = timer
        timer.resume()
    }

    private func endTimerFired(_ id: String) {
        endTimers.removeValue(forKey: id)?.cancel()
        guard !expire(at: now()).isEmpty else { return }
        changedNow()
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
            request.requestWindow?.finish()
            request.requestWindow = nil
            request.importAsk?.close()
            request.kind = .use
        }
        queue.removeAll()
        for panel in lingering { panel.finish() }
        lingering.removeAll()
        tickets.removeAll()
        limits = SecretLimits()
        book = SecretGrantBook()
        held.removeAll()
        for timer in endTimers.values { timer.cancel() }
        endTimers.removeAll()
        now = { .now }
        #if DEBUG
        Self.grantTimer = nil
        #endif
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

    /// "4:02 PM", for the notes a refusal gives.
    static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    /// "3 Oct", for when a key was added.
    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

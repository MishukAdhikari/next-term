import AppKit
import Darwin
import NextTermCore

/// The app's side of an agent session (plan 030, slice 3), on the MCP socket as `secret_run` is: a request from
/// `nxtrm agent` answered on its own connection, never an MCP tool. Only Next Term's own binary running `--cli agent`
/// is heard, and the tab it runs in is found by its process tree, so no other program can report for a tab or answer
/// for it.
///
/// - `report`: the session's state after each change: working, attention, done, the last turn's stop reason and the
///   agent's last message, which read_tab, wait_for_tab and list_tabs give exactly (`reports`); and the CLI's version, the
///   model and the session's id (plan 035 U7). The tab's saved state keeps the id, so an update brings the session back;
///   the app keeps the last version each agent ran, and answers with the one before when this session's differs.
/// - `confirm_always`: an Allow always picked in the session's menu, by the user's keys or an agent's answer_agent
///   (the tab can't tell them apart), is asked of the user on the Mac first (R16). The session answers the agent only
///   once this says approved.
/// - `trust_folder`: a Claude Code session asks before it starts in a folder (plan 035 R8), since `claude -p` runs a
///   folder's hooks and MCP servers with no dialog of its own. A folder already in the app's list is trusted at once;
///   another is asked on the Mac, by click only, in the window `confirm_always` uses, and the app records a yes itself
///   (AgentSessionTrust), so nothing typed into the tab can answer it or grant it.
enum AgentSessionSocket {
    static let tool = "agent_session"

    struct Report: Equatable {
        var agent: String
        /// working, attention, done or idle.
        var state: String
        var stopReason: String?
        /// The agent's last message of the current or last turn, whole (masked when it leaves).
        var lastMessage: String
        /// Turns ended so far: wait_for_tab tells a new end from the last one by it.
        var turns: Int
        /// The agent's id in the catalog (claude, codex, gemini…).
        var agentID: String? = nil
        /// The CLI's version and the model, when the session knows them.
        var version: String? = nil
        var model: String? = nil
        /// The session's id (Claude Code's session, Codex's thread) and the folder it runs in: what a restore resumes.
        var sessionID: String? = nil
        var folder: String? = nil
        /// The session went on with a conversation it was given (`--resume`): it holds turns from before its own.
        var resumed = false
        /// What this report offers the agent's terminal view for (plan 036 R13): one of the four known values only.
        var terminalOffer: ViewSwitch.TerminalOffer? = nil
    }

    /// Each session tab's last report, by tab id. Main thread.
    nonisolated(unsafe) static var reports: [UUID: Report] = [:]

    /// The longest last message kept.
    static let messageLimit = 64 * 1024

    /// Whether the process at a connection is `nxtrm agent`, by its whole argv as the kernel has it.
    static func isSession(pid: pid_t?) -> Bool {
        guard let pid, let full = ProcessInspector.fullCommandLine(of: pid) else { return false }
        return isSession(full.arguments)
    }

    static func isSession(_ arguments: [String]) -> Bool {
        arguments.count >= 4 && (arguments[0] as NSString).lastPathComponent == "NextTerm" && arguments[1] == "--cli" && arguments[2] == "agent"
    }

    /// Serves one request on the serve thread; the server closes `fd` when this returns.
    static func handle(fd: Int32, arguments: [String: Any], peer: pid_t?, auditToken token: audit_token_t?) {
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard let token, let pid = peer, PeerCode.pid(token) == pid, PeerCode.current.isThisProgram(auditToken: token),
              isSession(pid: pid) else {
            return answer(fd, ["error": "the program at the socket is not Next Term's own nxtrm agent"])
        }
        if PeerCode.usesPathFallback, !PeerCode.isSameProcess(socket: fd, as: token) {
            return answer(fd, ["error": "the process changed while it asked"])
        }
        let done = DispatchSemaphore(value: 0)
        var reply: [String: Any] = ["error": "no tab"]
        let gate = AnswerGate()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tab = ClaudeIDEServer.tab(for: pid, among: MCPControl.allTabs) else {
                    reply = ["error": "the session runs in no Next Term tab"]
                    done.signal()
                    return
                }
                switch arguments["op"] as? String {
                case "report":
                    reply = ["ok": true]
                    if let previous = record(arguments, for: tab) { reply["previous_version"] = previous }
                    done.signal()
                case "confirm_always":
                    confirm(arguments, tab: tab, gate: gate) { approved in
                        reply = ["approved": approved]
                        done.signal()
                    }
                case "trust_folder":
                    trust(arguments, tab: tab, gate: gate) { trusted in
                        reply = ["trusted": trusted]
                        done.signal()
                    }
                default:
                    reply = ["error": "unknown op"]
                    done.signal()
                }
            }
        }
        // The user may take their time on the Mac; the session's menu waits, as the agent does, until 15 minutes pass or
        // the session hangs up. Then the window closes and a later click does nothing: what the session was told stands.
        let deadline = Date().addingTimeInterval(15 * 60)
        while done.wait(timeout: .now() + 1) == .timedOut {
            guard Date() >= deadline || peerHungUp(fd) else { continue }
            if gate.expire() {
                DispatchQueue.main.async { MainActor.assumeIsolated { gate.closeWindow() } }
                return answer(fd, ["approved": false, "trusted": false])
            }
            // Clicked just now: its answer is on the way.
            done.wait()
            break
        }
        answer(fd, reply)
    }

    /// Whether the session at `fd` has closed its end (it quit, or its tab closed) while the app waited to answer.
    private static func peerHungUp(_ fd: Int32) -> Bool {
        var probe = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&probe, 1, 0) > 0 else { return false }
        if probe.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }

    /// One request's answer, given once: by the user's click on the Mac, or by the wait running out (or the session
    /// hanging up), whichever comes first. A click after the wait ran out does nothing, and a trust is never written for a
    /// session that was already told no.
    final class AnswerGate: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false
        /// The window asking, on the main thread.
        @MainActor weak var window: AgentApprovalWindow?

        /// The click's turn: true when it is the answer, false when the wait ran out first.
        func claim() -> Bool { settle() }

        /// The wait's turn: true when nothing was clicked yet, so the session is told no.
        func expire() -> Bool { settle() }

        private func settle() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !settled else { return false }
            settled = true
            return true
        }

        /// The window closes unanswered: its decline finds the gate settled and does nothing more.
        @MainActor func closeWindow() {
            window?.close()
        }
    }

    /// The report kept for the tab; the version this agent ran before, when this one differs.
    @MainActor
    @discardableResult
    private static func record(_ arguments: [String: Any], for tab: TerminalTab) -> String? {
        var message = arguments["last_message"] as? String ?? ""
        if message.utf8.count > messageLimit { message = String(message.prefix(messageLimit)) }
        var report = Report(agent: ACPSession.oneLine(arguments["agent"] as? String ?? "", limit: 60),
                            state: arguments["state"] as? String ?? "idle",
                            stopReason: arguments["stop_reason"] as? String,
                            lastMessage: message, turns: arguments["turns"] as? Int ?? 0)
        let agentID = (arguments["agent_id"] as? String).flatMap { ACPAgent.named($0)?.id }
        report.agentID = agentID
        report.version = (arguments["agent_version"] as? String).map { ACPSession.oneLine($0, limit: 64) }.flatMap { $0.isEmpty ? nil : $0 }
        report.model = (arguments["model"] as? String).map { ACPSession.oneLine($0, limit: 120) }.flatMap { $0.isEmpty ? nil : $0 }
        report.sessionID = (arguments["session_id"] as? String).flatMap { AgentSessionVersion.isSessionID($0) ? $0 : nil }
        report.folder = (arguments["folder"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
        report.resumed = arguments["resumed"] as? Bool ?? false
        report.terminalOffer = (arguments["terminal_offer"] as? String).flatMap { ViewSwitch.TerminalOffer(raw: $0) }
        reports[tab.id] = report
        // The bar over the tab offers the terminal view in one click (plan 036 U5).
        if let offer = report.terminalOffer, let agent = ViewSwitch.Agent(sessionAgentID: agentID) {
            ViewSwitchOfferBar.show(offer, agent: agent, in: tab)
        }
        guard let agentID, let version = report.version else { return nil }
        let stored = versionStore.dictionary(forKey: versionsKey) as? [String: String] ?? [:]
        let seen = AgentSessionVersion.remember(version, for: agentID, in: stored)
        if seen.stored != stored { versionStore.set(seen.stored, forKey: versionsKey) }
        return seen.previous
    }

    /// The last version each agent's sessions ran, by agent id, in the app's own defaults.
    nonisolated(unsafe) static var versionStore = UserDefaults.standard
    static let versionsKey = "AgentSessionVersions"

    /// The agent session a tab runs, for its saved state (plan 035 U7): Claude Code's or Codex's, with the id its session
    /// reported. Nil for any other tab.
    @MainActor
    static func record(of tab: TerminalTab) -> SessionSnapshot.AgentSessionRecord? {
        guard tab.status.running, tab.status.program == CommandClassifier.agentSessionProgram, let report = reports[tab.id],
              let agentID = report.agentID, let id = report.sessionID, ACPAgent.named(agentID)?.resumesSessions == true else { return nil }
        return SessionSnapshot.AgentSessionRecord(agent: agentID, sessionID: id, folder: report.folder)
    }

    @MainActor
    private static func confirm(_ arguments: [String: Any], tab: TerminalTab, gate: AnswerGate, then: @escaping (Bool) -> Void) {
        let agent = ACPSession.oneLine(arguments["agent"] as? String ?? "The agent", limit: 60)
        let action = ACPSession.oneLine(arguments["action"] as? String ?? "act", limit: 2000) // the whole command (R5)
        let option = ACPSession.oneLine(arguments["option"] as? String ?? "Allow always", limit: 60)
        let details = "\(agent) asks to \(action). \u{201C}\(option)\u{201D} lets it do this again in this session without asking. "
            + "It was picked in the session\u{2019}s tab, by you or by an agent that steers it."
        let request = AgentApprovalWindow.Request(title: "Allow \(agent) always?", requester: "The session in “\(tab.title)”",
                                                  agentWords: nil, details: details, approveTitle: option)
        ask(request, gate: gate, then: then)
    }

    /// The approval windows open now. A window doesn't keep its controller (`NSWindow.windowController` is weak), and
    /// nothing else here does: without this the controller went as soon as it was shown, its buttons answered nothing
    /// and the session's menu waited on the Mac for good.
    @MainActor private static var asking: [AgentApprovalWindow] = []

    /// Shows `request` on the Mac and answers `then` once, Approve (true) or Decline or a close (false), keeping the
    /// window until then. Once `gate` has expired (the wait ran out, or the session hung up), a click only closes the
    /// window: `approved` never runs and `then` isn't called.
    @MainActor
    private static func ask(_ request: AgentApprovalWindow.Request, gate: AnswerGate, approved: (() -> Void)? = nil,
                            then: @escaping (Bool) -> Void) {
        // Let go once its own close is done: Decline answers before the window closes.
        func letGo(_ window: AgentApprovalWindow?) {
            DispatchQueue.main.async { MainActor.assumeIsolated { asking.removeAll { $0 === window } } }
        }
        weak var shown: AgentApprovalWindow?
        let window = AgentApprovalWindow(request,
                                         approve: { window in
                                             window.finish()
                                             letGo(window)
                                             guard gate.claim() else { return }
                                             approved?()
                                             then(true)
                                         },
                                         decline: { _ in
                                             letGo(shown)
                                             guard gate.claim() else { return }
                                             then(false)
                                         })
        shown = window
        gate.window = window
        asking.append(window)
        window.present()
    }

    /// The folders Claude Code sessions may start in, in the app's own defaults: only the app writes them.
    nonisolated(unsafe) static var trustStore = UserDefaults.standard

    @MainActor
    private static func trust(_ arguments: [String: Any], tab: TerminalTab, gate: AnswerGate, then: @escaping (Bool) -> Void) {
        guard let given = arguments["folder"] as? String, given.hasPrefix("/") else { return then(false) }
        let folder = AgentSessionTrust.canonical(given)
        guard !AgentSessionTrust.isTrusted(folder, in: AgentSessionTrust.list(in: trustStore)) else { return then(true) }
        let agent = ACPSession.oneLine(arguments["agent"] as? String ?? "Claude Code", limit: 60)
        let details = AgentSessionTrust.question(folder: folder) + " Its CLAUDE.md and plugins load too. "
            + "Only this folder is trusted, not the folders in it; the session in the tab starts once you trust it."
        let request = AgentApprovalWindow.Request(title: "Trust this folder for \(agent)?",
                                                  requester: "The session in \u{201C}\(tab.title)\u{201D}",
                                                  agentWords: nil, details: details, approveTitle: "Trust Folder")
        ask(request, gate: gate, approved: {
            let list = AgentSessionTrust.list(in: trustStore)
            trustStore.set(AgentSessionTrust.adding(folder, to: list), forKey: AgentSessionTrust.defaultsKey)
        }, then: then)
    }

    private static func answer(_ fd: Int32, _ fields: [String: Any]) {
        let text = (try? JSONSerialization.data(withJSONObject: fields)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let data = MCPServer.encodeAnswer(MCPServer.CallResult(text: text, isError: fields["error"] != nil))
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    /// What read_tab, wait_for_tab and list_tabs add for a session tab: its agent, the last turn's stop reason and the
    /// agent's last message (masked).
    @MainActor
    static func fields(_ tab: TerminalTab) -> [String: Any] {
        guard let report = reports[tab.id], tab.status.running, tab.status.program == CommandClassifier.agentSessionProgram else { return [:] }
        var info = summary(report)
        if let reason = report.stopReason { info["stop_reason"] = reason }
        if !report.lastMessage.isEmpty { info["last_message"] = SecretMask.current.mask(report.lastMessage) }
        return info
    }

    /// What list_tabs adds for a session tab: its agent, and the CLI's version and the model when known (plan 035 U7).
    @MainActor
    static func listFields(_ tab: TerminalTab) -> [String: Any] {
        guard let report = reports[tab.id], tab.status.program == CommandClassifier.agentSessionProgram else { return [:] }
        return summary(report)
    }

    private static func summary(_ report: Report) -> [String: Any] {
        var info: [String: Any] = ["agent_session": report.agent]
        if let version = report.version { info["agent_version"] = version }
        if let model = report.model { info["model"] = model }
        return info
    }
}

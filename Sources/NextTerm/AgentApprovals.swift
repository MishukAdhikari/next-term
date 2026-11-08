import AppKit
import NextTermCore

/// The questions an agent session asks on the Mac (plan 037 KTD2), one copy for both kinds of session: an Allow always
/// picked in the session (R16 of plan 030) and the folder trust before Claude Code starts (plan 035 R8). `nxtrm agent`
/// reaches them through `AgentSessionSocket`, a chat tab calls them directly. Both are answered by a click in
/// `AgentApprovalWindow` only: nothing typed into a tab, no MCP tool and no notification button answers them.
enum AgentApprovals {
    /// One request's answer, given once: by the user's click on the Mac, or by the wait running out (the session hung up,
    /// or its tab closed), whichever comes first. A click after that does nothing, and a trust is never written for a
    /// session that was already told no.
    final class Gate: @unchecked Sendable {
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

    /// An Allow always for `agent`'s `action`, asked on the Mac: `then(true)` only when the user approves. `requester`
    /// names where it was picked ("The session in “zsh”", "The chat in “Claude Code”").
    @MainActor
    static func confirmAlways(agent: String, action: String, option: String, requester: String, gate: Gate,
                              then: @escaping (Bool) -> Void) {
        let agent = ACPSession.oneLine(agent, limit: 60)
        let action = ACPSession.oneLine(action, limit: 2000) // the whole command (R5)
        let option = ACPSession.oneLine(option, limit: 60)
        let details = "\(agent) asks to \(action). \u{201C}\(option)\u{201D} lets it do this again in this session without asking. "
            + "It was picked in the session\u{2019}s tab, by you or by an agent that steers it."
        let request = AgentApprovalWindow.Request(title: "Allow \(agent) always?", requester: requester,
                                                  agentWords: nil, details: details, approveTitle: option)
        ask(request, gate: gate, then: then)
    }

    /// Claude Code's folder trust: `then(true)` at once for a folder in the app's list, else once the user trusts it on
    /// the Mac, which the app records itself (AgentSessionTrust). `folder` must be absolute.
    @MainActor
    static func trustFolder(agent: String, folder given: String, requester: String, gate: Gate, then: @escaping (Bool) -> Void) {
        guard given.hasPrefix("/") else { return then(false) }
        let folder = AgentSessionTrust.canonical(given)
        let store = AgentSessionSocket.trustStore
        guard !AgentSessionTrust.isTrusted(folder, in: AgentSessionTrust.list(in: store)) else { return then(true) }
        let agent = ACPSession.oneLine(agent, limit: 60)
        let details = AgentSessionTrust.question(folder: folder) + " Its CLAUDE.md and plugins load too. "
            + "Only this folder is trusted, not the folders in it; the session in the tab starts once you trust it."
        let request = AgentApprovalWindow.Request(title: "Trust this folder for \(agent)?", requester: requester,
                                                  agentWords: nil, details: details, approveTitle: "Trust Folder")
        ask(request, gate: gate, approved: {
            let list = AgentSessionTrust.list(in: store)
            store.set(AgentSessionTrust.adding(folder, to: list), forKey: AgentSessionTrust.defaultsKey)
        }, then: then)
    }

    /// The approval windows open now. A window doesn't keep its controller (`NSWindow.windowController` is weak), and
    /// nothing else here does: without this the controller went as soon as it was shown, its buttons answered nothing
    /// and the session's menu waited on the Mac for good.
    @MainActor private static var asking: [AgentApprovalWindow] = []

    /// Shows `request` on the Mac and answers `then` once, Approve (true) or Decline or a close (false), keeping the
    /// window until then. Once `gate` has expired (the wait ran out, or the session hung up), a click only closes the
    /// window: `approved` never runs and `then` isn't called.
    @MainActor
    private static func ask(_ request: AgentApprovalWindow.Request, gate: Gate, approved: (() -> Void)? = nil,
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
}

/// The session reports the app keeps by tab (`AgentSessionSocket.reports`), from `nxtrm agent` over the socket and from
/// a chat tab's host directly, through one parser, so read_tab, wait_for_tab, list_tabs, the marks and the saved state
/// read both kinds alike.
enum AgentSessionReports {
    /// The report kept for the tab; the version this agent ran before, when this one differs.
    @MainActor
    @discardableResult
    static func record(_ arguments: [String: Any], for tab: TerminalTab) -> String? {
        typealias Socket = AgentSessionSocket
        var message = arguments["last_message"] as? String ?? ""
        if message.utf8.count > Socket.messageLimit { message = String(message.prefix(Socket.messageLimit)) }
        var report = Socket.Report(agent: ACPSession.oneLine(arguments["agent"] as? String ?? "", limit: 60),
                                   state: arguments["state"] as? String ?? "idle",
                                   stopReason: arguments["stop_reason"] as? String,
                                   lastMessage: message, turns: arguments["turns"] as? Int ?? 0)
        let agentID = (arguments["agent_id"] as? String).flatMap { ACPAgent.named($0)?.id }
        report.agentID = agentID
        report.version = (arguments["agent_version"] as? String).map { ACPSession.oneLine($0, limit: 64) }.flatMap { $0.isEmpty ? nil : $0 }
        report.model = (arguments["model"] as? String).map { ACPSession.oneLine($0, limit: 120) }.flatMap { $0.isEmpty ? nil : $0 }
        report.sessionID = (arguments["session_id"] as? String).flatMap { AgentSessionVersion.isSessionID($0) ? $0 : nil }
        report.folder = (arguments["folder"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
        Socket.reports[tab.id] = report
        guard let agentID, let version = report.version else { return nil }
        let stored = Socket.versionStore.dictionary(forKey: Socket.versionsKey) as? [String: String] ?? [:]
        let seen = AgentSessionVersion.remember(version, for: agentID, in: stored)
        if seen.stored != stored { Socket.versionStore.set(seen.stored, forKey: Socket.versionsKey) }
        return seen.previous
    }
}

import AppKit
import Darwin
import NextTermCore

/// The app's side of an agent session (plan 030, slice 3), on the MCP socket as `secret_run` is: a request from
/// `nxtrm agent` answered on its own connection, never an MCP tool. Only Next Term's own binary running `--cli agent`
/// is heard, and the tab it runs in is found by its process tree, so no other program can report for a tab or answer
/// for it.
///
/// - `report`: the session's state after each change: working, attention, done, the last turn's stop reason and the
///   agent's last message, which read_tab, wait_for_tab and list_tabs give exactly (`reports`).
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
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tab = ClaudeIDEServer.tab(for: pid, among: MCPControl.allTabs) else {
                    reply = ["error": "the session runs in no Next Term tab"]
                    done.signal()
                    return
                }
                switch arguments["op"] as? String {
                case "report":
                    record(arguments, for: tab)
                    reply = ["ok": true]
                    done.signal()
                case "confirm_always":
                    confirm(arguments, tab: tab) { approved in
                        reply = ["approved": approved]
                        done.signal()
                    }
                case "trust_folder":
                    trust(arguments, tab: tab) { trusted in
                        reply = ["trusted": trusted]
                        done.signal()
                    }
                default:
                    reply = ["error": "unknown op"]
                    done.signal()
                }
            }
        }
        // The user may take their time on the Mac; the session's menu waits, as the agent does.
        if done.wait(timeout: .now() + 15 * 60) == .timedOut { reply = ["approved": false] }
        answer(fd, reply)
    }

    @MainActor
    private static func record(_ arguments: [String: Any], for tab: TerminalTab) {
        var message = arguments["last_message"] as? String ?? ""
        if message.utf8.count > messageLimit { message = String(message.prefix(messageLimit)) }
        let report = Report(agent: ACPSession.oneLine(arguments["agent"] as? String ?? "", limit: 60),
                            state: arguments["state"] as? String ?? "idle",
                            stopReason: arguments["stop_reason"] as? String,
                            lastMessage: message, turns: arguments["turns"] as? Int ?? 0)
        reports[tab.id] = report
    }

    @MainActor
    private static func confirm(_ arguments: [String: Any], tab: TerminalTab, then: @escaping (Bool) -> Void) {
        let agent = ACPSession.oneLine(arguments["agent"] as? String ?? "The agent", limit: 60)
        let action = ACPSession.oneLine(arguments["action"] as? String ?? "act", limit: 200)
        let option = ACPSession.oneLine(arguments["option"] as? String ?? "Allow always", limit: 60)
        let details = "\(agent) asks to \(action). \u{201C}\(option)\u{201D} lets it do this again in this session without asking. "
            + "It was picked in the session\u{2019}s tab, by you or by an agent that steers it."
        let window = AgentApprovalWindow(.init(title: "Allow \(agent) always?", requester: "The session in “\(tab.title)”",
                                               agentWords: nil, details: details, approveTitle: option),
                                         approve: { window in
                                             window.finish()
                                             then(true)
                                         },
                                         decline: { _ in then(false) })
        window.present()
    }

    /// The folders Claude Code sessions may start in, in the app's own defaults: only the app writes them.
    nonisolated(unsafe) static var trustStore = UserDefaults.standard

    @MainActor
    private static func trust(_ arguments: [String: Any], tab: TerminalTab, then: @escaping (Bool) -> Void) {
        guard let given = arguments["folder"] as? String, given.hasPrefix("/") else { return then(false) }
        let folder = AgentSessionTrust.canonical(given)
        guard !AgentSessionTrust.isTrusted(folder, in: AgentSessionTrust.list(in: trustStore)) else { return then(true) }
        let agent = ACPSession.oneLine(arguments["agent"] as? String ?? "Claude Code", limit: 60)
        let details = AgentSessionTrust.question(folder: folder) + " Its CLAUDE.md and plugins load too. "
            + "Only this folder is trusted, not the folders in it; the session in the tab starts once you trust it."
        let request = AgentApprovalWindow.Request(title: "Trust this folder for \(agent)?",
                                                  requester: "The session in \u{201C}\(tab.title)\u{201D}",
                                                  agentWords: nil, details: details, approveTitle: "Trust Folder")
        let window = AgentApprovalWindow(request,
                                         approve: { window in
                                             window.finish()
                                             let list = AgentSessionTrust.list(in: trustStore)
                                             trustStore.set(AgentSessionTrust.adding(folder, to: list), forKey: AgentSessionTrust.defaultsKey)
                                             then(true)
                                         },
                                         decline: { _ in then(false) })
        window.present()
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
        var info: [String: Any] = ["agent_session": report.agent]
        if let reason = report.stopReason { info["stop_reason"] = reason }
        if !report.lastMessage.isEmpty { info["last_message"] = SecretMask.current.mask(report.lastMessage) }
        return info
    }
}

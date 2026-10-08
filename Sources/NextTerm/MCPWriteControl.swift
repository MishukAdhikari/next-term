import AppKit
import NextTermCore

/// The MCP tools that change things (MCPServer.controlTools): file edits, staging and commits, panes, the
/// layout and a few settings. Each change waits for its approval first (MCPApproval):
/// - `.askOnMac`, always for local agents: an AgentApprovalWindow shows what would change and who asks,
///   with Approve, Decline, and Decline and Stop Asking. Decline, closing the window, or no answer within
///   `answerWithin` seconds changes nothing, and the agent is told which. One change waits at a time.
/// - `.preApprovedByGrant(id)`: from the remote door, for a connection whose “Ask on this Mac before
///   changes” is off. The change runs at once and its answer names the grant.
/// After the approval each tool checks again that what the user saw still holds (the file as it was read,
/// the index and branch unchanged, the tab still there) and refuses if not.
///
/// The remote door calls `MCPControl.call(tool, arguments, caller: nil, approval: policy, requester:
/// "the connection “name”", connection: grantID, reply:)` on the main thread. `pending?.window` is the
/// window asking now, for its own checks that a tool asks before it changes anything.
@MainActor
enum MCPWriteControl {
    typealias Reply = MCPControl.Reply

    /// How long a change waits for the user's answer before it is refused (some clients give up on a tool
    /// after 60 seconds; the remote door allows 100).
    static var answerWithin: TimeInterval = 50

    /// What a tool knows about its call. Made on the main thread and read only there; work done off it
    /// carries it back.
    struct Context: @unchecked Sendable {
        let caller: TerminalTab?
        let approval: MCPApproval
        /// The agent's reason, shown as its own words.
        let reason: String?
        /// Who Decline and Stop Asking stops: the tab, the remote connection, or every caller outside the tabs.
        let asker: String
        /// Who asks, as the approval window names it.
        let who: String
        /// The open projects, with the caller's window's first.
        let projects: MCPProjects
        /// Whether the remote door asks (`requester` was given).
        let isRemote: Bool
    }

    static func call(_ tool: String, _ arguments: [String: Any], caller: TerminalTab?, approval: MCPApproval, requester: String?,
                     connection: String? = nil, reply: @escaping Reply) {
        let preferred = caller.flatMap(MCPControl.controller(of:))?.project
        let projects = MCPProjects(open: AppDelegate.shared.controllers.compactMap { $0.project }, preferred: preferred)
        let asker = Self.asker(connection: connection, requester: requester, caller: caller)
        let context = Context(caller: caller, approval: approval, reason: arguments["reason"] as? String, asker: asker,
                              who: requester ?? SkillsMCP.describe(caller), projects: projects, isRemote: requester != nil)
        switch tool {
        case "propose_edit": proposeEdit(arguments, context, reply: reply)
        case "write_file": writeFile(arguments, context, creating: false, reply: reply)
        case "create_file": writeFile(arguments, context, creating: true, reply: reply)
        case "stage", "commit": git(tool, arguments, context, reply: reply)
        case "focus_tab": focusTab(arguments, context, reply: reply)
        case "split_pane": splitPane(arguments, context, reply: reply)
        case "close_pane": closePane(arguments, context, reply: reply)
        case "zoom_pane": zoomPane(arguments, context, reply: reply)
        case "set_layout": setLayout(arguments, context, reply: reply)
        case "settings_get": reply(MCPControl.ok(settingsList()))
        case "settings_set": setSettings(arguments, context, reply: reply)
        default: reply(MCPControl.fail("Unknown tool \(tool)"))
        }
    }

    /// Who Decline and Stop Asking stops (here and in SkillsMCP): a remote connection by its grant id
    /// (by its name when the door gives no id), a tab, or every other caller outside the tabs.
    static func asker(connection: String?, requester: String?, caller: TerminalTab?) -> String {
        if let connection { return "remote:" + connection }
        if let requester { return "remote-name:" + requester }
        return caller.map { $0.id.uuidString } ?? "outside"
    }

    // MARK: approval

    /// A change waiting for the user.
    final class Asking {
        let asker: String
        var window: AgentApprovalWindow?
        var answered = false
        var timedOut = false

        init(asker: String) { self.asker = asker }
    }

    /// The change the user is asked about now.
    private(set) static var pending: Asking?
    /// Askers who chose Decline and Stop Asking: refused without a window until Next Term quits.
    static var stopped = Set<String>()

    /// What the user is asked: a title such as “An agent asks to change a file”, and what would change.
    struct Ask {
        let title: String
        let details: String
    }

    /// Runs `change` once the change is approved: at once under a grant, after Approve on the Mac
    /// otherwise. `change` gets how it was approved (for its answer) and the window, which it closes with
    /// `finish()`, or holds with `setCommitted(true)` while it runs. A decline, a closed window or no
    /// answer is answered here, and `change` never runs.
    static func approve(_ ask: Ask, _ context: Context, reply: @escaping Reply,
                        change: @escaping (_ approved: String, _ window: AgentApprovalWindow?) -> Void) {
        if case .preApprovedByGrant(let grant) = context.approval { return change("by grant \(grant)", nil) }
        if stopped.contains(context.asker) {
            return reply(MCPControl.fail("The user chose Decline and Stop Asking for your requests, until Next Term quits; nothing changed. Ask the user directly."))
        }
        if pending != nil {
            return reply(MCPControl.fail("Another change is waiting for the user's answer on the Mac; nothing changed. Try again once it is answered."))
        }
        let asking = Asking(asker: context.asker)
        pending = asking
        let request = AgentApprovalWindow.Request(title: ask.title, requester: context.who, agentWords: context.reason, details: ask.details,
                                                  approveTitle: "Approve", stopTitle: "Decline and Stop Asking")
        let window = AgentApprovalWindow(request, approve: { window in
            guard !asking.answered else { return }
            asking.answered = true
            if pending === asking { pending = nil }
            change("on this Mac", window)
        }, decline: { stop in
            guard !asking.answered else { return }
            asking.answered = true
            if pending === asking { pending = nil }
            if stop { stopped.insert(asking.asker) }
            let seconds = Int(answerWithin)
            reply(MCPControl.fail(asking.timedOut ? "No answer on the Mac within \(seconds) seconds, so nothing changed." : "Declined on the Mac; nothing changed."))
        })
        asking.window = window
        window.present()
        DispatchQueue.main.asyncAfter(deadline: .now() + answerWithin) {
            MainActor.assumeIsolated {
                guard !asking.answered else { return }
                asking.timedOut = true
                window.close() // a close is a decline
            }
        }
    }

    // MARK: tabs

    static func findTab(_ id: Any?) -> TerminalTab? {
        guard let id = (id as? String)?.lowercased() else { return nil }
        return AppDelegate.shared.controllers.flatMap(\.tabs).first { $0.id.uuidString.lowercased() == id }
    }

    /// The tab a pane tool acts on, its window, and its panes; refused when the tab's input line is not the
    /// user's own.
    static func paneTarget(_ arguments: [String: Any]) -> Result<(TerminalTab, TerminalWindowController, PaneGroup), MCPToolError> {
        guard let tab = findTab(arguments["tab_id"]), let controller = MCPControl.controller(of: tab), let group = controller.group(of: tab) else {
            return .failure(MCPToolError("No tab with that id; list_tabs shows them."))
        }
        if let why = MCPInputLine.refusal(tab) { return .failure(MCPToolError(why)) }
        return .success((tab, controller, group))
    }

    /// “the window of api”, for the approval window.
    static func place(_ controller: TerminalWindowController) -> String {
        controller.project.map { "the window of \(($0 as NSString).lastPathComponent)" } ?? "its window"
    }
}

/// Whether a tab's input line is the user's own. Tools that act on a tab refuse one whose line is not:
/// typing there would join, run or lose text that someone else put on it. MCPControl's send_to_tab,
/// press_keys and answer_agent ask it, and so do focus_tab, split_pane, close_pane and zoom_pane.
///
/// Features that put text on a tab's line add a rule here; update-resume's put-back line is not the
/// user's own until they type in that tab. A rule says why, in a sentence for the agent, or nil.
enum MCPInputLine {
    static var rules: [(TerminalTab) -> String?] = []

    static func refusal(_ tab: TerminalTab) -> String? {
        for rule in rules {
            if let why = rule(tab) { return why }
        }
        return nil
    }
}

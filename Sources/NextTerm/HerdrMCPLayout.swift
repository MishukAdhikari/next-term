import AppKit
import NextTermCore

/// Plan 040 U5–U9 over MCP, by herdr's own commands: a pane zoomed (`pane zoom`) or herdr's focus moved to its neighbour
/// (`pane focus`); herdr's tabs and workspaces as ids the tab tools take (`<tab id>/tab:w1:t1`, `<tab id>/ws:w1`), shown,
/// focused, renamed and closed; list_tabs with herdr_layout giving herdr's whole session from one read (`api snapshot`),
/// with what its integrations report; a new workspace or git worktree for start_agent; a worktree removed. Every change
/// to herdr asks on the Mac first.
extension HerdrMCP {
    private static func failed(_ text: String) -> MCPServer.CallResult { MCPControl.fail(text) }
    private static func done(_ value: Any) -> MCPServer.CallResult { MCPControl.ok(value) }

    /// The tools on a herdr tab's or workspace's id, and on a pane's for zoom_pane and focus_tab with a direction. Returns
    /// false for anything else.
    static func routeLayout(_ tool: String, _ target: HerdrTarget, _ arguments: [String: Any], caller: TerminalTab?,
                            herdrCaller: [String: String], reply: @escaping Reply) -> Bool {
        if let container = target.containerKind {
            MainActor.assumeIsolated {
                containerTool(tool, target, container, arguments, caller: caller, herdrCaller: herdrCaller, reply: reply)
            }
            return true
        }
        switch tool {
        case "zoom_pane":
            let on: Bool = arguments["zoomed"] as? Bool ?? true
            MainActor.assumeIsolated {
                askThenRun(.zoom(pane: target.pane, on: on), target, arguments, caller: caller,
                           title: "An agent asks to zoom a herdr pane",
                           what: on ? "Pane \(target.pane) fills its herdr tab; the others keep running behind it." : "Every pane of \(target.pane)'s herdr tab shows again.",
                           reply: reply)
            }
            return true
        case "focus_tab" where arguments["direction"] != nil:
            guard let side = (arguments["direction"] as? String).flatMap(HerdrCommand.Neighbor.init(rawValue:)) else {
                reply(failed("direction is left, right, up or down."))
                return true
            }
            MainActor.assumeIsolated {
                askThenRun(.focusNeighbor(pane: target.pane, direction: side), target, arguments, caller: caller,
                           title: "An agent asks to move herdr's focus",
                           what: "herdr's focus goes to the pane \(side.rawValue) of \(target.pane).", reply: reply)
            }
            return true
        default:
            return false
        }
    }

    /// Asked on the Mac, then herdr runs `command`; the answer is herdr's own.
    @MainActor private static func askThenRun(_ command: HerdrCommand, _ target: HerdrTarget, _ arguments: [String: Any], caller: TerminalTab?,
                                              title: String, what: String, reply: @escaping Reply) {
        if target.machine != nil { return reply(failed("That is on one of herdr's own machines: Next Term changes only the herdr server's own. Nothing changed.")) }
        let ref: HerdrAgentRef
        switch pane(target) {
        case .failure(let error): return reply(failed(error.text))
        case .success(let found): ref = found
        }
        if let refusal = command.refusal(session: nil) { return reply(failed(refusal)) }
        let shown: String = command.argv(executable: "herdr", session: nil, text: nil)?.first?.first?.map { ShellQuote.quote($0) }
            .joined(separator: " ") ?? "herdr"
        let ask = MCPWriteControl.Ask(title: title, details: "\(what) Next Term runs: \(shown)")
        let context = MCPWriteControl.context(arguments, caller: caller, approval: .askOnMac, requester: nil, connection: nil)
        MCPWriteControl.approve(ask, context, reply: reply) { approved, window in
            window?.finish()
            ref.run(command) { result in
                if let problem = problem(result, pane: target.pane, sent: false) { return reply(failed(problem)) }
                reply(done(["id": target.id, "done": true, "approved": approved]))
            }
        }
    }

    // MARK: herdr's tabs and workspaces (U6)

    @MainActor private static func containerTool(_ tool: String, _ target: HerdrTarget, _ container: (kind: HerdrTarget.Container, id: String),
                                                 _ arguments: [String: Any], caller: TerminalTab?, herdrCaller: [String: String],
                                                 reply: @escaping Reply) {
        if target.machine != nil { return reply(failed("herdr's machines' tabs and workspaces are not reached from Next Term.")) }
        let paneTarget = HerdrTarget(tabID: target.tabID, pane: "w1:p1")
        let ref: HerdrAgentRef
        switch pane(paneTarget) {
        case .failure(let error): return reply(failed(error.text))
        case .success(let found): ref = HerdrAgentRef(tab: found.tab, pane: container.id)
        }
        if container.kind == .session { return sessionTool(tool, target, container.id, ref.tab, arguments, caller: caller, reply: reply) }
        let tab: Bool = container.kind == .tab
        let noun: String = tab ? "herdr tab" : "herdr workspace"
        switch tool {
        case "show_tab":
            MCPControl.controller(of: ref.tab)?.show(ref.tab)
            reply(done(["id": target.id, "shown": true]))
        case "focus_tab":
            askThenRunContainer(tab ? .focusTab(tab: container.id) : .focusWorkspace(workspace: container.id), ref, target, arguments,
                                caller: caller, title: "An agent asks to move herdr's view", what: "herdr shows \(noun) \(container.id).", reply: reply)
        case "rename_tab":
            guard isOpener(target.id, caller: caller) else {
                return reply(failed("rename_tab renames only the \(noun)s you made (start_agent); the user renames the others from the herdr Agent menu."))
            }
            let label: String = (arguments["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let command: HerdrCommand = tab ? .renameTab(tab: container.id, label: label) : .renameWorkspace(workspace: container.id, label: label)
            if let refusal = command.refusal(session: nil) { return reply(failed(refusal)) }
            ref.run(command) { result in
                if let problem = problem(result, pane: container.id, sent: false) { return reply(failed(problem)) }
                reply(done(["id": target.id, "label": label, "renamed": true]))
            }
        case "close_tab":
            closeContainer(ref, target, container, arguments, caller: caller, herdrCaller: herdrCaller, reply: reply)
        default:
            reply(failed("\(tool) takes a tab's or a herdr pane's id, not a \(noun)'s."))
        }
    }

    @MainActor private static func askThenRunContainer(_ command: HerdrCommand, _ ref: HerdrAgentRef, _ target: HerdrTarget,
                                                       _ arguments: [String: Any], caller: TerminalTab?, title: String, what: String,
                                                       reply: @escaping Reply) {
        let run: HerdrCommand = command
        if let refusal = run.refusal(session: nil) { return reply(failed(refusal)) }
        let shown: String = run.argv(executable: "herdr", session: nil, text: nil)?.first?.first?.map { ShellQuote.quote($0) }
            .joined(separator: " ") ?? "herdr"
        let ask = MCPWriteControl.Ask(title: title, details: "\(what) Next Term runs: \(shown)")
        let context = MCPWriteControl.context(arguments, caller: caller, approval: .askOnMac, requester: nil, connection: nil)
        MCPWriteControl.approve(ask, context, reply: reply) { approved, window in
            window?.finish()
            ref.run(run) { result in
                if let problem = problem(result, pane: ref.pane, sent: false) { return reply(failed(problem)) }
                reply(done(["id": target.id, "done": true, "approved": approved]))
            }
        }
    }

    /// close_tab on a herdr tab or workspace: asked first, from a fresh snapshot, naming what closes; never the session's
    /// last panes, nor one that holds the caller's own pane. With remove_worktree on a linked worktree's workspace, herdr
    /// removes the worktree and its checkout (`worktree remove`, never --force), refused while it has uncommitted work.
    @MainActor private static func closeContainer(_ ref: HerdrAgentRef, _ target: HerdrTarget, _ container: (kind: HerdrTarget.Container, id: String),
                                                  _ arguments: [String: Any], caller: TerminalTab?, herdrCaller: [String: String],
                                                  reply: @escaping Reply) {
        ref.run(.snapshot) { read in
            MainActor.assumeIsolated {
                guard case .json(let json) = read, let snapshot = HerdrSnapshot.parse(json) else {
                    return reply(failed((problem(read, pane: "", sent: false) ?? "herdr gave no snapshot of its session.") + " Nothing was closed."))
                }
                let panes: [HerdrSnapshot.Pane]
                let name: String
                var checkout: String?
                switch container.kind {
                case .tab:
                    guard let found = snapshot.tab(container.id) else { return reply(failed("herdr no longer has tab \(container.id). Nothing was closed.")) }
                    panes = found.tab.panes
                    name = "herdr tab \(container.id)" + (found.tab.label.map { " (“\(SecretApprovalPanel.sanitized($0, limit: 40))”)" } ?? "")
                case .workspace:
                    guard let found = snapshot.workspace(container.id) else { return reply(failed("herdr no longer has workspace \(container.id). Nothing was closed.")) }
                    panes = found.tabs.flatMap(\.panes)
                    name = "herdr workspace \(container.id)" + (found.label.map { " (“\(SecretApprovalPanel.sanitized($0, limit: 40))”)" } ?? "")
                    if found.linkedWorktree { checkout = found.checkout }
                case .session:
                    return reply(failed("A herdr session is stopped by its own id. Nothing was closed."))
                }
                if panes.count >= snapshot.paneCount { return reply(failed("That is everything in the herdr session: Next Term never closes its last panes. Nothing was closed.")) }
                if panes.contains(where: { isCaller($0.id, in: ref.tab, caller: herdrCaller) }) {
                    return reply(failed("That holds your own herdr pane. Nothing was closed."))
                }
                let removing: Bool = arguments["remove_worktree"] as? Bool ?? false
                if removing, checkout == nil { return reply(failed("remove_worktree is for a linked worktree's workspace; that one is not. Nothing was closed.")) }
                if removing, let checkout, let dirty = uncommitted(checkout, in: ref.tab) {
                    return reply(failed("The worktree at \(checkout) has uncommitted work (\(dirty)); commit or remove it there first. Nothing was removed."))
                }
                let command: HerdrCommand = removing ? .removeWorktree(workspace: container.id)
                    : container.kind == .tab ? .closeTab(tab: container.id) : .closeWorkspace(workspace: container.id)
                let what: String = removing
                    ? "herdr closes \(name), removes its git worktree and deletes the checkout at \(checkout ?? "")."
                    : "herdr closes \(name) and its \(panes.count) pane\(panes.count == 1 ? "" : "s"); what runs there stops."
                askThenRunContainer(command, ref, target, arguments, caller: caller,
                                    title: removing ? "An agent asks to remove a herdr worktree" : "An agent asks to close a \(container.kind == .tab ? "herdr tab" : "herdr workspace")",
                                    what: what, reply: reply)
            }
        }
    }

    /// Uncommitted work in a checkout on this Mac, in a few words; nil when clean, or when it is on a server (herdr's own
    /// remove refuses a dirty worktree there).
    @MainActor private static func uncommitted(_ checkout: String, in tab: TerminalTab) -> String? {
        guard tab.remote == nil, let git = GitRunner.locateGit() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", checkout, "status", "--porcelain"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines: Int = String(decoding: data, as: UTF8.self).split(separator: "\n").count
        return lines == 0 ? nil : "\(lines) changed file\(lines == 1 ? "" : "s")"
    }

    /// close_tab on `<tab id>/session:<name>` (U10): herdr stops that session (`session stop`), and with delete: true deletes a
    /// stopped one's files (`session delete`), once the user approves on the Mac. Never a session a tab here shows: the user
    /// closes or detaches that tab first.
    @MainActor private static func sessionTool(_ tool: String, _ target: HerdrTarget, _ name: String, _ tab: TerminalTab,
                                               _ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        guard tool == "close_tab" else { return reply(failed("A herdr session's id goes to close_tab (it stops the session); host_sessions lists them.")) }
        guard HerdrTarget.isSession(name) else { return reply(failed("“\(name)” is not a herdr session name.")) }
        let deleting: Bool = arguments["delete"] as? Bool ?? false
        HerdrRunner.run(.sessions, for: tab) { listed in
            MainActor.assumeIsolated {
                guard case .json(let json) = listed, let sessions = HerdrSession.parse(json) else {
                    return reply(failed((problem(listed, pane: "", sent: false) ?? "herdr did not list its sessions there.") + " Nothing was stopped."))
                }
                guard let session = sessions.first(where: { $0.name == name }) else { return reply(failed("herdr there has no session “\(name)”.")) }
                let defaultName: String? = sessions.first(where: \.isDefault)?.name
                let shownHere: Bool = AppDelegate.shared.controllers.flatMap { $0.tabs }.contains { (other: TerminalTab) -> Bool in
                    guard other.followsHerdr else { return false }
                    if let remote = other.remote {
                        guard let mine = tab.remote, remote.host.id == mine.host.id else { return false }
                        return (remote.herdrSession ?? defaultName) == name
                    }
                    return tab.remote == nil && (other.localHerdr?.session ?? defaultName) == name
                }
                if shownHere { return reply(failed("A tab here shows herdr session “\(name)”: close that tab first. Nothing was stopped.")) }
                if deleting, session.running { return reply(failed("“\(name)” is still running: stop it first (close_tab without delete).")) }
                if !deleting, !session.running { return reply(failed("“\(name)” is not running; delete: true deletes its files.")) }
                let command: HerdrCommand = deleting ? .deleteSession(name: name) : .stopSession(name: name)
                let place: String = tab.remote.map { "on \($0.host.name)" } ?? "on this Mac"
                let what: String = deleting ? "herdr deletes the stopped session “\(name)” \(place), with its saved layout."
                    : "herdr stops the session “\(name)” \(place): every pane in it and what runs there stops."
                let ask = MCPWriteControl.Ask(title: deleting ? "An agent asks to delete a herdr session" : "An agent asks to stop a herdr session",
                                              details: "\(what) Next Term runs: herdr \(deleting ? "session delete" : "session stop") \(name)")
                let context = MCPWriteControl.context(arguments, caller: caller, approval: .askOnMac, requester: nil, connection: nil)
                MCPWriteControl.approve(ask, context, reply: reply) { approved, window in
                    window?.finish()
                    HerdrRunner.run(command, for: tab) { result in
                        if let problem = problem(result, pane: "", sent: false) { return reply(failed(problem)) }
                        reply(done(["id": target.id, deleting ? "deleted" : "stopped": true, "approved": approved]))
                    }
                }
            }
        }
    }

    @MainActor static func isOpener(_ id: String, caller: TerminalTab?) -> Bool { openerOf(id) == (caller?.id.uuidString ?? "outside") }

    /// What one list_tabs with herdr_layout gathers while herdr answers.
    private final class Gathering {
        var listing: [String: Any]
        var windows: [[String: Any]]
        var left: Int

        init(listing: [String: Any], windows: [[String: Any]], left: Int) {
            self.listing = listing
            self.windows = windows
            self.left = left
        }
    }

    // MARK: list_tabs with herdr_layout (U6, U8, U9)

    /// list_tabs, then each tab that follows herdr given `herdr_workspaces`: its whole session from one `api snapshot`
    /// each, workspaces > tabs > panes, with their places, zoom and what integrations report. A herdr without the
    /// snapshot says so in `herdr_layout_note`.
    static func listWithLayout(_ base: MCPServer.CallResult, reply: @escaping Reply) {
        guard !base.isError, let listing = (try? JSONSerialization.jsonObject(with: Data(base.text.utf8))) as? [String: Any],
              let windows = listing["windows"] as? [[String: Any]] else { return reply(base) }
        var pending: [(window: Int, tab: Int, ref: TerminalTab)] = []
        for (w, window) in windows.enumerated() {
            for (t, entry) in ((window["tabs"] as? [[String: Any]]) ?? []).enumerated() {
                guard let id = entry["id"] as? String, let tab = MCPControl.tab(withID: id), tab.followsHerdr else { continue }
                pending.append((w, t, tab))
            }
        }
        guard !pending.isEmpty else { return reply(base) }
        let gathering = Gathering(listing: listing, windows: windows, left: pending.count)
        for item in pending {
            HerdrRunner.run(.snapshot, for: item.ref) { result in
                var tabs: [[String: Any]] = gathering.windows[item.window]["tabs"] as? [[String: Any]] ?? []
                if case .json(let json) = result, let snapshot = HerdrSnapshot.parse(json) {
                    tabs[item.tab]["herdr_workspaces"] = snapshot.listing(tabID: item.ref.id.uuidString)
                } else {
                    tabs[item.tab]["herdr_layout_note"] = problem(result, pane: "", sent: false) ?? "herdr there gives no snapshot (api snapshot)."
                }
                gathering.windows[item.window]["tabs"] = tabs
                gathering.left -= 1
                guard gathering.left == 0 else { return }
                gathering.listing["windows"] = gathering.windows
                let data = (try? JSONSerialization.data(withJSONObject: gathering.listing, options: [.sortedKeys])) ?? Data()
                reply(MCPServer.CallResult(text: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

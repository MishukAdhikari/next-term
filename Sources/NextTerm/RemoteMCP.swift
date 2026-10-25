import AppKit
import NextTermCore

/// The MCP tools for servers (Connect VPS): saved hosts, tabs on them, what they keep running, and what
/// changed there. On the main thread, like the rest of MCPControl. Every command that runs on a host is
/// one of RemoteShell's fixed scripts; arguments only ever reach it quoted (see Remote.swift).
enum RemoteMCP {
    typealias Reply = MCPControl.Reply

    private static func fail(_ text: String) -> MCPServer.CallResult { MCPControl.fail(text) }
    private static func ok(_ value: Any) -> MCPServer.CallResult { MCPControl.ok(value) }

    static func call(_ tool: String, _ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        switch tool {
        case "list_hosts": reply(ok(["hosts": RemoteHosts.all.map(describe)]))
        case "add_host": reply(addHost(arguments))
        case "remove_host": reply(removeHost(arguments))
        case "check_host": checkHost(arguments, reply: reply)
        case "new_remote_tab": newRemoteTab(arguments, caller: caller, reply: reply)
        case "host_sessions": hostSessions(arguments, reply: reply)
        case "host_changes": hostChanges(arguments, reply: reply)
        default: reply(fail("Unknown tool \(tool)"))
        }
    }

    private static func describe(_ host: RemoteHost) -> [String: Any] {
        var info: [String: Any] = ["id": host.id, "name": host.name, "destination": host.destination,
                                   "directory": host.directory, "keep": host.keep.rawValue]
        if let port = host.port { info["port"] = port }
        return info
    }

    private static func host(_ arguments: [String: Any]) -> Result<RemoteHost, MCPControl.MCPError> {
        guard let reference = arguments["host"] as? String, !reference.isEmpty else { return .failure(.init("Give a host's id or name (list_hosts).")) }
        guard let host = RemoteHosts.find(reference) else { return .failure(.init("No host “\(reference)”; list_hosts shows them, add_host saves one.")) }
        return .success(host)
    }

    private static func keep(_ value: Any?) -> Result<KeepMode?, MCPControl.MCPError> {
        guard let text = value as? String else { return .success(nil) }
        guard let mode = KeepMode(rawValue: text) else { return .failure(.init("keep is off, tmux or herdr.")) }
        return .success(mode)
    }

    // MARK: hosts

    private static func addHost(_ arguments: [String: Any]) -> MCPServer.CallResult {
        let name = (arguments["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let destination = (arguments["destination"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let existing = RemoteHosts.all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        var host = existing ?? RemoteHost(name: name, destination: destination)
        let port = arguments["port"] as? Int
        // A saved host keeps where it points: tabs saved for it, and the user, trust that. Re-pointing it
        // is remove_host and a fresh add_host (a new id, which saved tabs do not follow).
        if let existing, existing.destination != destination || (arguments["port"] != nil && existing.port != port) {
            return fail("“\(existing.name)” points to \(existing.destination)\(existing.port.map { " port \($0)" } ?? ""). To point it elsewhere, remove_host it and add_host it again.")
        }
        host.name = name
        host.destination = destination
        if let port { host.port = port }
        if let directory = arguments["directory"] as? String { host.directory = directory.trimmingCharacters(in: .whitespaces) }
        switch keep(arguments["keep"]) {
        case .failure(let error): return fail(error.text)
        case .success(let mode): if let mode { host.keep = mode }
        }
        if let problem = host.problem { return fail(problem) }
        RemoteHosts.save(host)
        return ok(["host": describe(host), "saved": true])
    }

    private static func removeHost(_ arguments: [String: Any]) -> MCPServer.CallResult {
        switch host(arguments) {
        case .failure(let error): return fail(error.text)
        case .success(let host):
            RemoteHosts.remove(id: host.id)
            let open = AppDelegate.shared.controllers.flatMap(\.tabs).filter { $0.remote?.host.id == host.id && !$0.exited }.count
            var info: [String: Any] = ["id": host.id, "removed": true]
            if open > 0 {
                info["note"] = "\(open) tab\(open == 1 ? "" : "s") on it stay open until closed, and will not be reopened at the next launch. Sessions kept there (tmux, herdr) keep running."
            }
            return ok(info)
        }
    }

    private static func unreachable(_ host: RemoteHost, _ output: RemoteConnection.Output) -> MCPServer.CallResult {
        fail("Could not run a check on \(host.name): \(output.problem)")
    }

    private static func checkHost(_ arguments: [String: Any], reply: @escaping Reply) {
        let found: RemoteHost
        switch host(arguments) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let host): found = host
        }
        RemoteConnection.run(found, script: RemoteShell.probeScript, timeout: 25) { output in
            guard let probe = RemoteProbe.parse(output.output) else { return reply(unreachable(found, output)) }
            var info: [String: Any] = ["host": describe(found), "os": probe.os, "shell": probe.shell, "home": probe.home,
                                       "agents": probe.agents, "tmux_usable": probe.tmuxUsable,
                                       "sessions": probe.sessions.map(describe)]
            info["tmux"] = probe.tmux ?? NSNull()
            info["herdr"] = probe.herdr ?? NSNull()
            if let path = probe.herdrPath { info["herdr_path"] = path }
            if let how = RemoteProbe.foundHow(probe.herdrHow) { info["herdr_found"] = how }
            if let summary = probe.herdrSummary { info["herdr_summary"] = summary }
            info["git"] = probe.git ?? NSNull()
            if let linger = probe.linger { info["linger"] = linger }
            var notes: [String] = []
            if found.keep == .tmux && probe.tmux == nil {
                notes.append("keep is tmux but tmux is not on this host: tabs open a plain shell that nothing keeps. The user can install tmux, or use keep herdr or off.")
            } else if found.keep == .tmux && !probe.tmuxUsable {
                notes.append("tmux on this host is older than 3.2: tabs use it, but Next Term is tested with 3.2 and later.")
            }
            if found.keep == .herdr && probe.herdr == nil {
                let looked = probe.herdrSummary ?? "herdr is not on this host"
                notes.append("keep is herdr, but \(looked). Next Term never installs it; the user can install it from \(RemoteShell.herdrInstallPage).")
            }
            if probe.linger == "no" {
                notes.append("systemd linger is off for this user: on hosts that end a user's processes at logout (KillUserProcesses), kept sessions can stop when the last connection closes. The user can run `sudo loginctl enable-linger $USER` on the host.")
            }
            if !notes.isEmpty { info["notes"] = notes }
            reply(ok(info))
        }
    }

    private static func describe(_ session: RemoteSession) -> [String: Any] {
        ["name": session.name, "attached_clients": session.attached, "directory": session.directory, "program": session.program]
    }

    // MARK: tabs

    private static func newRemoteTab(_ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        let found: RemoteHost
        switch host(arguments) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let host): found = host
        }
        var mode = found.keep
        switch keep(arguments["keep"]) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let chosen): if let chosen { mode = chosen }
        }
        let directory = (arguments["directory"] as? String)?.trimmingCharacters(in: .whitespaces) ?? found.directory
        if let problem = RemoteHost.directoryProblem(directory) { return reply(fail(problem)) }
        let command = (arguments["command"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if command.contains("\n") { return reply(fail("The command must be one line.")) }
        if !command.isEmpty && mode == .herdr {
            return reply(fail("A herdr tab shows herdr itself, not a shell: give herdr's agents work with send_to_tab on their ids from list_tabs, or open the tab with keep tmux or off to run a command."))
        }
        let named = arguments["session"] as? String
        if !command.isEmpty && named != nil {
            return reply(fail("Give either session (attach to what runs there) or command (a new session), not both."))
        }
        if named != nil && mode == .off {
            return reply(fail("session is one of Next Term's tmux sessions (keep tmux) or one of herdr's sessions (keep herdr), from host_sessions."))
        }
        // A herdr session only as herdr lists it, never made by its name: asked on the open connection.
        if mode == .herdr, let named {
            return herdrSession(named, on: found) { result in
                switch result {
                case .failure(let error): reply(fail(error.text))
                case .success(let session):
                    open(found, directory: directory, mode: mode, session: nil, herdrSession: session, command: "",
                         arguments: arguments, caller: caller, reply: reply)
                }
            }
        }
        open(found, directory: directory, mode: mode, session: named.map(RemoteShell.safeName), herdrSession: nil, command: command,
             arguments: arguments, caller: caller, reply: reply)
    }

    /// The herdr session `name` names on `host`, as `herdr session list --json` lists it there: nil for herdr's default.
    /// Refused while no tab on the host is connected (checks never log in), and for a name herdr does not list.
    private static func herdrSession(_ name: String, on host: RemoteHost, _ done: @escaping (Result<String?, MCPControl.MCPError>) -> Void) {
        guard HerdrTarget.isSession(name) else {
            return done(.failure(.init("“\(name)” is not a herdr session name (letters, digits, _ and -); host_sessions lists herdr's sessions.")))
        }
        guard RemoteConnection.masterAlive(host) else {
            return done(.failure(.init("To open a herdr session by name, list host_sessions once a tab on \(host.name) is connected: Next Term opens only a session herdr lists.")))
        }
        RemoteConnection.run(host, script: RemoteShell.sessionsScript, timeout: 25) { output in
            guard let listed = RemoteSession.parseList(output.output) else {
                return done(.failure(.init("Could not list herdr's sessions on \(host.name): \(output.problem)")))
            }
            guard let session = listed.herdrSessions?.first(where: { $0.name == name }) else {
                let known = (listed.herdrSessions ?? []).map(\.name).joined(separator: ", ")
                let lists = known.isEmpty ? "" : " (it lists \(known))"
                return done(.failure(.init("herdr on \(host.name) lists no session “\(name)”\(lists); nothing was opened.")))
            }
            done(.success(session.isDefault ? nil : session.name))
        }
    }

    private static func open(_ found: RemoteHost, directory: String, mode: KeepMode, session: String?, herdrSession: String?,
                             command: String, arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        let app: AppDelegate = AppDelegate.shared
        let controller = caller.flatMap(MCPControl.controller(of:)) ?? (NSApp.keyWindow?.windowController as? TerminalWindowController)
            ?? app.controllers.first ?? app.openWindow(directory: nil, forAgent: true)
        // With no open connection, ssh may ask the user for a password or a host key: show them the tab that asks
        // (another tab may be logging in to this host already: then that one), selected even in the window they are in.
        // It waits for their click like any tab an agent opened, so nothing they were typing goes to ssh (AgentArrival).
        let mustLogIn = !RemoteConnection.masterAlive(found)
        let remote = RemoteTab(host: found, directory: directory, session: session, keep: mode, herdrSession: herdrSession)
        let tab = controller.addRemoteTab(remote, select: false, byAgent: true)
        if mustLogIn {
            let asking = RemoteConnection.loginTab(for: found) ?? tab
            if let owner = MCPControl.controller(of: asking) {
                if asking.view.awaitsChoice { asking.view.choiceHint = "ssh may ask for a password or a host key here. Click to answer." }
                owner.presentForAgent(asking, explicit: true, login: true)
            }
        } else {
            controller.presentForAgent(tab)
        }
        MCPControl.driven.insert(tab.id)
        if let title = arguments["title"] as? String, !title.isEmpty { tab.userTitle = String(title.prefix(100)) }
        controller.refresh()
        var answer: [String: Any] = ["id": tab.id.uuidString.lowercased(), "host": found.name, "directory": directory,
                                     "keep": mode.rawValue, "session": tab.remote?.session ?? ""]
        if mode == .herdr { answer["session"] = herdrSession ?? NSNull() } // herdr's session; null for its default
        guard !command.isEmpty else { return reply(ok(answer)) }
        // Type it only at the host's shell prompt: never into ssh asking the user for a password.
        waitForPrompt(tab, until: TerminalTab.now + 45) { ready in
            guard ready else {
                var info = answer
                info["command_typed"] = false
                if tab.disconnected || tab.exited {
                    info["note"] = "ssh could not connect, so the command was not typed. The tab shows why."
                    info["screen"] = MCPControl.fieldTail(tab, 8).joined(separator: "\n") // masked over whole lines, as read_tab
                    return reply(MCPServer.CallResult(text: MCPServer.json(info), isError: true))
                }
                info["note"] = "The tab is open but its shell was not at a prompt within 45 s (ssh may be asking the user for a password or a host key). The command was not typed: send it with send_to_tab once read_tab shows a prompt."
                return reply(ok(info))
            }
            if tab.remoteFolderMissing {
                var info = answer
                info["command_typed"] = false
                info["note"] = "\(directory) is not a folder on \(found.name); the tab opened in the home folder, so the command was not typed there."
                return reply(MCPServer.CallResult(text: MCPServer.json(info), isError: true))
            }
            MCPControl.type(command, into: tab, submit: true)
            var info = answer
            info["command_typed"] = true
            reply(ok(info))
        }
    }

    private static func waitForPrompt(_ tab: TerminalTab, until deadline: TimeInterval, _ body: @escaping (Bool) -> Void) {
        if tab.exited || tab.disconnected { return body(false) }
        if tab.remoteReady && !tab.disconnected { return body(true) }
        if TerminalTab.now >= deadline { return body(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitForPrompt(tab, until: deadline, body) }
    }

    // MARK: what the host keeps, and what changed there

    private static func hostSessions(_ arguments: [String: Any], reply: @escaping Reply) {
        let found: RemoteHost
        switch host(arguments) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let host): found = host
        }
        RemoteConnection.run(found, script: RemoteShell.sessionsScript, timeout: 25) { output in
            guard let listed = RemoteSession.parseList(output.output) else { return reply(unreachable(found, output)) }
            let open = AppDelegate.shared.controllers.flatMap(\.tabs).compactMap { tab -> (String, String)? in
                guard let remote = tab.remote, remote.host.id == found.id, !tab.exited else { return nil }
                return (remote.session, tab.id.uuidString.lowercased())
            }
            let openTabs = Dictionary(open, uniquingKeysWith: { first, _ in first })
            var info: [String: Any] = ["host": found.name, "sessions": listed.sessions.map { session -> [String: Any] in
                var entry = describe(session)
                if let tab = openTabs[session.name] { entry["tab_id"] = tab }
                return entry
            }]
            if let report = listed.herdr, report.listing != .missing, let problem = report.problem { info["herdr"] = problem }
            info.merge(herdrFields(listed.herdr, sessions: listed.herdrSessions, named: listed.herdrReports, host: found)) { $1 }
            reply(ok(info))
        }
    }

    /// herdr's sessions on a host (`herdr_sessions`: name, default, running, and the tab showing it, if one does) and the
    /// agents of the running ones (`herdr_agents`, each with its session), from sessionsScript's answer.
    static func herdrFields(_ fallback: HerdrReport?, sessions: [HerdrSession]?, named: [String: HerdrReport],
                            host: RemoteHost) -> [String: Any] {
        var info: [String: Any] = [:]
        let tabs = AppDelegate.shared.controllers.flatMap(\.tabs).filter { tab in
            tab.remote?.host.id == host.id && tab.remote?.keep == .herdr && !tab.exited && !tab.fellBack
        }
        // The tab showing a session: herdr's default is a tab with none.
        func tab(showing session: String?) -> TerminalTab? { tabs.first { $0.remote?.herdrSession == session } }
        let defaultName = sessions?.first(where: \.isDefault)?.name
        if let sessions {
            info["herdr_sessions"] = sessions.map { session -> [String: Any] in
                var entry: [String: Any] = ["name": session.name, "default": session.isDefault, "running": session.running]
                if let shown = tab(showing: session.isDefault ? nil : session.name) { entry["tab_id"] = shown.id.uuidString.lowercased() }
                return entry
            }
        }
        var agents: [[String: Any]] = []
        var answered = false
        let reports: [(String?, HerdrReport?)] = [(nil, fallback)] + named.keys.sorted().map { ($0, named[$0]) }
        for (session, report) in reports {
            guard let report, case .agents(let listed) = report.listing else { continue }
            answered = true
            let shown = tab(showing: session)
            for agent in listed {
                var entry = HerdrMCP.fields(agent)
                if let name = session ?? defaultName { entry["session"] = name }
                // Its id while a tab follows this session's agents: the tab tools then take it.
                if let shown, shown.followsHerdr { entry["id"] = HerdrTarget(tabID: shown.id.uuidString, pane: agent.paneID).id }
                agents.append(entry)
            }
        }
        if answered { info["herdr_agents"] = agents }
        return info
    }

    private static func hostChanges(_ arguments: [String: Any], reply: @escaping Reply) {
        let found: RemoteHost
        switch host(arguments) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let host): found = host
        }
        let directory = (arguments["directory"] as? String)?.trimmingCharacters(in: .whitespaces) ?? found.directory
        if let problem = RemoteHost.directoryProblem(directory) { return reply(fail(problem)) }
        let withDiff = arguments["diff"] as? Bool ?? true
        let limit = min(2_000_000, max(1000, arguments["max_bytes"] as? Int ?? 200_000))
        // The diff is masked before it is cut, on the bytes `head -c` counts: the host sends the longest stored form's
        // bytes past the cut, so a value that starts before it is there whole, and is left out whole. The answer takes
        // the mask as it is then, up to 50 s later (RemoteChanges.shownDiff).
        let asked = withDiff ? SecretMask.current.bytesToRead(forCutAt: limit) : 0
        let script = RemoteShell.changesScript(directory: directory, maxBytes: asked)
        RemoteConnection.run(found, script: script, timeout: 50) { output in
            guard let changes = RemoteChanges.parse(output.output) else {
                if output.status == 3 || output.status == 4 { return reply(fail("\(directory) on \(found.name): \(output.problem)")) }
                return reply(unreachable(found, output))
            }
            var info: [String: Any] = ["host": found.name, "directory": directory, "branch": changes.branch,
                                       "files": changes.files, "stat": changes.stat]
            if withDiff {
                let shown = changes.shownDiff(cutAt: limit, asked: asked, mask: SecretMask.current)
                info["diff"] = shown.text
                if let cut = shown.cutAt { info["diff_cut_at_bytes"] = cut }
            }
            reply(ok(info))
        }
    }
}

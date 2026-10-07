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
            info["git"] = probe.git ?? NSNull()
            if let linger = probe.linger { info["linger"] = linger }
            var notes: [String] = []
            if found.keep == .tmux && probe.tmux == nil {
                notes.append("keep is tmux but tmux is not on this host: tabs open a plain shell that nothing keeps. The user can install tmux, or use keep herdr or off.")
            } else if found.keep == .tmux && !probe.tmuxUsable {
                notes.append("tmux on this host is older than 3.2: tabs use it, but Next Term is tested with 3.2 and later.")
            }
            if found.keep == .herdr && probe.herdr == nil {
                notes.append("keep is herdr but herdr is not on this host (herdr.dev). Next Term never installs it.")
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
        let session = (arguments["session"] as? String).map(RemoteShell.safeName)
        let command = (arguments["command"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if command.contains("\n") { return reply(fail("The command must be one line.")) }
        if !command.isEmpty && mode == .herdr {
            return reply(fail("A herdr tab shows herdr itself, not a shell: start agents in herdr (on the host: herdr agent start), or open the tab with keep tmux or off to run a command."))
        }
        if !command.isEmpty && session != nil {
            return reply(fail("Give either session (attach to what runs there) or command (a new session), not both."))
        }
        if session != nil && mode != .tmux { return reply(fail("session attaches to Next Term's tmux sessions: use it with keep tmux.")) }
        let app: AppDelegate = AppDelegate.shared
        let controller = caller.flatMap(MCPControl.controller(of:)) ?? (NSApp.keyWindow?.windowController as? TerminalWindowController)
            ?? app.controllers.first ?? app.openWindow(directory: nil)
        // With no open connection, ssh may ask the user for a password or a host key: show them the tab
        // that asks (another tab may be logging in to this host already: then that one).
        let mustLogIn = !RemoteConnection.masterAlive(found)
        let tab = controller.addRemoteTab(RemoteTab(host: found, directory: directory, session: session, keep: mode), select: false)
        if mustLogIn {
            let asking = RemoteConnection.loginTab(for: found) ?? tab
            if let owner = MCPControl.controller(of: asking) {
                owner.show(asking)
                owner.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        MCPControl.driven.insert(tab.id)
        if let title = arguments["title"] as? String, !title.isEmpty { tab.userTitle = String(title.prefix(100)) }
        controller.refresh()
        let answer: [String: Any] = ["id": tab.id.uuidString.lowercased(), "host": found.name, "directory": directory,
                                     "keep": mode.rawValue, "session": tab.remote?.session ?? ""]
        guard !command.isEmpty else { return reply(ok(answer)) }
        // Type it only at the host's shell prompt: never into ssh asking the user for a password.
        waitForPrompt(tab, until: TerminalTab.now + 45) { ready in
            guard ready else {
                var info = answer
                info["command_typed"] = false
                if tab.disconnected || tab.exited {
                    info["note"] = "ssh could not connect, so the command was not typed. The tab shows why."
                    info["screen"] = tab.screenTail(8).joined(separator: "\n")
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
            if let agents = listed.herdr {
                info["herdr_agents"] = agents.map { agent -> [String: Any] in
                    var entry: [String: Any] = ["pane": agent.paneID, "agent": agent.name, "state": agent.status.rawValue]
                    if let title = agent.title { entry["title"] = title }
                    if let directory = agent.directory { entry["directory"] = directory }
                    return entry
                }
            }
            reply(ok(info))
        }
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
        let script = RemoteShell.changesScript(directory: directory, maxBytes: withDiff ? limit + 1 : 0)
        RemoteConnection.run(found, script: script, timeout: 50) { output in
            guard let changes = RemoteChanges.parse(output.output) else {
                if output.status == 3 || output.status == 4 { return reply(fail("\(directory) on \(found.name): \(output.problem)")) }
                return reply(unreachable(found, output))
            }
            var info: [String: Any] = ["host": found.name, "directory": directory, "branch": changes.branch,
                                       "files": changes.files, "stat": changes.stat]
            if withDiff {
                let cut = changes.diff.utf8.count > limit
                info["diff"] = cut ? String(decoding: Array(changes.diff.utf8.prefix(limit)), as: UTF8.self) : changes.diff
                if cut { info["diff_cut_at_bytes"] = limit }
            }
            reply(ok(info))
        }
    }
}

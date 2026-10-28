import AppKit
import NextTermCore

/// The MCP tools for servers (Connect VPS): saved hosts, tabs on them, what they keep running, and what
/// changed there. On the main thread, like the rest of MCPControl. Every command that runs on a host is
/// one of RemoteShell's fixed scripts; arguments only ever reach it quoted (see Remote.swift).
enum RemoteMCP {
    typealias Reply = MCPControl.Reply

    private static func fail(_ text: String) -> MCPServer.CallResult { MCPControl.fail(text) }
    private static func ok(_ value: Any) -> MCPServer.CallResult { MCPControl.ok(value) }

    /// `approval`, `requester` and `connection`: as MCPControl.call has them, for the tools that ask on the Mac first
    /// (saving, changing and forgetting a host, ending a session; MCPWriteControl.approve).
    static func call(_ tool: String, _ arguments: [String: Any], caller: TerminalTab?, approval: MCPApproval = .askOnMac,
                     requester: String? = nil, connection: String? = nil, reply: @escaping Reply) {
        switch tool {
        case "list_hosts": reply(ok(["hosts": RemoteHosts.all.map(describe)]))
        case "add_host", "remove_host", "edit_host", "end_session":
            MainActor.assumeIsolated {
                let context = MCPWriteControl.context(arguments, caller: caller, approval: approval, requester: requester,
                                                      connection: connection)
                switch tool {
                case "add_host": addHost(arguments, context, reply: reply)
                case "remove_host": removeHost(arguments, context, reply: reply)
                case "edit_host": editHost(arguments, context, reply: reply)
                default: endSession(arguments, context, reply: reply)
                }
            }
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
        if let prefix = host.tmuxPrefix { info["tmux_prefix"] = prefix.rawValue }
        if let history = host.tmuxHistory { info["tmux_history"] = history }
        return info
    }

    /// One line for the approval window: “web-1 (dev@203.0.113.5, port 2222)”.
    private static func named(_ host: RemoteHost) -> String {
        "“\(host.name)” (\(host.destination)\(host.port.map { ", port \($0)" } ?? ""))"
    }

    /// The tabs open on `host` now.
    private static func openTabs(on host: RemoteHost) -> [TerminalTab] {
        AppDelegate.shared.controllers.flatMap(\.tabs).filter { (tab: TerminalTab) -> Bool in tab.remote?.host.id == host.id && !tab.exited }
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

    /// add_host: every check first, so a call that would fail never asks; then the user approves on the Mac, and the
    /// host is looked at again before it is saved.
    @MainActor
    private static func addHost(_ arguments: [String: Any], _ context: MCPWriteControl.Context, reply: @escaping Reply) {
        let name = (arguments["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let destination = (arguments["destination"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let existing = RemoteHosts.all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        var host = existing ?? RemoteHost(name: name, destination: destination)
        let port = arguments["port"] as? Int
        // A saved host keeps where it points: tabs saved for it, and the user, trust that. Re-pointing it is edit_host,
        // which gives it a new id that saved tabs do not follow.
        if let existing, existing.destination != destination || (arguments["port"] != nil && existing.port != port) {
            return reply(fail("“\(existing.name)” points to \(existing.destination)\(existing.port.map { " port \($0)" } ?? ""). To point it elsewhere, use edit_host, or remove_host it and add_host it again."))
        }
        host.name = name
        host.destination = destination
        if let port { host.port = port }
        if let directory = arguments["directory"] as? String { host.directory = directory.trimmingCharacters(in: .whitespaces) }
        switch keep(arguments["keep"]) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let mode): if let mode { host.keep = mode }
        }
        if let problem = host.problem { return reply(fail(problem)) }
        if let existing, existing == host { return reply(ok(["host": describe(host), "saved": true, "unchanged": true])) }
        let details: String
        if let existing {
            // Which server, then what changes: a name alone does not say where it points.
            details = named(existing) + ":\n" + HostEdit.changes(from: existing, to: host).joined(separator: "\n")
        } else {
            details = "\(named(host)), folder \(host.directory), keep \(host.keep.rawValue). Next Term connects to it only when a tab opens there, with your own ssh and keys; nothing is installed or run on it now."
        }
        let title = existing == nil ? "An agent asks to save a server" : "An agent asks to change a saved server"
        MCPWriteControl.approve(MCPWriteControl.Ask(title: title, details: details), context, reply: reply) { approved, window in
            window?.finish()
            // Looked at again: the saved host as it was asked about, and the name still free.
            let now = RemoteHosts.all
            let same: Bool = existing.map { (saved: RemoteHost) -> Bool in now.contains(saved) } ?? true
            let taken: Bool = now.contains { (other: RemoteHost) -> Bool in
                other.id != host.id && other.name.caseInsensitiveCompare(host.name) == .orderedSame
            }
            guard same, !taken else { return reply(fail("The saved servers changed while you were asked; nothing changed. list_hosts shows them.")) }
            RemoteHosts.save(host)
            reply(ok(["host": describe(host), "saved": true, "approved": approved]))
        }
    }

    @MainActor
    private static func removeHost(_ arguments: [String: Any], _ context: MCPWriteControl.Context, reply: @escaping Reply) {
        let host: RemoteHost
        switch self.host(arguments) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let found): host = found
        }
        let open: Int = openTabs(on: host).count
        let tabs = open == 0 ? "" : " \(open) tab\(open == 1 ? "" : "s") on it stay open until closed, and are not reopened at the next launch."
        let ask = MCPWriteControl.Ask(title: "An agent asks to forget a saved server",
                                      details: "\(named(host)) leaves Next Term’s servers.\(tabs) Sessions kept there (tmux, herdr) keep running.")
        MCPWriteControl.approve(ask, context, reply: reply) { approved, window in
            window?.finish()
            guard RemoteHosts.all.contains(where: { (saved: RemoteHost) -> Bool in saved.id == host.id }) else {
                return reply(fail("“\(host.name)” was removed meanwhile; nothing changed."))
            }
            RemoteHosts.remove(id: host.id)
            let open: Int = openTabs(on: host).count
            var info: [String: Any] = ["id": host.id, "removed": true, "approved": approved]
            if open > 0 {
                info["note"] = "\(open) tab\(open == 1 ? "" : "s") on it stay open until closed, and will not be reopened at the next launch. Sessions kept there (tmux, herdr) keep running."
            }
            reply(ok(info))
        }
    }

    /// edit_host: the fields given replace the saved ones (HostEdit), checked before anything is asked. A new destination
    /// or port gives the host a new id, as New Remote Tab does.
    @MainActor
    private static func editHost(_ arguments: [String: Any], _ context: MCPWriteControl.Context, reply: @escaping Reply) {
        let saved: RemoteHost
        switch host(arguments) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let found): saved = found
        }
        let applied: HostEdit.Applied
        switch HostEdit.parse(arguments).flatMap({ (edit: HostEdit) in edit.apply(to: saved, others: RemoteHosts.all) }) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let result): applied = result
        }
        guard !applied.changes.isEmpty else { return reply(ok(["host": describe(saved), "unchanged": true])) }
        let open: Int = openTabs(on: saved).count
        var lines: [String] = applied.changes
        if applied.repointed {
            lines.append("It then points at another server: tabs saved for it are not reopened there.")
        }
        if open > 0 {
            lines.append("\(open) tab\(open == 1 ? "" : "s") open on it keep their connection; tmux's prefix and history reach them as they reconnect.")
        }
        let ask = MCPWriteControl.Ask(title: "An agent asks to change a saved server", details: named(saved) + ":\n" + lines.joined(separator: "\n"))
        MCPWriteControl.approve(ask, context, reply: reply) { approved, window in
            window?.finish()
            let now: [RemoteHost] = RemoteHosts.all
            guard now.contains(saved) else {
                return reply(fail("“\(saved.name)” changed or was removed while you were asked; nothing changed. list_hosts shows it now."))
            }
            // The new name still free: another server may have taken it while the user was asked.
            let taken: Bool = now.contains { (other: RemoteHost) -> Bool in
                other.id != saved.id && other.name.caseInsensitiveCompare(applied.host.name) == .orderedSame
            }
            guard !taken else { return reply(fail("Another saved server took the name “\(applied.host.name)” while you were asked; nothing changed.")) }
            if applied.repointed { RemoteHosts.remove(id: saved.id) }
            RemoteHosts.save(applied.host)
            var info: [String: Any] = ["host": describe(applied.host), "changed": applied.changes, "approved": approved]
            if applied.repointed { info["repointed"] = true }
            if open > 0 { info["note"] = "Tabs open on it keep their connection; tmux's prefix and history reach them as they reconnect." }
            reply(ok(info))
        }
    }

    /// end_session: one of Next Term's tmux sessions on a host, over a tab's open connection. herdr's sessions are never
    /// stopped. Tabs here that show it close once it has ended.
    @MainActor
    private static func endSession(_ arguments: [String: Any], _ context: MCPWriteControl.Context, reply: @escaping Reply) {
        let found: RemoteHost
        switch host(arguments) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let host): found = host
        }
        guard let raw = (arguments["session"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return reply(fail("Give the session's name: host_sessions lists Next Term's tmux sessions."))
        }
        let name = RemoteShell.safeName(raw)
        guard name == raw else { return reply(fail("“\(raw)” is not one of Next Term's tmux session names; host_sessions lists them.")) }
        if let own = context.caller?.remote, own.host.id == found.id, own.session == name {
            return reply(fail("That is your own tab's session."))
        }
        let showing: [TerminalTab] = openTabs(on: found).filter { (tab: TerminalTab) -> Bool in
            tab.remote?.keep == .tmux && tab.remote?.session == name
        }
        endTmuxSession(found, session: name, closing: showing, context, reply: reply) {
            var closed: [String] = []
            for tab in showing {
                guard let controller = MCPControl.controller(of: tab), !controller.asksToSave(closing: tab) else { continue }
                controller.remove(tab)
                closed.append(tab.id.uuidString.lowercased())
            }
            var info: [String: Any] = ["host": found.name, "session": name, "ended": true]
            if !closed.isEmpty { info["closed_tabs"] = closed }
            reply(ok(info))
        }
    }

    /// Ends Next Term's tmux session `session` on `host` once the user approves on the Mac: who is attached is read
    /// first and shown, and read again after Approve; a client that attached meanwhile (another Mac, say) stops it.
    /// `closing`: the tabs here that show it, named in the window. `ended` runs once the session is gone; every refusal
    /// and failure is answered here.
    @MainActor
    static func endTmuxSession(_ host: RemoteHost, session: String, closing: [TerminalTab], _ context: MCPWriteControl.Context,
                               reply: @escaping Reply, ended: @escaping () -> Void) {
        guard RemoteConnection.masterAlive(host) else {
            return reply(fail("To end a session on \(host.name), a tab there must be connected: Next Term never logs in for it."))
        }
        RemoteConnection.run(host, script: RemoteShell.clientsScript(session: session), timeout: 15) { output in
            MainActor.assumeIsolated {
                let before: [String]
                switch RemoteShell.parseClients(output.output) {
                case .unread: return reply(fail("Could not read the session on \(host.name): \(output.problem)"))
                case .gone: return reply(fail("\(host.name) has no tmux session “\(session)”; host_sessions lists them."))
                case .attached(let clients): before = clients
                }
                let attached = before.isEmpty ? "No client is attached to it now." : "Attached now: \(before.joined(separator: ", "))."
                let shown = closing.isEmpty ? "" : " \(closing.count == 1 ? "A tab here shows it and closes" : "\(closing.count) tabs here show it and close")."
                let ask = MCPWriteControl.Ask(title: "An agent asks to end a tmux session",
                                              details: "“\(session)” on \(named(host)): what runs in it stops for good. \(attached)\(shown)")
                MCPWriteControl.approve(ask, context, reply: reply) { _, window in
                    window?.finish()
                    // The second look: nobody new attached while the user was asked.
                    RemoteConnection.run(host, script: RemoteShell.clientsScript(session: session), timeout: 15) { again in
                        MainActor.assumeIsolated {
                            switch RemoteShell.parseClients(again.output) {
                            case .unread: return reply(fail("Could not read the session on \(host.name) again, so it was not ended: \(again.problem)"))
                            case .gone: return ended()
                            case .attached(let now):
                                let new: [String] = now.filter { (client: String) -> Bool in !before.contains(client) }
                                guard new.isEmpty else {
                                    return reply(fail("\(new.joined(separator: ", ")) attached to “\(session)” on \(host.name) while you were asked, so it was not ended."))
                                }
                            }
                            RemoteConnection.endSession(host, session: session) { problem in
                                if let problem {
                                    return reply(fail("Could not end tmux session \(session) on \(host.name): \(problem)"))
                                }
                                ended()
                            }
                        }
                    }
                }
            }
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
        // The title's check first, so a refused one opens nothing; open(...) sets it.
        if case .failure(let refusal) = TabRename.given(arguments["title"]) { return reply(fail(refusal.text)) }
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
        // One of Next Term's tmux sessions: while a tab on the host is connected, only one the host lists, never made by
        // its name. With no connection nothing can list them: the tab expects it, and says so if it was gone.
        if mode == .tmux, let named {
            let name = RemoteShell.safeName(named)
            guard RemoteConnection.masterAlive(found) else {
                return open(found, directory: directory, mode: mode, session: name, herdrSession: nil, command: "",
                            expectsSession: true, arguments: arguments, caller: caller, reply: reply)
            }
            return tmuxSessionListed(name, on: found) { refusal in
                if let refusal { return reply(fail(refusal.text)) }
                open(found, directory: directory, mode: mode, session: name, herdrSession: nil, command: "", expectsSession: true,
                     arguments: arguments, caller: caller, reply: reply)
            }
        }
        open(found, directory: directory, mode: mode, session: named.map(RemoteShell.safeName), herdrSession: nil, command: command,
             arguments: arguments, caller: caller, reply: reply)
    }

    /// Whether Next Term's tmux on `host` lists the session `name` (as host_sessions does), asked on the open connection:
    /// nil when it does, else why not.
    private static func tmuxSessionListed(_ name: String, on host: RemoteHost, _ done: @escaping (MCPControl.MCPError?) -> Void) {
        RemoteConnection.run(host, script: RemoteShell.sessionsScript, timeout: 25) { output in
            guard let listed = RemoteSession.parseList(output.output) else {
                return done(.init("Could not list the tmux sessions on \(host.name): \(output.problem)"))
            }
            guard listed.sessions.contains(where: { (session: RemoteSession) -> Bool in session.name == name }) else {
                let known: String = listed.sessions.map(\.name).joined(separator: ", ")
                let lists: String = known.isEmpty ? " (it has none)" : " (it lists \(known))"
                return done(.init("\(host.name) has no tmux session “\(name)”\(lists); nothing was opened. Leave session out for a new one."))
            }
            done(nil)
        }
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
                             command: String, expectsSession: Bool = false, arguments: [String: Any], caller: TerminalTab?,
                             reply: @escaping Reply) {
        let app: AppDelegate = AppDelegate.shared
        let controller = caller.flatMap(MCPControl.controller(of:)) ?? (NSApp.keyWindow?.windowController as? TerminalWindowController)
            ?? app.controllers.first ?? app.openWindow(directory: nil, forAgent: true)
        // With no open connection, ssh may ask the user for a password or a host key: show them the tab that asks
        // (another tab may be logging in to this host already: then that one), selected even in the window they are in.
        // It waits for their click like any tab an agent opened, so nothing they were typing goes to ssh (AgentArrival).
        let mustLogIn = !RemoteConnection.masterAlive(found)
        let remote = RemoteTab(host: found, directory: directory, session: session, keep: mode, herdrSession: herdrSession,
                               expectsSession: expectsSession)
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
        if case .success(let title?) = TabRename.given(arguments["title"]) { tab.userTitle = title }
        MCPTabOpeners.record(tab, openedBy: caller)
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

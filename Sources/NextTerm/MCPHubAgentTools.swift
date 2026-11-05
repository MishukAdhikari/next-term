import AppKit
import NextTermCore

/// add_mcp_server and list_mcp_servers on the app's side (MCPServer.hubTools). add_mcp_server checks the call first
/// (MCPServer.addServerRequest: a key-shaped value is refused, pointing to request_secret), then that each key it names
/// is stored and its name is free in the user's list, and only then asks on the Mac (MCPWriteControl.approve), showing
/// what will run or be reached, with which keys and where it applies. Approved, the server goes into the user's list as
/// Settings would add it (MCPHubEdits, so Settings › MCP Servers' Undo takes it out again); declined, nothing is written.
/// Always asked on the Mac, never under a grant, and this Mac only: the remote door gets neither tool.
@MainActor
enum MCPHubAgentTools {
    static let localOnly = "This works only for agents on this Mac. Nothing was done."

    static func call(_ tool: String, _ arguments: [String: Any], caller: TerminalTab?, approval: MCPApproval, requester: String?,
                     connection: String?, reply: @escaping MCPControl.Reply) {
        guard requester == nil, connection == nil else { return reply(MCPControl.fail(localOnly)) }
        switch tool {
        case "list_mcp_servers": reply(list(caller: caller))
        case "add_mcp_server": add(arguments, caller: caller, reply: reply)
        default: reply(MCPControl.fail("Unknown tool \(tool)"))
        }
    }

    // MARK: list

    static func list(caller: TerminalTab?) -> MCPServer.CallResult {
        let home = NSHomeDirectory()
        let userFile = MCPHubEdits.userFile
        let runs = MCPHubControl.lastRuns
        let user = MCPHubScope.sources(folder: nil, home: home, userFile: userFile).user
        let personal = MCPHubOverview.personal(user, runs: runs)
        var project: (folder: String, rows: [MCPHubOverview.Row])?
        if let folder = MCPHubControl.folder(of: caller) {
            let found = MCPHubScope.sources(folder: folder, home: home, userFile: userFile)
            project = (folder, MCPHubOverview.project(folder, user: found.user, projects: found.projects, home: home, runs: runs).rows)
        }
        return MCPControl.ok(MCPServer.listServersAnswer(personal: personal, project: project, home: home))
    }

    // MARK: add

    static func add(_ arguments: [String: Any], caller: TerminalTab?, reply: @escaping MCPControl.Reply) {
        var request: MCPServer.AddServerRequest
        switch MCPServer.addServerRequest(arguments) {
        case .failure(let error): return reply(MCPControl.fail(error.text))
        case .success(let made): request = made
        }
        let context = TasksMCP.onTheMac(MCPWriteControl.context(arguments, caller: caller, approval: .askOnMac, requester: nil, connection: nil))
        // Where it applies: an open project when one is named, else every project.
        var appliesTo = "every project"
        if request.project != nil {
            switch context.projects.project(request.project) {
            case .failure(let error): return reply(MCPControl.fail(error.text + " Nothing was asked."))
            case .success(let folder):
                let top = context.projects.root(holding: folder) ?? folder
                request.server.projects = .only([top])
                appliesTo = "only \(ProjectSkillsView.title(top)) (\(SkillStep.short(top)))"
            }
        }
        let stored = Set(SecretsStore.shared.index?.names ?? [])
        if let missing = request.secrets.first(where: { !stored.contains($0) }) {
            return reply(MCPControl.fail("\(missing) is not in Secrets: ask the user for it with request_secret, then call again. Nothing was asked."))
        }
        let name = request.server.name
        if MCPServerSheet.names(in: MCPHubEdits.userFile).contains(name) {
            return reply(MCPControl.fail("A server named \(name) is connected already; list_mcp_servers shows it. Pick another name, or "
                + "the user changes it in Settings \u{203A} MCP Servers. Nothing was asked."))
        }
        let server = request.server
        var ask = MCPWriteControl.Ask(title: "An agent asks to connect an MCP server",
                                      details: "\u{201C}\(name)\u{201D}, for every agent in Next Term.\n\n"
                                          + MCPServer.addServerDetails(server, appliesTo: appliesTo, commandShown: server.transport == .stdio))
        if server.transport == .stdio { ask.command = MCPHubOverview.runsText(server) }
        MCPWriteControl.approve(ask, context, reply: reply) { approved, window in
            window?.finish()
            // The list as it is now: a server of this name added meanwhile is never replaced.
            guard !MCPServerSheet.names(in: MCPHubEdits.userFile).contains(name) else {
                return reply(MCPControl.fail("A server named \(name) was connected meanwhile; nothing was added."))
            }
            if let failure = MCPHubEdits.apply("Add \(name)", [.init(change: .set(server), file: MCPHubEdits.userFile, place: .user)]) {
                return reply(MCPControl.fail(failure + " Nothing was added."))
            }
            reply(MCPControl.ok([
                "added": name,
                "applies": appliesTo,
                "approved": approved,
                "note": "Agents started in Next Term from now on can use it; Settings \u{203A} MCP Servers shows it, and its Undo takes it out.",
            ]))
        }
    }
}

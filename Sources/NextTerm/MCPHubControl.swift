import AppKit
import NextTermCore

/// The app's part of the MCP hub: an agent's bridge (`nxtrm mcp`) asks it, as its session starts, which of the servers
/// the user connected apply where the agent works (MCPHubPlan.tool). The bridge runs them; the app only reads the lists
/// (MCPHubScope) and says where: the calling tab's folder, and the login shell's PATH, with each server's cached tool
/// list for the session's direct tools (MCPHubManifest). Nothing is written for a plan, so until the user adds a server
/// there is no file, and the answer is empty (R17); a server's cached list is written only once an agent has used it.
///
/// An agent in one of this Mac's tabs gets the plan for its tab's folder; one started outside Next Term's tabs (Terminal,
/// an IDE, a desktop app) gets the plan for the folder its bridge runs in, which the bridge sends, so the user's own
/// servers reach every agent on this Mac. A remote tab's agent runs on its host and gets none. A project's list waits for the user's approval of it as it is now, which Settings › MCP Servers
/// keeps in the user's list (MCPHubChoices); until then a project's servers are listed, never started.
///
/// The app also keeps, in memory only, how each server's last start in an agent's session ended (`lastRuns`, from the
/// bridge's report), and the changes Settings made, for its Undo (MCPHubEdits).
@MainActor
enum MCPHubControl {
    /// The user's list: the self-test points it at its own.
    static var userFile: String?

    static func plan(_ arguments: [String: Any] = [:], caller: TerminalTab?, reply: @escaping MCPControl.Reply) {
        guard let folder = folder(of: caller, arguments: arguments) else { return reply(MCPServer.CallResult(text: "")) }
        let file = userFile ?? MCPHubScope.userPath()
        // The login shell's PATH once its probe has run; never waited for here, since the bridge waits for this answer
        // before its tool list. Without it the bridge's own PATH is used.
        let path = LoginShell.isProbed ? LoginShell.path : []
        if !LoginShell.isProbed { LoginShell.warmUp() }
        Task.detached {
            let resolution = MCPHubScope.servers(folder: folder, userFile: file)
            var plan = MCPHubPlan.make(resolution, folder: folder, path: path, approved: resolution.approved)
            // The servers' cached tool lists, for the session's direct tools: read, never fetched (MCPHubManifest).
            plan.allotDirect(MCPHubManifest.read(resolution, userFile: file))
            let answer = MCPServer.CallResult(text: plan.servers.isEmpty && plan.problems.isEmpty ? "" : plan.text)
            await MainActor.run { reply(answer) }
        }
    }

    /// Posted when the lists change through Settings, or a start's report changes what Settings shows.
    static let changed = Notification.Name("NextTermMCPHubChanged")

    /// The last start of each server in an agent's session, by MCPHubOverview.runKey. Kept while the app runs.
    static var lastRuns: [String: MCPHubOverview.Run] = [:]

    /// The bridge's report of a start (MCPHubPlan.reportTool): only from an agent in one of this Mac's tabs. One with a
    /// `manifest` is a local server's tool list instead, which its session found other than the one it started with.
    static func report(_ arguments: [String: Any], caller: TerminalTab?, reply: @escaping MCPControl.Reply) {
        guard let folder = folder(of: caller, arguments: arguments), let server = arguments["server"] as? String, let list = arguments["list"] as? String,
              !server.isEmpty, !list.isEmpty else { return reply(MCPServer.CallResult(text: "")) }
        if let manifest = arguments["manifest"] { return remember(manifest, server: server, list: list, folder: folder, reply: reply) }
        let run = MCPHubOverview.Run(failure: arguments["failure"] as? String, tools: arguments["tools"] as? Int ?? 0)
        let key = MCPHubOverview.runKey(list: list, server: server)
        if lastRuns[key] != run {
            lastRuns[key] = run
            NotificationCenter.default.post(name: changed, object: nil)
        }
        reply(MCPServer.CallResult(text: ""))
    }

    /// Keeps a local server's tool list as the bridge saw it, for the next sessions' direct tools: only for a server that
    /// applies where the agent works, from that list, as the lists are now (the bridge's word names it, never decides it).
    private static func remember(_ manifest: Any, server name: String, list: String, folder: String, reply: @escaping MCPControl.Reply) {
        let file = userFile ?? MCPHubScope.userPath()
        guard JSONSerialization.isValidJSONObject(manifest), let data = try? JSONSerialization.data(withJSONObject: manifest),
              let decoded = try? JSONDecoder().decode(MCPHubManifest.self, from: data) else { return reply(MCPServer.CallResult(text: "")) }
        // Its tools again through the same cuts, whatever the bridge sent.
        let kept = MCPHubManifest(tools: decoded.tools.map { MCPHubManifest.Tool(checking: $0) }, count: decoded.count)
            .masked { SecretMask.current.mask($0) }
        Task.detached {
            let resolution = MCPHubScope.servers(folder: folder, userFile: file)
            if let applied = resolution.servers.first(where: { $0.name == name && $0.source.file == list }), applied.server.transport == .stdio {
                MCPHubManifest.remember(kept, server: applied.server, list: list, userFile: file)
            }
            await MainActor.run { reply(MCPServer.CallResult(text: "")) }
        }
    }

    /// Where the calling agent works: its tab's folder (nil for a remote tab); outside Next Term's tabs, the folder its
    /// bridge sent (`folder`, an absolute folder that exists), else the home folder.
    static func folder(of tab: TerminalTab?, arguments: [String: Any]) -> String? {
        if tab != nil { return folder(of: tab) }
        return MCPHubPlan.outsideFolder(arguments["folder"] as? String)
    }

    /// Where the agent in `tab` works: its folder, or its window's project. Nil outside a tab, and for a remote one.
    static func folder(of tab: TerminalTab?) -> String? {
        guard let tab, tab.remote == nil else { return nil }
        let folder = tab.directory.isEmpty ? MCPControl.controller(of: tab)?.project : tab.directory
        return folder.flatMap { $0.isEmpty ? nil : canonicalPath($0) }
    }
}

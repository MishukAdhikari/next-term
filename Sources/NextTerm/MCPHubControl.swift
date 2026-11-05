import AppKit
import NextTermCore

/// The app's part of the MCP hub: an agent's bridge (`nxtrm mcp`) asks it, as its session starts, which of the servers
/// the user connected apply where the agent works (MCPHubPlan.tool). The bridge runs them; the app only reads the lists
/// (MCPHubScope) and says where: the calling tab's folder, and the login shell's PATH. Nothing is written, so until the
/// user adds a server there is no file, and the answer is empty (R17).
///
/// Only an agent in one of this Mac's tabs gets a plan: servers apply inside Next Term (R4), and a remote tab's agent
/// runs on its host. A project's list waits for the user's approval of it as it is now, which Settings › MCP Servers
/// keeps in the user's list (MCPHubChoices); until then a project's servers are listed, never started.
///
/// The app also keeps, in memory only, how each server's last start in an agent's session ended (`lastRuns`, from the
/// bridge's report), and the changes Settings made, for its Undo (MCPHubEdits).
@MainActor
enum MCPHubControl {
    /// The user's list: the self-test points it at its own.
    static var userFile: String?

    static func plan(caller: TerminalTab?, reply: @escaping MCPControl.Reply) {
        guard let folder = folder(of: caller) else { return reply(MCPServer.CallResult(text: "")) }
        let file = userFile ?? MCPHubScope.userPath()
        // The login shell's PATH once its probe has run; never waited for here, since the bridge waits for this answer
        // before its tool list. Without it the bridge's own PATH is used.
        let path = LoginShell.isProbed ? LoginShell.path : []
        if !LoginShell.isProbed { LoginShell.warmUp() }
        Task.detached {
            let resolution = MCPHubScope.servers(folder: folder, userFile: file)
            let plan = MCPHubPlan.make(resolution, folder: folder, path: path, approved: resolution.approved)
            let answer = MCPServer.CallResult(text: plan.servers.isEmpty && plan.problems.isEmpty ? "" : plan.text)
            await MainActor.run { reply(answer) }
        }
    }

    /// Posted when the lists change through Settings, or a start's report changes what Settings shows.
    static let changed = Notification.Name("NextTermMCPHubChanged")

    /// The last start of each server in an agent's session, by MCPHubOverview.runKey. Kept while the app runs.
    static var lastRuns: [String: MCPHubOverview.Run] = [:]

    /// The bridge's report of a start (MCPHubPlan.reportTool): only from an agent in one of this Mac's tabs.
    static func report(_ arguments: [String: Any], caller: TerminalTab?, reply: @escaping MCPControl.Reply) {
        guard folder(of: caller) != nil, let server = arguments["server"] as? String, let list = arguments["list"] as? String,
              !server.isEmpty, !list.isEmpty else { return reply(MCPServer.CallResult(text: "")) }
        let run = MCPHubOverview.Run(failure: arguments["failure"] as? String, tools: arguments["tools"] as? Int ?? 0)
        let key = MCPHubOverview.runKey(list: list, server: server)
        if lastRuns[key] != run {
            lastRuns[key] = run
            NotificationCenter.default.post(name: changed, object: nil)
        }
        reply(MCPServer.CallResult(text: ""))
    }

    /// Where the agent in `tab` works: its folder, or its window's project. Nil outside a tab, and for a remote one.
    static func folder(of tab: TerminalTab?) -> String? {
        guard let tab, tab.remote == nil else { return nil }
        let folder = tab.directory.isEmpty ? MCPControl.controller(of: tab)?.project : tab.directory
        return folder.flatMap { $0.isEmpty ? nil : canonicalPath($0) }
    }
}

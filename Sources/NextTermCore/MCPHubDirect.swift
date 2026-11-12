import CryptoKit
import Foundation

/// Direct tools (R5): the tools of the servers that apply where an agent works, listed after Next Term's own (and the
/// catalog's) as if they were its own, from each server's cached list (MCPHubManifest), fixed as the session starts. A
/// call to one goes exactly where mcp_call with its server and tool goes (MCPHubSession). The catalog stays for the rest
/// (R6): a server added mid-session, one with no cached list yet, and the servers over the budget.
///
/// **Names.** `<server>__<tool>`, every character but `A-Z a-z 0-9 _ -` made `_`, which every agent and API takes as it is
/// (Anthropic's `^[a-zA-Z0-9_-]{1,128}$`, OpenAI's and many gateways' `{1,64}`; MCP's own set adds `.`, which those
/// refuse). An agent puts its own prefix in front: Claude Code and Codex `mcp__next-term__`, Gemini CLI `mcp_next-term_`.
/// So a name is at most `nameLimit`, 64 less the longest of those, 16: the whole name stays within the 64 of OpenAI-style
/// limits and under the 63 past which Gemini CLI keeps only a name's ends (with no check for two that end alike). A name
/// that had to change (a character made `_`), runs over, or would be another's (ignoring case and `-` against `_`, as
/// Codex's own sanitizing folds them, and never one of Next Term's own) ends in `_` and six hex digits of its server and
/// tool's digest instead, so it is the same in every session. Of tools whose names clash, the first in byte order keeps
/// its name.
///
/// **Budget.** At most `budget` direct tools a session, a server's tools all or none (half a server would be harder to
/// reason about than a server reached by the catalog). Servers take their turn in the plan's order (name order), and one
/// that doesn't fit leaves the rest of the budget to the next. 40: Next Term's own 62 tools and the catalog's 3 then come
/// to 105, under the 128 tools VS Code takes in one request (the one documented cap among agents) with room for an
/// agent's own built-ins; and it is the cap Cursor was long known for, which some agents and gateways still follow. Each
/// is kept loaded for Claude Code (`anthropic/alwaysLoad`): the user connected the server for its agents to use, and a
/// deferred tool stays out of sight until a search the agent has no reason to make.
public enum MCPHubDirect {
    public static let budget = 40
    /// The longest name: 64 less the longest agent prefix (`mcp__next-term__`).
    public static let nameLimit = 64 - ("mcp__" + MCPServer.name + "__").count
    static let hashLength = 6

    /// One direct tool: its name for the agent, and the server and tool a call reaches.
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let server: String
        public let tool: MCPHubManifest.Tool
    }

    /// Whether a tool name is a direct tool's: one of Next Term's own never has `__`.
    public static func isDirectName(_ name: String) -> Bool { name.contains("__") }

    /// The names Next Term's own tools and the catalog's take, which a direct tool's never clashes with.
    public static var reserved: Set<String> { Set((MCPServer.tools + MCPHubCatalog.tools).map(\.name)) }

    // MARK: names

    private static let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".unicodeScalars)

    static func sanitized(_ text: String) -> String {
        let made = String(String.UnicodeScalarView(text.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        return made.isEmpty ? "_" : made
    }

    /// How a name compares with others: case and `-` against `_` don't tell two apart.
    static func folded(_ name: String) -> String { name.lowercased().replacingOccurrences(of: "-", with: "_") }

    static func hash(_ server: String, _ tool: String, length: Int = hashLength) -> String {
        String(SHA256.hash(data: Data((server + "\u{0}" + tool).utf8)).map { String(format: "%02x", $0) }.joined().prefix(length))
    }

    /// Each server's tools' names, in order, across the session: nil for a tool no name could be found for (it stays
    /// with the catalog). `reserved`: names already taken.
    public static func names(_ servers: [(server: String, tools: [String])], reserved: Set<String> = reserved) -> [[String?]] {
        var taken = Set(reserved.map(folded))
        var names: [[String?]] = servers.map { Array(repeating: nil, count: $0.tools.count) }
        var later: [(server: Int, tool: Int)] = []
        for (s, entry) in servers.enumerated() {
            // Those that keep their name: unchanged, within the limit, and the first of a clash in byte order.
            var keeps: [String: Int] = [:]
            for (t, tool) in entry.tools.enumerated() {
                let plain = entry.server + "__" + tool
                guard sanitized(tool) == tool, plain.count <= nameLimit, !taken.contains(folded(plain)) else { continue }
                if let other = keeps[folded(plain)], entry.tools[other].utf8.lexicographicallyPrecedes(tool.utf8) { continue }
                keeps[folded(plain)] = t
            }
            for (key, t) in keeps {
                names[s][t] = entry.server + "__" + entry.tools[t]
                taken.insert(key)
            }
            for t in entry.tools.indices where names[s][t] == nil { later.append((s, t)) }
        }
        // Then the rest, each with its digest; a longer one in the unlikely case that clashes too.
        for (s, t) in later {
            let server = servers[s].server, tool = servers[s].tools[t]
            let base = server + "__" + sanitized(tool)
            for length in [hashLength, 12] {
                let name = String(base.prefix(nameLimit - length - 1)) + "_" + hash(server, tool, length: length)
                if taken.insert(folded(name)).inserted { names[s][t] = name; break }
            }
        }
        return names
    }

    // MARK: the session's tools

    /// The direct tools of a plan's servers: those it gives cached tools (MCPHubPlan.allotDirect), named.
    public static func entries(_ plan: MCPHubPlan) -> [Entry] {
        let servers = plan.servers.filter { $0.state == .ready && $0.tools != nil }
        let named = names(servers.map { ($0.name, ($0.tools ?? []).map(\.name)) })
        var entries: [Entry] = []
        for (server, names) in zip(servers, named) {
            for (tool, name) in zip(server.tools ?? [], names) {
                if let name { entries.append(Entry(name: name, server: server.name, tool: tool)) }
            }
        }
        return entries
    }

    /// One as `tools/list` lists it: the server's name in its title, its description as the server gave it (cut), its
    /// schema and hints, kept loaded for Claude Code. A hint the server left out is MCP's default for it, as it would be.
    public static func listed(_ entry: Entry) -> MCPServer.Tool {
        let tool = entry.tool
        let description = tool.description.flatMap { $0.isEmpty ? nil : $0 } ?? "\(tool.name), a tool of \(entry.server)."
        return MCPServer.Tool(name: entry.name, title: "\(entry.server): \(tool.title ?? tool.name)", description: description,
                              inputSchema: tool.inputSchema ?? #"{"type":"object"}"#, readOnly: tool.readOnlyHint ?? false,
                              destructive: tool.destructiveHint ?? true, idempotent: tool.idempotentHint ?? false,
                              timeout: MCPHubUpstream.Limits.standard.call, openWorld: tool.openWorldHint ?? true, alwaysLoad: true)
    }

    /// Of a server's cached tools, those that can be direct: the ones with a schema an agent takes.
    static func usable(_ manifest: MCPHubManifest) -> [MCPHubManifest.Tool] { manifest.tools.filter { $0.inputSchema != nil } }
}

extension MCPHubPlan {
    /// Gives each ready server with a whole cached list its usable tools for direct tools, in order, while they fit in
    /// `budget`; the others keep only their cached list's digest and size, so the plan stays small.
    public mutating func allotDirect(_ manifests: [String: MCPHubManifest], budget: Int = MCPHubDirect.budget) {
        var left = budget
        for index in servers.indices {
            let name = servers[index].name
            guard servers[index].state == .ready, let manifest = manifests[name] else { continue }
            servers[index].manifest = manifest.digest
            servers[index].cachedTools = manifest.count
            let usable = MCPHubDirect.usable(manifest)
            if manifest.isComplete, !usable.isEmpty, usable.count <= left {
                servers[index].tools = usable
                left -= usable.count
            }
        }
    }
}

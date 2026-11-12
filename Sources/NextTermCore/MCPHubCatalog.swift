import Foundation

/// The MCP hub's catalog (R6): three tools `next-term` lists after its own once a server the user connected applies
/// where the agent works (MCPHubPlan.isActive), and never before (R17); the servers' direct tools follow them
/// (MCPHubDirect). They are answered in the agent's bridge, which
/// runs the servers (MCPHubSession), never by the app. Each is kept loaded (`anthropic/alwaysLoad`): an agent can't search
/// for a server it doesn't know it has, and they are listed only once the user connected one.
public enum MCPHubCatalog {
    private static let serverArgument = #""server": {"type": "string", "description": "A server's name, as mcp_servers lists it."}"#

    public static let tools: [MCPServer.Tool] = [
        MCPServer.Tool(name: "mcp_servers", title: "List connected MCP servers",
                       description: "The MCP servers the user connected in Next Term that apply in this folder, each with its command or URL and its state: ready (it starts, or is reached, the first time it is used), running (with its tool count), failed (and why), off (the user turned it off here), needs_approval (from a project's list the user hasn't approved) or remote (an older HTTP+SSE server Next Term doesn't reach); and direct_tools, how many of its tools you have as your own, named <server>__<tool>, or direct, why they aren't (then mcp_call reaches them). mcp_tools lists and describes their tools; mcp_call calls one.",
                       inputSchema: #"{"type": "object", "properties": {}, "additionalProperties": false}"#,
                       readOnly: true, destructive: false, idempotent: true, timeout: 15, alwaysLoad: true),
        MCPServer.Tool(name: "mcp_tools", title: "Find a connected server's tools",
                       description: "The tools of the MCP servers the user connected in Next Term: with server, that server's tools; with server and tool, that tool with its full input schema; with query, the tools whose name or description has every word, across the servers. A server starts the first time it is needed, in this folder.",
                       inputSchema: #"{"type": "object", "properties": {\#(serverArgument), "tool": {"type": "string", "description": "With server: the tool to describe."}, "query": {"type": "string", "description": "Words to find in tools' names and descriptions."}}, "additionalProperties": false}"#,
                       readOnly: false, destructive: false, idempotent: true, timeout: 60, alwaysLoad: true),
        MCPServer.Tool(name: "mcp_call", title: "Call a connected server's tool",
                       description: "Calls a tool of an MCP server the user connected in Next Term, and answers what the tool answered. mcp_servers lists the servers; mcp_tools gives a tool's arguments. A local server starts the first time it is used, in this folder; Next Term reaches a remote one itself. Either gets its keys from Next Term's Secrets, never through you. A result over 100,000 characters is cut, and says so.",
                       inputSchema: #"{"type": "object", "properties": {\#(serverArgument), "tool": {"type": "string", "description": "The tool's name, as mcp_tools lists it."}, "arguments": {"type": "object", "description": "The tool's arguments, as its input schema has them."}}, "required": ["server", "tool"], "additionalProperties": false}"#,
                       readOnly: false, destructive: true, idempotent: false, timeout: 60, openWorld: true, alwaysLoad: true),
    ]

    public static func isCatalogTool(_ name: String) -> Bool { tools.contains { $0.name == name } }

    // MARK: answers

    /// A tool result with one text, for the agent.
    public static func text(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    /// The most characters of a result the agent gets: about the 25,000 tokens Claude Code takes of a tool's output.
    public static let resultLimit = 100_000

    /// A server's result as the agent gets it: its content in order while it fits in `limit` characters (a text cut
    /// where the limit falls, an image or other block counted by its data), then a last text that says what was cut;
    /// `structuredContent` only when it fits too. Anything else of the result, `isError` included, stays.
    public static func fit(_ result: [String: Any], limit: Int = resultLimit) -> [String: Any] {
        var fitted = result
        let content = result["content"] as? [[String: Any]] ?? []
        var kept: [[String: Any]] = []
        var used = 0, total = 0, cut = false
        for block in content {
            let size = characters(block)
            total += size
            guard !cut else { continue }
            if used + size <= limit {
                kept.append(block)
                used += size
            } else if block["type"] as? String == "text", let text = block["text"] as? String, limit - used > 0 {
                var part = block
                part["text"] = String(text.prefix(limit - used))
                kept.append(part)
                used = limit
                cut = true
            } else {
                cut = true
            }
        }
        if let structured = result["structuredContent"], characters(structured) + used > limit {
            fitted["structuredContent"] = nil
            total += characters(structured)
            cut = true
        }
        if cut {
            kept.append(["type": "text", "text": "[Next Term cut this result at \(limit.formatted()) characters; it had "
                + "\(total.formatted()). Ask the tool for less: a page, a filter or a smaller range.]"])
        }
        if result["content"] != nil || cut { fitted["content"] = kept }
        return fitted
    }

    /// A block's size: its text's characters, or its JSON's for anything else.
    static func characters(_ value: Any) -> Int {
        if let block = value as? [String: Any], block["type"] as? String == "text", let text = block["text"] as? String {
            return text.count
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) else { return 0 }
        return data.count
    }

    /// A tool as mcp_tools lists it: its name, title and description's first 300 characters.
    static func brief(_ tool: [String: Any]) -> [String: Any] {
        var item: [String: Any] = ["name": tool["name"] as? String ?? ""]
        if let title = tool["title"] as? String { item["title"] = title }
        if let description = tool["description"] as? String {
            item["description"] = description.count > 300 ? String(description.prefix(300)) + "…" : description
        }
        return item
    }

    /// Whether every word of `query` is in the tool's name, title or description, ignoring case.
    static func matches(_ tool: [String: Any], words: [String]) -> Bool {
        let text = ["name", "title", "description"].compactMap { tool[$0] as? String }.joined(separator: " ").lowercased()
        return words.allSatisfy { text.contains($0) }
    }
}

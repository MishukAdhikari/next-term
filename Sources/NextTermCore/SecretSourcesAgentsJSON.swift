import Foundation

// Agents' JSON configs the MCP-config import doesn't rewrite, each known by members only it has: Zed's
// `context_servers` (each server's `env`, the older `command.env`, an extension's `settings`, a remote one's
// `headers`), Claude Code's settings' `env`, opencode's providers' keys and its servers' `environment` and `headers`,
// and a file of `mcpServers` (Devin Desktop's `mcp_config.json`) with each server's `env` and `headers`. The rest of
// the file is read as any JSON is, so no key in it goes unseen. Each row says the file still holds the key.

extension SecretSources {
    /// Claude Code's settings' own members, beside `env`: ones another tool's file doesn't have at its top.
    static let claudeSettingsMembers: Set<String> = [
        "permissions", "hooks", "apiKeyHelper", "statusLine", "enabledPlugins", "includeCoAuthoredBy",
        "cleanupPeriodDays", "outputStyle", "forceLoginMethod", "enableAllProjectMcpServers", "awsAuthRefresh",
        "enabledMcpjsonServers", "disabledMcpjsonServers",
    ]

    /// The members an MCP server's entry has, in the shapes agents write.
    static let serverMembers: Set<String> = [
        "command", "args", "url", "serverUrl", "httpUrl", "type", "env", "environment", "headers", "transport",
        "source", "settings",
    ]

    /// The agent whose config a JSON object is, with its values read into `walk`, the rest of the file's too; nil for
    /// any other JSON.
    static func jsonAgent(_ root: JSONC.Object, file: String, walk: inout JSONWalk) -> String? {
        let lower: String = file.lowercased()
        walk.note = .stillInFile
        let agent: String
        if let servers = servers(root, "context_servers") {
            for server in servers { zedServer(server, walk: &walk) }
            agent = "Zed"
        } else if let env = root.member("env"), case .object = env.value,
                  isClaudeSettings(root, file: lower, walk: walk) {
            walk.env(env.value, place: "env", scope: "")
            agent = "Claude Code"
        } else if isOpencode(root, file: lower, walk: walk) {
            opencodeFound(root, walk: &walk)
            agent = "opencode"
        } else if let servers = servers(root, "mcpServers") {
            for server in servers {
                guard case .object(let entry) = server.value else { continue }
                let place: String = "mcpServers." + server.key
                walk.env(entry.member("env")?.value, place: place + ".env", scope: place)
                let headers: JSONC.Value? = entry.member("headers")?.value
                walk.headers(headers, server: server.key, place: place + ".headers", scope: place)
            }
            agent = lower == "mcp_config.json" ? "Devin Desktop" : "an MCP client"
        } else {
            walk.note = nil
            return nil
        }
        walk.value(.object(root), at: JSONPath(), section: "", line: nil)
        return agent
    }

    /// The servers under `key` at the top, when at least one of them is an object with a server's member.
    static func servers(_ root: JSONC.Object, _ key: String) -> [JSONC.Member]? {
        guard let member = root.member(key), case .object(let servers) = member.value else { return nil }
        let isServer = { (server: JSONC.Member) -> Bool in
            guard case .object(let entry) = server.value else { return false }
            return entry.members.contains { (field: JSONC.Member) -> Bool in
                SecretSources.serverMembers.contains(field.key)
            }
        }
        return servers.members.contains(where: isServer) ? servers.members : nil
    }

    /// One of Zed's servers: its `env`, the older `command.env`, an extension's `settings`, and a remote one's
    /// `headers`.
    static func zedServer(_ server: JSONC.Member, walk: inout JSONWalk) {
        guard case .object(let entry) = server.value else { return }
        let place: String = "context_servers." + server.key
        walk.env(entry.member("env")?.value, place: place + ".env", scope: place)
        if let command = entry.member("command"), case .object(let shape) = command.value {
            walk.env(shape.member("env")?.value, place: place + ".command.env", scope: place)
        }
        walk.env(entry.member("settings")?.value, place: place + ".settings", scope: place)
        walk.headers(entry.member("headers")?.value, server: server.key, place: place + ".headers", scope: place)
    }

    /// Claude Code's settings: named `settings.json` or `settings.local.json`, with its schema, or with one of its own
    /// members.
    static func isClaudeSettings(_ root: JSONC.Object, file: String, walk: JSONWalk) -> Bool {
        if file == "settings.json" || file == "settings.local.json" { return true }
        if root.members.contains(where: { (member: JSONC.Member) -> Bool in claudeSettingsMembers.contains(member.key) }) {
            return true
        }
        let schema: String? = root.member("$schema")?.value.object(in: walk.text) as? String
        return schema?.contains("claude-code-settings") ?? false
    }
}

import Foundation

// Agents' JSON configs the MCP-config import doesn't rewrite, by their members: Zed's `context_servers` (each server's
// `env`, the older `command.env`, and an extension's `settings`), Claude Code's settings `env`, and a file of
// `mcpServers` (Devin Desktop's `mcp_config.json`). Only those values are read; the rest of the file is the agent's
// settings. Each row says the file still holds the key.

extension SecretSources {
    /// Claude Code's settings' own members, beside `env`.
    static let claudeSettingsMembers: Set<String> = [
        "permissions", "hooks", "model", "apiKeyHelper", "statusLine", "enabledPlugins", "includeCoAuthoredBy",
        "cleanupPeriodDays", "outputStyle", "forceLoginMethod", "enableAllProjectMcpServers", "awsAuthRefresh",
    ]

    /// The agent whose config a JSON object is, with its values read into `walk`; nil for any other JSON.
    static func jsonAgent(_ root: JSONC.Object, file: String, walk: inout JSONWalk) -> String? {
        let lower: String = file.lowercased()
        if let member = root.member("context_servers"), case .object(let servers) = member.value {
            for server in servers.members {
                guard case .object(let entry) = server.value else { continue }
                let place: String = "context_servers." + server.key
                walk.env(entry.member("env")?.value, place: place + ".env", scope: place, note: .stillInFile)
                if let command = entry.member("command"), case .object(let shape) = command.value {
                    walk.env(shape.member("env")?.value, place: place + ".command.env", scope: place,
                             note: .stillInFile)
                }
                walk.env(entry.member("settings")?.value, place: place + ".settings", scope: place, note: .stillInFile)
            }
            return "Zed"
        }
        if let env = root.member("env"), case .object = env.value, isClaudeSettings(root, file: lower, walk: walk) {
            walk.env(env.value, place: "env", scope: "", note: .stillInFile)
            return "Claude Code"
        }
        if let member = root.member("mcpServers"), case .object(let servers) = member.value {
            for server in servers.members {
                guard case .object(let entry) = server.value else { continue }
                let place: String = "mcpServers." + server.key
                walk.env(entry.member("env")?.value, place: place + ".env", scope: place, note: .stillInFile)
            }
            return lower == "mcp_config.json" ? "Devin Desktop" : "an MCP client"
        }
        return nil
    }

    /// Claude Code's settings: named `settings.json` or `settings.local.json`, with one of its own members, or with its
    /// schema.
    static func isClaudeSettings(_ root: JSONC.Object, file: String, walk: JSONWalk) -> Bool {
        if file == "settings.json" || file == "settings.local.json" { return true }
        if root.members.contains(where: { (member: JSONC.Member) -> Bool in claudeSettingsMembers.contains(member.key) }) {
            return true
        }
        let schema: String? = root.member("$schema")?.value.object(in: walk.text) as? String
        return schema?.contains("claude-code-settings") ?? false
    }
}

import Foundation

/// The editor link to Claude Code (and opencode, which speaks its protocol), Gemini CLI, Qwen Code and
/// GitHub Copilot CLI (ClaudeIDEServer, GeminiIDEServer, CopilotIDEServer).
public enum IDELink {
    /// Files whose selection and place among the open files are never shared: environment files
    /// (`.env`, `.env.*`, `*.env`, `.flaskenv`) except the committed `.env.example`, keys, and two
    /// credentials files. The MCP tools refuse a longer list (MCPProjects.secretReason).
    public static func isSensitive(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if EnvFile.isEnvFile(named: name) { return name != ".env.example" }
        return name.hasSuffix(".pem") || name.hasSuffix(".key") || name == "id_rsa" || name == "id_ed25519"
            || name == ".npmrc" || name == ".netrc"
    }

    /// Compares a secret in constant time (no early exit at the first different byte).
    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(x, y) { difference |= left ^ right }
        return difference == 0
    }
}

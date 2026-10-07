import Foundation

/// The editor link to Claude Code, Gemini CLI and Qwen Code (ClaudeIDEServer, GeminiIDEServer).
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
}

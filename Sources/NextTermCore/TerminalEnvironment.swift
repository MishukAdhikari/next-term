import Foundation

/// A new tab starts as a fresh terminal, not as a child of whatever launched Next Term. Agents and
/// editors mark their own child processes with variables: inherited by a tab, they make `claude` think
/// it is a sub-agent (it turns transcript saving off), hand every shell another program's secret
/// (CLAUDE_CODE_MESSAGING_TOKEN), point git at an editor's password helper that is gone once the
/// editor quits, or make tools believe they run inside VS Code or a JetBrains IDE. Those go; settings a
/// user gives on purpose (ANTHROPIC_API_KEY, CLAUDE_CONFIG_DIR, CODEX_HOME…) stay.
public enum TerminalEnvironment {
    /// Exact names to drop.
    static let markers: Set<String> = [
        // The terminal Next Term was launched from.
        "TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE", "WINDOWID", "__CFBundleIdentifier",
        "TERMINAL_EMULATOR", "KITTY_WINDOW_ID", "ALACRITTY_WINDOW_ID", "WEZTERM_PANE", "GHOSTTY_RESOURCES_DIR",
        // Claude Code's session (its Bash tool and sub-agents).
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_EFFORT", "CLAUDE_PID",
        // IDE links left by another editor's terminal (Next Term sets its own).
        "CLAUDE_CODE_SSE_PORT", "ENABLE_IDE_INTEGRATION", "CLAUDE_CODE_AUTO_CONNECT_IDE",
        "GEMINI_CLI_IDE_SERVER_PORT", "GEMINI_CLI_IDE_WORKSPACE_PATH", "GEMINI_CLI_IDE_AUTH_TOKEN", "GEMINI_CLI_IDE_PID",
        "QWEN_CODE_IDE_SERVER_PORT", "QWEN_CODE_IDE_WORKSPACE_PATH",
        // Codex's and Gemini's sandboxed shells.
        "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "GEMINI_CLI",
    ]

    /// Prefixes to drop: VS Code's terminal and its git integration.
    static let prefixes = ["VSCODE_"]

    public static func clean(_ environment: [String: String]) -> [String: String] {
        var env = environment.filter { key, _ in !markers.contains(key) && !prefixes.contains { key.hasPrefix($0) } }
        // Git's password prompt pointed at VS Code's helper: gone with VS Code.
        if let askpass = env["GIT_ASKPASS"], askpass.contains("Visual Studio Code") || askpass.contains("vscode") || askpass.contains("askpass.sh") {
            env.removeValue(forKey: "GIT_ASKPASS")
        }
        return env
    }
}

import Foundation
import Testing
@testable import NextTermCore

@Suite struct TerminalEnvironmentTests {
    @Test func aTabStartsFresh() {
        let inherited = [
            "PATH": "/usr/bin", "HOME": "/Users/me", "ANTHROPIC_API_KEY": "sk-keep", "CLAUDE_CONFIG_DIR": "/Users/me/.claude-work",
            "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_MESSAGING_TOKEN": "secret", "CLAUDE_CODE_SESSION_ID": "x",
            "CLAUDE_CODE_SSE_PORT": "61000", "VSCODE_IPC_HOOK_CLI": "/tmp/vscode.sock", "VSCODE_GIT_ASKPASS_MAIN": "x",
            "GIT_ASKPASS": "/Applications/Visual Studio Code.app/Contents/Resources/app/extensions/git/dist/askpass.sh",
            "TERMINAL_EMULATOR": "JetBrains-JediTerm", "CODEX_SANDBOX": "seatbelt", "CODEX_HOME": "/Users/me/.codex",
            "TERM_SESSION_ID": "w0t0p0",
        ]
        let env = TerminalEnvironment.clean(inherited)
        #expect(env == ["PATH": "/usr/bin", "HOME": "/Users/me", "ANTHROPIC_API_KEY": "sk-keep",
                        "CLAUDE_CONFIG_DIR": "/Users/me/.claude-work", "CODEX_HOME": "/Users/me/.codex"])
        // A user's own askpass helper stays.
        #expect(TerminalEnvironment.clean(["GIT_ASKPASS": "/opt/homebrew/bin/my-askpass"])["GIT_ASKPASS"] == "/opt/homebrew/bin/my-askpass")
    }
}

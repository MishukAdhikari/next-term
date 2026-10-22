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
        // OpenCode's editor link and the marks it puts on its own children go; settings a user gives it stay.
        let opencode = [
            "OPENCODE_EDITOR_SSE_PORT": "4100", "OPENCODE_CALLER": "vscode", "_EXTENSION_OPENCODE_PORT": "4101",
            "OPENCODE": "1", "OPENCODE_PID": "4242", "OPENCODE_SERVER_PASSWORD": "made-up", "OPENCODE_CONFIG": "/Users/me/oc.json",
        ]
        #expect(TerminalEnvironment.clean(opencode) == ["OPENCODE_SERVER_PASSWORD": "made-up", "OPENCODE_CONFIG": "/Users/me/oc.json"])
        // A user's own askpass helper stays.
        #expect(TerminalEnvironment.clean(["GIT_ASKPASS": "/opt/homebrew/bin/my-askpass"])["GIT_ASKPASS"] == "/opt/homebrew/bin/my-askpass")
    }
}

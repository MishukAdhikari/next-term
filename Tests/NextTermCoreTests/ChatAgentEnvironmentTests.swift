import Foundation
import Testing
@testable import NextTermCore

/// A chat tab's agent environment and status (plan 037 KTD7, KTD9): the login shell's listing read whole, what belongs to
/// one shell or to Next Term left out, a Next Term tab's own variables added, and the fallback when the probe failed.
@Suite struct ChatAgentEnvironmentTests {
    @Test func theListingReadsNamesValuesAndValuesWithLineBreaks() {
        let listing = "PATH=/opt/homebrew/bin:/usr/bin\nNOTE=first line\nsecond = line\nEMPTY=\nURL=https://x.test/?a=b\n"
        let env = ChatAgentEnvironment.parse(listing: listing)
        #expect(env?["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(env?["NOTE"] == "first line\nsecond = line")
        #expect(env?["EMPTY"] == "")
        #expect(env?["URL"] == "https://x.test/?a=b")
        #expect(env?.count == 4)
        #expect(ChatAgentEnvironment.parse(listing: "") == nil)
        #expect(ChatAgentEnvironment.parse(listing: "\n\n") == nil)
    }

    @Test func theLoginEnvironmentLosesTheShellsOwnAndNextTermsVariables() {
        let login = ["PATH": "/Users/u/.nvm/bin:/usr/bin", "ANTHROPIC_BASE_URL": "https://proxy.test", "CODEX_HOME": "/Users/u/.codex",
                     "PWD": "/Users/u", "OLDPWD": "/", "SHLVL": "2", "_": "/usr/bin/env", "ZDOTDIR": "/x",
                     "NEXTTERM_NONCE": "n", "NEXTTERM_USER_ZDOTDIR": "/y", "CLAUDECODE": "1", "LANG": "de_DE.UTF-8"]
        let (env, fromLogin) = ChatAgentEnvironment.make(login: login, app: ["PATH": "/usr/bin", "HOME": "/app"],
                                                         loginPath: ["/ignored"], socket: "/tmp/nt.sock",
                                                         toolFolder: "/Apps/NextTerm.app/Contents/Resources/bin", version: "1.2.3")
        #expect(fromLogin)
        #expect(env["PATH"] == "/Users/u/.nvm/bin:/usr/bin:/Apps/NextTerm.app/Contents/Resources/bin")
        #expect(env["ANTHROPIC_BASE_URL"] == "https://proxy.test")
        #expect(env["CODEX_HOME"] == "/Users/u/.codex")
        for gone in ["PWD", "OLDPWD", "SHLVL", "_", "ZDOTDIR", "NEXTTERM_NONCE", "NEXTTERM_USER_ZDOTDIR", "CLAUDECODE", "HOME"] {
            #expect(env[gone] == nil, "\(gone) stays out")
        }
        #expect(env[MCPServer.socketVariable] == "/tmp/nt.sock")
        #expect(env["TERM_PROGRAM"] == "NextTerm")
        #expect(env["TERM_PROGRAM_VERSION"] == "1.2.3")
        #expect(env["LANG"] == "de_DE.UTF-8")
    }

    @Test func withoutTheLoginShellTheAppsCleanEnvironmentGetsTheLoginPath() {
        let app = ["PATH": "/usr/bin:/bin", "HOME": "/Users/u", "TERM_SESSION_ID": "x", NextTermKey.socket: "/old.sock"]
        let (env, fromLogin) = ChatAgentEnvironment.make(login: nil, app: app, loginPath: ["/opt/homebrew/bin", "/usr/bin"],
                                                         socket: nil, toolFolder: "/usr/bin", version: "dev")
        #expect(!fromLogin)
        // The tool's folder is on PATH already: not added twice.
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(env["HOME"] == "/Users/u")
        #expect(env["TERM_SESSION_ID"] == nil)
        // No control socket running: none given, and the app's own isn't handed on.
        #expect(env[MCPServer.socketVariable] == nil)
        #expect(env["LANG"] == "en_US.UTF-8")
    }

    @Test func reportsBecomeTheTabsActivity() {
        #expect(ChatHostStatus.activity(state: "working", question: nil) == .working)
        #expect(ChatHostStatus.activity(state: "attention", question: "Claude Code asks to run ls") == .asking("Claude Code asks to run ls"))
        #expect(ChatHostStatus.activity(state: "attention", question: "") == .asking(ProgramStatus.words(for: .permission)))
        #expect(ChatHostStatus.activity(state: "done", question: nil) == .ready)
        #expect(ChatHostStatus.activity(state: "idle", question: "left over") == .ready)
    }

    @Test func theHostsStateFollowsItsSessionInOrder() {
        #expect(ChatHostStatus.state(ended: true, waiting: true, asking: true, working: true, ready: true) == .ended)
        #expect(ChatHostStatus.state(ended: false, waiting: true, asking: false, working: false, ready: false) == .trusting)
        #expect(ChatHostStatus.state(ended: false, waiting: false, asking: true, working: true, ready: true) == .asking)
        #expect(ChatHostStatus.state(ended: false, waiting: false, asking: false, working: true, ready: true) == .working)
        #expect(ChatHostStatus.state(ended: false, waiting: false, asking: false, working: false, ready: true) == .ready)
        #expect(ChatHostStatus.state(ended: false, waiting: false, asking: false, working: false, ready: false) == .starting)
    }
}

private enum NextTermKey {
    static let socket = MCPServer.socketVariable
}

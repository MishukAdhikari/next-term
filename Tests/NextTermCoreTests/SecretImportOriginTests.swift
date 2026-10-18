import Foundation
import Testing
@testable import NextTermCore

/// Where `nxtrm secret import`'s keys came from, as the sheet says it: who may have seen them, whether the tab ran a
/// preset's line as typed, and how to end the password manager's session after. Commands here are made up.
@Suite struct SecretImportOriginTests {
    typealias P = SecretImportPipe
    typealias Preset = SecretImportPreset
    static let nxtrm = ["/Applications/Next Term.app/Contents/Resources/bin/nxtrm"]

    static func line(_ preset: Preset) -> String {
        preset.line(nxtrm: nxtrm, shell: "zsh") ?? ""
    }

    /// The Bitwarden line with its `; bw lock` taken off, as a user might edit it.
    static var unlockedBitwarden: String {
        String(line(.bitwarden).dropLast("; bw lock".count))
    }

    @Test func theWarningSaysWhoMayHaveSeenTheKeys() {
        #expect(P.originWarning(agent: "Claude Code", inTab: true) == P.agentWarning)
        #expect(P.originWarning(agent: "Codex", inTab: false) == P.agentWarning)
        #expect(P.originWarning(agent: nil, inTab: false) == P.untracedWarning)
        #expect(P.originWarning(agent: nil, inTab: true) == nil)
        #expect(P.agentWarning == "An agent ran this command. It may have seen these keys.")
        #expect(P.untracedWarning.hasPrefix("Next Term couldn\u{2019}t tell which tab ran this command."))
    }

    /// Who ran the importer goes by the agent above it and the tab it runs in. Only the user, in a tab of Next Term's,
    /// is handled as the user: a run no tab is above (`( … &)`, nohup, another terminal app) is handled as an agent's.
    @Test func whoRanTheImporterGoesByTheAgentAboveAndTheTab() {
        #expect(P.runner(agent: "Claude Code", inTab: true) == .agent)
        #expect(P.runner(agent: "Codex", inTab: false) == .agent)
        #expect(P.runner(agent: nil, inTab: false) == .untraced)
        #expect(P.runner(agent: nil, inTab: true) == .user)
        #expect(P.Runner.user.isUser && !P.Runner.agent.isUser && !P.Runner.untraced.isUser)
        #expect(P.Runner.user.mayStartMove)
        #expect(!P.Runner.agent.mayStartMove && !P.Runner.untraced.mayStartMove)
        // The warning follows the same rule.
        #expect(P.originWarning(agent: nil, inTab: false) == P.untracedWarning)
    }

    /// A run in a tab an agent drives (one it opened, or typed or pressed keys in, and the user hasn't typed in since)
    /// is the agent's, though no agent runs above the importer: it gets the agent's warning, the sheet without the
    /// keyboard, and no move. A tab the user has typed in since is theirs again; with no tab, there is none to drive.
    @Test func aRunInATabAnAgentDrivesIsTheAgents() {
        #expect(P.runner(agent: nil, inTab: true, driven: true) == .agent)
        #expect(P.runner(agent: "Claude Code", inTab: true, driven: true) == .agent)
        #expect(P.runner(agent: nil, inTab: true, driven: false) == .user)
        #expect(P.runner(agent: "Codex", inTab: true, driven: false) == .agent)
        #expect(P.runner(agent: nil, inTab: false, driven: true) == .untraced)
        #expect(P.runner(agent: nil, inTab: true) == P.runner(agent: nil, inTab: true, driven: false))
        let driven: P.Runner = P.runner(agent: nil, inTab: true, driven: true)
        #expect(!driven.isUser && !driven.mayStartMove)
        #expect(P.originWarning(agent: nil, inTab: true, driven: true) == P.agentWarning)
        #expect(P.originWarning(agent: nil, inTab: true, driven: false) == nil)
        #expect(P.originWarning(agent: nil, inTab: false, driven: true) == P.untracedWarning)
        #expect(P.originWarning(agent: nil, inTab: true) == nil)
    }

    /// An MCP config given to an agent's run, or to one no tab ran, is refused before anything opens: moving its keys
    /// rewrites the file, which only the user starts. The user's own run opens the MCP-config import for it, and any
    /// other file is a copy for every run. Files, the server and its key are made up, under a temporary home.
    @Test func onlyTheUsersOwnRunMovesKeysOutOfAnMCPConfig() {
        let home = SecretImportFixtures.Home()
        defer { home.remove() }
        let value: String = "made-up-value-" + UUID().uuidString.lowercased()
        let server: String = #"{"command": "made-up-server", "env": {"MADE_UP_TOKEN": "\#(value)"}}"#
        let mcp: String = home.write("made-up-project/.mcp.json", #"{"mcpServers": {"made-up": \#(server)}}"#)
        let env: String = home.write("made-up-project/.env", "MADE_UP_TOKEN=\(value)\n")
        for runner in [P.Runner.agent, .untraced, .user] {
            let config: SecretSources.Picked? = P.opens(SecretSources.readPicked(mcp, home: home.path), runner: runner)
            switch config {
            case .move(let source, _)?:
                #expect(runner == .user && source.path == mcp, "\(runner)")
            case .copy?:
                Issue.record("an MCP config is never a copy: \(runner)")
            case nil:
                #expect(runner != .user, "\(runner)")
            }
            let file: SecretSources.Picked? = P.opens(SecretSources.readPicked(env, home: home.path), runner: runner)
            guard case .copy(let report)? = file else {
                Issue.record("a .env is a copy for every run: \(runner)")
                continue
            }
            let names: [String] = report.rows.map(\.name) + report.notKeys.map(\.name)
            #expect(report.unreadable == nil && names == ["MADE_UP_TOKEN"], "\(runner)")
        }
        // Typed into the user's tab by an agent that drives it: refused, as the agent's own run is.
        let typed: P.Runner = P.runner(agent: nil, inTab: true, driven: true)
        #expect(P.opens(SecretSources.readPicked(mcp, home: home.path), runner: typed) == nil)
    }

    @Test func aPresetIsNamedOnlyForItsLineAsTyped() {
        for preset in Preset.allCases {
            let typed: String = Self.line(preset)
            #expect(!typed.isEmpty)
            #expect(Preset.ran(typed, as: typed), "\(preset)")
            #expect(Preset.ran("  " + typed + "\n", as: typed), "\(preset)")
            #expect(!Preset.ran("", as: typed), "\(preset)")
            #expect(!Preset.ran("cat made-up.json | nxtrm secret import -", as: typed), "\(preset)")
        }
        // The user's own edits: the lock taken off, or Secrets' wrapper put in front of bws.
        #expect(!Preset.ran(Self.unlockedBitwarden, as: Self.line(.bitwarden)))
        let wrapped: String = "nxtrm secret run BWS_ACCESS_TOKEN -- " + Self.line(.bws)
        #expect(!Preset.ran(wrapped, as: Self.line(.bws)))
        #expect(!Preset.ran("", as: ""))
    }

    @Test func aLineEndsWithBwLockOnlyWhenItRunsWhateverCameBefore() {
        #expect(Preset.endsWithLock(Self.line(.bitwarden)))
        #expect(Preset.endsWithLock("bw list items | nxtrm secret import -;bw lock;"))
        #expect(Preset.endsWithLock("bw list items | nxtrm secret import -\nbw lock"))
        #expect(Preset.endsWithLock("bw list items | nxtrm secret import - ;  bw   lock  "))
        #expect(!Preset.endsWithLock(Self.unlockedBitwarden))
        // `&&` skips it when the import ends with nothing imported, which exits 1.
        #expect(!Preset.endsWithLock("bw list items | nxtrm secret import - && bw lock"))
        #expect(!Preset.endsWithLock("bw lock; echo made-up"))
        #expect(!Preset.endsWithLock("bw lock --help"))
        #expect(!Preset.endsWithLock(""))
    }

    @Test func bitwardenIsSaidLockedOnlyWhenTheLineEndsWithBwLock() {
        func said(_ command: String?, _ tab: Preset?) -> String? {
            Preset.sessionLine(format: .bitwarden, command: command, tabPreset: tab, inTab: true)
        }
        #expect(said(Self.line(.bitwarden), .bitwarden) == Preset.lockedLine)
        #expect(said(Self.line(.bitwarden), nil) == Preset.lockedLine)
        #expect(said(Self.unlockedBitwarden, .bitwarden) == Preset.unlockedLine)
        #expect(said(Self.unlockedBitwarden, nil) == Preset.unlockedLine)
        // A shell that doesn't say what it ran: only the preset's tab gets a line, and it says if.
        #expect(said(nil, .bitwarden) == Preset.lockedIfLine)
        #expect(said("  ", .bitwarden) == Preset.lockedIfLine)
        #expect(said(nil, nil) == nil)
        #expect(said(nil, .onePassword) == nil)
        // An export piped in by cat: no session to end.
        #expect(said("cat made-up-export.json | nxtrm secret import --from bitwarden -", nil) == nil)
        #expect(Preset.lockedLine == "Bitwarden is locked again.")
    }

    @Test func onePasswordsLineNeedsItsTabAndOp() {
        func said(_ command: String?, inTab: Bool) -> String? {
            Preset.sessionLine(format: .onePassword, command: command, tabPreset: nil, inTab: inTab)
        }
        #expect(said(Self.line(.onePassword), inTab: true) == Preset.onePasswordLine)
        #expect(said("op item get made-up --format json --reveal | nxtrm secret import -", inTab: true) != nil)
        #expect(said(nil, inTab: true) == Preset.onePasswordLine)
        #expect(said(Self.line(.onePassword), inTab: false) == nil)
        #expect(said("cat made-up-items.json | nxtrm secret import --from 1password -", inTab: true) == nil)
        #expect(Preset.onePasswordLine == "Close this tab to end 1Password\u{2019}s authorization for it.")
    }

    @Test func otherFormatsHaveNoSessionToEnd() {
        let formats: [SecretSources.Format] = [.bws, .env, .json, .toml, .yaml, .csv]
        for format in formats {
            let line: String? = Preset.sessionLine(format: format, command: Self.line(.bws), tabPreset: .bws, inTab: true)
            #expect(line == nil, "\(format)")
        }
    }
}

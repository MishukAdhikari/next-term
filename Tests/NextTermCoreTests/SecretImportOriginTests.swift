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

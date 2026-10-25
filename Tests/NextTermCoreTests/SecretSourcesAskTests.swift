import Foundation
import Testing
@testable import NextTermCore

/// import_secrets before anything opens: its arguments, the file it names, and the audit lines it leaves. Files are made
/// up, under a temporary home.
@Suite struct SecretSourcesAskTests {
    typealias I = SecretImportFixtures
    typealias Asked = Result<SecretSources.Asked, SecretSources.AskRefusal>

    static func refusal(_ note: String) -> Asked { .failure(SecretSources.AskRefusal(note)) }

    @Test func aCallNamesOneFileOrOnePasswordManager() {
        let usage: Asked = Self.refusal(SecretSources.askUsage)
        #expect(SecretSources.askUsage == "Give path (a file of keys) or source (1password, bitwarden or bws), not both.")
        // Neither, both, or only empty ones.
        #expect(SecretSources.asked(path: nil, source: nil) == usage)
        #expect(SecretSources.asked(path: "", source: "") == usage)
        #expect(SecretSources.asked(path: "/a/.env", source: "bws") == usage)
        // A path that isn't text counts as none.
        #expect(SecretSources.asked(path: 7, source: nil) == usage)
        #expect(SecretSources.asked(path: 7, source: "bws") == .success(.source(.bws)))
        // A source by its preset's name only.
        #expect(SecretSources.asked(path: nil, source: "1password") == .success(.source(.onePassword)))
        #expect(SecretSources.asked(path: "", source: "bitwarden") == .success(.source(.bitwarden)))
        let source: Asked = Self.refusal(SecretSources.askSourceUsage)
        #expect(SecretSources.askSourceUsage == "Give source as 1password, bitwarden or bws.")
        for name in ["lastpass", "1Password", "op", "bw", " bws"] {
            #expect(SecretSources.asked(path: nil, source: name) == source, "\(name)")
        }
    }

    @Test func aPathHasNoNULAndAtMost4096Characters() {
        let path: Asked = Self.refusal(SecretSources.askPathUsage)
        #expect(SecretSources.askPathUsage == "Give path: a file's path, at most 4,096 characters.")
        #expect(SecretSources.asked(path: "/a/.env\0.txt", source: nil) == path)
        #expect(SecretSources.asked(path: "\0", source: nil) == path)
        let longest: String = "/" + String(repeating: "a", count: SecretSources.maxPathLength - 1)
        #expect(SecretSources.asked(path: longest, source: nil) == .success(.path(longest)))
        #expect(SecretSources.asked(path: longest + "a", source: nil) == path)
        // A relative path is the tab's to resolve: it comes back as given.
        #expect(SecretSources.asked(path: ".env.local", source: nil) == .success(.path(".env.local")))
    }

    /// An agent's MCP config goes to the user's own MCP-config import, by any path to it; any other file is the one to
    /// open, and a path refusal keeps its class.
    @Test func anAgentsMCPConfigIsLeftToTheUsersOwnImport() throws {
        let home = I.Home()
        defer { home.remove() }
        let claude: String = home.write(".claude.json", "{}")
        let project: String = home.write("triage-agent/.mcp.json", "{}")
        let env: String = home.write("shop-web/.env.local", "A=1\n")
        let vault: String = home.file("Library/Application Support/Next Term/Secrets")
        func check(_ path: String) -> Result<String, SecretSources.AskRefusal> {
            SecretSources.checkAsked(path, home: home.path, vaultFolder: vault, folder: home.file("shop-web"))
        }
        let moves: Result<String, SecretSources.AskRefusal> = .failure(SecretSources.AskRefusal(SecretSources.moveTargetNote))
        #expect(SecretSources.moveTargetNote.hasPrefix("That file is an agent's MCP config"))
        #expect(check(claude) == moves)
        #expect(check(project) == moves)
        #expect(check("~/.claude.json") == moves)
        #expect(check("/System/Volumes/Data" + claude) == moves)
        #expect(check(".env.local") == .success(env))
        let missing = SecretSources.AskRefusal(SecretSources.PathRefusal.notFound.note)
        #expect(check("~/.ssh/config") == .failure(missing))
        #expect(check("/System/Volumes/Data" + home.file(".ssh/config")) == .failure(missing))
        // The configs' home may be another (the self-test's): the agents' configs are looked for there.
        let other = I.Home()
        defer { other.remove() }
        let elsewhere: Result<String, SecretSources.AskRefusal> = SecretSources.checkAsked(
            claude, home: home.path, vaultFolder: vault, folder: nil, configHome: other.path)
        #expect(elsewhere == .success(claude))
    }

    /// The audit lines' command names the file and the agent's reason. With a reason, a long path keeps its end, so the
    /// reason still fits in the log's 300 characters.
    @Test func theAuditCommandKeepsTheReasonPastALongPath() throws {
        let reason: String = "Move the app's keys out of .env.local"
        let short: String = SecretSources.askedCommand("/Users/someone/shop-web/.env.local", reason: reason)
        #expect(short == "import_secrets /Users/someone/shop-web/.env.local (reason: Move the app's keys out of .env.local)")
        #expect(SecretSources.askedCommand("bws", reason: "  ") == "import_secrets bws")
        #expect(SecretSources.askedCommand("bws", reason: nil) == "import_secrets bws")
        let deep: String = "/Users/someone/" + String(repeating: "nested-folder/", count: 30) + "shop-web/.env.local"
        #expect(deep.count > 400)
        #expect(SecretSources.askedCommand(deep, reason: nil) == "import_secrets " + deep)
        let line = SecretAudit.Line(event: .import, names: [], command: SecretSources.askedCommand(deep, reason: reason))
        let written = try #require(SecretAudit.lines(in: SecretAudit.encode(line)).first?.command)
        #expect(written.count <= SecretAudit.maxCommand)
        #expect(written.contains("nested-folder/shop-web/.env.local (reason: \(reason))"), "\(written)")
        #expect(written.hasPrefix("import_secrets \u{2026}"))
        // A reason too long for the line keeps its start.
        let long: String = "Move every key " + String(repeating: "and more ", count: 60)
        let cut = SecretAudit.Line(event: .import, names: [], command: SecretSources.askedCommand(deep, reason: long))
        let cutText = try #require(SecretAudit.lines(in: SecretAudit.encode(cut)).first?.command)
        #expect(cutText.contains("(reason: Move every key and more"))
    }

    /// An import that copied nothing in and wasn't declined leaves an audit line too: its class only, never more of the
    /// file. A copy-in writes its own line, and a decline the queue's.
    @Test func anImportThatCopiedNothingInStillLeavesAnAuditLine() {
        #expect(SecretSources.askedAuditOutcome(.nothingFound(format: .env)) == "nothing imported: no key found in a .env file")
        #expect(SecretSources.askedAuditOutcome(.nothingFound(format: .bws))
                == "nothing imported: no key found in a Bitwarden Secrets Manager list")
        #expect(SecretSources.askedAuditOutcome(.unreadable(.encryptedExport))
                == "nothing imported: an encrypted Bitwarden export")
        #expect(SecretSources.askedAuditOutcome(.unreadable(.notTOML(line: 4))) == "nothing imported: not TOML Next Term can read")
        #expect(SecretSources.askedAuditOutcome(.declined) == nil)
        let imported = SecretSources.CopyInOutcome.imported(["AE9_KEY"], replaced: [], found: 2, format: .env)
        #expect(SecretSources.askedAuditOutcome(imported) == nil)
    }
}

import Foundation
import Testing
@testable import NextTermCore

/// A multi-line string ends only at three of its own quotes. Ended at any three like characters ("...", "---", three
/// spaces, the other quotes), a real env key was hidden, a key inside a string was listed and moved, or a valid file
/// was reported as one Next Term can't read. Each file here is TOML Codex reads (checked with Python's tomllib).
@Suite struct SecretImportTOMLStringTests {
    func scanned(_ text: String) -> SecretImport.Scan {
        let home = F.Home()
        defer { home.remove() }
        home.write(".codex/config.toml", text)
        return SecretImport.scan(F.sources(home))
    }

    static let env = "env = { GITHUB_TOKEN = \"\(F.github)\" }"

    @Test func aDescriptionWithThreeLikeCharactersKeepsTheKeyAfterItMovable() {
        for inside in ["Reads files... and more", "---", "aaa", "a   b", "say ''' here", "\\\"\\\"\\\" escaped"] {
            let text = "[mcp_servers.a]\ncommand = \"npx\"\ndescription = \"\"\"\n\(inside)\n\"\"\"\n\(Self.env)\n"
            let found = scanned(text)
            #expect(found.unreadable.isEmpty && found.findings.count == 1 && found.findings.first?.movable == true, "\(inside)")
        }
        let literal = scanned("[mcp_servers.a]\ncommand = \"npx\"\nd = '''\nsay \"\"\" here...\n'''\n\(Self.env)\n")
        #expect(literal.unreadable.isEmpty && literal.findings.map(\.variable) == ["GITHUB_TOKEN"])
    }

    /// The review's second case: `xxx` ended the first string, `k = """` opened one that took the env line, and the
    /// key was hidden with no file reported.
    @Test func aKeyAfterAStringIsNeverHidden() {
        let found = scanned("[mcp_servers.a]\ncommand = \"npx\"\nd = \"\"\"\nxxx\nk = \"\"\"\n\(Self.env)\n# aaa\n")
        #expect(found.findings.map(\.variable) == ["GITHUB_TOKEN"] && found.findings.first?.value.utf8String() == F.github)
        #expect(found.unreadable.isEmpty)
    }

    /// The review's third case: the env line is inside the string, so nothing is listed, and nothing would be moved.
    @Test func aKeyInsideAStringIsNotListed() {
        let found = scanned("[mcp_servers.a]\ncommand = \"npx\"\nd = \"\"\"\nxxx\n\(Self.env)\ntail = '''\"\"\"\n")
        #expect(found.findings.isEmpty && found.unreadable.isEmpty && found.read.count == 1)
    }

    /// A move in a file with such a string writes only the entry's keys, and leaves the string as it was.
    @Test func aMovePastAMultiLineStringLeavesItAsItWas() throws {
        let home = F.Home()
        defer { home.remove() }
        let description = "description = \"\"\"\nReads files... and more ---\n\"\"\"\n"
        home.write(".codex/config.toml", "[mcp_servers.a]\ncommand = \"npx\"\n\(description)\(Self.env)\n")
        let finding = try #require(SecretImport.scan(F.sources(home)).findings.first)
        let edit = try #require(SecretImport.plan([SecretImport.Move(name: "GITHUB_TOKEN", findings: [finding])], nxtrm: F.nxtrm).edits.first)
        #expect(SecretImport.apply(edit) == .written)
        let text = home.read(".codex/config.toml")
        #expect(text.contains(description) && !text.contains(F.github) && text.contains("\"secret\", \"run\", \"GITHUB_TOKEN\", \"--\", \"npx\""))
    }
}

import Foundation
import Testing
@testable import NextTermCore

/// Before the write, the confirm names each value the scan found that a wrapped entry would drop although its row isn't
/// ticked: nxtrm secret run would take it out at start, and after the write it is only in the entry's backup, kept for
/// 30 days (review finding #18, from its check). No value here is a real key.
@Suite struct SecretImportDroppedWarningTests {
    static let anthropicA = "made-up-anthropic-value-a-0123"
    static let anthropicB = "made-up-anthropic-value-b-4567"
    static let anthropicC = "made-up-anthropic-value-c-89ab"
    static let openai = "made-up-openai-value-d-cdef"

    func finding(_ scan: SecretImport.Scan, _ variable: String, server: String) -> SecretImport.Finding? {
        scan.findings.first { $0.variable == variable && $0.location.server == server }
    }

    /// a, b and c set ANTHROPIC_API_KEY to three values. Moving a's Anthropic key and b's OpenAI key wraps b, whose
    /// ANTHROPIC_API_KEY (its own row, not ticked) would be taken out: it is named, and the plan drops it. c's entry is
    /// left as it is, so its value is not named.
    @Test func anUntickedValueInAWrappedEntryIsNamed() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".gemini/settings.json", """
            {"mcpServers": {
              "a": {"command": "srv-a", "env": {"ANTHROPIC_API_KEY": "\(Self.anthropicA)"}},
              "b": {"command": "srv-b", "env": {"ANTHROPIC_API_KEY": "\(Self.anthropicB)", "OPENAI_API_KEY": "\(Self.openai)"}},
              "c": {"command": "srv-c", "env": {"ANTHROPIC_API_KEY": "\(Self.anthropicC)"}}
            }}

            """)
        let scan = SecretImport.scan(F.sources(home))
        let a = try #require(finding(scan, "ANTHROPIC_API_KEY", server: "a"))
        let b = try #require(finding(scan, "OPENAI_API_KEY", server: "b"))
        let moves = [SecretImport.Move(name: "ANTHROPIC_API_KEY", findings: [a]), SecretImport.Move(name: "OPENAI_API_KEY", findings: [b])]
        let dropped = SecretImport.droppedFindings(moves, among: scan.findings, stored: [])
        #expect(dropped.map(\.location.server) == ["b"] && dropped.map(\.variable) == ["ANTHROPIC_API_KEY"])
        let planned = SecretImport.plan(moves, nxtrm: F.nxtrm)
        #expect(planned.edits.first?.dropped.first?.variables == ["ANTHROPIC_API_KEY"])
        // Its row ticked too, the entry asks for it, and nothing is named.
        let bAnthropic = try #require(finding(scan, "ANTHROPIC_API_KEY", server: "b"))
        let all = moves + [SecretImport.Move(name: "ANTHROPIC_API_KEY_2", findings: [bAnthropic])]
        #expect(SecretImport.droppedFindings(all, among: scan.findings, stored: []).isEmpty)
    }

    /// A name the vault holds is taken out too; with nothing stored under it and no move of that name, nothing is named.
    @Test func aNameTheVaultHoldsCounts() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".gemini/settings.json", """
            {"mcpServers": {"b": {"command": "srv-b", "env": {"ANTHROPIC_API_KEY": "\(Self.anthropicB)", "OPENAI_API_KEY": "\(Self.openai)"}}}}

            """)
        let scan = SecretImport.scan(F.sources(home))
        let b = try #require(finding(scan, "OPENAI_API_KEY", server: "b"))
        let moves = [SecretImport.Move(name: "OPENAI_API_KEY", findings: [b])]
        #expect(SecretImport.droppedFindings(moves, among: scan.findings, stored: ["OTHER_KEY"]).isEmpty)
        let held = SecretImport.droppedFindings(moves, among: scan.findings, stored: ["ANTHROPIC_API_KEY"])
        #expect(held.map(\.variable) == ["ANTHROPIC_API_KEY"])
    }

    /// The confirm's paragraph: where each one is, that the server would never get it, that its value is then only in
    /// the backup kept for 30 days, and how to keep it. A long server name is cut; past three, the rest are counted.
    @Test func theConfirmSaysWhereEachIsAndHowToKeepIt() {
        #expect(SecretImport.droppedWarning([]) == nil)
        let one = SecretImport.droppedWarning([(variable: "ANTHROPIC_API_KEY", server: "b")])
        #expect(one == "Not ticked, but taken out too: ANTHROPIC_API_KEY in “b”. nxtrm secret run removes the name of every key "
                + "in Secrets that a server doesn’t ask for, so the server would never get it, and after this its value is only in "
                + "the backup Next Term keeps for 30 days. To keep it in Secrets, tick its row too.")
        let two = SecretImport.droppedWarning([(variable: "A_KEY", server: "b"), (variable: "C_KEY", server: "d")])
        #expect(two?.hasPrefix("Not ticked, but taken out too: A_KEY in “b” and C_KEY in “d”. ") == true)
        #expect(two?.hasSuffix("so the servers would never get them, and after this their values are only in the backups Next Term "
                + "keeps for 30 days. To keep them in Secrets, tick their rows too.") == true)
        let long = String(repeating: "s", count: 100)
        let cut: String = String(repeating: "s", count: 60) + "…"
        let many: [(variable: String, server: String)] = [("A_KEY", long), ("B_KEY", "b"), ("C_KEY", "c"), ("D_KEY", "d"), ("E_KEY", "e")]
        let five = SecretImport.droppedWarning(many)
        #expect(five?.hasPrefix("Not ticked, but taken out too: A_KEY in “\(cut)”, B_KEY in “b”, C_KEY in “c” and 2 more. ") == true)
    }
}

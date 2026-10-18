import Foundation
import Testing
@testable import NextTermCore

/// An Undo of a copy-in keeps a key that a later MCP-config move used instead of storing a second copy: the entries that
/// move rewrote start through `nxtrm secret run` with it, so deleting it would start their servers without it. The
/// confirm and the deletion read the same names. Files are made up, under a temporary home; every value is made up.
@Suite struct SecretCopyInUndoInUseTests {
    typealias C = SecretCopyInTests
    typealias I = SecretImportFixtures

    /// A move of an `.mcp.json` entry whose OPENAI_API_KEY used the key stored already: its backup names the key and
    /// stored none itself.
    private static func moveBackups() throws -> [SecretImport.EntryBackup] {
        let home = I.Home()
        defer { home.remove() }
        home.write(".cursor/mcp.json", """
            {"mcpServers": {"openai": {"command": "npx", "env": {"OPENAI_API_KEY": "\(I.openai)"}}}}
            """)
        let found = SecretImport.scan(I.sources(home), isOpen: { (_: String) -> Bool in false })
        let moves: [SecretImport.Move] = SecretImport.groups(found.findings, stored: []).map {
            (group: SecretImport.Group) -> SecretImport.Move in SecretImport.Move(name: group.name, findings: group.findings)
        }
        var edit: SecretImport.FileEdit = try #require(SecretImport.plan(moves, nxtrm: I.nxtrm).edits.first)
        edit.setStored([])
        return edit.backups
    }

    @Test func undoKeepsACopiedInKeyAMoveStillUses() throws {
        let vault = try C.vault()
        let report = C.ragReport()
        let openAI: [SourceRow] = C.allTicked(report).filter { (row: SourceRow) -> Bool in row.name == "OPENAI_API_KEY" }
        let planned = try SecretCopyIn.plan(openAI, purpose: report.purpose, stored: ["PINECONE_API_KEY"])
        let record = try SecretCopyIn.apply(planned, to: vault, source: ".env in rag-api", format: .env, remindDays: nil,
                                            maskKey: nil).record
        #expect(record.added.map(\.name) == ["OPENAI_API_KEY"])
        let backups = try Self.moveBackups()
        #expect(backups.flatMap(\.names) == ["OPENAI_API_KEY"] && backups.flatMap(\.storedNames).isEmpty)
        let inUse = Set(backups.flatMap(\.names))
        let plan = SecretCopyIn.undoPlan(record, index: vault.index, usedElsewhere: inUse)
        #expect(plan.inUse == ["OPENAI_API_KEY"] && plan.deletes.isEmpty)
        #expect(plan.changed.isEmpty && plan.replaced.isEmpty && plan.gone.isEmpty)
        let kept = "OPENAI_API_KEY stays in Secrets: entries an MCP-config import rewrote start with it."
        #expect(plan.keptText == kept)
        #expect(plan.text == "Nothing deleted. " + kept)
        // The deletion reads the same names as the confirm: nothing is deleted, and the key is still there.
        let undone = try SecretCopyIn.undo(record, in: vault, usedElsewhere: inUse)
        #expect(undone.file == nil && undone.plan == plan)
        #expect(vault.index.entry(named: "OPENAI_API_KEY") != nil)
        // With no move naming it, the same Undo deletes it, as before.
        let alone = SecretCopyIn.undoPlan(record, index: vault.index)
        #expect(alone.deletes == ["OPENAI_API_KEY"] && alone.inUse.isEmpty)
    }

    @Test func whatAnUndoSaysOfKeysStillInUse() {
        let plan = SecretCopyIn.UndoPlan(deletes: ["A_KEY"], changed: [], replaced: [], gone: [],
                                         inUse: ["B_KEY", "C_KEY"])
        #expect(plan.text == "Deleted A_KEY. B_KEY and C_KEY stay in Secrets: entries an MCP-config import rewrote start "
                + "with them.")
    }
}

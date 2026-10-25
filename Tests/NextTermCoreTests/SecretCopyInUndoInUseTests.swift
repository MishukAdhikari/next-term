import Foundation
import Testing
@testable import NextTermCore

/// An Undo of a copy-in keeps a key that a later MCP-config move used instead of storing a second copy: the entries that
/// move rewrote start through `nxtrm secret run` with it, so deleting it would start their servers without it. The
/// confirm and the deletion read the same names, and the record stays for that key, so its Undo can delete it once the
/// move is undone. Files are made up, under a temporary home; every value is made up.
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
        let kept = "OPENAI_API_KEY stays in Secrets: entries an MCP-config import rewrote start with it. Once that "
            + "import is undone, Undo here deletes it."
        #expect(plan.keptText == kept)
        #expect(plan.text == "Nothing deleted. " + kept)
        // The deletion reads the same names as the confirm: nothing is deleted, and the key is still there.
        let undone = try SecretCopyIn.undo(record, in: vault, usedElsewhere: inUse)
        #expect(undone.file == nil && undone.plan == plan)
        #expect(vault.index.entry(named: "OPENAI_API_KEY") != nil)
        #expect(undone.left == record)
        // With no move naming it, the same Undo deletes it, as before.
        let alone = SecretCopyIn.undoPlan(record, index: vault.index)
        #expect(alone.deletes == ["OPENAI_API_KEY"] && alone.inUse.isEmpty)
    }

    @Test func whatAnUndoSaysOfKeysStillInUse() {
        let plan = SecretCopyIn.UndoPlan(deletes: ["A_KEY"], changed: [], replaced: [], gone: [],
                                         inUse: ["B_KEY", "C_KEY"])
        #expect(plan.text == "Deleted A_KEY. B_KEY and C_KEY stay in Secrets: entries an MCP-config import rewrote start "
                + "with them. Once that import is undone, Undo here deletes them.")
    }

    /// The Undo deletes the keys no move uses, and its record stays for the one a move still uses, under the same id
    /// and file: once that move is undone, the record's Undo deletes it, and the record goes.
    @Test func undoLeavesARecordForTheKeysAMoveStillUses() throws {
        let vault = try C.vault()
        let report = C.ragReport()
        let planned = try SecretCopyIn.plan(C.allTicked(report), purpose: report.purpose, stored: ["PINECONE_API_KEY"])
        let record = try SecretCopyIn.apply(planned, to: vault, source: ".env in rag-api", format: .env, remindDays: nil,
                                            maskKey: nil).record
        #expect(record.added.map(\.name) == ["OPENAI_API_KEY", "LANGSMITH_API_KEY"])
        #expect(record.replaced == ["PINECONE_API_KEY"])
        let undone = try SecretCopyIn.undo(record, in: vault, usedElsewhere: ["OPENAI_API_KEY"])
        #expect(undone.plan.deletes == ["LANGSMITH_API_KEY"] && undone.plan.inUse == ["OPENAI_API_KEY"])
        #expect(undone.file != nil && vault.index.entry(named: "LANGSMITH_API_KEY") == nil)
        let left = try #require(undone.left)
        #expect(left.added == record.added.filter { (added: SecretCopyIn.Record.Added) -> Bool in
            added.name == "OPENAI_API_KEY"
        })
        #expect(left.replaced.isEmpty && left.id == record.id && left.fileName == record.fileName)
        #expect(left.date == record.date && left.source == record.source && left.format == record.format)
        // That move undone: nothing names the key any more, so the record's Undo deletes it, and leaves no record.
        let after = try SecretCopyIn.undo(left, in: vault)
        #expect(after.plan.deletes == ["OPENAI_API_KEY"] && after.file != nil && after.left == nil)
        #expect(vault.index.entry(named: "OPENAI_API_KEY") == nil)
    }

    /// An Undo that keeps no key for a move leaves no record, whatever else it kept.
    @Test func undoWithNoKeyInUseLeavesNoRecord() throws {
        let vault = try C.vault()
        let report = C.ragReport()
        let planned = try SecretCopyIn.plan(C.allTicked(report), purpose: report.purpose, stored: ["PINECONE_API_KEY"])
        let record = try SecretCopyIn.apply(planned, to: vault, source: ".env in rag-api", format: .env, remindDays: nil,
                                            maskKey: nil).record
        let undone = try SecretCopyIn.undo(record, in: vault, usedElsewhere: ["SOME_OTHER_KEY"])
        #expect(undone.plan.inUse.isEmpty && undone.plan.replaced == ["PINECONE_API_KEY"] && undone.left == nil)
    }
}

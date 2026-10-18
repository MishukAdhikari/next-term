import Foundation
import Testing
@testable import NextTermCore

/// What an Undo's "Also delete these keys" deletes, now that a move can use a key an earlier one stored (review finding
/// #19, follow-up): only the keys the undone moves stored themselves, and none another entry still uses. What it
/// keeps, it says.
@Suite struct SecretImportUndoKeysTests {
    /// One move's edit of two entries: github's (GITHUB_TOKEN) and openai's (OPENAI_API_KEY).
    private static func edit() throws -> SecretImport.FileEdit {
        let home = F.Home()
        defer { home.remove() }
        home.write(".cursor/mcp.json", """
            {"mcpServers": {
              "github": {"command": "npx", "env": {"GITHUB_TOKEN": "\(F.github)"}},
              "openai": {"command": "npx", "env": {"OPENAI_API_KEY": "\(F.openai)"}}
            }}
            """)
        let found = SecretImport.scan(F.sources(home), isOpen: { _ in false })
        let moves = SecretImport.groups(found.findings, stored: []).map { SecretImport.Move(name: $0.name, findings: $0.findings) }
        return try #require(SecretImport.plan(moves, nxtrm: F.nxtrm).edits.first)
    }

    private static func backup(_ edit: SecretImport.FileEdit, _ name: String) throws -> SecretImport.EntryBackup {
        try #require(edit.backups.first { $0.names == [name] })
    }

    /// Each backup records which of its keys the move stored, not used from an earlier one; the record reads back. One
    /// written before there was a record stored them all, as every move did then.
    @Test func aBackupRecordsTheKeysItsMoveStored() throws {
        var edit = try Self.edit()
        edit.setStored(["OPENAI_API_KEY"])
        let github = try Self.backup(edit, "GITHUB_TOKEN")
        let openai = try Self.backup(edit, "OPENAI_API_KEY")
        #expect(github.storedNames == [] && openai.storedNames == ["OPENAI_API_KEY"])
        let githubData = try #require(github.encoded())
        let read = try #require(SecretImport.EntryBackup.decode(githubData))
        #expect(read.stored == [] && read.storedNames == [])
        let openaiData = try #require(openai.encoded())
        var older = try #require(JSONSerialization.jsonObject(with: openaiData) as? [String: Any])
        older["stored"] = nil
        let olderData = try JSONSerialization.data(withJSONObject: older)
        let olderRead = try #require(SecretImport.EntryBackup.decode(olderData))
        #expect(olderRead.stored == nil && olderRead.storedNames == ["OPENAI_API_KEY"])
    }

    /// A key the move used because an earlier move had stored it stays, whoever else uses it, even once the earlier
    /// move's backup is gone after 30 days; the key it stored itself goes. Undo says which stayed and why.
    @Test func undoDeletesOnlyTheKeysItsMovesStored() throws {
        var edit = try Self.edit()
        edit.setStored(["OPENAI_API_KEY"])
        let backups = edit.backups
        let keys = SecretImport.UndoKeys(undoing: backups, others: [])
        #expect(keys.deletable == ["OPENAI_API_KEY"])
        #expect(keys.storedBefore == ["GITHUB_TOKEN"] && keys.usedElsewhere == [])
        let kept = keys.keptText(["GITHUB_TOKEN", "OPENAI_API_KEY"])
        #expect(kept == "GITHUB_TOKEN stays in Secrets: it was there before this import, and other entries may use it.")
        // A key whose entry didn't go back is kept for that, and said so elsewhere: nothing more here.
        #expect(keys.keptText(["OPENAI_API_KEY"]) == nil)
        edit.setStored([])
        let both = SecretImport.UndoKeys(undoing: edit.backups, others: [])
        #expect(both.deletable.isEmpty)
        #expect(both.keptText(["GITHUB_TOKEN", "OPENAI_API_KEY"])
                == "GITHUB_TOKEN and OPENAI_API_KEY stay in Secrets: they were there before this import, and other entries may "
                + "use them.")
    }

    /// A key another listed import's entries name, or an entry of this one left wrapped (a write-only key's), stays:
    /// those entries still run with it. Older backups, with no record, may delete their keys as before.
    @Test func undoKeepsAKeyEntriesItDoesntPutBackStillUse() throws {
        var edit = try Self.edit()
        let older = try Self.backup(edit, "GITHUB_TOKEN")
        edit.setStored(["GITHUB_TOKEN", "OPENAI_API_KEY"])
        let github = try Self.backup(edit, "GITHUB_TOKEN")
        let openai = try Self.backup(edit, "OPENAI_API_KEY")
        let keys = SecretImport.UndoKeys(undoing: [openai, github], others: [older])
        #expect(keys.deletable == ["OPENAI_API_KEY"])
        #expect(keys.storedBefore == [] && keys.usedElsewhere == ["GITHUB_TOKEN"])
        #expect(keys.keptText(["GITHUB_TOKEN", "OPENAI_API_KEY"])
                == "GITHUB_TOKEN stays in Secrets: entries this Undo doesn’t put back still use it.")
        let alone = SecretImport.UndoKeys(undoing: [older], others: [])
        #expect(alone.deletable == ["GITHUB_TOKEN"] && alone.keptText(["GITHUB_TOKEN"]) == nil)
    }
}

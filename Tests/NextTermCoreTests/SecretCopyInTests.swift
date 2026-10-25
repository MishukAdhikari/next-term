import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// A copy-in: the preview's ticked rows saved as keys in one unlock, and the record Undo reads, which holds names, ids
/// and dates, never a value. The vault is made with a software keyring; every value is made up.
@Suite struct SecretCopyInTests {
    typealias F = SecretSourcesFixtures

    /// rag-api's `.env`, with PINECONE_API_KEY stored already: its row starts unticked ("Replaces your key").
    static func ragReport(stored: Set<String> = ["PINECONE_API_KEY"]) -> SourceReport {
        F.report(F.ragAPIEnv, name: ".env", folder: "rag-api", stored: stored)
    }

    /// The report's rows with every row that can be stored ticked, as by hand.
    static func allTicked(_ report: SourceReport) -> [SourceRow] {
        report.rows.map { (row: SourceRow) -> SourceRow in
            var ticked: SourceRow = row
            ticked.ticked = row.refusal == nil
            return ticked
        }
    }

    /// A vault holding PINECONE_API_KEY, with what it's for and no page.
    static func vault() throws -> SecretVault {
        let vault: SecretVault = try SecretVault.create(keyring: SoftwareKeyring()).vault
        _ = try vault.add(name: "PINECONE_API_KEY", purpose: "Pinecone, by hand", purposeBy: .user, origin: .settings,
                          writeOnly: false, value: SecretBytes(utf8: F.pinecone.reversedText))
        return vault
    }

    @Test func tickedRowsBecomeAddsAndReplacesWithTheirPageAndPurpose() throws {
        let report = Self.ragReport()
        let pinecone = try #require(report.rows.first { (row: SourceRow) -> Bool in row.name == "PINECONE_API_KEY" })
        #expect(!pinecone.ticked && pinecone.note == .replaces)
        let planned = try SecretCopyIn.plan(Self.allTicked(report), purpose: report.purpose, stored: ["PINECONE_API_KEY"])
        #expect(planned.map(\.name) == ["OPENAI_API_KEY", "PINECONE_API_KEY", "LANGSMITH_API_KEY"])
        let openAI = try #require(planned.first)
        #expect(!openAI.replaces && openAI.purpose == "From .env in rag-api")
        #expect(openAI.link == "https://platform.openai.com/settings/organization/api-keys")
        #expect(openAI.linkFrom == .suggested && openAI.value == SecretBytes(utf8: F.openAI))
        #expect(planned[1].replaces && !planned[2].replaces)
    }

    @Test func untickedAndRefusedRowsAreLeftAndNamesAreChecked() throws {
        let report = Self.ragReport(stored: [])
        var rows: [SourceRow] = report.rows
        rows[1].ticked = false
        #expect(try SecretCopyIn.plan(rows, purpose: report.purpose, stored: []).map(\.name)
            == ["OPENAI_API_KEY", "LANGSMITH_API_KEY"])
        rows[0].name = "openai key"
        #expect(throws: SecretCopyIn.Problem.badName("openai key")) {
            try SecretCopyIn.plan(rows, purpose: report.purpose, stored: [])
        }
        rows[0].name = "LANGSMITH_API_KEY"
        #expect(throws: SecretCopyIn.Problem.sameName("LANGSMITH_API_KEY")) {
            try SecretCopyIn.plan(rows, purpose: report.purpose, stored: [])
        }
    }

    @Test func aPageThatHoldsAStoredKeyIsLeftOut() throws {
        let report = Self.ragReport(stored: [])
        let holds: (String) -> Bool = { (text: String) -> Bool in text.contains("openai") }
        let planned = try SecretCopyIn.plan(report.rows, purpose: report.purpose, stored: [], holdsKey: holds)
        #expect(planned[0].link == nil && planned[0].linkFrom == nil)
        #expect(planned[1].link != nil)
    }

    @Test func applySavesEachKeyAndRecordsWhatUndoNeeds() throws {
        let vault = try Self.vault()
        let report = Self.ragReport()
        let planned = try SecretCopyIn.plan(Self.allTicked(report), purpose: report.purpose, stored: ["PINECONE_API_KEY"])
        let now = Date(timeIntervalSince1970: 1_791_000_000.6)
        let done = try SecretCopyIn.apply(planned, to: vault, source: ".env in rag-api", format: .env, remindDays: 90,
                                          maskKey: SymmetricKey(size: .bits256), now: now)
        #expect(done.file != nil)
        let openAI = try #require(vault.index.entry(named: "OPENAI_API_KEY"))
        #expect(openAI.origin == .import && openAI.purpose == "From .env in rag-api" && openAI.purposeBy == .user)
        #expect(openAI.linkFrom == .suggested && openAI.link == planned[0].link && openAI.remindDays == 90)
        #expect(openAI.valueSet == Date(timeIntervalSince1970: 1_791_000_000) && !openAI.marks.isEmpty)
        #expect(try vault.value(of: "OPENAI_API_KEY") == SecretBytes(utf8: F.openAI))
        // The key it replaced keeps what it's for, gets the page it had none of, and holds the new value.
        let pinecone = try #require(vault.index.entry(named: "PINECONE_API_KEY"))
        #expect(pinecone.purpose == "Pinecone, by hand" && pinecone.origin == .import && pinecone.link != nil)
        #expect(try vault.value(of: "PINECONE_API_KEY") == SecretBytes(utf8: F.pinecone))
        let record = done.record
        #expect(record.added.map(\.name) == ["OPENAI_API_KEY", "LANGSMITH_API_KEY"])
        #expect(record.added[0].id == openAI.id && record.added[0].valueSet == openAI.valueSet)
        #expect(record.replaced == ["PINECONE_API_KEY"] && record.source == ".env in rag-api" && record.format == "env")
    }

    @Test func theRecordHoldsNoValueAndReadsBack() throws {
        let vault = try Self.vault()
        let report = Self.ragReport()
        let planned = try SecretCopyIn.plan(Self.allTicked(report), purpose: report.purpose, stored: ["PINECONE_API_KEY"])
        let record = try SecretCopyIn.apply(planned, to: vault, source: ".env in rag-api", format: .env, remindDays: nil,
                                            maskKey: nil, now: Date()).record
        let data = try #require(record.encoded())
        let text = String(decoding: data, as: UTF8.self)
        for value in [F.openAI, F.pinecone, F.langSmith] {
            #expect(!text.contains(value) && !text.contains(String(value.suffix(4))))
        }
        #expect(SecretCopyIn.Record.decode(data) == record)
        #expect(record.fileName.hasSuffix("-copy-\(record.id).json"))
        // The MCP-config import's backups and copy-in records live in one folder; neither reads as the other.
        let backup = #"{"id":"abc","batch":"b","date":"2026-10-15T10:00:00Z","path":"/x","names":["A"]}"#
        #expect(SecretCopyIn.Record.decode(Data(backup.utf8)) == nil)
        #expect(SecretImport.EntryBackup.decode(data) == nil)
    }

    @Test func undoDeletesOnlyKeysThatStillHoldWhatWasCopiedIn() throws {
        let vault = try Self.vault()
        let report = Self.ragReport()
        let planned = try SecretCopyIn.plan(Self.allTicked(report), purpose: report.purpose, stored: ["PINECONE_API_KEY"])
        let then = Date(timeIntervalSince1970: 1_791_000_000)
        let record = try SecretCopyIn.apply(planned, to: vault, source: ".env in rag-api", format: .env, remindDays: nil,
                                            maskKey: nil, now: then).record
        // Renamed since: still the value copied in. Replaced since: not any more.
        _ = try vault.edit("OPENAI_API_KEY", newName: "RAG_OPENAI_KEY", now: then.addingTimeInterval(60))
        _ = try vault.replace("LANGSMITH_API_KEY", value: SecretBytes(utf8: F.langSmith.reversedText), writeOnly: false,
                              now: then.addingTimeInterval(120))
        let plan = SecretCopyIn.undoPlan(record, index: vault.index)
        #expect(plan.deletes == ["RAG_OPENAI_KEY"] && plan.changed == ["LANGSMITH_API_KEY"])
        #expect(plan.replaced == ["PINECONE_API_KEY"] && plan.gone.isEmpty)
        let undone = try SecretCopyIn.undo(record, in: vault)
        #expect(undone.file != nil && undone.plan == plan)
        #expect(vault.index.names.sorted() == ["LANGSMITH_API_KEY", "PINECONE_API_KEY"])
        let again = SecretCopyIn.undoPlan(record, index: vault.index)
        #expect(again.deletes.isEmpty && again.gone == ["OPENAI_API_KEY"])
        #expect(try SecretCopyIn.undo(record, in: vault).file == nil)
    }
}

import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// What a copy-in does when the vault moved under it, and what its Undo trusts: a key stored after the confirm is never
/// replaced, a record naming a key no import added deletes nothing, and a full vault's worth is saved in one encode.
/// The vault is made with a software keyring; every value is made up.
@Suite struct SecretCopyInGuardTests {
    typealias F = SecretSourcesFixtures
    typealias C = SecretCopyInTests

    @Test func aKeyStoredSinceTheConfirmIsRefusedAndOneDeletedSinceIsAdded() throws {
        let vault = try C.vault()
        let report = C.ragReport()
        let planned = try SecretCopyIn.plan(C.allTicked(report), purpose: report.purpose, stored: ["PINECONE_API_KEY"])
        // Between the confirm and Touch ID, OPENAI_API_KEY is stored elsewhere: the confirm named it as a new key.
        _ = try vault.add(name: "OPENAI_API_KEY", purpose: "By hand", purposeBy: .user, origin: .settings,
                          writeOnly: false, value: SecretBytes(utf8: F.openAI.reversedText))
        let names: [String] = vault.index.names
        let file: Data = vault.file
        #expect(throws: SecretVault.Failure.nameTaken("OPENAI_API_KEY")) {
            try SecretCopyIn.apply(planned, to: vault, source: ".env in rag-api", format: .env, remindDays: nil,
                                   maskKey: nil)
        }
        #expect(vault.index.names == names && vault.file == file)
        #expect(try vault.value(of: "OPENAI_API_KEY") == SecretBytes(utf8: F.openAI.reversedText))
        #expect(try vault.value(of: "PINECONE_API_KEY") == SecretBytes(utf8: F.pinecone.reversedText))
        // The key it would replace is gone since: it is added, so Undo can delete it.
        _ = try vault.delete("OPENAI_API_KEY")
        _ = try vault.delete("PINECONE_API_KEY")
        let record = try SecretCopyIn.apply(planned, to: vault, source: ".env in rag-api", format: .env,
                                            remindDays: nil, maskKey: nil).record
        #expect(record.added.map(\.name) == ["OPENAI_API_KEY", "PINECONE_API_KEY", "LANGSMITH_API_KEY"])
        #expect(record.replaced.isEmpty)
    }

    @Test func undoDeletesNoKeyAnImportDidNotAdd() throws {
        let vault = try C.vault()
        let pinecone = try #require(vault.index.entry(named: "PINECONE_API_KEY"))
        // A record another process wrote: a key's id and date are in vault.json, which reads without unlocking.
        let added = SecretCopyIn.Record.Added(name: "PINECONE_API_KEY", id: pinecone.id, valueSet: pinecone.lastSet)
        let record = SecretCopyIn.Record(id: "made-up", date: Date(), source: ".env in rag-api", format: "env",
                                         added: [added], replaced: [])
        let plan = SecretCopyIn.undoPlan(record, index: vault.index)
        #expect(plan.deletes.isEmpty && plan.changed == ["PINECONE_API_KEY"])
        #expect(try SecretCopyIn.undo(record, in: vault).file == nil)
        #expect(vault.index.entry(named: "PINECONE_API_KEY") != nil)
    }

    @Test func aFullVaultsWorthIsCopiedInAndUndoneInTime() throws {
        let vault = try C.vault()
        let count: Int = SecretVault.maxEntries - 1
        let planned: [SecretCopyIn.Planned] = (0..<count).map { (index: Int) -> SecretCopyIn.Planned in
            let value = SecretBytes(utf8: "made-up-\(index)-" + String(repeating: "q7Zx", count: 8))
            return SecretCopyIn.Planned(name: "COPIED_KEY_\(index)", value: value, purpose: "From .env in rag-api",
                                        link: nil, linkFrom: nil, replaces: false)
        }
        let clock = ContinuousClock()
        var record: SecretCopyIn.Record?
        let encoded: Int = vault.encodedFiles
        let copying: Duration = try clock.measure {
            record = try SecretCopyIn.apply(planned, to: vault, source: ".env in rag-api", format: .env,
                                            remindDays: nil, maskKey: SymmetricKey(size: .bits256)).record
        }
        #expect(record?.added.count == count && vault.index.entries.count == SecretVault.maxEntries)
        // One encode for the whole copy-in, and one for its Undo: the vault isn't encoded again for each key.
        #expect(vault.encodedFiles == encoded + 1)
        #expect(copying < .seconds(5), "the copy-in took \(copying)")
        let saved = try #require(record)
        var deleted: Data?
        let undoing: Duration = try clock.measure { deleted = try SecretCopyIn.undo(saved, in: vault).file }
        #expect(deleted != nil && vault.index.names == ["PINECONE_API_KEY"] && vault.encodedFiles == encoded + 2)
        #expect(undoing < .seconds(5), "the Undo took \(undoing)")
    }
}

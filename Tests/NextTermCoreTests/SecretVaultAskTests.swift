import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// A key's "Ask for Touch ID every time it's used": an optional member of the entry, absent on every key that asks,
/// so a key saved before the box reads as asking every time, and the vault stays format 1. Every value is made up.
@Suite struct SecretVaultAskTests {
    static let value = SecretBytes(utf8: "made-up-ask-value-0123456789")

    static func vault(asksEveryUse: Bool? = nil) throws -> (vault: SecretVault, keyring: SoftwareKeyring, file: Data) {
        let keyring = SoftwareKeyring()
        let vault: SecretVault = try SecretVault.create(keyring: keyring).vault
        let file: Data
        if let asksEveryUse {
            file = try vault.add(name: "ASK_KEY", purpose: "rag-api", purposeBy: .user, origin: .settings, writeOnly: false,
                                 value: value, asksEveryUse: asksEveryUse)
        } else {
            file = try vault.add(name: "ASK_KEY", purpose: "rag-api", purposeBy: .user, origin: .settings, writeOnly: false,
                                 value: value)
        }
        return (vault, keyring, file)
    }

    /// The first entry's members, as JSON.
    static func firstEntry(of file: Data) throws -> [String: Any] {
        let body: Data = try JSONDecoder().decode(SecretVault.File.self, from: file).body
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let entries = try #require(object?["entries"] as? [[String: Any]])
        return try #require(entries.first)
    }

    @Test func aNewKeyAsksEveryTimeAndWritesNothingNew() throws {
        let made = try Self.vault()
        #expect(made.vault.index.entries[0].asksEveryUse)
        #expect(made.vault.index.entries[0].lastingApprovals == nil)
        #expect(try Self.firstEntry(of: made.file)["lastingApprovals"] == nil)
        let ticked = try Self.vault(asksEveryUse: true)
        #expect(try Self.firstEntry(of: ticked.file)["lastingApprovals"] == nil)
    }

    @Test func aKeyUntickedLetsApprovalsLastAndReadsBack() throws {
        let made = try Self.vault(asksEveryUse: false)
        #expect(!made.vault.index.entries[0].asksEveryUse)
        #expect(try Self.firstEntry(of: made.file)["lastingApprovals"] as? Bool == true)
        let listed = try SecretVault.index(from: made.file)
        #expect(listed.entries[0].asksEveryUse == false)
        let opened = try SecretVault.unlock(made.file, keyring: made.keyring, context: nil)
        #expect(opened.index.entries[0].asksEveryUse == false)
    }

    /// A key saved before the box has no member: it reads as asking every time.
    @Test func anOldKeyWithNoMemberAsksEveryTime() throws {
        let made = try Self.vault(asksEveryUse: false)
        let outer = try JSONDecoder().decode(SecretVault.File.self, from: made.file)
        var body = try #require(try JSONSerialization.jsonObject(with: outer.body) as? [String: Any])
        var entries = body["entries"] as? [[String: Any]] ?? []
        entries[0]["lastingApprovals"] = nil
        body["entries"] = entries
        let bytes: Data = try JSONSerialization.data(withJSONObject: body)
        let file: Data = try SecretVault.encodeFile(body: bytes, key: made.vault.unlockedKey())
        let opened = try SecretVault.unlock(file, keyring: made.keyring, context: nil)
        #expect(opened.index.entries[0].asksEveryUse)
    }

    /// The index's MAC covers it: a file changed to let approvals last is refused as changed outside Next Term.
    @Test func aFlagChangedInTheFileIsTampered() throws {
        let made = try Self.vault()
        let outer = try JSONDecoder().decode(SecretVault.File.self, from: made.file)
        var body = try #require(try JSONSerialization.jsonObject(with: outer.body) as? [String: Any])
        var entries = body["entries"] as? [[String: Any]] ?? []
        entries[0]["lastingApprovals"] = true
        body["entries"] = entries
        let bytes: Data = try JSONSerialization.data(withJSONObject: body)
        let forged: Data = try JSONEncoder().encode(SecretVault.File(format: outer.format, body: bytes, mac: outer.mac))
        #expect(throws: SecretVault.Failure.tampered) {
            try SecretVault.unlock(forged, keyring: made.keyring, context: nil)
        }
    }

    /// Edit… sets it either way with no new seal; nil leaves it.
    @Test func editSetsItAndKeepsTheSeal() throws {
        let made = try Self.vault()
        let box: Data = made.vault.index.entries[0].box
        _ = try made.vault.edit("ASK_KEY", asksEveryUse: false)
        #expect(!made.vault.index.entries[0].asksEveryUse && made.vault.index.entries[0].box == box)
        _ = try made.vault.edit("ASK_KEY", purpose: "rag-api, staging")
        #expect(!made.vault.index.entries[0].asksEveryUse)
        let file: Data = try made.vault.edit("ASK_KEY", asksEveryUse: true)
        #expect(made.vault.index.entries[0].asksEveryUse && made.vault.index.entries[0].box == box)
        #expect(try Self.firstEntry(of: file)["lastingApprovals"] == nil)
    }

    /// A rename, a new value, a rotation and Never Show keep what the user chose.
    @Test func everyOtherChangeKeepsIt() throws {
        let made = try Self.vault(asksEveryUse: false)
        _ = try made.vault.edit("ASK_KEY", newName: "ASK_KEY_2")
        _ = try made.vault.replace("ASK_KEY_2", value: SecretBytes(utf8: "made-up-ask-value-new-0123"), writeOnly: false)
        _ = try made.vault.rotate("ASK_KEY_2", value: SecretBytes(utf8: "made-up-ask-value-rotated-01"))
        _ = try made.vault.makeWriteOnly("ASK_KEY_2")
        let entry = try #require(made.vault.index.entry(named: "ASK_KEY_2"))
        #expect(!entry.asksEveryUse && entry.writeOnly)
    }
}

/// "Never show" on an import's rows, and the New keys default for asking every time.
@Suite struct SecretCopyInNeverShowTests {
    typealias F = SecretSourcesFixtures

    @Test func aRowTickedNeverShowIsAddedWriteOnly() throws {
        let report = SecretCopyInTests.ragReport(stored: [])
        var rows: [SourceRow] = SecretCopyInTests.allTicked(report)
        #expect(rows.allSatisfy { (row: SourceRow) -> Bool in !row.neverShow })
        rows[0].neverShow = true
        let planned = try SecretCopyIn.plan(rows, purpose: report.purpose, stored: [])
        #expect(planned.map(\.writeOnly) == [true, false, false])
        let vault: SecretVault = try SecretVault.create(keyring: SoftwareKeyring()).vault
        _ = try SecretCopyIn.apply(planned, to: vault, source: ".env in rag-api", format: .env, remindDays: nil, maskKey: nil)
        #expect(vault.index.entry(named: "OPENAI_API_KEY")?.writeOnly == true)
        #expect(vault.index.entry(named: "PINECONE_API_KEY")?.writeOnly == false)
        #expect(throws: SecretVault.Failure.writeOnly("OPENAI_API_KEY")) { try vault.shownValue(of: "OPENAI_API_KEY") }
    }

    /// A row that replaces a key makes it never shown when ticked so, and never shows a never-shown key again.
    @Test func aReplaceIsNeverShownWhenEitherSaysSo() throws {
        let report = SecretCopyInTests.ragReport()
        var rows: [SourceRow] = SecretCopyInTests.allTicked(report)
        let vault: SecretVault = try SecretCopyInTests.vault()
        var planned = try SecretCopyIn.plan(rows, purpose: report.purpose, stored: ["PINECONE_API_KEY"])
        #expect(planned[1].replaces && !planned[1].writeOnly)
        _ = try SecretCopyIn.apply([planned[1]], to: vault, source: ".env", format: .env, remindDays: nil, maskKey: nil)
        #expect(vault.index.entry(named: "PINECONE_API_KEY")?.writeOnly == false)
        rows[1].neverShow = true
        planned = try SecretCopyIn.plan(rows, purpose: report.purpose, stored: ["PINECONE_API_KEY"])
        _ = try vault.replace("PINECONE_API_KEY", value: SecretBytes(utf8: "made-up-pinecone-other-0123"), writeOnly: false)
        _ = try SecretCopyIn.apply([planned[1]], to: vault, source: ".env", format: .env, remindDays: nil, maskKey: nil)
        #expect(vault.index.entry(named: "PINECONE_API_KEY")?.writeOnly == true)
        rows[1].neverShow = false
        planned = try SecretCopyIn.plan(rows, purpose: report.purpose, stored: ["PINECONE_API_KEY"])
        _ = try vault.replace("PINECONE_API_KEY", value: SecretBytes(utf8: "made-up-pinecone-third-0123"), writeOnly: true)
        _ = try SecretCopyIn.apply([planned[1]], to: vault, source: ".env", format: .env, remindDays: nil, maskKey: nil)
        #expect(vault.index.entry(named: "PINECONE_API_KEY")?.writeOnly == true)
    }

    /// New keys take the New keys default; a key it replaces keeps its own.
    @Test func newKeysTakeTheAskDefault() throws {
        let report = SecretCopyInTests.ragReport()
        let rows: [SourceRow] = SecretCopyInTests.allTicked(report)
        let planned = try SecretCopyIn.plan(rows, purpose: report.purpose, stored: ["PINECONE_API_KEY"])
        let vault: SecretVault = try SecretCopyInTests.vault()
        _ = try SecretCopyIn.apply(planned, to: vault, source: ".env", format: .env, remindDays: nil, asksEveryUse: false,
                                   maskKey: nil)
        #expect(vault.index.entry(named: "OPENAI_API_KEY")?.asksEveryUse == false)
        #expect(vault.index.entry(named: "LANGSMITH_API_KEY")?.asksEveryUse == false)
        #expect(vault.index.entry(named: "PINECONE_API_KEY")?.asksEveryUse == true)
        let other: SecretVault = try SecretVault.create(keyring: SoftwareKeyring()).vault
        _ = try SecretCopyIn.apply(planned, to: other, source: ".env", format: .env, remindDays: nil, maskKey: nil)
        let allAsk: Bool = other.index.entries.allSatisfy { (entry: SecretVault.Entry) -> Bool in entry.asksEveryUse }
        #expect(allAsk)
    }
}

import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// A vault Next Term made and recorded, holding one key, and the bytes it wrote.
private struct RecordedVault {
    let keyring = SoftwareKeyring(kind: .secureEnclave)
    let record = MemoryVaultRecord()
    let vault: SecretVault
    var file: Data

    init() throws {
        vault = try SecretVault.create(keyring: keyring).vault
        try vault.record(in: record)
        file = try vault.add(name: "GITHUB_TOKEN", purpose: "GitHub MCP server", purposeBy: .user, origin: .settings,
                             writeOnly: false, value: SecretBytes(utf8: "ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    func unlock(_ data: Data) throws -> SecretVault {
        try SecretVault.unlock(data, keyring: keyring, context: nil)
    }
}

/// `original`'s index rebuilt around another vault key, `key`, wrapped for `publicKey` with `keyBlob`, and its MAC made
/// with `key`: what someone who can write vault.json can build with no secret of this Mac's.
private func rebuilt(_ original: SecretVault, key: SymmetricKey, publicKey: Data, keyBlob: Data?) throws -> Data {
    var index = original.index
    index.wrapped = try SecretVault.wrap(key, for: publicKey, kind: index.keyring)
    index.keyBlob = keyBlob
    index.publicKey = publicKey
    return try SecretVault.encodeFile(index, key: key)
}

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

private let typed = "sk-typed-after-the-swap-0123456789abcdef"

@Suite struct SecretVaultRecordTests {
    @Test func aVaultNextTermMadeIsBound() throws {
        let f = try RecordedVault()
        try f.vault.bind(to: f.record)
        let binding = try f.vault.binding()
        #expect(binding.count == 32)
        // The same vault read again from its bytes, changed, and read again: the binding is the vault key's, so it stays.
        let opened = try f.unlock(f.file)
        try opened.bind(to: f.record)
        let changed = try opened.edit("GITHUB_TOKEN", newName: "GH_TOKEN", purpose: "renamed")
        try f.vault.reload(changed)
        try f.unlock(changed).bind(to: f.record)
        #expect(try opened.binding() == binding)
        #expect(f.record.writes == 1)
        // Another vault has another binding.
        let other = try SecretVault.create(keyring: f.keyring).vault
        #expect(try other.binding() != binding)
    }

    /// The finding's scenario: a whole vault.json built elsewhere, with its own vault key wrapped under a Secure Enclave
    /// key its maker made (the app opens any blob the file holds), the original's names and purposes copied. Every
    /// check inside the file passes, so an add would be sealed under a key its maker knows; the record refuses it.
    @Test func aWholeVaultBuiltWithItsOwnKeyringIsRefused() throws {
        let f = try RecordedVault()
        let theirs = SoftwareKeyring(kind: .secureEnclave)
        let key = SymmetricKey(size: .bits256)
        let planted = try rebuilt(f.vault, key: key, publicKey: theirs.publicKey(), keyBlob: Data("their blob".utf8))
        let opened = try SecretVault.unlock(planted, keyring: theirs, context: nil)
        #expect(opened.index.names == ["GITHUB_TOKEN"] && opened.index.entries[0].purpose == "GitHub MCP server")
        #expect(throws: SecretVault.Failure.tampered) { try opened.bind(to: f.record) }
        // What the record keeps from happening: a value added to it opens with the key its maker chose.
        let file = try opened.add(name: "STRIPE_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: true,
                                  value: SecretBytes(utf8: typed))
        let entry = try #require(try SecretVault.index(from: file).entry(named: "STRIPE_KEY"))
        #expect(try SecretVault.open(entry, key: key) == SecretBytes(utf8: typed))
        #expect(f.record.writes == 1)
    }

    /// Wrapping needs only the public key, so a vault key of someone else's can be wrapped under this Mac's own key, with
    /// the original's blob and public key kept: this Mac's keyring opens it. The record refuses it too.
    @Test func anotherVaultKeyWrappedUnderThisMacsKeyIsRefused() throws {
        let f = try RecordedVault()
        let key = SymmetricKey(size: .bits256)
        let planted = try rebuilt(f.vault, key: key, publicKey: f.vault.index.publicKey, keyBlob: f.vault.index.keyBlob)
        let opened = try f.unlock(planted)
        #expect(opened.index.publicKey == f.vault.index.publicKey)
        #expect(throws: SecretVault.Failure.tampered) { try opened.bind(to: f.record) }
        let file = try opened.replace("GITHUB_TOKEN", value: SecretBytes(utf8: typed), writeOnly: false)
        let entry = try #require(try SecretVault.index(from: file).entry(named: "GITHUB_TOKEN"))
        #expect(try SecretVault.open(entry, key: key) == SecretBytes(utf8: typed))
    }

    /// A record that lists other vaults, or is not a list of bindings: the vault is refused as tampered.
    @Test func aVaultNoRecordListsIsRefused() throws {
        let f = try RecordedVault()
        for contents in [Data(), Data(repeating: 7, count: 31), Data(repeating: 7, count: 32)] {
            let record = MemoryVaultRecord(contents)
            #expect(throws: SecretVault.Failure.tampered, "\(contents.count)") { try f.vault.bind(to: record) }
            #expect(record.writes == 0)
        }
    }

    /// No record at all (none made yet, or the login keychain lost it): refused too, but as unlisted, whose text says
    /// the record is missing. Restoring vault.json would not help, so it never says to.
    @Test func aVaultWithNoRecordIsRefusedAsUnlisted() throws {
        let f = try RecordedVault()
        let record = MemoryVaultRecord()
        #expect(throws: SecretVault.Failure.unlisted) { try f.vault.bind(to: record) }
        #expect(record.writes == 0)
        let text = try #require(SecretVault.Failure.unlisted.errorDescription)
        #expect(text != SecretVault.Failure.tampered.errorDescription)
        #expect(text.contains("login keychain") && !text.contains("restore the file"))
    }

    /// The record is trusted as it reads: one that lists a vault built elsewhere binds it. So it is kept where a program
    /// that only writes files can't write it; a program that can add login-keychain items can still forge it.
    @Test func aRecordThatListsAVaultBindsItWhoeverWroteIt() throws {
        let f = try RecordedVault()
        let theirs = SoftwareKeyring(kind: .secureEnclave)
        let key = SymmetricKey(size: .bits256)
        let planted = try rebuilt(f.vault, key: key, publicKey: theirs.publicKey(), keyBlob: Data("their blob".utf8))
        let opened = try SecretVault.unlock(planted, keyring: theirs, context: nil)
        let forged = MemoryVaultRecord(SecretVault.binding(of: key))
        try opened.bind(to: forged)
        #expect(throws: SecretVault.Failure.tampered) { try opened.bind(to: f.record) }
    }

    /// Start Over then Add makes a second vault: both stay recorded, so a kept or restored vault still opens.
    @Test func recordingKeepsTheVaultsMadeBefore() throws {
        let f = try RecordedVault()
        let second = try SecretVault.create(keyring: SoftwareKeyring(kind: .secureEnclave)).vault
        try second.record(in: f.record)
        try f.vault.bind(to: f.record)
        try second.bind(to: f.record)
        #expect(f.record.contents?.count == 64)
        try f.vault.record(in: f.record) // listed already: nothing written
        #expect(f.record.writes == 2)
        // A record that is not a list of bindings is started again by the next vault made.
        let damaged = MemoryVaultRecord(Data(repeating: 1, count: 5))
        try second.record(in: damaged)
        #expect(try damaged.contents == second.binding())
    }

    @Test func theRecordKeepsTheNewestVaults() throws {
        let record = MemoryVaultRecord()
        var vaults: [SecretVault] = []
        for _ in 0...SecretVault.maxRecordedVaults {
            let vault = try SecretVault.create(keyring: SoftwareKeyring()).vault
            try vault.record(in: record)
            vaults.append(vault)
        }
        #expect(record.contents?.count == SecretVault.maxRecordedVaults * 32)
        #expect(throws: SecretVault.Failure.tampered) { try vaults[0].bind(to: record) }
        try vaults[1].bind(to: record)
        try vaults[SecretVault.maxRecordedVaults].bind(to: record)
    }

    /// A record that can't be read just now, or whose prompt the user refused, is not tampering: it says so, and nothing
    /// is written.
    @Test func aRecordThatCantBeReadIsNotTampering() throws {
        let f = try RecordedVault()
        for failure in [SecretVault.Failure.cancelled, .keyUnavailable] {
            f.record.failure = failure
            #expect(throws: failure) { try f.vault.bind(to: f.record) }
            let other = try SecretVault.create(keyring: f.keyring).vault
            #expect(throws: failure) { try other.record(in: f.record) }
        }
        f.record.failure = nil
        #expect(f.record.writes == 1)
        try f.vault.bind(to: f.record)
    }

    @Test func aLockedVaultBindsNothing() throws {
        let f = try RecordedVault()
        f.vault.wipe()
        #expect(throws: SecretVault.Failure.locked) { try f.vault.bind(to: f.record) }
        #expect(throws: SecretVault.Failure.locked) { try f.vault.record(in: MemoryVaultRecord()) }
    }

    @Test func theBindingMatchesAFixedVector() {
        let vaultKey = SymmetricKey(data: Data(0..<32))
        #expect(hex(SecretVault.binding(of: vaultKey)) == "c2c6e79efe37c6982a88e0fb7a3961138754064980da7ed89d77cc53b9b3da12")
    }
}

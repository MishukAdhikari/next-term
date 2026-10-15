import Foundation
import Testing
@testable import NextTermCore

/// Changes saved as one file: each is checked as it is made, the file is encoded once at the end, and a failure leaves
/// the vault as it was before the first. Every value is made up.
@Suite struct SecretVaultBatchTests {
    static func value(_ index: Int) -> SecretBytes {
        SecretBytes(utf8: "made-up-batch-\(index)-" + String(repeating: "k3Pw", count: 6))
    }

    @Test func aBatchsChangesAreOneFileThatReadsBack() throws {
        let keyring = SoftwareKeyring()
        let vault: SecretVault = try SecretVault.create(keyring: keyring).vault
        _ = try vault.add(name: "KEPT_KEY", purpose: "Kept", purposeBy: .user, origin: .settings, writeOnly: false,
                          value: Self.value(0))
        let encoded: Int = vault.encodedFiles
        let file: Data = try vault.batch {
            _ = try vault.add(name: "FIRST_KEY", purpose: "First", purposeBy: .user, origin: .import, writeOnly: false,
                              value: Self.value(1))
            _ = try vault.replace("KEPT_KEY", value: Self.value(2), writeOnly: false, origin: .import)
            _ = try vault.edit("KEPT_KEY", link: .some("https://example.com/keys"))
            // A batch inside a batch is part of it.
            _ = try vault.batch { _ = try vault.delete("FIRST_KEY") }
        }
        #expect(file == vault.file && vault.encodedFiles == encoded + 1)
        let again = try SecretVault.unlock(file, keyring: keyring, context: nil)
        #expect(again.index.names == ["KEPT_KEY"] && again.index.entry(named: "KEPT_KEY")?.origin == .import)
        #expect(again.index.entry(named: "KEPT_KEY")?.link == "https://example.com/keys")
        #expect(try again.value(of: "KEPT_KEY") == Self.value(2))
    }

    @Test func aFailureInABatchLeavesTheVaultAsItWas() throws {
        let vault: SecretVault = try SecretVault.create(keyring: SoftwareKeyring()).vault
        _ = try vault.add(name: "KEPT_KEY", purpose: "Kept", purposeBy: .user, origin: .settings, writeOnly: false,
                          value: Self.value(0))
        let index: SecretVault.Index = vault.index
        let file: Data = vault.file
        #expect(throws: SecretVault.Failure.nameTaken("KEPT_KEY")) {
            try vault.batch {
                _ = try vault.add(name: "NEW_KEY", purpose: "New", purposeBy: .user, origin: .import, writeOnly: false,
                                  value: Self.value(1))
                _ = try vault.replace("KEPT_KEY", value: Self.value(2), writeOnly: false)
                _ = try vault.add(name: "KEPT_KEY", purpose: "Twice", purposeBy: .user, origin: .import,
                                  writeOnly: false, value: Self.value(3))
            }
        }
        #expect(vault.index == index && vault.file == file)
        #expect(try vault.value(of: "KEPT_KEY") == Self.value(0))
        // The vault takes changes again, one at a time, as before.
        let one: Data = try vault.add(name: "NEW_KEY", purpose: "New", purposeBy: .user, origin: .import,
                                      writeOnly: false, value: Self.value(1))
        #expect(one == vault.file && vault.index.names == ["KEPT_KEY", "NEW_KEY"])
    }
}

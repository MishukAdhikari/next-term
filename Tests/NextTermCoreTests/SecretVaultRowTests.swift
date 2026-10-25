import Foundation
import Testing
@testable import NextTermCore

/// The row a list keeps selected after a reload: the selected key's, found by its id (review finding #25, and the
/// rename the name lookup lost). A rename or a new value keeps the id; a key deleted and added again under the same name
/// is another key, so nothing stays selected.
@Suite struct SecretVaultRowTests {
    private static func value(_ tag: String) -> SecretBytes { SecretBytes(utf8: "made-up-row-value-\(tag)-0123456789") }

    /// A vault holding ROW_A, ROW_B and ROW_C, in that order.
    private static func threeKeys() throws -> SecretVault {
        let vault = try SecretVault.create(keyring: SoftwareKeyring()).vault
        for name in ["ROW_A", "ROW_B", "ROW_C"] {
            _ = try vault.add(name: name, purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                              value: value(name))
        }
        return vault
    }

    @Test func aKeyDeletedElsewhereLeavesTheSelectedKeyAtItsNewRow() throws {
        let vault = try Self.threeKeys()
        let selected = vault.index.entry(named: "ROW_B")?.id
        let now = try SecretVault.index(from: vault.delete("ROW_A"))
        #expect(now.row(of: selected) == 0)
        #expect(now.entries[0].name == "ROW_B")
    }

    @Test func theSelectedKeyRenamedStaysSelected() throws {
        let vault = try Self.threeKeys()
        let selected = vault.index.entry(named: "ROW_B")?.id
        let now = try SecretVault.index(from: vault.edit("ROW_B", newName: "ROW_B2"))
        let row: Int? = now.row(of: selected)
        #expect(row == 1)
        #expect(row.map { now.entries[$0].name } == "ROW_B2")
    }

    @Test func theSelectedKeyGivenANewValueStaysSelected() throws {
        let vault = try Self.threeKeys()
        let selected = vault.index.entry(named: "ROW_C")?.id
        let now = try SecretVault.index(from: vault.replace("ROW_C", value: Self.value("new"), writeOnly: true))
        #expect(now.row(of: selected) == 2)
    }

    @Test func theSelectedKeyDeletedLeavesNoRow() throws {
        let vault = try Self.threeKeys()
        let selected = vault.index.entry(named: "ROW_B")?.id
        let now = try SecretVault.index(from: vault.delete("ROW_B"))
        #expect(now.row(of: selected) == nil)
    }

    /// Deleted and added again under its name: another key, whose value the user never chose to act on.
    @Test func theSelectedKeyDeletedAndAddedAgainIsNotSelected() throws {
        let vault = try Self.threeKeys()
        let selected = vault.index.entry(named: "ROW_A")?.id
        _ = try vault.delete("ROW_A")
        let file = try vault.add(name: "ROW_A", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                 value: Self.value("ROW_A"))
        let now = try SecretVault.index(from: file)
        #expect(now.entry(named: "ROW_A") != nil)
        #expect(now.row(of: selected) == nil)
    }

    @Test func nothingSelectedIsNoRow() throws {
        let vault = try Self.threeKeys()
        let none: String? = nil
        #expect(vault.index.row(of: none) == nil)
    }
}

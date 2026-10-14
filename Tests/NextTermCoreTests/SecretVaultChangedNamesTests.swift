import Foundation
import Testing
@testable import NextTermCore

/// What another copy of Next Term changed in vault.json, by name, so this copy's grants holding those keys end
/// (review finding #12).
@Suite struct SecretVaultChangedNamesTests {
    private static let first = SecretBytes(utf8: "made-up-value-first-0123456789")
    private static let second = SecretBytes(utf8: "made-up-value-second-0123456789")

    /// A vault with two keys, as this copy read it, and the same vault opened in "another copy".
    private static func twoCopies() throws -> (earlier: SecretVault.Index, other: SecretVault) {
        let keyring = SoftwareKeyring()
        let vault = try SecretVault.create(keyring: keyring).vault
        _ = try vault.add(name: "SERVICE_TOKEN", purpose: "A service", purposeBy: .user, origin: .settings, writeOnly: false,
                          value: first)
        let file = try vault.add(name: "OTHER_TOKEN", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                 value: second)
        return (try SecretVault.index(from: file), try SecretVault.unlock(file, keyring: keyring, context: nil))
    }

    private static func changed(_ change: (SecretVault) throws -> Data) throws -> [String] {
        let (earlier, other) = try twoCopies()
        let now = try SecretVault.index(from: change(other))
        return now.changedNames(since: earlier)
    }

    @Test func aKeyReplacedDeletedOrRenamedElsewhereIsChanged() throws {
        #expect(try Self.changed { try $0.replace("SERVICE_TOKEN", value: Self.second, writeOnly: false) } == ["SERVICE_TOKEN"])
        #expect(try Self.changed { try $0.delete("SERVICE_TOKEN") } == ["SERVICE_TOKEN"])
        #expect(try Self.changed { try $0.edit("SERVICE_TOKEN", newName: "RENAMED_TOKEN") } == ["SERVICE_TOKEN"])
    }

    /// Deleted and added again under the same name, even with the same value: a new key, so its grants end.
    @Test func aKeyDeletedAndAddedAgainIsChanged() throws {
        let names = try Self.changed { other in
            _ = try other.delete("SERVICE_TOKEN")
            return try other.add(name: "SERVICE_TOKEN", purpose: "A service", purposeBy: .user, origin: .settings,
                                 writeOnly: false, value: Self.first)
        }
        #expect(names == ["SERVICE_TOKEN"])
    }

    /// What a key is for, changed alone, keeps its value: nothing ends. A key added elsewhere had no grant here.
    @Test func aPurposeOrANewKeyChangesNothing() throws {
        #expect(try Self.changed { try $0.edit("SERVICE_TOKEN", purpose: "Another service") } == [])
        let added = try Self.changed { other in
            try other.add(name: "NEW_TOKEN", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                          value: SecretBytes(utf8: "made-up-value-new-0123456789"))
        }
        #expect(added == [])
    }

    /// Another vault at the same place (Start Over and an add, in another copy): every key of the old one changed.
    @Test func anotherVaultChangesEveryKey() throws {
        let (earlier, _) = try Self.twoCopies()
        let (_, other) = try Self.twoCopies()
        #expect(other.index.changedNames(since: earlier) == ["SERVICE_TOKEN", "OTHER_TOKEN"])
    }
}

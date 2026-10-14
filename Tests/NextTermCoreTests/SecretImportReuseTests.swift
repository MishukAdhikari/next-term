import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// An import tried again after its file was left as it was (locked or changed) uses the key the first try stored,
/// instead of a second copy under `_2` (review finding #19).
@Suite struct SecretImportReuseTests {
    private static let value = SecretBytes(utf8: "made-up-value-0123456789")

    private static func vault(_ maskKey: SymmetricKey) throws -> SecretVault {
        let vault = try SecretVault.create(keyring: SoftwareKeyring()).vault
        _ = try vault.add(name: "HELD", purpose: "", purposeBy: .user, origin: .import, writeOnly: false, value: value,
                          maskKey: maskKey)
        _ = try vault.add(name: "SHORT", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                          value: SecretBytes(utf8: "short-1"), maskKey: maskKey)
        return vault
    }

    /// The marks tell which stored key holds a value, with no value read from the vault: trimmed as the vault trims
    /// it, under the mask's own key, and never for a value under 12 bytes, which has none.
    @Test func theMarksTellWhichKeyHoldsAValue() throws {
        let maskKey = SymmetricKey(size: .bits256)
        let vault = try Self.vault(maskKey)
        let mask = SecretMask(key: maskKey, index: vault.index)
        let held = try #require(vault.index.entry(named: "HELD"))
        let short = try #require(vault.index.entry(named: "SHORT"))
        #expect(mask.isHeld(Self.value, by: held))
        #expect(mask.isHeld(SecretBytes(utf8: "  made-up-value-0123456789\n"), by: held))
        #expect(!mask.isHeld(SecretBytes(utf8: "made-up-value-0123456789x"), by: held))
        #expect(!mask.isHeld(Self.value, by: short))
        #expect(!mask.isHeld(SecretBytes(utf8: "short-1"), by: short))
        #expect(!SecretMask.empty.isHeld(Self.value, by: held))
        #expect(!SecretMask(key: SymmetricKey(size: .bits256), index: vault.index).isHeld(Self.value, by: held))
    }

    /// Inside the unlocked vault, the value itself: the same one (trimmed as `add` trims it) under that name, or not.
    @Test func theVaultTellsWhetherAKeyHoldsAValue() throws {
        let vault = try Self.vault(SymmetricKey(size: .bits256))
        #expect(try vault.holds("HELD", value: Self.value))
        #expect(try vault.holds("HELD", value: SecretBytes(utf8: " made-up-value-0123456789 ")))
        #expect(try !vault.holds("HELD", value: SecretBytes(utf8: "made-up-value-9876543210")))
        #expect(try !vault.holds("MISSING", value: Self.value))
        #expect(try !vault.holds("HELD", value: SecretBytes(utf8: "two\nlines")))
        vault.wipe()
        #expect(throws: SecretVault.Failure.locked) { _ = try vault.holds("HELD", value: Self.value) }
    }

    /// A group whose value a stored key holds takes that key's name, even one unlike its variable's, and says so.
    /// Groups of other values still step around stored names, and so does a second group of the same value (one entry
    /// holding it under two variables needs a key for each).
    @Test func aGroupUsesTheStoredKeyHoldingItsValue() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".cursor/mcp.json", """
            {"mcpServers": {
              "github": {"command": "npx", "env": {"GITHUB_TOKEN": "\(F.github)", "GH_TOKEN": "\(F.github)"}},
              "openai": {"command": "npx", "env": {"OPENAI_API_KEY": "\(F.openai)"}}
            }}
            """)
        let found = SecretImport.scan(F.sources(home), isOpen: { _ in false })
        let github = SecretBytes(utf8: F.github)
        let stored = ["EARLIER_TOKEN", "OPENAI_API_KEY"]
        let groups = SecretImport.groups(found.findings, stored: stored) { $0 == github ? "EARLIER_TOKEN" : nil }
        let same = groups.filter { $0.value == github }
        #expect(same.count == 2)
        #expect(same.filter(\.reusesStored).map(\.name) == ["EARLIER_TOKEN"])
        #expect(same.filter { !$0.reusesStored }.allSatisfy { !stored.contains($0.name) })
        let openai = try #require(groups.first { $0.value == SecretBytes(utf8: F.openai) })
        #expect(openai.name == "OPENAI_API_KEY_2" && !openai.reusesStored)
        // With no stored key holding a value, nothing is reused.
        #expect(SecretImport.groups(found.findings, stored: stored).allSatisfy { !$0.reusesStored })
    }
}

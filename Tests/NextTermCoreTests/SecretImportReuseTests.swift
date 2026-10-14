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

    /// The keys a group may use: an earlier move's (origin `import`) whose marks hold its value. Never a key added in
    /// Settings, which is the user's own, nor a write-only one, which an Undo of the move couldn't put back.
    @Test func onlyAnEarlierMovesReadableKeysAreUsed() throws {
        let maskKey = SymmetricKey(size: .bits256)
        let vault = try SecretVault.create(keyring: SoftwareKeyring()).vault
        let keys: [(String, SecretVault.Origin)] = [("FIRST_MOVE", .import), ("MINE", .settings), ("LOCKED_MOVE", .import),
                                                    ("SECOND_MOVE", .import)]
        for (name, origin) in keys {
            _ = try vault.add(name: name, purpose: "", purposeBy: .user, origin: origin, writeOnly: false, value: Self.value,
                              maskKey: maskKey)
        }
        _ = try vault.makeWriteOnly("LOCKED_MOVE")
        _ = try vault.add(name: "OTHER_MOVE", purpose: "", purposeBy: .user, origin: .import, writeOnly: false,
                          value: SecretBytes(utf8: "made-up-value-9876543210"), maskKey: maskKey)
        let mask = SecretMask(key: maskKey, index: vault.index)
        #expect(SecretImport.reusable(holding: Self.value, in: vault.index, mask: mask) == ["FIRST_MOVE", "SECOND_MOVE"])
        #expect(SecretImport.reusable(holding: Self.value, in: nil, mask: mask) == [])
        #expect(SecretImport.reusable(holding: Self.value, in: vault.index, mask: .empty) == [])
        #expect(SecretImport.reusable(holding: SecretBytes(utf8: "short-1"), in: vault.index, mask: mask) == [])
    }

    /// Inside the unlocked vault, the import keeps a key instead of storing the value again only when an earlier move
    /// stored it, it is not write-only, and it holds that value.
    @Test func theVaultKeepsOnlyAnEarlierMovesReadableKey() throws {
        let vault = try SecretVault.create(keyring: SoftwareKeyring()).vault
        let keys: [(String, SecretVault.Origin)] = [("HELD", .import), ("MINE", .settings), ("LOCKED", .import)]
        for (name, origin) in keys {
            _ = try vault.add(name: name, purpose: "", purposeBy: .user, origin: origin, writeOnly: false, value: Self.value)
        }
        _ = try vault.makeWriteOnly("LOCKED")
        #expect(try vault.isReusable("HELD", for: Self.value))
        #expect(try !vault.isReusable("HELD", for: SecretBytes(utf8: "made-up-value-9876543210")))
        #expect(try !vault.isReusable("MINE", for: Self.value))
        #expect(try !vault.isReusable("LOCKED", for: Self.value))
        #expect(try !vault.isReusable("MISSING", for: Self.value))
    }

    /// The scan of an entry holding one value under two variables, and another value, for the groups below.
    private static func twoVariablesOneValue() -> [SecretImport.Finding] {
        let home = F.Home()
        defer { home.remove() }
        home.write(".cursor/mcp.json", """
            {"mcpServers": {
              "github": {"command": "npx", "env": {"GITHUB_TOKEN": "\(F.github)", "GH_TOKEN": "\(F.github)"}},
              "openai": {"command": "npx", "env": {"OPENAI_API_KEY": "\(F.openai)"}}
            }}
            """)
        return SecretImport.scan(F.sources(home), isOpen: { _ in false }).findings
    }

    /// Each group's name by its first variable, and whether it uses a stored key.
    private static func named(_ groups: [SecretImport.Group]) -> [String: String] {
        var names: [String: String] = [:]
        for group in groups { names[group.findings[0].variable] = group.name + (group.reusesStored ? " (stored)" : "") }
        return names
    }

    /// Groups whose value stored keys hold use those keys, one each. An entry holding the value under two variables,
    /// both stored by the first try, uses both again, each its own name; never one key twice and a second copy.
    @Test func eachGroupUsesItsOwnStoredKeyHoldingItsValue() {
        let findings = Self.twoVariablesOneValue()
        let github = SecretBytes(utf8: F.github)
        let stored = ["GH_TOKEN", "GITHUB_TOKEN", "OPENAI_API_KEY"]
        let both = SecretImport.groups(findings, stored: stored) { $0 == github ? ["GH_TOKEN", "GITHUB_TOKEN"] : [] }
        #expect(Self.named(both) == ["GITHUB_TOKEN": "GITHUB_TOKEN (stored)", "GH_TOKEN": "GH_TOKEN (stored)",
                                     "OPENAI_API_KEY": "OPENAI_API_KEY_2"])
        // Held under other names: a group takes the one named as its variable first, the other group the next.
        let other = ["GH_TOKEN", "EARLIER_TOKEN", "OPENAI_API_KEY"]
        let renamed = SecretImport.groups(findings, stored: other) { $0 == github ? ["EARLIER_TOKEN", "GH_TOKEN"] : [] }
        #expect(Self.named(renamed)["GITHUB_TOKEN"] == "EARLIER_TOKEN (stored)")
        #expect(Self.named(renamed)["GH_TOKEN"] == "GH_TOKEN (stored)")
        // One stored key holding it: one group uses it, the other gets a name of its own and a key of its own.
        let one = SecretImport.groups(findings, stored: ["EARLIER_TOKEN"]) { $0 == github ? ["EARLIER_TOKEN"] : [] }
        let same = one.filter { $0.value == github }
        #expect(same.filter(\.reusesStored).map(\.name) == ["EARLIER_TOKEN"])
        #expect(same.filter { !$0.reusesStored }.allSatisfy { $0.name != "EARLIER_TOKEN" })
        // A name `holding` gives that isn't stored is never used; with none, nothing is reused.
        #expect(SecretImport.groups(findings, stored: []) { _ in ["GITHUB_TOKEN"] }.allSatisfy { !$0.reusesStored })
        #expect(SecretImport.groups(findings, stored: stored).allSatisfy { !$0.reusesStored })
    }
}

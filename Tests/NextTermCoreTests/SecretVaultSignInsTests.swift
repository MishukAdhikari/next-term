import Foundation
import Testing
@testable import NextTermCore

/// The sign-ins' key in the vault: its hidden `NEXT_TERM_SIGN_INS` entry, which no list shows, no agent path releases,
/// and only Next Term itself reads (MCPHubSignIns).
struct SecretVaultSignInsTests {
    @Test func theSignInsKeyIsHiddenRefusedAndRemovable() throws {
        let vault = try SecretVault.create(keyring: SoftwareKeyring()).vault
        _ = try vault.add(name: "GITHUB_TOKEN", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false, value: SecretBytes(utf8: "ghp_x"))
        // The reserved name is the sign-ins' key's alone, and it has no other.
        #expect(throws: SecretVault.Failure.badName) {
            try vault.add(name: SecretVault.signInsName, purpose: "", purposeBy: .agent, origin: .agent, writeOnly: false, value: SecretBytes(utf8: "x"))
        }
        #expect(throws: SecretVault.Failure.badName) {
            try vault.add(name: "OTHER", purpose: "", purposeBy: .user, origin: .settings, writeOnly: true, value: SecretBytes(utf8: "x"), kind: .signIns)
        }
        let file = try vault.add(name: SecretVault.signInsName, purpose: "sign-ins", purposeBy: .user, origin: .settings, writeOnly: true,
                                 value: SecretBytes(utf8: "a2V5"), kind: .signIns)
        let index = try SecretVault.index(from: file)
        #expect(index.signIns?.kind == .signIns)
        // Every list sees the user's keys alone.
        #expect(index.hidingSignIns.names == ["GITHUB_TOKEN"])
        #expect(index.names.contains(SecretVault.signInsName))
        // Never shown, copied, given a value from outside, or renamed; Next Term itself reads it.
        #expect(throws: SecretVault.Failure.writeOnly(SecretVault.signInsName)) { try vault.shownValue(of: SecretVault.signInsName) }
        #expect(throws: SecretVault.Failure.badName) { try vault.replace(SecretVault.signInsName, value: SecretBytes(utf8: "b"), writeOnly: true) }
        #expect(throws: SecretVault.Failure.badName) { try vault.rotate(SecretVault.signInsName, value: SecretBytes(utf8: "b")) }
        #expect(throws: SecretVault.Failure.badName) { try vault.edit(SecretVault.signInsName, newName: "MINE") }
        #expect(throws: SecretVault.Failure.badName) { try vault.edit("GITHUB_TOKEN", newName: SecretVault.signInsName) }
        #expect(try vault.value(of: SecretVault.signInsName).utf8String() == "a2V5")
        // Removed, the vault is as it was.
        let removed = try SecretVault.index(from: try vault.delete(SecretVault.signInsName))
        #expect(removed.signIns == nil && removed.names == ["GITHUB_TOKEN"])
    }

    @Test func theKindIsReadLenientlyAndTheNameAloneHides() throws {
        let vault = try SecretVault.create(keyring: SoftwareKeyring()).vault
        let file = try vault.add(name: SecretVault.signInsName, purpose: "", purposeBy: .user, origin: .settings, writeOnly: true,
                                 value: SecretBytes(utf8: "a2V5"), kind: .signIns)
        // A copy before the kind dropped it when it saved: the reserved name still hides it.
        var entry = try #require(try SecretVault.index(from: file).entries.first)
        entry.kind = nil
        #expect(entry.isSignIns)
        // A kind a later release adds reads as none, never as a broken vault.
        let json = #"{"kind":"laterKind"}"#
        struct Probe: Decodable { let kind: SecretVault.Kind? }
        #expect(try JSONDecoder().decode(Probe.self, from: Data(json.utf8)).kind == nil)
    }

}

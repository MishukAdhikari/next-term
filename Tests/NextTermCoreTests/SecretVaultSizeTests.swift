import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// The write cap: vault.json never grows past what Next Term can read back (review finding #10). The tests lower the
/// cap, so a few 16 KB values fill it; the real one is checked against the read cap on its own.
@Suite struct SecretVaultSizeTests {
    private static let cap = 64 * 1024
    private static let big = SecretBytes([UInt8](repeating: UInt8(ascii: "A"), count: SecretVault.maxValueBytes))
    private static let small = SecretBytes(utf8: "made-up-value-0123456789")

    /// A vault with SMALL, then 16 KB keys added under a 64 KB cap until one is refused: how many fitted.
    private static func filled(_ keyring: SoftwareKeyring) throws -> (vault: SecretVault, added: Int) {
        let vault = try SecretVault.create(keyring: keyring).vault
        vault.writeCap = cap
        _ = try vault.add(name: "SMALL", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false, value: small)
        var added = 0
        while added < 10 {
            do {
                _ = try vault.add(name: "BIG_\(added)", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                  value: big)
            } catch let failure as SecretVault.Failure {
                #expect(failure == .full)
                break
            }
            added += 1
        }
        return (vault, added)
    }

    @Test func theCapIsBelowTheReadCapAndSaysWhatToDo() {
        #expect(SecretVault.maxWriteSize < SecretVault.maxFileSize)
        let vault = try? SecretVault.create(keyring: SoftwareKeyring()).vault
        #expect(vault?.writeCap == SecretVault.maxWriteSize)
        let text = SecretVault.Failure.full.errorDescription ?? ""
        #expect(text.contains("nothing was saved") && text.contains("Delete keys"))
    }

    /// An add whose file would pass the cap is refused, and the vault is as it was: its index and its file. What it
    /// wrote last reads back, and opens.
    @Test func anAddPastTheCapIsRefusedAndLeavesTheVaultAsItWas() throws {
        let keyring = SoftwareKeyring()
        let (vault, added) = try Self.filled(keyring)
        #expect(added >= 1 && added < 10)
        #expect(vault.file.count <= Self.cap)
        let bigNames: [String] = (0..<added).map { "BIG_\($0)" }
        let names: [String] = ["SMALL"] + bigNames
        #expect(vault.index.names == names)
        let before = vault.file
        #expect(throws: SecretVault.Failure.full) {
            _ = try vault.add(name: "ONE_MORE", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false, value: Self.big)
        }
        #expect(vault.file == before && vault.index.entry(named: "ONE_MORE") == nil)
        let reopened = try SecretVault.unlock(before, keyring: keyring, context: nil)
        #expect(reopened.index.names == vault.index.names)
    }

    /// A replace or a rename that would pass the cap is refused, and the key keeps its value, its name and its seal.
    @Test func aReplaceOrRenamePastTheCapLeavesTheKeyAsItWas() throws {
        let keyring = SoftwareKeyring()
        let (vault, _) = try Self.filled(keyring)
        let entry = try #require(vault.index.entry(named: "SMALL"))
        #expect(throws: SecretVault.Failure.full) { _ = try vault.replace("SMALL", value: Self.big, writeOnly: false) }
        #expect(vault.index.entry(named: "SMALL") == entry)
        #expect(try vault.value(of: "SMALL") == Self.small)
        vault.writeCap = vault.file.count
        let longer = "SMALL_" + String(repeating: "X", count: 50)
        #expect(throws: SecretVault.Failure.full) { _ = try vault.edit("SMALL", newName: longer) }
        #expect(vault.index.entry(named: "SMALL") == entry && vault.index.entry(named: longer) == nil)
        #expect(try vault.value(of: "SMALL") == Self.small)
    }

    /// Upkeep may use the room between the cap and the read cap, so a full vault can still be marked again, have a key
    /// made write-only, and be emptied.
    @Test func upkeepStillWorksInAFullVault() throws {
        let keyring = SoftwareKeyring()
        let (vault, _) = try Self.filled(keyring)
        vault.writeCap = vault.file.count - 1
        #expect(throws: SecretVault.Failure.full) {
            _ = try vault.edit("SMALL", purpose: "A purpose that makes the file longer")
        }
        _ = try vault.remark(maskKey: SymmetricKey(size: .bits256))
        let recovery = SecretVault.randomBytes(SecretVault.recoveryKeyLength)
        let recovered = try vault.addRecovery(key: recovery)
        #expect(recovered.count > vault.writeCap)
        let newKeyring = SoftwareKeyring(kind: .secureEnclave)
        _ = try vault.rewrap(under: newKeyring)
        _ = try vault.makeWriteOnly("SMALL")
        let file = try vault.delete("BIG_0")
        #expect(try SecretVault.index(from: file).entry(named: "BIG_0") == nil)
        #expect(try SecretVault.unlock(file, keyring: newKeyring, context: nil).value(of: "SMALL") == Self.small)
        #expect(try SecretVault.unlock(file, recovery: recovery).index.names == vault.index.names)
    }

    /// A vault.json past the read cap is too large, not changed outside Next Term: Settings and every action say so,
    /// and Start Over or an older copy is the way out. A file that doesn't decode is not too large.
    @Test func aFilePastTheReadCapIsTooLargeNotTampered() throws {
        let base = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("nt-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = SecretFolder(applicationSupport: base)
        try folder.ensure()
        try folder.write(SecretFolder.vaultName, data: Data(repeating: UInt8(ascii: "x"), count: 64))
        func failure(_ body: () throws -> Void) -> Error? {
            do { try body() } catch { return error }
            return nil
        }
        let read = failure { _ = try folder.read(SecretFolder.vaultName, cap: 32) }
        let decoded = failure { _ = try SecretVault.index(from: Data(count: SecretVault.maxFileSize + 1)) }
        let garbled = failure { _ = try SecretVault.index(from: Data("{}".utf8)) }
        #expect(read.map(SecretVault.isTooLarge) == true)
        #expect(decoded.map(SecretVault.isTooLarge) == true)
        #expect(garbled.map(SecretVault.isTooLarge) == false)
        #expect(!SecretVault.isTooLarge(SecretFolder.Failure.notPrivate))
        #expect(!SecretVault.isTooLarge(SecretVault.Failure.tampered))
    }

    /// A vault already past the cap (written before there was one, or grown by upkeep) still takes a change that
    /// doesn't make its file larger: a leaked key replaced in place with a value of the same length, or a shorter one.
    /// A change that makes it larger is still refused.
    @Test func aChangeThatDoesNotGrowAFullVaultIsSaved() throws {
        let keyring = SoftwareKeyring()
        let (vault, _) = try Self.filled(keyring)
        vault.writeCap = vault.file.count / 2
        let rotated = SecretBytes(utf8: "made-up-value-9876543210")
        let before = vault.file.count
        let file = try vault.replace("SMALL", value: rotated, writeOnly: false)
        #expect(file.count == before)
        #expect(try SecretVault.unlock(file, keyring: keyring, context: nil).value(of: "SMALL") == rotated)
        let shorter = SecretBytes(utf8: "made-up-value-0")
        let smaller = try vault.replace("SMALL", value: shorter, writeOnly: false)
        #expect(smaller.count < before)
        #expect(throws: SecretVault.Failure.full) { _ = try vault.replace("SMALL", value: rotated, writeOnly: false) }
        #expect(try vault.value(of: "SMALL") == shorter && vault.file == smaller)
    }
}

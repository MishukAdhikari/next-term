import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// A vault made with a software keyring, holding one key, and the bytes it wrote.
private struct VaultFixture {
    let keyring = SoftwareKeyring()
    let vault: SecretVault
    var file: Data

    init(writeOnly: Bool = false) throws {
        vault = try SecretVault.create(keyring: keyring).vault
        file = try vault.add(name: "GITHUB_TOKEN", purpose: "GitHub MCP server", purposeBy: .user, origin: .settings,
                             writeOnly: writeOnly, value: SecretBytes(utf8: "ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    func unlock(_ data: Data) throws -> SecretVault {
        try SecretVault.unlock(data, keyring: keyring, context: nil)
    }
}

/// The body of `file` as a dictionary, changed by `edit`, then written back with the old MAC (`resealed: false`) or a
/// MAC made with the vault key (`resealed: true`, "fixed by hand").
private func edited(_ file: Data, vault: SecretVault, resealed: Bool, _ edit: (inout [String: Any]) -> Void) throws -> Data {
    let outer = try JSONDecoder().decode(SecretVault.File.self, from: file)
    var body = try #require(try JSONSerialization.jsonObject(with: outer.body) as? [String: Any])
    edit(&body)
    let bytes = try JSONSerialization.data(withJSONObject: body)
    if resealed { return try SecretVault.encodeFile(body: bytes, key: vault.unlockedKey()) }
    return try JSONEncoder().encode(SecretVault.File(format: outer.format, body: bytes, mac: outer.mac))
}

private func entries(_ body: inout [String: Any], _ change: (inout [[String: Any]]) -> Void) {
    var list = body["entries"] as? [[String: Any]] ?? []
    change(&list)
    body["entries"] = list
}

private func hex(_ key: SymmetricKey) -> String { key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined() }
private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

@Suite struct SecretVaultSealTests {
    @Test func aChangedFieldFailsTheMACAndReleasesNothing() throws {
        let f = try VaultFixture()
        let changes: [(String, (inout [String: Any]) -> Void)] = [
            ("purpose", { entries(&$0) { $0[0]["purpose"] = "Something else" } }),
            ("name", { entries(&$0) { $0[0]["name"] = "GH_TOKEN" } }),
            ("write-only", { entries(&$0) { $0[0]["writeOnly"] = true } }),
            ("date", { entries(&$0) { $0[0]["changed"] = "2020-01-01T00:00:00Z" } }),
            ("origin", { entries(&$0) { $0[0]["origin"] = "agent" } }),
        ]
        for (label, change) in changes {
            let tampered = try edited(f.file, vault: f.vault, resealed: false, change)
            #expect(throws: SecretVault.Failure.tampered, "\(label)") { _ = try f.unlock(tampered) }
        }
        #expect(try f.unlock(f.file).value(of: "GITHUB_TOKEN").count == 40)
    }

    @Test func swappedBoxesAndABoxFromAnotherVaultFailTheSeal() throws {
        let f = try VaultFixture()
        let file = try f.vault.add(name: "OTHER_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                   value: SecretBytes(utf8: "sk-other-value-0123456789abcdef"))
        let swapped = try edited(file, vault: f.vault, resealed: true) { body in
            entries(&body) { list in
                let first = list[0]["box"]
                list[0]["box"] = list[1]["box"]
                list[1]["box"] = first
            }
        }
        let opened = try f.unlock(swapped) // the MAC was fixed by hand
        #expect(throws: SecretVault.Failure.tampered) { _ = try opened.value(of: "GITHUB_TOKEN") }
        #expect(throws: SecretVault.Failure.tampered) { _ = try opened.value(of: "OTHER_KEY") }

        let other = try VaultFixture()
        let otherBody = try JSONDecoder().decode(SecretVault.File.self, from: other.file).body
        let otherEntries = try #require(try JSONSerialization.jsonObject(with: otherBody) as? [String: Any])["entries"] as? [[String: Any]]
        let foreign = try edited(f.file, vault: f.vault, resealed: true) { body in
            entries(&body) { $0[0]["box"] = otherEntries?[0]["box"] }
        }
        #expect(throws: SecretVault.Failure.tampered) { _ = try f.unlock(foreign).value(of: "GITHUB_TOKEN") }
    }

    @Test func theWriteOnlyFlagIsInTheSeal() throws {
        let f = try VaultFixture(writeOnly: true)
        let cleared = try edited(f.file, vault: f.vault, resealed: true) { body in
            entries(&body) { $0[0]["writeOnly"] = false }
        }
        let opened = try f.unlock(cleared)
        #expect(opened.index.entries[0].writeOnly == false)
        #expect(throws: SecretVault.Failure.tampered) { _ = try opened.shownValue(of: "GITHUB_TOKEN") }
        #expect(throws: SecretVault.Failure.tampered) { _ = try opened.value(of: "GITHUB_TOKEN") }
        // Untouched, it opens for a command and is never shown.
        let intact = try f.unlock(f.file)
        #expect(try intact.value(of: "GITHUB_TOKEN").count == 40)
        #expect(throws: SecretVault.Failure.writeOnly("GITHUB_TOKEN")) { _ = try intact.shownValue(of: "GITHUB_TOKEN") }
    }

    @Test func aRenameSealsAgain() throws {
        let f = try VaultFixture()
        let before = f.vault.index.entries[0]
        let file = try f.vault.edit("GITHUB_TOKEN", newName: "GH_TOKEN")
        let after = try f.unlock(file)
        #expect(after.index.names == ["GH_TOKEN"])
        #expect(try after.value(of: "GH_TOKEN").count == 40)
        var renamed = after.index.entries[0]
        #expect(renamed.box != before.box)
        // The new box under the old name's associated data no longer opens.
        renamed.name = "GITHUB_TOKEN"
        #expect(throws: SecretVault.Failure.tampered) { _ = try SecretVault.open(renamed, key: after.unlockedKey()) }
    }

    @Test func theMACIsOverTheStoredBytes() throws {
        let f = try VaultFixture()
        let outer = try JSONDecoder().decode(SecretVault.File.self, from: f.file)
        let object = try JSONSerialization.jsonObject(with: outer.body)
        // The same body, its keys in another order and with other spacing: not what JSONEncoder would write.
        let reordered = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        #expect(reordered != outer.body)
        let file = try SecretVault.encodeFile(body: reordered, key: f.vault.unlockedKey())
        let opened = try f.unlock(file)
        #expect(opened.index.names == ["GITHUB_TOKEN"])
        #expect(try opened.value(of: "GITHUB_TOKEN") == SecretBytes(utf8: "ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        // A format that differs from the outer one is tampering.
        let other = try edited(f.file, vault: f.vault, resealed: true) { $0["format"] = 2 }
        #expect(throws: SecretVault.Failure.tampered) { _ = try f.unlock(other) }
    }

    @Test func associatedDataAndKeysMatchFixedVectors() {
        let settings = SecretVault.associatedData(id: "id-1", name: "GITHUB_TOKEN", writeOnly: false, origin: .settings)
        #expect(hex(settings) == "000000116e6578747465726d2d7365637265742f310000000469642d310000000c4749544855425f544f4b454e00000001300000000873657474696e6773")
        let agent = SecretVault.associatedData(id: "id-1", name: "GITHUB_TOKEN", writeOnly: true, origin: .agent)
        #expect(hex(agent) == "000000116e6578747465726d2d7365637265742f310000000469642d310000000c4749544855425f544f4b454e0000000131000000056167656e74")
        let vaultKey = SymmetricKey(data: Data(0..<32))
        #expect(hex(SecretVault.entryKey(vaultKey, id: "id-1")) == "8adcb1b98a63ecde0549d59bc13c557ed036a6ade32f53eddd318cfe92352762")
        #expect(hex(SecretVault.indexKey(vaultKey)) == "a9fb63b791eb279b5b488b28456c154ceb9e4ef4f15707d0f51f401edb75c3ae")
        #expect(hex(SecretVault.importKey(vaultKey, id: "rec-1")) == "0a608884ea0153354202d17eedd1a8e2fed8fed5752c646f9cf35db1c6c292c4")
        let recovery = SecretBytes([UInt8](repeating: 0xAA, count: 32))
        #expect(hex(SecretVault.recoveryKey(recovery)) == "7fc7e1b6e61d1d4a1bb1a9359b7922c4a3f487c5560dd6522be8dde464f1d038")
        let mac = HMAC<SHA256>.authenticationCode(for: Data(#"{"a":1}"#.utf8), using: SecretVault.indexKey(vaultKey))
        #expect(hex(Data(mac)) == "ebb7fb2ff30f472917dc0a05c21914de5422a54005c91cc835e2d95c109d3755")
        #expect(SecretVault.wrapData("secure-enclave") == Data("nextterm-wrap/1secure-enclave".utf8))
    }
}

@Suite struct SecretVaultKeyringTests {
    @Test func savesAndReadsBackAValue() throws {
        let f = try VaultFixture()
        let opened = try f.unlock(f.file)
        #expect(try opened.value(of: "GITHUB_TOKEN") == SecretBytes(utf8: "ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(opened.index.entries[0].purpose == "GitHub MCP server")
        #expect(opened.index.entries[0].addedByUser)
        #expect(opened.index.keyring == .keychain && opened.index.keyBlob == nil)
        #expect(try SecretVault.index(from: f.file).names == ["GITHUB_TOKEN"])
        #expect(f.keyring.check(publicKey: opened.index.publicKey))
    }

    @Test func anotherKeyringCantOpenIt() throws {
        let f = try VaultFixture()
        #expect(throws: SecretVault.Failure.cantOpen) {
            _ = try SecretVault.unlock(f.file, keyring: SoftwareKeyring(), context: nil)
        }
        #expect(!SoftwareKeyring().check(publicKey: f.vault.index.publicKey))
        // A stored public key that differs from the keyring's.
        let other = SoftwareKeyring().publicKey().base64EncodedString()
        let planted = try edited(f.file, vault: f.vault, resealed: true) { $0["publicKey"] = other }
        #expect(throws: SecretVault.Failure.cantOpen) { _ = try f.unlock(planted) }
        // A keyring of another kind.
        let enclave = SoftwareKeyring(kind: .secureEnclave, key: f.keyring.key)
        #expect(throws: SecretVault.Failure.cantOpen) { _ = try SecretVault.unlock(f.file, keyring: enclave, context: nil) }
    }

    @Test func aCancelledKeyringIsCancelled() throws {
        final class Refusing: VaultKeyring {
            let kind = VaultKeyringKind.keychain
            let keyBlob: Data? = nil
            let inner: SoftwareKeyring
            init(_ inner: SoftwareKeyring) { self.inner = inner }
            func publicKey() throws -> Data { inner.publicKey() }
            func check(publicKey: Data) -> Bool { true }
            func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey, context: AnyObject?) throws -> VaultKeyringSecret {
                throw SecretVault.Failure.cancelled
            }
        }
        let f = try VaultFixture()
        #expect(throws: SecretVault.Failure.cancelled) { _ = try SecretVault.unlock(f.file, keyring: Refusing(f.keyring), context: nil) }
    }

    @Test func createMakesAFreshMaskKey() throws {
        let one = try SecretVault.create(keyring: SoftwareKeyring())
        let two = try SecretVault.create(keyring: SoftwareKeyring())
        #expect(one.maskKey.count == 32 && two.maskKey.count == 32)
        #expect(one.maskKey != two.maskKey)
        #expect(one.vault.index.entries.isEmpty && one.vault.isUnlocked)
    }

    @Test func aWipedVaultReleasesNothing() throws {
        let f = try VaultFixture()
        f.vault.wipe()
        #expect(throws: SecretVault.Failure.locked) { _ = try f.vault.value(of: "GITHUB_TOKEN") }
        #expect(throws: SecretVault.Failure.locked) { _ = try f.vault.delete("GITHUB_TOKEN") }
    }

    @Test func theRecoveryWrap() throws {
        let f = try VaultFixture()
        #expect(!f.vault.index.hasRecovery)
        let recovery = SecretVault.randomBytes(32)
        let file = try f.vault.addRecovery(key: recovery)
        #expect(try SecretVault.index(from: file).hasRecovery)
        // The recovery key alone opens it, and the Secure Enclave keyring still does too.
        let rescued = try SecretVault.unlock(file, recovery: recovery)
        #expect(try rescued.value(of: "GITHUB_TOKEN").count == 40)
        #expect(try f.unlock(file).value(of: "GITHUB_TOKEN").count == 40)
        // Another recovery key, or a vault without the second wrap, can't.
        #expect(throws: SecretVault.Failure.cantOpen) { _ = try SecretVault.unlock(file, recovery: SecretVault.randomBytes(32)) }
        #expect(throws: SecretVault.Failure.cantOpen) { _ = try SecretVault.unlock(f.file, recovery: recovery) }
        // A changed recovery box fails the MAC.
        let changed = try edited(file, vault: f.vault, resealed: false) { body in
            var recoveryBox = body["recovery"] as? [String: Any] ?? [:]
            recoveryBox["box"] = Data(repeating: 1, count: 60).base64EncodedString()
            body["recovery"] = recoveryBox
        }
        #expect(throws: SecretVault.Failure.tampered) { _ = try f.unlock(changed) }
        // A new keyring takes over: F-a's rescue.
        let newKeyring = SoftwareKeyring(kind: .secureEnclave)
        let rewrapped = try rescued.rewrap(under: newKeyring)
        let reopened = try SecretVault.unlock(rewrapped, keyring: newKeyring, context: nil)
        #expect(try reopened.value(of: "GITHUB_TOKEN").count == 40)
        #expect(reopened.index.keyring == .secureEnclave && reopened.index.hasRecovery)
        #expect(throws: SecretVault.Failure.cantOpen) { _ = try f.unlock(rewrapped) }
    }

    @Test func theImportsKeptValuesAreSealed() throws {
        let f = try VaultFixture()
        let values = [SecretBytes(utf8: "kept-one-0123456789"), SecretBytes(utf8: "kept-two-abcdefghij")]
        let box = try f.vault.sealBackup(values, id: "rec-1")
        #expect(!String(decoding: box, as: UTF8.self).contains("kept-one"))
        let opened = try f.vault.openBackup(box, id: "rec-1")
        #expect(opened == values)
        #expect(throws: SecretVault.Failure.tampered) { _ = try f.vault.openBackup(box, id: "rec-2") }
    }
}

@Suite struct SecretVaultChangeTests {
    @Test func editReplaceMakeWriteOnlyAndDelete() throws {
        let f = try VaultFixture()
        let purposeFile = try f.vault.edit("GITHUB_TOKEN", purpose: "the agent's words", purposeBy: .agent)
        #expect(try f.unlock(purposeFile).index.entries[0].purposeBy == .agent)
        let replaced = try f.vault.replace("GITHUB_TOKEN", value: SecretBytes(utf8: "  new-value-0123456789\n"), writeOnly: false,
                                           origin: .agent)
        let opened = try f.unlock(replaced)
        #expect(try opened.value(of: "GITHUB_TOKEN") == SecretBytes(utf8: "new-value-0123456789")) // trimmed
        #expect(opened.index.entries[0].origin == .agent && !opened.index.entries[0].addedByUser)
        #expect(opened.index.entries[0].purpose == "the agent's words") // a replace keeps the purpose
        let writeOnly = try f.vault.makeWriteOnly("GITHUB_TOKEN")
        let locked = try f.unlock(writeOnly)
        #expect(locked.index.entries[0].writeOnly)
        #expect(try locked.value(of: "GITHUB_TOKEN") == SecretBytes(utf8: "new-value-0123456789"))
        #expect(throws: SecretVault.Failure.writeOnly("GITHUB_TOKEN")) { _ = try locked.shownValue(of: "GITHUB_TOKEN") }
        // Replace may clear the flag.
        let cleared = try f.unlock(try f.vault.replace("GITHUB_TOKEN", value: SecretBytes(utf8: "third-value-0123456789"), writeOnly: false))
        #expect(try cleared.shownValue(of: "GITHUB_TOKEN") == SecretBytes(utf8: "third-value-0123456789"))
        let deleted = try f.vault.delete("GITHUB_TOKEN")
        #expect(try SecretVault.index(from: deleted).entries.isEmpty)
        #expect(throws: SecretVault.Failure.noSuchKey("GITHUB_TOKEN")) { _ = try f.vault.value(of: "GITHUB_TOKEN") }
    }

    @Test func limits() throws {
        let f = try VaultFixture()
        let short = SecretBytes(utf8: "value-0123456789")
        func add(_ name: String, _ value: SecretBytes = SecretBytes(utf8: "value-0123456789"), purpose: String = "") throws {
            _ = try f.vault.add(name: name, purpose: purpose, purposeBy: .user, origin: .settings, writeOnly: false, value: value)
        }
        #expect(throws: SecretVault.Failure.valueTooLong("BIG")) { try add("BIG", SecretBytes([UInt8](repeating: 65, count: 16 * 1024 + 1))) }
        try add("BIG", SecretBytes([UInt8](repeating: 65, count: 16 * 1024)))
        #expect(throws: SecretVault.Failure.badPurpose) { try add("LONG", purpose: String(repeating: "a", count: 201)) }
        try add("LONG", purpose: String(repeating: "a", count: 200))
        #expect(throws: SecretVault.Failure.badPurpose) { try add("LINES", purpose: "one\ntwo") }
        #expect(throws: SecretVault.Failure.badValue("LF")) { try add("LF", SecretBytes(utf8: "abc\ndef")) }
        #expect(throws: SecretVault.Failure.badValue("CR")) { try add("CR", SecretBytes(utf8: "abc\rdef")) }
        #expect(throws: SecretVault.Failure.badValue("NUL")) { try add("NUL", SecretBytes([0x61, 0x00, 0x62])) }
        #expect(throws: SecretVault.Failure.badValue("EMPTY")) { try add("EMPTY", SecretBytes(utf8: "  \n")) }
        #expect(throws: SecretVault.Failure.badValue("BINARY")) { try add("BINARY", SecretBytes([0xFF, 0xFE, 0x41])) }
        #expect(throws: SecretVault.Failure.badName) { try add("github_token", short) }
        #expect(throws: SecretVault.Failure.nameTaken("GITHUB_TOKEN")) { try add("GITHUB_TOKEN", short) }
        while f.vault.index.entries.count < SecretVault.maxEntries {
            try add("K\(f.vault.index.entries.count)", short)
        }
        #expect(throws: SecretVault.Failure.tooManyKeys) { try add("ONE_MORE", short) }
        // A file over the cap is refused before it is decoded.
        #expect(throws: SecretVault.Failure.tooLarge) { _ = try SecretVault.index(from: Data(count: 9 * 1024 * 1024)) }
        #expect(throws: SecretVault.Failure.tampered) { _ = try SecretVault.index(from: Data("not json".utf8)) }
    }

    @Test func secretBytesPrintAsDots() {
        let value = SecretBytes(utf8: "ghp_abcdefghijklmnopqrstuvwxyz0123456789")
        #expect(value.description == "•••" && value.debugDescription == "•••")
        #expect("\(value)" == "•••" && String(describing: value) == "•••" && String(reflecting: value) == "•••")
        var dumped = ""
        dump(value, to: &dumped)
        #expect(!dumped.contains("ghp_"))
        #expect(!String(describing: SecretVault.Failure.badValue("X")).contains("ghp_"))
    }
}

@Suite struct SecretNameTests {
    @Test func theNameRule() {
        for name in ["GITHUB_TOKEN", "A", "K2", "A_B_C", String(repeating: "A", count: 64)] {
            #expect(SecretName.isValid(name), "\(name)")
        }
        for name in ["github_token", "1KEY", "KEY-1", "\u{0410}PI_KEY", "_KEY", "", "KEY ONE", String(repeating: "A", count: 65)] {
            #expect(!SecretName.isValid(name), "\(name)")
        }
    }

    @Test func refusedEnvironmentNames() {
        for name in ["PATH", "DYLD_X", "DYLD_INSERT_LIBRARIES", "GIT_SSH_COMMAND", "NEXTTERM_X", "NODE_OPTIONS", "BASH_ENV", "LD_PRELOAD"] {
            #expect(SecretName.isRefusedEnvName(name), "\(name)")
        }
        for name in ["GITHUB_TOKEN", "OPENAI_API_KEY", "PATHS", "GITHUB_PAT"] {
            #expect(!SecretName.isRefusedEnvName(name), "\(name)")
        }
    }

    @Test func suggestedNames() {
        #expect(SecretName.suggested(from: "github-token") == "GITHUB_TOKEN")
        #expect(SecretName.suggested(from: "2fa") == "KEY_2FA")
        #expect(SecretName.suggested(from: "apiKey") == "APIKEY")
        #expect(SecretName.suggested(from: "-token-") == "TOKEN")
        #expect(SecretName.suggested(from: "") == "KEY")
        #expect(SecretName.isValid(SecretName.suggested(from: String(repeating: "x", count: 100))))
        #expect(SecretName.isValid(SecretName.suggested(from: "clé d’API")))
    }
}

/// A temporary Application Support folder.
private final class FolderFixture {
    let base: URL
    let folder: SecretFolder

    init() throws {
        base = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("nt-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        folder = SecretFolder(applicationSupport: base)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    var nextTerm: URL { base.appendingPathComponent("Next Term") }

    func mode(_ path: String) -> mode_t {
        var info = stat()
        lstat(path, &info)
        return info.st_mode & 0o777
    }

    func isExcluded(_ name: String) -> Bool {
        let url = folder.url.appendingPathComponent(name)
        return (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }
}

@Suite struct SecretFolderTests {
    @Test func madePrivateAndChecked() throws {
        let f = try FolderFixture()
        #expect(f.folder.url.path.hasSuffix("/Next Term/Secrets.noindex"))
        try f.folder.ensure()
        #expect(f.mode(f.folder.url.path) == 0o700)
        try f.folder.ensure() // there already: checked
        try f.folder.write(SecretFolder.vaultName, data: Data("{}".utf8), expecting: .noFile)
        try f.folder.write(SecretFolder.maskKeyName, data: Data(count: 32), expecting: .noFile)
        try f.folder.appendAudit(Data("{}\n".utf8))
        _ = try f.folder.ensureImports()
        for name in [SecretFolder.vaultName, SecretFolder.maskKeyName, SecretFolder.auditName] {
            #expect(f.mode(f.folder.path(name)) == 0o600, "\(name)")
        }
        #expect(f.mode(f.folder.path(SecretFolder.importsName)) == 0o700)
        #expect(f.isExcluded(SecretFolder.maskKeyName) && f.isExcluded(SecretFolder.auditName) && f.isExcluded(SecretFolder.importsName))
        #expect(!f.isExcluded(SecretFolder.vaultName)) // Time Machine copies the sealed vault
        #expect(try f.folder.read(SecretFolder.vaultName, cap: 100) == Data("{}".utf8))
        #expect(try f.folder.read("missing", cap: 100) == nil)
    }

    @Test func aLinkOrAnOpenFolderIsRefused() throws {
        let f = try FolderFixture()
        let elsewhere = f.base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: f.nextTerm, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.folder.url, withDestinationURL: elsewhere)
        #expect(throws: SecretFolder.Failure.notPrivate) { try f.folder.ensure() }
        #expect(throws: SecretFolder.Failure.notPrivate) { _ = try f.folder.read(SecretFolder.vaultName, cap: 100) }
        #expect(throws: SecretFolder.Failure.notPrivate) { try f.folder.write(SecretFolder.vaultName, data: Data()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty) // not followed
        try FileManager.default.removeItem(at: f.folder.url)
        try FileManager.default.createDirectory(at: f.folder.url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        #expect(throws: SecretFolder.Failure.notPrivate) { try f.folder.ensure() }
    }

    @Test func aLinkedOrLargeFileIsRefusedUnread() throws {
        let f = try FolderFixture()
        try f.folder.ensure()
        let outside = f.base.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: f.folder.path(SecretFolder.vaultName), withDestinationPath: outside.path)
        #expect(throws: SecretFolder.Failure.refused) { _ = try f.folder.read(SecretFolder.vaultName, cap: 100) }
        #expect(throws: SecretFolder.Failure.refused) { try f.folder.write(SecretFolder.vaultName, data: Data("x".utf8)) }
        #expect(try Data(contentsOf: outside) == Data("{}".utf8))
        // A 9 MB vault.json: refused before it is read.
        let big = f.folder.path("big.json")
        #expect(FileManager.default.createFile(atPath: big, contents: nil, attributes: [.posixPermissions: 0o600]))
        #expect(truncate(big, 9 * 1024 * 1024) == 0)
        #expect(throws: SecretFolder.Failure.tooLarge) { _ = try f.folder.read("big.json", cap: SecretVault.maxFileSize) }
        // A second name for a file (a hard link) is refused too.
        #expect(link(f.folder.path("big.json"), f.folder.path("other.json")) == 0)
        #expect(throws: SecretFolder.Failure.refused) { _ = try f.folder.read("other.json", cap: SecretVault.maxFileSize) }
    }

    @Test func aChangeBetweenReadAndWriteIsRetriedOnTheNewBytes() throws {
        let f = try FolderFixture()
        try f.folder.ensure()
        let keyring = SoftwareKeyring()
        let made = try SecretVault.create(keyring: keyring)
        try f.folder.write(SecretFolder.vaultName, data: made.vault.file, expecting: .noFile)
        // Another copy of Next Term adds a key between this one's read and its write, once.
        var interfered = false
        f.folder.beforeWrite = { _ in
            guard !interfered else { return }
            interfered = true
            let data = (try? f.folder.read(SecretFolder.vaultName, cap: SecretVault.maxFileSize)) ?? nil
            guard let data, let other = try? SecretVault.unlock(data, keyring: keyring, context: nil),
                  let file = try? other.add(name: "OTHER_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                            value: SecretBytes(utf8: "other-value-0123456789")) else { return }
            try? SafeWrite.replace(f.folder.path(SecretFolder.vaultName), with: file)
        }
        var vault: SecretVault?
        var calls = 0
        try f.folder.withLock {
            try f.folder.update { current in
                calls += 1
                let data = try #require(current)
                if let vault { try vault.reload(data) } else { vault = try SecretVault.unlock(data, keyring: keyring, context: nil) }
                return try vault?.add(name: "GITHUB_TOKEN", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                      value: SecretBytes(utf8: "ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
            }
        }
        #expect(calls == 2 && interfered)
        let data = try #require(try f.folder.read(SecretFolder.vaultName, cap: SecretVault.maxFileSize))
        #expect(try SecretVault.index(from: data).names.sorted() == ["GITHUB_TOKEN", "OTHER_KEY"])
        // A file that changes on every try gives `changed`, and keeps the other copy's bytes.
        f.folder.beforeWrite = { _ in try? SafeWrite.replace(f.folder.path(SecretFolder.vaultName), with: Data(UUID().uuidString.utf8)) }
        #expect(throws: SecretFolder.Failure.changed) {
            try f.folder.withLock { try f.folder.update { _ in Data("mine".utf8) } }
        }
        #expect(try f.folder.read(SecretFolder.vaultName, cap: 100) != Data("mine".utf8))
    }

    @Test func startOverNames() throws {
        var taken: Set<String> = []
        #expect(SecretFolder.oldName(day: "2026-10-09") { taken.contains($0) } == "Secrets-2026-10-09.old.noindex")
        taken.insert("Secrets-2026-10-09.old.noindex")
        #expect(SecretFolder.oldName(day: "2026-10-09") { taken.contains($0) } == "Secrets-2026-10-09-2.old.noindex")
        taken.insert("Secrets-2026-10-09-2.old.noindex")
        #expect(SecretFolder.oldName(day: "2026-10-09") { taken.contains($0) } == "Secrets-2026-10-09-3.old.noindex")
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(SecretFolder.day(of: Date(timeIntervalSince1970: 1_791_547_200), timeZone: utc) == "2026-10-09")
    }

    @Test func twoStartOversOnOneDayKeepBothFolders() throws {
        let f = try FolderFixture()
        let utc = try #require(TimeZone(identifier: "UTC"))
        let day = Date(timeIntervalSince1970: 1_791_547_200)
        try f.folder.ensure()
        try f.folder.write(SecretFolder.vaultName, data: Data("first".utf8))
        let first = try f.folder.retire(on: day, timeZone: utc)
        try f.folder.ensure()
        try f.folder.write(SecretFolder.vaultName, data: Data("second".utf8))
        let second = try f.folder.retire(on: day, timeZone: utc)
        try f.folder.ensure()
        #expect(first.lastPathComponent == "Secrets-2026-10-09.old.noindex")
        #expect(second.lastPathComponent == "Secrets-2026-10-09-2.old.noindex")
        #expect(try Data(contentsOf: first.appendingPathComponent(SecretFolder.vaultName)) == Data("first".utf8))
        #expect(try Data(contentsOf: second.appendingPathComponent(SecretFolder.vaultName)) == Data("second".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.folder.url.path).isEmpty)
    }

    @Test func theAuditLogRotatesKeepingOneOlderFile() throws {
        let f = try FolderFixture()
        try f.folder.ensure()
        let line = Data((String(repeating: "x", count: 1023) + "\n").utf8)
        for _ in 0..<(1024 * 2 + 10) { try f.folder.appendAudit(line) }
        let names = try FileManager.default.contentsOfDirectory(atPath: f.folder.url.path).sorted()
        #expect(names == ["audit.log", "audit.log.1"])
        let older = try #require(FileManager.default.attributesOfItem(atPath: f.folder.path(SecretFolder.olderAuditName))[.size] as? Int)
        let current = try #require(FileManager.default.attributesOfItem(atPath: f.folder.path(SecretFolder.auditName))[.size] as? Int)
        // 1,024 lines fill 1 MB: the log rotated twice, and the older file holds the second 1,024.
        #expect(older == SecretAudit.maxSize && current == 10 * 1024)
        #expect(f.isExcluded(SecretFolder.olderAuditName) && f.isExcluded(SecretFolder.auditName))
        #expect(f.mode(f.folder.path(SecretFolder.auditName)) == 0o600)
    }
}

import Foundation
import Testing
@testable import NextTermCore

@Suite struct ReleaseSignatureTests {
    let hex = String(repeating: "0123456789abcdef", count: 4)

    /// The app and the installer trust one key: the one in install.sh, which the site serves.
    @Test func theKeyIsTheInstallers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/install.sh"), encoding: .utf8)
        func value(_ name: String) -> String? {
            guard let range = script.range(of: "local \(name)=\"[^\"]*\"", options: .regularExpression) else { return nil }
            return script[range].split(separator: "\"").dropFirst().first.map(String.init)
        }
        #expect(value("release_key") == ReleaseSignature.publicKey)
        #expect(value("signer") == ReleaseSignature.signer)
        #expect(script.contains("ssh-keygen -Y verify -f \"${work}/allowed_signers\" -I \"${signer}\" -n \(ReleaseSignature.namespace) "))
        #expect(script.contains("printf '%s %s\\n' \"${signer}\" \"${release_key}\" > \"${work}/allowed_signers\""))
    }

    /// The text must be the checksum line of exactly that file, as install.sh compares it.
    @Test func theSignedTextNamesTheVersionedFile() {
        let file = "NextTerm-0.9.0.dmg"
        func sum(_ text: String) -> String? { ReleaseSignature.checksum(Data(text.utf8), naming: file) }
        #expect(sum("\(hex)  NextTerm-0.9.0.dmg\n") == hex)
        #expect(sum("\(hex)  NextTerm-0.9.0.dmg") == hex)
        #expect(sum("\(hex)  NextTerm-0.9.0.dmg\n\n") == hex)
        #expect(sum("\(hex)  NextTerm.dmg\n") == nil)          // the unversioned copy
        #expect(sum("\(hex)  NextTerm-0.8.0.dmg\n") == nil)    // another release's
        #expect(sum("\(hex)  NextTerm-0.9.0.dmg.old\n") == nil)
        #expect(sum("\(hex)  x/NextTerm-0.9.0.dmg\n") == nil)
        #expect(sum("\(hex.uppercased())  NextTerm-0.9.0.dmg\n") == nil)
        #expect(sum("\(hex.dropLast())  NextTerm-0.9.0.dmg\n") == nil)
        #expect(sum(" \(hex)  NextTerm-0.9.0.dmg\n") == nil)
        #expect(sum("\(hex) NextTerm-0.9.0.dmg\n") == nil)
        #expect(sum("\(hex) *NextTerm-0.9.0.dmg\n") == nil)
        #expect(sum("\(hex)  NextTerm-0.9.0.dmg\r\n") == nil)
        #expect(sum("\(hex)  NextTerm-0.9.0.dmg\n\(hex)  NextTerm-0.9.0.dmg\n") == nil)
        #expect(ReleaseSignature.checksum(Data([0xff, 0xfe]), naming: file) == nil)
    }

    /// A key made for the test (never one kept in the repository), signing the way sign-release.sh does.
    @Test func onlyTheKeysSignatureForReleasesCounts() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try makeKey(in: folder, named: "key")
        let other = try makeKey(in: folder, named: "other")
        let checksum = Data("\(hex)  NextTerm-0.9.0.dmg\n".utf8)
        let signature = try sign(checksum, with: folder.appendingPathComponent("key"), in: folder)

        #expect(ReleaseSignature.verify(checksum, signature: signature, key: key))
        #expect(try ReleaseSignature.signedChecksum(checksum, signature: signature, for: "NextTerm-0.9.0.dmg", key: key) == hex)
        // Not the release key's.
        #expect(!ReleaseSignature.verify(checksum, signature: signature))
        #expect(throws: ReleaseSignature.Refusal.notSigned) {
            try ReleaseSignature.signedChecksum(checksum, signature: signature, for: "NextTerm-0.9.0.dmg")
        }
        #expect(!ReleaseSignature.verify(checksum, signature: signature, key: other))
        // Changed text, a signature made for something else, or no signature at all.
        #expect(!ReleaseSignature.verify(Data("\(hex)  NextTerm-0.9.1.dmg\n".utf8), signature: signature, key: key))
        let file = try sign(checksum, with: folder.appendingPathComponent("key"), in: folder, namespace: "file")
        #expect(!ReleaseSignature.verify(checksum, signature: file, key: key))
        #expect(!ReleaseSignature.verify(checksum, signature: Data(), key: key))
        #expect(!ReleaseSignature.verify(checksum, signature: Data("Not Found".utf8), key: key))
        // Signed, but for another file: a signature can't be moved to another release.
        #expect(throws: ReleaseSignature.Refusal.notFor(file: "NextTerm-0.9.1.dmg")) {
            try ReleaseSignature.signedChecksum(checksum, signature: signature, for: "NextTerm-0.9.1.dmg", key: key)
        }
    }

    /// What the updater does with a release: its `.sha256` and `.sha256.sig`, fetched next to the disk image.
    @Test func aReleaseIsCheckedFromItsFiles() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try makeKey(in: folder, named: "key")
        func release(_ tag: String, _ files: [String: Data]) throws -> ReleaseInfo {
            let dir = folder.appendingPathComponent(tag)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, data) in files { try data.write(to: dir.appendingPathComponent(name)) }
            let dmg = dir.appendingPathComponent("NextTerm-\(tag.dropFirst()).dmg")
            return ReleaseInfo(version: try #require(AppVersion(tag)), tag: tag, pageURL: dir, dmgURL: dmg,
                               checksumURL: URL(fileURLWithPath: dmg.path + ".sha256"), notes: "")
        }
        let checksum = Data("\(hex)  NextTerm-0.9.0.dmg\n".utf8)
        let signature = try sign(checksum, with: folder.appendingPathComponent("key"), in: folder)
        let signed = try release("v0.9.0", ["NextTerm-0.9.0.dmg.sha256": checksum, "NextTerm-0.9.0.dmg.sha256.sig": signature])
        #expect(try await ReleaseSignature.signedChecksum(of: signed, key: key) == hex)
        await #expect(throws: ReleaseSignature.Refusal.notSigned) { try await ReleaseSignature.signedChecksum(of: signed) }
        // Not signed yet: nothing to refuse, nothing to install.
        let unsigned = try release("v0.9.1", ["NextTerm-0.9.1.dmg.sha256": Data("\(hex)  NextTerm-0.9.1.dmg\n".utf8)])
        #expect(try await ReleaseSignature.signedChecksum(of: unsigned, key: key) == nil)
        // 0.9.0's signed checksum in another release.
        let moved = try release("v0.9.2", ["NextTerm-0.9.2.dmg.sha256": checksum, "NextTerm-0.9.2.dmg.sha256.sig": signature])
        await #expect(throws: ReleaseSignature.Refusal.notFor(file: "NextTerm-0.9.2.dmg")) {
            try await ReleaseSignature.signedChecksum(of: moved, key: key)
        }
        let empty = try release("v0.9.3", [:])
        await #expect(throws: ReleaseSignature.Refusal.noChecksum) { try await ReleaseSignature.signedChecksum(of: empty, key: key) }
    }

    /// v0.8.0 as published: its checksum and the signature sign-release.sh uploaded, which the embedded key verifies.
    @Test func thePublishedReleaseVerifies() throws {
        let sha = "38deaa5853126a58bb292b17051d06b71120051fc0f41fadd3165886c3369e9b"
        let checksum = Data("\(sha)  NextTerm-0.8.0.dmg\n".utf8)
        let armor = "SSH SIGNATURE" // assembled here, so the file holds no block a secret scanner mistakes for a key
        let signature = Data(("-----BEGIN \(armor)-----\n" + v080Signature + "\n-----END \(armor)-----\n").utf8)
        #expect(try ReleaseSignature.signedChecksum(checksum, signature: signature, for: "NextTerm-0.8.0.dmg") == sha)
        #expect(throws: ReleaseSignature.Refusal.notFor(file: "NextTerm-0.9.0.dmg")) {
            try ReleaseSignature.signedChecksum(checksum, signature: signature, for: "NextTerm-0.9.0.dmg")
        }
        // The unversioned copy has the same SHA-256, but its line was never signed.
        #expect(!ReleaseSignature.verify(Data("\(sha)  NextTerm.dmg\n".utf8), signature: signature))
    }

    /// A release not signed yet: waited for while it is under a day old, for two hours from the click.
    @Test func aReleaseNotSignedYetIsWaitedForAWhile() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let minute: TimeInterval = 60, hour = 60 * minute
        func decide(published: TimeInterval?, since: TimeInterval) -> SignatureWait {
            SignatureWait.decide(published: published.map { now.addingTimeInterval(-$0) }, since: now.addingTimeInterval(-since), now: now)
        }
        #expect(decide(published: 5 * minute, since: 0) == .wait)
        // A day after it was published, a release the key never signed is refused at once.
        #expect(decide(published: 23 * hour + 59 * minute, since: 0) == .wait)
        #expect(decide(published: 24 * hour + minute, since: 0) == .tooOld)
        #expect(decide(published: 24 * hour + minute, since: 3 * hour) == .tooOld)
        // Two hours after the install was asked for, the wait ends.
        #expect(decide(published: 2 * hour, since: hour + 59 * minute) == .wait)
        #expect(decide(published: 2 * hour, since: 2 * hour + minute) == .gaveUp)
        // No date (GitHub's API rate-limited): only the two hours count.
        #expect(decide(published: nil, since: 0) == .wait)
        #expect(decide(published: nil, since: hour + 59 * minute) == .wait)
        #expect(decide(published: nil, since: 2 * hour + minute) == .gaveUp)
    }

    let v080Signature = """
    U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAgiexu/H9+3fK0YL3MCUziFI6qpU
    rLRf3gCHvuYPMCd4YAAAARbmV4dC10ZXJtLXJlbGVhc2UAAAAAAAAABnNoYTUxMgAAAFMA
    AAALc3NoLWVkMjU1MTkAAABAbfWdobIcAgp9rKUUCm1h0/b5togpemIUjH+YVrxy5z/Iz/
    U7XdMUAGBjTootSR+ePbFkV2yM9k25IDfgNMceBQ==
    """

    func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nt-signature-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A new ed25519 key pair in `folder`; returns the public half as "ssh-ed25519 AAAA…".
    func makeKey(in folder: URL, named name: String) throws -> String {
        try sshKeygen(["-q", "-t", "ed25519", "-N", "", "-C", "test", "-f", folder.appendingPathComponent(name).path])
        let line = try String(contentsOf: folder.appendingPathComponent(name + ".pub"), encoding: .utf8)
        return line.split(separator: " ").prefix(2).joined(separator: " ")
    }

    func sign(_ message: Data, with key: URL, in folder: URL, namespace: String = ReleaseSignature.namespace) throws -> Data {
        let file = folder.appendingPathComponent("checksum-\(UUID().uuidString)")
        try message.write(to: file)
        try sshKeygen(["-q", "-Y", "sign", "-f", key.path, "-n", namespace, file.path])
        return try Data(contentsOf: URL(fileURLWithPath: file.path + ".sig"))
    }

    func sshKeygen(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "ssh-keygen \(arguments.joined(separator: " "))")
    }
}

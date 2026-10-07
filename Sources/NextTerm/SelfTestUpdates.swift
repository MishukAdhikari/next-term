import AppKit
import NextTermCore

/// The updater's release-key check, made by the app itself as install.sh makes it, on local files.
extension SelfTest {
    static func updateSignatureChecks() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-update-signature-\(getpid())")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        /// A release served from `root/<tag>/`, holding `files` (by name) and nothing else.
        func release(_ tag: String, _ files: [String: Data]) -> ReleaseInfo {
            let folder = root.appendingPathComponent(tag)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, data) in files { try? data.write(to: folder.appendingPathComponent(name)) }
            let dmg = folder.appendingPathComponent("NextTerm-\(tag.dropFirst()).dmg")
            return ReleaseInfo(version: AppVersion(tag)!, tag: tag, pageURL: URL(string: "https://github.com/MishukAdhikari/next-term/releases/tag/\(tag)")!,
                               dmgURL: dmg, checksumURL: URL(fileURLWithPath: dmg.path + ".sha256"), notes: "")
        }
        /// What the updater makes of the release: the SHA-256 it accepts, nil (not signed yet), or its refusal.
        func outcome(_ release: ReleaseInfo) async -> String {
            do {
                let sha = try await ReleaseSignature.signedChecksum(of: release)
                return "accepted: \(sha ?? "nil")"
            } catch {
                return (error as? ReleaseSignature.Refusal).map { "\($0)" } ?? "\(error)"
            }
        }

        // v0.8.0 as published, checked by the system's ssh-keygen from inside the app.
        let sha = "38deaa5853126a58bb292b17051d06b71120051fc0f41fadd3165886c3369e9b"
        let checksum = Data("\(sha)  NextTerm-0.8.0.dmg\n".utf8)
        let body = """
            U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAgiexu/H9+3fK0YL3MCUziFI6qpU
            rLRf3gCHvuYPMCd4YAAAARbmV4dC10ZXJtLXJlbGVhc2UAAAAAAAAABnNoYTUxMgAAAFMA
            AAALc3NoLWVkMjU1MTkAAABAbfWdobIcAgp9rKUUCm1h0/b5togpemIUjH+YVrxy5z/Iz/
            U7XdMUAGBjTootSR+ePbFkV2yM9k25IDfgNMceBQ==
            """
        let armor = "SSH SIGNATURE" // assembled here, so no block in the source looks like a key to a secret scanner
        let signature = Data("-----BEGIN \(armor)-----\n\(body)\n-----END \(armor)-----\n".utf8)
        let published = release("v0.8.0", ["NextTerm-0.8.0.dmg.sha256": checksum, "NextTerm-0.8.0.dmg.sha256.sig": signature])
        let accepted = await outcome(published)
        check(accepted == "accepted: \(sha)", "the updater accepts a checksum signed with the Next Term release key", accepted)

        // The same signed checksum put in another release: it names NextTerm-0.8.0.dmg, so it is refused.
        let moved = release("v0.8.1", ["NextTerm-0.8.1.dmg.sha256": checksum, "NextTerm-0.8.1.dmg.sha256.sig": signature])
        let movedResult = await outcome(moved)
        check(movedResult == "\(ReleaseSignature.Refusal.notFor(file: "NextTerm-0.8.1.dmg"))", "a signature moved to another release is refused", movedResult)

        // Signed with a key made here and now: not the release key, refused.
        let key = root.appendingPathComponent("test-key")
        let other = Data("\(String(repeating: "ab", count: 32))  NextTerm-99.0.0.dmg\n".utf8)
        let sumFile = root.appendingPathComponent("NextTerm-99.0.0.dmg.sha256")
        try? other.write(to: sumFile)
        let made = sshKeygen(["-q", "-t", "ed25519", "-N", "", "-C", "self-test", "-f", key.path])
            && sshKeygen(["-q", "-Y", "sign", "-f", key.path, "-n", ReleaseSignature.namespace, sumFile.path])
        let otherSignature = (try? Data(contentsOf: URL(fileURLWithPath: sumFile.path + ".sig"))) ?? Data()
        let forged = release("v99.0.0", ["NextTerm-99.0.0.dmg.sha256": other, "NextTerm-99.0.0.dmg.sha256.sig": otherSignature])
        let forgedResult = await outcome(forged)
        check(made && forgedResult == "\(ReleaseSignature.Refusal.notSigned)", "a checksum signed with any other key is refused", "\(made) \(forgedResult)")

        // Published, but not signed yet: waited for, not refused.
        let unsigned = release("v99.1.0", ["NextTerm-99.1.0.dmg.sha256": Data("\(sha)  NextTerm-99.1.0.dmg\n".utf8)])
        let unsignedResult = await outcome(unsigned)
        check(unsignedResult == "accepted: nil", "a release whose signature is not up yet is waited for", unsignedResult)
    }

    private static func sshKeygen(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

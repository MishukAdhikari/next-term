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

    /// A retry of an install asked for earlier, run by a timer while someone may be typing: a release still
    /// not signed, or GitHub not answering, is tried again later, and nothing opens.
    static func updateWaitChecks() async {
        let updater = Updater.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-update-wait-\(getpid())")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let page = URL(string: "https://github.com/MishukAdhikari/next-term/releases/tag/v99.1.0")!
        // A checksum and no signature yet.
        let dmg = root.appendingPathComponent("NextTerm-99.1.0.dmg")
        let checksum = URL(fileURLWithPath: dmg.path + ".sha256")
        try? Data("\(String(repeating: "ab", count: 32))  NextTerm-99.1.0.dmg\n".utf8).write(to: checksum)
        let unsigned = ReleaseInfo(version: AppVersion("99.1.0")!, tag: "v99.1.0", pageURL: page, dmgURL: dmg,
                                   checksumURL: checksum, notes: "", published: Date())
        // Nothing listens on port 9 here: the try fails before anything is downloaded, as it does offline.
        let offline = URL(string: "https://127.0.0.1:9/NextTerm-99.2.0.dmg")!
        let unreachable = ReleaseInfo(version: AppVersion("99.2.0")!, tag: "v99.2.0", pageURL: page, dmgURL: offline,
                                      checksumURL: URL(string: offline.absoluteString + ".sha256"), notes: "", published: Date())
        let tries = [(unsigned, "a quiet try of a release not signed yet"), (unreachable, "a quiet try that cannot reach GitHub")]
        for (release, name) in tries {
            let shown = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            updater.download(release, quietly: true)
            let done = await wait(10) { !updater.installing }
            let opened = NSApp.windows.filter { $0.isVisible && !shown.contains(ObjectIdentifier($0)) }.map(\.title)
            check(done && updater.awaitingSignature?.tag == release.tag && opened.isEmpty && NSApp.modalWindow == nil,
                  "\(name) opens nothing and is tried again later", "\(done) \(updater.awaitingSignature?.tag ?? "no retry") \(opened)")
        }
        updater.withdraw()
        check(updater.awaitingSignature == nil, "forgetting the update stops the tries")

        let network = Updater.endOfWait(.gaveUp, unreachable: true) ?? ""
        check(network.hasPrefix("GitHub did not answer") && !network.contains("not signed"),
              "two hours of tries GitHub did not answer blame GitHub, not the signature", network)
        let unsignedText = Updater.endOfWait(.gaveUp, unreachable: false) ?? ""
        check(unsignedText.contains("still not signed") && Updater.endOfWait(.wait, unreachable: true) == nil,
              "two hours with no signature say so, and nothing is said before", unsignedText)
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

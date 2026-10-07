import Foundation

/// The check made before an update is installed, by the app's updater and by the installer
/// (site/src/install.sh) alike. scripts/sign-release.sh signs each release's `NextTerm-1.2.3.dmg.sha256`
/// with the Next Term release key, whose private half never leaves the maintainer's Mac, so a release
/// changed on GitHub is refused. The signed text names the versioned file, so a signature can't be
/// moved to another release, or to the unversioned `NextTerm.dmg`.
public enum ReleaseSignature {
    /// The release key's public half. install.sh has the same value; a test keeps the two identical.
    public static let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIInsbvx/ft3ytGC9zAlM4hSOqqVKy0X94Ah77mDzAneG"
    /// The key's name in the allowed-signers line, not a web address: it stays as it is when the site moves.
    public static let signer = "release@next-term.mishuk.me"
    public static let namespace = "next-term-release"
    /// The system's, never one found on PATH.
    static let sshKeygen = "/usr/bin/ssh-keygen"

    public enum Refusal: Error, Equatable {
        /// The signature is not the release key's, or not of this checksum, or not for releases.
        case notSigned
        /// The signed text is not the checksum line of the file (another version, or `NextTerm.dmg`).
        case notFor(file: String)
        /// The download is not the file whose checksum was signed.
        case mismatch
        /// The release has no `.sha256` for its disk image.
        case noChecksum
    }

    /// GitHub answered with neither the file nor "not found".
    public struct Unavailable: Error, Equatable {
        public let status: Int
    }

    /// The SHA-256 the release key signed for the release's disk image, read from its `.sha256` and
    /// `.sha256.sig`, or nil while the signature is not up (it is uploaded a few minutes after the
    /// release is published). Anything install.sh refuses throws a `Refusal`.
    public static func signedChecksum(of release: ReleaseInfo, key: String = publicKey) async throws -> String? {
        guard let checksumURL = release.checksumURL, let signatureURL = release.signatureURL,
              let checksum = try await fetch(checksumURL) else { throw Refusal.noChecksum }
        guard let signature = try await fetch(signatureURL) else { return nil }
        return try signedChecksum(checksum, signature: signature, for: release.dmgName, key: key)
    }

    /// A small file of a release; nil when it is not there (yet).
    static func fetch(_ url: URL) async throws -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return data }
            if http.statusCode == 404 { return nil }
            throw Unavailable(status: http.statusCode)
        } catch let error as URLError where error.code == .fileDoesNotExist {
            return nil // a local test feed's
        }
    }

    /// The SHA-256 the release key signed for `file`: `checksum` is the release's `.sha256`, `signature`
    /// its `.sha256.sig`. Exactly what install.sh accepts, or a refusal.
    public static func signedChecksum(_ checksum: Data, signature: Data, for file: String, key: String = publicKey) throws -> String {
        guard verify(checksum, signature: signature, key: key) else { throw Refusal.notSigned }
        guard let hex = Self.checksum(checksum, naming: file) else { throw Refusal.notFor(file: file) }
        return hex
    }

    /// Whether `signature` is `key`'s signature of exactly `message`, made for releases: `ssh-keygen -Y
    /// verify` with an allowed-signers file that holds only that key, as install.sh runs it.
    public static func verify(_ message: Data, signature: Data, key: String = publicKey) -> Bool {
        // The two files ssh-keygen reads, in a folder only this user can open.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("next-term-verify-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: folder) }
        let signers = folder.appendingPathComponent("allowed_signers")
        let sig = folder.appendingPathComponent("checksum.sig")
        guard FileManager.default.createFile(atPath: signers.path, contents: Data("\(signer) \(key)\n".utf8), attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: sig.path, contents: signature, attributes: [.posixPermissions: 0o600]) else { return false }
        let arguments = ["-Y", "verify", "-f", signers.path, "-I", signer, "-n", namespace, "-s", sig.path]
        return GitRunner.run(sshKeygen, arguments, timeout: 15, input: message) != nil
    }

    /// The SHA-256 in a checksum that is exactly `shasum -a 256`'s line for `file`
    /// ("<lowercase hex>  NextTerm-1.2.3.dmg", ending in newlines or not), as install.sh compares it.
    public static func checksum(_ text: Data, naming file: String) -> String? {
        guard var line = String(data: text, encoding: .utf8) else { return nil }
        while line.hasSuffix("\n") { line.removeLast() }
        let name = "  " + file
        guard line.hasSuffix(name) else { return nil }
        let hex = String(line.dropLast(name.count))
        return hex.count == 64 && hex.allSatisfy({ "0123456789abcdef".contains($0) }) ? hex : nil
    }
}

/// What the updater does about a release whose checksum is not signed yet, each time a try finds it so.
/// Each release is signed a few minutes after it is published, so a recent one is waited for, for a while.
public enum SignatureWait: Equatable, Sendable {
    /// Try again later.
    case wait
    /// Published more than `signingDelay` ago and still not signed: it never will be. Refused.
    case tooOld
    /// Waited `limit` since the install was asked for: given up.
    case gaveUp

    public static let signingDelay: TimeInterval = 24 * 60 * 60
    public static let limit: TimeInterval = 2 * 60 * 60

    /// `published` is unknown when GitHub's API is rate-limited (the release came from the releases
    /// page's redirect): then only `limit` ends the wait. `since` is when the install was asked for.
    public static func decide(published: Date?, since: Date, now: Date,
                              signingDelay: TimeInterval = SignatureWait.signingDelay, limit: TimeInterval = SignatureWait.limit) -> SignatureWait {
        if let published, now.timeIntervalSince(published) >= signingDelay { return .tooOld }
        return now.timeIntervalSince(since) < limit ? .wait : .gaveUp
    }
}

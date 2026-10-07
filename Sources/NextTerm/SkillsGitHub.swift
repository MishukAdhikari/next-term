import Foundation
import NextTermCore

/// The few GitHub requests the Skills library makes, only after the user acts: resolve a link to one
/// commit (and prove that commit is the named repository's own), list the skills in it, read the
/// repository's stars and licence, and download that commit's files. Only github.com hosts are
/// accepted, after redirects too.
enum SkillsGitHub {
    struct Failure: Error, Sendable { let message: String }

    typealias Found = SkillFolder

    /// A source resolved to one commit, and the skills in it.
    struct Resolved: Sendable {
        let source: SkillSource
        let commit: String
        let date: Date?
        let skills: [Found]
        /// GitHub cut the file list short (a huge repository): some skills may be missing.
        let truncated: Bool
        /// The source named a branch or tag (updates can follow it), rather than a commit or nothing.
        var namedRef = false
    }

    struct RepoInfo: Sendable {
        let stars: Int
        let license: String?
        let description: String?
        let archived: Bool
        let defaultBranch: String?
    }

    static let allowedHosts: Set<String> = ["api.github.com", "codeload.github.com", "github.com"]
    /// The most a download may be, compressed, and what its skills may unpack to.
    static let maxDownload = 100_000_000
    static let maxUnpacked = 200_000_000
    static let maxEntries = 10_000

    private static var userAgent: String {
        "NextTerm/" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    }

    private static func request(_ url: URL, timeout: TimeInterval = 20) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The answer's status and body; throws only when GitHub can't be reached or answers from elsewhere.
    private static func fetch(_ url: URL) async throws -> (Int, Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request(url)) } catch {
            throw Failure(message: "GitHub could not be reached: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, let host = http.url?.host, allowedHosts.contains(host) else {
            throw Failure(message: "GitHub answered from an unexpected address.")
        }
        return (http.statusCode, data, http)
    }

    private static func get(_ url: URL) async throws -> Data {
        let (status, data, http) = try await fetch(url)
        switch status {
        case 200: return data
        case 404: throw Failure(message: "Not found on GitHub. Next Term installs from public repositories only.")
        case 403, 429:
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                throw Failure(message: "GitHub's limit for requests without an account is used up for this hour. Try again later.")
            }
            throw Failure(message: "GitHub refused the request (\(status)).")
        default: throw Failure(message: "GitHub answered \(status).")
        }
    }

    /// An API address for a repository; owner and repo are checked, never trusted to build.
    private static func api(_ source: SkillSource, _ tail: String) throws -> URL {
        guard source.isValid, let url = URL(string: "https://api.github.com/repos/\(source.owner)/\(source.repo)" + (tail.isEmpty ? "" : "/" + tail)) else {
            throw Failure(message: "That is not a GitHub repository Next Term can read.")
        }
        return url
    }

    private static func encoded(_ ref: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        return ref.addingPercentEncoding(withAllowedCharacters: allowed) ?? ref
    }

    /// The commit a source points to now, and every skill folder in it (under the source's path). A ref
    /// must be one of the repository's own branches or tags, or a commit on its default branch: GitHub
    /// also serves commits that exist only in a fork under the parent's name.
    static func resolve(_ source: SkillSource) async throws -> Resolved {
        let ref = source.ref.map(encoded) ?? "HEAD"
        let commitData = try await get(try api(source, "commits/\(ref)"))
        guard let commitJSON = try? JSONSerialization.jsonObject(with: commitData) as? [String: Any],
              let sha = commitJSON["sha"] as? String, sha.count == 40,
              let commit = commitJSON["commit"] as? [String: Any],
              let rootTree = (commit["tree"] as? [String: Any])?["sha"] as? String else {
            throw Failure(message: "GitHub's answer about the commit could not be read.")
        }
        var namedRef = false
        if let given = source.ref {
            namedRef = try await isBranchOrTag(source, given)
            if !namedRef {
                guard let branch = await info(owner: source.owner, repo: source.repo)?.defaultBranch else {
                    throw Failure(message: "Next Term could not check that this commit belongs to \(source.shortName).")
                }
                let (status, data, _) = try await fetch(try api(source, "compare/\(sha)...\(encoded(branch))"))
                let state = status == 200 ? (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String : nil
                guard SkillTreeListing.commitIsOnBranch(compareStatus: state) else {
                    throw Failure(message: "This commit is not on any branch or tag of \(source.shortName); it may come from a fork. Use the fork's own address, or a branch or tag.")
                }
            }
        }
        let date = ((commit["committer"] as? [String: Any])?["date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let treeData = try await get(try api(source, "git/trees/\(sha)?recursive=1"))
        guard let listing = SkillTreeListing.parse(treeData, rootTree: rootTree, prefix: source.path) else {
            throw Failure(message: "GitHub's list of files could not be read.")
        }
        return Resolved(source: source, commit: sha, date: date, skills: listing.skills, truncated: listing.truncated, namedRef: namedRef)
    }

    /// Whether `ref` names one of the repository's own branches or tags (those resolve only inside it).
    private static func isBranchOrTag(_ source: SkillSource, _ ref: String) async throws -> Bool {
        for kind in ["heads", "tags"] {
            let (status, _, _) = try await fetch(try api(source, "git/ref/\(kind)/\(encoded(ref))"))
            if status == 200 { return true }
        }
        return false
    }

    /// Every file in a tree (a skill folder's, by its hash), with its blob hash and whether it is a link;
    /// nil when GitHub can't say (offline, gone, cut short).
    static func treeBlobs(owner: String, repo: String, tree: String) async -> [String: SkillEdits.Blob]? {
        let source = SkillSource(owner: owner, repo: repo)
        guard tree.count == 40, tree.allSatisfy(\.isHexDigit), let url = try? api(source, "git/trees/\(tree)?recursive=1"),
              let data = try? await get(url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["truncated"] as? Bool != true, let entries = json["tree"] as? [[String: Any]] else { return nil }
        var blobs: [String: SkillEdits.Blob] = [:]
        for entry in entries where entry["type"] as? String == "blob" {
            guard let path = entry["path"] as? String, let sha = entry["sha"] as? String else { continue }
            blobs[path] = SkillEdits.Blob(sha: sha, link: entry["mode"] as? String == "120000")
        }
        return blobs
    }

    static func info(owner: String, repo: String) async -> RepoInfo? {
        let source = SkillSource(owner: owner, repo: repo)
        guard let url = try? api(source, ""), let data = try? await get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let license = (json["license"] as? [String: Any])?["spdx_id"] as? String
        return RepoInfo(stars: json["stargazers_count"] as? Int ?? 0, license: license == "NOASSERTION" ? nil : license,
                        description: json["description"] as? String, archived: json["archived"] as? Bool ?? false,
                        defaultBranch: json["default_branch"] as? String)
    }

    // MARK: downloading

    /// Downloads the commit's files (at most `maxDownload` bytes), checks what the skills would unpack
    /// to, and unpacks only the skill folders, in a private folder. Returns the repository's top folder
    /// there; the caller removes `scratch` when done.
    static func download(owner: String, repo: String, commit: String, paths: [String], into scratch: URL) async throws -> URL {
        let source = SkillSource(owner: owner, repo: repo)
        guard source.isValid, commit.count == 40, commit.allSatisfy(\.isHexDigit),
              let url = URL(string: "https://codeload.github.com/\(owner)/\(repo)/tar.gz/\(commit)") else {
            throw Failure(message: "That is not a GitHub commit Next Term can download.")
        }
        let manager = FileManager.default
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = scratch.appendingPathComponent("source.tar.gz")
        defer { try? manager.removeItem(at: archive) }
        try await save(url, to: archive)

        // The folder tar puts everything in.
        let listing = try await tar(["-tzf", archive.path], timeout: 30)
        guard let top = listing.split(separator: "\n").first?.split(separator: "/").first.map(String.init), !top.isEmpty else {
            throw Failure(message: "The downloaded files could not be read.")
        }
        let wanted = paths.contains("") ? [top] : paths.map { top + "/" + $0 }
        // Only the skill folders, by patterns in a file (see tarPatternList). Counted with the same
        // patterns tar unpacks with, one entry per line: names can't be compared here, since tar writes
        // the ones it can't print in this locale as escapes.
        let patterns = scratch.appendingPathComponent("patterns")
        try SkillTreeListing.tarPatternList(wanted).write(to: patterns)
        defer { try? manager.removeItem(at: patterns) }
        let select = ["--null", "-T", patterns.path]
        let selected = try await tar(["-tvzf", archive.path] + select, timeout: 30, missingIsFine: true)
        var bytes = 0, count = 0
        for line in selected.split(separator: "\n") {
            count += 1
            bytes += entrySize(String(line))
        }
        guard count <= maxEntries else { throw Failure(message: "The skill holds too many files (\(count)) to review.") }
        guard bytes <= maxUnpacked else { throw Failure(message: "The skill is too large to review (\(bytes / 1_000_000) MB unpacked).") }

        let unpacked = scratch.appendingPathComponent("files", isDirectory: true)
        try manager.createDirectory(at: unpacked, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // bsdtar keeps paths inside the folder (it refuses ".." and absolute paths), does not write
        // through links, and does not restore owners.
        _ = try await tar(["-xzf", archive.path, "-C", unpacked.path, "--no-same-owner"] + select, timeout: 60, missingIsFine: true)
        let folder = unpacked.appendingPathComponent(top, isDirectory: true)
        let missing = paths.contains { !manager.fileExists(atPath: folder.appendingPathComponent($0).path) }
        guard manager.fileExists(atPath: folder.path), !missing else { throw Failure(message: "The downloaded files could not be unpacked.") }
        return folder
    }

    /// Streams the download to a file, stopping as soon as it passes `maxDownload`.
    private static func save(_ url: URL, to file: URL) async throws {
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await URLSession.shared.bytes(for: request(url, timeout: 60)) } catch {
            throw Failure(message: "The download failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let host = http.url?.host, allowedHosts.contains(host) else {
            throw Failure(message: "GitHub did not send the files.")
        }
        if response.expectedContentLength > maxDownload { throw Failure(message: "The repository is too large to download.") }
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: file) else { throw Failure(message: "The download could not be saved.") }
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var total = 0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == 1 << 20 {
                    total += buffer.count
                    guard total <= maxDownload else { throw Failure(message: "The repository is too large to download (over \(maxDownload / 1_000_000) MB).") }
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try handle.write(contentsOf: buffer)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: "The download failed: \(error.localizedDescription)")
        }
    }

    /// A `tar -tv` line's size (the fifth field).
    static func entrySize(_ line: String) -> Int {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        return fields.count > 4 ? Int(fields[4]) ?? 0 : 0
    }

    /// Runs /usr/bin/tar off the main thread, stopping it after `timeout` seconds (a crafted archive can
    /// take long to read). `missingIsFine`: patterns that matched nothing are not a failure.
    private static func tar(_ arguments: [String], timeout: TimeInterval, missingIsFine: Bool = false) async throws -> String {
        let result = await Task.detached { () -> String? in
            let manager = FileManager.default
            // Complaints go to a file: a pipe left unread could fill up and stop tar.
            let errors = manager.temporaryDirectory.appendingPathComponent("nextterm-tar-\(UUID().uuidString)")
            guard manager.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let errorHandle = try? FileHandle(forWritingTo: errors) else { return nil }
            defer { try? manager.removeItem(at: errors) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = arguments
            let out = Pipe()
            process.standardOutput = out
            process.standardError = errorHandle
            guard (try? process.run()) != nil else { return nil }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            try? errorHandle.close()
            guard process.terminationReason == .exit else { return nil }
            if process.terminationStatus != 0 {
                guard missingIsFine, process.terminationStatus == 1 else { return nil }
                let size = (try? manager.attributesOfItem(atPath: errors.path))?[.size] as? Int
                guard let size, size <= 1_000_000, let text = try? String(contentsOf: errors, encoding: .utf8),
                      SkillTreeListing.tarErrorsAreOnlyMissingNames(text) else { return nil }
            }
            return String(decoding: data, as: UTF8.self)
        }.value
        guard let result else { throw Failure(message: "The downloaded files could not be unpacked.") }
        return result
    }
}

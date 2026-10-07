import Foundation
import NextTermCore

/// The few GitHub requests the Skills library makes, only after the user (or an approved agent request)
/// asks: resolve a link to one commit, list the skills in it, read the repository's stars and licence,
/// and download that commit's files. Only github.com hosts are accepted, after redirects too.
enum SkillsGitHub {
    struct Failure: Error, Sendable { let message: String }

    /// A source resolved to one commit, and the skills in it.
    struct Resolved: Sendable {
        let source: SkillSource
        let commit: String
        let date: Date?
        let skills: [Found]
        /// GitHub cut the file list short (a huge repository): some skills may be missing.
        let truncated: Bool
    }

    struct Found: Equatable, Sendable {
        /// The skill's folder in the repository ("" for the root).
        let path: String
        /// That folder's git tree hash at the commit.
        let tree: String
        /// SKILL.md's path (what the lock file records).
        var skillPath: String { path.isEmpty ? "SKILL.md" : path + "/SKILL.md" }
    }

    struct RepoInfo: Sendable {
        let stars: Int
        let license: String?
        let description: String?
        let archived: Bool
    }

    static let allowedHosts: Set<String> = ["api.github.com", "codeload.github.com", "github.com"]

    private static var userAgent: String {
        "NextTerm/" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    }

    private static func get(_ url: URL, accept: String = "application/vnd.github+json") async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch {
            throw Failure(message: "GitHub could not be reached: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, let host = http.url?.host, allowedHosts.contains(host) else {
            throw Failure(message: "GitHub answered from an unexpected address.")
        }
        switch http.statusCode {
        case 200: return data
        case 404: throw Failure(message: "Not found on GitHub. Next Term installs from public repositories only.")
        case 403, 429:
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                throw Failure(message: "GitHub's limit for requests without an account is used up for this hour. Try again later.")
            }
            throw Failure(message: "GitHub refused the request (\(http.statusCode)).")
        default: throw Failure(message: "GitHub answered \(http.statusCode).")
        }
    }

    private static func api(_ path: String) -> URL { URL(string: "https://api.github.com/repos/" + path)! }

    /// The commit a source points to now, and every skill folder in it (under the source's path).
    static func resolve(_ source: SkillSource) async throws -> Resolved {
        let ref = source.ref.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) } ?? "HEAD"
        let commitData = try await get(api("\(source.owner)/\(source.repo)/commits/\(ref)"))
        guard let commitJSON = try? JSONSerialization.jsonObject(with: commitData) as? [String: Any],
              let sha = commitJSON["sha"] as? String, sha.count == 40,
              let commit = commitJSON["commit"] as? [String: Any],
              let rootTree = (commit["tree"] as? [String: Any])?["sha"] as? String else {
            throw Failure(message: "GitHub's answer about the commit could not be read.")
        }
        let date = ((commit["committer"] as? [String: Any])?["date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let treeData = try await get(api("\(source.owner)/\(source.repo)/git/trees/\(sha)?recursive=1"))
        guard let treeJSON = try? JSONSerialization.jsonObject(with: treeData) as? [String: Any],
              let entries = treeJSON["tree"] as? [[String: Any]] else {
            throw Failure(message: "GitHub's list of files could not be read.")
        }
        var folders: [String: String] = ["": rootTree]
        var skillFolders: [String] = []
        for entry in entries {
            guard let path = entry["path"] as? String, let type = entry["type"] as? String else { continue }
            if type == "tree", let hash = entry["sha"] as? String { folders[path] = hash }
            if type == "blob", ["SKILL.md", "skill.md"].contains((path as NSString).lastPathComponent) {
                skillFolders.append((path as NSString).deletingLastPathComponent)
            }
        }
        let prefix = source.path
        let found = skillFolders
            .filter { prefix.isEmpty || $0 == prefix || $0.hasPrefix(prefix + "/") }
            .compactMap { folder in folders[folder].map { Found(path: folder, tree: $0) } }
            .sorted { $0.path < $1.path }
        return Resolved(source: source, commit: sha, date: date, skills: found, truncated: treeJSON["truncated"] as? Bool ?? false)
    }

    static func info(owner: String, repo: String) async -> RepoInfo? {
        guard let data = try? await get(api("\(owner)/\(repo)")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let license = (json["license"] as? [String: Any])?["spdx_id"] as? String
        return RepoInfo(stars: json["stargazers_count"] as? Int ?? 0, license: license == "NOASSERTION" ? nil : license,
                        description: json["description"] as? String, archived: json["archived"] as? Bool ?? false)
    }

    /// Downloads the commit's files and unpacks them in a private folder. Returns the repository's
    /// top folder there; the caller removes `scratch` when done.
    static func download(owner: String, repo: String, commit: String, into scratch: URL) async throws -> URL {
        let url = URL(string: "https://codeload.github.com/\(owner)/\(repo)/tar.gz/\(commit)")!
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let file: URL, response: URLResponse
        do { (file, response) = try await URLSession.shared.download(for: request) } catch {
            throw Failure(message: "The download failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let host = http.url?.host, allowedHosts.contains(host) else {
            throw Failure(message: "GitHub did not send the files.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size <= 100_000_000 else { throw Failure(message: "The repository is too large to download (\(size / 1_000_000) MB).") }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let archive = scratch.appendingPathComponent("source.tar.gz")
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: file, to: archive)
        let unpacked = scratch.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        // bsdtar keeps paths inside the folder (it refuses ".." and absolute paths) and does not restore owners.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", unpacked.path, "--no-same-owner"]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0,
              let top = try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).first(where: { $0.hasDirectoryPath }) else {
            throw Failure(message: "The downloaded files could not be unpacked.")
        }
        return top
    }
}

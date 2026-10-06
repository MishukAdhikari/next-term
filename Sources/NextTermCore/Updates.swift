import Foundation

/// A version like "0.1.0" or "v1.2.3-beta.1", compared the way people expect: 0.10.0 is newer than 0.9.2,
/// and a pre-release is older than its release.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let numbers: [Int]
    public let preRelease: String?

    public init?(_ text: String) {
        var core = Substring(text.trimmingCharacters(in: .whitespaces))
        if core.first == "v" || core.first == "V" { core = core.dropFirst() }
        var pre: Substring?
        if let dash = core.firstIndex(of: "-") {
            pre = core[core.index(after: dash)...]
            core = core[..<dash]
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        numbers = parts.map { $0! }
        preRelease = pre.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
    }

    public var description: String { numbers.map(String.init).joined(separator: ".") + (preRelease.map { "-" + $0 } ?? "") }

    public static func < (a: Self, b: Self) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0, y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        switch (a.preRelease, b.preRelease) {
        case (nil, _): return false                   // a release is never older than anything with its number
        case (.some, nil): return true                // 1.0.0-beta < 1.0.0
        case let (.some(p), .some(q)): return p.compare(q, options: .numeric) == .orderedAscending
        }
    }

    public static func == (a: Self, b: Self) -> Bool { !(a < b) && !(b < a) }
}

/// The parts of a GitHub release that matter for updating.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: AppVersion
    public let tag: String
    public let pageURL: URL
    public let dmgURL: URL?
    public let checksumURL: URL?
    public let notes: String
    public let published: Date?

    public init(version: AppVersion, tag: String, pageURL: URL, dmgURL: URL?, checksumURL: URL?, notes: String, published: Date? = nil) {
        self.version = version
        self.tag = tag
        self.pageURL = pageURL
        self.dmgURL = dmgURL
        self.checksumURL = checksumURL
        self.notes = notes
        self.published = published
    }

    /// Parses GitHub's `GET /repos/{owner}/{repo}/releases/latest` JSON. Drafts and pre-releases are
    /// ignored (the endpoint never returns them, but a mirror might). Downloads are accepted only over
    /// https from GitHub, unless `allowingFileURLs` (a local test feed).
    public static func parse(_ data: Data, allowingFileURLs: Bool = false) -> ReleaseInfo? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { parse(json: $0, allowingFileURLs: allowingFileURLs) }
    }

    /// Parses `GET /repos/{owner}/{repo}/releases` (newest first): the releases the update window
    /// shows notes for when more than one came out since this version.
    public static func parseList(_ data: Data, allowingFileURLs: Bool = false) -> [ReleaseInfo] {
        ((try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []).compactMap { parse(json: $0, allowingFileURLs: allowingFileURLs) }
    }

    /// The releases to show notes for, newest first: every release after `current` up to `latest`
    /// (at most `limit`), always including `latest` itself.
    public static func since(_ current: AppVersion, latest: ReleaseInfo, among releases: [ReleaseInfo], limit: Int = 5) -> [ReleaseInfo] {
        var newer = releases.filter { current < $0.version && !(latest.version < $0.version) && $0.version != latest.version }
        newer.sort { $1.version < $0.version }
        return Array(([latest] + newer).prefix(limit))
    }

    private static func parse(json: [String: Any], allowingFileURLs: Bool) -> ReleaseInfo? {
        guard let tag = json["tag_name"] as? String, let version = AppVersion(tag),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true else { return nil }
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        func trusted(_ url: URL) -> Bool {
            if allowingFileURLs, url.isFileURL { return true }
            guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
            return host == "github.com" || host.hasSuffix(".github.com") || host.hasSuffix(".githubusercontent.com")
        }
        func asset(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(suffix) == true }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
                .flatMap { trusted($0) ? $0 : nil }
        }
        return ReleaseInfo(version: version, tag: tag, pageURL: page, dmgURL: asset(".dmg"), checksumURL: asset(".dmg.sha256"),
                           notes: (json["body"] as? String) ?? "",
                           published: (json["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    /// When the API refuses (60 requests an hour per address, shared behind an office router), the
    /// releases page still redirects `…/releases/latest` to `…/releases/tag/v1.2.3`; the assets are
    /// always `NextTerm-1.2.3.dmg` and its `.sha256` (scripts/build-dmg.sh and CI name them so).
    public static func fromLatestRedirect(_ finalURL: URL, repository: String) -> ReleaseInfo? {
        // Exactly /owner/repo/releases/tag/<tag>.
        let parts = finalURL.pathComponents.filter { $0 != "/" }
        let expected = repository.split(separator: "/").map(String.init)
        guard finalURL.scheme == "https", finalURL.host?.lowercased() == "github.com", expected.count == 2,
              parts.count == 5, parts[0].lowercased() == expected[0].lowercased(), parts[1].lowercased() == expected[1].lowercased(),
              parts[2] == "releases", parts[3] == "tag", let version = AppVersion(parts[4]) else { return nil }
        let tag = parts[4]
        let base = "https://github.com/\(repository)/releases/download/\(tag)/NextTerm-\(version).dmg"
        return ReleaseInfo(version: version, tag: tag, pageURL: finalURL, dmgURL: URL(string: base),
                           checksumURL: URL(string: base + ".sha256"), notes: "")
    }

    /// The hex SHA-256 from a `shasum -a 256` line ("<hex>  NextTerm-0.1.1.dmg").
    public static func checksum(fromShasumLine text: String) -> String? {
        let hex = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first.map(String.init)?.lowercased() ?? ""
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }
}

import Foundation

/// A project's remote on github.com or gitlab.com, read from its git remote only to prefill Settings › Tasks. It never
/// chooses a destination by itself. Only the three usual spellings are read (`git@host:path`, `https://host/path`
/// and `ssh://git@host/path`, each with or without `.git`); any other host, a port, plain `http://` or a path part
/// outside letters, digits, `.`, `_` and `-` gives nil.
public struct RepositoryAddress: Equatable, Hashable, Sendable {
    public enum Host: String, Sendable {
        case github = "github.com"
        case gitlab = "gitlab.com"
    }

    public let host: Host
    /// `owner/repo` on GitHub; `group/…/project` on GitLab, subgroups included.
    public let path: String

    public init(host: Host, path: String) {
        self.host = host
        self.path = path
    }

    /// The first part of the path: the GitHub owner, or the top GitLab group.
    public var owner: String { String(path.split(separator: "/").first ?? "") }
    /// The last part of the path: the repository or project.
    public var repo: String { String(path.split(separator: "/").last ?? "") }

    /// The destination this address would prefill.
    public var destination: TaskDestination {
        switch host {
        case .github: return .github(owner: owner, repo: repo)
        case .gitlab: return .gitlab(path: path)
        }
    }

    /// The address a remote URL names, or nil when it is not one of the three spellings on github.com or gitlab.com.
    public static func parse(_ remoteURL: String) -> RepositoryAddress? {
        let text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (hostText, pathText) = split(text) else { return nil }
        guard let host = Host(rawValue: hostText.lowercased()) else { return nil }
        var path = Substring(pathText)
        if path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let address = RepositoryAddress(host: host, path: String(path))
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        if host == .github, segments.count != 2 { return nil }
        return address.destination.problem == nil ? address : nil
    }

    /// The host and the path of one of the three spellings; nil for any other.
    static func split(_ text: String) -> (host: String, path: String)? {
        let rest: Substring
        let separator: Character
        if text.hasPrefix("https://") {
            rest = text.dropFirst("https://".count)
            separator = "/"
        } else if text.hasPrefix("ssh://git@") {
            rest = text.dropFirst("ssh://git@".count)
            separator = "/"
        } else if text.hasPrefix("git@") {
            rest = text.dropFirst("git@".count)
            separator = ":"
        } else {
            return nil
        }
        guard let index = rest.firstIndex(of: separator) else { return nil }
        let host = String(rest[..<index])
        let path = String(rest[rest.index(after: index)...])
        return (host, path)
    }
}

import Foundation

/// The rules for every URL a sign-in uses: the ones a server's metadata names (its resource metadata, its
/// authorization servers, their endpoints) and the authorization URL Next Term opens in the user's browser. Each one
/// comes from the server, so none is trusted (the MCP spec's security best practices: SSRF, and the authorization URL).
///
/// - **An allowlist of schemes**: `https`, or `http` only to this Mac when the MCP server itself is on this Mac (a
///   server there, such as the tests' fake, may sign in there). `javascript:`, `data:`, `file:`, `vbscript:` and every
///   other scheme are refused by not being on it.
/// - **No user name or password, and no fragment.**
/// - **A host**: a name with at least one dot, or an address. An address must be a public one (an IPv4 address inside
///   IPv6 counted as that IPv4 address, MCPHubAddress), or this Mac's under the rule above. A name is resolved when it
///   is fetched, and its addresses held to the same rule then (MCPHubOAuthHTTP).
/// - Next Term opens the authorization URL with LaunchServices (NSWorkspace), never through a shell.
public enum MCPHubOAuthURL {
    /// `text` as a URL a sign-in may use for the MCP server at `server`, or why not, as the end of a sentence
    /// ("… isn't one Next Term uses: it is a javascript: address").
    public static func checked(_ text: String, server: URL) -> Result<URL, MCPHubOAuth.Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed == text, !text.isEmpty, !text.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F }) else {
            return .failure("it has spaces or control characters in it")
        }
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased() else {
            return .failure("it isn't a URL")
        }
        let local = isThisMac(server)
        guard scheme == "https" || scheme == "http" else { return .failure(MCPHubOAuth.Failure("it is a \(scheme): address")) }
        guard parts.user == nil, parts.password == nil else { return .failure("it has a user name or password in it") }
        guard parts.fragment == nil else { return .failure("it has a fragment (#) in it") }
        guard let rawHost = parts.host, !rawHost.isEmpty else { return .failure("it has no server name") }
        let host = MCPHubAddressHost.bare(rawHost)
        if MCPHubRules.isThisMac(host) {
            guard local else { return .failure("it names this Mac, and the server isn\u{2019}t on this Mac") }
        } else if let address = MCPHubAddress.bytes(host) {
            let kind = MCPHubAddress.kind(address)
            if kind == .loopback {
                guard local else { return .failure("it names this Mac, and the server isn\u{2019}t on this Mac") }
            } else if kind != .public {
                return .failure("it names an address in a private network")
            }
            if scheme == "http", kind != .loopback { return .failure("it is http:// to another machine") }
        } else {
            guard host.contains("."), !host.hasPrefix("."), !host.contains("..") else { return .failure("its server name has no domain") }
            if scheme == "http" { return .failure("it is http:// to another machine") }
        }
        guard let url = parts.url else { return .failure("it isn't a URL") }
        return .success(url)
    }

    /// Whether the MCP server's URL is on this Mac, which lets its sign-in be on this Mac too.
    public static func isThisMac(_ server: URL) -> Bool {
        let host = MCPHubAddressHost.bare(server.host ?? "")
        if MCPHubRules.isThisMac(host) { return true }
        return MCPHubAddress.bytes(host).map { MCPHubAddress.kind($0) == .loopback } ?? false
    }

    /// A server's canonical URI (RFC 8707, the MCP spec's resource): the scheme and host lowercased, no fragment, the
    /// port only when it isn't the scheme's own, the path and query as written.
    public static func canonical(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        parts.fragment = nil
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        return parts.string ?? url.absoluteString
    }

    /// The URL's origin: scheme, host and port, no path.
    static func origin(_ url: URL) -> String {
        var parts = URLComponents()
        parts.scheme = url.scheme?.lowercased()
        parts.host = url.host?.lowercased()
        parts.port = url.port
        return parts.string ?? ""
    }

    /// Whether `url` is one Next Term may open in the browser for a sign-in with the MCP server at `server`: the rules
    /// above, checked again just before it opens.
    public static func isOpenable(_ url: URL, server: URL) -> Bool {
        if case .success = checked(url.absoluteString, server: server) { return true }
        return false
    }
}

/// A host as URLs give it, compared bare: lowercased, without brackets or a final dot.
enum MCPHubAddressHost {
    static func bare(_ host: String) -> String {
        var name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }
}

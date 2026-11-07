import Foundation

/// A command that only bridges an agent to an MCP server at a URL (`npx -y mcp-remote@0.15.2 https://… --header
/// 'Authorization: Bearer ${NXTRM_API_TOKEN}'`): the panel offers "Use as an MCP Server" for it, which adds the server to
/// Settings › MCP Servers as a URL server with the same header, its key named there (`${secret:NAME}`). Next Term then
/// sends the key itself, the agent never sees it, and Always is safe there, where it never is for `npx -y`.
public enum SecretAlwaysBridge {
    /// The server a bridge reaches, as Settings › MCP Servers would have it.
    public struct Server: Equatable, Sendable {
        public var name: String
        public var url: String
        /// Header name → its template, each `${ENVNAME}` of a key the command sets written `${secret:NAME}`.
        public var headers: [String: String]
    }

    /// The packages known to bridge to a URL, by their name before any `@version`.
    static let bridges: Set<String> = ["mcp-remote"]

    /// The server `words` bridge to, given the keys as NAME → ENVNAME: nil when they aren't a known bridge's, or name a
    /// variable no key sets, or reach anything but one https URL.
    public static func server(_ words: [String], keys: [String: String] = [:]) -> Server? {
        var index = 0
        while index < words.count, words[index].hasPrefix("-") || ["npx", "bunx", "pnpx"].contains(CommandClassifier.baseName(words[index])) {
            index += 1
        }
        guard index < words.count else { return nil }
        let package = words[index]
        let bare = package.hasPrefix("@") ? package : String(package.split(separator: "@", maxSplits: 1).first ?? "")
        guard bridges.contains(bare), let launcher = words.first, ["npx", "bunx", "pnpx"].contains(CommandClassifier.baseName(launcher)) else {
            return nil
        }
        var url: String?
        var headers: [String: String] = [:]
        let byEnv = Dictionary(keys.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var at = index + 1
        while at < words.count {
            let word = words[at]
            if word == "--header", at + 1 < words.count {
                let pair = words[at + 1]
                guard let colon = pair.firstIndex(of: ":") else { return nil }
                let name = pair[..<colon].trimmingCharacters(in: .whitespaces)
                var value = pair[pair.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                for (envName, key) in byEnv { value = value.replacingOccurrences(of: "${\(envName)}", with: "${secret:\(key)}") }
                guard !name.isEmpty, !value.contains("${") || value.range(of: #"\$\{(?!secret:)"#, options: .regularExpression) == nil else { return nil }
                headers[name] = value
                at += 2
                continue
            }
            if word.hasPrefix("-") { return nil } // another option: not one Next Term can carry over as it is
            guard url == nil, let parsed = URL(string: word), parsed.scheme == "https", parsed.host != nil else { return nil }
            url = word
            at += 1
        }
        guard let url, let host = URL(string: url)?.host else { return nil }
        let name = host.split(separator: ".").filter { !["mcp", "www", "api"].contains($0) }.first.map(String.init) ?? host
        return Server(name: name, url: url, headers: headers)
    }
}

import Foundation

/// The one gate for a web link built from a project's files, when it is built and again when it is opened. It takes
/// `http` or `https` only, and plain `http` only to this Mac (loopback, `*.localhost`, `*.test`); a host of
/// `[a-z0-9.-]`, or `[::1]`, with no user or password; a port from 1 to 65535. A path, query or fragment comes from a
/// fixed template, and each value put in it matches its pattern and is percent-encoded. Nothing is taken whole from a
/// file but a server's scheme, host and port.
public enum SafeWebLink {
    /// A piece of a link's path, query or fragment.
    public enum Part: Sendable, Hashable {
        /// The template's own text, written percent-encoded: `/app/projects/`, `%2F%5Bteam%5D`.
        case fixed(String)
        /// A value from the project's files: refused unless it matches its pattern, then percent-encoded.
        case value(String, Placeholder)
        /// A checked origin as text: a local server's address handed to a hosted page (`?baseUrl=`).
        case origin(Origin)
    }

    /// One `name=value` of a query. The name is the template's; the value is a part.
    public struct QueryItem: Sendable, Hashable {
        public let name: String
        public let value: Part

        public init(_ name: String, _ value: Part) {
            self.name = name
            self.value = value
        }
    }

    /// What a value from a file must look like before it goes into a link. None takes `/`, `?`, `#`, `%` or anything
    /// outside ASCII, and none takes `.` or `..`, which would leave the page the template names.
    public enum Placeholder: String, Sendable, Hashable, CaseIterable {
        /// A Supabase project ref: 20 lower-case letters.
        case supabaseRef
        /// A MongoDB Atlas project id: 24 hex digits.
        case atlasProject
        /// A Trigger.dev project ref: `proj_` then lower-case letters and digits.
        case triggerRef
        /// A Google Cloud project id: 6 to 30 of lower-case letters, digits and `-`, from a letter.
        case gcpProject
        /// An AWS region: `us-east-1`, `us-gov-west-1`.
        case awsRegion
        /// A UUID, as Railway's ids are.
        case uuid
        /// A lower-case name: a Fly.io app, a Neon project, a Convex deployment, a Temporal namespace.
        case slug
        /// A name people type, such as a Braintrust project: letters, digits, `.`, `_`, `-` and spaces, up to 100.
        case name
        /// Digits only: an MLflow experiment id.
        case digits

        public func accepts(_ value: String) -> Bool {
            let ascii = value.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in scalar.isASCII }
            let leavesThePage = value == "." || value == ".."
            guard ascii, !leavesThePage else { return false }
            return value.wholeMatch(of: pattern) != nil
        }

        private var pattern: Regex<Substring> {
            switch self {
            case .supabaseRef: return Self.supabaseRefPattern
            case .atlasProject: return Self.atlasProjectPattern
            case .triggerRef: return Self.triggerRefPattern
            case .gcpProject: return Self.gcpProjectPattern
            case .awsRegion: return Self.awsRegionPattern
            case .uuid: return Self.uuidPattern
            case .slug: return Self.slugPattern
            case .name: return Self.namePattern
            case .digits: return Self.digitsPattern
            }
        }

        // Built and compiled once each. `[0-9]`, not `\d`, which takes other scripts' digits.
        private static let supabaseRefPattern = #/[a-z]{20}/#
        private static let atlasProjectPattern = #/[0-9a-f]{24}/#
        private static let triggerRefPattern = #/proj_[a-z0-9]{1,64}/#
        private static let gcpProjectPattern = #/[a-z][a-z0-9-]{4,28}[a-z0-9]/#
        private static let awsRegionPattern = #/[a-z]{2}(?:-gov)?-[a-z]{1,20}-[0-9]/#
        private static let uuidPattern = #/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/#
        private static let slugPattern = #/[a-z0-9-]{1,100}/#
        private static let namePattern = #/[A-Za-z0-9._ -]{1,100}/#
        private static let digitsPattern = #/[0-9]{1,19}/#
    }
}

// MARK: - Origins: where a server is

extension SafeWebLink {
    /// A server's scheme, host and port, and nothing more. The path, query, fragment, user and password of the value
    /// it came from are never kept, so printing an origin never shows a key.
    public struct Origin: Sendable, Hashable, CustomStringConvertible {
        public let scheme: String
        public let host: String
        public let port: Int?

        /// Checked as a link's scheme, host and port are, but plain `http` may name any host here (a Compose
        /// service's name); `link` and `mayOpen` apply that rule.
        public init?(scheme: String, host: String, port: Int?) {
            let lowered = scheme.lowercased()
            guard SafeWebLink.schemes.contains(lowered), let checked = SafeWebLink.checkedHost(host),
                  SafeWebLink.isPort(port) else { return nil }
            self.scheme = lowered
            self.host = checked
            self.port = port
        }

        /// `https://abc.cloud.qdrant.io:6333`.
        public var string: String {
            let portText = port.map { (port: Int) -> String in ":\(port)" } ?? ""
            return scheme + "://" + host + portText
        }

        public var description: String { string }

        /// Whether a link here may open: `https` anywhere, plain `http` only on this Mac.
        public var mayOpen: Bool { SafeWebLink.mayOpen(scheme: scheme, host: host) }

        /// A link on this origin, built and checked as `make` does.
        public func link(path: [Part] = [], query: [QueryItem] = [], fragment: [Part] = []) -> URL? {
            SafeWebLink.make(scheme: scheme, host: host, port: port, path: path, query: query, fragment: fragment)
        }
    }

    /// The origin a project value names (`QDRANT_URL`, `LANGFUSE_HOST`), if a link there may open: as `address(of:)`,
    /// then plain `http` only to this Mac. `https://abc.cloud.qdrant.io:6333?api_key=…` gives
    /// `https://abc.cloud.qdrant.io:6333`.
    public static func origin(of value: String) -> Origin? {
        guard let origin = address(of: value), origin.mayOpen else { return nil }
        return origin
    }

    /// A server's address from a project value: trimmed, given `https://` when it is a bare host (Weaviate's values may
    /// lack a scheme), then read by URLComponents. A value with a user or password, one that names another value, or
    /// one whose scheme, host or port a link would refuse, gives nil; its path, query and fragment are dropped. Plain
    /// `http` to a host off this Mac is kept, so that a Compose service's name (`http://qdrant:6333`) can be mapped to
    /// its published port: only `origin(of:)` or a link built on it may open.
    public static func address(of value: String) -> Origin? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isPrintable(text), !text.contains("\\"), isLiteral(text) else { return nil }
        let written = text.contains("://") ? text : "https://" + text
        guard let parts = URLComponents(string: written), parts.percentEncodedUser == nil,
              parts.percentEncodedPassword == nil, let scheme = parts.scheme,
              let host = parts.percentEncodedHost else { return nil }
        return Origin(scheme: scheme, host: host, port: parts.port)
    }

    private static let lowerLetters: ClosedRange<Unicode.Scalar> = "a"..."z"
    private static let upperLetters: ClosedRange<Unicode.Scalar> = "A"..."Z"

    /// Whether a value names no other value: no `$NAME`, `${…}` or `$(…)`, and no backtick. Such a value is refused
    /// whole, never expanded, so a link never takes in another key's value.
    public static func isLiteral(_ value: String) -> Bool {
        guard !value.contains("`") else { return false }
        let scalars = Array(value.unicodeScalars)
        for index in scalars.indices where scalars[index] == "$" && index + 1 < scalars.count {
            let next = scalars[index + 1]
            let letter = lowerLetters.contains(next) || upperLetters.contains(next)
            let opens = next == "_" || next == "{" || next == "("
            if letter || opens { return false }
        }
        return true
    }
}

// MARK: - Building and checking links

extension SafeWebLink {
    static let schemes: Set<String> = ["http", "https"]

    /// A link from a template's parts, or nil when any check fails: the scheme, host and port as `Origin` checks them,
    /// plain `http` only to this Mac, a path that starts with `/` and never steps out with `.` or `..`, and values
    /// that match their pattern. A value is encoded for where it goes: in a path with `.urlPathAllowed` minus `/`, in
    /// a query with `.urlQueryAllowed` minus `&`, `=` and `+`, in a fragment with `.urlFragmentAllowed` minus `#`, `;`
    /// and `=`. URLComponents reads the result back and must find every part where it was put, so the template's own
    /// text cannot move a value into the host, the query or the fragment.
    public static func make(scheme: String, host: String, port: Int? = nil, path: [Part] = [],
                            query: [QueryItem] = [], fragment: [Part] = []) -> URL? {
        guard let origin = Origin(scheme: scheme, host: host, port: port), origin.mayOpen,
              let pathText = text(of: path, encoding: pathValues, fixedMayNotHold: "?#"),
              pathText.isEmpty || pathText.hasPrefix("/"), !leavesItsPath(pathText),
              let queryText = text(of: query),
              let fragmentText = text(of: fragment, encoding: fragmentValues, fixedMayNotHold: "#") else { return nil }
        var written = origin.string + pathText
        if !query.isEmpty { written += "?" + queryText }
        if !fragment.isEmpty { written += "#" + fragmentText }
        guard let parts = URLComponents(string: written), let url = parts.url else { return nil }
        let noUser: Bool = parts.percentEncodedUser == nil && parts.percentEncodedPassword == nil
        let sameScheme: Bool = parts.scheme == origin.scheme
        let sameHost: Bool = checkedHost(parts.percentEncodedHost ?? "") == origin.host
        let samePort: Bool = parts.port == origin.port
        let samePath: Bool = parts.percentEncodedPath == pathText
        let sameQuery: Bool = parts.percentEncodedQuery == (query.isEmpty ? nil : queryText)
        let sameFragment: Bool = parts.percentEncodedFragment == (fragment.isEmpty ? nil : fragmentText)
        guard noUser, sameScheme, sameHost, samePort, samePath, sameQuery, sameFragment, isAllowed(url) else { return nil }
        return url
    }

    /// Whether a finished link may open, by the same rules as `make`: the app asks again just before it opens one.
    public static func isAllowed(_ url: URL) -> Bool {
        guard isPrintable(url.absoluteString),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.percentEncodedUser == nil, parts.percentEncodedPassword == nil,
              let scheme = parts.scheme, let host = parts.percentEncodedHost, host != "0.0.0.0",
              let origin = Origin(scheme: scheme, host: host, port: parts.port) else { return false }
        return origin.mayOpen && !leavesItsPath(parts.percentEncodedPath)
    }

    /// The host a link may name, lower-cased: labels of 1 to 63 of `[a-z0-9-]` joined by dots, with no trailing dot
    /// and no `xn--` label (a name in another script, written for DNS); or `[::1]`. `0.0.0.0`, every address of this
    /// Mac, becomes `localhost`, which a browser opens.
    static func checkedHost(_ raw: String) -> String? {
        guard raw.unicodeScalars.allSatisfy({ (scalar: Unicode.Scalar) -> Bool in scalar.isASCII }) else { return nil }
        let host = raw.lowercased()
        if host == "[::1]" || host == "::1" { return "[::1]" }
        if host == "0.0.0.0" { return "localhost" }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let plain = host.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in hostCharacters.contains(scalar) }
        let filled = labels.allSatisfy { (label: Substring) -> Bool in !label.isEmpty && label.count <= 63 }
        let encoded = labels.contains { (label: Substring) -> Bool in label.hasPrefix("xn--") }
        guard !host.isEmpty, host.count <= 253, plain, filled, !encoded else { return nil }
        return host
    }

    static func isPort(_ port: Int?) -> Bool {
        guard let port else { return true }
        return (1...65535).contains(port)
    }

    /// `https` anywhere; plain `http` only where `DatabaseEnvironment` says local: loopback, `*.localhost`, `*.test`.
    static func mayOpen(scheme: String, host: String) -> Bool {
        if scheme == "https" { return true }
        return scheme == "http" && DatabaseEnvironment.classify(host: host) == .local
    }

    /// ASCII from `!` to `~`: no space, control character or other script.
    static func isPrintable(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in scalar.value > 0x20 && scalar.value < 0x7F }
    }

    /// A path segment `.` or `..`, written or percent-encoded, would leave the page the template names.
    static func leavesItsPath(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains { (segment: Substring) -> Bool in
            guard let decoded = segment.removingPercentEncoding else { return true }
            return decoded == "." || decoded == ".."
        }
    }

    private static func text(of parts: [Part], encoding allowed: CharacterSet, fixedMayNotHold forbidden: String) -> String? {
        let refused = forbidden + #""<>\^`{|}"#
        var text = ""
        for part in parts {
            switch part {
            case .fixed(let fixed):
                let holds = fixed.contains { (character: Character) -> Bool in refused.contains(character) }
                guard isPrintable(fixed), !holds else { return nil }
                text += fixed
            case .value(let value, let placeholder):
                guard placeholder.accepts(value),
                      let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
                text += encoded
            case .origin(let origin):
                guard let encoded = origin.string.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
                text += encoded
            }
        }
        return text
    }

    private static func text(of query: [QueryItem]) -> String? {
        var items: [String] = []
        for item in query {
            guard !item.name.isEmpty, item.name.unicodeScalars.allSatisfy({ (scalar: Unicode.Scalar) -> Bool in
                      queryNameCharacters.contains(scalar) }),
                  let value = text(of: [item.value], encoding: queryValues, fixedMayNotHold: "&=#") else { return nil }
            items.append(item.name + "=" + value)
        }
        return items.joined(separator: "&")
    }

    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
    private static let queryNameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
    private static let pathValues = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    private static let queryValues = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))
    private static let fragmentValues = CharacterSet.urlFragmentAllowed.subtracting(CharacterSet(charactersIn: "#;="))
}

// MARK: - Secret names

/// Whether a key's name marks a secret, whose value is never read, shown, logged or put in a link; the name alone may
/// still say which service a project uses (`OPENAI_API_KEY`). A name is cut into segments at `_`, `-`, `.` and a
/// change of case (`DB_PASS`, `apiKey`), and is secret when a segment is a secret word, when it ends in a name on the
/// fixed list, or when it holds a word MCP's redaction looks for anywhere in a name (`MYSECRETVALUE`), so the two
/// never disagree. A word counts as a whole segment, not inside one: `KEYCLOAK_URL` and `MONKEY_PORT` are not secret.
public enum SecretName {
    static let words: Set<String> = ["KEY", "APIKEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASS", "PASSPHRASE",
                                     "PWD", "CREDENTIAL", "CREDENTIALS", "AUTH", "HEADERS", "COOKIE", "PRIVATE",
                                     "SIGNING", "DSN"]

    /// Secrets whose name has no secret word: Vercel's Edge Config string carries its token.
    static let names: [String] = ["EDGE_CONFIG", "MILVUS_TOKEN", "BLOB_READ_WRITE_TOKEN", "CONVEX_DEPLOY_KEY",
                                  "OTEL_EXPORTER_OTLP_HEADERS"]

    public static func isSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        let word = segments(of: name).contains { (segment: String) -> Bool in words.contains(segment) }
        let listed = names.contains { (listed: String) -> Bool in upper == listed || upper.hasSuffix("_" + listed) }
        let range = NSRange(name.startIndex..., in: name)
        let masked = MCPRedaction.secretWord.firstMatch(in: name, range: range) != nil
        return word || listed || masked
    }

    /// The upper-cased segments of a name: `NEXT_PUBLIC_SUPABASE_URL` gives NEXT, PUBLIC, SUPABASE, URL; `apiPort`
    /// gives API, PORT; `DBPass` gives DB, PASS.
    public static func segments(of name: String) -> [String] {
        let characters = Array(name)
        var segments: [String] = []
        var current = ""
        for index in characters.indices {
            let character = characters[index]
            if character == "_" || character == "-" || character == "." {
                if !current.isEmpty { segments.append(current) }
                current = ""
                continue
            }
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            if let previous = current.last, startsASegment(character, after: previous, before: next) {
                segments.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { segments.append(current) }
        return segments.map { (segment: String) -> String in segment.uppercased() }
    }

    /// `aB` and `2B` start a segment at B; so does `DBPass` at P, the last capital before a small letter.
    private static func startsASegment(_ character: Character, after previous: Character, before next: Character?) -> Bool {
        guard character.isUppercase else { return false }
        let fromSmall = previous.isLowercase || previous.isNumber
        let endsCapitals = previous.isUppercase && (next?.isLowercase ?? false)
        return fromSmall || endsCapitals
    }
}

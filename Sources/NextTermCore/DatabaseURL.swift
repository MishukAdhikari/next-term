import Foundation

/// A connection URL taken apart by hand: passwords in env files are often not percent-encoded, Mongo
/// URLs list several hosts, and libpq puts a socket folder in `?host=`. URLComponents rejects all three.
struct DatabaseURL: Sendable {
    let scheme: String
    private(set) var engine: DatabaseEngine
    var user: String?
    /// Secret. Never shown, logged or copied; only a hand-off reads it.
    var password: String?
    var host: String?
    var port: Int?
    var database: String?
    /// A Unix socket (libpq `?host=/path`, MySQL `?socket=`).
    var socket: String?
    /// SQLite: the file as written (`file:./dev.db`), relative or absolute.
    var file: String?
    /// The authority as written (`host:port`, or Mongo's `a:27017,b:27017`), for the masked form.
    private(set) var authority = ""
    private(set) var path = ""
    private(set) var query: [(key: String, value: String)] = []

    /// Query keys whose values are secrets (Prisma Accelerate's api_key, Turso's authToken, libpq's password).
    static func isSecretParameter(_ key: String) -> Bool {
        let k = key.lowercased()
        return ["pass", "pwd", "secret", "token", "key", "auth"].contains { k.contains($0) } && k != "authsource" && k != "authmechanism"
    }

    init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon].lowercased()
        // SQLite as Prisma and Drizzle write it: file:./dev.db, file:///abs/app.db, sqlite:app.db.
        if scheme == "file" || scheme == "sqlite" {
            var rest = text[text.index(after: colon)...]
            if rest.hasPrefix("//") { rest = rest.dropFirst(2) }
            if let q = rest.firstIndex(of: "?") { rest = rest[..<q] }
            guard !rest.isEmpty else { return nil }
            self.scheme = scheme
            engine = .sqlite
            file = rest.removingPercentEncoding ?? String(rest)
            return
        }
        guard let engine = DatabaseEngine(scheme: scheme), text[colon...].hasPrefix("://") else { return nil }
        self.scheme = scheme
        self.engine = engine
        var rest = text[text.index(colon, offsetBy: 3)...]
        // Credentials end at the last @ (an unencoded password may hold @, / or ?).
        if let at = rest.lastIndex(of: "@") {
            let info = rest[..<at]
            rest = rest[rest.index(after: at)...]
            if let split = info.firstIndex(of: ":") {
                user = Self.decode(info[..<split])
                password = Self.decode(info[info.index(after: split)...])
            } else {
                user = Self.decode(info)
            }
            if user?.isEmpty == true { user = nil }
        }
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
        authority = String(rest[..<authorityEnd])
        rest = rest[authorityEnd...]
        if rest.hasPrefix("/") {
            let end = rest.firstIndex(of: "?") ?? rest.endIndex
            path = String(rest[..<end])
            rest = rest[end...]
            let name = Self.decode(path.dropFirst())
            if !name.isEmpty { database = name }
        }
        if rest.hasPrefix("?") {
            query = rest.dropFirst().split(separator: "&").map { pair in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
            }
        }
        let first = authority.split(separator: ",").first.map(String.init) ?? ""
        (host, port) = Self.hostAndPort(first)
        for (key, value) in query {
            let decoded = Self.decode(value[...])
            switch key.lowercased() {
            case "host" where decoded.hasPrefix("/"), "socket", "unix_socket": socket = decoded
            case "host" where host == nil: host = decoded
            case "port" where port == nil: port = Int(decoded)
            case "user" where user == nil: user = decoded
            case "password" where password == nil: password = decoded
            case "dbname" where database == nil, "database" where database == nil: database = decoded
            default: break
            }
        }
    }

    /// The same connection read by another engine's client (MariaDB through `mysql://`).
    func with(engine: DatabaseEngine) -> DatabaseURL {
        var copy = self
        copy.engine = engine
        return copy
    }

    var parameters: [(key: String, value: String)] { query }

    /// `[::1]:5432`, `db.example.com:3306`, `localhost`.
    static func hostAndPort(_ text: String) -> (String?, Int?) {
        guard !text.isEmpty else { return (nil, nil) }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let after = text[text.index(after: close)...]
            return (host, after.hasPrefix(":") ? Int(after.dropFirst()) : nil)
        }
        if let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) {
            let host = String(text[..<colon])
            return (host.isEmpty ? nil : decode(host[...]), port)
        }
        return (decode(text[...]), nil)
    }

    static func decode(_ text: Substring) -> String { text.removingPercentEncoding ?? String(text) }

    /// The URL with its password and secret parameters replaced by `•••`.
    var masked: String {
        if engine == .sqlite, let file { return "\(scheme):\(file)" }
        var text = scheme + "://"
        if let user {
            text += Self.encode(user)
            if let password, !password.isEmpty { text += ":" + DatabaseMask.dots }
            text += "@"
        } else if let password, !password.isEmpty {
            text += ":" + DatabaseMask.dots + "@"
        }
        text += authority + path
        if !query.isEmpty {
            text += "?" + query.map { Self.isSecretParameter($0.key) ? "\($0.key)=\(DatabaseMask.dots)" : $0.value.isEmpty ? $0.key : "\($0.key)=\($0.value)" }
                .joined(separator: "&")
        }
        return text
    }

    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.urlUserAllowed
        allowed.remove(charactersIn: ":@/?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// The URL to hand to TablePlus: credentials percent-encoded, and the query as written.
    var handOffURL: URL? {
        var text = scheme + "://"
        var allowed = CharacterSet.urlUserAllowed
        allowed.remove(charactersIn: ":@/?#[]")
        if let user { text += user.addingPercentEncoding(withAllowedCharacters: allowed) ?? user }
        if let password, !password.isEmpty { text += ":" + (password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password) }
        if user != nil || password?.isEmpty == false { text += "@" }
        text += authority + path
        if !query.isEmpty { text += "?" + query.map { $0.value.isEmpty ? $0.key : "\($0.key)=\($0.value)" }.joined(separator: "&") }
        return URL(string: text)
    }
}

/// The one redactor: what any text about a connection goes through before it is shown.
public enum DatabaseMask {
    public static let dots = "•••"

    private static let credentials = try! NSRegularExpression(pattern: #"([A-Za-z][A-Za-z0-9+.\-]*://[^\s:/@]*):[^\s]*@"#)
    private static let parameters = try! NSRegularExpression(
        pattern: #"(?i)\b([a-z_]*(?:password|passwd|pwd|secret|token|api_?key|auth_?token)[a-z_]*)=[^&\s"']+"#)

    /// `scheme://user:secret@host` becomes `scheme://user:•••@host`; `password=…`, `api_key=…` and the
    /// like lose their values. For error text and anything else that might quote a connection.
    public static func redact(_ text: String) -> String {
        var result = text
        let whole = NSRange(result.startIndex..., in: result)
        result = credentials.stringByReplacingMatches(in: result, range: whole, withTemplate: "$1:\(dots)@")
        result = parameters.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1=\(dots)")
        return result
    }
}

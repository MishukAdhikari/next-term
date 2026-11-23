import Foundation

/// One challenge of a WWW-Authenticate header (RFC 9110 §11.6.1), as a remote MCP server sends it with a 401 or 403:
/// its scheme and its auth-params. Where a sign-in starts: a Bearer challenge names the server's resource metadata
/// (RFC 9728 §5.1), the scopes it wants, and, for a 403, `insufficient_scope` (RFC 6750 §3.1).
///
/// - **Several challenges** may share one header (`Basic realm="x", Bearer resource_metadata="…"`): each is read.
/// - **Values** are tokens or quoted strings; in a quoted string `\"` is a quote and `\\` a backslash, and a comma is
///   part of the value. A quote left open ends the header, and the parameter it began is dropped.
/// - **Case.** The scheme and parameter names are compared without case (RFC 9110); values are kept as sent.
/// - **token68** (`Basic dXNlcjpwYXNz`) is kept as `token68`, so it is never read as a parameter.
public struct MCPHubOAuthChallenge: Equatable, Sendable {
    /// Lowercased.
    public let scheme: String
    /// By name, lowercased; the first of a name repeated.
    public let params: [String: String]
    public let token68: String?

    public var resourceMetadata: String? { params["resource_metadata"] }
    public var scope: String? { params["scope"] }
    public var error: String? { params["error"] }
    public var errorDescription: String? { params["error_description"] }

    /// The scopes it names, in order, each once.
    public var scopes: [String] { MCPHubOAuthChallenge.words(scope) }

    public var isBearer: Bool { scheme == "bearer" }
    public var isInsufficientScope: Bool { isBearer && error == "insufficient_scope" }

    /// Every challenge in `header`, in order.
    public static func parse(_ header: String) -> [MCPHubOAuthChallenge] {
        var reader = Reader(Array(header.unicodeScalars))
        var found: [MCPHubOAuthChallenge] = []
        while !reader.atEnd {
            reader.skip { $0 == " " || $0 == "\t" || $0 == "," }
            guard let scheme = reader.token() else {
                if !reader.atEnd { reader.advance() } // not a token: passed over
                continue
            }
            reader.skip { $0 == " " || $0 == "\t" }
            var params: [String: String] = [:]
            var token68: String?
            var first = true
            while !reader.atEnd {
                let mark = reader.position
                if reader.peek == "," { break } // the next challenge, or an empty list member
                guard let name = reader.token() else {
                    if first, let bare = reader.token68() { token68 = bare }
                    break
                }
                reader.skip { $0 == " " || $0 == "\t" }
                // `name=value`, unless what follows `=` is more `=` or nothing: then it is a token68's padding.
                if reader.peek == "=", !reader.isPadding(after: reader.position) {
                    reader.advance()
                    reader.skip { $0 == " " || $0 == "\t" }
                    let value: String?
                    if reader.peek == "\"" {
                        value = reader.quoted()
                        if value == nil { return found + [MCPHubOAuthChallenge(scheme: scheme.lowercased(), params: params, token68: token68)] }
                    } else {
                        value = reader.token() ?? ""
                    }
                    if let value, params[name.lowercased()] == nil { params[name.lowercased()] = value }
                    reader.skip { $0 == " " || $0 == "\t" }
                    if reader.peek == "," {
                        reader.advance()
                        reader.skip { $0 == " " || $0 == "\t" }
                        // A parameter of this challenge continues only with `name=`; anything else starts the next.
                        if !reader.startsParameter() { break }
                    }
                    first = false
                    continue
                }
                // No `=`: a token68 right after the scheme, or the next challenge's scheme.
                reader.position = mark
                if first, let bare = reader.token68() {
                    token68 = bare
                }
                break
            }
            found.append(MCPHubOAuthChallenge(scheme: scheme.lowercased(), params: params, token68: token68))
        }
        return found
    }

    /// The first Bearer challenge in `header`, or nil.
    public static func bearer(_ header: String?) -> MCPHubOAuthChallenge? {
        header.flatMap { parse($0).first(where: \.isBearer) }
    }

    /// A space-separated list (`scope`, `scopes_supported` joined), each word once, in order.
    static func words(_ text: String?) -> [String] {
        var seen = Set<String>()
        return (text ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init).filter { seen.insert($0).inserted }
    }

    /// RFC 9110's tchar.
    static func isTokenCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value > 0x7E || scalar.value <= 0x20 { return false }
        return !"\"(),/:;<=>?@[\\]{}".unicodeScalars.contains(scalar)
    }

    private struct Reader {
        let scalars: [Unicode.Scalar]
        var position = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var atEnd: Bool { position >= scalars.count }
        var peek: Unicode.Scalar? { atEnd ? nil : scalars[position] }
        mutating func advance() { position += 1 }

        mutating func skip(_ test: (Unicode.Scalar) -> Bool) {
            while let next = peek, test(next) { advance() }
        }

        mutating func token() -> String? {
            let start = position
            while let next = peek, MCPHubOAuthChallenge.isTokenCharacter(next) { advance() }
            guard position > start else { return nil }
            return String(String.UnicodeScalarView(scalars[start..<position]))
        }

        /// RFC 9110's token68: letters, digits, `-._~+/`, then any `=`.
        mutating func token68() -> String? {
            let start = position
            let body = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/".unicodeScalars)
            while let next = peek, body.contains(next) { advance() }
            guard position > start else { return nil }
            while peek == "=" { advance() }
            let after = peek
            guard after == nil || after == "," || after == " " || after == "\t" else { position = start; return nil }
            return String(String.UnicodeScalarView(scalars[start..<position]))
        }

        /// Whether the `=` at `at` is a token68's padding: more `=`, or the end of the challenge, follows it.
        func isPadding(after at: Int) -> Bool {
            var next = at + 1
            while next < scalars.count, scalars[next] == " " || scalars[next] == "\t" { next += 1 }
            return next >= scalars.count || scalars[next] == "=" || scalars[next] == ","
        }

        /// Whether `name=` comes next, without moving.
        func startsParameter() -> Bool {
            var copy = self
            guard copy.token() != nil else { return false }
            copy.skip { $0 == " " || $0 == "\t" }
            return copy.peek == "="
        }

        /// A quoted string from its opening quote; nil when it is never closed.
        mutating func quoted() -> String? {
            advance()
            var out = String.UnicodeScalarView()
            while let next = peek {
                advance()
                if next == "\\" {
                    guard let escaped = peek else { return nil }
                    out.append(escaped)
                    advance()
                } else if next == "\"" {
                    return String(out)
                } else {
                    out.append(next)
                }
            }
            return nil
        }
    }
}

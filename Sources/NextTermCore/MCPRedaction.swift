import Foundation

/// Hides credentials in what the MCP tools hand to an agent (file text, search results, diffs), which
/// goes on to the agent's vendor. It masks the token shapes AgentSessions scrubs from titles, private
/// key blocks, passwords in URLs, the values of keys named like secrets, and long random-looking
/// strings. Code stays readable: identifiers, paths, UUIDs and git's hex ids are left alone.
public enum MCPRedaction {
    public static let mask = "•••"

    static let tokens = AgentSessions.tokenPatterns.map { try! NSRegularExpression(pattern: $0) }

    /// A whole private key, from BEGIN to END (or to the end of the text).
    static let privateKey = try! NSRegularExpression(
        pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----|\z)"#)

    /// "https://user:password@host": the password.
    static let urlPassword = try! NSRegularExpression(pattern: #"\b([a-z][a-z0-9+.\-]*://[^\s:/@]+:)([^\s@/]+)(@)"#, options: [.caseInsensitive])

    static let secretName = #"[A-Za-z0-9_.\-]*(?:password|passwd|passphrase|secret|token|api[_\-]?key|access[_\-]?key|private[_\-]?key|credential)[A-Za-z0-9_.\-]*"#

    /// `api_key = "…"`, `"password": "…"`, `'token' => '…'`: the quoted value.
    static let quotedValue = try! NSRegularExpression(
        pattern: #"\b"# + secretName + #"["']?\s*(?:=>|:=|[:=])\s*(?:"([^"\n]{4,})"|'([^'\n]{4,})'|`([^`\n]{4,})`)"#,
        options: [.caseInsensitive])

    /// `API_KEY=…` or `password: …` on a line of its own (env, YAML, INI): the bare value.
    static let bareValue = try! NSRegularExpression(
        pattern: #"^\s*(?:export\s+)?"# + secretName + #"\s*[:=]\s*([^\s"'`#]{6,})\s*$"#,
        options: [.caseInsensitive, .anchorsMatchLines])

    /// A run long enough to be a key; masked only if it looks random (see `looksRandom`).
    static let longRun = try! NSRegularExpression(pattern: #"[A-Za-z0-9+/_\-]{32,}={0,2}"#)

    /// The text with credentials masked, and how many were.
    public static func redact(_ text: String) -> (text: String, count: Int) {
        var result = text
        var count = 0
        // Line by line inside a key block, so line numbers around it stay right.
        count += replace(privateKey, in: &result) { match, ns in
            let block = ns.substring(with: match.range)
            return block.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                line.hasPrefix("-----") ? String(line) : mask
            }.joined(separator: "\n")
        }
        for token in tokens {
            count += replace(token, in: &result) { _, _ in mask }
        }
        count += replace(urlPassword, in: &result) { match, ns in
            ns.substring(with: match.range(at: 1)) + mask + "@"
        }
        for expression in [quotedValue, bareValue] {
            count += replace(expression, in: &result) { match, ns in
                let whole = ns.substring(with: match.range)
                for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
                    let value = ns.substring(with: match.range(at: group))
                    guard isValue(value) else { return nil }
                    let offset = match.range(at: group).location - match.range.location
                    return (whole as NSString).replacingCharacters(in: NSRange(location: offset, length: match.range(at: group).length), with: mask)
                }
                return nil
            }
        }
        count += replace(longRun, in: &result) { match, ns in
            looksRandom(ns.substring(with: match.range)) ? mask : nil
        }
        return (result, count)
    }

    /// A value worth hiding: not a placeholder (`${TOKEN}`, `<your key>`, `xxxx`), not code
    /// (`getToken()`, `config.secret`), and not a short plain word (`"bearer"`, `String`).
    static func isValue(_ value: String) -> Bool {
        if value == mask || value.contains(mask) { return false }
        if let first = value.first, "$<{%[(&*".contains(first) { return false }
        if value.contains("(") || value.range(of: #"^[A-Za-z_]+\.[A-Za-z_.]+$"#, options: .regularExpression) != nil { return false }
        if Set(value.lowercased()).isSubset(of: ["x", "*", ".", "-", "_"]) { return false }
        if value.count < 16, value.range(of: #"^[A-Za-z_\- ]+$"#, options: .regularExpression) != nil { return false }
        return true
    }

    /// Random-looking: upper and lower case and at least three digits. Hex (git ids, hashes), UUIDs,
    /// long words and paths do not qualify.
    static func looksRandom(_ run: String) -> Bool {
        var upper = false, lower = false, digits = 0
        for scalar in run.unicodeScalars {
            switch scalar {
            case "A"..."Z": upper = true
            case "a"..."z": lower = true
            case "0"..."9": digits += 1
            default: break
            }
        }
        return upper && lower && digits >= 3
    }

    /// Replaces each match with what `body` gives (nil keeps it). Returns how many it replaced.
    private static func replace(_ expression: NSRegularExpression, in text: inout String,
                                _ body: (NSTextCheckingResult, NSString) -> String?) -> Int {
        let ns = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return 0 }
        let output = NSMutableString(string: ns)
        var count = 0
        for match in matches.reversed() {
            guard let replacement = body(match, ns) else { continue }
            output.replaceCharacters(in: match.range, with: replacement)
            count += 1
        }
        text = output as String
        return count
    }
}

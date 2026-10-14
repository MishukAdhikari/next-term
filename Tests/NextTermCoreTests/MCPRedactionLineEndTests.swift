import Foundation
import Testing
@testable import NextTermCore

/// `text`'s lines, as read_file and find_in_files split them, each with its values named on a line before it made •••.
private func carriedLines(_ text: String) -> [String] {
    let lines = ProjectSearch.splitLines(text).map(\.0)
    let values = MCPRedaction.CarriedValues(lines, in: 0..<lines.count, mask: .empty)
    return lines.indices.map { values.masked(lines[$0], at: $0).text }
}

/// A bare value (`API_KEY=…`, `password: …`) is on its name's line: the spaces around its `=` or `:` never run past the
/// line's end. An empty value (`DB_PASSWORD=`) took the next line with text as its value, which masked a harmless line
/// under it, or kept a password under a name that is no secret's.
@Suite struct BareValueLineEndTests {
    /// The line under a name with no value is read on its own: masked for its own name, or kept.
    @Test func anEmptyValueNeverTakesTheNextLine() {
        let forms: [(text: String, redacted: String)] = [
            ("db.user=\ndb.password=Tr0ub4dor3horse", "db.user=\ndb.password=•••"),
            ("db.user =\n\ndb.password = Tr0ub4dor3horse\n", "db.user =\n\ndb.password = •••\n"),
            ("DB_PASSWORD=\n\nSESSION_DRIVER=database", "DB_PASSWORD=\n\nSESSION_DRIVER=database"),
            ("DB_PASSWORD=\r\nSESSION_DRIVER=database\r\n", "DB_PASSWORD=\r\nSESSION_DRIVER=database\r\n"),
            ("password:\n  Tr0ub4dor3horse", "password:\n  Tr0ub4dor3horse"),
            ("api_key:\n\tmade-up-value-123\n", "api_key:\n\tmade-up-value-123\n"),
            ("+DB_PASSWORD=\n+SESSION_DRIVER=database", "+DB_PASSWORD=\n+SESSION_DRIVER=database"),
            ("API_TOKEN\n=Tr0ub4dor3horse", "API_TOKEN\n=Tr0ub4dor3horse"),
        ]
        for form in forms {
            #expect(MCPRedaction.redact(form.text, mask: .empty).text == form.redacted, "\(form.text.debugDescription)")
            // Nothing is carried onto a line from the line before: each line masks what its own name names.
            let lines = ProjectSearch.splitLines(form.text).map(\.0)
            #expect(carriedLines(form.text) == lines, "\(form.text.debugDescription)")
        }
    }

    /// Spaces and tabs around the `=` or `:` on the name's line are still read past.
    @Test func spacesAndTabsOnTheLineStillCount() {
        for line in ["DB_PASSWORD \t=\t s3cr3t-passw0rd", "  password:\thunter2x", "export API_KEY =  Tr0ub4dor3horse \t"] {
            let redacted = MCPRedaction.redact(line, mask: .empty)
            #expect(redacted.count == 1 && redacted.text.contains(MCPRedaction.mask), "\(line) -> \(redacted.text)")
        }
    }
}

@Suite struct ExampleEnvFileTests {
    /// A `.env.example` as frameworks ship it: names with empty values or placeholders, and one value that looks random.
    static let example = [
        "APP_NAME=Example", "DB_PASSWORD=", "", "SESSION_DRIVER=database", "API_KEY=your-key-here", "MAIL_PASSWORD=xxx",
        "STRIPE_SECRET=<your-secret>", "JWT_SECRET=Hq7vT2mZp9Lx4Wc8Nb3R", "",
    ].joined(separator: "\n")

    static let shown = [
        "APP_NAME=Example", "DB_PASSWORD=", "", "SESSION_DRIVER=database", "API_KEY=your-key-here", "MAIL_PASSWORD=xxx",
        "STRIPE_SECRET=<your-secret>", "JWT_SECRET=•••",
    ].joined(separator: "\n")

    /// read_file shows the line under an empty value and the placeholders as they are, from the file's start and from
    /// the empty value's line, and masks the value that looks random.
    @Test func readFileKeepsTheLineUnderAnEmptyValue() throws {
        let f = try ProjectFixture()
        try f.write("api/.env.example", Self.example)
        let whole = json(MCPProjectTools.readFile(["path": ".env.example", "project": "api"], in: f.both, mask: .empty))
        #expect(whole["text"] as? String == Self.shown && whole["redacted"] as? Int == 1, "\(whole)")
        let from = json(MCPProjectTools.readFile(["path": ".env.example", "project": "api", "offset": 2], in: f.both, mask: .empty))
        let rest = Self.shown.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
        #expect(from["text"] as? String == rest, "\(from)")

        try f.write("api/app.properties", "db.user=\ndb.password=Tr0ub4dor3horse\n")
        let properties = json(MCPProjectTools.readFile(["path": "app.properties", "project": "api", "offset": 1], in: f.both, mask: .empty))
        #expect(properties["text"] as? String == "db.user=\ndb.password=•••" && properties["redacted"] as? Int == 1, "\(properties)")
    }

    /// find_in_files does the same at each match.
    @Test func findInFilesKeepsTheLineUnderAnEmptyValue() throws {
        let f = try ProjectFixture()
        try f.write("api/.env.example", Self.example)
        let expected: [(query: String, text: String)] = [
            ("SESSION_DRIVER", "SESSION_DRIVER=database"), ("your-key-here", "API_KEY=your-key-here"),
            ("MAIL_PASSWORD", "MAIL_PASSWORD=xxx"), ("STRIPE_SECRET", "STRIPE_SECRET=<your-secret>"), ("JWT_SECRET", "JWT_SECRET=•••"),
        ]
        for item in expected {
            let arguments: [String: Any] = ["query": item.query, "glob": ".env.example", "project": "api"]
            let found = json(MCPProjectTools.findInFiles(arguments, in: f.both, git: nil, mask: .empty))
            let match = try #require((found["matches"] as? [[String: Any]])?.first, "\(item.query): \(found)")
            #expect(match["text"] as? String == item.text, "\(item.query): \(match)")
        }
    }
}

/// A quoted value may sit on the line under its name (`password:` then `"…"`), but a quoted name with its own `:` or `=`
/// after it is a key, never the value of the name above it. Taken as one, the match ran past the key's name, and the
/// value on that line was never matched for it: `production:` then `"password": "…"` showed the password.
@Suite struct QuotedKeyLineEndTests {
    /// Each line's quoted key keeps its own value: it is masked in the text whole, and nothing is carried onto it.
    @Test func aQuotedKeyOnTheNextLineIsNeverTheValueAbove() {
        let forms: [(text: String, redacted: String)] = [
            ("production:\n  \"password\": \"Tr0ub4dor3horse\"", "production:\n  \"password\": \"•••\""),
            ("\"database\":\n  \"password\": \"Tr0ub4dor3horse\"\n", "\"database\":\n  \"password\": \"•••\"\n"),
            ("db:\n  'api_key': 'Tr0ub4dor3horse'", "db:\n  'api_key': '•••'"),
            ("db:\r\n  \"token\" : \"Tr0ub4dor3horse\"\r\n", "db:\r\n  \"token\" : \"•••\"\r\n"),
            ("'db' =>\n  'password' => 'Tr0ub4dor3horse',", "'db' =>\n  'password' => '•••',"),
            // get_diff's context lines start with a space, its added ones with a +.
            (" production:\n   \"password\": \"Tr0ub4dor3horse\"", " production:\n   \"password\": \"•••\""),
            ("+production:\n+  \"password\": \"Tr0ub4dor3horse\"", "+production:\n+  \"password\": \"•••\""),
            // A quoted key under a secret's name is no value: it stays as it is.
            ("secrets:\n  \"prod-db-01\": x", "secrets:\n  \"prod-db-01\": x"),
            ("secrets:\n\n  \"prod-db-01\" = x\n", "secrets:\n\n  \"prod-db-01\" = x\n"),
        ]
        for form in forms {
            #expect(MCPRedaction.redact(form.text, mask: .empty).text == form.redacted, "\(form.text.debugDescription)")
            let lines = ProjectSearch.splitLines(form.text).map(\.0)
            #expect(carriedLines(form.text) == lines, "\(form.text.debugDescription)")
        }
    }

    /// A quoted value under its name is still its value, and on its name's line what follows it changes nothing.
    @Test func aQuotedValueUnderItsNameIsStillMasked() {
        let forms: [(text: String, redacted: String, carried: [String])] = [
            ("password:\n  \"Tr0ub4dor3horse\"", "password:\n  \"•••\"", ["password:", "  \"•••\""]),
            ("const apiKey =\n  \"Tr0ub4dor3horse\";", "const apiKey =\n  \"•••\";", ["const apiKey =", "  \"•••\";"]),
            ("token:\n  \"Tr0ub4dor3horse\", \"label\": \"x\"", "token:\n  \"•••\", \"label\": \"x\"",
             ["token:", "  \"•••\", \"label\": \"x\""]),
            ("token = \"Tr0ub4dor3horse\" == provided", "token = \"•••\" == provided", ["token = \"Tr0ub4dor3horse\" == provided"]),
            ("{\"secret\": \"Tr0ub4dor3horse\": 1}", "{\"secret\": \"•••\": 1}", ["{\"secret\": \"Tr0ub4dor3horse\": 1}"]),
        ]
        for form in forms {
            #expect(MCPRedaction.redact(form.text, mask: .empty).text == form.redacted, "\(form.text.debugDescription)")
            #expect(carriedLines(form.text) == form.carried, "\(form.text.debugDescription)")
        }
    }
}

extension QuotedKeyLineEndTests {
    /// read_file masks the password under a key with no value of its own, from the file's start and from the password's
    /// line; find_in_files does at its match.
    @Test func readFileMasksAValueUnderAKeyWithNoValue() throws {
        let f = try ProjectFixture()
        try f.write("api/config.yaml", "production:\n  \"password\": \"Tr0ub4dor3horse\"\nsecrets:\n  \"prod-db-01\": x\n")
        let shown = "production:\n  \"password\": \"•••\"\nsecrets:\n  \"prod-db-01\": x"
        let whole = json(MCPProjectTools.readFile(["path": "config.yaml", "project": "api"], in: f.both, mask: .empty))
        #expect(whole["text"] as? String == shown && whole["redacted"] as? Int == 1, "\(whole)")
        let from = json(MCPProjectTools.readFile(["path": "config.yaml", "project": "api", "offset": 2, "limit": 1],
                                                 in: f.both, mask: .empty))
        #expect(from["text"] as? String == "  \"password\": \"•••\"" && from["redacted"] as? Int == 1, "\(from)")
        let arguments: [String: Any] = ["query": "password", "glob": "config.yaml", "project": "api"]
        let found = json(MCPProjectTools.findInFiles(arguments, in: f.both, git: nil, mask: .empty))
        let match = try #require((found["matches"] as? [[String: Any]])?.first, "\(found)")
        #expect(match["text"] as? String == "\"password\": \"•••\"", "\(match)")
    }
}

extension QuotedKeyLineEndTests {
    /// Each name, operator, gap, quote and what follows the closing quote, together: a quoted value is masked for a
    /// secret's name unless it is on a line under the operator with its own `:` or `=` after it, the scan read_file's cut
    /// and find_in_files' snippet use finds every value masked, and none is carried onto a key's line.
    @Test func aQuotedKeyIsTheOnlyQuotedTextUnderAnOperatorLeft() {
        let probe = "Hq7vT2mZp9Lx"
        var seen = (masked: 0, keys: 0)
        for name in ["password", "\"token\"", "'api_key'", "label"] {
            for gap in ["", " ", "\t", "\u{A0}", "\n  ", "\r\n", " \u{2028}\t", "\n\n"] {
                for op in [":", "=", "=>", ":="] {
                    for quote in ["\"", "'", "`"] {
                        for tail in ["", ",", ": x", " = 1", "\t=> y", "\u{3000}:", " # note"] {
                            let line: String = name + op + gap + quote + probe + quote + tail
                            let under: Bool = gap.contains { $0.isNewline }
                            let operand: Bool = tail.trimmingCharacters(in: .whitespaces).first.map { ":=".contains($0) } ?? false
                            let key: Bool = under && operand
                            let shown: Bool = MCPRedaction.redact(line, mask: .empty).text.contains(probe)
                            #expect(shown == (key || name == "label"), "\(line.debugDescription)")
                            if !shown {
                                seen.masked += 1
                                let values = MCPRedaction.NamedValues(line, mask: .empty)
                                let inside = line.index(after: line.range(of: probe)!.lowerBound)
                                #expect(values.cuts(inside, keepingAfter: false), "\(line.debugDescription)")
                            }
                            if key {
                                seen.keys += 1
                                #expect(carriedLines(line) == ProjectSearch.splitLines(line).map(\.0), "\(line.debugDescription)")
                            }
                        }
                    }
                }
            }
        }
        #expect(seen.masked > 500 && seen.keys > 200, "\(seen)")
    }
}

/// The spaces around a bare value's `=` or `:` are any on the name's line (ICU's `\h`: a tab and the space separators),
/// as before they stopped at its end: a no-break or an ideographic space there still masks the value, and a line's end
/// of any kind still ends it.
@Suite struct BareValueHorizontalSpaceTests {
    @Test func unicodeSpacesOnTheNameLineStillCount() {
        let lines = ["API_KEY=\u{3000}Tr0ub4dor3horse", "password\u{A0}:\u{A0}Tr0ub4dor3horse",
                     "DB_PASSWORD \u{2003}=\u{202F}s3cr3t-passw0rd", "+export SECRET_TOKEN\u{205F}= made-up-value-123"]
        for line in lines {
            let redacted = MCPRedaction.redact(line, mask: .empty)
            #expect(redacted.count == 1 && !redacted.text.contains("Tr0ub4dor3horse"), "\(line.debugDescription) -> \(redacted.text)")
            #expect(!redacted.text.contains("passw0rd") && !redacted.text.contains("value-123"), "\(line.debugDescription)")
            // The scan read_file's cut and find_in_files' snippet use finds the value too.
            let values = MCPRedaction.NamedValues(line, mask: .empty)
            let last = line.index(before: line.endIndex)
            #expect(values.cuts(last, keepingAfter: false), "\(line.debugDescription)")
        }
    }

    @Test func noLineEndIsASpaceOnTheNameLine() {
        for end in ["\u{2028}", "\u{2029}", "\u{85}", "\u{0B}", "\u{0C}", "\r"] {
            let text = "DB_PASSWORD=" + end + "SESSION_DRIVER=database"
            #expect(MCPRedaction.redact(text, mask: .empty).text == text, "\(text.debugDescription)")
            let values = MCPRedaction.NamedValues(text, mask: .empty)
            #expect(!values.cuts(text.index(before: text.endIndex), keepingAfter: false), "\(text.debugDescription)")
        }
    }
}

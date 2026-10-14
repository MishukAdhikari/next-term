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

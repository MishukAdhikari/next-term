import Foundation
import Testing
@testable import NextTermCore

/// `text`'s lines from `first` on, as read_file and find_in_files split them, each with its values named on a line
/// before it made •••.
private func carriedIndented(_ text: String, from first: Int = 0) -> [String] {
    let lines = ProjectSearch.splitLines(text).map(\.0)
    let values = MCPRedaction.CarriedValues(lines, in: first..<lines.count, mask: .empty)
    return (first..<lines.count).map { values.masked(lines[$0], at: $0).text }
}

/// `text`'s lines from `first` on, each as read_file and find_in_files give it: its values named on a line before it
/// made •••, then redacted alone.
private func aloneIndented(_ text: String, from first: Int = 0) -> [String] {
    carriedIndented(text, from: first).map { MCPRedaction.redact($0, mask: .empty).text }
}

/// YAML's own rule for a key with nothing after its `:`: the next line with text, indented more than the key's line, is
/// the key's value. A plain value there (`password:` then `    Tr0ub4dor3horse`) is masked for the key's name, as a
/// quoted one is. A line at the same or a lower indent, a key of its own (`name:`) or an item (`- item`) is never the
/// value, and an `=` never reaches past its name's line.
@Suite struct IndentedValueTests {
    /// The value is masked in the text whole, and in its line read alone, from the text's start and from its own line.
    @Test func anIndentedValueUnderASecretsKeyIsMasked() {
        let forms: [(text: String, redacted: String)] = [
            ("password:\n  Tr0ub4dor3horse", "password:\n  •••"),
            ("password:\n\n    Tr0ub4dor3horse\n  port: 5432", "password:\n\n    •••\n  port: 5432"),
            ("database:\n  password:\n    Tr0ub4dor3horse\n", "database:\n  password:\n    •••\n"),
            ("api_key:\n\tmade-up-value-123\n", "api_key:\n\t•••\n"),
            ("token:\n    Tr0ub4dor3horse;", "token:\n    •••"),
            ("  DB.Password :  \r\n   \r\n\r\n      s3cr3t-passw0rd  \r\nport: 1",
             "  DB.Password :  \r\n   \r\n\r\n      •••  \r\nport: 1"),
            ("password:\u{2028}  Tr0ub4dor3horse", "password:\u{2028}  •••"),
            // get_diff's context lines start with a space.
            (" database:\n   password:\n \n     Tr0ub4dor3horse\n port: 5432",
             " database:\n   password:\n \n     •••\n port: 5432"),
        ]
        for form in forms {
            let redacted = MCPRedaction.redact(form.text, mask: .empty)
            #expect(redacted.text == form.redacted && redacted.count == 1, "\(form.text.debugDescription) -> \(redacted.text)")
            let shown = ProjectSearch.splitLines(form.redacted).map(\.0)
            #expect(aloneIndented(form.text) == shown, "\(form.text.debugDescription)")
            let at = shown.lastIndex { $0.contains(MCPRedaction.mask) } ?? 0
            #expect(aloneIndented(form.text, from: at) == Array(shown[at...]), "\(form.text.debugDescription)")
        }
    }

    /// What is never the key's value stays as it is, in the text whole and in each line read alone, and nothing is
    /// carried onto a line from the key above it.
    @Test func aLineAtTheSameOrALowerIndentOrAKeyOrAnItemIsNeverTheValue() {
        for text in [
            "password:\nTr0ub4dor3horse",
            "  password:\n  Tr0ub4dor3horse\n",
            "    password:\n  Tr0ub4dor3horse",
            "password:\n\n\nTr0ub4dor3horse",
            "\tpassword:\n\tTr0ub4dor3horse",
            "password:\n  Tr0ub4dor3horse:",
            "password:\n  database:\n    port: 5432",
            "password:\n  - Tr0ub4dor3horse",
            "password:\n  -   made-up-value-123",
            "API_KEY=\n  Tr0ub4dor3horse",
            "password =\n  Tr0ub4dor3horse",
            "password:=\n  Tr0ub4dor3horse",
            "label:\n  Tr0ub4dor3horse",
            "password:\n  ${DB_PASSWORD}",
            "password:\n  xxxxxxxx",
            "password:\u{2028}Tr0ub4dor3horse",
        ] {
            #expect(MCPRedaction.redact(text, mask: .empty).text == text, "\(text.debugDescription)")
            let lines = ProjectSearch.splitLines(text).map(\.0)
            #expect(carriedIndented(text) == lines, "\(text.debugDescription)")
            #expect(aloneIndented(text) == lines, "\(text.debugDescription)")
        }
    }
}

/// The same pieces from one seed on every run.
private struct IndentedPieces {
    var state: UInt64

    mutating func pick(_ pieces: [String]) -> String {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return pieces[Int((state >> 33) % UInt64(pieces.count))]
    }
}

extension IndentedValueTests {
    /// Each line before the key, key indent, name, `:`, what follows it, line end of each kind, blank lines, value indent,
    /// value and what follows it, together: the value is masked in the text whole exactly when its line, read alone, is,
    /// from the text's start and from that line; and the scan read_file's cut and find_in_files' snippet use finds every
    /// value masked in the text whole.
    @Test func eachLineAloneMasksWhatTheTextWholeMasks() {
        let probe = "0f1e2d3c4b5a6978"
        var maker = IndentedPieces(state: 29)
        var seen = (masked: 0, indented: 0, kept: 0)
        for _ in 0..<10000 {
            let befores: [String] = ["", "x: 1\n", "a\u{2028}", "b\u{0B}", "c\r", "d\u{85}"]
            let keyIndents: [String] = ["", " ", "  ", "\t", "+", " -"]
            let names: [String] = ["password", "DB_PASSWORD", "api_key", "api.key", "label", "\"token\""]
            let colons: [String] = [":", ":", " :", "\t:", "\u{A0}:", "=", ":=", "\n:"]
            let afters: [String] = ["", "", "  ", "\t", "\u{3000}", " #", " x"]
            let ends: [String] = ["\n", "\r\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"]
            let blanks: [String] = ["", "", "\n", " \n", "\t\r\n", "\u{A0}\n", "  \u{2028}"]
            let valueIndents: [String] = ["", " ", "  ", "   ", "    ", "\t", "\u{3000}", " \u{A0}", "  - ", "\t "]
            let quoted: String = "\"" + probe + "\""
            let values: [String] = [probe, probe, "x" + probe + ";", "-" + probe, probe + ":", quoted, "${" + probe,
                                    probe + " # c", probe + " y"]
            let tails: [String] = ["", "  ", "\n", "\r\n  port: 1", "\u{2028}next: 2", "\n    more", "\u{0B}", "\u{85}x"]
            let value: String = maker.pick(values)
            var text: String = maker.pick(befores) + maker.pick(keyIndents) + maker.pick(names) + maker.pick(colons)
            text += maker.pick(afters) + maker.pick(ends) + maker.pick(blanks) + maker.pick(blanks)
            text += maker.pick(valueIndents) + value + maker.pick(tails)
            let lines = ProjectSearch.splitLines(text).map(\.0)
            let joined: String = lines.joined(separator: "\n")
            let whole = MCPRedaction.redact(joined, mask: .empty).text
            guard let at = lines.firstIndex(where: { $0.contains(probe) }) else { continue }
            for from in [0, at] {
                let values = MCPRedaction.CarriedValues(lines, in: from..<lines.count, mask: .empty)
                let alone = MCPRedaction.redact(values.masked(lines[at], at: at).text, mask: .empty).text
                #expect(alone.contains(probe) == whole.contains(probe), "\(text.debugDescription) from \(from)")
            }
            guard !whole.contains(probe), let found = joined.range(of: probe) else {
                seen.kept += 1
                continue
            }
            seen.masked += 1
            if !value.hasPrefix("\"") { seen.indented += 1 } // no quote: only the indented value's rule masks it
            let named = MCPRedaction.NamedValues(joined, mask: .empty)
            #expect(named.cuts(joined.index(after: found.lowerBound), keepingAfter: false), "\(text.debugDescription)")
        }
        #expect(seen.indented > 200 && seen.masked > 400 && seen.kept > 5000, "\(seen)")
    }
}

/// read_file, find_in_files and get_diff each mask a value indented under its secret's key, and show a line at the
/// key's own indent as it is.
@Suite struct IndentedValueToolTests {
    static let config = [
        "database:", "  host: db.example.test", "  password:", "", "    Tr0ub4dor3horse", "  port: 5432",
        "token:", "same-indent-value", "",
    ].joined(separator: "\n")

    static let shown = [
        "database:", "  host: db.example.test", "  password:", "", "    •••", "  port: 5432", "token:", "same-indent-value",
    ].joined(separator: "\n")

    /// From the file's start, and from the value's own line, which has no name on it.
    @Test func readFileMasksIt() throws {
        let f = try ProjectFixture()
        try f.write("api/config.yaml", Self.config)
        let whole = json(MCPProjectTools.readFile(["path": "config.yaml", "project": "api"], in: f.both, mask: .empty))
        #expect(whole["text"] as? String == Self.shown && whole["redacted"] as? Int == 1, "\(whole)")
        let arguments: [String: Any] = ["path": "config.yaml", "project": "api", "offset": 5, "limit": 1]
        let from = json(MCPProjectTools.readFile(arguments, in: f.both, mask: .empty))
        #expect(from["text"] as? String == "    •••" && from["redacted"] as? Int == 1, "\(from)")
    }

    /// At the match's own line; the line at the key's indent is shown.
    @Test func findInFilesMasksIt() throws {
        let f = try ProjectFixture()
        try f.write("api/config.yaml", Self.config)
        let expected: [(query: String, text: String)] = [("Tr0ub", "•••"), ("same-indent", "same-indent-value")]
        for item in expected {
            let arguments: [String: Any] = ["query": item.query, "glob": "config.yaml", "project": "api"]
            let found = json(MCPProjectTools.findInFiles(arguments, in: f.both, git: nil, mask: .empty))
            let match = try #require((found["matches"] as? [[String: Any]])?.first, "\(item.query): \(found)")
            #expect(match["text"] as? String == item.text, "\(item.query): \(match)")
        }
    }

    /// In a diff's context lines, each of which starts with a space.
    @Test func getDiffMasksItInContextLines() throws {
        guard let git = GitRunner.locateGit() else { return } // no git on this machine
        let f = try ProjectFixture()
        let repo = f.base + "/repo"
        func sh(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            let settings = ["-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"]
            p.arguments = ["-C", repo, "-c", "core.hooksPath=/dev/null"] + settings + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "git \(args.joined(separator: " "))")
        }
        try f.write("repo/config.yaml", Self.config)
        try sh("init")
        try sh("add", "-A")
        try sh("commit", "-m", "first")
        try f.write("repo/config.yaml", Self.config.replacingOccurrences(of: "port: 5432", with: "port: 6543"))
        let projects = MCPProjects(open: [repo], preferred: nil)
        let diff = json(MCPProjectTools.getDiff(["path": "config.yaml"], in: projects, git: git))
        let text = try #require(diff["diff"] as? String, "\(diff)")
        #expect(text.contains("\n   password:\n \n     •••\n-  port: 5432\n+  port: 6543\n"), "\(text)")
        #expect(!text.contains("Tr0ub4dor3horse") && text.contains("\n same-indent-value\n"), "\(text)")
    }
}

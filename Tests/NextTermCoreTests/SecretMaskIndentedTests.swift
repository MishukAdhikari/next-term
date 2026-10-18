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

/// Each form's values are masked in the text whole, as `redacted` shows them, once each, and in their lines read alone,
/// from the text's start and from each masked line.
private func expectIndentedMasked(_ forms: [(text: String, redacted: String)],
                                  sourceLocation: SourceLocation = #_sourceLocation) {
    for form in forms {
        let redacted = MCPRedaction.redact(form.text, mask: .empty)
        let masks: Int = form.redacted.components(separatedBy: MCPRedaction.mask).count - 1
        let said: String = "\(form.text.debugDescription) -> \(redacted.text.debugDescription)"
        #expect(redacted.text == form.redacted && redacted.count == masks, "\(said)", sourceLocation: sourceLocation)
        let shown = ProjectSearch.splitLines(form.redacted).map(\.0)
        #expect(aloneIndented(form.text) == shown, "\(form.text.debugDescription)", sourceLocation: sourceLocation)
        for at in shown.indices where shown[at].contains(MCPRedaction.mask) {
            let from: [String] = aloneIndented(form.text, from: at)
            #expect(from == Array(shown[at...]), "\(form.text.debugDescription) from \(at)", sourceLocation: sourceLocation)
        }
    }
}

/// Each text stays as it is, in the text whole and in each line read alone, and nothing is carried onto a line from the
/// key above it.
private func expectIndentedKept(_ texts: [String], sourceLocation: SourceLocation = #_sourceLocation) {
    for text in texts {
        let redacted: String = MCPRedaction.redact(text, mask: .empty).text
        #expect(redacted == text, "\(text.debugDescription) -> \(redacted.debugDescription)", sourceLocation: sourceLocation)
        let lines = ProjectSearch.splitLines(text).map(\.0)
        #expect(carriedIndented(text) == lines, "\(text.debugDescription)", sourceLocation: sourceLocation)
        #expect(aloneIndented(text) == lines, "\(text.debugDescription)", sourceLocation: sourceLocation)
    }
}

/// YAML's own rule for a key with nothing after its `:`: the next line with text, indented more than the key's line, is
/// the key's value. A plain value there (`password:` then `    Tr0ub4dor3horse`) is masked for the key's name, as a
/// quoted one is. A line at the same or a lower indent, a key of its own (`name:`) or an item (`- item`) is never the
/// value, and an `=` never reaches past its name's line.
@Suite struct IndentedValueTests {
    /// The value is masked in the text whole, and in its line read alone, from the text's start and from its own line.
    @Test func anIndentedValueUnderASecretsKeyIsMasked() {
        expectIndentedMasked([
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
        ])
    }

    /// A block scalar (`|`, `>`, with a chomping or an indentation indicator, or both) under a secret's key: its first
    /// line, indented more than the key, is the value when it is one plain value.
    @Test func aBlockScalarsFirstLineIsMasked() {
        expectIndentedMasked([
            ("password: |\n    Tr0ub4dor3horse\n", "password: |\n    •••\n"),
            ("password: >-\n  Tr0ub4dor3horse", "password: >-\n  •••"),
            ("password: |+\n\n  Tr0ub4dor3horse\n", "password: |+\n\n  •••\n"),
            ("stringData:\n  password: |-\n    Tr0ub4dor3horse\n  user: app\n",
             "stringData:\n  password: |-\n    •••\n  user: app\n"),
            ("api_key:\t>2 # rotated\n  made-up-value-123", "api_key:\t>2 # rotated\n  •••"),
            ("token: |-1\n Tr0ub4dor3horse\r\n", "token: |-1\n •••\r\n"),
        ])
    }

    /// A diff's lines are read a side at a time, each as its own file: context and added lines (a space or a + first),
    /// then context and removed lines (a space or a - first), the other side's lines passed over. A rotated value shows
    /// neither the old one nor the new one.
    @Test func aDiffsAddedAndRemovedValuesAreMasked() {
        expectIndentedMasked([
            ("+  password:\n+    Tr0ub4dor3horse", "+  password:\n+    •••"),
            ("-password:\n-  OldPassw0rd1234\n", "-password:\n-  •••\n"),
            ("   password:\n-    OldPassw0rd1234\n+    Tr0ub4dor3horse", "   password:\n-    •••\n+    •••"),
            (" database:\n-  password:\n-    OldPassw0rd1234\n+  password:\n+    Tr0ub4dor3horse\n",
             " database:\n-  password:\n-    •••\n+  password:\n+    •••\n"),
            ("+password:\n   Tr0ub4dor3horse", "+password:\n   •••"),
            (" password:\n+\n \n+  Tr0ub4dor3horse", " password:\n+\n \n+  •••"),
            ("+password: |\n+  Tr0ub4dor3horse", "+password: |\n+  •••"),
            ("@@ -1,3 +1,3 @@\n api_key:\r\n-  OldPassw0rd1234\r\n+  made-up-value-123\r\n",
             "@@ -1,3 +1,3 @@\n api_key:\r\n-  •••\r\n+  •••\r\n"),
        ])
    }

    /// A key in a list item (`- password:`) is as far in as its name: the item's dash counts as indent.
    @Test func aListItemsKeyCountsItsDashAsIndent() {
        expectIndentedMasked([
            ("- password:\n    Tr0ub4dor3horse", "- password:\n    •••"),
            ("- password:\n   Tr0ub4dor3horse\n", "- password:\n   •••\n"),
            ("users:\n  - password:\n      Tr0ub4dor3horse", "users:\n  - password:\n      •••"),
            ("  -   token:\n        Tr0ub4dor3horse", "  -   token:\n        •••"),
            ("+- password:\n+    Tr0ub4dor3horse", "+- password:\n+    •••"),
        ])
    }

    /// A comment after the key's `:`, comment lines between the key and its value (two at most), and a comment after the
    /// value are passed over.
    @Test func aCommentIsPassedOver() {
        expectIndentedMasked([
            ("password:\n    Tr0ub4dor3horse  # rotated", "password:\n    •••  # rotated"),
            ("password: # db\n    Tr0ub4dor3horse", "password: # db\n    •••"),
            ("password:\n  # rotated\n\n  Tr0ub4dor3horse\n", "password:\n  # rotated\n\n  •••\n"),
            ("password:\n# one\n  # two\n  Tr0ub4dor3horse #three", "password:\n# one\n  # two\n  ••• #three"),
            ("password: | # db\n  Tr0ub4dor3horse", "password: | # db\n  •••"),
            (" password:\n+  # new\n-  # old\n+  Tr0ub4dor3horse", " password:\n+  # new\n-  # old\n+  •••"),
        ])
    }

    /// What is never the key's value stays as it is, in the text whole and in each line read alone, and nothing is
    /// carried onto a line from the key above it.
    @Test func aLineAtTheSameOrALowerIndentOrAKeyOrAnItemIsNeverTheValue() {
        expectIndentedKept([
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
            "password:\n- Tr0ub4dor3horse",
            "password:\n  Tr0ub4dor3horse#c",
            "password:#c\n  Tr0ub4dor3horse",
        ])
    }

    /// A block scalar's line at the key's own indent, or one with more than a plain value, is not its value; a header
    /// with text after it, or with no space after the `:`, is not a header.
    @Test func aBlockScalarsLineAtTheKeysIndentIsNeverTheValue() {
        expectIndentedKept([
            "password: |\nTr0ub4dor3horse",
            "  password: >-\n  Tr0ub4dor3horse",
            "password: |\n  - Tr0ub4dor3horse",
            "password: >\n  Tr0ub4dor3horse and more",
            "password: |x\n  Tr0ub4dor3horse",
            "password:|\n  Tr0ub4dor3horse",
        ])
    }

    /// In a diff, a value at its key's indent, one on the other side, and a sign on a line under a key with none, stay.
    /// A list item's key reaches only a line indented more than its name.
    @Test func aDiffsOtherSideOrAListItemsSameIndentIsNeverTheValue() {
        expectIndentedKept([
            "+password:\n+Tr0ub4dor3horse",
            "+  password:\n+  Tr0ub4dor3horse",
            "+password:\n-  Tr0ub4dor3horse",
            "-password:\n+  Tr0ub4dor3horse",
            "password:\n+  Tr0ub4dor3horse",
            "- password:\n  Tr0ub4dor3horse",
            "  - password:\n    Tr0ub4dor3horse",
            "-   token:\n   Tr0ub4dor3horse",
        ])
    }
}

extension IndentedValueTests {
    /// Many blank lines or a long comment between a key and its value, and many blank context lines in a diff: ICU reads
    /// each through (it gave up on a possessive loop that many times round, and then masked nothing after it), and the
    /// time grows with the text, not with its square (a blank line read two ways did).
    @Test func manyBlankLinesOrALongCommentAreReadThrough() {
        let blank: String = "password:" + String(repeating: "\n", count: 200_000) + "  Tr0ub4dor3horse\n"
        let spaces: String = " password:" + String(repeating: "\n ", count: 100_000) + "\n+  Tr0ub4dor3horse\n"
        let comment: String = "password: # " + String(repeating: "x.", count: 150_000) + "\n  Tr0ub4dor3horse\n"
        let other: String = " password:\n-" + String(repeating: "x.", count: 150_000) + "\n+  Tr0ub4dor3horse\n"
        for text in [blank, spaces, comment, other] {
            // Each pattern on its own: `quotedValue`, an older one, gives up on as many blank lines.
            let expressions: [NSRegularExpression] = [MCPRedaction.indentedValue, MCPRedaction.removedIndentedValue]
            let found: [(count: Int, complete: Bool)] = expressions.map { expression in
                var copy = text
                var complete = true
                let count = MCPRedaction.replace(expression, in: &copy, complete: &complete) { _, _ in "" }
                return (count, complete)
            }
            let said: String = "\(text.prefix(24).debugDescription): \(found)"
            #expect(found[0] == (1, true) && found[1] == (0, true), "\(said)")
            #expect(MCPRedaction.redact(text, mask: .empty).text.hasSuffix("  •••\n"), "\(said)")
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
    /// Each line before the key, key indent (a diff's sign, a list item's dash), name, `:` (a block scalar's header after
    /// it), what follows it, line end of each kind, blank lines (comments, a diff's lines of either side), value indent,
    /// value and what follows it, together: the value is masked in the text whole exactly when its line, read alone, is,
    /// from the text's start and from that line; and the scan read_file's cut and find_in_files' snippet use finds every
    /// value masked in the text whole.
    @Test func eachLineAloneMasksWhatTheTextWholeMasks() {
        let probe = "0f1e2d3c4b5a6978"
        var maker = IndentedPieces(state: 29)
        var seen = (masked: 0, indented: 0, kept: 0, signed: 0)
        for _ in 0..<12000 {
            let befores: [String] = ["", "x: 1\n", "a\u{2028}", "b\u{0B}", "c\r", "d\u{85}", " ctx: 1\n"]
            let keyIndents: [String] = ["", " ", "  ", "\t", "+", " -", "- ", "  - ", "-", "+- ", "+  ", "-\t", "-  "]
            let names: [String] = ["password", "DB_PASSWORD", "api_key", "api.key", "label", "\"token\""]
            let colons: [String] = [":", ":", " :", "\t:", "\u{A0}:", "=", ":=", "\n:", ": |", ": >-", ":|", " :\t|2+",
                                    ": # c", ":#c"]
            let afters: [String] = ["", "", "  ", "\t", "\u{3000}", " #", " x", " # c"]
            let ends: [String] = ["\n", "\r\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"]
            let blanks: [String] = ["", "", "\n", " \n", "\t\r\n", "\u{A0}\n", "  \u{2028}", "  # c\n", "+\n", "-old\n",
                                    "+ # c\r\n", "#\u{2028}"]
            let valueIndents: [String] = ["", " ", "  ", "   ", "    ", "\t", "\u{3000}", " \u{A0}", "  - ", "\t ", "+  ",
                                          "-   ", " +  ", "+    ", "-"]
            let quoted: String = "\"" + probe + "\""
            let values: [String] = [probe, probe, "x" + probe + ";", "-" + probe, probe + ":", quoted, "${" + probe,
                                    probe + " # c", probe + " y"]
            let tails: [String] = ["", "  ", "\n", "\r\n  port: 1", "\u{2028}next: 2", "\n    more", "\u{0B}", "\u{85}x",
                                   "  # c", " #c"]
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
            // A diff's sign, a list item's dash, a block scalar's header or a comment in it.
            let marks: [String] = ["+", "\n-", "- ", "|", ">", "#"]
            if text.hasPrefix("-") || marks.contains(where: { text.contains($0) }) { seen.signed += 1 }
            let named = MCPRedaction.NamedValues(joined, mask: .empty)
            #expect(named.cuts(joined.index(after: found.lowerBound), keepingAfter: false), "\(text.debugDescription)")
        }
        let counted: Bool = seen.indented > 250 && seen.masked > 300 && seen.signed > 250
        #expect(counted && seen.kept > 5000, "\(seen)")
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
        let changed: String = Self.config.replacingOccurrences(of: "port: 5432", with: "port: 6543")
        guard let text = try Self.diff(from: Self.config, to: changed) else { return } // no git on this machine
        #expect(text.contains("\n   password:\n \n     •••\n-  port: 5432\n+  port: 6543\n"), "\(text)")
        #expect(!text.contains("Tr0ub4dor3horse") && text.contains("\n same-indent-value\n"), "\(text)")
    }

    /// A rotated value: the removed line holds the old one, the added line the new one, and neither shows.
    @Test func getDiffMasksARemovedAndAnAddedValue() throws {
        let rotated: String = Self.config.replacingOccurrences(of: "Tr0ub4dor3horse", with: "N3w-made-up-value")
        guard let text = try Self.diff(from: Self.config, to: rotated) else { return } // no git on this machine
        #expect(text.contains("\n   password:\n \n-    •••\n+    •••\n   port: 5432\n"), "\(text)")
        #expect(!text.contains("Tr0ub4dor3horse") && !text.contains("N3w-made-up-value"), "\(text)")
    }

    /// read_file of a patch, from the added value's own line: the key is on a context line before the removed one.
    @Test func readFileMasksAValueInAPatch() throws {
        let f = try ProjectFixture()
        try f.write("api/rotate.diff", "@@ -1,3 +1,3 @@\n password:\n-  Tr0ub4dor3horse\n+  N3w-made-up-value\n")
        let arguments: [String: Any] = ["path": "rotate.diff", "project": "api", "offset": 4]
        let from = json(MCPProjectTools.readFile(arguments, in: f.both, mask: .empty))
        #expect(from["text"] as? String == "+  •••" && from["redacted"] as? Int == 1, "\(from)")
    }

    /// get_diff's text for `config.yaml` changed from `before` to `after` in a new repository; nil with no git.
    private static func diff(from before: String, to after: String) throws -> String? {
        guard let git = GitRunner.locateGit() else { return nil }
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
        try f.write("repo/config.yaml", before)
        try sh("init")
        try sh("add", "-A")
        try sh("commit", "-m", "first")
        try f.write("repo/config.yaml", after)
        let projects = MCPProjects(open: [repo], preferred: nil)
        let diff = json(MCPProjectTools.getDiff(["path": "config.yaml"], in: projects, git: git))
        return try #require(diff["diff"] as? String, "\(diff)")
    }
}

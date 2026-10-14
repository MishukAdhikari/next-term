import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// A mask made from stored values' marks, as the app makes it. Never `SecretMask.current`: tests run in parallel.
private func carriedMask(_ values: [String]) -> SecretMask {
    let key = SymmetricKey(size: .bits256)
    return SecretMask(key: key, marks: values.flatMap { SecretMask.marks(for: SecretBytes(utf8: $0), key: key) })
}

/// `text`'s lines from `first` on, as read_file and find_in_files split them, each with its values named on a line
/// before it made •••.
private func carried(_ text: String, from first: Int = 0, mask: SecretMask = .empty) -> [String] {
    let lines = ProjectSearch.splitLines(text).map(\.0)
    let values = MCPRedaction.CarriedValues(lines, in: first..<lines.count, mask: mask)
    return (first..<lines.count).map { values.masked(lines[$0], at: $0).text }
}

/// A hex value, the same on every run: no long-run pattern masks it, only its name does.
private func hexCarried(_ count: Int) -> String {
    let digits = Array("0123456789abcdef")
    var state: UInt64 = 0x5851_F42D_4C95_7F2D
    return String((0..<count).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return digits[Int(state >> 60)]
    })
}

@Suite struct CarriedValueTests {
    /// A name, its operator and its quoted value on lines of their own, as a formatter writes a long assignment or YAML
    /// puts a quoted value under its key, or `export` on a line before a bare value's name: `redact` masks the value in
    /// the text whole, and the value's line, read alone, shows ••• for it too, from an offset at that line as well. A
    /// name on the value's own line is that line's to mask.
    @Test func aValueNamedOnALineBeforeItsOwnIsMaskedInIt() {
        let forms: [(text: String, lines: [String])] = [
            ("const apiKey =\n  \"Tr0ub4dor&3!horse-staple\";\nnext();", ["const apiKey =", "  \"•••\";", "next();"]),
            ("let apiKey\n  = 'Tr0ub4dor&3!horse';", ["let apiKey", "  = '•••';"]),
            ("{\n  \"password\":\n    \"Tr0ub4dor&3!horse\"\n}", ["{", "  \"password\":", "    \"•••\"", "}"]),
            ("token =>\r\n `Tr0ub4dor&3!horse`,", ["token =>", " `•••`,"]),
            ("password:\n\n    \"Tr0ub4dor3horse\"\n  port: 5432", ["password:", "", "    \"•••\"", "  port: 5432"]),
            ("export\n\n  API_KEY=Tr0ub4dor3horse", ["export", "", "  API_KEY=•••"]),
            ("export\n\u{3000}API_KEY=Tr0ub4dor3horse", ["export", "\u{3000}API_KEY=•••"]), // alone, the line keeps it
        ]
        for form in forms {
            let lines = ProjectSearch.splitLines(form.text).map(\.0)
            let whole = MCPRedaction.redact(lines.joined(separator: "\n"), mask: .empty).text
            #expect(whole == form.lines.joined(separator: "\n"), "\(form.text.debugDescription)")
            #expect(carried(form.text) == form.lines, "\(form.text.debugDescription)")
            let last = form.lines.lastIndex { $0.contains("•••") } ?? 0
            #expect(carried(form.text, from: last) == Array(form.lines[last...]), "\(form.text.debugDescription)")
        }
    }

    /// What `redact` keeps in the text whole stays: a placeholder, a name that is no secret's, a name with other text
    /// between it and the value, a value on its name's own line, which that line masks, and a bare value on a line after
    /// its name's: the spaces around a bare value's `=` or `:` stay on its name's line.
    @Test func whatTheWholeTextKeepsStays() {
        for text in [
            "apiKey =\n  \"${API_KEY}\"",
            "label =\n  \"Tr0ub4dor&3!horse\"",
            "apiKey\nfoo\n= \"Tr0ub4dor&3!horse\"",
            "x = 1\napiKey = \"Tr0ub4dor&3!horse\"",
            "password:\n  - Tr0ub4dor3horse",
            "+password:\n+  Tr0ub4dor3horse",
            "password:\n\n    Tr0ub4dor3horse\n  port: 5432",
            "database:\n  password:\n    Tr0ub4dor3horse\n",
            "export\n\n  API_KEY\n\n=\n \nTr0ub4dor3horse",
        ] {
            let lines = ProjectSearch.splitLines(text).map(\.0)
            let values = MCPRedaction.CarriedValues(lines, in: 0..<lines.count, mask: .empty)
            for index in lines.indices {
                #expect(values.masked(lines[index], at: index) == (lines[index], 0), "\(text.debugDescription) \(index)")
            }
        }
    }

    /// A value with a stored value in it is masked whole, as `redact` masks it: the stored part first, then the rest
    /// for its name.
    @Test func aStoredValueInACarriedValueIsMaskedWithIt() {
        let stored = "Rk7vQp2xLm9nWz4cTb8hYq3s"
        let mask = carriedMask([stored])
        #expect(carried("apiKey =\n  \"x" + stored + "y\";", mask: mask) == ["apiKey =", "  \"•••\";"])
        #expect(carried("apiKey =\n  \"${" + stored + "}\";", mask: mask) == ["apiKey =", "  \"•••\";"])
    }
}

extension CarriedValueTests {
    /// A search's match in a carried value is on its ••• once the value is masked, and one after it moves back by what
    /// the ••• took off, counted in UTF-16 as a search counts.
    @Test func aMatchMovesWithItsLine() {
        let lines = ["const apiKey =", "  \"Tr0ub4dor&3!horsé\"; // 😀 Tr0ub"]
        let values = MCPRedaction.CarriedValues(lines, in: 0..<2, mask: .empty)
        let inside = values.masked(lines[1], at: 1, keeping: NSRange(location: 5, length: 5))
        #expect(inside.text == "  \"•••\"; // 😀 Tr0ub" && inside.count == 1)
        #expect(inside.match == NSRange(location: 3, length: 3))
        #expect(values.masked(lines[1], at: 1, keeping: NSRange(location: 29, length: 5)).match == NSRange(location: 15, length: 5))
        #expect(values.masked(lines[1], at: 1, keeping: NSRange(location: 15, length: 14)).match == NSRange(location: 3, length: 12))
        #expect(values.masked(lines[1], at: 1, keeping: NSRange(location: 0, length: 3)).match == NSRange(location: 0, length: 3))
    }

    /// find_in_files reads a match's file again for the lines before the match's line, Windows line ends and all. A
    /// line the file no longer holds as the search found it, or a file gone since, is ••• whole; the first line, with
    /// nothing before it, stays as it is.
    @Test func aLineTheFileNoLongerHoldsIsMaskedWhole() throws {
        let f = try ProjectFixture()
        try f.write("api/src/config.ts", "const apiKey =\r\n\r\n  \"Tr0ub4dor&3!horse\";\r\n")
        let lines = MCPRedaction.CarriedLines(root: f.a, mask: .empty)
        func match(_ path: String, _ line: Int, _ text: String) -> SearchMatch {
            SearchMatch(relativePath: path, line: line, lineText: text, range: NSRange(location: 3, length: 5))
        }
        let current = lines.masking(match("src/config.ts", 3, "  \"Tr0ub4dor&3!horse\";"))
        #expect(current.match.lineText == "  \"•••\";" && current.count == 1)
        #expect(current.match.range == NSRange(location: 3, length: 3) && current.match.line == 3)
        let again = lines.masking(match("src/config.ts", 3, "  \"Tr0ub4dor&3!horse\";"))
        #expect(again.match.lineText == "  \"•••\";" && again.count == 1)
        let changed = lines.masking(match("src/config.ts", 3, "  \"Tr0ub4dor&3!horse-staple\";"))
        #expect(changed.match.lineText == "•••" && changed.count == 1)
        let gone = lines.masking(match("src/gone.ts", 3, "  \"Tr0ub4dor&3!horse\";"))
        #expect(gone.match.lineText == "•••" && gone.count == 1)
        let first = lines.masking(match("src/config.ts", 1, "const apiKey ="))
        #expect(first.match.lineText == "const apiKey =" && first.count == 0)
        #expect(lines.masking(match("src/config.ts", 9, "needle")).match.lineText == "•••")
        let plain = lines.masking(match("src/config.ts", 2, ""))
        #expect(plain.match.lineText == "" && plain.count == 0)
    }
}

/// The same pieces from one seed on every run.
private struct PieceMaker {
    var state: UInt64

    mutating func pick(_ pieces: [String]) -> String {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return pieces[Int((state >> 33) % UInt64(pieces.count))]
    }
}

extension CarriedValueTests {
    /// A value `redact` masks in a text of a few lines is masked in its own line read alone, once the values named on
    /// a line before it are •••, from the text's start or from an offset at that line; one it keeps is kept. The texts
    /// put a name, its quote, operator and value on one line or several, with blank lines, spaces of each kind, Windows
    /// line ends, `export` and a diff's sign around them, a stored value or a placeholder's start in the value.
    @Test func eachLineAloneMasksWhatTheTextWholeMasks() {
        let stored = "Rk7vQp2xLm9nWz4cTb8hYq3s"
        let mask = carriedMask([stored])
        let probe = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
        var maker = PieceMaker(state: 17)
        var seen = (masked: 0, across: 0)
        for _ in 0..<6000 {
            let starts = ["", "  ", "export ", "export\n", "+", "-  ", "say(", "x = 1;\n", "{\n  ", "a\n\n", "EXPORT\n\t"]
            let names = ["password", "apiKey", "DB_PASSWORD", "\"api_key\"", "'token'", "label", "credentials", "my.secret"]
            let gaps = ["", " ", "\n", "\n\n", " \n  ", "\r\n", "\u{3000}\n", "\n\u{3000}", "\t\n\t", "\n \n", "\u{2028}"]
            let operators = ["=", ":", "=>", ":=", ""]
            let quotes = ["", "\"", "'", "`"]
            let fronts = ["", "x", stored, "${"]
            let tails = ["", ";", ",", "  ", " # note", "\n", "\nnext = 1", "\r\n}", " \t", "\n  port: 1"]
            let quote = maker.pick(quotes)
            var text = maker.pick(starts) + maker.pick(names) + maker.pick(gaps) + maker.pick(operators)
            text += maker.pick(gaps) + quote + maker.pick(fronts) + probe + quote + maker.pick(tails)
            let lines = ProjectSearch.splitLines(text).map(\.0)
            let whole = MCPRedaction.redact(lines.joined(separator: "\n"), maskingRun: { _ in nil }, mask: mask).text
            guard let at = lines.firstIndex(where: { $0.contains(probe) }) else { continue }
            for from in [0, at] {
                let values = MCPRedaction.CarriedValues(lines, in: from..<lines.count, mask: mask)
                let line = values.masked(lines[at], at: at).text
                let alone = MCPRedaction.redact(line, maskingRun: { _ in nil }, mask: mask).text
                #expect(alone.contains(probe) == whole.contains(probe), "\(text.debugDescription) from \(from)")
            }
            guard !whole.contains(probe) else { continue }
            seen.masked += 1
            if MCPRedaction.redact(lines[at], maskingRun: { _ in nil }, mask: mask).text.contains(probe) { seen.across += 1 }
        }
        #expect(seen.masked > 1000 && seen.across > 300, "\(seen)")
    }
}

extension CarriedValueTests {
    /// A blank line holds no value: find_in_files gives a match in one as it is, without reading the lines before it,
    /// even when the file no longer holds it. It read them for each such match, back over every blank line before it to
    /// the third line with text, so many matches after many blank lines took time that grows with their product.
    @Test func aMatchOnABlankLineIsGivenAsItIs() throws {
        let f = try ProjectFixture()
        try f.write("api/src/config.ts", "const apiKey =\n\n  \"Tr0ub4dor&3!horse\";\n")
        let lines = MCPRedaction.CarriedLines(root: f.a, mask: .empty)
        let past = lines.masking(SearchMatch(relativePath: "src/config.ts", line: 9, lineText: " \t ", range: NSRange(location: 1, length: 1)))
        #expect(past.match.lineText == " \t " && past.count == 0)
        let gone = lines.masking(SearchMatch(relativePath: "src/gone.ts", line: 3, lineText: "  ", range: NSRange(location: 0, length: 1)))
        #expect(gone.match.lineText == "  " && gone.count == 0)

        // 200 lines of spaces, each a match for " ", after 400,000 empty lines.
        try f.write("api/blank.txt", String(repeating: "\n", count: 400_000) + String(repeating: "  \n", count: 200))
        let arguments: [String: Any] = ["query": " ", "glob": "blank.txt", "project": "api", "max_results": 200]
        var found: [String: Any] = [:]
        let took = ContinuousClock().measure {
            found = json(MCPProjectTools.findInFiles(arguments, in: f.both, git: nil, mask: .empty))
        }
        let matches = try #require(found["matches"] as? [[String: Any]])
        #expect(matches.count == 200 && matches.allSatisfy { $0["text"] as? String == "" } && found["redacted"] == nil)
        #expect(took < .seconds(5), "find_in_files took \(took)")
    }
}

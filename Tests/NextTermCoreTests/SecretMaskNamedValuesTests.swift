import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// A mask made from stored values' marks, as the app makes it. Never `SecretMask.current`: tests run in parallel.
private func namedMask(_ values: [String]) -> SecretMask {
    let key = SymmetricKey(size: .bits256)
    return SecretMask(key: key, marks: values.flatMap { SecretMask.marks(for: SecretBytes(utf8: $0), key: key) })
}

/// What `body` gives for `text`'s bytes as `NamedValues` reads them.
private func withBytes<T>(_ text: String, _ body: (NamedValueBytes) -> T) -> T {
    var copy = text
    return copy.withUTF8 { body(NamedValueBytes(bytes: $0)) }
}

/// The scalars of the Basic Multilingual Plane (no astral one is a space, a line's end or a name's character), and the
/// text made of them all.
private let planeZero: (text: String, scalars: [Unicode.Scalar]) = {
    let scalars = (0...0xFFFF).compactMap(Unicode.Scalar.init)
    var text = ""
    text.unicodeScalars.append(contentsOf: scalars)
    return (text, scalars)
}()

/// The scalars of the plane that `pattern` matches on their own.
private func matched(_ pattern: String, options: NSRegularExpression.Options = []) throws -> Set<UInt32> {
    let expression = try NSRegularExpression(pattern: pattern, options: options)
    let ns = planeZero.text as NSString
    var found = Set<UInt32>()
    for match in expression.matches(in: planeZero.text, range: NSRange(location: 0, length: ns.length)) {
        for scalar in ns.substring(with: match.range).unicodeScalars { found.insert(scalar.value) }
    }
    return found
}

@Suite struct NamedValueBytesTests {
    /// The scan reads a space, a line's end and a name's character exactly as ICU does: `\s` is White_Space, `^` and
    /// `$` see LF, VT, FF, CR, NEL, LS and PS, and a pattern that ignores case takes ſ and the Kelvin sign into a name.
    @Test func spacesLineEndsAndNamesAreICUs() throws {
        let spaces = try matched(#"\s"#)
        let names = try matched(#"[A-Za-z0-9_.\-]"#, options: [.caseInsensitive])
        let schemes = try matched(#"[a-z0-9+.\-]"#, options: [.caseInsensitive])
        let letters = try matched(#"[a-z]"#, options: [.caseInsensitive])
        // `^` after each scalar: "a", the scalar and "b", for every scalar in one text.
        var probe = ""
        var after: [Int: UInt32] = [:]
        var length = 0
        for scalar in planeZero.scalars {
            probe.unicodeScalars.append(contentsOf: ["a", scalar, "b"])
            length += 1 + UTF16.width(scalar)
            after[length] = scalar.value
            length += 1
        }
        let start = try NSRegularExpression(pattern: "^b", options: [.anchorsMatchLines])
        let ends = Set(start.matches(in: probe, range: NSRange(location: 0, length: (probe as NSString).length))
            .compactMap { after[$0.range.location] })
        #expect(ends == [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029])
        for scalar in planeZero.scalars {
            let text = String(scalar)
            let length = text.utf8.count
            withBytes(text) { bytes in
                #expect((bytes.space(0) == length) == spaces.contains(scalar.value), "\(scalar.value)")
                #expect((bytes.lineEnd(0) == length) == ends.contains(scalar.value), "\(scalar.value)")
                #expect((bytes.foldedName(0) == length) == names.contains(scalar.value), "\(scalar.value)")
                let scheme = bytes.schemeCharacter(endingAt: length)
                #expect((scheme?.length == length) == schemes.contains(scalar.value), "\(scalar.value)")
                #expect((scheme?.letter ?? false) == letters.contains(scalar.value), "\(scalar.value)")
            }
        }
    }
}

/// The same lines from one seed on every run.
private struct LineMaker {
    var state: UInt64

    mutating func next(_ count: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(count))
    }

    mutating func pick(_ pieces: [String]) -> String { pieces[next(pieces.count)] }
}

/// `text`'s UTF-16 range as UTF-8 offsets.
private func utf8Range(_ range: NSRange, in text: String) -> Range<Int> {
    let bounds = Range(range, in: text)!
    let lower = text.utf8.distance(from: text.startIndex, to: bounds.lowerBound)
    return lower..<lower + text[bounds].utf8.count
}

extension NamedValueBytesTests {
    /// A private key's BEGIN line and a URL's password are found where the token pattern and `urlPassword` find them.
    @Test func headersAndPasswordsAreWhereThePatternsFindThem() throws {
        let header = try NSRegularExpression(pattern: AgentSessions.tokenPatterns.first { $0.contains("BEGIN") }!)
        var maker = LineMaker(state: 7)
        var seen = (headers: 0, passwords: 0)
        let pieces = ["-----BEGIN ", "RSA ", "PRIVATE KEY", "-----", "PRIVATE KEY-----", " ", "x", "https://", "HTTP", "://",
                      "u", "s\u{17F}", "\u{212A}", "1a", ":", "pa'ss", "p\"w", "@", "/", "@h", "\u{3000}", "-", "+", ".", "é",
                      "ftp://u:pw@", "x://", "u:p'w@", ":p\"q@", "a.b-c+d://", "-----BEGIN PRIVATE KEY-----",
                      "-----BEGIN EC PRIVATE KEY", "-----BEGIN OPENSSH PRIVATE KEY-----"]
        for _ in 0..<4000 {
            let line = (0..<(4 + maker.next(14))).map { _ in maker.pick(pieces) }.joined()
            let ns = NSRange(location: 0, length: (line as NSString).length)
            let headers = header.matches(in: line, range: ns).map { utf8Range($0.range, in: line) }
            let passwords = MCPRedaction.urlPassword.matches(in: line, range: ns).map { utf8Range($0.range(at: 2), in: line) }
            withBytes(line) { bytes in
                #expect(bytes.privateKeyHeaders() == headers, "\(line)")
                #expect(bytes.urlPasswords() == passwords, "\(line)")
            }
            seen.headers += headers.count
            seen.passwords += passwords.count
        }
        #expect(seen.headers > 50 && seen.passwords > 50, "\(seen)")
    }

    /// Every value `quotedValue` or `bareValue` masks for its name is one the scan finds, in lines that put a name, its
    /// quotes, the spaces and operator ICU takes, a line's end of each kind, a stored value or a URL's password with a
    /// quote in it, and a private key's BEGIN line before a value. `probe` stands in the value, and a pattern masked
    /// the value for its name when `probe` is gone from what `redact` gives, long runs kept.
    @Test func theScanFindsEveryValueTheNamePatternsMask() {
        let stored = "Qz9\"Lm4W'x7Rt2Yp"
        let mask = namedMask([stored])
        let probe = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
        var maker = LineMaker(state: 11)
        var masked = 0
        for _ in 0..<6000 {
            let starts = ["", "+", "-", "- ", "  ", "\t", "export ", "EXPORT\u{3000}", "x = 1;\r", "a\u{2028}", "b\u{85}",
                          "c\u{0C}", "-export ", "say(", "{\"", "'"]
            let names = ["password", "DB_PASSWORD", "apiKey", "api-key", "\u{17F}ecret", "api_\u{212A}ey", "label", "my.token",
                         "Token", "x" + String(repeating: "y", count: 300) + "_secret", "pass word", "credentials"]
            let gaps = ["", " ", "\t", "\u{A0}", "\u{3000}", " \u{2028} ", "\r", "  "]
            let operators = ["=", ":", "=>", ":=", "==", "->", ""]
            let quotes = ["", "\"", "'", "`"]
            let fronts = ["", "ab ", "x", "#", "\"", "'", stored, "https://u:pa'ss@h/", "-----BEGIN RSA PRIVATE KEY-----", "a b"]
            let tails = ["", " end", "   ", " # note", "\u{2028}next", "\r", " \"x\"", "'", "\"", "`", "\u{85}"]
            let quote = maker.pick(quotes)
            var line = maker.pick(starts) + maker.pick(names) + maker.pick(["", "\"", "'"]) + maker.pick(gaps)
            line += maker.pick(operators) + maker.pick(gaps) + quote + maker.pick(fronts) + probe
            line += maker.pick([quote, "", "\"", "'"]) + maker.pick(tails)
            // Long runs stay: a name run into the probe looks random, and that mask is no name's.
            guard !MCPRedaction.redact(line, maskingRun: { _ in nil }, mask: mask).text.contains(probe) else { continue }
            masked += 1
            let values = MCPRedaction.NamedValues(line, mask: mask)
            let start = line.range(of: probe)!
            for place in [line.index(after: start.lowerBound), line.index(before: start.upperBound)] {
                #expect(values.cuts(place, keepingAfter: false) && values.cuts(place, keepingAfter: true), "\(line.debugDescription)")
            }
            // At the probe's ends a cut keeps all of it: one at its end is in the value (a closing quote the pattern
            // needs is left out) or keeps text that masks it; one at its start is in the value, its name left out.
            let before = MCPRedaction.redact(String(line[..<start.upperBound]), maskingRun: { _ in nil }, mask: mask).text
            #expect(values.cuts(start.upperBound, keepingAfter: false) || !before.contains(probe), "\(line.debugDescription)")
            #expect(values.cuts(start.lowerBound, keepingAfter: true), "\(line.debugDescription)")
        }
        #expect(masked > 300, "\(masked)")
    }
}

@Suite struct NamedValueSnippetTests {
    /// A minified line of many short values under a secret's name, each a match: every snippet's edges move out of the
    /// values around it, and the line is read once for all 200 of them.
    @Test func manyValuesInALongLineShowNoneInAnySnippet() throws {
        let f = try ProjectFixture()
        var maker = LineMaker(state: 5)
        let digits = Array("0123456789abcdef")
        let entries = (0..<3000).map { _ in
            "\"token\": \"" + String((0..<40).map { _ in digits[maker.next(16)] }) + "\", \"n\": 1"
        }
        try f.write("api/bundle.json", "{" + entries.joined(separator: ", ") + "}\n")
        let started = Date()
        let found = MCPProjectTools.findInFiles(["query": "[0-9a-f]{40}", "regex": true, "case_sensitive": true,
                                                 "glob": "bundle.json", "project": "api", "max_results": 200],
                                                in: f.both, git: nil, mask: .empty)
        let matches = try #require(json(found)["matches"] as? [[String: Any]])
        #expect(matches.count == 200)
        for match in matches {
            let text = try #require(match["text"] as? String)
            #expect(text.range(of: "[0-9a-f]{5}", options: .regularExpression) == nil, "\(text)")
            #expect(text.contains("•••"), "\(text)")
        }
        #expect(Date().timeIntervalSince(started) < 20)
    }
}

@Suite struct RemoteChangesLinesTests {
    /// The diff's lines are taken from the end of the output as splitting it at each line feed would give them.
    @Test func lastLinesAreThoseSplittingGives() {
        var maker = LineMaker(state: 3)
        for _ in 0..<500 {
            let text = (0..<maker.next(12)).map { _ in maker.pick(["\n", "\r\n", "\r", "a", "é", "中", " ", "@@"]) }.joined()
            let lines = text.components(separatedBy: "\n")
            for count in 0...lines.count {
                let expected = count == 0 ? "" : lines.suffix(count).joined(separator: "\n")
                #expect(RemoteChanges.lastLines(count, of: text) == expected, "\(text.debugDescription) \(count)")
            }
        }
    }
}

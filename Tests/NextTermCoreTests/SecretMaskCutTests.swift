import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// A mask made from stored values' marks, as the app makes it. Never `SecretMask.current`: tests run in parallel.
private func storedMask(_ values: [String]) -> SecretMask {
    let key = SymmetricKey(size: .bits256)
    return SecretMask(key: key, marks: values.flatMap { SecretMask.marks(for: SecretBytes(utf8: $0), key: key) })
}

/// Two random values no pattern catches: short of a long run, no token prefix, never assigned to a secret's name.
private let stored = "Rk7vQp2xLm9nWz4cTb8hYq3s"
private let other = "Hd5tGw8kPz2mXc6vNb4j"

/// A base64 run that looks random, the same on every run: an inlined image or font in a bundle.
private func base64Run(_ count: Int) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    var run = ""
    run.reserveCapacity(count)
    for _ in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        run.append(alphabet[Int(state >> 58)])
    }
    return run
}

/// Whether `text` shows any 5 characters in a row of `value`.
private func showsPart(of value: String, in text: String) -> Bool {
    let characters = Array(value)
    return (0...(characters.count - 5)).contains { text.contains(String(characters[$0..<$0 + 5])) }
}

@Suite struct SecretMaskPrefixTests {
    /// host_changes cuts a diff at the bytes the agent asks for. Masking the cut text missed a stored value across the
    /// cut and showed its start; masking first, each cut through it leaves it out whole, and one past it shows •••.
    @Test func noCutShowsPartOfAStoredValue() {
        let m = storedMask([stored])
        let head = "diff --git a/.env b/.env\n+DB_PASSWORD="
        let text = head + stored + "\n+NEXT=1\n"
        let start = head.utf8.count
        let cutFirst = String(decoding: Array(text.utf8.prefix(start + 10)), as: UTF8.self)
        #expect(showsPart(of: stored, in: m.mask(cutFirst))) // the order before
        for limit in start...(start + stored.utf8.count) {
            let cut = m.maskedPrefix(text, maxBytes: limit)
            #expect(cut.cut && cut.text.utf8.count <= limit, "\(limit)")
            #expect(!showsPart(of: stored, in: cut.text), "\(limit): \(cut.text)")
        }
        #expect(m.maskedPrefix(text, maxBytes: start + 3).text == head)
        let past = m.maskedPrefix(text, maxBytes: start + stored.utf8.count + 3)
        #expect(past.text == head + "•••\n+N" && past.cut)
        let whole = m.maskedPrefix(text, maxBytes: 10_000)
        #expect(whole.text == head + "•••\n+NEXT=1\n" && !whole.cut)
    }

    /// host_changes asks the host for `bytesToRead(forCutAt:)` bytes (`head -c`), then cuts with `maskedPrefix`. Each
    /// cut through a stored value leaves it out whole, because the host sent all of it: asking for one byte past the
    /// cut only, the host's own cut split the value, and the part before the agent's cut showed.
    @Test func aHostSendsAllOfAValueAcrossTheCut() {
        let m = storedMask([stored])
        let head = "diff --git a/.env b/.env\n+DB_PASSWORD="
        let text = head + stored + "\n+NEXT=1\n"
        let start = head.utf8.count
        for limit in start...(start + stored.utf8.count) {
            let sent = String(decoding: Array(text.utf8.prefix(m.bytesToRead(forCutAt: limit))), as: UTF8.self)
            let cut = m.maskedPrefix(sent, maxBytes: limit)
            #expect(cut.cut && !showsPart(of: stored, in: cut.text), "\(limit): \(cut.text)")
        }
        let short = String(decoding: Array(text.utf8.prefix(start + 11)), as: UTF8.self)
        #expect(showsPart(of: stored, in: m.maskedPrefix(short, maxBytes: start + 10).text)) // the host's cut alone
        #expect(SecretMask.empty.bytesToRead(forCutAt: 1000) == 1001)
    }

    /// A cut never splits a character, with or without marks.
    @Test func aCutNeverSplitsACharacter() {
        let text = "é" + String(repeating: "ü", count: 10)
        let even = SecretMask.empty.maskedPrefix(text, maxBytes: 4)
        let odd = SecretMask.empty.maskedPrefix(text, maxBytes: 5)
        #expect(even.text == "éü" && even.cut && odd.text == "éü" && odd.cut)
        #expect(SecretMask.empty.maskedPrefix(text, maxBytes: 100) == (text, false))
    }
}

@Suite struct MCPCutMaskTests {
    /// read_file cuts a line at 2,000 characters. A stored value, or a token the patterns know, across the cut is left
    /// out whole, never shown in part.
    @Test func readFileShowsNoPartOfAValueAtTheCut() throws {
        let f = try ProjectFixture()
        let filler = String(repeating: "lorem ipsum ", count: 165) + "key: " // 1,985 characters: the value spans the cut
        try f.write("api/long.txt", "short line\n" + filler + stored + " and more text after it, " + String(repeating: "x", count: 100) + "\n")
        let result = json(MCPProjectTools.readFile(["path": "long.txt", "project": "api"], in: f.both, mask: storedMask([stored])))
        let text = try #require(result["text"] as? String)
        #expect(!showsPart(of: stored, in: text), "\(text.suffix(80))")
        #expect(text.hasPrefix("short line\nlorem ipsum") && text.hasSuffix("…") && result["long_lines_cut"] as? Int == 1)

        let token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        try f.write("api/token.txt", filler + token + String(repeating: " y", count: 60) + "\n")
        let plain = json(MCPProjectTools.readFile(["path": "token.txt", "project": "api"], in: f.both, mask: .empty))
        let tokenText = try #require(plain["text"] as? String)
        #expect(!tokenText.contains("ghp_abc") && tokenText.hasPrefix("lorem ipsum"), "\(tokenText.suffix(80))")
    }

    /// find_in_files shows 300 characters around a match in a long line. A stored value across either edge is shown
    /// whole as •••, never in part.
    @Test func findInFilesShowsNoPartOfAValueAtTheSnippetsEdges() throws {
        let f = try ProjectFixture()
        // `stored` at 360..<384 and the snippet from 374; `other` at 664..<684 and the snippet to 674.
        let before = String(repeating: "lorem ipsum ", count: 30)
        let gap = String(repeating: "dolor sit ", count: 9)
        let after = String(repeating: "amet ", count: 36) + "sed "
        let line = before + stored + gap + "needle" + after + other + " " + String(repeating: "consectetur ", count: 20)
        try f.write("api/wide.txt", line + "\n")
        let result = MCPProjectTools.findInFiles(["query": "needle", "glob": "wide.txt", "project": "api"], in: f.both, git: nil,
                                                 mask: storedMask([stored, other]))
        let matches = try #require(json(result)["matches"] as? [[String: Any]])
        let text = try #require(matches.first?["text"] as? String)
        #expect(text.contains("needle") && text.contains("•••"), "\(text)")
        #expect(!showsPart(of: stored, in: text) && !showsPart(of: other, in: text), "\(text)")
        #expect(matches.first?["column"] as? Int == 475)
        // With nothing masked across its edges, the snippet keeps its 300 characters.
        try f.write("api/plain.txt", before + gap + gap + "needle" + after + after + "\n")
        let plain = MCPProjectTools.findInFiles(["query": "needle", "glob": "plain.txt", "project": "api"], in: f.both, git: nil,
                                                mask: storedMask([stored, other]))
        let plainText = try #require((json(plain)["matches"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(plainText.hasPrefix("…") && plainText.hasSuffix("…") && plainText.count <= 302, "\(plainText.count)")
    }

    /// A long run across a snippet's edge (an inlined image or font) is left out, and ••• stands for it: the edge moves
    /// in, toward the match, so the snippet stays within its 300 characters. Moving the edge out grew the snippet to
    /// the whole run, and a run of a million characters, too long for the patterns, came back unmasked.
    @Test func aLongRunAcrossAnEdgeKeepsTheSnippetShortAndMasked() throws {
        let f = try ProjectFixture()
        let run = base64Run(1_000_000)
        let head = "const x = 'needle'; const img = \"data:image/png;base64,"
        try f.write("api/bundle.js", head + run + "\";\n")
        let result = MCPProjectTools.findInFiles(["query": "needle", "glob": "bundle.js", "project": "api"], in: f.both, git: nil,
                                                 mask: storedMask([stored]))
        let found = try #require((json(result)["matches"] as? [[String: Any]])?.first)
        let text = try #require(found["text"] as? String)
        #expect(text.count <= 310, "\(text.count)")
        #expect(text == head + "•••…" && !showsPart(of: String(run.prefix(600)), in: text), "\(text.prefix(300))")
        #expect(json(result)["redacted"] as? Int == 1)

        // A match inside the run: the whole window is the run, so the snippet is ••• alone.
        let inside = String(run.dropFirst(500_000).prefix(12))
        let deep = MCPProjectTools.findInFiles(["query": inside, "case_sensitive": true, "glob": "bundle.js", "project": "api"],
                                               in: f.both, git: nil, mask: storedMask([stored]))
        let deepText = try #require((json(deep)["matches"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(deepText == "…•••…", "\(deepText.prefix(300))")
    }

    /// A run that ends before the match: the snippet starts where it ends, with ••• for it, and keeps the match.
    @Test func aRunEndingBeforeTheMatchLeavesTheMatchInTheSnippet() throws {
        let f = try ProjectFixture()
        let run = base64Run(5000)
        try f.write("api/inline.css", "src: url(" + run + ") needle " + String(repeating: "format ", count: 60) + "\n")
        let result = MCPProjectTools.findInFiles(["query": "needle", "glob": "inline.css", "project": "api"], in: f.both, git: nil,
                                                 mask: .empty)
        let text = try #require((json(result)["matches"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(text.hasPrefix("…•••") && text.contains(") needle format") && text.count <= 310, "\(text.prefix(300))")
        #expect(!showsPart(of: String(run.suffix(200)), in: text), "\(text.prefix(300))")
    }
}

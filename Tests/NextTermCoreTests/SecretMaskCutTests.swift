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
}

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

/// What a host prints for host_changes: its status and stat, then `diff` as `head -c` cut it at `asked` bytes, then the
/// script's end, unless the connection was cut first (`ended` false).
private func hostOutput(_ diff: String, asked: Int, ended: Bool = true) -> String {
    let sent = String(decoding: Array(diff.utf8.prefix(asked)), as: UTF8.self)
    let head = "\(RemoteShell.marker)\n## main\n M .env\n\(RemoteShell.statMarker)\n .env | 2 +-\n\(RemoteShell.diffMarker)\n"
    return head + sent + (ended ? "\n\(RemoteShell.endMarker)\n" : "")
}

/// A diff of a file with CRLF line ends, as git prints it: the header's lines end in a newline, the file's in a carriage
/// return and a newline. `value` follows `lines` such lines; `start` is its first byte in the diff.
private func crlfDiff(lines: Int, value: String) -> (diff: String, start: Int) {
    var diff = "diff --git a/.env b/.env\nindex 1111111..2222222 100644\n--- a/.env\n+++ b/.env\n@@ -0,0 +1,\(lines + 2) @@\n"
    for line in 0..<lines { diff += "+SETTING_\(line)=on\r\n" }
    diff += "+DB_PASSWORD="
    let start = diff.utf8.count
    return (diff + value + "\r\n+NEXT=1\r\n", start)
}

@Suite struct HostChangesCutTests {
    /// The host's `head -c` counts each line's carriage return, and the answer drops them. Counting the margin after
    /// they were dropped, 200 of them used it up: the host's cut fell inside a value before the agent's did, and the
    /// value's start showed. Counted on the bytes as the host sent them, no cut shows any of it.
    @Test func aKeyAcrossTheCutOfACRLFDiffNeverShows() throws {
        let m = storedMask([stored])
        let (diff, start) = crlfDiff(lines: 200, value: stored)
        let into = start + 9 - m.longest // the host's cut 10 bytes into the value
        let early = try #require(RemoteChanges.parse(hostOutput(diff, asked: m.bytesToRead(forCutAt: into))))
        let dropped = early.diff.replacingOccurrences(of: "\r\n", with: "\n")
        #expect(showsPart(of: stored, in: m.maskedPrefix(dropped, maxBytes: into).text)) // the order before
        for limit in (start - m.longest - 5)...(start + stored.utf8.count + 5) {
            let asked = m.bytesToRead(forCutAt: limit)
            let changes = try #require(RemoteChanges.parse(hostOutput(diff, asked: asked)))
            let shown = changes.shownDiff(cutAt: limit, asked: asked, mask: m)
            #expect(!showsPart(of: stored, in: shown.text), "\(limit): \(shown.text.suffix(40))")
            #expect(shown.cutAt == limit && shown.text.utf8.count <= limit && !shown.text.utf8.contains(0x0D), "\(limit)")
        }
        let past = start + stored.utf8.count + 3
        let after = try #require(RemoteChanges.parse(hostOutput(diff, asked: m.bytesToRead(forCutAt: past))))
        let pastText = after.shownDiff(cutAt: past, asked: m.bytesToRead(forCutAt: past), mask: m).text
        #expect(pastText.hasSuffix("+DB_PASSWORD=•••\n+"))
        let whole = try #require(RemoteChanges.parse(hostOutput(diff, asked: m.bytesToRead(forCutAt: 100_000))))
        let all = whole.shownDiff(cutAt: 100_000, asked: m.bytesToRead(forCutAt: 100_000), mask: m)
        let expected = diff.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: stored, with: "•••")
        #expect(whole.ended && all.cutAt == nil && all.text == expected)
    }

    /// The connection keeps at most 8 MB of what a host prints, and a long status can take most of it: the connection's
    /// cut then comes before `head -c`'s, with no margin past it. The script's end never comes, so the diff is masked
    /// and cut with the margin there too, and a value across the connection's cut never shows.
    @Test func aConnectionsCutIsMaskedWithTheMargin() throws {
        let m = storedMask([stored])
        let head = "diff --git a/.env b/.env\n+DB_PASSWORD="
        let diff = head + stored + "\n+NEXT=1\n" + String(repeating: "+filler line\n", count: 60)
        let start = head.utf8.count
        let asked = m.bytesToRead(forCutAt: 100_000)
        let early = String(decoding: Array(diff.utf8.prefix(start + 10)), as: UTF8.self)
        #expect(showsPart(of: stored, in: m.maskedPrefix(early, maxBytes: 100_000).text)) // the order before
        for end in start...(start + stored.utf8.count + m.longest + 2) {
            let sent = String(decoding: Array(diff.utf8.prefix(end)), as: UTF8.self)
            let changes = try #require(RemoteChanges.parse(hostOutput(sent, asked: asked, ended: false)))
            let shown = changes.shownDiff(cutAt: 100_000, asked: asked, mask: m)
            #expect(!changes.ended && shown.cutAt != nil, "\(end)")
            #expect(!showsPart(of: stored, in: shown.text), "\(end): \(shown.text.suffix(40))")
        }
        // A cut in the status leaves out the line it fell in, and the diff, which never came, is cut at 0.
        let status = try #require(RemoteChanges.parse("\(RemoteShell.marker)\n## main\n M .env\n M conf"))
        #expect(status.files == [" M .env"] && status.branch == "main" && !status.ended)
        #expect(status.shownDiff(cutAt: 100_000, asked: asked, mask: m) == ("", 0))
        let inStat = "\(RemoteShell.marker)\n## main\n M .env\n\(RemoteShell.statMarker)\n .env | 2 +-\n con"
        let stat = try #require(RemoteChanges.parse(inStat))
        #expect(stat.files == [" M .env"] && stat.stat == ".env | 2 +-")
    }

    /// host_changes asks the host for the margin of the mask it has then, and its answer can come 50 s later. A longer
    /// key stored meanwhile, across the cut, came past the host's cut in part: the answer takes the mask again, and
    /// its margin, so none of that key shows.
    @Test func aKeyStoredDuringTheRunKeepsItsMargin() throws {
        let asking = storedMask([other])
        let long = "Vb3nXq8wLe5rTz1yKu7iPo2aSd6fGh4jMc9vBx0nWq5eRt8y"
        let answering = storedMask([other, long])
        let head = "diff --git a/.env b/.env\n+API_KEY="
        let diff = head + long + "\n+NEXT=1\n"
        let start = head.utf8.count
        let sent = String(decoding: Array(diff.utf8.prefix(asking.bytesToRead(forCutAt: start + 10))), as: UTF8.self)
        #expect(showsPart(of: long, in: answering.maskedPrefix(sent, maxBytes: start + 10).text)) // the order before
        for limit in (start - asking.longest - 5)...(start + long.utf8.count + 3) {
            let asked = asking.bytesToRead(forCutAt: limit)
            let changes = try #require(RemoteChanges.parse(hostOutput(diff, asked: asked)))
            let shown = changes.shownDiff(cutAt: limit, asked: asked, mask: answering)
            #expect(!showsPart(of: long, in: shown.text), "\(limit): \(shown.text)")
        }
    }

    /// The script on a real work tree with a CRLF file: its end comes after the diff, and no cut shows the key.
    @Test func theScriptCutsARealCRLFDiffWithoutShowingAKey() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-crlf-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/repo", withIntermediateDirectories: true)
        let lines = (0..<120).map { "SETTING_\($0)=on\r\n" }.joined()
        try Data("A=1\r\n".utf8).write(to: URL(fileURLWithPath: home + "/repo/.env"))
        try shell("git init -q && git add .env && git -c user.email=a@b -c user.name=a commit -q -m a", in: home)
        let changed = "A=1\r\n" + lines + "DB_PASSWORD=" + stored + "\r\nNEXT=1\r\n"
        try Data(changed.utf8).write(to: URL(fileURLWithPath: home + "/repo/.env"))
        let m = storedMask([stored])
        let whole = try changesOutput(home, maxBytes: 100_000)
        let first = try #require(RemoteChanges.parse(whole))
        #expect(first.ended && first.diff.contains("+SETTING_7=on\r\n") && first.files == [" M .env"])
        let bytes = Array(first.diff.utf8), needle = Array(stored.utf8)
        let offset = try #require((0...(bytes.count - needle.count)).first { Array(bytes[$0..<$0 + needle.count]) == needle })
        for limit in stride(from: offset - m.longest - 1, through: offset + stored.utf8.count, by: 7) {
            let asked = m.bytesToRead(forCutAt: limit)
            let output = try changesOutput(home, maxBytes: asked)
            let changes = try #require(RemoteChanges.parse(output))
            let shown = changes.shownDiff(cutAt: limit, asked: asked, mask: m)
            #expect(changes.ended && shown.cutAt == limit, "\(limit)")
            #expect(!showsPart(of: stored, in: shown.text), "\(limit): \(shown.text.suffix(40))")
            #expect(!shown.text.utf8.contains(0x0D), "\(limit)")
        }
    }

    private func shell(_ line: String, in home: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        process.currentDirectoryURL = URL(fileURLWithPath: home + "/repo")
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// What `RemoteShell.changesScript` prints on this Mac for the repository in `home`, as a host would send it.
    private func changesOutput(_ home: String, maxBytes: Int) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", RemoteShell.command(RemoteShell.changesScript(directory: "~/repo", maxBytes: maxBytes))]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
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

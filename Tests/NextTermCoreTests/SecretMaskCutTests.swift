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

/// A hex value, the same on every run: no long-run pattern masks it (hex never looks random), only its name does.
private func hexValue(_ count: Int) -> String {
    let digits = Array("0123456789abcdef")
    var state: UInt64 = 0x2545_F491_4F6C_DD1D
    var value = ""
    value.reserveCapacity(count)
    for _ in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        value.append(digits[Int(state >> 60)])
    }
    return value
}

@Suite struct NamedValueCutTests {
    /// read_file cuts a line at 2,000 characters. A value masked for its name can be longer than the 512 characters a
    /// cut looks around, and its name and quotes then lie outside them: the cut showed the value's first characters, or
    /// all but the first few of a bare one. The cut goes before the name now.
    @Test func readFileShowsNoPartOfALongNamedValue() throws {
        let f = try ProjectFixture()
        let quoted = hexValue(1200)
        let line = String(repeating: "lorem ipsum ", count: 160) + "password = \"" + quoted + "\" end"
        #expect(MCPRedaction.redact(line, mask: .empty).text.hasSuffix("password = \"•••\" end")) // what the whole line hides
        try f.write("api/quoted.txt", line + "\n")
        let result = json(MCPProjectTools.readFile(["path": "quoted.txt", "project": "api"], in: f.both, mask: .empty))
        let text = try #require(result["text"] as? String)
        #expect(!showsPart(of: quoted, in: text), "\(text.suffix(80))")
        #expect(text.hasPrefix("lorem ipsum") && text.hasSuffix("…") && result["long_lines_cut"] as? Int == 1)

        let bare = hexValue(3000)
        try f.write("api/.env.example", "SECRET_KEY=" + bare + "\n")
        let env = json(MCPProjectTools.readFile(["path": ".env.example", "project": "api"], in: f.both, mask: .empty))
        let envText = try #require(env["text"] as? String)
        #expect(!showsPart(of: bare, in: envText), "\(envText.prefix(80))")
    }

    /// find_in_files shows 300 characters around a match. Inside a long value masked for its name, each match's
    /// snippet showed 300 of its characters, so a pattern like `[0-9a-f]{200}` read it all; a snippet whose end fell
    /// inside one showed its start. A window inside such a value is ••• now, and an edge in one moves before its name.
    @Test func findInFilesShowsNoPartOfALongNamedValue() throws {
        let f = try ProjectFixture()
        let bare = hexValue(3000)
        try f.write("api/settings.txt", "SECRET_KEY=" + bare + "\n")
        let probe = String(bare.dropFirst(1500).prefix(12))
        let one = MCPProjectTools.findInFiles(["query": probe, "glob": "settings.txt", "project": "api"], in: f.both, git: nil,
                                              mask: .empty)
        let oneText = try #require((json(one)["matches"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(!showsPart(of: bare, in: oneText), "\(oneText)")
        let chunks = MCPProjectTools.findInFiles(["query": "[0-9a-f]{200}", "regex": true, "case_sensitive": true, "glob": "settings.txt",
                                                  "project": "api", "max_results": 200], in: f.both, git: nil, mask: .empty)
        let found = try #require(json(chunks)["matches"] as? [[String: Any]])
        #expect(found.count == 15)
        for match in found {
            let text = try #require(match["text"] as? String)
            #expect(!showsPart(of: bare, in: text), "\(match["column"] ?? 0): \(text)")
        }

        let quoted = hexValue(1500)
        let lead = "needle " + String(repeating: "lorem ", count: 25)
        try f.write("api/conf.json", lead + "\"api_key\": \"" + quoted + "\"\n")
        let upper = MCPProjectTools.findInFiles(["query": "needle", "glob": "conf.json", "project": "api"], in: f.both, git: nil,
                                                mask: .empty)
        let upperText = try #require((json(upper)["matches"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(upperText.hasPrefix("needle lorem") && upperText.hasSuffix("•••…"), "\(upperText)")
        #expect(!showsPart(of: quoted, in: upperText), "\(upperText)")
    }
}

extension NamedValueCutTests {
    /// Each way a line names a secret's value, with the value longer than a cut's reach: quoted after `=`, `:`, `=>` or
    /// `:=`, with its name quoted or not and Unicode spaces around, and bare on an env, YAML or diff line, or on a line
    /// that starts after a lone carriage return, with spaces, tabs or a line's end after it. No cut and no snippet
    /// across any of them shows a part of it. The text a cut keeps before it is redacted as read_file redacts it, with
    /// its "…" after it.
    @Test(arguments: [
        "const config = { \"apiKey\": \"%@\", other: 1 }",
        "  token => '%@' , next",
        "let secret := `%@` ok",
        "pre password\u{00A0}=\u{3000}\"%@\" post",
        "export DB_PASSWORD=%@",
        "-API_TOKEN = %@   ",
        "access_key: %@",
        "x = 1;\rPASSWORD=%@",
        "export DB_PASSWORD=%@\t\t \t",
        "SECRET_KEY=%@    \rNEXT=1",
    ])
    func noCutInAValueItsNameMasksShowsAnyOfIt(_ form: String) {
        let value = hexValue(900)
        let line = form.replacingOccurrences(of: "%@", with: value)
        let redacted = MCPRedaction.redact(line, mask: .empty).text
        #expect(!showsPart(of: value, in: redacted), "\(redacted)") // the whole line hides it
        let length = line.utf16.count
        // Every 29th place, and around the value's end: a cut on a closing quote keeps all of the value, and one in the
        // spaces after a bare value keeps it without the line's end its pattern needs.
        let end = line.range(of: value)!.upperBound.utf16Offset(in: line)
        for offset in Array(stride(from: 1, to: length, by: 29)) + [end - 1, end, end + 1, end + 2, length - 1] where offset < length {
            let at = String.Index(utf16Offset: offset, in: line)
            let back = MCPRedaction.cleanCut(line, at: at, forward: false, mask: .empty)
            let left = MCPRedaction.redact(String(line[..<back]) + "…", mask: .empty).text
            #expect(!showsPart(of: value, in: left), "\(offset) back: \(left.suffix(40))")
            let ahead = MCPRedaction.cleanCut(line, at: at, forward: true, mask: .empty)
            let right = MCPRedaction.redact(String(line[ahead...]), mask: .empty).text
            #expect(!showsPart(of: value, in: right), "\(offset) ahead: \(right.prefix(40))")
        }
        for start in stride(from: 0, to: length - 300, by: 37) {
            let lower = String.Index(utf16Offset: start, in: line)
            let window = lower..<String.Index(utf16Offset: start + 300, in: line)
            let match = String.Index(utf16Offset: start + 100, in: line)..<String.Index(utf16Offset: start + 110, in: line)
            let snippet = MCPRedaction.snippet(line, window: window, match: match, mask: .empty).text
            #expect(!showsPart(of: value, in: snippet), "\(start): \(snippet)")
        }
    }

    /// A long value under a name that is no secret's stays readable: only a secret's name makes its value one.
    @Test func aLongValueUnderAnotherNameIsCutWhereAsked() {
        let value = hexValue(900)
        let line = "label = \"" + value + "\" and more"
        let at = String.Index(utf16Offset: 400, in: line)
        #expect(MCPRedaction.cleanCut(line, at: at, forward: false, mask: .empty) == at)
        let window = String.Index(utf16Offset: 300, in: line)..<String.Index(utf16Offset: 600, in: line)
        let match = String.Index(utf16Offset: 400, in: line)..<String.Index(utf16Offset: 410, in: line)
        let snippet = MCPRedaction.snippet(line, window: window, match: match, mask: .empty).text
        #expect(snippet == "…" + String(line[window]) + "…")
    }

    /// read_file's cut at 2,000 characters on a long quoted value's closing quote kept all of the value and left out
    /// the quote the pattern needs to mask it, so the value showed whole. Cut on the quote, one before it or one past
    /// it, in double, single or back quotes, the line shows none of the value.
    @Test(arguments: ["\"", "'", "`"])
    func readFileCutOnAClosingQuoteShowsNoneOfTheValue(_ quote: String) throws {
        let f = try ProjectFixture()
        let filler = String(repeating: "lorem ipsum ", count: 58) + "sit " // 700 characters
        let name = "password = " + quote
        // The closing quote at 1,999, 2,000 or 2,001: the cut keeps it, falls on it, or falls one before it.
        for length in [1287, 1288, 1289] {
            let value = hexValue(length)
            let line = filler + name + value + quote + " end"
            #expect(MCPRedaction.redact(line, mask: .empty).text == filler + name + "•••" + quote + " end")
            try f.write("api/long-\(length).txt", line + "\n")
            let result = json(MCPProjectTools.readFile(["path": "long-\(length).txt", "project": "api"], in: f.both, mask: .empty))
            let text = try #require(result["text"] as? String)
            #expect(!showsPart(of: value, in: text), "\(length): \(text.suffix(80))")
            let kept = length < 1288 ? name + "•••" + quote : name
            #expect(text == filler + kept + "…", "\(length): \(text.suffix(80))")
            #expect(result["long_lines_cut"] as? Int == 1)
        }
    }

    /// A cut on a quoted value's closing quote is in the value for the text before it, which holds all of the value
    /// and not the quote: it goes back to just after the opening quote. A cut past the quote, or one that keeps the
    /// text after the quote, is not. A bare value's pattern needs the line's end after it, past any spaces: a cut at
    /// its end, in the spaces after it or on the line's end leaves that out, and goes back to the value's start. One
    /// past the line's end is not in it, and neither is one that keeps the text after the value.
    @Test func aQuotedValuesClosingQuoteIsInTheValue() {
        for quote in ["\"", "'", "`"] {
            let line = "let password = " + quote + "0f1e2d3c4b5a6978" + quote + " end"
            let values = MCPRedaction.NamedValues(line, mask: .empty)
            let open = line.index(line.startIndex, offsetBy: 16) // just after the opening quote
            let close = line.index(open, offsetBy: 16)
            #expect(values.cuts(close, keepingAfter: false) && values.clean(close, keepingAfter: false) == open, "\(quote)")
            #expect(!values.cuts(line.index(after: close), keepingAfter: false), "\(quote)")
            #expect(!values.cuts(close, keepingAfter: true) && values.cuts(line.index(before: close), keepingAfter: true))
        }
        let bare = "API_TOKEN=0f1e2d3c4b5a6978 \t\rnext" // the value at 10..<26, the line's end at 28
        let values = MCPRedaction.NamedValues(bare, mask: .empty)
        let first = bare.index(bare.startIndex, offsetBy: 10)
        for offset in 11...28 {
            let at = bare.index(bare.startIndex, offsetBy: offset)
            #expect(values.cuts(at, keepingAfter: false) && values.clean(at, keepingAfter: false) == first, "\(offset)")
        }
        let past = bare.index(bare.startIndex, offsetBy: 29)
        #expect(!values.cuts(past, keepingAfter: false))
        #expect(!values.cuts(bare.index(bare.startIndex, offsetBy: 26), keepingAfter: true))
    }

    /// read_file adds "…" to a line it cuts, then redacts. A bare value's pattern needs only spaces and then the line's
    /// end after the value: a cut in the spaces or tabs after one kept all of it with "…" where the line's end was, so
    /// nothing masked it. Cut there, the line shows none of it; cut past a line's end inside the line, the text kept
    /// masks it. Not cut, the line comes back masked.
    @Test func readFileCutInTheSpacesAfterABareValueShowsNoneOfIt() throws {
        let f = try ProjectFixture()
        let value = "Tr0ub4dor&3!horse"
        let spaces = String(repeating: " ", count: 2100)
        let lines = [
            "DB_PASSWORD=" + value + spaces,
            "export DB_PASSWORD=" + value + String(repeating: "\t", count: 2100),
            "  -API_TOKEN = " + value + " \t" + spaces,
            "secret: " + value + String(repeating: " \t", count: 1050),
            "DB_PASSWORD=" + value + spaces + "\rNEXT=1",
            "DB_PASSWORD=" + value + "  \r" + spaces, // the cut past the line's end: the kept text masks it
            "DB_PASSWORD=" + hexValue(1980) + String(repeating: " ", count: 100), // the cut 8 past the value
        ]
        for (index, line) in lines.enumerated() {
            let secret = line.contains(value) ? value : String(line.dropFirst(12).prefix(1980))
            #expect(!showsPart(of: secret, in: MCPRedaction.redact(line, mask: .empty).text), "\(index)") // the whole line hides it
            try f.write("api/b-\(index).ini", line + "\n")
            let result = json(MCPProjectTools.readFile(["path": "b-\(index).ini", "project": "api"], in: f.both, mask: .empty))
            let text = try #require(result["text"] as? String)
            #expect(!showsPart(of: secret, in: text), "\(index): \(text.prefix(60).debugDescription)")
            #expect(result["long_lines_cut"] as? Int == 1, "\(index)")
        }
        try f.write("api/short.ini", "DB_PASSWORD=" + value + String(repeating: " ", count: 100) + "\n")
        let short = json(MCPProjectTools.readFile(["path": "short.ini", "project": "api"], in: f.both, mask: .empty))
        #expect(short["text"] as? String == "DB_PASSWORD=•••" + String(repeating: " ", count: 100))
        #expect(short["redacted"] as? Int == 1 && short["long_lines_cut"] == nil)
    }
}

@Suite struct MaskedTailTests {
    /// A remote tool's failure answer ends with ssh's error output, its last 600 characters. Cut first, a stored value
    /// across where they start showed its end there, and the final mask cannot match part of one. Masked first, it is
    /// ••• or left out.
    @Test func aKeyAcrossWhereTheTailStartsNeverShows() {
        let m = storedMask([stored])
        let cutFirst = "bash: " + stored + " " + String(repeating: "x", count: 590) + "\n"
        let before = String(cutFirst.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600))
        #expect(showsPart(of: stored, in: m.mask(before))) // the order before
        for count in 560...610 {
            let error = "bash: " + stored + " " + String(repeating: "x", count: count) + "\n"
            let tail = m.maskedTail(error, characters: 600, endIsACut: false)
            #expect(!showsPart(of: stored, in: tail) && tail.count <= 600, "\(count): \(tail.prefix(30))")
        }
        #expect(m.maskedTail("  ssh: no route to host\n", characters: 600, endIsACut: false) == "ssh: no route to host")
        #expect(SecretMask.empty.maskedTail("plain\n", characters: 3, endIsACut: true) == "ain")
    }

    /// ssh's error output is kept up to 64 KB, and past that its end is a cut: a value it cut through is left out.
    @Test func aKeyCutAtTheEndOfTheErrorOutputNeverShows() {
        let m = storedMask([stored])
        let lead = "warning: " + String(repeating: "noise ", count: 20)
        for keep in 1...stored.count {
            let part = String(stored.prefix(keep))
            let tail = m.maskedTail(lead + part, characters: 600, endIsACut: true)
            #expect(tail.hasPrefix("warning: noise") && !tail.hasSuffix(part), "\(keep): \(tail.suffix(30))")
            if keep >= 5 { #expect(!showsPart(of: part, in: tail), "\(keep): \(tail.suffix(30))") }
        }
        let rest = " and the rest of a line that goes on past the margin"
        let whole = m.maskedTail(lead + stored + rest, characters: 600, endIsACut: true)
        #expect(whole.contains("noise ••• and the") && !whole.hasSuffix("margin") && !showsPart(of: stored, in: whole), "\(whole)")
        #expect(m.maskedTail(lead + stored + rest, characters: 600, endIsACut: false).hasSuffix("•••" + rest))
    }
}

extension HostChangesCutTests {
    /// A connection cut inside the script's end line left the part of it that came at the end of the diff, with no key
    /// stored to keep a margin. That part goes now, whatever the margin.
    @Test func aConnectionsCutInTheEndLineLeavesNoneOfIt() throws {
        let diff = "diff --git a/notes.md b/notes.md\n+one line\n"
        let end = Array("\n\(RemoteShell.endMarker)\n".utf8)
        for mask in [SecretMask.empty, storedMask([stored])] {
            let asked = mask.bytesToRead(forCutAt: 100_000)
            for count in 0..<end.count {
                let output = hostOutput(diff, asked: asked, ended: false) + String(decoding: end.prefix(count), as: UTF8.self)
                let changes = try #require(RemoteChanges.parse(output))
                let shown = changes.shownDiff(cutAt: 100_000, asked: asked, mask: mask)
                #expect(!changes.ended && diff.hasPrefix(shown.text) && !shown.text.contains("@@NEXT"), "\(count): \(shown.text)")
                #expect(shown.cutAt == shown.text.utf8.count, "\(count)")
            }
        }
    }

    /// The host's bytes as they come: a Latin-1 byte (no UTF-8) and wide characters before the key, and a key of
    /// two-byte characters. Neither `head -c` nor the connection, cutting at any byte near it, shows any of it.
    @Test func aCutThroughInvalidOrWideCharactersNearAKeyShowsNoneOfIt() throws {
        let wide = "Zq7Ωж9Ψ2λЖ4ξ8Ðr5ŵ3"
        let m = storedMask([wide])
        let lead = Array("diff --git a/.env b/.env\n+NAME=caf".utf8) + [0xE9] + Array(" \u{4E2D}\u{6587}\n+DB_PASSWORD=".utf8)
        let host = lead + Array(wide.utf8) + Array("\n+NEXT=1\n".utf8) + Array(String(repeating: "+filler\n", count: 40).utf8)
        let head = Array("\(RemoteShell.marker)\n## main\n\(RemoteShell.statMarker)\n\(RemoteShell.diffMarker)\n".utf8)
        let end = Array("\n\(RemoteShell.endMarker)\n".utf8)
        let start = lead.count
        for limit in max(1, start - m.longest - 4)...(start + wide.utf8.count + 4) {
            let asked = m.bytesToRead(forCutAt: limit)
            let changes = try #require(RemoteChanges.parse(String(decoding: head + host.prefix(asked) + end, as: UTF8.self)))
            let shown = changes.shownDiff(cutAt: limit, asked: asked, mask: m)
            #expect(!showsPart(of: wide, in: shown.text), "\(limit): \(shown.text.suffix(30))")
        }
        for cut in (start - 4)...(start + wide.utf8.count + m.longest + 2) {
            let asked = m.bytesToRead(forCutAt: 100_000)
            let changes = try #require(RemoteChanges.parse(String(decoding: head + host.prefix(cut), as: UTF8.self)))
            let shown = changes.shownDiff(cutAt: 100_000, asked: asked, mask: m)
            #expect(!changes.ended && !showsPart(of: wide, in: shown.text), "\(cut): \(shown.text.suffix(30))")
        }
    }
}

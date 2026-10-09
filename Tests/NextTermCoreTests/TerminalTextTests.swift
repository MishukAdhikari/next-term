import Foundation
import Testing
@testable import NextTermCore

/// The sanitizer for text a restore feeds into a terminal (KTD9): only printable text, newlines and tabs get through,
/// so nothing in a note, a folder name or replayed scrollback can make the terminal answer, copy or run anything.
@Suite struct TerminalTextTests {
    /// What a terminal answers or acts on: device attributes and status reports, the clipboard (OSC 52), Next Term's
    /// own integration channel (OSC 6973 with a nonce), a settings query (DECRQSS), a title report (CSI 21 t), the end
    /// of a bracketed paste, and the same introducers as 8-bit C1 characters.
    static let hostile: [String] = [
        "\u{1B}[c", "\u{1B}[>c", "\u{1B}[5n", "\u{1B}[6n",
        "\u{1B}]52;c;aGVsbG8=\u{07}", "\u{1B}]52;c;?\u{1B}\\",
        "\u{1B}]6973;6f1e2d3c4b5a;cmd;bHM=;bHM=\u{07}", "\u{1B}]6973;6f1e2d3c4b5a;end;0\u{07}",
        "\u{1B}P$qm\u{1B}\\", "\u{1B}[21t", "\u{1B}[201~", "\u{1B}[200~",
        "\u{9B}6n", "\u{9B}c", "\u{9D}52;c;aGVsbG8=\u{9C}", "\u{90}$qm\u{9C}",
        "\u{7F}", "\u{0}", "\r", "\u{08}", "\u{0E}", "\u{1B}",
    ]

    static func isPrintable(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in
            switch scalar.value {
            case 0x09, 0x0A: return true
            case 0x00...0x1F, 0x7F...0x9F: return false
            default: return true
            }
        }
    }

    @Test func theHostileListLeavesOnlyPrintableText() {
        for sample in Self.hostile {
            let clean = TerminalText.sanitize("before " + sample + " after")
            #expect(Self.isPrintable(clean), "\(sample.unicodeScalars.map(\.value))")
            #expect(clean.hasPrefix("before ") && clean.hasSuffix(" after"))
        }
        let all = TerminalText.sanitize(Self.hostile.joined())
        #expect(Self.isPrintable(all))
        #expect(!all.unicodeScalars.contains("\u{1B}") && !all.unicodeScalars.contains("\u{9B}") && !all.unicodeScalars.contains("\u{07}"))
    }

    @Test func printableTextStaysAsItIs() {
        let text = "héllo wörld ✓ 日本語 🚀 a\tb\nnext line — “quoted” […]"
        #expect(TerminalText.sanitize(text) == text)
        #expect(TerminalText.sanitize("") == "")
    }

    @Test func c1EncodedAsUTF8AndStrayEightBitBytesAreHarmless() {
        // C1 as UTF-8 (C2 9B) is one scalar, U+009B: removed.
        let utf8: [UInt8] = [0x61, 0xC2, 0x9B, 0x36, 0x6E, 0x62]
        #expect(TerminalText.sanitize(utf8: utf8) == "a6nb")
        // A lone 0x9B is not UTF-8: it reads as U+FFFD, which a terminal only shows.
        let raw: [UInt8] = [0x61, 0x9B, 0x36, 0x6E, 0x1B, 0x5B, 0x63, 0x62]
        let clean = TerminalText.sanitize(utf8: raw)
        #expect(clean == "a\u{FFFD}6n[cb")
        #expect(Self.isPrintable(clean))
    }

    @Test func oneLineTurnsBreaksAndTabsIntoSpaces() {
        #expect(TerminalText.oneLine("a\nb\tc\r\nd\u{1B}[2Je") == "a b c d[2Je")
        #expect(!TerminalText.oneLine(Self.hostile.joined(separator: "\n")).contains("\n"))
    }

    @Test func oneLineShowsInvisibleAndDirectionCharactersAsReplacements() {
        // Bidi overrides and isolates, zero-width characters and other format characters could make a note read as
        // something else; line and paragraph separators would break it.
        let text = "a\u{202E}b\u{2066}c\u{200B}d\u{FEFF}e\u{00AD}f\u{2028}g\u{2029}h"
        #expect(TerminalText.oneLine(text) == "a\u{FFFD}b\u{FFFD}c\u{FFFD}d\u{FFFD}e\u{FFFD}f g h")
        // Scrollback keeps them: a program printed them, and joiners hold emoji together.
        #expect(TerminalText.sanitize("👩\u{200D}💻") == "👩\u{200D}💻")
    }

    @Test func feedableWritesEachNewlineAsCRLF() {
        #expect(TerminalText.feedable("one\ntwo\n") == "one\r\ntwo\r\n")
        // A carriage return of its own is a control character: it goes, and the newline gets its own.
        #expect(TerminalText.feedable("one\r\ntwo\rthree") == "one\r\ntwothree")
        let fed = TerminalText.feedable(Self.hostile.joined(separator: "\n"))
        let crs = fed.unicodeScalars.filter { $0 == "\r" }.count
        let lfs = fed.unicodeScalars.filter { $0 == "\n" }.count
        let breaks: Int = Self.hostile.count - 1
        #expect(crs == lfs && lfs == breaks)
        #expect(Self.isPrintable(fed.replacingOccurrences(of: "\r\n", with: "\n")))
    }
}

/// The scrollback an update quit saves (R4, KTD9): rows joined where the terminal wrapped them and where a shell went
/// on over PS2 rows, sanitized, masked through CommandSecrets.mask, the line of a command that held a secret blanked,
/// an agent's pane cut at its command, capped, and each newline written as CR LF.
@Suite struct ScrollbackTextTests {
    typealias Row = ScrollbackText.Row
    typealias Echo = ScrollbackText.Echo

    /// A GitHub token only whole: neither half of it is one.
    static let firstHalf = "ghp_abcdefgh"
    static let secondHalf = "ijklmnop1234QRST"

    /// What `saved` gives, with what it handed `CommandSecrets.mask`.
    private func savedAndMasked(_ rows: [Row], dropped: [Echo] = []) -> (saved: String, masked: [String]) {
        var masked: [String] = []
        let saved = ScrollbackText.saved(rows, dropped: dropped, extent: .all, limits: .standard) { (text: String) -> String in
            masked.append(text)
            return CommandSecrets.mask(text)
        }
        return (saved, masked)
    }

    // MARK: joins

    @Test func rowsTheTerminalWrappedAreOneLine() {
        let rows = [Row("first half "), Row("and the rest", wrapped: true), Row("next line")]
        #expect(ScrollbackText.saved(rows) == "first half and the rest\r\nnext line")
    }

    @Test func aTokenPrintedAcrossAWrapIsMasked() {
        #expect(CommandSecrets.mask("$ echo " + Self.firstHalf) == "$ echo " + Self.firstHalf)
        #expect(CommandSecrets.mask(Self.secondHalf + " done") == Self.secondHalf + " done")
        let wrapped = [Row("$ echo " + Self.firstHalf), Row(Self.secondHalf + " done", wrapped: true)]
        #expect(ScrollbackText.saved(wrapped) == "$ echo ••• done")
        // Two lines the terminal did not wrap are two lines, each masked alone.
        let apart = [Row("$ echo " + Self.firstHalf), Row(Self.secondHalf + " done")]
        #expect(ScrollbackText.saved(apart) == "$ echo \(Self.firstHalf)\r\n\(Self.secondHalf) done")
    }

    @Test func withoutWrapFlagsATokenSplitAcrossTwoRowsIsMasked() {
        let rows = [Row("$ echo " + Self.firstHalf, wrapped: nil), Row(Self.secondHalf + " done", wrapped: nil),
                    Row("plain text", wrapped: nil), Row("after DB_PASSWORD=hunter2", wrapped: nil)]
        #expect(ScrollbackText.saved(rows) == "$ echo •••\r\n••• done\r\nplain text\r\nafter DB_PASSWORD=•••")
        // A value split there: masked alone, the first row leaves the rest of it on the second; joined, it goes too.
        let split = [Row("DB_PASSWORD=hunt", wrapped: nil), Row("er2 next", wrapped: nil)]
        #expect(ScrollbackText.saved(split) == "DB_PASSWORD=•••\r\n••• next")
    }

    @Test func aSecretOnAPS2RowAfterABackslashIsMaskedAndTheRowKeepsItsPrompt() {
        let rows = [Row("% app --password \\"), Row("> s3cret")]
        let (saved, masked) = savedAndMasked(rows)
        #expect(saved == "% app --password \\\r\n> •••")
        // A newline alone after the row's own backslash (a second would make `\\` the value), and no PS2 prompt.
        #expect(masked == ["% app --password \\\ns3cret"])
        // Alone, the continuation row names no tool.
        #expect(CommandSecrets.mask("% app --password \\\n> s3cret") == "% app --password \\\n> s3cret")
    }

    @Test func aPS2RowAfterARowWithoutABackslashIsJoinedWithABackslashNewline() {
        let (saved, masked) = savedAndMasked([Row("$ echo pw |"), Row("> sudo -S ls"), Row("Password:")])
        #expect(saved == "$ echo ••• |\r\n> sudo -S ls\r\nPassword:")
        #expect(masked == ["$ echo pw |\\\nsudo -S ls\nPassword:"])
        // A continuation can go on over several rows, and zsh's PS2 names what it continues.
        let zsh = [Row("% mysql -u root \\"), Row("> -h db \\"), Row("> -pS3cret app"), Row("% echo pw |"),
                   Row("pipe> sudo -S ls")]
        #expect(ScrollbackText.saved(zsh) == "% mysql -u root \\\r\n> -h db \\\r\n> -p••• app\r\n% echo ••• |\r\npipe> sudo -S ls")
    }

    @Test func aQuotedLineIsNotAContinuation() {
        // A bare `> ` row continues only a line that goes on (a backslash, a pipe, && or ||): not a quote in output.
        let (saved, masked) = savedAndMasked([Row("$ cat notes.md"), Row("> s3cret here"), Row("> --password")])
        #expect(saved == "$ cat notes.md\r\n> s3cret here\r\n> --password")
        #expect(masked == ["$ cat notes.md\n> s3cret here\n> --password"])
    }

    // MARK: what is kept

    @Test func itStripsTheHostileListMasksATokenBlanksADroppedEchoAndRespectsTheCap() {
        let hostile = TerminalTextTests.hostile.joined(separator: " ")
        let rows = [Row("old line"), Row("% DB_PASSWORD=hunter2 npm start"), Row("listening on 3000"),
                    Row("build ok sk-ant-api03-abcdefgh12345678 more"), Row("x " + hostile + " y")]
        let echo = Echo(row: 101, shown: ["% DB_PASSWORD=hunter2 npm start"])
        let saved = ScrollbackText.saved(rows, firstRow: 100, dropped: [echo])
        let lines = saved.components(separatedBy: "\r\n")
        #expect(lines.count == 5)
        #expect(lines[0] == "old line" && lines[1] == "" && lines[2] == "listening on 3000")
        #expect(lines[3] == "build ok ••• more")
        #expect(lines[4].hasPrefix("x ") && lines[4].hasSuffix(" y"))
        #expect(TerminalTextTests.isPrintable(saved.replacingOccurrences(of: "\r\n", with: "\n")))
        #expect(!saved.contains("hunter2") && !saved.contains("DB_PASSWORD"))
        let capped = ScrollbackText.saved(rows, firstRow: 100, dropped: [echo], limits: .init(lines: 2, bytes: 1 << 20))
        #expect(capped.components(separatedBy: "\r\n") == ["build ok ••• more", lines[4]])
    }

    @Test func aDroppedCommandsEchoIsFoundByItsTextAfterTheRowsMoved() {
        // Recorded at rows 7 and 8; a resize reflowed the buffer since, so the command now starts on row 3.
        let rows = [Row("% ls"), Row("a b"), Row("% mysql -u root \\"), Row("> -pS3cret app", wrapped: false), Row("% ls")]
        let echo = Echo(row: 7, shown: ["% mysql -u root \\", "> -pS3cret app"])
        #expect(ScrollbackText.saved(rows, firstRow: 1, dropped: [echo]) == "% ls\r\na b\r\n\r\n\r\n% ls")
        // Shown on one row when recorded, wrapped onto two by a narrower window since: the same line.
        let one = Echo(row: 3, shown: ["% export GITHUB_TOKEN=ghp_abcdefghijklmnop1234QRST"])
        let wrapped = [Row("% export GITHUB_TOKEN=ghp_abcd"), Row("efghijklmnop1234QRST", wrapped: true), Row("% ls")]
        #expect(ScrollbackText.saved(wrapped, dropped: [one]) == "\r\n% ls")
    }

    @Test func anAgentsPaneKeepsOnlyWhatCameBeforeItsCommand() {
        let rows = [Row("% npm test"), Row("ok"), Row("% claude"), Row("╭──────╮"), Row("│ > hi │"), Row("% claude")]
        let start = Echo(row: 12, shown: ["% claude"])
        let atRow = ScrollbackText.saved(rows, firstRow: 10, extent: .before(start))
        #expect(atRow == "% npm test\r\nok")
        // The row moved (a resize): the last place it shows is the agent's.
        let moved = ScrollbackText.saved(rows, firstRow: 30, extent: .before(start))
        #expect(moved == "% npm test\r\nok\r\n% claude\r\n╭──────╮\r\n│ > hi │")
        // Not known, or not found: nothing is kept.
        #expect(ScrollbackText.saved(rows, extent: .before(nil)).isEmpty)
        #expect(ScrollbackText.saved(rows, extent: .before(Echo(row: 0, shown: ["% codex"]))).isEmpty)
        // Rows with no number to go by (the normal buffer behind the alternate screen): where it last shows.
        let unnumbered = rows.map { (row: Row) -> Row in Row(row.text, wrapped: nil) }
        #expect(ScrollbackText.saved(unnumbered, firstRow: nil, extent: .before(start)) == moved)
    }

    @Test func theCapKeepsTheLatestLinesAndLeavesOutAPartCutFromWhatWentBefore() {
        let rows = (1...10).map { Row("line \($0)") }
        #expect(ScrollbackText.saved(rows, limits: .init(lines: 3, bytes: 1 << 20)) == "line 8\r\nline 9\r\nline 10")
        // Each line counts its CR LF: "line 10\r\n" is 9 bytes, "line 9\r\n" 8.
        #expect(ScrollbackText.saved(rows, limits: .init(lines: 100, bytes: 17)) == "line 9\r\nline 10")
        #expect(ScrollbackText.saved(rows, limits: .init(lines: 100, bytes: 16)) == "line 10")
        // A PS2 row whose start the cap cut off goes too: alone it would name no tool.
        let continued = [Row("% app --password \\"), Row("> s3cret"), Row("done")]
        #expect(ScrollbackText.saved(continued, limits: .init(lines: 2, bytes: 1 << 20)) == "done")
        // Rows without wrap flags: the first one kept may be the end of a wrapped line, so it goes too.
        let plain = (1...5).map { Row("row \($0)", wrapped: nil) }
        #expect(ScrollbackText.saved(plain, limits: .init(lines: 3, bytes: 1 << 20)) == "row 4\r\nrow 5")
        #expect(ScrollbackText.saved(plain, limits: .init(lines: 5, bytes: 1 << 20)).hasPrefix("row 1\r\n"))
    }

    @Test func aLineWhoseStartScrolledOffTheBufferIsLeftOut() {
        let rows = [Row(Self.secondHalf + " done", wrapped: true), Row("next")]
        #expect(ScrollbackText.saved(rows) == "next")
    }

    @Test func everyNewlineIsCRLF() {
        let rows = [Row("one"), Row("two\r"), Row(""), Row("three"), Row(""), Row("   ")]
        let saved = ScrollbackText.saved(rows)
        #expect(saved == "one\r\ntwo\r\n\r\nthree")
        let unpaired = saved.replacingOccurrences(of: "\r\n", with: "")
        #expect(!unpaired.contains("\r") && !unpaired.contains("\n"))
        #expect(ScrollbackText.saved([]).isEmpty)
    }

    @Test func emptyCellsReadAsBlanks() {
        // A tab moves the cursor past cells it never writes: they read as U+0000.
        #expect(ScrollbackText.saved([Row("a\u{0}\u{0}\u{0}b\u{0}\u{0}")]) == "a   b")
    }

    @Test func aRuleThatTakesAJoinsNewlineMasksEveryRowItSpans() {
        // `echo "pw` then `dquote> " | sudo -S ls`: what is echoed spans the join, so masking it takes the newline too.
        let rows = [Row("ok"), Row("% echo \"pw"), Row("dquote> \" | sudo -S ls"), Row("done")]
        #expect(ScrollbackText.saved(rows) == "ok\r\n•••\r\ndquote> •••\r\ndone")
        // The same from any masking that loses a line.
        let continued = [Row("one"), Row("% app --password \\"), Row("> s3cret"), Row("two")]
        let lossy = ScrollbackText.saved(continued, dropped: [], extent: .all, limits: .standard) { (text: String) -> String in
            text.replacingOccurrences(of: "\\\n", with: " ")
        }
        #expect(lossy == "one\r\n•••\r\n> •••\r\ntwo")
    }

    // MARK: commands

    @Test func aCommandWhoseLineHeldASecretIsDropped() {
        #expect(ScrollbackText.holdsSecret(typed: "DB_PASSWORD=hunter2 npm start"))
        #expect(ScrollbackText.holdsSecret(typed: " ls"))
        #expect(ScrollbackText.holdsSecret(typed: "deploy", expanded: "deploy --token abc123"))
        #expect(ScrollbackText.holdsSecret(typed: "echo pw |\nsudo -S ls"))
        #expect(ScrollbackText.holdsSecret(typed: "mysql -u root \\\n-pS3cret"))
        #expect(!ScrollbackText.holdsSecret(typed: "npm run dev"))
        #expect(!ScrollbackText.holdsSecret(typed: "ls \\\n-la", expanded: "ls -G \\\n-la"))
    }

    // MARK: files

    @Test func fileNamesNameTheMarkerAndThePane() {
        let marker = UUID(uuidString: "C4D5E6F7-1A2B-4C3D-8E9F-0A1B2C3D4E5F")!
        let pane = UUID(uuidString: "9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d")!
        let name = ScrollbackText.fileName(marker: marker, pane: pane)
        #expect(name == "scrollback-c4d5e6f7-1a2b-4c3d-8e9f-0a1b2c3d4e5f-9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d")
        #expect(ScrollbackText.parseFileName(name)?.marker == marker && ScrollbackText.parseFileName(name)?.pane == pane)
        for planted in ["scrollback-../state-v1.json", "scrollback-/etc/passwd", name + "/x", name.uppercased(), "../" + name,
                        "scrollback-c4d5e6f7-1a2b-4c3d-8e9f-0a1b2c3d4e5f", name + ".prev"] {
            #expect(ScrollbackText.parseFileName(planted) == nil, "\(planted)")
        }
    }

    @Test func onlyTheClaimedMarkersFilesAreReadAndEveryOneIsRemoved() {
        let marker = UUID(uuidString: "c4d5e6f7-1a2b-4c3d-8e9f-0a1b2c3d4e5f")!
        let other = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let wanted = UUID(uuidString: "9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d")!
        let unknown = UUID(uuidString: "0f0e0d0c-0b0a-4908-8706-050403020100")!
        let scrollback: [String] = [ScrollbackText.fileName(marker: marker, pane: wanted),
                                    ScrollbackText.fileName(marker: marker, pane: unknown),
                                    ScrollbackText.fileName(marker: other, pane: wanted), "scrollback-planted"]
        let names: [String] = [SessionSnapshot.fileName()] + scrollback + ["owner.lock"]
        let sorted = ScrollbackText.sort(names, marker: marker, panes: [wanted])
        #expect(sorted.read == [wanted: scrollback[0]])
        #expect(sorted.remove == scrollback)
        let unread = ScrollbackText.sort(names, marker: nil, panes: [wanted])
        #expect(unread.read.isEmpty)
        #expect(unread.remove == scrollback)
    }

    // MARK: showing it again

    @Test func thePrefaceShowsTheLinesAboveADimDivider() {
        let preface = ScrollbackText.preface("old one\r\nold two\u{1B}]52;c;aGk=\u{07}")
        #expect(preface == "old one\r\nold two]52;c;aGk=\r\n\u{1B}[2m\(ScrollbackText.divider)\u{1B}[0m\r\n")
        #expect(ScrollbackText.preface("") == "\u{1B}[2m\(ScrollbackText.divider)\u{1B}[0m\r\n")
        let fed = preface.replacingOccurrences(of: "\u{1B}[2m", with: "").replacingOccurrences(of: "\u{1B}[0m", with: "")
        #expect(TerminalTextTests.isPrintable(fed.replacingOccurrences(of: "\r\n", with: "\n")))
    }

    @Test func questionsAreReadOnlyBelowTheDivider() {
        let divider = ScrollbackText.divider
        let tail = ["Do you want to proceed? (y/n)", divider, "% claude --resume S", "Working"]
        #expect(ScrollbackText.below(divider: divider, in: tail) == ["% claude --resume S", "Working"])
        #expect(ScrollbackText.below(divider: divider, in: ["a", "b"]) == ["a", "b"])
        // In a narrow pane it wraps, and the row before the wrap loses its trailing blank.
        let words = divider.split(separator: " ", maxSplits: 2).map(String.init)
        let narrow = ["(y/n)", words[0] + " " + words[1], words[2], "live"]
        #expect(ScrollbackText.below(divider: divider, in: narrow) == ["live"])
        // A box an agent draws is no divider.
        #expect(ScrollbackText.below(divider: divider, in: ["(y/n)", "──", "live"]) == ["(y/n)", "──", "live"])
    }

    @Test func theNormalBufferReadAsTextHasNoWrapFlags() {
        // The other half of a wide character reads as U+0000 there too: it goes, and other empty cells are blanks.
        let data = Data("日\u{0}本\u{0}x\u{0}\u{0}y\n\nlast\n".utf8)
        let rows = ScrollbackText.rows(bufferData: data)
        #expect(rows.count == 3 && rows.allSatisfy { (row: Row) -> Bool in row.wrapped == nil })
        #expect(ScrollbackText.saved(rows) == "日本x  y\r\n\r\nlast")
    }

    @Test func aFullScrollbackIsSavedInTime() {
        let sample = ["% npm run build", "src/app.ts:12:4 - error TS2322: Type 'string' is not assignable to type 'number'.",
                      "  at Object.<anonymous> (/Users/x/Code/app/node_modules/ts-node/src/index.ts:1587:12)",
                      "GET /api/users 200 12.345 ms - 1532", "commit 3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a"]
        let rows = (0..<5_000).map { (index: Int) -> Row in Row(sample[index % sample.count]) }
        let clock = ContinuousClock()
        var saved = ""
        let elapsed = clock.measure { saved = ScrollbackText.saved(rows) }
        #expect(saved.components(separatedBy: "\r\n").count == 5_000)
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }
}

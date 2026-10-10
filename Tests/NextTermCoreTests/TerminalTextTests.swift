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

    // MARK: between sequences

    /// What the shell printed, read in pieces as the terminal reads them: whether each piece leaves it between sequences.
    func between(_ pieces: [[UInt8]]) -> [Bool] {
        var watch = TerminalText.SequenceWatch()
        return pieces.map { (piece: [UInt8]) -> Bool in
            watch.read(piece)
            return watch.isBetweenSequences
        }
    }

    func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// Text fed after the shell started joins any sequence its output left open (a title, a clipboard write, the
    /// integration's own channel), so a note waits until the output is between sequences, as SwiftTerm's parser reads
    /// it: a CSI or ESC sequence ends at its final byte, an OSC or APC string at BEL, CAN or ESC, and a DCS, SOS or PM
    /// string only at SUB or ESC.
    @Test func aWatchKnowsWhenTheOutputIsBetweenSequences() {
        #expect(TerminalText.SequenceWatch().isBetweenSequences)
        #expect(between([bytes("% ls\r\n"), bytes("\u{1B}[1;32mok\u{1B}[0m\r\n")]) == [true, true])
        // An OSC string split across reads: a title, the integration's channel, ended by BEL or by ST (ESC and a backslash).
        #expect(between([bytes("\u{1B}]0;~/app"), bytes(" — zsh"), bytes("\u{07}")]) == [false, false, true])
        #expect(between([bytes("\u{1B}]6973;6f1e;cmd;bHM="), bytes("\u{1B}"), bytes("\\")]) == [false, false, true])
        #expect(between([bytes("\u{1B}]52;c;aGVs"), [0x18]]) == [false, true])
        #expect(between([bytes("\u{1B}_Gf=24;"), bytes("AAAA\u{07}")]) == [false, true])
        // A title holding a character whose UTF-8 bytes look like 8-bit controls stays open until its own end.
        #expect(between([bytes("\u{1B}]2;Ŝ"), [0x9C], bytes("x\u{07}")]) == [false, false, true])
        // A CSI or ESC sequence cut short, and ended.
        #expect(between([bytes("\u{1B}[3"), bytes("8;5;2"), bytes("08m")]) == [false, false, true])
        #expect(between([bytes("\u{1B}"), bytes("(B")]) == [false, true])
        #expect(between([bytes("\u{1B}[?2004"), [0x1A]]) == [false, true])
        // DCS, SOS and PM go on through BEL and CAN, as SwiftTerm reads them.
        #expect(between([bytes("\u{1B}P$qm"), [0x07], [0x18], bytes("\u{1B}\\")]) == [false, false, false, true])
        #expect(between([bytes("\u{1B}^note"), [0x1A]]) == [false, true])
        // 8-bit introducers inside a sequence start another, as SwiftTerm's table has them; printed text keeps them as text.
        #expect(between([bytes("\u{1B}["), [0x9D], bytes("0;t"), [0x07]]) == [false, false, false, true])
        #expect(between([[0x9B, 0x9D, 0x90]]) == [true])
        // A character cut across reads.
        #expect(between([[0xE2, 0x9C], [0x93], [0xF0, 0x9F, 0x8E], [0x89]]) == [false, true, false, true])
        #expect(between([[0xC3], bytes("\r\n")]) == [false, true])
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

    /// `line` over rows `width` cells wide, as a terminal wraps it.
    static func wrapping(_ line: String, width: Int) -> [String] {
        var rows: [String] = []
        var rest = Substring(line)
        while !rest.isEmpty {
            rows.append(String(rest.prefix(width)))
            rest = rest.dropFirst(width)
        }
        return rows
    }

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

    @Test func withoutWrapFlagsTheRestOfAKeyTheFirstRowMaskedAloneIsMaskedToo() {
        // The first row alone holds enough of it to be masked; the rest, on the next row, only joined to the row as it was.
        let rows = [Row("$ echo ghp_abcdefghijklmnopqrstUVWX", wrapped: nil), Row("YZ0123456789 done", wrapped: nil)]
        #expect(ScrollbackText.saved(rows) == "$ echo •••\r\n••• done")
        let key = "Ab3Cd4Ef5Gh6Ij7Kl8Mn9Op0Qr1St2Uv3Wx4Yz5Ab6Cd7Ef8Gh9Ij0Kl1Mn2Op"
        let split = [Row("key " + key.prefix(33), wrapped: nil), Row(key.dropFirst(33) + " ok", wrapped: nil)]
        #expect(ScrollbackText.saved(split) == "key •••\r\n••• ok")
        // What masking a row alone found is kept as it was, and the rest of the row too.
        let both = [Row("TOKEN=abc123 and $ echo ghp_abcdefghijklmnopqrstUVWX", wrapped: nil),
                    Row("YZ0123456789 done SECRET=x9", wrapped: nil)]
        #expect(ScrollbackText.saved(both) == "TOKEN=••• and $ echo •••\r\n••• done SECRET=•••")
    }

    @Test func withoutWrapFlagsAWrapAtABlankKeepsABlankBetweenTheRows() {
        // getBufferAsData trims a row's empty cells, and a blank written at its end goes when it is saved: either way
        // the rows are joined with a blank where the first did not fill the width, or ended in one.
        let short = ScrollbackText.rows(bufferData: Data("% app --password\ns3cretValue9 && ls\n".utf8), columns: 20)
        #expect(short.map(\.full) == [false, false])
        #expect(ScrollbackText.saved(short) == "% app --password\r\n••• && ls")
        let ended = ScrollbackText.rows(bufferData: Data("% app --password \ns3cretValue9\n".utf8), columns: 17)
        #expect(ended.map(\.full) == [true, false])
        #expect(ScrollbackText.saved(ended) == "% app --password\r\n•••")
        // Not known to fill it: joined both ways.
        let unknown = [Row("% app --password", wrapped: nil), Row("s3cretValue9 && ls", wrapped: nil)]
        #expect(ScrollbackText.saved(unknown) == "% app --password\r\n••• && ls")
    }

    @Test func withoutWrapFlagsRowsThatFillTheWidthAreMaskedAsTheLineTheyWere() {
        // docker login over three rows of 24: the tool on the first, the password on the last.
        let docker = "% docker login registry.example.com --username sam -p Zq7Lw2Xr9"
        let shown = Self.wrapping(docker, width: 24)
        #expect(shown == ["% docker login registry.", "example.com --username s", "am -p Zq7Lw2Xr9"])
        let rows = ScrollbackText.rows(bufferData: Data((shown + ["% ls"]).map { $0 + "\n" }.joined().utf8), columns: 24)
        #expect(rows.map(\.full) == [true, true, false, false])
        #expect(ScrollbackText.saved(rows) == "% docker login registry.\r\nexample.com --username s\r\nam -p •••\r\n% ls")
        // A blank at the end of a full row stays between it and the next.
        let mysql = ["% mysql -h db.example.internal ", "--user=root --database=app1 -pS", "3cretPass9"]
        let rows31 = ScrollbackText.rows(bufferData: Data((mysql + ["% ls"]).map { $0 + "\n" }.joined().utf8), columns: 31)
        #expect(rows31.map(\.full) == [true, true, false, false])
        let masked31 = "% mysql -h db.example.internal\r\n--user=root --database=app1 -p•••\r\n•••\r\n% ls"
        #expect(ScrollbackText.saved(rows31) == masked31)
    }

    @Test func withoutWrapFlagsADroppedCommandIsFoundOverTheRowsItWrappedOver() {
        // Its echo is its line as one: rows read without wrap flags are each a line, so it is found by its text
        // without blanks, over as many rows as it takes.
        let docker = "% docker login registry.example.com --username sam -p Zq7Lw2Xr9"
        let rows = Self.wrapping(docker, width: 24).map { (text: String) -> Row in Row(text, wrapped: nil) } + [Row("% ls", wrapped: nil)]
        #expect(ScrollbackText.saved(rows, dropped: [Echo(row: 0, shown: [docker])]) == "\r\n\r\n\r\n% ls")
        // Wrapped at a blank, which the row lost at its end; read as capture reads it, with no row numbers.
        let mysql = "% mysql --host=db.example.internal --user=root --database=app -pS3cretPass9"
        let at30 = ["% before", "% mysql --host=db.example.internal", "--user=root --database=app -pS3", "cretPass9", "% ls"]
        let unnumbered = at30.map { (text: String) -> Row in Row(text, wrapped: nil) }
        let saved = ScrollbackText.saved(unnumbered, firstRow: nil, dropped: [Echo(row: 7, shown: [mysql])])
        #expect(saved == "\r\n\r\n\r\n% ls")
        // A command typed over PS2 rows: each of its lines over its own rows.
        let typed = ["% mysql -u root --host=db.example.internal \\", "> -pS3cretPass9 app"]
        let ps2 = ["% mysql -u root --host=db.examp", "le.internal \\", "> -pS3cretPass9 app", "done"]
        let ps2Rows = ps2.map { (text: String) -> Row in Row(text, wrapped: nil) }
        #expect(ScrollbackText.saved(ps2Rows, dropped: [Echo(row: 0, shown: typed)]) == "\r\n\r\n\r\ndone")
        // The same text spaced otherwise is the same line; other text is not.
        let spaced = [Row("% ls  -la", wrapped: nil), Row("% ls -l", wrapped: nil)]
        #expect(ScrollbackText.saved(spaced, dropped: [Echo(row: 0, shown: ["% ls -la"])]) == "\r\n% ls -l")
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

    @Test func aHereDocumentFedToAPasswordReaderIsMaskedOnItsPS2Row() {
        #expect(ScrollbackText.holdsSecret(typed: "docker login -u sam --password-stdin <<EOF\nS3cretPw\nEOF"))
        let zsh = [Row("% docker login -u sam --password-stdin <<EOF"), Row("heredoc> S3cretPw"), Row("heredoc> EOF"),
                   Row("Login Succeeded")]
        #expect(ScrollbackText.saved(zsh) == "% docker login -u sam --password-stdin <<EOF\r\nheredoc> •••\r\nheredoc> EOF\r\nLogin Succeeded")
        // bash's PS2 names nothing: a line that ends in a here-document's word goes on, as one that ends in a pipe does.
        let bash = [Row("$ sudo -S whoami <<'END'"), Row("> S3cretPw"), Row("> END"), Row("root")]
        #expect(ScrollbackText.saved(bash) == "$ sudo -S whoami <<'END'\r\n> •••\r\n> END\r\nroot")
        #expect(ScrollbackText.saved([Row("$ cat <<EOF"), Row("> hello"), Row("> EOF")]) == "$ cat <<EOF\r\n> hello\r\n> EOF")
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
        // Rows with no number to go by (the normal buffer behind the alternate screen): where it last shows. The first
        // row read there may be the end of a line, and goes.
        let unnumbered = ([Row("ing tail")] + rows).map { (row: Row) -> Row in Row(row.text, wrapped: nil) }
        #expect(ScrollbackText.saved(unnumbered, firstRow: nil, extent: .before(start)) == moved)
        // There a command that wrapped is found over its rows, at a blank that ended a row too.
        let long = "% claude --dangerously-skip-permissions --model opus"
        let wrapped = [Row("ing tail", wrapped: nil), Row("% npm test", wrapped: nil), Row("ok", wrapped: nil),
                       Row("% claude --dangerously-skip-permissions", wrapped: nil), Row("--model opus", wrapped: nil),
                       Row("╭──────╮", wrapped: nil)]
        let agent = Echo(row: 3, shown: [long])
        #expect(ScrollbackText.saved(wrapped, firstRow: nil, extent: .before(agent)) == "% npm test\r\nok")
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
        // A PS2 row whose command line scrolled off (the scrollback setting at or below the cap, which then never cuts).
        #expect(ScrollbackText.saved([Row("> -pS3cretTop"), Row("% ls"), Row("a b")], firstRow: 7_000) == "% ls\r\na b")
        #expect(ScrollbackText.saved([Row("dquote> pw\" app"), Row("% ls")], firstRow: 7_000) == "% ls")
        // At the very top of the terminal's history nothing went before it.
        #expect(ScrollbackText.saved([Row("> quoted"), Row("% ls")], firstRow: 0) == "> quoted\r\n% ls")
        // Without wrap flags the first row read may be the end of a wrapped line whether the cap cut or not, and so may
        // the rows after it while each before fills the width.
        let tail = [Row("ijklmnopQRST1234uvwx done", wrapped: nil), Row("% ls", wrapped: nil)]
        #expect(ScrollbackText.saved(tail, firstRow: nil) == "% ls")
        let rest = [Row("abcdef", wrapped: nil, full: true), Row("ghijkl", wrapped: nil, full: true),
                    Row("mn op", wrapped: nil, full: false), Row("% ls", wrapped: nil, full: false)]
        #expect(ScrollbackText.saved(rest, firstRow: nil) == "% ls")
    }

    @Test func aPrivateKeyWhoseStartWasCutIsLeftOut() {
        let body = ["b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW",
                    "QyNTUxOQAAACDk3x9yZ0Abc/Def/GhiJkl/mnoPQRst8uvwxyz0123456789abcAAAAJg",
                    "Users/Code/Sources/abcdEFGH1234ijklMNOP5678qrstUVWX9012yzAB+/CDEF"]
        let rows = [Row("% cat id_ed25519"), Row("-----BEGIN OPENSSH PRIVATE KEY-----")] + body.map { (line: String) -> Row in Row(line) }
            + [Row("-----END OPENSSH PRIVATE KEY-----"), Row("% ls")]
        // Whole, it is masked a line at a time.
        let whole = ScrollbackText.saved(rows)
        #expect(whole.hasPrefix("% cat id_ed25519\r\n"))
        #expect(whole.hasSuffix("\r\n•••\r\n•••\r\n•••\r\n-----END OPENSSH PRIVATE KEY-----\r\n% ls"))
        // Its start cut by the cap, or scrolled off the buffer: alone, a line of its body can read as a path.
        #expect(ScrollbackText.saved(rows, limits: .init(lines: 4, bytes: 1 << 20)) == "% ls")
        #expect(ScrollbackText.saved(Array(rows.dropFirst(2)), firstRow: 7_000) == "% ls")
        let unflagged = rows.dropFirst(2).map { (row: Row) -> Row in Row(row.text, wrapped: nil, full: false) }
        #expect(ScrollbackText.saved(unflagged, firstRow: nil) == "% ls")
        // An END with its BEGIN kept is whole.
        let fromBegin = whole.components(separatedBy: "\r\n").dropFirst().joined(separator: "\r\n")
        #expect(ScrollbackText.saved(rows, limits: .init(lines: 6, bytes: 1 << 20)) == fromBegin)
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
        // The self-test's command over three rows: a name with a secret word holds a secret, while a 24-character value
        // under a plain name holds none (a run is looked at from 32 characters on).
        let pad = String(repeating: "y", count: 196)
        #expect(ScrollbackText.holdsSecret(typed: ": \(pad); export NT_SELFTEST_LONG_TOKEN=Hs3Vd6Kc1Mn8Tb4Xr9Lw2Zq7; echo x"))
        #expect(!ScrollbackText.holdsSecret(typed: ": \(pad); export NT_SELFTEST_LONG=Hs3Vd6Kc1Mn8Tb4Xr9Lw2Zq7; echo x"))
    }

    // MARK: files

    @Test func fileNamesNameTheQuitAndTheScrollback() {
        let quit = UUID(uuidString: "C4D5E6F7-1A2B-4C3D-8E9F-0A1B2C3D4E5F")!
        let id = UUID(uuidString: "9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d")!
        let name = ScrollbackText.fileName(quit: quit, id: id)
        #expect(name == "scrollback-c4d5e6f7-1a2b-4c3d-8e9f-0a1b2c3d4e5f-9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d")
        #expect(ScrollbackText.parseFileName(name)?.quit == quit && ScrollbackText.parseFileName(name)?.id == id)
        for planted in ["scrollback-../state-v1.json", "scrollback-/etc/passwd", name + "/x", name.uppercased(), "../" + name,
                        "scrollback-c4d5e6f7-1a2b-4c3d-8e9f-0a1b2c3d4e5f", name + ".prev"] {
            #expect(ScrollbackText.parseFileName(planted) == nil, "\(planted)")
        }
    }

    @Test func onlyTheRestoredQuitsFilesAreReadAndEveryOneIsRemoved() {
        let marker = UUID(uuidString: "c4d5e6f7-1a2b-4c3d-8e9f-0a1b2c3d4e5f")!
        let launch = UUID(uuidString: "7d6c5b4a-3928-4716-a5b4-c3d2e1f0a9b8")!
        let wanted = UUID(uuidString: "9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d")!
        let unknown = UUID(uuidString: "0f0e0d0c-0b0a-4908-8706-050403020100")!
        // An update quit names its files for its marker, a quit under "Resume where I left off" for its snapshot's
        // launch id.
        let scrollback: [String] = [ScrollbackText.fileName(quit: marker, id: wanted),
                                    ScrollbackText.fileName(quit: marker, id: unknown),
                                    ScrollbackText.fileName(quit: launch, id: wanted), "scrollback-planted"]
        let names: [String] = [SessionSnapshot.fileName()] + scrollback + ["owner.lock"]
        let update = ScrollbackText.sort(names, quit: marker, ids: [wanted])
        #expect(update.read == [wanted: scrollback[0]])
        #expect(update.remove == scrollback)
        let quit = ScrollbackText.sort(names, quit: launch, ids: [wanted])
        #expect(quit.read == [wanted: scrollback[2]])
        #expect(quit.remove == scrollback)
        let unread = ScrollbackText.sort(names, quit: nil, ids: [wanted])
        #expect(unread.read.isEmpty)
        #expect(unread.remove == scrollback)
    }

    // MARK: showing it again

    @Test func thePrefaceShowsTheLinesAboveADimDividerThatSaysWhichQuit() {
        let update = ScrollbackText.SavedAt.update.divider
        let preface = ScrollbackText.preface("old one\r\nold two\u{1B}]52;c;aGk=\u{07}", savedAt: .update)
        #expect(preface == "old one\r\nold two]52;c;aGk=\r\n\u{1B}[2m\(update)\u{1B}[0m\r\n")
        #expect(ScrollbackText.preface("", savedAt: .update) == "\u{1B}[2m\(update)\u{1B}[0m\r\n")
        let fed = preface.replacingOccurrences(of: "\u{1B}[2m", with: "").replacingOccurrences(of: "\u{1B}[0m", with: "")
        #expect(TerminalTextTests.isPrintable(fed.replacingOccurrences(of: "\r\n", with: "\n")))
        // A quit under "Resume where I left off" is no update.
        let quit = ScrollbackText.SavedAt.quit.divider
        #expect(update == "── Restored from before the update ──" && quit == "── Restored from before Next Term quit ──")
        #expect(ScrollbackText.preface("old", savedAt: .quit) == "old\r\n\u{1B}[2m\(quit)\u{1B}[0m\r\n")
    }

    @Test func questionsAreReadOnlyBelowTheDivider() {
        for divider in [ScrollbackText.SavedAt.update.divider, ScrollbackText.SavedAt.quit.divider] {
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
    }

    @Test func theDividerIsFoundAtItsRowSoTheSameTextPrintedBelowItHidesNothing() {
        let divider = ScrollbackText.SavedAt.update.divider
        // Rows 100 to 104: the divider at 101, then a live question, and the same text printed after it.
        let tail = ["old (y/n)", divider, "Do you want to proceed?", "(y/n)", divider]
        #expect(ScrollbackText.below(divider: divider, row: 101, in: tail, first: 100) == Array(tail[2...]))
        // Wrapped over two rows, it is noted at its last.
        let words = divider.split(separator: " ", maxSplits: 2).map(String.init)
        let narrow = ["old (y/n)", words[0] + " " + words[1], words[2], "live", divider]
        #expect(ScrollbackText.below(divider: divider, row: 102, in: narrow, first: 100) == ["live", divider])
        #expect(ScrollbackText.below(divider: divider, row: 100, in: [words[2], "live"], first: 100) == ["live"])
        // Above the tail: all of it is below.
        #expect(ScrollbackText.below(divider: divider, row: 40, in: tail, first: 100) == tail)
        // No longer at its row (the screen was cleared), or not known to be (the width changed since): by its text.
        #expect(ScrollbackText.below(divider: divider, row: 102, in: tail, first: 100).isEmpty)
        #expect(ScrollbackText.below(divider: divider, row: 300, in: ["a", "b"], first: 100) == ["a", "b"])
        #expect(ScrollbackText.below(divider: divider, row: nil, in: tail, first: 100).isEmpty)
    }

    @Test func theNormalBufferReadAsTextHasNoWrapFlags() {
        // The other half of a wide character reads as U+0000 there too: it goes, and other empty cells are blanks.
        let data = Data("日\u{0}本\u{0}x\u{0}\u{0}y\n\nlast\n".utf8)
        let rows = ScrollbackText.rows(bufferData: data, columns: 8)
        #expect(rows.count == 3 && rows.allSatisfy { (row: Row) -> Bool in row.wrapped == nil })
        // Whether each fills the width: a wide character takes two cells.
        #expect(rows.map(\.full) == [true, false, false])
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

    @Test func aScrollbackFullOfWhatLooksLikeSecretsIsSavedInTimeEitherWay() {
        let sample = ["echo a b c d e f g h i j k l m n o p q r s t u v w x y z | grep -v x | sed s/a/b/ | curl -s http://x",
                      "Ab3Cd4Ef5Gh6Ij7Kl8Mn9Op0Qr1St2Uv3Wx4Yz5 sudo -S ls sudo -S ls sudo echo printf echo printf --password",
                      "DB_PASSWORD=hunter2 API_KEY=xyz TOKEN=abc htpasswd -b a b c vault login -method=x a=b c d e f g h i j",
                      String(repeating: "x", count: 100)]
        let clock = ContinuousClock()
        let flagged = (0..<5_000).map { (index: Int) -> Row in Row(sample[index % sample.count]) }
        // In a pool of its own, so the masker's temporary strings go at once: other suites measure the process's memory.
        let normal = clock.measure { autoreleasepool { _ = ScrollbackText.saved(flagged) } }
        // Behind the alternate screen, in a pane 101 wide: rows that fill it go on to the next, so a line of one row
        // alternates with one of three; and the commands that held a secret to find among them.
        let data = Data(flagged.map { (row: Row) -> String in row.text + "\n" }.joined().utf8)
        let rows = ScrollbackText.rows(bufferData: data, columns: 101)
        let dropped = (0..<64).map { (index: Int) -> Echo in Echo(row: index, shown: ["% deploy --token t\(index)"]) }
        let alternate = clock.measure { autoreleasepool { _ = ScrollbackText.saved(rows, firstRow: nil, dropped: dropped) } }
        // About 0.7 s and 2.5 s in a debug build on a recent Mac: behind the alternate screen each row is masked alone
        // and twice more beside its neighbours. Room is left for a slower machine.
        #expect(normal < .seconds(4), "\(normal)")
        #expect(alternate < .seconds(10), "\(alternate)")
    }
}

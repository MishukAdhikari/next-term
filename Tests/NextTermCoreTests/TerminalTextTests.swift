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

    @Test func feedableWritesEachNewlineAsCRLF() {
        #expect(TerminalText.feedable("one\ntwo\n") == "one\r\ntwo\r\n")
        // A carriage return of its own is a control character: it goes, and the newline gets its own.
        #expect(TerminalText.feedable("one\r\ntwo\rthree") == "one\r\ntwothree")
        let fed = TerminalText.feedable(Self.hostile.joined(separator: "\n"))
        let crs = fed.unicodeScalars.filter { $0 == "\r" }.count
        let lfs = fed.unicodeScalars.filter { $0 == "\n" }.count
        #expect(crs == lfs && lfs == Self.hostile.count - 1)
        #expect(Self.isPrintable(fed.replacingOccurrences(of: "\r\n", with: "\n")))
    }
}

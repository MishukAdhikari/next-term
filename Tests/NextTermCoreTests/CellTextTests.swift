import Foundation
import Testing
@testable import NextTermCore

@Suite struct CellTextTests {
    @Test func everyLineBreakIsOneMark() {
        for breaker in ["\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            let line = CellText.line("a" + breaker + "b")
            #expect(line == "a ⏎ b", "\(breaker.unicodeScalars.map { String($0.value, radix: 16) })")
            #expect(line.components(separatedBy: "⏎").count == 2)
        }
        #expect(CellText.line("a\r\nb") == "a ⏎ b")
        #expect(CellText.line("a\n\r\nb") == "a ⏎  ⏎ b")
    }

    @Test func controlsShowAsPictures() {
        #expect(CellText.line("a\tb") == "a⇥b")
        #expect(CellText.line("\u{0}") == "␀")
        #expect(CellText.line("\u{1B}[0m") == "␛[0m")
        #expect(CellText.line("\u{1F}") == "␟")
        #expect(CellText.line("\u{7F}") == "␡")
        #expect(CellText.line("\u{90}") == "\u{FFFD}")
        #expect(CellText.line("\u{9F}x") == "\u{FFFD}x")
    }

    @Test func plainTextIsUnchanged() {
        for text in ["", "hello", "Grace Hopper, “Amazing Grace”", "naïve café", "日本語のテキスト", "👨‍👩‍👧 family", String(repeating: "x", count: 300)] {
            #expect(CellText.line(text) == text)
        }
    }

    /// The SQLite viewer once skipped the line-break rule for text over 300 characters.
    @Test func longTextWithNewlinesIsOneLine() {
        var text = ""
        while text.count < 5000 { text += "A paragraph of a message, with words.\n\nAnother one\r\n" }
        let line = CellText.line(text)
        #expect(line.count == 301 && line.hasSuffix("…"))
        #expect(line.unicodeScalars.allSatisfy { !CharacterSet.newlines.contains($0) && !CharacterSet.controlCharacters.contains($0) })
    }

    @Test func cutAddsOneEllipsis() {
        #expect(CellText.line("short", cut: true) == "short…")
        let long = CellText.line(String(repeating: "a", count: 500), cut: true)
        #expect(long == String(repeating: "a", count: 300) + "…")
        #expect(CellText.line(String(repeating: "a", count: 300), cut: false) == String(repeating: "a", count: 300))
        #expect(CellText.line(String(repeating: "a", count: 301)) == String(repeating: "a", count: 300) + "…")
        #expect(CellText.line("abcdef", limit: 3) == "abc…")
    }

    @Test func charactersAreNotSplitAtTheLimit() {
        let family = "👨‍👩‍👧"
        let emoji = CellText.line(String(repeating: family, count: 400))
        #expect(emoji.hasSuffix("…") && emoji.dropLast().allSatisfy { $0 == Character(family) } && emoji.count == 301)
        let accented = CellText.line(String(repeating: "e\u{301}", count: 400))
        #expect(accented.dropLast().allSatisfy { $0 == "e\u{301}" } && accented.count == 301)
        #expect(accented.unicodeScalars.dropLast().count == 600)
    }

    @Test func aMarkAtTheLimitIsCutWithTheText() {
        let line = CellText.line(String(repeating: "a", count: 299) + "\nmore")
        #expect(line.count == 301 && line.hasPrefix(String(repeating: "a", count: 299) + " ") && line.hasSuffix("…"))
    }
}

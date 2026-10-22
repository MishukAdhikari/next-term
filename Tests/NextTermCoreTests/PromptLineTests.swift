import Foundation
import Testing
@testable import NextTermCore

@Suite struct PromptLineTests {
    private func fed(_ chunks: [UInt8]...) -> PromptLine {
        var line = PromptLine()
        for chunk in chunks { line.feed(chunk[...]) }
        return line
    }

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test func typingAndDeletingCountsCharacters() {
        var line = PromptLine()
        line.feed(bytes("abc")[...])
        #expect(line.hasText)
        let deletes: [UInt8] = [0x7F, 0x7F, 0x7F]
        line.feed(deletes[...])
        #expect(!line.hasText)
        line.feed(bytes("x\r")[...])
        #expect(!line.hasText)
    }

    @Test func ctrlHDeletesAndNeverGoesBelowEmpty() {
        let back: [UInt8] = [0x08, 0x08, 0x7F]
        var line = fed(bytes("a"), back)
        #expect(!line.hasText)
        line.feed(bytes("b")[...])
        #expect(line.hasText)
    }

    @Test func aPasteHoldingAReturnIsText() {
        let start: [UInt8] = [0x1B] + bytes("[200~")
        let end: [UInt8] = [0x1B] + bytes("[201~")
        let line = fed(start, bytes("first\rsecond"), end)
        #expect(line.hasText)
        let afterReturn = fed(start, bytes("one\r"), end, bytes("\r"))
        #expect(!afterReturn.hasText)
    }

    @Test func anEmptyPasteLeavesTheLineEmpty() {
        let paste: [UInt8] = [0x1B] + bytes("[200~") + [0x1B] + bytes("[201~")
        #expect(!fed(paste).hasText)
    }

    @Test func aPasteMarkerSplitAcrossWritesStillCounts() {
        let line = fed([0x1B, 0x5B, 0x32], bytes("00~a\rb"), [0x1B], bytes("[201~"))
        #expect(line.hasText)
    }

    @Test func escapeSequencesCountNothing() {
        let up: [UInt8] = [0x1B] + bytes("[A")
        let f1: [UInt8] = [0x1B] + bytes("OP")
        let modified: [UInt8] = [0x1B] + bytes("[1;5C")
        let lone: [UInt8] = [0x1B]
        #expect(!fed(up, f1, modified, lone).hasText)
        let title: [UInt8] = [0x1B] + bytes("]0;title") + [0x07]
        #expect(!fed(title).hasText)
        let altB: [UInt8] = [0x1B] + bytes("b")
        #expect(!fed(altB).hasText)
    }

    @Test func aLoneEscapeThenTypingCountsTheTyping() {
        let lone: [UInt8] = [0x1B]
        let escapeThenTwo = fed(lone, lone, bytes("[A"), bytes("hi"))
        #expect(escapeThenTwo.hasText)
    }

    @Test func clearingKeysAndResetEmptyTheLine() {
        let ctrlU: [UInt8] = [0x15]
        let ctrlC: [UInt8] = [0x03]
        #expect(!fed(bytes("abc"), ctrlU).hasText)
        #expect(!fed(bytes("abc"), ctrlC).hasText)
        var line = fed(bytes("abc"))
        line.reset()
        #expect(!line.hasText)
    }

    @Test func resetEndsAPasteAndAnEscape() {
        var line = PromptLine()
        let start: [UInt8] = [0x1B] + bytes("[200~")
        line.feed(start[...])
        line.reset()
        line.feed(bytes("\r")[...])
        #expect(!line.hasText)
    }

    @Test func multibyteCharactersCountOnce() {
        let one: [UInt8] = [0x7F]
        #expect(!fed(bytes("é"), one).hasText)
        #expect(!fed(bytes("漢"), one).hasText)
        #expect(fed(bytes("é漢"), one).hasText)
    }

    @Test func otherControlCharactersCountNothing() {
        let controls: [UInt8] = [0x09, 0x0A, 0x01, 0x05]
        #expect(!fed(controls).hasText)
    }

    @Test func aNewlineInsideTheLineDoesNotClearIt() {
        let altReturn: [UInt8] = [0x1B, 0x0D]
        let lineFeed: [UInt8] = [0x0A]
        #expect(fed(bytes("a"), altReturn).hasText)
        #expect(fed(bytes("a"), lineFeed).hasText)
    }
}

import Foundation
import Testing
@testable import NextTermCore

/// Edit › Line in the editor and its whole-line copy, on texts written with the selection in them: "|" is the
/// caret, "[" and "]" go around a selection.
@Suite struct LineEditsTests {
    static func parse(_ marked: String) -> (text: String, selection: NSRange) {
        let units = marked as NSString
        let caret = units.range(of: "|")
        if caret.location != NSNotFound {
            return (units.replacingCharacters(in: caret, with: ""), NSRange(location: caret.location, length: 0))
        }
        let open = units.range(of: "["), close = units.range(of: "]")
        let text = marked.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        return (text, NSRange(location: open.location, length: close.location - open.location - 1))
    }

    static func mark(_ text: String, _ selection: NSRange) -> String {
        let units = NSMutableString(string: text)
        if selection.length == 0 {
            units.insert("|", at: selection.location)
        } else {
            units.insert("]", at: NSMaxRange(selection))
            units.insert("[", at: selection.location)
        }
        return units as String
    }

    /// The marked text after the edit, nil when there is none.
    func edit(_ marked: String, _ make: (NSRange, NSString, LineIndex) -> LineEdits.Edit?) -> String? {
        let (text, selection) = Self.parse(marked)
        guard let edit = make(selection, text as NSString, LineIndex(text)) else { return nil }
        return Self.mark((text as NSString).replacingCharacters(in: edit.range, with: edit.text), edit.selection)
    }

    func duplicate(_ marked: String) -> String? { edit(marked) { LineEdits.duplicate($0, in: $1, $2) } }
    func delete(_ marked: String) -> String? { edit(marked) { LineEdits.delete($0, in: $1, $2) } }
    func up(_ marked: String) -> String? { edit(marked) { LineEdits.move($0, up: true, in: $1, $2) } }
    func down(_ marked: String) -> String? { edit(marked) { LineEdits.move($0, up: false, in: $1, $2) } }

    @Test func theLinesASelectionTouches() {
        func lines(_ marked: String) -> ClosedRange<Int> {
            let (text, selection) = Self.parse(marked)
            return LineEdits.lines(touching: selection, in: LineIndex(text))
        }
        #expect(lines("one\nt|wo\nthree") == 1...1)
        #expect(lines("o[ne\ntw]o\nthree") == 0...1)
        // Ending at the start of a line leaves that line out; its line break belongs to the line before.
        #expect(lines("[one\ntwo\n]three") == 0...1)
        #expect(lines("one\ntwo\n|") == 2...2)
    }

    @Test func duplicateTheLineOrTheSelection() {
        // Nothing selected: the line, below it, and the caret goes with the copy.
        #expect(duplicate("one\nt|wo\nthree") == "one\ntwo\nt|wo\nthree")
        // A selection within a line duplicates after itself, and the copy is selected.
        #expect(duplicate("o[ne]\ntwo") == "one[ne]\ntwo")
        // Over several lines: each line it touches, below them, the selection on the copy.
        #expect(duplicate("o[ne\ntw]o\nthree") == "one\ntwo\no[ne\ntw]o\nthree")
        #expect(duplicate("[one\n]two") == "one\n[one\n]two")
        // The last line, with no line break after it.
        #expect(duplicate("one\ntw|o") == "one\ntwo\ntw|o")
        #expect(duplicate("|") == "\n|")
        // Again and again: each time another copy.
        #expect(duplicate("one\ntwo\nt|wo\nthree").flatMap(duplicate) == "one\ntwo\ntwo\ntwo\nt|wo\nthree")
    }

    @Test func deleteTheLinesTheSelectionTouches() throws {
        // The caret keeps its column on the line that takes their place.
        #expect(delete("one\nt|wo\nthree") == "one\nt|hree")
        #expect(delete("o[ne\ntw]o\nthree") == "t|hree")
        #expect(delete("[one\n]two") == "|two")
        // The last line takes the line break before it, and the caret goes up.
        #expect(delete("one\ntw|o") == "on|e")
        #expect(delete("one\nthree\nt|wo") == "one\nt|hree")
        // A file that ends in a line break keeps it.
        #expect(delete("one\ntw|o\n") == "one\n|")
        // The only line; nothing to delete.
        #expect(delete("on|e") == "|")
        #expect(delete("|") == nil)
    }

    @Test func moveLinesUpAndDown() throws {
        #expect(up("one\nt|wo\nthree") == "t|wo\none\nthree")
        #expect(down("one\nt|wo\nthree") == "one\nthree\nt|wo")
        // The selection goes with the lines, as selected.
        #expect(down("[one\ntwo\n]three\nfour") == "three\n[one\ntwo\n]four")
        #expect(up("zero\n[one\n]two") == "[one\n]zero\ntwo")
        // The last line has no line break after it, wherever it goes.
        #expect(up("one\ntw|o") == "tw|o\none")
        #expect(down("o|ne\ntwo") == "two\no|ne")
        // Moved to the end, a selection that held a line break ends with the line.
        #expect(down("[one\n]two") == "two\n[one]")
        // Nowhere to go at the top and the bottom; the empty line after a final line break stays last.
        #expect(up("o|ne\ntwo") == nil)
        #expect(down("one\nt|wo") == nil)
        #expect(down("one\nt|wo\n") == nil)
        #expect(up("one\ntwo\n|") == nil)
        // There and back is where it started.
        #expect(up("one\nt|wo\nthree").flatMap(down) == "one\nt|wo\nthree")
    }

    @Test func windowsLineEndingsAreEditedAsPlainNewlines() throws {
        // A CRLF file is edited with "\n" and saved with "\r\n" again.
        let (text, format) = try #require(TextFile.decode(Data("one\r\ntwo\r\n".utf8)))
        let index = LineIndex(text)
        let duplicated = LineEdits.duplicate(NSRange(location: 1, length: 0), in: text as NSString, index)
        let moved = try #require(LineEdits.move(NSRange(location: 5, length: 0), up: true, in: text as NSString, index))
        func apply(_ edit: LineEdits.Edit) -> Data { TextFile.encode((text as NSString).replacingCharacters(in: edit.range, with: edit.text), as: format) }
        #expect(apply(duplicated) == Data("one\r\none\r\ntwo\r\n".utf8))
        #expect(apply(moved) == Data("two\r\none\r\n".utf8))
        // Mixed endings stay as they are: a line's "\r" goes with it.
        let mixed = "one\r\ntwo\n"
        let copy = LineEdits.duplicate(NSRange(location: 0, length: 0), in: mixed as NSString, LineIndex(mixed))
        #expect((mixed as NSString).replacingCharacters(in: copy.range, with: copy.text) == "one\r\none\r\ntwo\n")
    }

    @Test func wholeLineCopyAndPaste() {
        func copy(_ marked: String) -> String {
            let (text, selection) = Self.parse(marked)
            return LineEdits.wholeLine(at: selection.location, in: text as NSString, LineIndex(text))
        }
        #expect(copy("one\nt|wo\nthree") == "two\n")
        #expect(copy("one\ntw|o") == "two\n") // a line break added after the last line
        #expect(copy("one\n|\nthree") == "\n")
        // Pasted with nothing selected: above the caret's line, the caret staying where it was.
        #expect(edit("one\nt|wo") { LineEdits.pasteLines("three\n", at: $0.location, $2) } == "one\nthree\nt|wo")
        #expect(edit("one\n|") { LineEdits.pasteLines("two\n", at: $0.location, $2) } == "one\ntwo\n|")
    }

    @Test func pathWithLine() {
        #expect(LineEdits.pathWithLine("/p/src/app.ts", root: "/p", lines: 41...41) == "src/app.ts:42")
        #expect(LineEdits.pathWithLine("/p/src/app.ts", root: "/p/", lines: 41...47) == "src/app.ts:42-48")
        // Outside the project: the whole path.
        #expect(LineEdits.pathWithLine("/other/app.ts", root: "/p", lines: 0...0) == "/other/app.ts:1")
        #expect(LineEdits.pathWithLine("/p2/app.ts", root: "/p", lines: 0...0) == "/p2/app.ts:1")
        #expect(LineEdits.pathWithLine("/p/app.ts", root: nil, lines: 2...3) == "/p/app.ts:3-4")
    }
}

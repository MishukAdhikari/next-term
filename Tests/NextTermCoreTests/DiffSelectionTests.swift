import Foundation
import Testing
@testable import NextTermCore

/// What a diff's selected lines tell an agent: the lines of the file as it is now, or the text of lines it
/// no longer has with a caret where they were, or text alone when no place in the file is true.
@Suite struct DiffSelectionTests {
    /// A 30-line file: line 5 changed, lines 15 and 16 removed, a line added after line 25.
    static let text = """
    diff --git a/app.txt b/app.txt
    index 1111111..2222222 100644
    --- a/app.txt
    +++ b/app.txt
    @@ -2,7 +2,7 @@
     line 2
     line 3
     line 4
    -line 5
    +line five
     line 6
     line 7
     line 8
    @@ -12,8 +12,6 @@
     line 12
     line 13
     line 14
    -line 15
    -line 16
     line 17
     line 18
     line 19
    @@ -23,6 +21,7 @@
     line 23
     line 24
     line 25
    +added after 25
     line 26
     line 27
     line 28

    """
    let file = UnifiedDiff.parse(Self.text)[0]
    var sideBySide: [SideBySideRow] { SideBySide.rows(for: file) }
    var unified: [UnifiedRow] { UnifiedRows.rows(for: file) }

    /// Side by side: the rows of one side whose text reads `texts`, whole lines through their line breaks.
    func pick(_ side: DiffSide, _ texts: [String]) -> [DiffSelectedRow] {
        sideBySide.compactMap { row in
            let line = side == .old ? row.left : row.right
            guard let line, texts.contains(line.text) else { return nil }
            return DiffSelectedRow(line: line, side: side, from: 0, to: nil)
        }
    }

    /// Unified: the rows whose text reads `texts` (a fold or header row is never one of them).
    func pickUnified(_ texts: [String]) -> [DiffSelectedRow] {
        unified.compactMap { row in
            guard let line = row.line, texts.contains(line.text) else { return nil }
            return DiffSelectedRow(line: line, side: row.kind == .removed ? .old : .new, from: 0, to: nil)
        }
    }

    // MARK: rows under a selection

    @Test func spansCoverTheRowsTheSelectionTouches() {
        // "ab\ncd\nef\n": rows at 0, 3, 6.
        let starts = [0, 3, 6]
        #expect(DiffSelections.spans(of: NSRange(location: 1, length: 4), starts: starts, length: 9)
            == [DiffRowSpan(row: 0, from: 1, to: nil), DiffRowSpan(row: 1, from: 0, to: 2)])
        // Through row 1's line break: row 2 is not in it.
        #expect(DiffSelections.spans(of: NSRange(location: 0, length: 6), starts: starts, length: 9)
            == [DiffRowSpan(row: 0, from: 0, to: nil), DiffRowSpan(row: 1, from: 0, to: nil)])
        // Only a line break: the row it ends.
        #expect(DiffSelections.spans(of: NSRange(location: 2, length: 1), starts: starts, length: 9) == [DiffRowSpan(row: 0, from: 2, to: nil)])
        // Within one row.
        #expect(DiffSelections.spans(of: NSRange(location: 7, length: 1), starts: starts, length: 9) == [DiffRowSpan(row: 2, from: 1, to: 2)])
        #expect(DiffSelections.spans(of: NSRange(location: 4, length: 0), starts: starts, length: 9).isEmpty)
        #expect(DiffSelections.spans(of: NSRange(location: 0, length: 3), starts: [], length: 0).isEmpty)
    }

    // MARK: the new side: lines of the file as it is now

    @Test func newSideIsTheFileAtItsLines() throws {
        let selection = try #require(DiffSelections.make(pick(.new, ["line five", "line 6"]), in: file, today: .new))
        #expect(selection.side == .new && selection.isInFile)
        #expect(selection.lines == 5...6)
        #expect(selection.start == DiffPosition(line: 4, character: 0) && selection.end == DiffPosition(line: 6, character: 0))
        #expect(selection.text == "line five\nline 6\n")
        #expect(selection.linesText == "line five\nline 6")
    }

    @Test func partOfALineCountsItsCharactersAsTheEditorDoes() throws {
        var rows = pick(.new, ["line five", "line 6"])
        rows[0].from = 2
        rows[1].to = 4
        let selection = try #require(DiffSelections.make(rows, in: file, today: .new))
        #expect(selection.start == DiffPosition(line: 4, character: 2) && selection.end == DiffPosition(line: 5, character: 4))
        #expect(selection.text == "ne five\nline")
        #expect(selection.linesText == "line five\nline 6")
        // UTF-16, as NSTextView counts, and a carriage return is not text.
        let line = DiffLine(kind: .added, text: "a😀b\r", oldNumber: nil, newNumber: 3)
        let one = try #require(DiffSelections.make([DiffSelectedRow(line: line, side: .new, from: 3, to: nil)], in: file, today: .new))
        #expect(one.start == DiffPosition(line: 2, character: 3) && one.text == "b\n")
    }

    // MARK: the old side: lines the file no longer has

    @Test func removedLinesAreTextWithACaretWhereTheyWere() throws {
        let selection = try #require(DiffSelections.make(pick(.old, ["line 15", "line 16"]), in: file, today: .new))
        #expect(selection.side == .old && !selection.isInFile && selection.changedOnly)
        #expect(selection.text == "line 15\nline 16\n")
        #expect(selection.lines == 15...16) // the old file's, never claimed for the file now
        // They were where line 17 is now: line 15 of the file.
        #expect(selection.start == DiffPosition(line: 14, character: 0) && selection.end == selection.start)
    }

    @Test func aChangedLinesOldTextPointsAtItsReplacement() throws {
        let selection = try #require(DiffSelections.make(pick(.old, ["line 5"]), in: file, today: .new))
        #expect(selection.text == "line 5\n" && !selection.isInFile)
        #expect(selection.start == DiffPosition(line: 4, character: 0) && selection.end == selection.start)
    }

    @Test func unchangedLinesOnTheOldSideAreTheFilesLines() throws {
        // Lines 26 and 27 of the old file are lines 25 and 26 now: the rows line up, as Send to Agent has it.
        let selection = try #require(DiffSelections.make(pick(.old, ["line 26", "line 27"]), in: file, today: .new))
        #expect(selection.side == .new && selection.isInFile && selection.lines == 25...26)
        #expect(selection.start == DiffPosition(line: 24, character: 0) && selection.end == DiffPosition(line: 26, character: 0))
    }

    @Test func oldTextWithUnchangedLinesStartsWhereTheFirstIs() throws {
        let selection = try #require(DiffSelections.make(pick(.old, ["line 14", "line 15"]), in: file, today: .new))
        #expect(!selection.isInFile && !selection.changedOnly && selection.text == "line 14\nline 15\n")
        #expect(selection.start == DiffPosition(line: 13, character: 0) && selection.end == selection.start)
    }

    @Test func aDeletionAtTheEndOfAHunkPointsAfterTheLineBefore() throws {
        let deleted = UnifiedDiff.parse("""
        diff --git a/b.txt b/b.txt
        --- a/b.txt
        +++ b/b.txt
        @@ -5,2 +4,0 @@
        -five
        -six

        """)[0]
        let rows = deleted.hunks[0].lines.map { DiffSelectedRow(line: $0, side: .old, from: 0, to: nil) }
        let selection = try #require(DiffSelections.make(rows, in: deleted, today: .new))
        #expect(selection.start == DiffPosition(line: 4, character: 0) && selection.text == "five\nsix\n")
    }

    // MARK: Unified

    @Test func unifiedSharesTheLinesStillInTheFile() throws {
        // Removed "line 5", added "line five", unchanged "line 6": the file's lines 5–6.
        let mixed = try #require(DiffSelections.make(pickUnified(["line 5", "line five", "line 6"]), in: file, today: .new))
        #expect(mixed.side == .new && mixed.isInFile && mixed.lines == 5...6 && mixed.text == "line five\nline 6\n")
        // Removed lines alone: their text, a caret where they were.
        let removed = try #require(DiffSelections.make(pickUnified(["line 15", "line 16"]), in: file, today: .new))
        #expect(removed.side == .old && !removed.isInFile && removed.start == DiffPosition(line: 14, character: 0))
    }

    // MARK: across hunks and folds

    @Test func acrossHunksTheRangeRunsFromFirstToLastWithAMarkBetween() throws {
        // "line 8" ends change 1, a header row, "line 12" starts change 2.
        var rows = pick(.new, ["line 8", "line 12"])
        rows.insert(DiffSelectedRow(line: nil, side: .new, from: 0, to: nil), at: 1)
        let selection = try #require(DiffSelections.make(rows, in: file, today: .new))
        #expect(selection.lines == 8...12 && selection.isInFile)
        #expect(selection.text == "line 8\n⋯\nline 12\n" && selection.linesText == "line 8\n⋯\nline 12")
        #expect(selection.start == DiffPosition(line: 7, character: 0) && selection.end == DiffPosition(line: 12, character: 0))
        // In Unified, over the fold between them: the same.
        let rows8 = unified.firstIndex { $0.line?.text == "line 8" }, rows12 = unified.firstIndex { $0.line?.text == "line 12" }
        let folded = try #require(rows8.flatMap { from in rows12.map { unified[from...$0] } })
        #expect(folded.contains { $0.fold != nil })
        let pieces = folded.map { DiffSelectedRow(line: $0.line, side: .new, from: 0, to: nil) }
        #expect(DiffSelections.make(Array(pieces), in: file, today: .new)?.lines == 8...12)
    }

    @Test func onlyHeadersAndFillersAreNoSelection() {
        let rows = [DiffSelectedRow(line: nil, side: .new, from: 0, to: nil), DiffSelectedRow(line: nil, side: .old, from: 0, to: nil)]
        #expect(DiffSelections.make(rows, in: file, today: .new) == nil)
        #expect(DiffSelections.make([], in: file, today: .new) == nil)
    }

    // MARK: versions that are not the file now

    @Test func aCommitsVersionIsTextWithNoPlaceInTheFile() throws {
        let selection = try #require(DiffSelections.make(pick(.new, ["line five", "line 6"]), in: file, today: .neither))
        #expect(!selection.isInFile && selection.start == nil && selection.end == nil)
        #expect(selection.lines == 5...6 && selection.text == "line five\nline 6\n")
    }

    @Test func aDeletedFileHasNoPlaceForItsLines() throws {
        let gone = UnifiedDiff.parse("""
        diff --git a/gone.md b/gone.md
        deleted file mode 100644
        --- a/gone.md
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -bye
        -now

        """)[0]
        let rows = gone.hunks[0].lines.map { DiffSelectedRow(line: $0, side: .old, from: 0, to: nil) }
        let selection = try #require(DiffSelections.make(rows, in: gone, today: .new))
        #expect(selection.start == nil && selection.text == "bye\nnow\n" && !selection.isInFile)
    }

    @Test func anAgentsProposalHasTheFileOnItsOldSide() throws {
        // Your file is the old side: its lines are in it; the agent's new line is not, and sits before line 26.
        let yours = try #require(DiffSelections.make(pick(.old, ["line 25", "line 26"]), in: file, today: .old))
        #expect(yours.isInFile && yours.side == .old && yours.lines == 25...26)
        let proposed = try #require(DiffSelections.make(pick(.new, ["added after 25"]), in: file, today: .old))
        #expect(!proposed.isInFile && proposed.start == DiffPosition(line: 25, character: 0) && proposed.end == proposed.start)
        // Unchanged lines picked on the new side are the file's, at its own numbers.
        let same = try #require(DiffSelections.make(pick(.new, ["line 26"]), in: file, today: .old))
        #expect(same.isInFile && same.lines == 26...26)
    }
}

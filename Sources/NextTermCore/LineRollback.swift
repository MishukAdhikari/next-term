import Foundation

/// Rollback Lines (⌥⌘Z in the editor, with the caret or a selection on changed lines): the changes the selection
/// touches put back as the last commit has them, as one edit of the text being edited, so ⌘Z undoes it. The changes
/// are the gutter's: a diff of the committed text and the text as it is now, with no lines of context.
public enum LineRollback {
    /// The changes of `diff` that the 0-based lines `lines` touch: a change or an addition when one of its lines is
    /// among them, a deletion (a mark between two lines) when the line above or below the mark is.
    public static func touched(_ diff: FileDiff, lines: ClosedRange<Int>) -> [DiffHunk] {
        diff.hunks.filter { hunk in
            let from = newFrom(hunk)
            if hunk.newCount > 0 { return lines.overlaps(from...(from + hunk.newCount - 1)) }
            return lines.contains(from - 1) || lines.contains(from)
        }
    }

    /// The edit that puts `hunks` back: from the start of the first line they change to the end of the last, the
    /// lines between rebuilt with the committed lines in place of the changed ones, then those lines selected. Nil
    /// when there is nothing to change. `current` and `baseline` as the editor holds them (LF line ends).
    public static func edit(_ hunks: [DiffHunk], current: String, baseline: String) -> LineEdits.Edit? {
        let now = lines(of: current), was = lines(of: baseline)
        let sorted = hunks.sorted { newFrom($0) < newFrom($1) }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let start = newFrom(first), end = newFrom(last) + last.newCount
        guard end <= now.count else { return nil }
        var rebuilt = "", cursor = start
        for hunk in sorted {
            let from = newFrom(hunk), oldFrom = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1
            guard from >= cursor, oldFrom + hunk.oldCount <= was.count else { return nil }
            rebuilt += now[cursor..<from].joined() + was[oldFrom..<(oldFrom + hunk.oldCount)].joined()
            cursor = from + hunk.newCount
        }
        rebuilt += now[cursor..<end].joined()
        let location = now[..<start].reduce(0) { $0 + $1.utf16.count }
        let length = now[start..<end].reduce(0) { $0 + $1.utf16.count }
        guard rebuilt != now[start..<end].joined() else { return nil }
        let shown = (rebuilt as NSString).length - (rebuilt.hasSuffix("\n") ? 1 : 0)
        return LineEdits.Edit(range: NSRange(location: location, length: length), text: rebuilt,
                              selection: NSRange(location: location, length: max(0, shown)))
    }

    /// How many lines the edit puts back, as the notice counts them: each change's lines on the larger side.
    public static func lineCount(_ hunks: [DiffHunk]) -> Int {
        hunks.reduce(0) { $0 + max($1.oldCount, $1.newCount) }
    }

    /// Where a hunk's lines are in the text now (0-based); for a deletion, the line just below its mark.
    static func newFrom(_ hunk: DiffHunk) -> Int { hunk.newCount == 0 ? hunk.newStart : hunk.newStart - 1 }

    /// Each line with its "\n" (the last one may have none), split as git splits them: at every "\n", whatever is
    /// before it ("\r\n" is one Character to Swift, two bytes to git).
    static func lines(of text: String) -> [String] {
        var result: [String] = [], line = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            line.append(scalar)
            if scalar == "\n" {
                result.append(String(line))
                line = String.UnicodeScalarView()
            }
        }
        if !line.isEmpty { result.append(String(line)) }
        return result
    }
}

import Foundation

// Lines selected in a diff, as an agent connected to Next Term is told about them (Claude Code's
// selection_changed, Gemini CLI's and Qwen Code's open files, Copilot CLI's selection) and as Send to Agent
// types them: like an editor's selection when the lines are in the file as it is now, at their real line
// numbers; otherwise their text, with a caret where they were in the file, or with no place at all when
// nothing in the file now is where they are (a commit's version, a deleted file).

/// The two versions a diff compares: the old one (its removed lines) and the new one (its added lines).
/// Unchanged lines are in both.
public enum DiffSide: Sendable, Equatable { case old, new }

/// Which version of a diff is the file as it is now: the new one for the working tree's changes (against
/// HEAD, the index or another commit), the old one for an agent's proposal (your file against its
/// version), neither for a commit's, a branch's or the index's own version, or a file that is gone.
public enum DiffToday: Sendable, Equatable { case new, old, neither }

/// What a selection covers of one row of a diff view.
public struct DiffSelectedRow: Equatable, Sendable {
    /// The row's line: nil for a hunk's header, a filler across from the other side's line, or a fold.
    public var line: DiffLine?
    /// The version the row's text is from.
    public var side: DiffSide
    /// Where the selection starts in the row's text (UTF-16, carriage returns left out): 0 when it starts
    /// on an earlier row.
    public var from: Int
    /// Where it ends; nil when it runs on past the row's end, its line break with it.
    public var to: Int?

    public init(line: DiffLine?, side: DiffSide, from: Int, to: Int?) {
        self.line = line
        self.side = side
        self.from = from
        self.to = to
    }
}

/// A row a selection touches, by its index, with where the selection starts and ends in it.
public struct DiffRowSpan: Equatable, Sendable {
    public let row: Int
    public let from: Int
    /// Nil: through the row's end and its line break.
    public let to: Int?

    public init(row: Int, from: Int, to: Int?) {
        self.row = row
        self.from = from
        self.to = to
    }
}

/// A place in a file as an editor's selection gives it: 0-based line, UTF-16 character in the line.
public struct DiffPosition: Equatable, Sendable {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

/// A diff's selection, ready to tell an agent about.
public struct DiffSelection: Equatable, Sendable {
    /// The version the shared lines are from: one side, even when the selection crossed both (Unified).
    public let side: DiffSide
    /// The text as selected, a "⋯" line where lines between are not shown (another hunk, a fold), a line
    /// break at the end when the selection ran through the last line's.
    public let text: String
    /// The same lines whole, without the line break at the end: what Send to Agent pastes as code.
    public let linesText: String
    /// First to last line: in the file as it is now when `isInFile`, else in `side`'s version.
    public let lines: ClosedRange<Int>
    /// Every line shared is in the file as it is now, at `lines`.
    public let isInFile: Bool
    /// Every line shared is one the diff changed (removed on the old side, added on the new).
    public let changedOnly: Bool
    /// The selection in the file as it is now, as an editor's: from `start` to `end` when `isInFile`; a
    /// caret where the lines were (start == end) when the file no longer has them; nil when no place in it
    /// is true.
    public let start: DiffPosition?
    public let end: DiffPosition?
}

public enum DiffSelections {
    /// The rows `range` touches, in a text of rows that start at `starts` (each ends in a line break) and is
    /// `length` long. A selection ending at the start of a row does not touch that row.
    public static func spans(of range: NSRange, starts: [Int], length: Int) -> [DiffRowSpan] {
        guard range.length > 0, !starts.isEmpty else { return [] }
        func row(at offset: Int) -> Int {
            var low = 0, high = starts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if starts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return low
        }
        let end = NSMaxRange(range)
        let first = row(at: range.location), last = row(at: max(range.location, end - 1))
        return (first...max(first, last)).map { index in
            let start = starts[index]
            let next = index + 1 < starts.count ? starts[index + 1] : length
            let textLength = max(0, next - start - 1)
            let from = index == first ? min(textLength, max(0, range.location - start)) : 0
            let to: Int? = end - start <= textLength ? end - start : nil
            return DiffRowSpan(row: index, from: from, to: to)
        }
    }

    /// What `rows` (in order, as the view shows them) select in `file`'s diff, with `today` the version that
    /// is the file as it is now. Nil when no row holds a line.
    ///
    /// Rows from both versions (Unified, removed lines among the others) share those of the version that is
    /// the file now (the new one when neither is), as Send to Agent does. Unchanged lines alone are in both
    /// versions: they are shared as that version's.
    public static func make(_ rows: [DiffSelectedRow], in file: FileDiff, today: DiffToday) -> DiffSelection? {
        var pieces = rows.filter { $0.line != nil }
        guard !pieces.isEmpty else { return nil }
        // A file that is gone has no place for any line, nor a proposal of a file that isn't there yet.
        let today: DiffToday = (today == .new && file.isDeleted) || (today == .old && file.isNew) ? .neither : today
        let preferred: DiffSide = today == .old ? .old : .new
        let unchanged = { (piece: DiffSelectedRow) in piece.line?.kind == .context }
        if Set(pieces.map { $0.side == .old }).count > 1 {
            pieces = pieces.filter { $0.side == preferred || unchanged($0) }
        }
        if pieces.allSatisfy(unchanged) || pieces.contains(where: { $0.side == preferred }) {
            pieces = pieces.map { DiffSelectedRow(line: $0.line, side: preferred, from: $0.from, to: $0.to) }
        }
        guard let side = pieces.first?.side, let firstPiece = pieces.first, let lastPiece = pieces.last else { return nil }

        func own(_ line: DiffLine) -> Int? { side == .old ? line.oldNumber : line.newNumber }
        /// The line's number in the file as it is now, if it is in it.
        func now(_ line: DiffLine) -> Int? {
            switch today {
            case .neither: return nil
            case .new: return side == .new || line.kind == .context ? line.newNumber : nil
            case .old: return side == .old || line.kind == .context ? line.oldNumber : nil
            }
        }
        let numbers = pieces.compactMap { $0.line.flatMap(now) }
        let inFile = numbers.count == pieces.count
        let shown = inFile ? numbers : pieces.compactMap { $0.line.flatMap(own) }
        guard let first = shown.first, let last = shown.last else { return nil }

        var text: [String] = [], whole: [String] = []
        var previous: Int?
        for (piece, number) in zip(pieces, shown) {
            guard let line = piece.line else { continue }
            if let previous, number != previous + 1 {
                text.append("⋯")
                whole.append("⋯")
            }
            previous = number
            let clean = line.text.replacingOccurrences(of: "\r", with: "") as NSString
            let from = min(piece.from, clean.length), to = max(from, min(piece.to ?? clean.length, clean.length))
            text.append(clean.substring(with: NSRange(location: from, length: to - from)))
            whole.append(clean as String)
        }
        let through = lastPiece.to == nil
        var start: DiffPosition?, end: DiffPosition?
        if inFile {
            start = DiffPosition(line: first - 1, character: firstPiece.from)
            end = lastPiece.to.map { DiffPosition(line: last - 1, character: $0) } ?? DiffPosition(line: last, character: 0)
        } else if let line = firstPiece.line, let place = now(line) ?? anchors(of: file, today: today)[own(line) ?? -1] {
            start = DiffPosition(line: place - 1, character: 0)
            end = start
        }
        return DiffSelection(side: side, text: text.joined(separator: "\n") + (through ? "\n" : ""), linesText: whole.joined(separator: "\n"),
                             lines: min(first, last)...max(first, last), isInFile: inFile,
                             changedOnly: !pieces.contains(where: unchanged), start: start, end: end)
    }

    /// Where each line the file as it is now doesn't have was in it (1-based: the line now in its place, or
    /// one past the last), by the line's number in its own version: the removed lines when the new version is
    /// the file, a proposal's added lines when the old one is.
    static func anchors(of file: FileDiff, today: DiffToday) -> [Int: Int] {
        guard today != .neither else { return [:] }
        var anchors: [Int: Int] = [:]
        for hunk in file.hunks {
            // Lines of the file now before the hunk: an empty side's start is the line before it.
            var before = today == .new ? (hunk.newCount == 0 ? hunk.newStart : hunk.newStart - 1)
                : (hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1)
            for line in hunk.lines {
                switch (line.kind, today) {
                case (.context, _), (.added, .new), (.removed, .old):
                    before += 1
                case (.removed, _):
                    if let number = line.oldNumber { anchors[number] = before + 1 }
                case (.added, _):
                    if let number = line.newNumber { anchors[number] = before + 1 }
                }
            }
        }
        return anchors
    }
}

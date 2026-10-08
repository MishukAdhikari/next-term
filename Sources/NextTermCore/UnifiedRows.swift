import Foundation

// A diff top to bottom, the way the Unified view and the Git Diff tab's All files page show it: removed
// lines, then the lines that replace them, unchanged ones between, and long unchanged runs folded into
// "N unmodified lines" rows that open when clicked. The rows come from a diff with three lines of context
// (the one hunk actions work on); the lines a fold hides come from the same diff with the whole file as
// context, read when they are first wanted.

/// Unchanged lines a row stands for until it is opened.
public struct UnifiedFold: Equatable, Hashable, Sendable {
    /// Where the hidden lines start in the old file (the fold's key: it stays when the diff is read again)
    /// and in the new one.
    public let oldStart: Int
    public let newStart: Int
    /// How many lines it hides; nil when that isn't known yet: the rest of the file, after the last change.
    public let count: Int?

    public init(oldStart: Int, newStart: Int, count: Int?) {
        self.oldStart = oldStart
        self.newStart = newStart
        self.count = count
    }

    /// "67 unmodified lines", "1 unmodified line", "Show more lines".
    public var title: String {
        guard let count else { return "Show more lines" }
        return count == 1 ? "1 unmodified line" : "\(count.formatted()) unmodified lines"
    }
}

/// One row of a unified diff.
public struct UnifiedRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, removed, added, fold }
    public let kind: Kind
    /// Nil for a fold.
    public let line: DiffLine?
    /// The words that changed within the line, as UTF-16 ranges (a removed line paired with the added one
    /// that replaces it, as side by side).
    public let changes: [NSRange]
    /// The hunk of the diff the row is in: what Stage, Unstage and Revert act on. Nil for a fold, and for
    /// lines a fold showed (they are in no hunk).
    public let hunk: Int?
    public let fold: UnifiedFold?

    public init(kind: Kind, line: DiffLine?, changes: [NSRange] = [], hunk: Int? = nil, fold: UnifiedFold? = nil) {
        self.kind = kind
        self.line = line
        self.changes = changes
        self.hunk = hunk
        self.fold = fold
    }

    /// The line number shown: the old file's for a removed line, the new one's for the others.
    public var number: Int? { kind == .removed ? line?.oldNumber : line?.newNumber }
    /// "−" for a removed line, "+" for an added one.
    public var marker: String {
        switch kind {
        case .removed: return "−"
        case .added: return "+"
        case .context, .fold: return ""
        }
    }
}

public enum UnifiedRows {
    /// Lines of context around each change, as git shows by default.
    public static let context = 3
    /// Lines of context that make a diff the whole file.
    public static let wholeFile = 1_000_000
    /// Fewer unchanged lines than this between changes are shown, not folded, once they are known.
    public static let minimumFold = 4

    /// `file`'s rows. `fill` holds the file's unchanged lines by their old line number (from `fill(from:)`):
    /// with it, short runs show as lines and `expanded` folds (by `oldStart`) open; without, every run
    /// the diff leaves out is a fold.
    public static func rows(for file: FileDiff, expanded: Set<Int> = [], fill: [Int: DiffLine]? = nil) -> [UnifiedRow] {
        var rows: [UnifiedRow] = []
        func gap(oldStart: Int, newStart: Int, count: Int?) {
            guard let fill else {
                if (count ?? 1) > 0 { rows.append(UnifiedRow(kind: .fold, line: nil, fold: UnifiedFold(oldStart: oldStart, newStart: newStart, count: count))) }
                return
            }
            let known: [DiffLine]
            if let count {
                known = (0..<max(0, count)).compactMap { fill[oldStart + $0] }
            } else {
                known = fill.keys.filter { $0 >= oldStart }.sorted().compactMap { fill[$0] }
            }
            let total = count ?? known.count
            guard total > 0 else { return }
            if known.count == total, total < minimumFold || expanded.contains(oldStart) {
                rows += known.map { UnifiedRow(kind: .context, line: $0) }
            } else {
                rows.append(UnifiedRow(kind: .fold, line: nil, fold: UnifiedFold(oldStart: oldStart, newStart: newStart, count: total)))
            }
        }
        var nextOld = 1, nextNew = 1
        for (index, hunk) in file.hunks.enumerated() {
            // An empty side's start is the line before ("@@ -5,0 +6,2 @@" adds after line 5).
            let firstOld = hunk.oldCount == 0 ? hunk.oldStart + 1 : hunk.oldStart
            let firstNew = hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart
            if firstOld > nextOld { gap(oldStart: nextOld, newStart: nextNew, count: firstOld - nextOld) }
            rows += self.rows(of: hunk, index: index)
            nextOld = firstOld + hunk.oldCount
            nextNew = firstNew + hunk.newCount
        }
        // After the last change: the rest of the file, if there may be more (a hunk that ends on its full
        // context, not at the end of the file). A new or deleted file is all in its hunk.
        guard let last = file.hunks.last, !file.isNew, !file.isDeleted else { return rows }
        let trailing = last.lines.reversed().prefix(while: { $0.kind == .context }).count
        let atEnd = last.oldMissingNewline || last.newMissingNewline || trailing < context
        if fill != nil || !atEnd { gap(oldStart: nextOld, newStart: nextNew, count: nil) }
        return rows
    }

    /// A hunk's lines: each run of removed lines, then the added lines after it, with the changed words
    /// of each pair marked.
    static func rows(of hunk: DiffHunk, index: Int) -> [UnifiedRow] {
        var rows: [UnifiedRow] = []
        var removed: [DiffLine] = [], added: [DiffLine] = []
        func flush() {
            var old = [[NSRange]](repeating: [], count: removed.count), new = [[NSRange]](repeating: [], count: added.count)
            for i in 0..<min(removed.count, added.count) {
                let pair = WordDiff.changes(old: removed[i].text, new: added[i].text)
                old[i] = pair.old
                new[i] = pair.new
            }
            rows += removed.indices.map { UnifiedRow(kind: .removed, line: removed[$0], changes: old[$0], hunk: index) }
            rows += added.indices.map { UnifiedRow(kind: .added, line: added[$0], changes: new[$0], hunk: index) }
            removed = []
            added = []
        }
        for line in hunk.lines {
            switch line.kind {
            case .removed:
                if !added.isEmpty { flush() }
                removed.append(line)
            case .added:
                added.append(line)
            case .context:
                flush()
                rows.append(UnifiedRow(kind: .context, line: line, hunk: index))
            }
        }
        flush()
        return rows
    }

    /// The unchanged lines of a diff made with the whole file as context, by their line in the old file:
    /// what folds show when they open.
    public static func fill(from whole: FileDiff) -> [Int: DiffLine] {
        var lines: [Int: DiffLine] = [:]
        for hunk in whole.hunks {
            for line in hunk.lines where line.kind == .context {
                if let number = line.oldNumber { lines[number] = line }
            }
        }
        return lines
    }

    /// Whether the whole file read along with `source` fills `file`'s folds: the same old file and the same
    /// hunks make the same new file. Anything else (a hunk reverted, an agent's edit undone, another base)
    /// may have changed lines between the hunks, which no hunk shows.
    public static func fill(of source: FileDiff?, fits file: FileDiff) -> Bool {
        guard let source, let blob = source.oldBlob else { return false }
        return blob == file.oldBlob && source.hunks == file.hunks
    }

    /// A file git doesn't track yet, as a diff that adds every line; one with no lines for an empty file,
    /// and a binary one when the first 8000 bytes hold a NUL. A line that isn't UTF-8 reads as Latin-1, as
    /// in git's diffs.
    public static func addedFile(path: String, data: Data) -> FileDiff {
        var file = FileDiff()
        file.oldPath = nil
        file.newPath = path
        guard !data.prefix(8000).contains(0) else {
            file.isBinary = true
            return file
        }
        let text = GitRunner.diffText(data)
        guard !text.isEmpty else { return file }
        // By the "\n" scalar: "\r\n" stays a line with its "\r", as git keeps it.
        var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
        let endsInNewline = text.unicodeScalars.last == "\n"
        if endsInNewline { lines.removeLast() }
        var hunk = DiffHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: lines.count, section: "", lines: [])
        hunk.lines = lines.enumerated().map { DiffLine(kind: .added, text: $1, oldNumber: nil, newNumber: $0 + 1) }
        hunk.newMissingNewline = !endsInNewline
        file.hunks = [hunk]
        return file
    }
}

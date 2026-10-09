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
        guard let touched = rows(of: range, starts: starts) else { return [] }
        let end = NSMaxRange(range), first = touched.lowerBound
        return touched.map { index in
            let start = starts[index]
            let next = index + 1 < starts.count ? starts[index + 1] : length
            let textLength = max(0, next - start - 1)
            let from = index == first ? min(textLength, max(0, range.location - start)) : 0
            let to: Int? = end - start <= textLength ? end - start : nil
            return DiffRowSpan(row: index, from: from, to: to)
        }
    }

    /// The first to the last row `range` touches (by binary search: a view asks often); nil for no selection.
    public static func rows(of range: NSRange, starts: [Int]) -> ClosedRange<Int>? {
        guard range.length > 0, !starts.isEmpty else { return nil }
        func row(at offset: Int) -> Int {
            var low = 0, high = starts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if starts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return low
        }
        let first = row(at: range.location), last = row(at: max(range.location, NSMaxRange(range) - 1))
        return first...max(first, last)
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

/// Lines selected in one file's diff, with what is known of the file: what the editor link tells the agents in
/// the window of them (Claude Code's and opencode's selection_changed, Gemini CLI's and Qwen Code's open files,
/// Copilot CLI's selection) and what Send to Agent types for them. The app speaks each agent's protocol.
public struct DiffShare: Equatable, Sendable {
    /// What the diff compares the lines with, for what Send to Agent says about them.
    public enum Version: Equatable, Sendable {
        /// The working tree against HEAD, the index or a commit: the new side is the file on disk.
        case workingTree
        case staged
        case commit(String)
        case branch(String)
        case proposal
    }

    /// What the editor link says is selected: the file, the text, and where it is in the file now (a caret
    /// where it was when the file no longer has it; none when no place in the file is true).
    public struct Linked: Equatable, Sendable {
        public let path: String
        public let text: String
        public let start: DiffPosition?
        public let end: DiffPosition?

        public init(path: String, text: String, start: DiffPosition?, end: DiffPosition?) {
            self.path = path
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// The file in the working tree.
    public let path: String
    public let selection: DiffSelection
    /// The file tends to hold secrets (.env, keys), by its name, its link's or its old name: the link shares it
    /// as no file, as it shares such a file open in the editor.
    public let holdsSecrets: Bool
    /// The lines are changes not committed yet (the working tree's or the index's).
    public let isUncommitted: Bool
    public let version: Version
    /// The code fence's language.
    public let language: String

    public init(path: String, selection: DiffSelection, holdsSecrets: Bool, isUncommitted: Bool, version: Version, language: String) {
        self.path = path
        self.selection = selection
        self.holdsSecrets = holdsSecrets
        self.isUncommitted = isUncommitted
        self.version = version
        self.language = language
    }

    /// Whether any of a diff's names for its file (its path, a link's target, the name it had before a rename)
    /// is one that holds secrets.
    public static func holdsSecrets(_ paths: [String?]) -> Bool {
        paths.compactMap { $0 }.contains { IDELink.isSensitive($0) || IDELink.isSensitive(canonicalPath($0)) }
    }

    /// What the editor link is told: nil for a file that holds secrets, which is no file at all to it.
    public var linked: Linked? {
        guard !holdsSecrets else { return nil }
        return Linked(path: path, text: selection.text, start: selection.start, end: selection.end)
    }

    /// Whether the diff's toolbar offers "⌥⌘K Ask <Agent>" for what is selected: lines of changes not committed
    /// yet, in a file that may be shared. It never invites typing a secret file's lines into a prompt; ⌥⌘K,
    /// asked for, types them as it types an editor's selection.
    public static func offersAsk(hasLines: Bool, isUncommitted: Bool, holdsSecrets: @autoclosure () -> Bool) -> Bool {
        hasLines && isUncommitted && !holdsSecrets() // the names looked at last: asked as a selection is dragged
    }

    /// Send to Agent: the file at the lines selected, as `@path#L2-3`, when they are its lines on disk; a
    /// staged, committed or branch version's lines go along as code, said to be that; the old side's text,
    /// which the file no longer has, goes as code with the file's path and no lines. Nil for an agent's
    /// proposal (that agent waits for your answer in its terminal) and for old text too long to type.
    public func contextItem(exists: Bool) -> ContextItem? {
        guard version != .proposal else { return nil }
        var item = ContextItem(path: path)
        let code = selection.linesText
        if selection.side == .old {
            guard !code.isEmpty, !AgentPrompt.isTooLargeToInline(code) else { return nil }
            item.code = code
            item.language = language
            item.note = oldNote(exists: exists)
            return item
        }
        item.lines = selection.lines
        switch version {
        case let .commit(sha): item.note = "as of commit \(sha.prefix(7))"
        case let .branch(name): item.note = "as on \(name)"
        case .staged: item.note = "as staged"
        case .workingTree, .proposal: item.note = exists ? nil : "deleted"
        }
        if !selection.isInFile, !AgentPrompt.isTooLargeToInline(code) {
            item.code = code
            item.language = language
        }
        return item
    }

    /// What the old side's lines are: removed (in a commit, on a branch), or the version before the change
    /// when unchanged lines are among them.
    private func oldNote(exists: Bool) -> String {
        let removed = selection.changedOnly
        switch version {
        case let .commit(sha): return removed ? "lines removed in commit \(sha.prefix(7))" : "before commit \(sha.prefix(7))"
        case let .branch(name): return removed ? "lines removed on \(name)" : "before \(name) changed it"
        case .workingTree, .staged, .proposal: return exists ? (removed ? "lines removed" : "before the change") : "deleted"
        }
    }
}

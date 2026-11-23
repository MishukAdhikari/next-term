import Foundation

/// A note on lines of a diff, kept for a review the agent gets as one prompt (plan 039 U3): the file, its lines,
/// their text when the comment was made, and what to do about them.
public struct ReviewComment: Equatable, Sendable, Identifiable {
    public let id: UUID
    /// The file in the working tree, absolute.
    public var path: String
    /// The lines in the file now when `inFile`; else where they were in their own version.
    public var lines: ClosedRange<Int>
    /// The lines' text as selected, a "⋯" line where lines between were not shown.
    public var quoted: String
    public var note: String
    /// The code fence's language.
    public var language: String
    /// The lines are in the file on disk (the new side), so they are looked for again when it changes; removed
    /// lines are kept as text.
    public var inFile: Bool
    /// The file no longer has the lines as they were: the comment stays, said to be outdated.
    public var outdated = false

    public init(id: UUID = UUID(), path: String, lines: ClosedRange<Int>, quoted: String, note: String,
                language: String = "text", inFile: Bool) {
        self.id = id
        self.path = path
        self.lines = lines
        self.quoted = quoted
        self.note = note
        self.language = language
        self.inFile = inFile
    }

    /// A comment on what `share` selects, nil for an empty note.
    public init?(share: DiffShare, note: String) {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return nil }
        let selection = share.selection
        self.init(path: share.path, lines: selection.lines, quoted: selection.linesText, note: note,
                  language: share.language, inFile: selection.isInFile && selection.side == .new)
    }
}

public enum ReviewComments {
    /// `comment` against the file's lines now (nil: the file is gone): where its first shown lines are now, the
    /// nearest place to where they were, or outdated where they were when the file no longer has them. Removed
    /// lines are left as they are.
    public static func reanchor(_ comment: ReviewComment, fileLines: [String]?) -> ReviewComment {
        guard comment.inFile else { return comment }
        var comment = comment
        let quoted = comment.quoted.components(separatedBy: "\n")
        let block = Array(quoted.prefix { $0 != "⋯" })
        guard let fileLines, !block.isEmpty, block.count <= fileLines.count else {
            comment.outdated = true
            return comment
        }
        let was = comment.lines.lowerBound - 1
        var best: Int?
        for start in 0...(fileLines.count - block.count) where fileLines[start] == block[0] {
            guard Array(fileLines[start..<(start + block.count)]) == block else { continue }
            if best.map({ abs(start - was) < abs($0 - was) }) ?? true { best = start }
        }
        guard let best else {
            comment.outdated = true
            return comment
        }
        let shift = best - was
        comment.lines = (comment.lines.lowerBound + shift)...(comment.lines.upperBound + shift)
        comment.outdated = false
        return comment
    }

    /// A file's lines as `reanchor` compares them: split at line breaks, carriage returns left out.
    public static func lines(of text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The prompt for `comments`: a line saying what they are, then each one's place (relative to `base`, the
    /// agent's folder), its lines in a fence, and its note. Typed as one bracketed paste, so it is sanitized.
    public static func prompt(_ comments: [ReviewComment], relativeTo base: String) -> String {
        var parts = [comments.count == 1 ? "Review comment on your changes:" : "Review comments on your changes:"]
        for (index, comment) in comments.enumerated() {
            var path = comment.path
            if path == base { path = "." } else if path.hasPrefix(base + "/") { path = String(path.dropFirst(base.count + 1)) }
            let span = comment.lines.count == 1 ? "\(comment.lines.lowerBound)" : "\(comment.lines.lowerBound)-\(comment.lines.upperBound)"
            var place = comment.inFile ? "\(path):\(span)" : "\(path), removed lines (were \(span))"
            if comment.outdated { place += " (outdated: these lines have changed since)" }
            var fence = "```"
            while comment.quoted.contains(fence) { fence += "`" }
            parts.append("\(index + 1). \(place)\n\(fence)\(comment.language)\n\(comment.quoted)\n\(fence)\n\(comment.note)")
        }
        return AgentPrompt.sanitize(parts.joined(separator: "\n\n"))
    }

    /// What a diff of `path` shows for the comments: the lines marked on each side (the file's lines now for comments
    /// on it, removed lines by their old numbers) and each comment's note, in one line, after its last line. Outdated
    /// comments show nothing: their lines are not where they were.
    public struct Marks: Equatable, Sendable {
        public var new: Set<Int> = []
        public var old: Set<Int> = []
        /// The note shown after a line, by its number on that side; two comments ending on one line share it.
        public var newNotes: [Int: String] = [:]
        public var oldNotes: [Int: String] = [:]

        public init() {}

        public var isEmpty: Bool { new.isEmpty && old.isEmpty }
    }

    public static func marks(_ comments: [ReviewComment], path: String) -> Marks {
        var marks = Marks()
        for comment in comments where comment.path == path && !comment.outdated {
            let lines: [Int] = Array(comment.lines)
            let note: String = inline(comment.note)
            if comment.inFile {
                marks.new.formUnion(lines)
                if !note.isEmpty { marks.newNotes[comment.lines.upperBound] = marks.newNotes[comment.lines.upperBound].map { $0 + "  ·  " + note } ?? note }
            } else {
                marks.old.formUnion(lines)
                if !note.isEmpty { marks.oldNotes[comment.lines.upperBound] = marks.oldNotes[comment.lines.upperBound].map { $0 + "  ·  " + note } ?? note }
            }
        }
        return marks
    }

    /// A note as one line beside the code: its first line with text, cut at `limit` characters, "…" when more follows.
    public static func inline(_ note: String, limit: Int = 100) -> String {
        let lines: [String] = note.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return "" }
        let cut: String = first.count > limit ? String(first.prefix(limit)) : first
        return cut + (cut.count < first.count || lines.count > 1 ? "…" : "")
    }
}

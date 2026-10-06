import Foundation

/// One line of a unified diff hunk.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, added, removed }
    public let kind: Kind
    public let text: String
    /// 1-based line numbers in the old and new file (nil on the side the line does not exist).
    public let oldNumber: Int?
    public let newNumber: Int?
}

public struct DiffHunk: Equatable, Sendable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// Text after the @@ … @@ (often the enclosing function).
    public let section: String
    public internal(set) var lines: [DiffLine]
    /// "\ No newline at end of file" applied to the old or new side of this hunk.
    public internal(set) var oldMissingNewline = false
    public internal(set) var newMissingNewline = false

    public var added: Int { lines.filter { $0.kind == .added }.count }
    public var removed: Int { lines.filter { $0.kind == .removed }.count }
}

public struct FileDiff: Equatable, Sendable {
    public var oldPath: String?
    public var newPath: String?
    public var isBinary = false
    public var hunks: [DiffHunk] = []
    /// Full blob ids from the "index <old>..<new>" header line (with --full-index); all zeros for "none".
    public var oldBlob: String?
    public var newBlob: String?
    /// The header lines ("diff --git …", "index …", "--- a/…", "+++ b/…"), kept to rebuild patches.
    public var header: [String] = []

    public var isNew: Bool { oldPath == nil }
    public var isDeleted: Bool { newPath == nil }
    public var isRename: Bool { oldPath != nil && newPath != nil && oldPath != newPath }
    public var path: String { newPath ?? oldPath ?? "" }
}

public enum UnifiedDiff {
    /// Parses `git diff` output (one or more files). Each file is a header (from "diff --git" to the
    /// first "@@"), then hunks whose lines start with " ", "+", "-" or "\\". Line content is kept
    /// exactly, including a trailing "\r" from CRLF files, so patches rebuilt from it apply cleanly.
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var hunk: DiffHunk?
        var inHeader = false
        var oldLine = 0, newLine = 0

        func closeHunk() {
            if let h = hunk { current?.hunks.append(h) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if let f = current { files.append(f) }
            current = nil
        }

        // Split on the "\n" scalar, not on Character: Swift treats "\r\n" as one Character, which would
        // glue every line of a CRLF file together. The "\r" stays part of the line, as git sees it.
        for raw in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(String.UnicodeScalarView(raw))
            if line.hasPrefix("diff --git ") {
                closeFile()
                var file = FileDiff()
                file.header.append(line)
                // Paths from "diff --git a/x b/y", in case ---/+++ never come (binary or mode-only changes).
                let parts = line.dropFirst("diff --git ".count).components(separatedBy: " b/")
                if parts.count == 2 {
                    file.oldPath = parts[0].hasPrefix("a/") ? String(parts[0].dropFirst(2)) : parts[0]
                    file.newPath = parts[1]
                }
                current = file
                inHeader = true
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("@@") {
                closeHunk()
                inHeader = false
                guard let parsed = parseHunkHeader(line) else { continue }
                hunk = parsed
                oldLine = parsed.oldStart
                newLine = parsed.newStart
                continue
            }
            if inHeader {
                if line.hasPrefix("--- ") { current?.oldPath = path(String(line.dropFirst(4))) }
                else if line.hasPrefix("+++ ") { current?.newPath = path(String(line.dropFirst(4))) }
                else if line.hasPrefix("new file mode") { current?.oldPath = nil }
                else if line.hasPrefix("deleted file mode") { current?.newPath = nil }
                else if line.hasPrefix("rename from ") { current?.oldPath = String(line.dropFirst("rename from ".count)) }
                else if line.hasPrefix("rename to ") { current?.newPath = String(line.dropFirst("rename to ".count)) }
                else if line.hasPrefix("Binary files ") || line == "GIT binary patch" { current?.isBinary = true }
                else if line.hasPrefix("index "), let ids = line.dropFirst(6).split(separator: " ").first {
                    let pair = ids.components(separatedBy: "..")
                    if pair.count == 2 { current?.oldBlob = pair[0]; current?.newBlob = pair[1] }
                }
                if !line.isEmpty { current?.header.append(line) }
                continue
            }
            guard var h = hunk, let marker = line.first else { continue }
            let body = String(line.dropFirst())
            switch marker {
            case " ":
                h.lines.append(DiffLine(kind: .context, text: body, oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            case "-":
                h.lines.append(DiffLine(kind: .removed, text: body, oldNumber: oldLine, newNumber: nil))
                oldLine += 1
            case "+":
                h.lines.append(DiffLine(kind: .added, text: body, oldNumber: nil, newNumber: newLine))
                newLine += 1
            case "\\":
                // "\\ No newline at end of file" refers to the line just before it.
                switch h.lines.last?.kind {
                case .removed?: h.oldMissingNewline = true
                case .added?: h.newMissingNewline = true
                default: h.oldMissingNewline = true; h.newMissingNewline = true
                }
            default:
                break
            }
            hunk = h
        }
        closeFile()
        return files
    }

    /// "a/src/x.swift" -> "src/x.swift"; "/dev/null" -> nil.
    static func path(_ field: String) -> String? {
        let trimmed = field.split(separator: "\t").first.map(String.init) ?? field
        if trimmed == "/dev/null" { return nil }
        if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") { return String(trimmed.dropFirst(2)) }
        return trimmed
    }

    /// "@@ -12,7 +12,9 @@ func x()" ; a missing count means 1.
    static func parseHunkHeader(_ line: String) -> DiffHunk? {
        let scanner = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard let close = scanner.range(of: "@@") else { return nil }
        let ranges = scanner[..<close.lowerBound].split(separator: " ")
        guard ranges.count >= 2, ranges[0].hasPrefix("-"), ranges[1].hasPrefix("+") else { return nil }
        func pair(_ s: Substring) -> (Int, Int)? {
            let p = s.dropFirst().split(separator: ",")
            guard let start = Int(p[0]) else { return nil }
            return (start, p.count > 1 ? Int(p[1]) ?? 1 : 1)
        }
        guard let old = pair(ranges[0]), let new = pair(ranges[1]) else { return nil }
        let section = scanner[close.upperBound...].trimmingCharacters(in: .whitespaces)
        return DiffHunk(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1, section: section, lines: [])
    }

    /// A patch containing only `hunk` of `file`, for `git apply --cached` (stage this change)
    /// or `git apply -R` (revert it). Uses the file's original header.
    public static func patch(for hunk: DiffHunk, in file: FileDiff) -> String {
        var out = file.header.filter { !$0.hasPrefix("index ") }
        // Make sure ---/+++ are there (they are absent for some headers).
        if !out.contains(where: { $0.hasPrefix("--- ") }) { out.append("--- " + (file.oldPath.map { "a/" + $0 } ?? "/dev/null")) }
        if !out.contains(where: { $0.hasPrefix("+++ ") }) { out.append("+++ " + (file.newPath.map { "b/" + $0 } ?? "/dev/null")) }
        out.append("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@" + (hunk.section.isEmpty ? "" : " " + hunk.section))
        let lastOld = hunk.lines.lastIndex { $0.kind != .added }
        let lastNew = hunk.lines.lastIndex { $0.kind != .removed }
        for (i, line) in hunk.lines.enumerated() {
            let marker: String
            switch line.kind {
            case .context: marker = " "
            case .added: marker = "+"
            case .removed: marker = "-"
            }
            out.append(marker + line.text)
            let oldEnds = hunk.oldMissingNewline && i == lastOld && line.kind != .added
            let newEnds = hunk.newMissingNewline && i == lastNew && line.kind != .removed
            if oldEnds || newEnds { out.append("\\ No newline at end of file") }
        }
        return out.joined(separator: "\n") + "\n"
    }
}

// MARK: - side by side

/// One row of a side-by-side view. A changed line has both sides; a pure removal or addition has one,
/// and the other side is a filler so both columns stay aligned.
public struct SideBySideRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case hunkHeader, unchanged, changed, removed, added }
    public let kind: Kind
    public let left: DiffLine?
    public let right: DiffLine?
    /// Changed character ranges (UTF-16) on each side, for word-level highlighting.
    public let leftChanges: [NSRange]
    public let rightChanges: [NSRange]
    /// For `.hunkHeader`: the hunk's index in the file.
    public let hunkIndex: Int?
}

public enum SideBySide {
    public static func rows(for file: FileDiff) -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        for (index, hunk) in file.hunks.enumerated() {
            rows.append(SideBySideRow(kind: .hunkHeader, left: nil, right: nil, leftChanges: [], rightChanges: [], hunkIndex: index))
            var removed: [DiffLine] = []
            var added: [DiffLine] = []
            func flush() {
                // Pair removals with additions in order: those are the changed lines.
                for i in 0..<max(removed.count, added.count) {
                    let l = i < removed.count ? removed[i] : nil
                    let r = i < added.count ? added[i] : nil
                    if let l, let r {
                        let (lc, rc) = WordDiff.changes(old: l.text, new: r.text)
                        rows.append(SideBySideRow(kind: .changed, left: l, right: r, leftChanges: lc, rightChanges: rc, hunkIndex: index))
                    } else if let l {
                        rows.append(SideBySideRow(kind: .removed, left: l, right: nil, leftChanges: [], rightChanges: [], hunkIndex: index))
                    } else if let r {
                        rows.append(SideBySideRow(kind: .added, left: nil, right: r, leftChanges: [], rightChanges: [], hunkIndex: index))
                    }
                }
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
                    rows.append(SideBySideRow(kind: .unchanged, left: line, right: line, leftChanges: [], rightChanges: [], hunkIndex: index))
                }
            }
            flush()
        }
        return rows
    }
}

/// Which words changed between two versions of a line, as UTF-16 ranges on each side.
public enum WordDiff {
    /// Lines longer than this are highlighted whole rather than word by word.
    static let maxTokens = 400

    public static func changes(old: String, new: String) -> (old: [NSRange], new: [NSRange]) {
        let a = tokens(old), b = tokens(new)
        if a.count > maxTokens || b.count > maxTokens {
            return ([NSRange(location: 0, length: (old as NSString).length)], [NSRange(location: 0, length: (new as NSString).length)])
        }
        let diff = b.map(\.text).difference(from: a.map(\.text))
        var removedTokens = Set<Int>(), insertedTokens = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedTokens.insert(offset)
            case .insert(let offset, _, _): insertedTokens.insert(offset)
            }
        }
        return (merge(a, removedTokens), merge(b, insertedTokens))
    }

    struct Token { let text: String; let range: NSRange }

    /// Words, runs of whitespace, and single punctuation characters.
    static func tokens(_ line: String) -> [Token] {
        var result: [Token] = []
        let ns = line as NSString
        var i = 0
        while i < ns.length {
            let start = i
            let c = ns.character(at: i)
            func isWord(_ u: unichar) -> Bool {
                guard let scalar = Unicode.Scalar(u) else { return true } // surrogate halves: part of a word
                return CharacterSet.alphanumerics.contains(scalar) || u == 95 // _
            }
            func isSpace(_ u: unichar) -> Bool { u == 32 || u == 9 }
            if isWord(c) {
                while i < ns.length, isWord(ns.character(at: i)) { i += 1 }
            } else if isSpace(c) {
                while i < ns.length, isSpace(ns.character(at: i)) { i += 1 }
            } else {
                i += 1
            }
            let range = NSRange(location: start, length: i - start)
            result.append(Token(text: ns.substring(with: range), range: range))
        }
        return result
    }

    /// Joins adjacent changed tokens into ranges.
    static func merge(_ tokens: [Token], _ changed: Set<Int>) -> [NSRange] {
        var ranges: [NSRange] = []
        for index in changed.sorted() {
            let r = tokens[index].range
            if let last = ranges.last, NSMaxRange(last) == r.location {
                ranges[ranges.count - 1] = NSRange(location: last.location, length: last.length + r.length)
            } else {
                ranges.append(r)
            }
        }
        return ranges
    }
}

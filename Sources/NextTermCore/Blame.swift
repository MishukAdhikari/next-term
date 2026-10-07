import Foundation

/// Who last changed each line of a file, read from `git blame --porcelain`.
public struct Blame: Equatable, Sendable {
    public struct Commit: Equatable, Sendable {
        public let sha: String
        public let author: String
        public let authorMail: String
        public let authorTime: Date
        public let summary: String
        /// The file's path in that commit (an older name, before a rename).
        public let path: String

        public init(sha: String, author: String, authorMail: String, authorTime: Date, summary: String, path: String) {
            self.sha = sha
            self.author = author
            self.authorMail = authorMail
            self.authorTime = authorTime
            self.summary = summary
            self.path = path
        }

        public var shortSHA: String { String(sha.prefix(7)) }

        /// The author's first name ("Ann" for "Ann Lee"), or the whole name when it is one word.
        public var shortAuthor: String {
            let name = author.trimmingCharacters(in: .whitespaces)
            return name.split(separator: " ").first.map(String.init) ?? name
        }
    }

    public struct Line: Equatable, Sendable {
        /// The commit that last changed the line; nil when it is not committed yet.
        public let sha: String?
        /// 1-based line number in that commit's version of the file (0 when not committed).
        public let originalLine: Int

        public init(sha: String?, originalLine: Int) {
            self.sha = sha
            self.originalLine = originalLine
        }

        public static let notCommitted = Line(sha: nil, originalLine: 0)
        public var isCommitted: Bool { sha != nil }
    }

    /// The commits the lines name, by full hash. Never the not-committed one.
    public var commits: [String: Commit] = [:]
    /// One per line of the file, in order.
    public var lines: [Line] = []
    /// The work tree's root, and the commit the blame is of (empty when parsed from text alone).
    public var root = ""
    public var head = ""

    public init() {}

    /// git's name for changes not committed yet.
    static let zeroSHA = String(repeating: "0", count: 40)

    public func commit(_ line: Line) -> Commit? { line.sha.flatMap { commits[$0] } }

    /// Parses `git blame --porcelain`: per line a header (`sha original final [count]`), the commit's
    /// details the first time it appears, and the line itself after a tab. Nil for a binary file.
    public static func parse(_ data: Data) -> Blame? {
        struct Pending { var author = "", mail = "", time = 0.0, summary = "", path = "" }
        var blame = Blame()
        var details: [String: Pending] = [:]
        var placed: [(final: Int, line: Line)] = []
        var current: (sha: String, original: Int, final: Int)?
        for record in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if record.first == 0x09 { // the line's text
                if record.contains(0) { return nil }
                if let entry = current {
                    let sha = entry.sha == zeroSHA ? nil : entry.sha
                    placed.append((entry.final, Line(sha: sha, originalLine: sha == nil ? 0 : entry.original)))
                }
                current = nil
                continue
            }
            let text = String(decoding: record, as: UTF8.self)
            if current == nil {
                let fields = text.split(separator: " ")
                guard fields.count >= 3, fields[0].count == 40, let original = Int(fields[1]), let final = Int(fields[2]) else { continue }
                // One string per commit, shared by all of its lines.
                let key = String(fields[0])
                let sha = details.index(forKey: key).map { details.keys[$0] } ?? key
                current = (sha, original, final)
                if details[sha] == nil { details[sha] = Pending() }
                continue
            }
            guard let sha = current?.sha else { continue }
            let space = text.firstIndex(of: " ") ?? text.endIndex
            let value = space < text.endIndex ? String(text[text.index(after: space)...]) : ""
            switch text[..<space] {
            case "author": details[sha]?.author = value
            case "author-mail": details[sha]?.mail = value.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            case "author-time": details[sha]?.time = Double(value) ?? 0
            case "summary": details[sha]?.summary = value
            case "filename": details[sha]?.path = value
            default: break
            }
        }
        for (sha, d) in details where sha != zeroSHA {
            blame.commits[sha] = Commit(sha: sha, author: d.author, authorMail: d.mail, authorTime: Date(timeIntervalSince1970: d.time),
                                        summary: d.summary, path: d.path)
        }
        blame.lines = placed.sorted { $0.final < $1.final }.map(\.line)
        return blame
    }

    /// How long ago, in a few letters: "now", "5m", "3h", "2d", "3w", "5mo", "2y".
    public static func compactAge(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minute = 60.0, hour = 3600.0, day = 86400.0
        switch seconds {
        case ..<minute: return "now"
        case ..<hour: return "\(Int(seconds / minute))m"
        case ..<day: return "\(Int(seconds / hour))h"
        case ..<(7 * day): return "\(Int(seconds / day))d"
        case ..<(30 * day): return "\(Int(seconds / (7 * day)))w"
        case ..<(365 * day): return "\(max(1, Int(seconds / (30 * day))))mo"
        default: return "\(Int(seconds / (365 * day)))y"
        }
    }
}

extension GitRunner {
    public enum BlameResult: Equatable, Sendable {
        case annotated(Blame)
        /// In a repository, but not in its last commit (new, untracked, or no commit yet): no line is committed.
        case notCommitted(root: String)
        case notInRepository
        case binary
        /// Bigger than the limit asked for.
        case tooLarge
        case failed
    }

    /// The commit each line of a file comes from, as of the last commit, or with `workingTree` as the file
    /// is on disk (lines changed since the last commit are not committed). Lines moved within the file
    /// keep their commit (`-M`), and a renamed file is followed to its old name. Read-only.
    /// With a `cache`, a file already blamed at this HEAD is not blamed again.
    public static func blame(of path: String, git: String, workingTree: Bool = false, maxSize: Int = 2_000_000,
                             timeout: TimeInterval = 30, cache: BlameCache? = nil) -> BlameResult {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let prefix = ["-C", folder, "--no-optional-locks"]
        // The root and HEAD in one run; with no commit yet, only the root answers.
        guard let found = lines(run(git, prefix + ["rev-parse", "--show-toplevel", "HEAD"], timeout: timeout)), found.count == 2 else {
            if let root = lines(run(git, prefix + ["rev-parse", "--show-toplevel"], timeout: timeout))?.first { return .notCommitted(root: root) }
            return .notInRepository
        }
        let (root, head) = (found[0], found[1])
        let key = workingTree ? nil : path + "\0" + head
        if let key, let known = cache?[key] { return known }
        let result = blame(name, prefix: prefix, root: root, head: head, git: git, workingTree: workingTree, maxSize: maxSize, timeout: timeout)
        if let key, result != .failed { cache?[key] = result }
        return result
    }

    private static func lines(_ data: Data?) -> [String]? {
        data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\n").map(String.init)
    }

    private static func blame(_ name: String, prefix: [String], root: String, head: String, git: String, workingTree: Bool,
                              maxSize: Int, timeout: TimeInterval) -> BlameResult {
        // Its size in the commit, which also says whether it is there at all.
        guard let size = lines(run(git, prefix + ["cat-file", "-s", head + ":./" + name], timeout: timeout))?.first.flatMap({ Int($0) }) else {
            return .notCommitted(root: root)
        }
        guard size <= maxSize else { return .tooLarge }
        let revision = workingTree ? [] : [head]
        guard let data = run(git, prefix + ["blame", "--porcelain", "-M"] + revision + ["--", name], timeout: timeout) else { return .failed }
        guard var blame = Blame.parse(data) else { return .binary }
        blame.root = root
        blame.head = head
        return .annotated(blame)
    }
}

/// The blame of the text being edited: the last commit's blame carried over to the current text (lines
/// added or changed since are not committed), and kept in step with each edit until the next diff.
public struct EditedBlame: Sendable {
    public let blame: Blame
    /// One per line of the current text, as git counts lines (no line after a final newline).
    public private(set) var lines: [Blame.Line]
    private let oldest: Date
    private let newest: Date

    /// `diff` goes from the committed text to the current one (nil: they are the same).
    public init(_ blame: Blame, diff: FileDiff?, lineCount: Int) {
        self.blame = blame
        let times = blame.commits.values.map(\.authorTime)
        oldest = times.min() ?? Date()
        newest = times.max() ?? Date()
        var lines: [Blame.Line] = []
        lines.reserveCapacity(lineCount)
        func committed(_ number: Int) -> Blame.Line { blame.lines.indices.contains(number - 1) ? blame.lines[number - 1] : .notCommitted }
        var old = 1, new = 1 // the next line of each, 1-based
        for hunk in diff?.hunks ?? [] {
            // git numbers an empty side by the line before it.
            let oldFirst = hunk.oldCount == 0 ? hunk.oldStart + 1 : hunk.oldStart
            let newFirst = hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart
            while new < newFirst { lines.append(committed(old)); old += 1; new += 1 }
            lines.append(contentsOf: repeatElement(.notCommitted, count: hunk.newCount))
            new = newFirst + hunk.newCount
            old = oldFirst + hunk.oldCount
        }
        while new <= lineCount { lines.append(committed(old)); old += 1; new += 1 }
        if lines.count > lineCount { lines.removeLast(lines.count - lineCount) }
        self.lines = lines
    }

    /// Lines as git counts them: a final newline ends the last line rather than starting another.
    public static func lineCount(of text: String) -> Int {
        var count = 0, last: UInt8 = 0x0A
        for byte in text.utf8 {
            if byte == 0x0A { count += 1 }
            last = byte
        }
        return last == 0x0A ? count : count + 1
    }

    /// A file with no commit: every line is new.
    public static func notCommitted(lineCount: Int, root: String) -> EditedBlame {
        var blame = Blame()
        blame.root = root
        return EditedBlame(blame, diff: nil, lineCount: lineCount)
    }

    private mutating func fit(_ count: Int) {
        if lines.count > count { lines.removeLast(lines.count - count) }
        if lines.count < count { lines.append(contentsOf: repeatElement(.notCommitted, count: count - lines.count)) }
    }

    /// Lines `old` (0-based, as they were) became lines `old.lowerBound...newLast`: those are not committed
    /// now, and every line after them moves with the edit. `lineCount` is the text's count after it.
    public mutating func edit(lines old: ClosedRange<Int>, nowEndingAt newLast: Int, lineCount: Int) {
        let lower = min(old.lowerBound, lines.count)
        let upper = min(old.upperBound + 1, lines.count)
        lines.replaceSubrange(lower..<upper, with: repeatElement(.notCommitted, count: max(0, newLast - old.lowerBound + 1)))
        fit(lineCount)
    }

    public func line(_ index: Int) -> Blame.Line? { lines.indices.contains(index) ? lines[index] : nil }

    public func commit(at index: Int) -> Blame.Commit? { line(index).flatMap(blame.commit) }

    /// Whether a line starts a run of lines from one commit (the annotation is drawn there only).
    public func isBlockStart(_ index: Int) -> Bool {
        guard lines.indices.contains(index) else { return false }
        return index == 0 || lines[index - 1].sha != lines[index].sha
    }

    /// The run of lines from the same commit around a line.
    public func block(containing index: Int) -> ClosedRange<Int>? {
        guard lines.indices.contains(index) else { return nil }
        let sha = lines[index].sha
        var first = index, last = index
        while first > 0, lines[first - 1].sha == sha { first -= 1 }
        while last + 1 < lines.count, lines[last + 1].sha == sha { last += 1 }
        return first...last
    }

    /// How recent a commit is among the file's, from 0 (the oldest) to 1 (the newest).
    public func recency(of commit: Blame.Commit) -> Double {
        let span = newest.timeIntervalSince(oldest)
        guard span > 0 else { return 1 }
        return max(0, min(1, commit.authorTime.timeIntervalSince(oldest) / span))
    }
}

/// Blames already read, by file and HEAD: a file is blamed again only after a commit or a checkout.
public final class BlameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: GitRunner.BlameResult] = [:]
    private var order: [String] = []
    private let limit: Int

    public init(limit: Int = 32) { self.limit = limit }

    subscript(key: String) -> GitRunner.BlameResult? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return results[key]
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            order.removeAll { $0 == key }
            results[key] = newValue
            if newValue != nil { order.append(key) }
            while order.count > limit { results[order.removeFirst()] = nil }
        }
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return results.count
    }
}

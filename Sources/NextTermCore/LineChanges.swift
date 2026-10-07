import Foundation

/// The editor gutter's change marks: which lines of the text being edited differ from the last commit.
/// A run of removed lines followed by added lines is a change (the first lines of the run are marked
/// changed, any extra as added); added lines alone are added; removed lines alone leave a mark between
/// the lines around where they were.
public enum LineChanges {
    public enum Mark: Equatable, Sendable { case added, modified }

    public struct Marks: Equatable, Sendable {
        /// 0-based line in the current text → its mark.
        public var lines: [Int: Mark] = [:]
        /// Lines were removed just above this 0-based line (the line count: at the end).
        public var deletedBefore: Set<Int> = []
        public init() {}
        public var isEmpty: Bool { lines.isEmpty && deletedBefore.isEmpty }
    }

    public static func marks(from diff: FileDiff) -> Marks {
        var marks = Marks()
        for hunk in diff.hunks {
            var removed = 0
            var added: [Int] = []
            // Where the next new line would be (1-based), to place a deletion with no added lines after it.
            var nextNew = hunk.newStart + (hunk.newCount == 0 ? 1 : 0)
            func flush() {
                for (i, line) in added.enumerated() { marks.lines[line - 1] = i < removed ? .modified : .added }
                if removed > 0 && added.isEmpty { marks.deletedBefore.insert(max(0, nextNew - 1)) }
                removed = 0
                added = []
            }
            for line in hunk.lines {
                switch line.kind {
                case .removed:
                    if !added.isEmpty { flush() }
                    removed += 1
                case .added:
                    if let number = line.newNumber { added.append(number); nextNew = number + 1 }
                case .context:
                    flush()
                    if let number = line.newNumber { nextNew = number + 1 }
                }
            }
            flush()
        }
        return marks
    }
}

extension GitRunner {
    /// The commit HEAD points at in the repository a file is in; nil with no commit yet, or outside one.
    public static func headCommit(of path: String, git: String) -> String? {
        let folder = (path as NSString).deletingLastPathComponent
        let data = run(git, ["-C", folder, "--no-optional-locks", "rev-parse", "--verify", "--quiet", "HEAD"], timeout: 10)
        let sha = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha?.isEmpty == false ? sha : nil
    }

    /// A file's text in the last commit (or in `revision`), or nil when it is not there (new, untracked,
    /// or outside a repository). Read-only: `git show` takes no index lock.
    public static func headText(of path: String, git: String, revision: String = "HEAD") -> String? {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let object = revision + ":./" + name
        guard let data = run(git, ["-C", folder, "--no-optional-locks", "show", "--no-textconv", object], timeout: 10),
              !data.prefix(8000).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

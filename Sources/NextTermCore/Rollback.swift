import Foundation

/// Git › Rollback…: putting a file's uncommitted changes back to the last commit, as JetBrains IDEs' Rollback and
/// VS Code's Discard Changes do. What each path needs is read from git's own status codes (GitSnapshot.codes), so a
/// path the last commit doesn't have is never checked out of it (that fails) and is never deleted for good: it leaves
/// the index and goes to the Trash. A conflict is never touched. Every git step takes its paths literally.
public enum Rollback {
    public enum Step: Equatable, Sendable {
        /// Back to HEAD in the index and the working tree: a change, a deletion, a type change.
        case restore(String)
        /// A file HEAD doesn't have: out of the index when it is there (`staged`), and to the Trash.
        case remove(String, staged: Bool)
    }

    public enum Refusal: Equatable, Sendable, Error {
        /// In a merge or rebase conflict: resolving it is the way out, not a rollback.
        case conflicted(String)
        /// Nothing uncommitted: nothing to roll back.
        case unchanged(String)
    }

    /// The steps for `paths` (relative to the snapshot's root, as its keys are), in order: what goes to the Trash first,
    /// so a file a restore puts back never lands on top of one that was there. A folder's path takes every changed
    /// path under it. Ignored files are never part of a rollback.
    public static func plan(_ paths: [String], in snapshot: GitSnapshot) -> Result<[Step], Refusal> {
        var removes: [Step] = [], restores: [Step] = []
        for path in expanded(paths, in: snapshot) {
            let change = snapshot.files[path]
            let code = snapshot.codes[path] ?? ""
            let index = code.first.map(String.init) ?? "", worktree = code.dropFirst().first.map(String.init) ?? ""
            if change == .conflicted { return .failure(.conflicted(path)) }
            if let old = snapshot.renamedFrom[path] {
                // Renamed in the index: the old path back from HEAD, the new one out of the index and to the Trash.
                restores.append(.restore(old))
                removes.append(.remove(path, staged: true))
            } else if index == "A" || worktree == "A" {
                // Added, or marked with `git add -N`: HEAD has nothing to restore it from.
                removes.append(.remove(path, staged: true))
            } else if index == "D" && change == .untracked {
                // Deleted in the index with a new, untracked file at the same path: that file first, then HEAD's back.
                removes.append(.remove(path, staged: false))
                restores.append(.restore(path))
            } else if change == .untracked {
                removes.append(.remove(path, staged: false))
            } else if !code.isEmpty {
                restores.append(.restore(path))
            }
        }
        guard !removes.isEmpty || !restores.isEmpty else { return .failure(.unchanged(paths.first ?? "")) }
        return .success(removes + restores)
    }

    /// `paths`, each folder in it given as every path with a change under it, without duplicates, ignored files left out.
    static func expanded(_ paths: [String], in snapshot: GitSnapshot) -> [String] {
        var seen = Set<String>(), result: [String] = []
        let changed = snapshot.files.filter { $0.value != .ignored }.keys.sorted()
        for path in paths {
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            let matches = snapshot.files[trimmed].map { $0 == .ignored ? [] : [trimmed] }
                ?? changed.filter { trimmed.isEmpty || $0.hasPrefix(trimmed + "/") }
            for match in matches where seen.insert(match).inserted { result.append(match) }
        }
        return result
    }

    /// The git commands for `steps`, as GitWriter runs them (after `-C root`), each step's paths taken literally:
    /// first `rm --cached` for the new files in the index, then one `checkout HEAD --` for every path HEAD has. The
    /// files themselves go to the Trash in between, by the app (`trashed`).
    public static func commands(_ steps: [Step]) -> (unstage: [[String]], restore: [[String]]) {
        let staged = steps.compactMap { step -> String? in if case let .remove(path, true) = step { return path } else { return nil } }
        let restored = steps.compactMap { step -> String? in if case let .restore(path) = step { return path } else { return nil } }
        let unstage = staged.isEmpty ? [] : [["--literal-pathspecs", "rm", "--cached", "--quiet", "--ignore-unmatch", "--"] + staged]
        let restore = restored.isEmpty ? [] : [["--literal-pathspecs", "checkout", "HEAD", "--"] + restored]
        return (unstage, restore)
    }

    /// The paths that go to the Trash.
    public static func trashed(_ steps: [Step]) -> [String] {
        steps.compactMap { step -> String? in if case let .remove(path, _) = step { return path } else { return nil } }
    }

    /// Every path a rollback of `steps` changes, for what Undo saves first.
    public static func touched(_ steps: [Step]) -> [String] {
        var seen = Set<String>()
        return steps.compactMap { step -> String? in
            switch step {
            case let .restore(path), let .remove(path, _): return seen.insert(path).inserted ? path : nil
            }
        }
    }

    // MARK: Undo

    /// A path's entry in the index before the rollback (stage 0), to put back exactly: what was staged stays staged.
    public struct IndexEntry: Equatable, Sendable {
        public var mode: String
        public var sha: String
        public init(mode: String, sha: String) {
            self.mode = mode
            self.sha = sha
        }
    }

    /// The index entries in `git ls-files --stage -z -- <paths>` output, by path (stage 0 only).
    public static func indexEntries(_ output: String) -> [String: IndexEntry] {
        var entries: [String: IndexEntry] = [:]
        for record in output.split(separator: "\0") {
            // "100644 <sha> 0\tpath"
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count == 3, fields[2] == "0" else { continue }
            entries[String(record[record.index(after: tab)...])] = IndexEntry(mode: String(fields[0]), sha: String(fields[1]))
        }
        return entries
    }

    /// The command that reads the index entries Undo puts back (`indexEntries`), paths taken literally.
    public static func indexEntriesCommand(_ paths: [String]) -> [String] {
        ["--literal-pathspecs", "ls-files", "--stage", "-z", "--"] + paths
    }

    /// The index entries for `paths` in the repository at `root`, read now; nil when git can't say.
    public static func readIndexEntries(_ paths: [String], root: String, git: String) -> [String: IndexEntry]? {
        guard let data = GitRunner.run(git, ["-C", root] + indexEntriesCommand(paths), timeout: 15) else { return nil }
        return indexEntries(String(decoding: data, as: UTF8.self))
    }

    /// The paths marked with `git add -N` (".A"): the index holds no content of theirs, so Undo marks them again.
    public static func intentToAdd(_ paths: [String], in snapshot: GitSnapshot) -> Set<String> {
        Set(paths.filter { snapshot.codes[$0] == ".A" })
    }

    /// The git commands that put the index back as `before` had it for `paths`: each entry's blob again (it is still in
    /// the object store), a path marked with `git add -N` marked again, and a path that wasn't in the index taken out
    /// of it. Run once the files are back.
    public static func undoIndexCommands(_ paths: [String], before: [String: IndexEntry], intentToAdd: Set<String> = []) -> [[String]] {
        var commands: [[String]] = []
        for path in paths where !intentToAdd.contains(path) {
            guard let entry = before[path] else { continue }
            commands.append(["update-index", "--add", "--cacheinfo", "\(entry.mode),\(entry.sha),\(path)"])
        }
        let absent = paths.filter { before[$0] == nil && !intentToAdd.contains($0) }
        if !absent.isEmpty { commands.append(["update-index", "--force-remove", "--"] + absent) }
        let marked = paths.filter { intentToAdd.contains($0) }
        if !marked.isEmpty { commands.append(["--literal-pathspecs", "add", "-N", "--"] + marked) }
        return commands
    }

    /// What the notice says once it's done: "Rolled back main.swift", "Rolled back 3 files".
    public static func done(_ paths: [String]) -> String {
        guard paths.count == 1, let path = paths.first else { return "Rolled back \(paths.count) files" }
        return "Rolled back \((path as NSString).lastPathComponent)"
    }
}

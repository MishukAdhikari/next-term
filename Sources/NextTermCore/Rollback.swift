import Foundation

/// Git › Rollback…: putting files' uncommitted changes back to the last commit, as JetBrains IDEs' Rollback and VS Code's
/// Discard Changes do. What each path needs is read from git's own status codes (GitSnapshot.codes), and what is on disk
/// now (`DiskKind`, from the app), so that:
/// - a path the last commit doesn't have is never checked out of it and never deleted for good: it leaves the index and
///   goes to the Trash (a new file, a new folder, a rename's or a copy's new path);
/// - nothing a checkout would overwrite or delete is ever in the way: a folder, a nested repository or a file at a
///   path to restore, or at one of its parent folders, is refused, never removed;
/// - a conflict and a submodule are never touched.
/// Every git step takes its paths literally.
public enum Rollback {
    public enum Step: Equatable, Sendable {
        /// Back to HEAD in the index and the working tree: a change, a deletion, a type change, a rename's old path.
        case restore(String)
        /// What HEAD doesn't have: out of the index when it is there (`staged`), and to the Trash (a file or a folder).
        case remove(String, staged: Bool)
    }

    /// What is at a path on disk now, without following a link.
    public enum DiskKind: Equatable, Sendable { case none, file, directory, link }

    /// What is at `relative` under `root` (lstat: a link is a link, not what it points to).
    public static func diskKind(_ relative: String, root: String) -> DiskKind {
        var info = stat()
        guard lstat(relative.isEmpty ? root : root + "/" + relative, &info) == 0 else { return .none }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .link
        default: return .file
        }
    }

    public enum Refusal: Equatable, Sendable, Error {
        /// In a merge or rebase conflict: resolving it is the way out, not a rollback.
        case conflicted(String)
        /// Nothing uncommitted there: nothing to roll back.
        case unchanged(String)
        /// A submodule: its changes are rolled back in its own repository.
        case submodule(String)
        /// `path` can't come back while `by` is on disk where it goes (a folder, a nested repository, a file where a
        /// parent folder must be, a name that differs only in case): moving it is the user's call.
        case blocked(String, by: String)
    }

    public struct Plan: Equatable, Sendable {
        /// In order: the Trash first, so nothing a restore brings back lands on what was there.
        public var steps: [Step]
        /// The files and folders as the user sees them: a rename once, by its new name.
        public var files: [String]
    }

    /// The plan for `paths` (relative to the snapshot's root, as its keys are; "" is the whole work tree), `disk` saying
    /// what is at a relative path now. A folder's path takes every change under it, new folders included. Ignored files
    /// are never part of a rollback.
    public static func plan(_ paths: [String], in snapshot: GitSnapshot, disk: (String) -> DiskKind) -> Result<Plan, Refusal> {
        var removes: [Step] = [], restores: [Step] = [], files: [String] = []
        func restore(_ path: String, deleted: Bool) -> Refusal? {
            // Every parent folder must be a folder (or not there yet): git would replace a file or a link there.
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if [.file, .link].contains(disk(parent)) { return .blocked(path, by: parent) }
                parent = (parent as NSString).deletingLastPathComponent
            }
            let there = disk(path)
            // A deleted file comes back where nothing is now; a changed one replaces a file or a link, never a folder.
            if (deleted && there != .none) || there == .directory { return .blocked(path, by: path) }
            restores.append(.restore(path))
            return nil
        }
        for path in expanded(paths, in: snapshot) {
            let change = snapshot.files[path] ?? snapshot.wholeFolders[path]
            let code = snapshot.codes[path] ?? ""
            let index = code.first.map(String.init) ?? "", worktree = code.dropFirst().first.map(String.init) ?? ""
            if snapshot.submodules.contains(path) { return .failure(.submodule(path)) }
            if change == .conflicted { return .failure(.conflicted(path)) }
            let stepsBefore = removes.count + restores.count
            defer { if removes.count + restores.count > stepsBefore { files.append(path) } }
            // A path inside a new folder git reports whole is new itself.
            let insideNew = change == nil && snapshot.wholeFolders.contains { $0.value == .untracked && path.hasPrefix($0.key + "/") }
            if let old = snapshot.renamedFrom[path] {
                removes.append(.remove(path, staged: true))
                // A copy's origin is a file of its own, left as it is; a rename's comes back from HEAD.
                guard !code.contains("C") else { continue }
                if disk(old) != .none {
                    // The old path taken again by a new file: to the Trash first; by anything else: refused.
                    guard snapshot.files[old] == .untracked, disk(old) == .file else { return .failure(.blocked(old, by: old)) }
                    removes.append(.remove(old, staged: false))
                }
                if let refused = restore(old, deleted: false) { return .failure(refused) }
            } else if index == "A" || worktree == "A" {
                // Added, or marked with `git add -N`: HEAD has nothing to restore it from.
                removes.append(.remove(path, staged: true))
            } else if index == "D" && change == .untracked {
                // Deleted in the index with a new, untracked file at the same path: that file first, then HEAD's back.
                removes.append(.remove(path, staged: false))
                if let refused = restore(path, deleted: false) { return .failure(refused) }
            } else if change == .untracked || insideNew {
                removes.append(.remove(path, staged: false))
            } else if !code.isEmpty {
                if let refused = restore(path, deleted: index == "D" || worktree == "D") { return .failure(refused) }
            }
        }
        guard !removes.isEmpty || !restores.isEmpty else { return .failure(.unchanged(paths.first ?? "")) }
        return .success(Plan(steps: removes + restores, files: files))
    }

    /// `paths`, each folder in it given as every path with a change under it, new folders git reports whole included,
    /// without duplicates, ignored entries left out. A path inside a new folder is that path, new itself.
    static func expanded(_ paths: [String], in snapshot: GitSnapshot) -> [String] {
        var seen = Set<String>(), result: [String] = []
        let changed = snapshot.files.filter { $0.value != .ignored }.keys.sorted()
        let newFolders = snapshot.wholeFolders.filter { $0.value == .untracked }.keys.sorted()
        for path in paths {
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            var matches: [String]
            if let change = snapshot.files[trimmed] {
                matches = change == .ignored ? [] : [trimmed]
            } else if newFolders.contains(where: { trimmed == $0 || trimmed.hasPrefix($0 + "/") }) {
                matches = [trimmed]
            } else {
                let under = { (candidate: String) in trimmed.isEmpty || candidate.hasPrefix(trimmed + "/") }
                matches = changed.filter(under) + newFolders.filter(under)
            }
            for match in matches where seen.insert(match).inserted { result.append(match) }
        }
        return result
    }

    /// The git commands for `steps`, as GitWriter runs them (after `-C root`), each step's paths taken literally:
    /// first `rm --cached` for the new files in the index (`--force`: one changed again after staging is taken out too;
    /// its staged content is what Undo keeps), then one `checkout HEAD --` for every path HEAD has. What goes to the
    /// Trash goes in between, by the app (`trashed`).
    public static func commands(_ steps: [Step]) -> (unstage: [[String]], restore: [[String]]) {
        let staged = steps.compactMap { step -> String? in if case let .remove(path, true) = step { return path } else { return nil } }
        let restored = restoredPaths(steps)
        let unstage = staged.isEmpty ? [] : [["--literal-pathspecs", "rm", "--cached", "--force", "--quiet", "--ignore-unmatch", "--"] + staged]
        let restore = restored.isEmpty ? [] : [["--literal-pathspecs", "checkout", "HEAD", "--"] + restored]
        return (unstage, restore)
    }

    /// The paths that go to the Trash.
    public static func trashed(_ steps: [Step]) -> [String] {
        steps.compactMap { step -> String? in if case let .remove(path, _) = step { return path } else { return nil } }
    }

    /// The paths that come back from HEAD: the files Undo keeps copies of.
    public static func restoredPaths(_ steps: [Step]) -> [String] {
        steps.compactMap { step -> String? in if case let .restore(path) = step { return path } else { return nil } }
    }

    /// Every path a rollback of `steps` changes, for the index entries Undo puts back.
    public static func touched(_ steps: [Step]) -> [String] {
        var seen = Set<String>()
        return steps.compactMap { step -> String? in
            switch step {
            case let .restore(path), let .remove(path, _): return seen.insert(path).inserted ? path : nil
            }
        }
    }

    // MARK: What it says

    /// The question before a rollback: the file by its name, or how many there are and where, the first ten listed;
    /// what happens to them; and Undo. `named` is what was chosen (a folder's path, "" for the whole work tree).
    public static func question(_ plan: Plan, named: [String], root: String) -> (title: String, info: String) {
        let count = plan.files.count
        let trashed = Set(trashed(plan.steps)).intersection(plan.files).count
        let title: String
        if count == 1, let file = plan.files.first {
            title = "Roll back “\((file as NSString).lastPathComponent)”?"
        } else if named.count == 1, let folder = named.first, !plan.files.contains(folder) {
            let name = folder.isEmpty ? (root as NSString).lastPathComponent : (folder as NSString).lastPathComponent
            title = folder.isEmpty ? "Roll back all \(count) changed files in “\(name)”?" : "Roll back \(count) files in “\(name)”?"
        } else {
            title = "Roll back \(count) files?"
        }
        var lines: [String] = []
        if count > 1 {
            lines.append(plan.files.prefix(10).joined(separator: "\n") + (count > 10 ? "\nand \(count - 10) more" : ""))
        }
        switch (count - trashed, trashed) {
        case (_, 0): lines.append(count == 1 ? "It goes back to the last commit." : "They go back to the last commit.")
        case (0, _): lines.append(count == 1 ? "It isn’t in the last commit, so it goes to the Trash." : "They aren’t in the last commit, so they go to the Trash.")
        default: lines.append("They go back to the last commit; the \(trashed) new one\(trashed == 1 ? "" : "s") go\(trashed == 1 ? "es" : "") to the Trash.")
        }
        lines.append("Undo, on the notice after, puts everything back.")
        return (title, lines.joined(separator: "\n\n"))
    }

    /// Why a rollback was refused, as an alert says it.
    public static func refusal(_ refusal: Refusal) -> (title: String, info: String) {
        func name(_ path: String) -> String { (path as NSString).lastPathComponent }
        switch refusal {
        case let .conflicted(path):
            return ("“\(name(path))” is in a conflict", "Resolve it, or abort the merge or rebase, before rolling it back.")
        case let .unchanged(path):
            return ("Nothing to roll back", "“\(name(path))” has no uncommitted changes.")
        case let .submodule(path):
            return ("“\(name(path))” is a submodule", "Roll back the changes inside it from its own repository.")
        case let .blocked(path, by):
            let what = by == path ? "Something else is at “\(path)” now" : "“\(by)” is a file where a folder has to be"
            return ("“\(name(path))” can’t come back", "\(what). Move it out of the way, then roll back again.")
        }
    }

    /// What the notice says once it's done: "Rolled back main.swift", "Rolled back 3 files".
    public static func done(_ files: [String]) -> String {
        guard files.count == 1, let path = files.first else { return "Rolled back \(files.count) files" }
        return "Rolled back \((path as NSString).lastPathComponent)"
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

    /// The paths marked with `git add -N` (".A", or ".R" when git pairs one with a deleted file): the index holds no
    /// content of theirs, so Undo marks them again.
    public static func intentToAdd(_ paths: [String], in snapshot: GitSnapshot) -> Set<String> {
        Set(paths.filter { snapshot.codes[$0] == ".A" || snapshot.codes[$0] == ".R" })
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
        if !marked.isEmpty { commands.append(["--literal-pathspecs", "add", "-N", "-f", "--"] + marked) }
        return commands
    }
}

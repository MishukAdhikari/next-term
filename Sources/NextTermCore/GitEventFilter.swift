import Foundation

/// Which file changes can change what `git status` says about a work tree, so the sidebar runs git only for
/// those. FSEvents names the folder each change happened in. A writer in a folder git ignores (`next dev`
/// appending to `.next/trace` twice a second, `npm install`, a build) used to set off a full git refresh
/// each time, which on a 20,000-file repository is half a core for as long as it writes.
///
/// No reason to run git:
/// - a change in a folder the last `status --ignored=matching` listed as ignored whole (`.next/`,
///   `node_modules/`, `dist/`). git lists a folder whole only when nothing in it is tracked;
/// - a change in a nested repository or linked worktree (`.claude/worktrees/fix-7611`): the work tree
///   around it lists it as one untracked or ignored folder at most, whatever happens inside;
/// - a change in `.git/` other than its own folder (HEAD, index, packed-refs, FETCH_HEAD and config are
///   reported as that), `refs/` and `info/`: objects, logs, hooks, and linked worktrees' own state.
///
/// Everything else is, including the work tree's own folder and anything outside it. Folders the tree has
/// loaded are read again whatever this says: it decides only about git.
public struct GitEventFilter: Equatable, Sendable {
    /// The work tree's root, as FSEvents names it (symbolic links resolved).
    public var workTree: String
    /// Folders git ignores whole, from the work tree's root, without a trailing "/".
    public var ignoredFolders: Set<String>

    public init(workTree: String, ignoredFolders: Set<String> = []) {
        self.workTree = workTree.count > 1 && workTree.hasSuffix("/") ? String(workTree.dropLast()) : workTree
        self.ignoredFolders = ignoredFolders
    }

    /// From a refresh's snapshot: its root (or `workTree`, the same folder as FSEvents names it) and the
    /// folders it lists as ignored whole.
    public init(snapshot: GitSnapshot, workTree: String? = nil) {
        let ignored = snapshot.wholeFolders.filter { $0.value == .ignored }.keys
        self.init(workTree: workTree ?? snapshot.root, ignoredFolders: Set(ignored))
    }

    /// What in `.git/` counts, by the first name below it. The folder itself counts too.
    static let gitState: Set<String> = ["HEAD", "index", "packed-refs", "FETCH_HEAD", "config", "refs", "info"]

    /// Whether a change at `path` (a folder, as FSEvents reports them, or a file) can change git's status.
    /// `isRepository` tells whether a folder below the work tree is a nested repository or linked worktree
    /// (`isNestedRepository`, through a cache): it is asked about each folder from the top down, only when
    /// nothing cheaper has decided.
    public func matters(_ path: String, isRepository: (String) -> Bool = { _ in false }) -> Bool {
        let path = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard path.hasPrefix(workTree + "/") else { return true } // the work tree itself, or outside it
        let relative = path.dropFirst(workTree.count + 1)
        let names = relative.split(separator: "/")
        guard let first = names.first else { return true }
        if first == ".git" {
            guard names.count > 1 else { return true }
            return Self.gitState.contains(String(names[1]))
        }
        var folders: [String] = []
        var folder = ""
        for name in names {
            if !folder.isEmpty { folder.append("/") }
            folder.append(contentsOf: name)
            if ignoredFolders.contains(folder) { return false }
            folders.append(folder)
        }
        for folder in folders where isRepository(workTree + "/" + folder) { return false }
        return true
    }

    /// Whether `folder` is a repository of its own or a linked worktree: it has a `.git` folder, or a `.git`
    /// file naming a folder that is not a submodule's (`…/.git/modules/…`, whose changes the work tree
    /// around it does show).
    public static func isNestedRepository(_ folder: String, fileManager: FileManager = .default) -> Bool {
        let dotGit = folder + "/.git"
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit, isDirectory: &isFolder) else { return false }
        if isFolder.boolValue { return true }
        guard let handle = FileHandle(forReadingAtPath: dotGit) else { return false }
        defer { try? handle.close() }
        let text = String(decoding: handle.readData(ofLength: 4096), as: UTF8.self)
        guard text.hasPrefix("gitdir:") else { return false }
        return !text.contains("/modules/")
    }
}

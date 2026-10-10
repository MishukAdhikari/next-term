import Foundation
import Testing
@testable import NextTermCore

@Suite struct GitEventFilterTests {
    let root = "/Users/me/shop"

    func z(_ records: [String]) -> Data { Data(records.joined(separator: "\0").utf8 + [0]) }

    /// A Next.js project as `status --ignored=matching` lists it: `.next/`, `node_modules/` and `dist/` ignored whole,
    /// an ignored log file, and an untracked folder.
    var filter: GitEventFilter {
        let status = z([
            "# branch.oid 1234567890abcdef1234567890abcdef12345678", "# branch.head main",
            "1 .M N... 100644 100644 100644 aaa bbb src/app.tsx",
            "? scratch/", "! .next/", "! node_modules/", "! dist/", "! debug.log", "! packages/ui/node_modules/",
        ])
        return GitEventFilter(snapshot: GitSnapshot.parse(root: root, status: status, numstat: Data()))
    }

    /// FSEvents names folders, with a trailing "/".
    func matters(_ relative: String, repositories: Set<String> = []) -> Bool {
        filter.matters(root + "/" + relative + "/") { repositories.contains($0) }
    }

    @Test func foldersGitIgnoresGiveNoRefresh() {
        #expect(filter.ignoredFolders == [".next", "node_modules", "dist", "packages/ui/node_modules"])
        #expect(!matters(".next"))
        #expect(!matters(".next/cache/webpack/client-development"))
        #expect(!matters("node_modules/react/cjs"))
        #expect(!matters("dist"))
        #expect(!matters("packages/ui/node_modules/.cache"))
        // Only whole folders: a name that starts the same is another folder, and an ignored file's folder can
        // hold tracked files too.
        #expect(matters(".nextra"))
        #expect(matters("distribution"))
        #expect(matters("packages/ui"))
        #expect(matters("scratch")) // untracked: its files' line counts are shown
    }

    @Test func trackedFoldersAndTheRootDo() {
        #expect(matters("src"))
        #expect(matters("src/components/cart"))
        #expect(filter.matters(root + "/"))
        #expect(filter.matters(root))
        // Without the trailing "/" too, as a file event would name it.
        #expect(filter.matters(root + "/src/app.tsx"))
        #expect(!filter.matters(root + "/.next/trace"))
        // Outside the work tree, as for a watcher on a repository's git folder elsewhere: never dropped.
        #expect(filter.matters("/Users/me/other/.git/objects/ab/"))
        #expect(filter.matters("/Users/me/shop-old/src/"))
    }

    @Test func insideGitOnlyItsStateCounts() {
        // The folder itself is reported for HEAD, index, packed-refs, FETCH_HEAD and config.
        #expect(matters(".git"))
        #expect(filter.matters(root + "/.git/HEAD"))
        #expect(filter.matters(root + "/.git/index"))
        #expect(filter.matters(root + "/.git/packed-refs"))
        #expect(matters(".git/refs"))
        #expect(matters(".git/refs/heads"))
        #expect(matters(".git/refs/remotes/origin/feature"))
        #expect(matters(".git/info")) // info/exclude ignores files too
        #expect(!matters(".git/objects"))
        #expect(!matters(".git/objects/3f"))
        #expect(!matters(".git/objects/pack"))
        #expect(!matters(".git/logs"))
        #expect(!matters(".git/logs/refs/heads"))
        #expect(!matters(".git/worktrees/fix-7611")) // a linked worktree's own HEAD and index
        #expect(!matters(".git/modules/vendor/lib/objects/12"))
        #expect(!matters(".git/hooks"))
        #expect(!filter.matters(root + "/.git/index.lock")) // its rename to index is what counts
        #expect(!matters(".git/lfs/tmp"))
        // A folder that only starts with .git is an ordinary one.
        #expect(matters(".github/workflows"))
        #expect(matters(".gitlab"))
    }

    @Test func nestedWorktreesAndRepositoriesGiveNoRefresh() {
        let nested: Set = [root + "/.claude/worktrees/fix-7611", root + "/vendor/forked-lib"]
        #expect(!matters(".claude/worktrees/fix-7611", repositories: nested))
        #expect(!matters(".claude/worktrees/fix-7611/src/app", repositories: nested))
        #expect(!matters(".claude/worktrees/fix-7611/.next/cache", repositories: nested))
        #expect(!matters("vendor/forked-lib/.git/objects/aa", repositories: nested))
        // A worktree being added or removed changes the folder above it, which still counts.
        #expect(matters(".claude/worktrees", repositories: nested))
        #expect(matters(".claude", repositories: nested))
        #expect(matters("vendor", repositories: nested))
        // The work tree itself is never asked about.
        var asked: [String] = []
        _ = filter.matters(root + "/src/components/") { asked.append($0); return false }
        #expect(asked == [root + "/src", root + "/src/components"])
        // An ignored folder is dropped before any folder is looked at.
        asked = []
        _ = filter.matters(root + "/node_modules/react/") { asked.append($0); return false }
        _ = filter.matters(root + "/.git/objects/3f/") { asked.append($0); return false }
        #expect(asked.isEmpty)
    }

    @Test func noSnapshotDropsNothingButGit() {
        let bare = GitEventFilter(workTree: root)
        #expect(bare.matters(root + "/.next/"))
        #expect(bare.matters(root + "/.git/"))
        #expect(!bare.matters(root + "/.git/objects/3f/"))
        // A trailing "/" on the work tree is the same work tree.
        #expect(GitEventFilter(workTree: root + "/", ignoredFolders: ["dist"]).matters(root + "/dist/") == false)
    }

    @Test func nestedRepositoriesOnDisk() throws {
        let base = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("nt-eventfilter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        for folder in ["repo/.git", "repo/plain", "repo/inner/.git", "repo/wt", "repo/sub", "repo/odd"] {
            try fm.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try "gitdir: \(base.path)/repo/.git/worktrees/wt\n".write(to: base.appendingPathComponent("repo/wt/.git"), atomically: true, encoding: .utf8)
        try "gitdir: ../.git/modules/sub\n".write(to: base.appendingPathComponent("repo/sub/.git"), atomically: true, encoding: .utf8)
        try "not a git file".write(to: base.appendingPathComponent("repo/odd/.git"), atomically: true, encoding: .utf8)
        let path = { (name: String) in base.appendingPathComponent("repo/" + name).path }
        #expect(GitEventFilter.isNestedRepository(path("inner"))) // a repository of its own
        #expect(GitEventFilter.isNestedRepository(path("wt"))) // a linked worktree
        #expect(!GitEventFilter.isNestedRepository(path("sub"))) // a submodule: its changes show in the parent's status
        #expect(!GitEventFilter.isNestedRepository(path("plain")))
        #expect(!GitEventFilter.isNestedRepository(path("odd")))
        #expect(!GitEventFilter.isNestedRepository(path("missing")))
    }

    @Test func gitRunsAreCountedByFolder() throws {
        guard let git = GitRunner.locateGit() else { return }
        let base = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("nt-runcount-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("repo"), withIntermediateDirectories: true)
        let repo = base.appendingPathComponent("repo").path
        #expect(GitRunner.runs(in: base.path) == 0)
        _ = GitRunner.run(git, ["-C", repo, "init", "-q"], timeout: 10)
        _ = GitRunner.snapshot(for: repo, git: git) // rev-parse, status, and hash-object for the empty tree, diff-index
        #expect(GitRunner.runs(in: repo) >= 4)
        #expect(GitRunner.runs(in: base.path) == GitRunner.runs(in: repo)) // below a folder counts for it
        #expect(GitRunner.runs(in: repo + "-other") == 0)
        #expect(GitRunner.runs(in: repo + "/src") == 0)
    }
}

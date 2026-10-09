import Foundation
import Testing
@testable import NextTermCore

/// Open in New Worktree: the folder's place and name, the `git worktree add` per target, the window's title,
/// the agent guard's words, `.worktreeinclude`, and Remove Worktree's refusals. Git runs in temporary
/// repositories only.
@Suite struct WorktreesTests {
    // MARK: the target

    @Test func addArgumentsPerTarget() {
        let path = "/Users/me/Code/xCloud-wt-7027-sso"
        #expect(WorktreeTarget.branch("fix/7027-sso").addArguments(path: path) == ["worktree", "add", path, "fix/7027-sso"])
        // Remote-only: the local branch is made, tracking it; the remote's name may hold a "/".
        #expect(WorktreeTarget.remoteBranch(remote: "origin", branch: "rakib/new-panel", localExists: false).addArguments(path: path)
            == ["worktree", "add", "--track", "-b", "rakib/new-panel", path, "origin/rakib/new-panel"])
        #expect(WorktreeTarget.remoteBranch(remote: "my/fork", branch: "x", localExists: false).addArguments(path: path)
            == ["worktree", "add", "--track", "-b", "x", path, "my/fork/x"])
        // A local branch of that name is used, as Checkout does.
        #expect(WorktreeTarget.remoteBranch(remote: "origin", branch: "rakib/new-panel", localExists: true).addArguments(path: path)
            == ["worktree", "add", path, "rakib/new-panel"])
        #expect(WorktreeTarget.revision("refs/tags/v2.9.0", shown: "v2.9.0").addArguments(path: path) == ["worktree", "add", "--detach", path, "refs/tags/v2.9.0"])
        #expect(WorktreeTarget.newBranch("feat/x", base: "main", noTrack: false).addArguments(path: path) == ["worktree", "add", "-b", "feat/x", path, "main"])
        #expect(WorktreeTarget.newBranch("feat/x", base: "origin/main", noTrack: true).addArguments(path: path)
            == ["worktree", "add", "--no-track", "-b", "feat/x", path, "origin/main"])
        #expect(WorktreeTarget.newBranch("feat/x", base: nil, noTrack: false).addArguments(path: path) == ["worktree", "add", "-b", "feat/x", path, "HEAD"])
    }

    @Test func aTypedRevisionIsPinnedToTheCommitGitFound() {
        let sha = "4f2a9c1d0b7e6a5f4e3d2c1b0a9f8e7d6c5b4a39"
        #expect(WorktreeTarget.commit(in: sha + "\n") == sha)
        #expect(WorktreeTarget.commit(in: "warning: refname 'main' is ambiguous.\n" + sha + "\n") == sha)
        #expect(WorktreeTarget.commit(in: "fatal: bad revision\n") == nil)
        #expect(WorktreeTarget.commit(in: "") == nil)
        // What is typed is never read as an option.
        #expect(BranchName.revisionProblem("v1.2.0") == nil)
        #expect(BranchName.revisionProblem("main~3") == nil)
        #expect(BranchName.revisionProblem("-q") == "A revision can’t start with “-”.")
        #expect(BranchName.revisionProblem("a b") == "No spaces in a revision.")
    }

    @Test func whatTheTargetIsCalled() {
        #expect(WorktreeTarget.branch("fix/7027-sso").shortName == "7027-sso")
        #expect(WorktreeTarget.branch("main").shortName == "main")
        #expect(WorktreeTarget.remoteBranch(remote: "my/fork", branch: "rakib/new-panel", localExists: false).shortName == "new-panel")
        #expect(WorktreeTarget.revision("refs/tags/v2.9.0", shown: "v2.9.0").shortName == "v2.9.0")
        #expect(WorktreeTarget.revision("refs/tags/release/2.9", shown: "release/2.9").shortName == "release-2.9")
        let sha = "4f2a9c1d0b7e6a5f4e3d2c1b0a9f8e7d6c5b4a39"
        #expect(WorktreeTarget.revision(sha, shown: sha).shortName == "4f2a9c1")
        #expect(WorktreeTarget.revision("main~3", shown: "main~3").shortName == "main~3")
        #expect(WorktreeTarget.newBranch("feat/new-idea", base: "main", noTrack: false).shortName == "new-idea")
        // The branch it is on, and what the sheet names.
        #expect(WorktreeTarget.remoteBranch(remote: "origin", branch: "a/b", localExists: false).branchName == "a/b")
        #expect(WorktreeTarget.remoteBranch(remote: "origin", branch: "a/b", localExists: false).shown == "origin/a/b")
        #expect(WorktreeTarget.revision("refs/tags/v1", shown: "v1").branchName == nil)
        #expect(WorktreeTarget.newBranch("feat/x", base: "main", noTrack: false).shown == "feat/x")
        #expect(WorktreeFolder.sheetTitle(WorktreeTarget.branch("fix/7027-sso")) == "Open fix/7027-sso in a New Worktree")
    }

    // MARK: where it goes

    @Test func theMainCheckoutAndTheRepositorysName() {
        #expect(WorktreeFolder.mainCheckout(commonDir: "/Users/me/Code/xCloud/.git") == "/Users/me/Code/xCloud")
        #expect(WorktreeFolder.mainCheckout(commonDir: "/Users/me/Code/app.git") == "/Users/me/Code/app.git") // bare
        #expect(WorktreeFolder.repositoryName(mainCheckout: "/Users/me/Code/xCloud") == "xCloud")
        #expect(WorktreeFolder.repositoryName(mainCheckout: "/Users/me/Code/app.git") == "app")
    }

    @Test func theLocationRule() {
        let main = "/Users/me/Code/xCloud"
        // Beside the main checkout, never beside a linked worktree the window shows: the main checkout is all it is given.
        #expect(WorktreeFolder.place(mainCheckout: main, location: .beside, claudeWorktreesIgnored: true) == .init(folder: "/Users/me/Code", prefix: "xCloud-wt-"))
        #expect(WorktreeFolder.place(mainCheckout: main, location: .claudeWorktrees, claudeWorktreesIgnored: true)
            == .init(folder: main + "/.claude/worktrees", prefix: ""))
        // Asked for, but the repository doesn't ignore the folder: beside it after all.
        #expect(WorktreeFolder.place(mainCheckout: main, location: .claudeWorktrees, claudeWorktreesIgnored: false) == .init(folder: "/Users/me/Code", prefix: "xCloud-wt-"))
        // A bare repository has no checkout to nest in.
        #expect(WorktreeFolder.place(mainCheckout: "/srv/app.git", location: .claudeWorktrees, claudeWorktreesIgnored: true) == .init(folder: "/srv", prefix: "app-wt-"))
        #expect(WorktreeLocation(rawValue: "beside") == .beside && WorktreeLocation(rawValue: "claudeWorktrees") == .claudeWorktrees)
    }

    @Test func thePrefillAndItsNumbers() {
        var taken: Set<String> = []
        func name(_ prefix: String, _ short: String) -> String { WorktreeFolder.suggestedName(prefix: prefix, short: short) { taken.contains($0) } }
        #expect(name("xCloud-wt-", "7027-sso") == "xCloud-wt-7027-sso")
        taken = ["xCloud-wt-7027-sso"]
        #expect(name("xCloud-wt-", "7027-sso") == "xCloud-wt-7027-sso-2")
        taken = ["xCloud-wt-7027-sso", "xCloud-wt-7027-sso-2"]
        #expect(name("xCloud-wt-", "7027-sso") == "xCloud-wt-7027-sso-3")
        // The short part never starts the folder with "." or "-", and a "/" becomes "-".
        #expect(name("", ".hidden") == "hidden" && name("", "-x") == "x" && name("", "a/b") == "a-b")
        #expect(name("", "") == "worktree")
    }

    @Test func namesAndTheirReasons() {
        let folder = "/Users/me/Code"
        let taken: Set<String> = ["xCloud-wt-7027-sso"]
        let registered: Set<String> = ["xCloud-wt-gone"]
        func problem(_ name: String) -> String? {
            WorktreeFolder.problem(name, in: folder, isTaken: { taken.contains($0) }, isRegistered: { registered.contains($0) }, home: "/Users/me")
        }
        #expect(problem("xCloud-wt-aichat2") == nil)
        #expect(problem("") == "The folder needs a name.")
        #expect(problem("   ") == "The folder needs a name.")
        #expect(problem("xCloud-wt-7027-sso") == "Already exists in ~/Code")
        #expect(problem("xCloud-wt-gone") == "Git still lists a worktree there whose folder is gone: choose Remove Worktree… on its row first.")
        #expect(problem(".hidden") == "A folder name can’t start with “.”.")
        #expect(problem("..") == "A folder name can’t start with “.”.")
        #expect(problem("-x") == "A folder name can’t start with “-”.")
        #expect(problem("a:b") == "A folder name can’t contain “:”.")
        #expect(problem(String(repeating: "a", count: 256)) == "That name is too long for a folder.")
        #expect(problem(String(repeating: "é", count: 128)) == "That name is too long for a folder.") // 256 bytes
        #expect(problem(String(repeating: "a", count: 255)) == nil)
        // A "/" typed by habit becomes "-", as it is typed; spaces at either end go.
        #expect(WorktreeFolder.normalized("fix/7027") == "fix-7027")
        #expect(WorktreeFolder.finalName("  my folder ") == "my folder")
    }

    @Test func whatTheSheetSays() {
        #expect(WorktreeFolder.sheetInfo(checkout: "xCloud", includes: false)
            == "xCloud and its changes stay as they are. The new folder gets committed files only: no .env, vendor/ or node_modules/. List files in .worktreeinclude to copy them.")
        #expect(WorktreeFolder.sheetInfo(checkout: "next-term", includes: true)
            == "next-term and its changes stay as they are. The new folder gets committed files, and copies of the ignored files .worktreeinclude lists.")
        #expect(WorktreeFolder.pathLine(folder: "/Users/me/Code", name: "xCloud-wt-7027-sso", home: "/Users/me") == "~/Code/xCloud-wt-7027-sso")
    }

    /// The folder is made before git runs, so one that appeared since the sheet checked is never taken for
    /// the new worktree (git leaves a branch behind when it finds the folder there).
    @Test func theFolderIsClaimedBeforeGitRuns() throws {
        let base = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-claim-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let path = base + "/.claude/worktrees/7027-sso"
        #expect(WorktreeFolder.claim(path, home: "/nowhere") == nil)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: path)) == [])
        #expect(WorktreeFolder.claim(path, home: "/nowhere") == "Already exists in \(base)/.claude/worktrees")
        WorktreeFolder.release(path)
        #expect(!WorktreeFolder.exists(path))
        // Only an empty folder goes: never one git (or anyone) has put something in.
        #expect(WorktreeFolder.claim(path, home: "/nowhere") == nil)
        try "x".write(toFile: path + "/a.txt", atomically: true, encoding: .utf8)
        WorktreeFolder.release(path)
        #expect(FileManager.default.fileExists(atPath: path + "/a.txt"))
    }

    @Test func whetherTheRepositoryIgnoresClaudeWorktrees() throws {
        guard let git = GitRunner.locateGit() else { return }
        let repo = try TemporaryRepository(git: git)
        defer { repo.remove() }
        #expect(!WorktreeFolder.ignoresClaudeWorktrees(mainCheckout: repo.path, git: git))
        try repo.write(".gitignore", ".claude/worktrees/\n")
        #expect(WorktreeFolder.ignoresClaudeWorktrees(mainCheckout: repo.path, git: git))
        try repo.write(".gitignore", ".claude/\n")
        #expect(WorktreeFolder.ignoresClaudeWorktrees(mainCheckout: repo.path, git: git))
        try repo.write(".gitignore", "")
        try repo.write(".git/info/exclude", ".claude/worktrees\n")
        #expect(WorktreeFolder.ignoresClaudeWorktrees(mainCheckout: repo.path, git: git))
    }

    // MARK: the window

    @Test func theWindowsTitle() {
        #expect(WorktreeWindow.title(repository: "xCloud", folder: "xCloud-wt-7027-sso") == "xCloud ▸ 7027-sso")
        #expect(WorktreeWindow.title(repository: "xCloud", folder: "xcloud-wt-aichat") == "xCloud ▸ aichat") // his own folders are lower case
        #expect(WorktreeWindow.title(repository: "next-term", folder: "n-worktree") == "next-term ▸ n-worktree")
        #expect(WorktreeWindow.title(repository: "xCloud", folder: "xCloud-wt-") == "xCloud ▸ xCloud-wt-")
    }

    @Test func aLinkedWorktreeKnowsItsRepository() throws {
        guard let git = GitRunner.locateGit() else { return }
        let repo = try TemporaryRepository(git: git)
        defer { repo.remove() }
        let linked = repo.base + "/xCloud-wt-7027-sso", nested = repo.path + "/.claude/worktrees/side"
        repo.run(["worktree", "add", "-q", "-b", "fix/7027-sso", linked])
        repo.run(["worktree", "add", "-q", "-b", "side", nested])
        #expect(WorktreeWindow.repository(ofLinkedWorktree: linked) == .init(name: "xCloud", mainCheckout: repo.path))
        #expect(WorktreeWindow.repository(ofLinkedWorktree: nested)?.name == "xCloud")
        #expect(WorktreeWindow.repository(ofLinkedWorktree: repo.path) == nil) // the main checkout
        #expect(WorktreeWindow.repository(ofLinkedWorktree: repo.base) == nil) // no repository
    }

    // MARK: the guard

    @Test func theGuardsWordsForEveryCaller() {
        let claude = AgentGuard.Agent(program: "claude", tab: "✳ Slack thread discussion")
        let codex = AgentGuard.Agent(program: "codex", tab: "v2.9.0 / #7027 session")
        #expect(AgentGuard.title([claude]) == "Claude Code is working in this folder")
        #expect(AgentGuard.title([AgentGuard.Agent(program: "", tab: "zsh")]) == "An agent is working in this folder")
        #expect(AgentGuard.title([claude, codex]) == "2 agents are working in this folder")
        #expect(AgentGuard.info([claude], .switching(to: "fix/7027-sso"))
            == "In the tab “✳ Slack thread discussion”. Switching to fix/7027-sso changes the files under it.")
        #expect(AgentGuard.info([claude, codex], .switching(to: "fix/7027-sso"))
            == "Claude Code in “✳ Slack thread…” and Codex in “v2.9.0 / #7027 session”. Switching to fix/7027-sso changes the files under them.")
        let third = AgentGuard.Agent(program: "claude", tab: "tests")
        #expect(AgentGuard.info([claude, codex, third], .updating).hasPrefix("Claude Code in “✳ Slack thread…”, Codex in “v2.9.0 / #7027 session” and Claude Code in “tests”. Updating"))
        #expect(AgentGuard.info([claude], .continuing) == "In the tab “✳ Slack thread discussion”. Continuing changes the files under it.")
        #expect(AgentGuard.info([claude], .skipping).contains("Skipping changes the files"))
        #expect(AgentGuard.info([claude], .switching(to: nil)).contains("Switching branches changes the files"))
        // Each caller's button, and the worktree button only for a switch.
        let anyway: [(AgentGuard.Action, String)] = [(.switching(to: "x"), "Switch Anyway"), (.updating, "Update Anyway"), (.merging, "Merge Anyway"),
                                                      (.rebasing, "Rebase Anyway"), (.continuing, "Continue Anyway"), (.skipping, "Skip Anyway"),
                                                      (.aborting, "Abort Anyway")]
        for (action, label) in anyway {
            #expect(AgentGuard.anyway(action) == label)
            #expect(AgentGuard.buttons(action, worktree: false) == [label, "Cancel"])
        }
        #expect(AgentGuard.buttons(.switching(to: "x"), worktree: true) == ["Open in New Worktree…", "Switch Anyway", "Cancel"])
        #expect(AgentGuard.buttons(.updating, worktree: true) == ["Update Anyway", "Cancel"]) // git can't check its branch out twice
    }

    // MARK: .worktreeinclude

    @Test func onlyIgnoredFilesItListsInsideTheRepository() {
        let listed = [".env", "config/local.json", "untracked.txt", "../outside", "/etc/passwd", "a/../../b", ".git/config", "", "./x"]
        let ignored: Set<String> = [".env", "config/local.json", "../outside", "/etc/passwd", "a/../../b", ".git/config", "./x"]
        #expect(WorktreeInclude.select(listed: listed, ignored: ignored) == [".env", "config/local.json"])
    }

    @Test func copiesRegularFilesAndNeverThroughALink() throws {
        let base = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-include-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let source = base + "/src", destination = base + "/dst", outside = base + "/outside"
        let fm = FileManager.default
        for folder in [source + "/config", source + "/linked", destination + "/escape", outside] { try fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        try "SECRET=1\n".write(toFile: source + "/.env", atomically: true, encoding: .utf8)
        try "{}\n".write(toFile: source + "/config/local.json", atomically: true, encoding: .utf8)
        try "out\n".write(toFile: outside + "/secret", atomically: true, encoding: .utf8)
        // A link in the source to a file outside it, and a folder in the destination that is a link out.
        try fm.createSymbolicLink(atPath: source + "/link.env", withDestinationPath: outside + "/secret")
        try fm.removeItem(atPath: destination + "/escape")
        try fm.createSymbolicLink(atPath: destination + "/escape", withDestinationPath: outside)
        try "x\n".write(toFile: source + "/escape-file", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: source + "/escape", withIntermediateDirectories: true)
        try "y\n".write(toFile: source + "/escape/inside", atomically: true, encoding: .utf8)
        // Already there: kept.
        try "mine\n".write(toFile: destination + "/kept.txt", atomically: true, encoding: .utf8)
        try "theirs\n".write(toFile: source + "/kept.txt", atomically: true, encoding: .utf8)

        let result = WorktreeInclude.copy([".env", "config/local.json", "link.env", "escape/inside", "kept.txt", "missing"], from: source, to: destination)
        #expect(result.copied == [".env", "config/local.json"])
        #expect(result.skipped == ["link.env", "escape/inside", "kept.txt", "missing"])
        #expect((try? String(contentsOfFile: destination + "/.env", encoding: .utf8)) == "SECRET=1\n")
        #expect((try? String(contentsOfFile: destination + "/config/local.json", encoding: .utf8)) == "{}\n")
        #expect(!fm.fileExists(atPath: outside + "/inside")) // nothing written through the link
        #expect((try? String(contentsOfFile: destination + "/kept.txt", encoding: .utf8)) == "mine\n")
    }

    @Test func theFilesARepositorysWorktreeIncludeMatches() throws {
        guard let git = GitRunner.locateGit() else { return }
        let repo = try TemporaryRepository(git: git)
        defer { repo.remove() }
        #expect(!WorktreeInclude.exists(in: repo.path))
        #expect(WorktreeInclude.files(in: repo.path, git: git).isEmpty)
        try repo.write(".gitignore", ".env\nnode_modules/\n")
        try repo.write(".env", "SECRET=1\n")
        try repo.write("node_modules/x/index.js", "m\n")
        try repo.write("notes.txt", "untracked, not ignored\n")
        try repo.write(".worktreeinclude", ".env\nnotes.txt\n")
        #expect(WorktreeInclude.exists(in: repo.path))
        #expect(WorktreeInclude.files(in: repo.path, git: git) == [".env"]) // listed and ignored; notes.txt is only listed
        try repo.write(".worktreeinclude", ".env\nnode_modules/\n")
        #expect(WorktreeInclude.files(in: repo.path, git: git) == [".env", "node_modules/x/index.js"])
    }

    // MARK: Remove Worktree…

    @Test func removeWorktreesRefusals() {
        typealias F = WorktreeRemoval.Facts
        #expect(WorktreeRemoval.verdict(F()) == .remove)
        #expect(WorktreeRemoval.verdict(F(isMain: true)) == .refuse("It is the repository’s main checkout.", goTo: false))
        #expect(WorktreeRemoval.verdict(F(isMissing: true)) == .forget(losing: nil))
        #expect(WorktreeRemoval.verdict(F(agents: [AgentGuard.Agent(program: "claude", tab: "✳ Fix it")]))
            == .refuse("Claude Code is working in it, in the tab “✳ Fix it”.", goTo: true))
        #expect(WorktreeRemoval.verdict(F(windows: ["xCloud ▸ 7027-sso"])) == .refuse("The window “xCloud ▸ 7027-sso” is open on it.", goTo: true))
        #expect(WorktreeRemoval.verdict(F(tabs: ["zsh"])) == .refuse("The tab “zsh” is in it.", goTo: true))
        let holder = LockHolder(pid: 7639, started: nil, program: "claude")
        #expect(WorktreeRemoval.verdict(F(lockReason: "claude agent a (pid 7639)", holder: holder, holderAlive: true))
            == .refuse("Claude Code (pid 7639) holds it.", goTo: false))
        #expect(WorktreeRemoval.verdict(F(lockReason: "claude agent a (pid 7639)", holder: holder, holderAlive: false))
            == .unlockFirst("It is locked by Claude Code (pid 7639), which has ended."))
        #expect(WorktreeRemoval.verdict(F(lockReason: "moving it to the new disk")) == .unlockFirst("It is locked: moving it to the new disk."))
        #expect(WorktreeRemoval.verdict(F(lockReason: "")) == .unlockFirst("It is locked, with no reason given."))
        #expect(WorktreeRemoval.verdict(F(changedFiles: 3)) == .refuse("It has 3 changed files.", goTo: false))
        #expect(WorktreeRemoval.verdict(F(changedFiles: 1)) == .refuse("It has 1 changed file.", goTo: false))
        // A missing folder that is locked isn't forgotten: git keeps a locked entry.
        #expect(WorktreeRemoval.verdict(F(isMissing: true, lockReason: "on a disk that is out")) == .unlockFirst("It is locked: on a disk that is out."))
        // The first reason wins: an agent before the changes it made.
        #expect(WorktreeRemoval.verdict(F(agents: [AgentGuard.Agent(program: "codex", tab: "t")], changedFiles: 4))
            == .refuse("Codex is working in it, in the tab “t”.", goTo: true))
        // What git is in the middle of there goes with it, and so does a commit no branch or tag has.
        let rebase = GitInProgress.rebase(branch: "fix/x", onto: nil, step: 2, total: 5)
        #expect(WorktreeRemoval.verdict(F(inProgress: rebase))
            == .refuse("A rebase of fix/x is in progress there: finish or abort it there first.", goTo: false))
        #expect(WorktreeRemoval.verdict(F(inProgress: .merge, changedFiles: 2))
            == .refuse("A merge is in progress there: finish or abort it there first.", goTo: false))
        let sha = "4f2a9c1d0b7e6a5f4e3d2c1b0a9f8e7d6c5b4a39"
        #expect(WorktreeRemoval.verdict(F(headOnNoBranch: true, head: sha))
            == .refuse("It is detached at 4f2a9c1, a commit no branch or tag has: removing the worktree would lose it. New Branch… there keeps it.",
                       goTo: false))
        #expect(WorktreeRemoval.verdict(F(changedFiles: 1, headOnNoBranch: true, head: sha)) == .refuse("It has 1 changed file.", goTo: false))
        #expect(WorktreeRemoval.verdict(F(head: sha)) == .remove)
        #expect(WorktreeRemoval.verdict(F(isMissing: true, headOnNoBranch: true, head: sha)) == .forget(losing: "4f2a9c1"))
        #expect(WorktreeRemoval.arguments(path: "/w") == ["worktree", "remove", "/w"]) // never --force
        // git status's entries: a rename's old path is no entry of its own.
        #expect(WorktreeRemoval.countStatus(Data(" M a.txt\0?? new.txt\0R  b.txt\0old b.txt\0".utf8)) == 3)
        #expect(WorktreeRemoval.countStatus(Data()) == 0)
    }

    @Test func whatRemoveAndForgetSayGoes() {
        #expect(WorktreeRemoval.removeInfo(branch: "fix/7027-sso", head: "4f2a9c1d0b")
            == "Its folder is deleted, with the ignored files in it. The branch fix/7027-sso stays, with its commits.")
        #expect(WorktreeRemoval.removeInfo(branch: nil, head: "4f2a9c1d0b")
            == "Its folder is deleted, with the ignored files in it. It is detached at 4f2a9c1, which a branch or tag keeps.")
        // Forgetting deletes git's record of it, and with it the worktree's HEAD and reflog: never "nothing on disk".
        #expect(WorktreeRemoval.forgetInfo(branch: "fix/x", losing: nil)
            == "Its folder is gone, but git still lists it, and keeps fix/x checked out there. Forgetting it deletes only git’s record of it.")
        #expect(WorktreeRemoval.forgetInfo(branch: nil, losing: "4f2a9c1")
            == "Its folder is gone, but git still lists it. Forgetting it deletes only git’s record of it. Its commit 4f2a9c1 is on no branch or tag and goes with it: make a branch at 4f2a9c1 first to keep it.")
    }

    @Test func aDetachedWorktreesCommitOnNoBranch() throws {
        guard let git = GitRunner.locateGit() else { return }
        let repo = try TemporaryRepository(git: git)
        defer { repo.remove() }
        let detached = repo.base + "/xCloud-wt-det"
        repo.run(["worktree", "add", "-q", "--detach", detached, "HEAD"])
        let head = { repo.output(["-C", detached, "rev-parse", "HEAD"]) }
        // At a commit main has: kept.
        #expect(!WorktreeRemoval.isOnNoBranch(head(), in: repo.path, git: git))
        // A commit made there: only the worktree has it.
        try "two\n".write(toFile: detached + "/a.txt", atomically: true, encoding: .utf8)
        repo.run(["-C", detached, "commit", "-qam", "Two"])
        let made = head()
        #expect(made.count == 40)
        #expect(WorktreeRemoval.isOnNoBranch(made, in: repo.path, git: git))
        // A tag keeps it, and so would a branch.
        repo.run(["tag", "keep", made])
        #expect(!WorktreeRemoval.isOnNoBranch(made, in: repo.path, git: git))
        // git can't say: not shown to be kept.
        #expect(WorktreeRemoval.isOnNoBranch(String(repeating: "0", count: 40), in: repo.path, git: git))
    }

    @Test func gitsAlreadyExistsIsItsOwnFailure() {
        #expect(GitOutput.classify("Preparing worktree (new branch 'b2')\nfatal: '/Users/me/Code/xCloud-wt-x' already exists")
            == .pathExists(path: "/Users/me/Code/xCloud-wt-x"))
        #expect(GitOutput.classify("fatal: a branch named 'b2' already exists") == nil)
    }
}

/// A repository of its own in a temporary folder, named xCloud, with one commit.
struct TemporaryRepository {
    let git: String
    let base: String
    var path: String { base + "/xCloud" }

    init(git: String) throws {
        self.git = git
        base = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-worktrees-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base + "/xCloud", withIntermediateDirectories: true)
        run(["init", "-q"])
        try write("a.txt", "hi\n")
        run(["add", "a.txt"])
        run(["commit", "-qm", "One"])
    }

    @discardableResult
    func run(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false",
                       "-c", "core.hooksPath=/dev/null"] + args
        p.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// What git prints, trimmed.
    func output(_ args: [String]) -> String {
        guard let data = GitRunner.run(git, ["-C", path] + args, timeout: 10) else { return "" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ name: String, _ text: String) throws {
        let url = URL(fileURLWithPath: path).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(atPath: base) }
}

import Foundation
import Testing
@testable import NextTermCore

/// Where agents work: the checkout holding a folder, the folder an agent works in, its session records'
/// tails, the 3 s hold, and who switched a branch. Fixtures are made here by hand.
@Suite struct AgentLocationTests {
    // xCloud's layout: the main checkout, worktrees nested in it under .claude/worktrees (one a subagent's),
    // and a sibling worktree beside it.
    let main = Checkout(path: "/Code/xCloud", head: .branch("fix/7611-3ds"), commit: "a1", isMain: true)
    let nested = Checkout(path: "/Code/xCloud/.claude/worktrees/pr-7050", head: .branch("fix/7027-sso"), commit: "b2")
    let subagent = Checkout(path: "/Code/xCloud/.claude/worktrees/agent-a39109cc", head: .branch("worktree-agent-a39109cc"), commit: "c3")
    let sibling = Checkout(path: "/Code/xCloud-7027-dev", head: .detached("d4e5f6a7b8c9"), commit: "d4e5f6a7b8c9")
    var all: [Checkout] { [main, nested, subagent, sibling] }

    @Test func theLongestCheckoutHoldingAFolder() {
        func path(_ folder: String) -> String? { AgentLocation.checkout(containing: folder, in: all)?.path }
        #expect(path("/Code/xCloud") == main.path)
        #expect(path("/Code/xCloud/app/Http") == main.path) // a cd in the main checkout is no move
        #expect(path("/Code/xCloud/.claude/worktrees/pr-7050") == nested.path)
        #expect(path("/Code/xCloud/.claude/worktrees/pr-7050/app") == nested.path) // nested, though inside xCloud
        #expect(path("/Code/xCloud/.claude/worktrees") == main.path)
        #expect(path("/Code/xCloud-7027-dev/src") == sibling.path)
        // A subagent's worktree is not the agent's place: the checkout around it is.
        #expect(path("/Code/xCloud/.claude/worktrees/agent-a39109cc/app") == main.path)
        // A submodule inside the main checkout counts as the main checkout.
        #expect(path("/Code/xCloud/vendor/sdk") == main.path)
        // Outside every checkout: a separate clone, another repository, a name that only starts the same.
        #expect(path("/Code/xCloud-copy") == nil)
        #expect(path("/Code/other") == nil)
        #expect(path("/Code") == nil)
    }

    @Test func subagentWorktrees() {
        #expect(AgentLocation.isSubagentWorktree("/r/.claude/worktrees/agent-a39109cc"))
        #expect(!AgentLocation.isSubagentWorktree("/r/.claude/worktrees/pr-7050"))
        #expect(!AgentLocation.isSubagentWorktree("/r/.claude/worktrees/agent-x")) // too short for an id
        #expect(!AgentLocation.isSubagentWorktree("/r/worktrees/agent-a39109cc"))
        #expect(!AgentLocation.isSubagentWorktree("/Code/agent-a39109cc"))
    }

    @Test func checkoutsFromTheWorktreeList() {
        let list = [Worktree(path: "/r", head: "aaa", branch: "main"),
                    Worktree(path: "/r/.claude/worktrees/x", head: "bbb", branch: nil),
                    Worktree(path: "/bare", head: nil, branch: nil, isBare: true),
                    Worktree(path: "/gone", head: "ccc", branch: "old", isPrunable: true),
                    Worktree(path: "/new", head: String(repeating: "0", count: 40), branch: "fresh")]
        let checkouts = AgentLocation.checkouts(list, canonical: { $0 }) { $0 == "/r/.claude/worktrees/x" }
        #expect(checkouts.map(\.path) == ["/r", "/r/.claude/worktrees/x", "/new"])
        #expect(checkouts[0].isMain && !checkouts[1].isMain)
        #expect(checkouts[0].head == .branch("main") && !checkouts[0].busy)
        #expect(checkouts[1].head == .detached("bbb") && checkouts[1].busy)
        #expect(checkouts[2].commit == nil && checkouts[2].head == .branch("fresh")) // before the first commit
        #expect(checkouts[0].title == "r" && checkouts[1].title == "worktree x")
        #expect(CheckoutHead.detached("abc1234def").name == "detached at abc1234")
    }

    @Test func eachCheckoutsOwnGitFolderAndWhatItIsInTheMiddleOf() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nt-location-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let fm = FileManager.default
        let admin = base + "/repo/.git/worktrees/pr-7050"
        try fm.createDirectory(atPath: admin, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/repo/.claude/worktrees/pr-7050", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/sibling", withIntermediateDirectories: true)
        try "gitdir: \(admin)\n".write(toFile: base + "/repo/.claude/worktrees/pr-7050/.git", atomically: true, encoding: .utf8)
        try "gitdir: ../repo/.git/worktrees/pr-7050\n".write(toFile: base + "/sibling/.git", atomically: true, encoding: .utf8)
        #expect(AgentLocation.gitDir(ofCheckout: base + "/repo") == base + "/repo/.git")
        #expect(AgentLocation.gitDir(ofCheckout: base + "/repo/.claude/worktrees/pr-7050") == admin)
        #expect(AgentLocation.gitDir(ofCheckout: base + "/sibling").map(canonicalPath) == canonicalPath(admin))
        #expect(AgentLocation.gitDir(ofCheckout: base) == nil)

        // In-progress files are the worktree's own: a rebase there is not the main checkout's.
        #expect(!AgentLocation.isBusy(gitDir: admin))
        for marker in ["rebase-merge", "rebase-apply"] { // rebase -i; rebase or git am
            try fm.createDirectory(atPath: admin + "/" + marker, withIntermediateDirectories: true)
            #expect(AgentLocation.isBusy(gitDir: admin) && !AgentLocation.isBusy(gitDir: base + "/repo/.git"))
            try fm.removeItem(atPath: admin + "/" + marker)
        }
        for file in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"] {
            try "x\n".write(toFile: admin + "/" + file, atomically: true, encoding: .utf8)
            #expect(AgentLocation.isBusy(gitDir: admin), "\(file)")
            try fm.removeItem(atPath: admin + "/" + file)
        }
    }

    /// With git: a worktree nested in the main checkout and a sibling one share its common git folder; a
    /// separate clone has its own. Each checkout's branch, and a merge in progress in one of them only.
    @Test func checkoutsOfOneRepositoryShareItsCommonFolder() throws {
        guard let git = GitRunner.locateGit() else { return }
        let base = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-checkouts-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let main = base + "/xCloud", nested = main + "/.claude/worktrees/pr-7050", sibling = base + "/xCloud-7027-dev", clone = base + "/copy"
        try FileManager.default.createDirectory(atPath: main, withIntermediateDirectories: true)
        func sh(_ args: String..., in dir: String = main) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", dir, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        sh("init", "-q")
        sh("commit", "-q", "--allow-empty", "-m", "One")
        sh("worktree", "add", "-q", "-b", "fix/7027-sso", nested)
        sh("worktree", "add", "-q", "--detach", sibling)
        sh("clone", "-q", main, clone, in: base)
        let repository = AgentLocation.repository(of: nested + "/.", git: git)
        #expect(repository?.commonDir == main + "/.git" && repository?.root == nested)
        #expect(AgentLocation.repository(of: sibling, git: git)?.commonDir == main + "/.git")
        #expect(AgentLocation.repository(of: clone, git: git)?.commonDir == clone + "/.git") // another repository
        let checkouts = AgentLocation.checkouts(in: nested, git: git) ?? []
        func checkout(_ path: String) -> Checkout? { checkouts.first { $0.path == path } }
        #expect(checkouts.count == 3 && checkouts.first?.path == main) // the main checkout first, then git's order
        #expect(checkout(main)?.isMain == true && checkout(main)?.head == .branch("main"))
        #expect(checkout(nested)?.isMain == false && checkout(nested)?.head == .branch("fix/7027-sso"))
        if case .detached = checkout(sibling)?.head {} else { Issue.record("the sibling is detached: \(String(describing: checkout(sibling)?.head))") }
        // A folder in the nested worktree is in it, not in the main checkout around it; the clone is in none.
        #expect(AgentLocation.checkout(containing: nested + "/app", in: checkouts)?.path == nested)
        #expect(AgentLocation.checkout(containing: clone, in: checkouts) == nil)
        // A merge in the sibling is the sibling's own.
        let admin = AgentLocation.gitDir(ofCheckout: sibling) ?? ""
        try "x\n".write(toFile: admin + "/MERGE_HEAD", atomically: true, encoding: .utf8)
        let busy = AgentLocation.checkouts(in: main, git: git) ?? []
        #expect(busy.filter(\.busy).map(\.path) == [sibling])
    }

    @Test func theNewerOfTheProcessFolderAndTheRecord() {
        let start = Date(timeIntervalSince1970: 1000)
        let moved = Date(timeIntervalSince1970: 1100)
        func folder(_ record: RecordedFolder?, process: String? = "/r") -> String? {
            AgentLocation.folder(process: process, processSince: moved, record: record, startedAt: start)
        }
        // Claude's shell cd'd after its process last moved: the record says where it works.
        #expect(folder(RecordedFolder(folder: "/r/.claude/worktrees/x", at: Date(timeIntervalSince1970: 1200))) == "/r/.claude/worktrees/x")
        // The process moved after the record was written (ExitWorktree): the process wins.
        #expect(folder(RecordedFolder(folder: "/r/.claude/worktrees/x", at: Date(timeIntervalSince1970: 1050))) == "/r")
        // A resumed chat's line from before this run never counts.
        let old = RecordedFolder(folder: "/elsewhere", at: Date(timeIntervalSince1970: 500))
        #expect(folder(old) == "/r" && folder(old, process: nil) == nil)
        #expect(folder(nil) == "/r")
        #expect(folder(RecordedFolder(folder: "/r/x", at: moved), process: nil) == "/r/x")
    }

    @Test func claudeAndCodexRecordsByTheirLastLines() {
        let modified = Date(timeIntervalSince1970: 5000)
        let claude: [[String: Any]] = [
            ["type": "user", "cwd": "/r", "timestamp": "2026-10-09T10:00:00.000Z"],
            ["type": "assistant", "cwd": "/r/.claude/worktrees/x", "timestamp": "2026-10-09T10:01:00.000Z"],
            ["type": "assistant", "cwd": "/r/.claude/worktrees/agent-a39109cc", "isSidechain": true, "timestamp": "2026-10-09T10:02:00.000Z"],
            ["type": "ai-title", "aiTitle": "No folder here"],
        ]
        let found = AgentLocation.claudeFolder(claude, modified: modified)
        #expect(found?.folder == "/r/.claude/worktrees/x")
        #expect(found?.at == AgentSessions.parseDate("2026-10-09T10:01:00.000Z"))
        #expect(AgentLocation.claudeFolder([["type": "user", "cwd": "/r"]], modified: modified)?.at == modified)

        let codex: [[String: Any]] = [
            ["type": "turn_context", "timestamp": "2026-10-09T10:00:00.000Z", "payload": ["cwd": "/r"]],
            ["type": "event_msg", "timestamp": "2026-10-09T10:03:00.000Z",
             "payload": ["type": "thread_settings_applied", "thread_settings": ["cwd": "/Code/xCloud-7027-dev"]]],
            ["type": "event_msg", "payload": ["type": "token_count"]],
        ]
        #expect(AgentLocation.codexFolder(codex, modified: modified)?.folder == "/Code/xCloud-7027-dev")
        #expect(AgentLocation.codexFolder(Array(codex.prefix(1)), modified: modified)?.folder == "/r")
        #expect(AgentLocation.codexFolder([], modified: modified) == nil)
        #expect(AgentLocation.isCodexRollout("/h/.codex/sessions/2026/10/09/rollout-1-x.jsonl", home: "/h"))
        #expect(!AgentLocation.isCodexRollout("/h/.codex/history.jsonl", home: "/h"))
    }

    @Test func claudeTranscriptFoundByItsProcessAndReadFromTheEnd() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-claude-home-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        let id = "5e55a0de-0000-4000-8000-0000000000b2"
        try fm.createDirectory(atPath: home + "/.claude/sessions", withIntermediateDirectories: true)
        try #"{"pid": 4242, "sessionId": "\#(id)", "cwd": "/Code/xCloud"}"#.write(toFile: home + "/.claude/sessions/4242.json", atomically: true, encoding: .utf8)
        let project = home + "/.claude/projects/" + AgentSessions.claudeFolderName("/Code/xCloud")
        try fm.createDirectory(atPath: project, withIntermediateDirectories: true)
        // A long transcript: its start is never read, only its last 64 KiB.
        var text = #"{"type":"user","cwd":"/Code/xCloud","timestamp":"2026-10-09T09:00:00Z"}"# + "\n"
        let filler = #"{"type":"progress","data":""# + String(repeating: "x", count: 1000) + "\"}\n"
        text += String(repeating: filler, count: 80)
        text += #"{"type":"assistant","cwd":"/Code/xCloud/.claude/worktrees/pr-7050","timestamp":"2026-10-09T09:05:00Z"}"# + "\n"
        try text.write(toFile: project + "/\(id).jsonl", atomically: true, encoding: .utf8)
        #expect(AgentLocation.claudeFolder(pid: 4242, home: home)?.folder == "/Code/xCloud/.claude/worktrees/pr-7050")
        #expect(AgentLocation.claudeFolder(pid: 4343, home: home) == nil)
        let session = AgentLocation.claudeSession(pid: 4242, home: home)
        #expect(session?.id == id && session?.started == "/Code/xCloud")
        #expect(AgentLocation.claudeTranscript(id: id, started: nil, home: home) == project + "/\(id).jsonl") // looked for in every folder
        #expect(AgentLocation.claudeTranscript(id: "other", started: "/Code/xCloud", home: home) == nil)
        #expect(AgentLocation.claudeTranscript(id: id, started: "/elsewhere", home: home, scanning: false) == nil) // only where it should be

        // Moved to another project folder: still found.
        let other = home + "/.claude/projects/-elsewhere"
        try fm.createDirectory(atPath: other, withIntermediateDirectories: true)
        try fm.moveItem(atPath: project + "/\(id).jsonl", toPath: other + "/\(id).jsonl")
        #expect(AgentLocation.claudeFolder(pid: 4242, home: home)?.folder == "/Code/xCloud/.claude/worktrees/pr-7050")
    }

    /// A last line longer than the 64 KB read first (a big tool result), or a turn's worth of lines with no
    /// folder in them, doesn't lose the folder named before it.
    @Test func aFolderNamedBeforeALongLastLineOrALongTurnIsStillRead() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nt-records-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let worktree = "/Code/xCloud/.claude/worktrees/pr-7050"
        let claude = base + "/claude.jsonl"
        var text = #"{"type":"user","cwd":"/Code/xCloud","timestamp":"2026-10-09T09:00:00Z"}"# + "\n"
        text += #"{"type":"assistant","cwd":"\#(worktree)","timestamp":"2026-10-09T09:05:00Z"}"# + "\n"
        text += #"{"type":"file-history-snapshot","data":""# + String(repeating: "x", count: 70_000) + "\"}\n"
        try text.write(toFile: claude, atomically: true, encoding: .utf8)
        #expect(AgentLocation.claudeFolder(transcript: claude)?.folder == worktree)

        let codex = base + "/rollout-1.jsonl"
        text = #"{"type":"turn_context","timestamp":"2026-10-09T09:00:00Z","payload":{"cwd":"/Code/xCloud"}}"# + "\n"
        text += #"{"type":"event_msg","timestamp":"2026-10-09T09:01:00Z","payload":{"type":"thread_settings_applied","thread_settings":{"cwd":"\#(worktree)"}}}"# + "\n"
        let output = #"{"type":"response_item","payload":{"type":"function_call_output","output":""# + String(repeating: "y", count: 1000) + "\"}}\n"
        text += String(repeating: output, count: 100) // 100 KB of a turn's output
        try text.write(toFile: codex, atomically: true, encoding: .utf8)
        #expect(AgentLocation.codexFolder(rollout: codex)?.folder == worktree)
    }

    /// Followed as it grows: each look reads what was written since, and a turn's worth of output without a
    /// folder keeps the one named before; a replaced record is read anew.
    @Test func aRecordFollowedAsItGrows() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nt-follow-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let rollout = base + "/rollout-1.jsonl"
        func append(_ text: String) throws {
            let handle = try #require(FileHandle(forWritingAtPath: rollout))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }
        func settings(_ folder: String) -> String {
            #"{"type":"event_msg","timestamp":"2026-10-09T09:01:00Z","payload":{"type":"thread_settings_applied","thread_settings":{"cwd":"\#(folder)"}}}"# + "\n"
        }
        let output = #"{"type":"response_item","payload":{"type":"function_call_output","output":""# + String(repeating: "y", count: 1000) + "\"}}\n"
        try (#"{"type":"turn_context","timestamp":"2026-10-09T09:00:00Z","payload":{"cwd":"/r"}}"# + "\n").write(toFile: rollout, atomically: false, encoding: .utf8)
        var records = SessionRecords()
        #expect(records.folder(rollout, kind: .codex)?.folder == "/r")
        try append(settings("/r/.claude/worktrees/x"))
        #expect(records.folder(rollout, kind: .codex)?.folder == "/r/.claude/worktrees/x") // a /cd
        try append(String(repeating: output, count: 100)) // the rest of the turn: 100 KB without a folder
        #expect(records.folder(rollout, kind: .codex)?.folder == "/r/.claude/worktrees/x")
        try append(#"{"type":"response_item","payload":{"type":"message","content":"half a li"#) // still being written
        #expect(records.folder(rollout, kind: .codex)?.folder == "/r/.claude/worktrees/x")
        try append(#"ne"}}"# + "\n" + settings("/r/app"))
        #expect(records.folder(rollout, kind: .codex)?.folder == "/r/app")
        // Replaced by another file: read from its end again.
        try settings("/elsewhere").write(toFile: rollout, atomically: true, encoding: .utf8)
        #expect(records.folder(rollout, kind: .codex)?.folder == "/elsewhere")
        try FileManager.default.removeItem(atPath: rollout)
        #expect(records.folder(rollout, kind: .codex) == nil)

        // Claude Code: a 70 KB line after the folder, written while it was followed.
        let transcript = base + "/claude.jsonl"
        try (#"{"type":"user","cwd":"/r/.claude/worktrees/x","timestamp":"2026-10-09T09:00:00Z"}"# + "\n").write(toFile: transcript, atomically: false, encoding: .utf8)
        #expect(records.folder(transcript, kind: .claude)?.folder == "/r/.claude/worktrees/x")
        let handle = try #require(FileHandle(forWritingAtPath: transcript))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"progress","data":""# + String(repeating: "x", count: 70_000) + "\"}\n").utf8))
        try handle.close()
        #expect(records.folder(transcript, kind: .claude)?.folder == "/r/.claude/worktrees/x")
    }

    @Test func claudeSessionsAndCopilotWorkspacesAreReadAgainOnlyWhenTheyChange() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-records-home-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/.claude/sessions", withIntermediateDirectories: true)
        let sessionFile = home + "/.claude/sessions/4242.json"
        try #"{"pid": 4242, "sessionId": "s-one", "cwd": "/r"}"#.write(toFile: sessionFile, atomically: true, encoding: .utf8)
        var records = SessionRecords()
        #expect(records.claudeSession(pid: 4242, home: home)?.id == "s-one")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sessionFile)
        #expect(records.claudeSession(pid: 4242, home: home)?.id == "s-one") // unchanged: not read
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sessionFile)
        try #"{"pid": 4242, "sessionId": "s-two", "cwd": "/r"}"#.write(toFile: sessionFile, atomically: true, encoding: .utf8) // /clear
        #expect(records.claudeSession(pid: 4242, home: home)?.id == "s-two")
        #expect(records.claudeSession(pid: 4343, home: home) == nil)

        let one = home + "/.copilot/session-state/s1", two = home + "/.copilot/session-state/s2"
        for folder in [one, two] { try fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        try "cwd: /r\n".write(toFile: one + "/workspace.yaml", atomically: true, encoding: .utf8)
        try "cwd: /r/.claude/worktrees/x\n".write(toFile: two + "/workspace.yaml", atomically: true, encoding: .utf8)
        try "".write(toFile: one + "/inuse.777.lock", atomically: true, encoding: .utf8)
        #expect(records.copilotFolder(pid: 777, home: home)?.folder == "/r")
        try "cwd: /r/app\n".write(toFile: one + "/workspace.yaml", atomically: true, encoding: .utf8)
        #expect(records.copilotFolder(pid: 777, home: home)?.folder == "/r/app")
        // It moved to another session: its lock went with it.
        try fm.moveItem(atPath: one + "/inuse.777.lock", toPath: two + "/inuse.777.lock")
        #expect(records.copilotFolder(pid: 777, home: home)?.folder == "/r/.claude/worktrees/x")
        try fm.removeItem(atPath: two + "/inuse.777.lock")
        #expect(records.copilotFolder(pid: 777, home: home) == nil)
    }

    @Test func copilotWorkspaceOfTheSessionItsProcessHasOpen() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-copilot-home-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let session = home + "/.copilot/session-state/s1"
        try FileManager.default.createDirectory(atPath: session, withIntermediateDirectories: true)
        try "id: s1\ncwd: /Code/xCloud-7027-dev\nbranch: fix/7027-sso\n".write(toFile: session + "/workspace.yaml", atomically: true, encoding: .utf8)
        try "".write(toFile: session + "/inuse.777.lock", atomically: true, encoding: .utf8)
        #expect(AgentLocation.copilotFolder(pid: 777, home: home)?.folder == "/Code/xCloud-7027-dev")
        #expect(AgentLocation.copilotFolder(pid: 778, home: home) == nil)
    }

    @Test func commandsThatMoveHead() {
        for line in ["git switch fix/x", "git checkout -b y", "git -C .. switch main", "git -c core.x=1 switch -", "gh pr checkout 7050",
                     "gh co 7050", "git branch -m new", "cd app && git checkout main", "git bisect start", "git reset --hard HEAD~1"] {
            #expect(AgentLocation.movesHead(line), "\(line)")
        }
        for line in ["git status", "git log --oneline", "git branch", "git branch -d old", "gh pr view 7050", "git", "ls", "npm run git"] {
            #expect(!AgentLocation.movesHead(line), "\(line)")
        }
        // They keep the branch: a switch right after one is someone else's.
        for line in ["git pull", "git -c core.x=1 pull --rebase", "git -C .. rebase main", "git merge fix/x", "git checkout -- app/a.txt",
                     "git checkout main -- a.txt", "git checkout -p", "git reset --hard", "git reset -- a.txt"] {
            #expect(!AgentLocation.movesHead(line), "\(line)")
        }
    }

    @Test func commitsOnADetachedHeadAndRenamesAreNoSwitch() {
        let reflog = AgentLocation.parseReflog("""
        0000 aaa1 T <t@t> 1 +0000\tcommit (initial): One
        aaa1 bbb2 T <t@t> 2 +0000\tcheckout: moving from main to bbb2
        bbb2 ccc3 T <t@t> 3 +0000\tcommit: Two
        ccc3 ddd4 T <t@t> 4 +0000\tcommit (amend): Two again
        """)
        #expect(reflog.count == 4 && reflog[1].message == "checkout: moving from main to bbb2")
        #expect(AgentLocation.onlyCommits(from: "bbb2", to: "ddd4", in: reflog))
        #expect(!AgentLocation.onlyCommits(from: "aaa1", to: "ddd4", in: reflog)) // a checkout on the way
        #expect(AgentLocation.change(from: .detached("bbb2"), commit: "bbb2", to: .detached("ddd4"), commit: "ddd4",
                                     reflog: reflog, oldBranchExists: true) == .none)
        #expect(AgentLocation.change(from: .detached("aaa1"), commit: "aaa1", to: .detached("ddd4"), commit: "ddd4",
                                     reflog: reflog, oldBranchExists: true) == .switched)
        #expect(AgentLocation.change(from: .detached("ddd4"), commit: "ddd4", to: .branch("fix/7027-sso"), commit: "ddd4",
                                     reflog: reflog, oldBranchExists: true) == .switched)
        // Renamed in place: the old name is gone and HEAD is where it was.
        #expect(AgentLocation.change(from: .branch("fix/a"), commit: "ddd4", to: .branch("fix/b"), commit: "ddd4",
                                     reflog: [], oldBranchExists: false) == .renamed(from: "fix/a", to: "fix/b"))
        let renamed = [AgentLocation.ReflogEntry(old: "ddd4", new: "ddd4", message: "Branch: renamed refs/heads/fix/a to refs/heads/fix/b")]
        #expect(AgentLocation.change(from: .branch("fix/a"), commit: nil, to: .branch("fix/b"), commit: "ddd4",
                                     reflog: renamed, oldBranchExists: false) == .renamed(from: "fix/a", to: "fix/b"))
        #expect(AgentLocation.change(from: .branch("fix/a"), commit: "ddd4", to: .branch("fix/b"), commit: "ddd4",
                                     reflog: [], oldBranchExists: true) == .switched)

        // A cherry-pick, revert or am makes a commit on the detached HEAD as a commit does; so does a merge whose
        // first parent is the HEAD before it, as git says.
        let picked = AgentLocation.parseReflog("""
        aaa1 bbb2 T <t@t> 2 +0000\tcheckout: moving from main to bbb2
        bbb2 ccc3 T <t@t> 3 +0000\tcherry-pick: Fix it
        ccc3 ddd4 T <t@t> 4 +0000\trevert: Revert "Fix it"
        ddd4 eee5 T <t@t> 5 +0000\tam: Three
        eee5 fff6 T <t@t> 6 +0000\tmerge side: Merge made by the 'ort' strategy.
        """)
        #expect(AgentLocation.change(from: .detached("bbb2"), commit: "bbb2", to: .detached("ccc3"), commit: "ccc3",
                                     reflog: picked, oldBranchExists: true) == .none)
        #expect(AgentLocation.onlyCommits(from: "bbb2", to: "eee5", in: picked))
        #expect(!AgentLocation.onlyCommits(from: "eee5", to: "fff6", in: picked)) // not known to be on it
        #expect(AgentLocation.onlyCommits(from: "bbb2", to: "fff6", in: picked) { commit, parent in commit == "fff6" && parent == "eee5" })
        #expect(!AgentLocation.onlyCommits(from: "aaa1", to: "ccc3", in: picked) { _, _ in true }) // a checkout is never one
    }

    /// With git: a cherry-pick, revert, am and merge on a detached HEAD are no switch; a fast-forward over two
    /// commits is.
    @Test func gitsOwnCommitsOnADetachedHeadAreNoSwitch() throws {
        guard let git = GitRunner.locateGit() else { return }
        let repo = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-detached-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        @discardableResult func sh(_ args: String...) -> String {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", repo, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func commit(_ name: String) {
            try? name.write(toFile: repo + "/" + name, atomically: true, encoding: .utf8)
            sh("add", name)
            sh("commit", "-qm", name)
        }
        sh("init", "-q")
        commit("one")
        sh("switch", "-qc", "side")
        commit("two")
        commit("three")
        let patch = sh("format-patch", "-1", "HEAD", "-o", repo + "/.git/patches")
        sh("switch", "-q", "--detach", "main")
        let start = sh("rev-parse", "HEAD")
        sh("cherry-pick", "side~1")
        sh("revert", "--no-edit", "HEAD")
        sh("am", "-q", patch)
        sh("merge", "-q", "--no-edit", "--no-ff", "side")
        let merged = sh("rev-parse", "HEAD")
        func change(from old: String, to new: String) -> HeadChange {
            AgentLocation.change(in: Checkout(path: repo, head: .detached(new), commit: new), from: .detached(old), commit: old, git: git)
        }
        #expect(merged != start && change(from: start, to: merged) == .none)
        sh("switch", "-q", "--detach", "main")
        sh("merge", "-q", "--ff-only", "side")
        #expect(change(from: start, to: sh("rev-parse", "HEAD")) == .switched) // two commits on: another commit
    }

    @Test func nextTermsOwnStepsThatMoveHead() {
        #expect(AgentLocation.movesHead(arguments: ["switch", "main"]) && AgentLocation.movesHead(arguments: ["-c", "x=1", "switch", "--detach", "v1"]))
        #expect(AgentLocation.movesHead(arguments: ["reset", "--soft", "abc1234"]) && AgentLocation.movesHead(arguments: ["branch", "-m", "a", "b"]))
        // Update Project, Merge and Rebase keep the branch.
        #expect(!AgentLocation.movesHead(arguments: ["rebase", "--autostash", "@{upstream}"]))
        #expect(!AgentLocation.movesHead(arguments: ["-c", "x=1", "merge", "--no-edit", "--autostash", "fix/a"]))
        #expect(!AgentLocation.movesHead(arguments: ["merge", "--ff-only", "@{upstream}"]) && !AgentLocation.movesHead(arguments: ["pull"]))
        #expect(!AgentLocation.movesHead(arguments: ["fetch", "origin"]) && !AgentLocation.movesHead(arguments: ["push", "-u", "origin", "x"]))
        #expect(!AgentLocation.movesHead(arguments: []))
        // Where a switch goes.
        #expect(AgentLocation.switchTarget(arguments: ["switch", "fix/a"]) == "fix/a")
        #expect(AgentLocation.switchTarget(arguments: ["switch", "-c", "fix/a", "--track", "origin/fix/a"]) == "fix/a")
        #expect(AgentLocation.switchTarget(arguments: ["-c", "x=1", "checkout", "-b", "fix/b", "main"]) == "fix/b")
        #expect(AgentLocation.switchTarget(arguments: ["switch", "--detach", "v1"]) == nil && AgentLocation.switchTarget(arguments: ["switch", "-"]) == nil)
        #expect(AgentLocation.switchTarget(arguments: ["checkout", "--", "a.txt"]) == nil && AgentLocation.switchTarget(arguments: ["reset", "--hard", "x"]) == nil)
    }

    @Test func theSignatureChangesWithAHeadOrAWorktree() throws {
        let common = FileManager.default.temporaryDirectory.appendingPathComponent("nt-signature-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: common) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: common + "/worktrees/pr-7050", withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(toFile: common + "/HEAD", atomically: true, encoding: .utf8)
        try "ref: refs/heads/fix/7027-sso\n".write(toFile: common + "/worktrees/pr-7050/HEAD", atomically: true, encoding: .utf8)
        let first = AgentLocation.signature(commonDir: common)
        #expect(AgentLocation.signature(commonDir: common) == first)
        func later(_ path: String) throws {
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: path)
        }
        try later(common + "/worktrees/pr-7050/HEAD") // a switch in the worktree
        let switched = AgentLocation.signature(commonDir: common)
        #expect(switched != first)
        try fm.createDirectory(atPath: common + "/worktrees/agent-a39109cc", withIntermediateDirectories: true)
        #expect(AgentLocation.signature(commonDir: common) != switched) // a worktree came
    }

    @Test func aChangeCountsAfterHoldingThreeSecondsAndNotDuringAGitOperation() {
        let t0 = Date(timeIntervalSince1970: 0)
        func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
        var held = Held<String>()
        #expect(held.see("main", at: at(0))?.to == "main") // the first value counts at once
        #expect(held.see("fix/x", at: at(1)) == nil)
        #expect(held.see("fix/x", at: at(3.5)) == nil)
        let change = held.see("fix/x", at: at(4))
        #expect(change == Held<String>.Change(from: "main", to: "fix/x", since: at(1)) && held.value == "fix/x")

        // A rebase detaches HEAD for 2 s: nothing (AE8).
        #expect(held.see("detached", at: at(10)) == nil && held.see("detached", at: at(12)) == nil)
        #expect(held.see("fix/x", at: at(13)) == nil && held.see("fix/x", at: at(20)) == nil && held.value == "fix/x")

        // A long one, blocked while git is in the middle of it, then held 3 s more once it ends.
        #expect(held.see("detached", at: at(30), blocked: true) == nil)
        #expect(held.see("detached", at: at(60), blocked: true) == nil)
        #expect(held.see("detached", at: at(61)) == nil && held.see("detached", at: at(63.9)) == nil)
        #expect(held.see("detached", at: at(64))?.since == at(30))
        // Nothing counts first while blocked either.
        var fresh = Held<String>()
        #expect(fresh.see("main", at: at(0), blocked: true) == nil && fresh.value == nil)
        #expect(fresh.see("main", at: at(1))?.to == "main")
    }
}

/// The tracker: places held, Elsewhere's raw material, and who a switch in place is credited to (R4).
@Suite struct PlaceTrackerTests {
    static let repo = "/Code/xCloud/.git"
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func checkouts(main head: CheckoutHead, commit: String = "a1", busy: Bool = false, worktree: CheckoutHead = .branch("fix/7027-sso")) -> [Checkout] {
        [Checkout(path: "/Code/xCloud", head: head, commit: commit, isMain: true, busy: busy),
         Checkout(path: "/Code/xCloud/.claude/worktrees/pr-7050", head: worktree, commit: "b2")]
    }

    func sighting(_ head: CheckoutHead, _ agents: [(String, String, Bool)], busy: Bool = false, commit: String = "a1",
                  own: Date? = nil, shell: [PlaceSighting.ShellCommand] = []) -> PlaceSighting {
        var seen = PlaceSighting()
        seen.repositories[Self.repo] = checkouts(main: head, commit: commit, busy: busy)
        seen.agents = agents.map { PlaceSighting.Agent(key: $0.0, title: "tab " + $0.0, repository: Self.repo, folder: $0.1, working: $0.2) }
        if let own { seen.ownSwitches["/Code/xCloud"] = own }
        seen.shellCommands = shell
        return seen
    }

    /// Runs one look a second from `from` to `to` (inclusive).
    func run(_ tracker: inout PlaceTracker, _ seen: PlaceSighting, from: Double, to: Double,
             classify: (Checkout, CheckoutHead, String?) -> HeadChange = { _, _, _ in .switched }) {
        var second = from
        while second <= to {
            tracker.update(seen, at: at(second), classify: classify)
            second += 1
        }
    }

    let root = "/Code/xCloud"
    let worktree = "/Code/xCloud/.claude/worktrees/pr-7050/app"

    @Test func anAgentThatEntersANestedWorktreeIsThereAfterThreeSeconds() {
        var tracker = PlaceTracker()
        run(&tracker, sighting(.branch("main"), [("7", root, true)]), from: 0, to: 2)
        #expect(tracker.places["7"]?.checkout.path == root && tracker.places["7"]?.workingBranch == .branch("main"))
        // A cd in the main checkout is no move (AE11).
        run(&tracker, sighting(.branch("main"), [("7", root + "/app/Http", true)]), from: 3, to: 9)
        #expect(tracker.places["7"]?.checkout.path == root)
        run(&tracker, sighting(.branch("main"), [("7", worktree, true)]), from: 10, to: 12)
        #expect(tracker.places["7"]?.checkout.path == root) // held 2 s so far
        run(&tracker, sighting(.branch("main"), [("7", worktree, true)]), from: 13, to: 13)
        let place = tracker.places["7"]
        #expect(place?.checkout.path == "/Code/xCloud/.claude/worktrees/pr-7050" && place?.checkout.head == .branch("fix/7027-sso"))
        #expect(place?.workingBranch == .branch("fix/7027-sso") && place?.switched == nil) // it moved itself
        // A separate clone is no move: the agent stays where it was.
        run(&tracker, sighting(.branch("main"), [("7", "/Code/xCloud-copy", true)]), from: 14, to: 20)
        #expect(tracker.places["7"]?.checkout.path == "/Code/xCloud/.claude/worktrees/pr-7050")
        // A move back of under 3 s doesn't count either.
        run(&tracker, sighting(.branch("main"), [("7", root, true)]), from: 21, to: 22)
        run(&tracker, sighting(.branch("main"), [("7", worktree, true)]), from: 23, to: 30)
        #expect(tracker.places["7"]?.checkout.path == "/Code/xCloud/.claude/worktrees/pr-7050")
    }

    @Test func anotherRepositorysCheckoutIsNotThisOnes() {
        var tracker = PlaceTracker()
        var seen = sighting(.branch("main"), [("7", root, false)])
        seen.repositories["/Code/other/.git"] = [Checkout(path: "/Code/other", head: .branch("dev"), isMain: true)]
        run(&tracker, seen, from: 0, to: 1)
        // Matched against its own repository's checkouts only: /Code/other is outside xCloud's.
        seen.agents = [PlaceSighting.Agent(key: "7", title: "tab 7", repository: Self.repo, folder: "/Code/other/src", working: false)]
        run(&tracker, seen, from: 2, to: 10)
        #expect(tracker.places["7"]?.checkout.path == root && tracker.places["7"]?.repository == Self.repo)
        // Another repository for the tab starts it over.
        seen.agents = [PlaceSighting.Agent(key: "7", title: "tab 7", repository: "/Code/other/.git", folder: "/Code/other/src", working: false)]
        run(&tracker, seen, from: 11, to: 11)
        #expect(tracker.places["7"]?.checkout.path == "/Code/other" && tracker.places["7"]?.workingBranch == nil)
    }

    /// AE1: tab 7 switches in place while three others idle after earlier turns and one has had none.
    @Test func theAgentThatSwitchedMovesAlongAndTheOthersAreMarked() {
        var tracker = PlaceTracker()
        let turns = [("7", root, true), ("1", root, true), ("2", root, true), ("3", root, true), ("fresh", root, false)]
        run(&tracker, sighting(.branch("fix/7611-3ds"), turns), from: 0, to: 1)
        let idle = [("7", root, true), ("1", root, false), ("2", root, false), ("3", root, false), ("fresh", root, false)]
        run(&tracker, sighting(.branch("fix/7611-3ds"), idle), from: 2, to: 10)
        run(&tracker, sighting(.branch("fix/7050-pr"), idle), from: 11, to: 14)
        #expect(tracker.places["7"]?.workingBranch == .branch("fix/7050-pr") && tracker.places["7"]?.switched == nil)
        for key in ["1", "2", "3"] {
            let switched = tracker.places[key]?.switched
            #expect(switched?.from == .branch("fix/7611-3ds") && switched?.to == .branch("fix/7050-pr"))
            #expect(switched?.by == .agent(key: "7", title: "tab 7"))
        }
        #expect(tracker.places["fresh"]?.switched == nil && tracker.places["fresh"]?.workingBranch == nil)
        #expect(tracker.places["fresh"]?.checkout.head == .branch("fix/7050-pr")) // it follows the checkout
        // Keep Going makes the new branch the chat's; switching back clears the others.
        tracker.keepGoing("1")
        #expect(tracker.places["1"]?.switched == nil && tracker.places["1"]?.workingBranch == .branch("fix/7050-pr"))
        run(&tracker, sighting(.branch("fix/7611-3ds"), idle), from: 15, to: 18)
        #expect(tracker.places["2"]?.switched == nil && tracker.places["3"]?.switched == nil)
        #expect(tracker.places["1"]?.switched?.to == .branch("fix/7611-3ds"))
    }

    /// AE2: two agents working when the branch changes: both marked, nobody guessed.
    @Test func twoWorkingAgentsAreBothMarked() {
        var tracker = PlaceTracker()
        let working = [("5", root, true), ("7", root, true)]
        run(&tracker, sighting(.branch("main"), working), from: 0, to: 2)
        run(&tracker, sighting(.branch("fix/x"), working), from: 3, to: 6)
        for key in ["5", "7"] { #expect(tracker.places[key]?.switched?.by == .unknown(working: 2)) }
    }

    /// An agent that starts a turn while a switch is being held wasn't working at it: the one that was made it.
    /// One that paused just before the switch and works again during the hold was working at it.
    @Test func anAgentThatStartsDuringTheHoldWasNotWorkingAtTheSwitch() {
        var tracker = PlaceTracker()
        run(&tracker, sighting(.branch("main"), [("7", root, true), ("8", root, true)]), from: 0, to: 1)
        run(&tracker, sighting(.branch("main"), [("7", root, true), ("8", root, false)]), from: 2, to: 9)
        run(&tracker, sighting(.branch("fix/x"), [("7", root, true), ("8", root, false)]), from: 10, to: 10)
        run(&tracker, sighting(.branch("fix/x"), [("7", root, true), ("8", root, true)]), from: 11, to: 14)
        #expect(tracker.places["7"]?.switched == nil && tracker.places["7"]?.workingBranch == .branch("fix/x"))
        #expect(tracker.places["8"]?.switched?.by == .agent(key: "7", title: "tab 7"))

        run(&tracker, sighting(.branch("fix/x"), [("7", root, true), ("8", root, false)]), from: 15, to: 19)
        tracker.keepGoing("8")
        run(&tracker, sighting(.branch("fix/y"), [("7", root, false), ("8", root, false)]), from: 20, to: 20)
        run(&tracker, sighting(.branch("fix/y"), [("7", root, true), ("8", root, false)]), from: 21, to: 24)
        #expect(tracker.places["7"]?.switched == nil && tracker.places["7"]?.workingBranch == .branch("fix/y"))
        #expect(tracker.places["8"]?.switched?.by == .agent(key: "7", title: "tab 7"))
    }

    /// AE2a and a shell tab: their switches are theirs, even with one agent working.
    @Test func yourSwitchAndAShellTabsAreTheirs() {
        var tracker = PlaceTracker()
        let agents = [("7", root, true), ("8", root, false)]
        run(&tracker, sighting(.branch("main"), [("7", root, true), ("8", root, true)]), from: 0, to: 2)
        run(&tracker, sighting(.branch("fix/x"), agents, own: at(2.5)), from: 3, to: 6)
        #expect(tracker.places["7"]?.switched?.by == .you && tracker.places["8"]?.switched?.by == .you)

        let shell = PlaceSighting.ShellCommand(key: "sh", title: "zsh", folder: root + "/app", at: at(9.5))
        run(&tracker, sighting(.branch("fix/y"), agents, shell: [shell]), from: 10, to: 13)
        #expect(tracker.places["7"]?.switched?.by == .tab(key: "sh", title: "zsh") && tracker.places["7"]?.switched?.from == .branch("main"))
        // A shell tab in another checkout didn't do it.
        let elsewhere = PlaceSighting.ShellCommand(key: "sh2", title: "zsh 2", folder: worktree, at: at(19.5))
        run(&tracker, sighting(.branch("fix/z"), agents, shell: [elsewhere]), from: 20, to: 23)
        #expect(tracker.places["7"]?.switched == nil && tracker.places["7"]?.workingBranch == .branch("fix/z"))
        #expect(tracker.places["8"]?.switched?.by == .agent(key: "7", title: "tab 7") && tracker.places["8"]?.switched?.from == .branch("main"))
    }

    /// Your switch went to the branch you chose: when the checkout went to another one within the window (yours
    /// failed, or an agent switched first), that switch is the agent's (AE1), and yours stays yours.
    @Test func yourSwitchIsOnlyTheOneToYourBranch() {
        var tracker = PlaceTracker()
        let agents = [("7", root, true), ("8", root, false)]
        run(&tracker, sighting(.branch("main"), [("7", root, true), ("8", root, true)]), from: 0, to: 1)
        run(&tracker, sighting(.branch("main"), agents), from: 2, to: 4)
        var seen = sighting(.branch("fix/agent"), agents, own: at(4.5))
        seen.ownTargets[root] = "fix/mine"
        run(&tracker, seen, from: 5, to: 9)
        #expect(tracker.places["7"]?.switched == nil && tracker.places["7"]?.workingBranch == .branch("fix/agent"))
        #expect(tracker.places["8"]?.switched?.by == .agent(key: "7", title: "tab 7"))
        seen = sighting(.branch("fix/mine"), agents, own: at(4.5))
        seen.ownTargets[root] = "fix/mine"
        run(&tracker, seen, from: 10, to: 14)
        #expect(tracker.places["7"]?.switched?.by == .you && tracker.places["8"]?.switched?.by == .you)
    }

    /// AE8: a rebase that detaches HEAD (long, while git says it is rebasing) marks nobody.
    @Test func aRebaseInProgressIsNoSwitch() {
        var tracker = PlaceTracker()
        let agents = [("7", root, true), ("8", root, false)]
        run(&tracker, sighting(.branch("main"), agents), from: 0, to: 2)
        run(&tracker, sighting(.detached("e5"), agents, busy: true, commit: "e5"), from: 3, to: 30)
        run(&tracker, sighting(.branch("main"), agents, commit: "f6"), from: 31, to: 40)
        #expect(tracker.places["8"]?.switched == nil && tracker.places["7"]?.switched == nil)
    }

    /// R3a: commits on a detached HEAD, and a branch renamed in place, are followed, not marked.
    @Test func detachedCommitsAndRenamesAreFollowed() {
        var tracker = PlaceTracker()
        let agents = [("7", root, false)]
        run(&tracker, sighting(.detached("abc1234"), [("7", root, true)], commit: "abc1234"), from: 0, to: 1)
        run(&tracker, sighting(.detached("bcd2345"), agents, commit: "bcd2345"), from: 2, to: 6) { _, _, _ in .none }
        #expect(tracker.places["7"]?.switched == nil && tracker.places["7"]?.workingBranch == .detached("bcd2345"))
        run(&tracker, sighting(.branch("fix/a"), agents, commit: "bcd2345"), from: 7, to: 11)
        #expect(tracker.places["7"]?.switched?.to == .branch("fix/a")) // a real switch, from detached
        tracker.keepGoing("7")
        run(&tracker, sighting(.branch("fix/b"), agents, commit: "bcd2345"), from: 12, to: 16) { _, from, commit in
            from == .branch("fix/a") && commit == "bcd2345" ? .renamed(from: "fix/a", to: "fix/b") : .switched
        }
        #expect(tracker.places["7"]?.switched == nil && tracker.places["7"]?.workingBranch == .branch("fix/b"))
    }

    @Test func aNewRunInTheTabStartsOver() {
        var tracker = PlaceTracker()
        func seen(_ head: CheckoutHead, working: Bool, started: Double) -> PlaceSighting {
            var seen = sighting(head, [])
            seen.agents = [PlaceSighting.Agent(key: "7", title: "tab 7", repository: Self.repo, folder: root, working: working, startedAt: at(started))]
            return seen
        }
        run(&tracker, seen(.branch("main"), working: true, started: 0), from: 0, to: 1)
        #expect(tracker.places["7"]?.workingBranch == .branch("main"))
        // Restarted between two looks: a fresh agent, which has had no turn and follows the checkout.
        run(&tracker, seen(.branch("main"), working: false, started: 1.5), from: 2, to: 2)
        #expect(tracker.places["7"]?.workingBranch == nil)
        run(&tracker, seen(.branch("fix/x"), working: false, started: 1.5), from: 3, to: 7)
        #expect(tracker.places["7"]?.switched == nil)
    }

    @Test func aMoveMustHoldWithoutAnOutsideFolderBetween() {
        var tracker = PlaceTracker()
        run(&tracker, sighting(.branch("main"), [("7", root, true)]), from: 0, to: 1)
        run(&tracker, sighting(.branch("main"), [("7", worktree, true)]), from: 2, to: 3) // 2 s in the worktree
        run(&tracker, sighting(.branch("main"), [("7", "/tmp", true)]), from: 4, to: 9) // outside: no move
        #expect(tracker.places["7"]?.checkout.path == root)
        run(&tracker, sighting(.branch("main"), [("7", worktree, true)]), from: 10, to: 11)
        #expect(tracker.places["7"]?.checkout.path == root) // back in the worktree for 1 s: it holds anew
        run(&tracker, sighting(.branch("main"), [("7", worktree, true)]), from: 12, to: 13)
        #expect(tracker.places["7"]?.checkout.path == "/Code/xCloud/.claude/worktrees/pr-7050")
    }

    /// A chat whose first turn comes just after a switch, before it counted, works on the new branch.
    @Test func aFirstTurnRightAfterASwitchIsOnTheNewBranch() {
        var tracker = PlaceTracker()
        run(&tracker, sighting(.branch("main"), [("7", root, false)]), from: 0, to: 1)
        run(&tracker, sighting(.branch("fix/x"), [("7", root, false)], own: at(1.5)), from: 2, to: 2)
        run(&tracker, sighting(.branch("fix/x"), [("7", root, true)]), from: 3, to: 8) // its turn, 1 s after the switch
        #expect(tracker.places["7"]?.workingBranch == .branch("fix/x") && tracker.places["7"]?.switched == nil)
        // A first turn during a rebase takes the branch held, not the detached HEAD.
        var rebasing = PlaceTracker()
        run(&rebasing, sighting(.branch("main"), [("8", root, false)]), from: 0, to: 1)
        run(&rebasing, sighting(.detached("e5"), [("8", root, true)], busy: true, commit: "e5"), from: 2, to: 4)
        #expect(rebasing.places["8"]?.workingBranch == .branch("main"))
    }

    @Test func movingClearsTheMarkAndAgentsThatEndAreForgotten() {
        var tracker = PlaceTracker()
        run(&tracker, sighting(.branch("main"), [("7", root, true)]), from: 0, to: 1)
        run(&tracker, sighting(.branch("fix/x"), [("7", root, false)], own: at(1.5)), from: 2, to: 5)
        #expect(tracker.places["7"]?.switched != nil)
        run(&tracker, sighting(.branch("fix/x"), [("7", worktree, false)]), from: 6, to: 9)
        #expect(tracker.places["7"]?.switched == nil && tracker.places["7"]?.workingBranch == .branch("fix/7027-sso"))
        run(&tracker, sighting(.branch("fix/x"), []), from: 10, to: 10)
        #expect(tracker.places.isEmpty)
    }
}

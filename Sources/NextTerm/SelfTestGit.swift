import AppKit
import NextTermCore

/// The branch popup's and the commit sheet's later rows, in a repository of their own with a remote and
/// a second clone: long names cut in the middle (popup and Git Log tree), tags in the search, Delete on
/// Remote (refused for the default branch, and undone), Update of a branch that isn't checked out (and
/// when it diverged), Checkout and Update, a worktree's agent tab and stale lock with Unlock, and Write
/// with Agent with a stand-in agent.
extension SelfTest {
    static func gitLeftoverChecks(_ c: TerminalWindowController) async {
        guard let git = GitRunner.locateGit(), let window = c.window else { return }
        let base = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-selftest-git-\(getpid())")
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("work").path, remote = base.appendingPathComponent("origin.git").path
        let theirs = base.appendingPathComponent("theirs").path
        @discardableResult func run(_ dir: String, _ args: String...) -> String { gitOutput(git, dir, args) }
        func write(_ dir: String, _ name: String, _ text: String) { try? text.write(toFile: (dir as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8) }
        /// Presses a button in the sheet over the window (an alert from a git action).
        func press(_ title: String, within seconds: Double = 8) async -> Bool {
            func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
            guard await wait(seconds, { window.attachedSheet.flatMap { $0.contentView.map(buttons) }?.contains { $0.title == title } == true }),
                  let button = window.attachedSheet?.contentView.map(buttons)?.first(where: { $0.title == title }) else { return false }
            button.performClick(nil)
            return true
        }
        func sheetText() -> String {
            func fields(_ view: NSView) -> [NSTextField] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields($0) } }
            return window.attachedSheet?.contentView.map(fields)?.map(\.stringValue).joined(separator: "\n") ?? ""
        }
        /// GitActions for the repository, with its branches read fresh.
        func actions() async -> GitActions? {
            var made: GitActions?
            c.withGit(at: repo) { made = $0 }
            _ = await wait(15) { made != nil }
            return made
        }
        let popup = c.branchPopup
        func row(_ title: String) -> Int? { popup.rowTitles.firstIndex(of: title) }
        func menuTitles(_ title: String) -> [String] {
            guard let index = row(title), let menu = popup.menu(forRow: index) else { return [] }
            return menu.items.map { $0.title + ($0.isEnabled ? "" : " (off)") }
        }

        // A remote with main, a branch to delete there, and branches a second clone moves on.
        run(base.path, "init", "-q", "--bare", remote)
        run(base.path, "init", "-q", repo)
        write(repo, "a.txt", "hi\n")
        run(repo, "add", "a.txt")
        run(repo, "commit", "-qm", "One")
        let long = "feat/" + String(repeating: "a-very-long-branch-name-", count: 6) + "end"
        for name in ["feat/remote-x", "feat/u", "feat/behind", long] { run(repo, "branch", name) }
        run(repo, "tag", "v9.8.7")
        run(repo, "remote", "add", "origin", remote)
        run(repo, "push", "-q", "-u", "origin", "main", "feat/remote-x", "feat/u", "feat/behind")
        run(repo, "remote", "set-head", "origin", "main")
        run(base.path, "clone", "-q", remote, theirs)
        func theirsPush(_ branch: String, _ text: String) -> String {
            run(theirs, "fetch", "-q", "origin")
            run(theirs, "switch", "-q", "-C", branch, "origin/" + branch)
            write(theirs, "b.txt", text)
            run(theirs, "add", "b.txt")
            run(theirs, "commit", "-qm", text)
            run(theirs, "push", "-q", "origin", branch)
            return run(theirs, "rev-parse", "HEAD")
        }

        // Long names: cut in the middle, in the popup and in the Git Log's tree.
        c.showBranches(at: repo, query: "")
        check(await wait(20) { !popup.isReading && popup.model.map { canonicalPath($0.root) == canonicalPath(repo) } == true },
              "the branch popup reads the self-test's repository", popup.rowTitles.joined(separator: " | "))
        if !popup.isOpen("local:feat") { popup.toggleFolder("local:feat") }
        let longLabel = String(long.dropFirst("feat/".count))
        popup.tableView.layoutSubtreeIfNeeded()
        if let index = row(longLabel), let cell = popup.tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? BranchCell {
            let style = cell.titleText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            check(style?.lineBreakMode == .byTruncatingMiddle, "a long branch name in the popup is cut in the middle", "\(String(describing: style?.lineBreakMode))")
        } else {
            check(false, "a long branch name is listed in the popup", popup.rowTitles.joined(separator: " | "))
        }
        await screenshot(popup.panelWindow, suffix: "branches-long")
        popup.close()
        if let log = c.openGitLog(root: repo) {
            let listed = await wait(10) { log.refs.rowTitles.contains { $0.trimmingCharacters(in: .whitespaces) == longLabel } }
            let index = log.refs.rowTitles.firstIndex { $0.trimmingCharacters(in: .whitespaces) == longLabel }
            log.refs.outline.layoutSubtreeIfNeeded()
            let cell = index.flatMap { log.refs.outline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? GitRefCell }
            let style = cell?.titleText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            check(listed && style?.lineBreakMode == .byTruncatingMiddle, "and in the Git Log's branch tree", log.refs.rowTitles.joined(separator: " | "))
            c.editorArea.close(log)
        }

        // Tags in the search: listed once read, checked out detached; a tag typed in full has no revision row besides.
        c.showBranches(at: repo, query: "v9.8")
        check(await wait(15) { !popup.isReading && popup.rowTitles.contains("tag v9.8.7") }, "the popup's search lists tags",
              popup.rowTitles.joined(separator: " | "))
        popup.query = "v9.8.7"
        check(popup.rowTitles.contains("tag v9.8.7") && !popup.rowTitles.contains("revision v9.8.7"), "a tag typed in full is its own row, not a revision",
              popup.rowTitles.joined(separator: " | "))
        check(menuTitles("tag v9.8.7").starts(with: ["Checkout “v9.8.7” (detached)", "New Branch from “v9.8.7”…", "Show History"]),
              "a tag's menu checks it out, branches from it and shows its history", menuTitles("tag v9.8.7").joined(separator: " | "))
        if let index = row("tag v9.8.7") { popup.activate(row: index) }
        check(await wait(10) { run(repo, "rev-parse", "--abbrev-ref", "HEAD") == "HEAD" && run(repo, "rev-parse", "HEAD") == run(repo, "rev-parse", "v9.8.7^{commit}") },
              "↩ on a tag checks it out, detached", GitToast.text ?? run(repo, "status", "-sb"))
        run(repo, "switch", "-q", "main")
        GitToast.dismiss()

        // Delete on Remote: off for the remote's default branch; asks first, names both; Undo puts it back.
        c.showBranches(at: repo, query: "")
        _ = await wait(15) { !popup.isReading }
        if !popup.isOpen("remote:origin") { popup.toggleFolder("remote:origin") }
        check(menuTitles("remote main").contains("Delete on Remote… (off)") && menuTitles("remote feat/remote-x").contains("Delete on Remote…"),
              "Delete on Remote… is in a remote branch's menu, and off for the remote's default branch",
              menuTitles("remote main").joined(separator: " | "))
        popup.close()
        if let actions = await actions(), let model = c.branchPopup.model,
           let gone = model.remotes.first(where: { $0.name == "origin/feat/remote-x" }), let main = model.remotes.first(where: { $0.name == "origin/main" }) {
            actions.deleteOnRemote(main)
            check(await wait(5) { sheetText().contains("Deleting main on origin is off") }, "deleting the remote's default branch is refused", sheetText())
            _ = await press("OK")
            actions.deleteOnRemote(gone)
            let asked = await wait(5) { sheetText().contains("Delete feat/remote-x on origin?") && sheetText().contains("feat/remote-x on origin for everyone") }
            check(asked, "Delete on Remote asks first, naming the remote and the branch", sheetText())
            _ = await press("Delete on origin")
            check(await wait(10) { run(remote, "branch", "--list", "feat/remote-x").isEmpty && GitToast.text?.hasPrefix("Deleted origin/feat/remote-x (was ") == true },
                  "and deletes the branch there, with Undo", GitToast.text ?? "no notice")
            GitToast.pressButtonForTest()
            check(await wait(10) { run(remote, "rev-parse", "feat/remote-x") == gone.sha }, "Undo puts it back on the remote at its commit")
            check(!run(remote, "branch", "--list", "main").isEmpty, "and main was never touched")
        } else {
            check(false, "the remote's branches are read")
        }
        GitToast.dismiss()

        // Update a branch that isn't checked out: forward from its upstream; diverged, it says so and changes nothing.
        let newer = theirsPush("feat/u", "theirs 1")
        if let actions = await actions(), let u = c.branchPopup.model?.local("feat/u") {
            actions.update(u)
            check(await wait(10) { run(repo, "rev-parse", "feat/u") == newer && GitToast.text == "Updated feat/u from origin/feat/u" },
                  "Update brings a branch that isn't checked out up to its upstream", GitToast.text ?? run(repo, "rev-parse", "feat/u"))
        }
        run(repo, "switch", "-q", "feat/u")
        write(repo, "c.txt", "mine\n")
        run(repo, "add", "c.txt")
        run(repo, "commit", "-qm", "mine")
        let mine = run(repo, "rev-parse", "HEAD")
        run(repo, "switch", "-q", "main")
        _ = theirsPush("feat/u", "theirs 2")
        if let actions = await actions(), let u = c.branchPopup.model?.local("feat/u") {
            actions.update(u)
            check(await wait(10) { sheetText().contains("“feat/u” and “origin/feat/u” have both changed") && sheetText().contains("1 commit here and 1 on origin/feat/u") },
                  "when the two have diverged, Update says so plainly", sheetText())
            _ = await press("OK")
            check(run(repo, "rev-parse", "feat/u") == mine, "and leaves the branch as it was")
        }
        GitToast.dismiss()

        // Checkout and Update: in the menu of a branch behind its upstream; switches, then forward.
        let ahead = theirsPush("feat/behind", "theirs behind")
        run(repo, "fetch", "-q", "origin")
        c.showBranches(at: repo, query: "behind")
        _ = await wait(15) { !popup.isReading && popup.model?.local("feat/behind")?.behind == 1 }
        check(menuTitles("feat/behind").starts(with: ["Checkout", "Checkout and Update"]) && menuTitles("feat/behind").contains("Update “feat/behind” from origin/feat/behind"),
              "a branch behind its upstream has Checkout and Update, and Update", menuTitles("feat/behind").joined(separator: " | "))
        popup.close()
        if let actions = await actions(), let behind = c.branchPopup.model?.local("feat/behind") {
            actions.checkoutAndUpdate(behind)
            check(await wait(10) { run(repo, "rev-parse", "--abbrev-ref", "HEAD") == "feat/behind" && run(repo, "rev-parse", "HEAD") == ahead },
                  "Checkout and Update switches to it and brings it up to its upstream", GitToast.text ?? run(repo, "status", "-sb"))
        }
        run(repo, "switch", "-q", "main")
        GitToast.dismiss()

        await worktreeLockChecks(c, git: git, repo: repo, base: base, menuTitles: menuTitles)
        await writeWithAgentChecks(c, git: git, repo: repo, base: base)
        try? FileManager.default.removeItem(atPath: theirs)
    }

    /// git in `dir`, as the self-test's own committer; what it printed.
    @discardableResult
    private static func gitOutput(_ git: String, _ dir: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", dir, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false",
                       "-c", "init.defaultBranch=main"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A worktree with an agent tab working in it and a lock whose process has ended: the row says
    /// both, and Unlock frees it (with Undo). A lock held by a live process can't be unlocked from there.
    private static func worktreeLockChecks(_ c: TerminalWindowController, git: String, repo: String, base: URL,
                                           menuTitles: (String) -> [String]) async {
        let popup = c.branchPopup
        let stale = base.appendingPathComponent("work-stale").path, live = base.appendingPathComponent("work-live").path
        @discardableResult func sh(_ args: [String]) -> String { gitOutput(git, repo, args) }
        /// The worktree's lock reason, from git's own file; nil when it isn't locked.
        func lockReason(_ path: String) -> String? {
            let admin = canonicalPath(repo) + "/.git/worktrees/" + (path as NSString).lastPathComponent + "/locked"
            return (try? String(contentsOfFile: admin, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        sh(["worktree", "add", "-q", "-b", "wt/stale", stale])
        sh(["worktree", "add", "-q", "-b", "wt/live", live])
        // A process that has ended, and this one (started when ps says).
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? ended.run()
        ended.waitUntilExit()
        let ps = Process(), out = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "lstart=", "-p", String(getpid())]
        ps.environment = ["LC_ALL": "C", "TZ": "UTC"]
        ps.standardOutput = out
        try? ps.run()
        let started = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        ps.waitUntilExit()
        let staleReason = "claude agent agent-gone (pid \(ended.processIdentifier) start \(started))"
        sh(["worktree", "lock", "--reason", staleReason, stale])
        sh(["worktree", "lock", "--reason", "claude agent agent-here (pid \(getpid()) start \(started))", live])

        // An agent working in the stale one: a stand-in claude that keeps printing.
        let bin = base.appendingPathComponent("bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try? "#!/bin/sh\nwhile true; do printf '\\r\\342\\234\\273 Working (esc to interrupt) %s' $(date +%S); sleep 0.3; done\n"
            .write(to: bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        chmod(bin.appendingPathComponent("claude").path, 0o755)
        let tab = c.addTab(directory: stale)
        _ = await wait(20) { tab.status.integrated }
        tab.view.send(txt: "PATH=\(bin.path):$PATH claude\r")
        _ = await wait(5) { tab.status.running && tab.status.kind == .agent }

        c.showBranches(at: repo, query: "")
        let staleRow = { popup.rowTitles.first { $0.hasPrefix("worktree work-stale") } ?? "" }
        check(await wait(15) { !popup.isReading && staleRow().hasPrefix("worktree work-stale (stale lock) · Claude Code: ") },
              "a worktree row shows the agent working in it, and a lock whose process has ended as stale", popup.rowTitles.joined(separator: " | "))
        check(popup.rowTitles.contains("worktree work-live"), "a lock whose process still runs is not stale", popup.rowTitles.joined(separator: " | "))
        check(menuTitles("worktree work-live").contains("Unlock (off)"), "and can't be unlocked from the popup", menuTitles("worktree work-live").joined(separator: " | "))
        await screenshot(popup.panelWindow, suffix: "worktree-rows")
        let title = staleRow()
        if let index = popup.rowTitles.firstIndex(of: title), let item = popup.menu(forRow: index)?.items.first(where: { $0.title == "Unlock" }) {
            (item.representedObject as? MenuBlock)?.run(nil)
            check(await wait(10) { lockReason(stale) == nil && GitToast.text == "Unlocked work-stale" },
                  "Unlock frees a stale lock at once", GitToast.text ?? "no notice")
            GitToast.pressButtonForTest()
            check(await wait(10) { lockReason(stale) == staleReason }, "and its Undo locks it again, with the same reason", lockReason(stale) ?? "not locked")
        } else {
            check(false, "a stale lock's row has Unlock", menuTitles(title).joined(separator: " | "))
        }
        popup.close()
        GitToast.dismiss()

        tab.view.send(txt: "\u{03}")
        _ = await wait(5) { !tab.status.running }
        c.requestClose(tab)
        for path in [stale, live] {
            sh(["worktree", "unlock", path])
            sh(["worktree", "remove", "--force", path])
        }
    }

    /// Write with Agent, with a stand-in for Claude Code: it reads the staged changes, its answer fills the
    /// message (fences gone), the hint names it, nothing is committed until you commit.
    private static func writeWithAgentChecks(_ c: TerminalWindowController, git: String, repo: String, base: URL) async {
        let bin = base.appendingPathComponent("writer")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let seen = base.appendingPathComponent("seen.txt").path
        try? "#!/bin/sh\ncat > '\(seen)'\nprintf '```\\nFix the greeting\\n\\nSays hello properly.\\n```\\n'\n"
            .write(to: bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        chmod(bin.appendingPathComponent("claude").path, 0o755)
        GitActions.commitAgentForTest = (.claude, bin.appendingPathComponent("claude").path)
        defer { GitActions.commitAgentForTest = nil }
        try? "hello\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        gitOutput(git, repo, ["add", "a.txt"])
        let head = gitOutput(git, repo, ["rev-parse", "HEAD"])
        var opened = false
        c.withGit(at: repo) { actions in
            actions.commit()
            opened = true
        }
        guard await wait(15, { opened && CommitSheet.current != nil }), let sheet = CommitSheet.current else {
            return check(false, "the commit sheet opens for Write with Agent")
        }
        check(sheet.canWriteWithAgent, "the commit sheet offers Write with Agent when an agent is installed")
        sheet.pressWriteWithAgent()
        check(await wait(15) { !sheet.isWriting && sheet.messageText == "Fix the greeting\n\nSays hello properly." },
              "Write with Agent fills the message with the agent's answer", sheet.messageText.debugDescription + " / " + sheet.hintText)
        check(sheet.hintText.hasPrefix("Written by Claude Code"), "and says which agent wrote it", sheet.hintText)
        let input = (try? String(contentsOfFile: seen, encoding: .utf8)) ?? ""
        check(input.contains("The changes:") && input.contains("+hello"), "the agent read the staged changes", String(input.suffix(200)))
        check(CommitSheet.current === sheet && gitOutput(git, repo, ["rev-parse", "HEAD"]) == head, "and nothing is committed: the sheet waits for you")
        sheet.type("Fix the greeting\n\nSays hello, as an agent wrote and you edited.")
        sheet.pressCommit()
        check(await wait(10) { gitOutput(git, repo, ["log", "-1", "--format=%s"]) == "Fix the greeting" }, "you commit it, edited",
              gitOutput(git, repo, ["log", "-1", "--format=%B"]))
        GitToast.dismiss()
    }
}

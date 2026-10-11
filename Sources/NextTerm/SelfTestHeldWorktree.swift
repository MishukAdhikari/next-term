import AppKit
import NextTermCore

/// A branch another worktree has, in a repository of its own: checking it out offers Remove Worktree and Switch when
/// that worktree is clean with nothing open in it, and the switch follows the remove; a git command in a terminal tab
/// refused for the same reason brings a notice whose Free It… removes that worktree, with no switch; a removed
/// worktree leaves Recent Projects. Git › Worktrees… opens Branches at the worktrees. The clicks are the buttons' own.
extension SelfTest {
    static func heldWorktreeChecks(_ c: TerminalWindowController) async {
        guard let git = GitRunner.locateGit(), let window = c.window, let app = AppDelegate.shared else { return note("held worktree: skipped, no git or window") }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-held-\(getpid())"
        try? fm.removeItem(atPath: base)
        let repo = base + "/app", devTree = base + "/app-wt-dev", featureTree = base + "/app-wt-feature"
        try? fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let recentBefore = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
        defer {
            GitToast.dismiss()
            app.setRecentProjects(recentBefore)
            for tree in [devTree, featureTree] { gitOutput(git, repo, ["worktree", "remove", "--force", tree]) }
            try? fm.removeItem(atPath: base)
        }
        @discardableResult func sh(_ args: String...) -> String { gitOutput(git, repo, args) }
        func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        func fields(_ view: NSView) -> [NSTextField] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields($0) } }
        func sheetText() -> String { window.attachedSheet?.contentView.map(fields)?.map(\.stringValue).joined(separator: " | ") ?? "" }
        func offered() -> [String] { window.attachedSheet?.contentView.map(buttons)?.map(\.title) ?? [] }
        func press(_ title: String) async -> Bool {
            guard await wait(8, { offered().contains(title) }),
                  let button = window.attachedSheet?.contentView.map(buttons)?.first(where: { $0.title == title }) else { return false }
            button.performClick(nil)
            return true
        }
        try? "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        sh("init", "-q", "-b", "main")
        sh("add", "-A")
        sh("commit", "-q", "-m", "start")
        sh("branch", "dev")
        sh("branch", "feature")
        sh("worktree", "add", "-q", devTree, "dev")
        sh("worktree", "add", "-q", featureTree, "feature")
        app.setRecentProjects(recentBefore.filter { $0 != devTree } + [devTree])

        // Checkout dev: its worktree is clean with nothing open in it, so Remove Worktree and Switch comes first.
        var made: GitActions?
        c.withGit(at: repo) { made = $0 }
        _ = await wait(15) { made != nil }
        if let actions = made, let dev = actions.model?.local("dev") {
            actions.checkout(dev)
            let asked = await wait(10) { sheetText().contains("“dev” is checked out in “app-wt-dev”") }
            check(asked && offered() == ["Remove Worktree and Switch", "Open Worktree", "Cancel"] && sheetText().contains("It has no changes and nothing open in it."),
                  "held worktree: checking out a branch a clean worktree has offers Remove Worktree and Switch first", "\(sheetText()) | \(offered())")
            if asked { _ = await press("Remove Worktree and Switch") }
            let switched = await wait(15) { !fm.fileExists(atPath: devTree) && sh("rev-parse", "--abbrev-ref", "HEAD") == "dev" }
            check(switched && !sh("branch", "--list", "dev").isEmpty, "held worktree: the worktree goes, the branch stays, and the switch follows",
                  "\(sh("worktree", "list")), HEAD \(sh("rev-parse", "--abbrev-ref", "HEAD"))")
            check(!(UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []).contains(devTree), "held worktree: the removed worktree leaves Recent Projects")
            GitToast.dismiss()
        } else {
            check(false, "held worktree: the branches of the scratch repository are read")
        }

        // A git command in a terminal tab refused because a worktree has the branch: a notice, and Free It… removes that
        // worktree only (the command is the user's to run again).
        let tab = c.addTab(directory: repo)
        if await wait(20, { tab.status.integrated }) {
            tab.view.send(txt: "git switch feature\r")
            let noticed = await wait(15) { GitToast.text == "“feature” is checked out in “app-wt-feature”" }
            check(noticed, "held worktree: a git command refused in a terminal tab brings a notice naming the branch and the worktree", GitToast.text ?? "no notice")
            if noticed {
                GitToast.pressButtonForTest()
                let asked = await wait(10) { offered().first == "Remove Worktree" }
                check(asked && !offered().contains("Remove Worktree and Switch"), "held worktree: its Free It… offers Remove Worktree, with no switch", offered().joined(separator: ", "))
                if asked { _ = await press("Remove Worktree") }
                let freed = await wait(15) { !fm.fileExists(atPath: featureTree) && GitToast.text == "Removed app-wt-feature: feature is free" }
                check(freed && sh("rev-parse", "--abbrev-ref", "HEAD") == "dev", "held worktree: Free It… removes the worktree and says the branch is free, switching nothing",
                      GitToast.text ?? "no notice")
            }
        } else {
            check(false, "held worktree: a terminal tab in the scratch repository starts")
        }
        c.closeTab(nil)

        // Git › Worktrees…: Branches, the first worktree chosen.
        sh("worktree", "add", "-q", featureTree, "feature")
        let item = NSApp.mainMenu?.items.first { $0.title == "Git" }?.submenu?.items.first { $0.action == #selector(TerminalWindowController.showWorktrees(_:)) }
        check(item?.title == "Worktrees…", "held worktree: Git › Worktrees… is in the menu", item?.title ?? "none")
        let popup = c.branchPopup
        popup.focusWorktrees = true
        c.showBranches(at: repo, query: "")
        func chosen() -> String { popup.rowTitles[safe: popup.tableView.selectedRow] ?? "nothing chosen" }
        let onIt = await wait(15) { chosen() == "worktree app-wt-feature" }
        check(onIt, "held worktree: Git › Worktrees… opens Branches with the first worktree chosen", chosen())
        popup.close()
    }
}

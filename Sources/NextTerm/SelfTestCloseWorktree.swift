import AppKit
import NextTermCore

/// Close and Remove Worktree, in a repository of its own: closing a linked worktree's window while a program runs in it
/// offers it apart, under Cancel and past “or”, saying the folder goes and the branch stays. With a changed file there the worktree stays,
/// saying why, and Cancel keeps the window; clean, the window closes, its program ends, the folder goes and the branch
/// stays. The clicks are the buttons' own.
extension SelfTest {
    static func closeWorktreeChecks() async {
        guard let git = GitRunner.locateGit(), let app = AppDelegate.shared else { return note("close and remove worktree: skipped, no git") }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-closewt-\(getpid())"
        try? fm.removeItem(atPath: base)
        let repo = base + "/app", tree = base + "/app-wt-agent"
        try? fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        @discardableResult func sh(_ args: String...) -> String { gitOutput(git, repo, args) }
        try? "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        sh("init", "-q", "-b", "main")
        sh("add", "-A")
        sh("commit", "-q", "-m", "start")
        sh("worktree", "add", "-q", "-b", "agent/x", tree)
        let w = app.openWorktreeWindow(tree)
        defer {
            GitToast.dismiss()
            if !w.hasClosed { w.window?.close() }
            sh("worktree", "remove", "--force", tree)
            try? fm.removeItem(atPath: base)
        }
        guard let window = w.window, let tab = w.activeTab else { return check(false, "close and remove worktree: the worktree's window opens") }
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
        // A program running, so closing asks; the sidebar's git read, so the question names the branch.
        guard await wait(20, { tab.status.integrated }) else { return check(false, "close and remove worktree: a tab in the worktree starts") }
        tab.view.send(txt: "sleep 300\r")
        guard await wait(10, { !w.busyTabs.isEmpty && w.sidebar.git.snapshot?.branch == "agent/x" }) else {
            return check(false, "close and remove worktree: a program runs in the worktree's tab", "busy \(w.busyTabs.count), branch \(w.sidebar.git.snapshot?.branch ?? "none")")
        }

        // A changed file: the worktree stays and says why; Cancel keeps the window.
        try? "new\n".write(toFile: tree + "/new.txt", atomically: true, encoding: .utf8)
        window.performClose(nil)
        let asked = await wait(10) { sheetText().contains("Close this window?") }
        // Top to bottom as drawn: the alternative under Cancel, past the rule with "or", red, its note under it. Laid out first:
        // a sheet over a window of an app that isn't in front may not have been yet.
        window.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
        let drawn = (AlternativeAlert.current?.buttons ?? []).sorted { $0.frame.minY > $1.frame.minY }
        let parts: [(String, Bool)] = [
            ("offered", offered() == ["Close Window", "Cancel", "Close and Remove Worktree"]), ("drawn in that order", drawn.map(\.title) == offered()),
            ("red", drawn.last?.hasDestructiveAction == true), ("Return", drawn.first?.keyEquivalent == "\r"),
            ("Escape", drawn[safe: 1]?.keyEquivalent == "\u{1b}"),
            ("text", sheetText().contains("| or | Deletes its folder, with the ignored files in it. The branch agent/x stays, with its commits.")),
        ]
        check(asked && parts.allSatisfy(\.1),
              "close and remove worktree: a worktree's Close Window question sets it apart under Cancel, past “or”, saying the branch stays",
              "not: " + parts.filter { !$0.1 }.map(\.0).joined(separator: ", ") + " | \(drawn.map { "\($0.title)@\(Int($0.frame.minY))" }) | \(sheetText())")
        if asked { _ = await press("Close and Remove Worktree") }
        let stays = await wait(15) { sheetText().contains("“app-wt-agent” can’t be removed now") }
        check(stays && offered() == ["Close Window", "Cancel"] && sheetText().contains("It has 1 changed file. Commit or discard them first"),
              "close and remove worktree: with a changed file it stays, saying why, and Close Window is still offered", "\(sheetText()) | \(offered())")
        if stays { _ = await press("Cancel") }
        let kept = await wait(5) { window.attachedSheet == nil }
        check(kept && !w.hasClosed && fm.fileExists(atPath: tree + "/new.txt") && !w.busyTabs.isEmpty,
              "close and remove worktree: Cancel keeps the window, its program and the worktree")

        // Clean: the window closes, its program ends, the folder goes, the branch stays.
        try? fm.removeItem(atPath: tree + "/new.txt")
        window.performClose(nil)
        if await wait(10, { sheetText().contains("Close this window?") }) { _ = await press("Close and Remove Worktree") }
        let gone = await wait(20) { w.hasClosed && !fm.fileExists(atPath: tree) }
        check(gone && !sh("branch", "--list", "agent/x").isEmpty && !sh("worktree", "list").contains("app-wt-agent"),
              "close and remove worktree: the window closes, the worktree goes and its branch stays", sh("worktree", "list"))
        check(tab.exited, "close and remove worktree: the program in it ended")
    }
}

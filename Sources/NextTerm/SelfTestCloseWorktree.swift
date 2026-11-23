import AppKit
import NextTermCore

/// Removal on close, in a repository of its own with a remote: closing a linked worktree's window always asks one
/// question, busy or idle. Clean and pushed, it offers Close and Remove Worktree apart, under Cancel and past “or”,
/// saying the folder goes and the branch stays; Return is Close Window and Escape Cancel. With a changed file the same
/// question says so and offers only Close Window and Cancel; several reasons are all listed, in order; commits not
/// pushed are a note, never a refusal. Busy, the stop text and the removal share the question, and removing ends the
/// window's program first. Then the offer once an agent ends: a worktree it worked in with no window on it gets one
/// notice that stays until answered (Keep never repeats; Remove removes it and keeps its branch), and one with a change
/// gets none. The clicks are the buttons' own.
extension SelfTest {
    static func closeWorktreeChecks() async {
        guard let git = GitRunner.locateGit(), let app = AppDelegate.shared else { return note("close and remove worktree: skipped, no git") }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-closewt-\(getpid())"
        try? fm.removeItem(atPath: base)
        let repo = base + "/app", tree = base + "/app-wt-agent", remote = base + "/remote.git"
        let kept = base + "/app-wt-kept", dirty = base + "/app-wt-dirty", removed = base + "/app-wt-removed"
        try? fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        @discardableResult func sh(_ args: String...) -> String { gitOutput(git, repo, args) }
        try? "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        sh("init", "-q", "-b", "main")
        sh("add", "-A")
        sh("commit", "-q", "-m", "start")
        sh("init", "-q", "--bare", remote)
        sh("remote", "add", "origin", remote)
        sh("push", "-q", "origin", "main")
        sh("worktree", "add", "-q", "-b", "agent/x", tree)
        sh("push", "-q", "origin", "agent/x")
        let w = app.openWorktreeWindow(tree)
        let offered = [kept, dirty, removed]
        defer {
            GitToast.dismiss()
            if !w.hasClosed { w.window?.close() }
            for path in [tree] + offered { sh("worktree", "remove", "--force", path) }
            UserDefaults.standard.set(WorktreeEndOffer.answered.filter { !offered.contains($0) }, forKey: "worktreeRemovalOffered")
            try? fm.removeItem(atPath: base)
        }
        guard let window = w.window, let tab = w.activeTab else { return check(false, "close and remove worktree: the worktree's window opens") }
        func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        func fields(_ view: NSView) -> [NSTextField] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields($0) } }
        func sheetText() -> String { window.attachedSheet?.contentView.map(fields)?.map(\.stringValue).joined(separator: " | ") ?? "" }
        func choices() -> [String] { window.attachedSheet?.contentView.map(buttons)?.map(\.title) ?? [] }
        func press(_ title: String) async -> Bool {
            guard await wait(8, { choices().contains(title) }),
                  let button = window.attachedSheet?.contentView.map(buttons)?.first(where: { $0.title == title }) else { return false }
            button.performClick(nil)
            return true
        }
        /// Closes the window and waits for its one question.
        func ask() async -> Bool {
            window.performClose(nil)
            return await wait(15) { sheetText().contains("Close this window?") }
        }
        func cancel() async -> Bool {
            _ = await press("Cancel")
            return await wait(5) { window.attachedSheet == nil } && !w.hasClosed
        }
        let all = ["Close Window", "Cancel", "Close and Remove Worktree"]
        guard await wait(20, { tab.status.integrated }) else { return check(false, "close and remove worktree: a tab in the worktree starts") }

        // Idle, clean and pushed: asked all the same, removal offered apart.
        let asked = await ask()
        // Top to bottom as drawn: the alternative under Cancel, past the rule with "or", red, its note under it. Laid out first:
        // a sheet over a window of an app that isn't in front may not have been yet.
        window.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
        let drawn = (AlternativeAlert.current?.buttons ?? []).sorted { $0.frame.minY > $1.frame.minY }
        let parts: [(String, Bool)] = [
            ("offered", choices() == all), ("drawn in that order", drawn.map(\.title) == choices()),
            ("red", drawn.last?.hasDestructiveAction == true), ("Return", drawn.first?.keyEquivalent == "\r"),
            ("Escape", drawn[safe: 1]?.keyEquivalent == "\u{1b}"), ("never the default", drawn.last?.keyEquivalent == ""),
            ("text", sheetText().contains("| or | Deletes its folder, with the ignored files in it. The branch agent/x stays, with its commits.")),
            ("nothing unpushed", !sheetText().contains("not pushed")), ("no stop text", !sheetText().contains("Closing it stops")),
        ]
        check(asked && parts.allSatisfy(\.1),
              "close and remove worktree: an idle worktree window's close asks, offering removal apart under Cancel, past “or”, saying the branch stays",
              "not: " + parts.filter { !$0.1 }.map(\.0).joined(separator: ", ") + " | \(drawn.map { "\($0.title)@\(Int($0.frame.minY))" }) | \(sheetText())")
        check(await cancel(), "close and remove worktree: Cancel keeps the window")

        // A changed file: the one question says so and offers only Close Window and Cancel.
        try? "new\n".write(toFile: tree + "/new.txt", atomically: true, encoding: .utf8)
        let changed = await ask()
        check(changed && choices() == ["Close Window", "Cancel"] && sheetText().contains("The worktree can’t be removed now:\nIt has 1 changed file."),
              "close and remove worktree: with a changed file the first question says “1 changed file” and offers only Close Window and Cancel",
              "\(sheetText()) | \(choices())")
        check(await cancel() && fm.fileExists(atPath: tree + "/new.txt"), "close and remove worktree: Cancel keeps the window and the changed file")

        // A lock and a change: both listed, the lock first.
        sh("worktree", "lock", "--reason", "kept for a test", tree)
        let both = await ask()
        let text = sheetText()
        let lock = text.range(of: "It is locked: kept for a test."), change = text.range(of: "It has 1 changed file.")
        check(both && choices() == ["Close Window", "Cancel"] && lock != nil && change != nil && lock!.lowerBound < change!.lowerBound,
              "close and remove worktree: every reason it stays is listed, in order", text)
        _ = await cancel()
        sh("worktree", "unlock", tree)
        try? fm.removeItem(atPath: tree + "/new.txt")

        // Three commits not pushed: still offered, with a note saying so.
        for n in 1...3 {
            try? "\(n)\n".write(toFile: tree + "/a.txt", atomically: true, encoding: .utf8)
            sh("-C", tree, "commit", "-qam", "Step \(n)")
        }
        let unpushed = await ask()
        check(unpushed && choices() == all && sheetText().contains("It keeps 3 commits not pushed yet."),
              "close and remove worktree: commits not pushed are a note, and removal is still offered", "\(sheetText()) | \(choices())")
        _ = await cancel()

        // The offer once an agent ends, for worktrees no window has open, while this window is in front.
        sh("worktree", "add", "-q", "-b", "agent/kept", kept)
        sh("worktree", "add", "-q", "-b", "agent/dirty", dirty)
        sh("worktree", "add", "-q", "-b", "agent/removed", removed)
        try? "new\n".write(toFile: dirty + "/new.txt", atomically: true, encoding: .utf8)
        window.makeKeyAndOrderFront(nil)
        WorktreeEndOffer.agentsEnded(["self-test-dirty"], history: ["self-test-dirty": [dirty]])
        let quiet = await wait(4) { GitToast.text?.contains("app-wt-dirty") == true }
        check(!quiet && !WorktreeEndOffer.answered.contains(dirty), "worktree end offer: a worktree with a change gets no notice, and stays to offer")
        WorktreeEndOffer.agentsEnded(["self-test-kept"], history: ["self-test-kept": [kept]])
        let shown = await wait(10) { GitToast.text?.contains("app-wt-kept") == true }
        check(shown && GitToast.text?.contains("agent/kept stays") == true && GitToast.buttonTitles == ["Remove", "Keep"],
              "worktree end offer: an ended agent's worktree with no window gets one notice naming it and its branch", "\(GitToast.text ?? "none") \(GitToast.buttonTitles)")
        if shown { GitToast.pressOtherButtonForTest() }
        WorktreeEndOffer.agentsEnded(["self-test-kept"], history: ["self-test-kept": [kept]])
        let again = await wait(4) { GitToast.text?.contains("app-wt-kept") == true }
        check(WorktreeEndOffer.answered.contains(kept) && !again && fm.fileExists(atPath: kept), "worktree end offer: Keep keeps it, and it is never offered again")
        WorktreeEndOffer.agentsEnded(["self-test-removed"], history: ["self-test-removed": [removed]])
        if await wait(10, { GitToast.text?.contains("app-wt-removed") == true }) { GitToast.pressButtonForTest() }
        let removedGone = await wait(15) { !fm.fileExists(atPath: removed) }
        check(removedGone && !sh("branch", "--list", "agent/removed").isEmpty, "worktree end offer: Remove removes the folder and keeps the branch")

        // Busy: what closing stops and the removal on the one question; removing ends the program, then the folder goes.
        tab.view.send(txt: "sleep 300\r")
        guard await wait(10, { !w.busyTabs.isEmpty }) else { return check(false, "close and remove worktree: a program runs in the worktree's tab") }
        let busy = await ask()
        check(busy && choices() == all && sheetText().contains("Closing it stops"),
              "close and remove worktree: a busy window's one question says what stops and offers removal", "\(sheetText()) | \(choices())")
        if busy { _ = await press("Close and Remove Worktree") }
        let gone = await wait(20) { w.hasClosed && !fm.fileExists(atPath: tree) }
        check(gone && !sh("branch", "--list", "agent/x").isEmpty && !sh("worktree", "list").contains("app-wt-agent"),
              "close and remove worktree: the window closes, the worktree goes and its branch stays", sh("worktree", "list"))
        check(tab.exited, "close and remove worktree: the program in it ended")
    }
}

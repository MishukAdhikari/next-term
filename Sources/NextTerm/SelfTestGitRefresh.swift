import AppKit
import NextTermCore

/// The sidebar's git refresh, in a repository of its own: a writer in a gitignored `.next/` (as `next dev` is)
/// runs no git, a tracked change still shows within 3 s, a tracked file written twice a second is read at most
/// every 2.5 s, nothing runs while the app is hidden and one refresh runs when it shows again, and a closed
/// project window runs no git at all.
extension SelfTest {
    static func gitRefreshChecks(_ c: TerminalWindowController) async {
        guard let git = GitRunner.locateGit() else { return note("git refresh checks skipped: no git") }
        let base = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-selftest-refresh-\(getpid())")
        try? FileManager.default.removeItem(at: base)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("shop").path
        try? FileManager.default.createDirectory(atPath: repo + "/src", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: repo + "/.next", withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) { try? text.write(toFile: repo + "/" + name, atomically: false, encoding: .utf8) }
        func append(_ name: String, _ text: String) {
            guard let handle = FileHandle(forWritingAtPath: repo + "/" + name) else { return write(name, text) }
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        }
        write(".gitignore", ".next/\n")
        write("src/app.txt", "one\n")
        write("src/log.txt", "start\n")
        for args in [["init", "-q"], ["add", "-A"], ["commit", "-qm", "One"]] { _ = gitOutput(git, repo, args) }
        write(".next/trace", "{}\n") // after the commit; git lists `.next/` as ignored only with something in it

        let w = AppDelegate.shared.openWindow(directory: repo, project: repo)
        let monitor = w.sidebar.git
        var closed = false
        defer {
            if !closed { w.window?.close() }
            c.window?.makeKeyAndOrderFront(nil)
        }
        let read = await wait(15) { monitor.snapshot.map { canonicalPath($0.root) == repo } == true }
        check(read && monitor.snapshot?.wholeFolders[".next"] == .ignored, "git refresh: the repository is read, with .next/ ignored",
              "\(String(describing: monitor.snapshot?.wholeFolders))")
        guard read else { return }
        await pause(1.5) // the opening refresh, and the events of making the repository, are over

        // next dev appends to .next/trace twice a second: no git at all, while the tree stays live.
        var runs = GitRunner.runs(in: repo)
        for i in 0..<20 {
            append(".next/trace", "{\"ts\":\(i)}\n")
            await pause(0.5)
        }
        var ran = GitRunner.runs(in: repo) - runs
        check(ran == 0, "git refresh: a writer in a gitignored .next/ runs no git (10 s, twice a second)", "\(ran) git runs")

        // A tracked change still shows quickly.
        let touched = Date()
        write("src/app.txt", "two\n")
        let shown = await wait(5) { monitor.snapshot?.files["src/app.txt"] == .modified }
        let took = Date().timeIntervalSince(touched)
        check(shown && took <= 3, "git refresh: a tracked change shows in the sidebar within 3 s", String(format: "%.1f s", took))

        // A tracked file written twice a second: read at most every 2.5 s, and seen meanwhile, not only at the end.
        await pause(3)
        let refreshes = monitor.refreshCount
        var seenDuring = false
        for i in 0..<20 {
            append("src/log.txt", "line \(i)\n")
            await pause(0.5)
            if monitor.snapshot?.files["src/log.txt"] == .modified { seenDuring = true }
        }
        await pause(4) // the trailing refresh
        let count = monitor.refreshCount - refreshes
        check(count >= 2 && count <= 6 && seenDuring, "git refresh: a tracked file written twice a second for 10 s is read at most every 2.5 s",
              "\(count) refreshes, seen during the writes \(seenDuring)")

        // Hidden: no git; shown again: one refresh, with the change.
        if let window = w.window, await bringToFront(window) {
            NSApp.hide(nil)
            let hid = await wait(3) { !window.isVisible }
            runs = GitRunner.runs(in: repo)
            let hiddenRefreshes = monitor.refreshCount
            write("src/app.txt", "three\n")
            await pause(3)
            ran = GitRunner.runs(in: repo) - runs
            check(hid && ran == 0, "git refresh: none while the app is hidden", "hidden \(hid), \(ran) git runs")
            NSApp.unhide(nil)
            _ = await bringToFront(window)
            let caughtUp = await wait(5) { monitor.refreshCount > hiddenRefreshes }
            await pause(3)
            check(caughtUp && monitor.refreshCount - hiddenRefreshes == 1, "git refresh: one refresh when the app shows again",
                  "\(monitor.refreshCount - hiddenRefreshes) refreshes")
        } else {
            note("skipped 'git refresh: none while the app is hidden': " + (w.window.map(notFrontmost) ?? "no window"))
        }

        // A closed project window runs no git, whatever changes in its folder (and whatever still holds its sidebar).
        w.closeProject(nil)
        closed = await wait(5) { !AppDelegate.shared.controllers.contains { $0 === w } }
        check(closed, "git refresh: the project window closes")
        await pause(1)
        runs = GitRunner.runs(in: repo)
        write("src/app.txt", "four\n")
        write("src/new.txt", "new\n")
        await pause(3)
        ran = GitRunner.runs(in: repo) - runs
        check(ran == 0, "git refresh: a closed project window runs no git when its files change", "\(ran) git runs")
    }
}

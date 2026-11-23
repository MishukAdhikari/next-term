import AppKit
import NextTermCore

/// The strip above an agent's pane when its agent works in another linked worktree of the window's repository, in a
/// repository of its own with two worktrees beside it and a stand-in Claude Code that moves its own process. The strip
/// names the worktree and its branch, appears only once the tab has been quiet for 2 s, takes no key and leaves the
/// terminal's size alone; Not Now hides it and the header's place label brings it back; a second worktree gets its
/// own; it hides when the agent goes back to the main checkout; in a split tab it sits above the agent's pane only;
/// list_tabs reports it; Open as Project moves the tab into the worktree's window. Screenshots in Light and Dark.
extension SelfTest {
    static func worktreeStripChecks() async {
        guard let app = AppDelegate.shared, let git = GitRunner.locateGit() else { return }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-wtstrip-\(getpid())"
        try? fm.removeItem(atPath: base)
        let repo = base + "/shop", bin = base + "/bin", control = base + "/control"
        let first = base + "/shop-wt-120", second = base + "/shop-wt-130"
        for folder in [repo, bin, control] { try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        @discardableResult func sh(_ args: String...) -> String {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", repo, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        sh("init", "-q")
        try? "hi\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        sh("add", "a.txt")
        sh("commit", "-qm", "One")
        sh("worktree", "add", "-q", "-b", "fix/120-cart", first)
        sh("worktree", "add", "-q", "-b", "fix/130-tax", second)
        // A stand-in for Claude Code: it works in the folder its control file names, once that appears.
        let script = """
        #!/bin/sh
        \(stopsOnCtrlC)
        while true; do
          if [ -f "$CTL/dir" ]; then IFS= read -r d < "$CTL/dir"; cd "$d"; rm -f "$CTL/dir"; fi
          printf '\\r\\033[K> %s' "$SECONDS"
          \(standInWait("0.3"))
        done

        """
        fm.createFile(atPath: bin + "/claude", contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        let savedTarget = app.projectTarget, savedAppearance = Preferences.appearance
        app.projectTarget = .newWindow
        SessionStore.home = base + "/home"
        let holder = app.openWindow(directory: repo, project: canonicalPath(repo))
        var made: [TerminalWindowController] = [holder]
        defer {
            app.projectTarget = savedTarget
            Preferences.appearance = savedAppearance
            SessionStore.home = sessionsHome
            for controller in made where !controller.hasClosed {
                _ = TerminalTab.terminate(controller.tabs, finishLater: true)
                controller.window?.close()
            }
            try? fm.removeItem(atPath: base)
        }
        if !holder.isSidebarVisible { holder.toggleProjectSidebar(nil) }
        guard let agent = holder.tabs.first else { return check(false, "worktree strip: the repository's window has a tab") }
        _ = await wait(20) { agent.status.integrated }
        agent.view.send(txt: "CTL=\(ShellQuote.quote(control)) PATH=\(ShellQuote.quote(bin)):$PATH claude\r")
        _ = await wait(10) { agent.status.running && agent.status.kind == .agent }
        func place() -> String? { AgentPlaces.shared.places[agent.id.uuidString].map { canonicalPath($0.checkout.path) } }
        check(await wait(10) { place() == canonicalPath(repo) }, "worktree strip: a stand-in Claude Code runs in the main checkout",
              place() ?? "nowhere yet")
        guard let pane = holder.paneView(of: agent) else { return check(false, "worktree strip: the agent's tab has its pane") }
        let strip = pane.worktreeStrip
        check(strip.isHidden && strip.worktree == nil, "worktree strip: none while the agent works in the window's own checkout")
        let size = { (agent.view.getTerminal().cols, agent.view.getTerminal().rows) }
        let before = size()

        // Into the first worktree, the tab quiet: the strip names it and its branch.
        try? first.write(toFile: control + "/dir", atomically: true, encoding: .utf8)
        check(await wait(12) { strip.worktree?.path == canonicalPath(first) && !strip.isHidden },
              "worktree strip: the strip shows once the agent works in another worktree", strip.messageForTest)
        check(strip.messageForTest == "This tab\u{2019}s agent works in shop-wt-120 (fix/120-cart).",
              "worktree strip: it names the worktree and its branch", strip.messageForTest)
        check(strip.buttonsForTest == ["Not Now", "Open as Project"] && strip.primaryKeyForTest.isEmpty && !strip.buttonsTakeKeysForTest,
              "worktree strip: Not Now and Open as Project, which takes no key", "\(strip.buttonsForTest)")
        check(strip.accessibilityLabel() == strip.messageForTest, "worktree strip: VoiceOver hears its words", strip.accessibilityLabel() ?? "")
        await pause(0.5)
        check(size() == before, "worktree strip: the terminal keeps its size while it shows", "\(before) → \(size())")
        check(AgentPlaces.shared.fields(of: agent, in: holder)["worktree_offer"] as? String == "offered",
              "worktree strip: list_tabs says it was offered", "\(AgentPlaces.shared.fields(of: agent, in: holder))")
        Preferences.appearance = .dark
        await screenshot(holder, suffix: "worktree-strip-dark")
        Preferences.appearance = .light
        await screenshot(holder, suffix: "worktree-strip-light")
        Preferences.appearance = savedAppearance

        // Not Now: hidden, the terminal keeps the keyboard and its size; the header's place label brings it back.
        holder.window?.makeFirstResponder(agent.view)
        strip.pressForTest("Not Now")
        check(await wait(3) { strip.worktree == nil }, "worktree strip: Not Now hides it")
        check(holder.window?.firstResponder === agent.view, "worktree strip: the terminal keeps the keyboard")
        await pause(1.5)
        check(strip.worktree == nil && AgentPlaces.shared.fields(of: agent, in: holder)["worktree_offer"] as? String == "dismissed",
              "worktree strip: and it does not come back by itself", "\(AgentPlaces.shared.fields(of: agent, in: holder))")
        let header = holder.sidebar.header
        check(await wait(3) { header.tabPlace.place?.bringsBackOffer == true && header.tabPlace.place?.hasChoices == true },
              "worktree strip: the header's place label offers it again", header.tabPlace.toolTip ?? "")
        _ = header.tabPlace.accessibilityPerformPress()
        check(await wait(3) { strip.worktree?.path == canonicalPath(first) }, "worktree strip: a click on the place label brings it back")
        check(size() == before, "worktree strip: the terminal kept its size all along", "\(before) → \(size())")

        // A second worktree while the person types: no strip until 2 s after the last key, then its own.
        let moved = Date()
        try? second.write(toFile: control + "/dir", atomically: true, encoding: .utf8)
        var early = false
        while Date().timeIntervalSince(moved) < 6 {
            agent.userInput()
            if strip.worktree?.path == canonicalPath(second) { early = true }
            await pause(0.3)
        }
        let quiet = Date()
        check(!early && place() == canonicalPath(second), "worktree strip: none for the second worktree while the person types",
              place() ?? "nowhere")
        check(await wait(5) { strip.worktree?.path == canonicalPath(second) }, "worktree strip: the second worktree gets its own")
        let after = Date().timeIntervalSince(quiet)
        check(after >= 1.5, "worktree strip: about 2 s after the last key, not before", String(format: "%.1f s", after))

        // Back to the main checkout: hidden.
        try? repo.write(toFile: control + "/dir", atomically: true, encoding: .utf8)
        check(await wait(8) { strip.worktree == nil }, "worktree strip: it hides when the agent goes back to the window's checkout")

        // A split tab: above the agent's pane only.
        try? second.write(toFile: control + "/dir", atomically: true, encoding: .utf8)
        holder.show(agent)
        let shell = holder.split(vertical: true, from: agent, focus: false)
        check(await wait(8) { strip.worktree?.path == canonicalPath(second) }, "worktree strip: it shows above the agent's pane in a split tab")
        if let shell, let other = holder.paneView(of: shell) {
            check(other.worktreeStrip.worktree == nil && other.worktreeStrip.isHidden, "worktree strip: and not above the other pane")
        }

        // Open as Project: the tab moves, live, into the worktree's own window, and the offer is answered.
        strip.pressForTest("Open as Project")
        let destination = await wait(8) { app.controllers.contains { $0.project == canonicalPath(second) && $0.tabs.contains { $0 === agent } } }
        made += app.controllers.filter { $0.project == canonicalPath(second) }
        check(destination && agent.status.running, "worktree strip: Open as Project moves the agent's tab into the worktree's window")
        check(await wait(3) { holder.paneView(of: agent) == nil && strip.worktree == nil },
              "worktree strip: no strip once the window shows the worktree")
        agent.view.send(txt: "\u{03}")
    }
}

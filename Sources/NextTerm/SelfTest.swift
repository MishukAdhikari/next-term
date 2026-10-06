import AppKit
import NextTermCore

/// End-to-end check of the real app: real shells, real tabs, real status changes.
/// Run with `NextTerm --self-test <report-path>`; writes PASS/FAIL lines and quits.
@MainActor
enum SelfTest {
    nonisolated static var isRequested: Bool { CommandLine.arguments.contains("--self-test") }

    private static var lines: [String] = []
    private static var failures = 0

    static func run() {
        Task { @MainActor in
            await runAll()
            finish()
        }
    }

    private static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        let d = detail()
        lines.append("\(ok ? "PASS" : "FAIL") \(name)\(ok || d.isEmpty ? "" : " — \(d)")")
    }

    private static func note(_ text: String) { lines.append("NOTE \(text)") }

    private static func wait(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func runAll() async {
        guard let c = AppDelegate.shared.controllers.first, let window = c.window else {
            check(false, "a window opens at launch")
            return
        }
        check(c.tabs.count == 1, "one tab at launch")
        note("app active: \(NSApp.isActive), key window: \(window.isKeyWindow)")

        let first = c.tabs[0]
        check(await wait(20) { first.status.integrated }, "zsh integration reports in", "no OSC 6973 from the shell")

        // The tab bar sits in the title-bar area; clicks there must reach the tabs, not the title bar.
        c.tabBar.layoutSubtreeIfNeeded()
        if let frameView = window.contentView?.superview {
            // Inside the first tab, within the top 12 points that belong to the title bar.
            let point = c.tabBar.convert(NSPoint(x: c.tabBar.leadingInset + 40, y: 12), to: nil)
            let hit = frameView.hitTest(point)
            var v: NSView? = hit
            var hitsTab = false
            while let view = v { if String(describing: type(of: view)) == "TabItemView" { hitsTab = true; break }; v = view.superview }
            check(hitsTab, "clicks in the title-bar strip reach the tab", "hit \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
        }

        // Menu routing: no responder in front of the controller may claim one of its actions
        // (NSWindow implements toggleSidebar:/selectNextTab: and would swallow them).
        var chain: [NSResponder] = []
        var responder: NSResponder? = first.view
        while let r = responder, r !== c { chain.append(r); responder = r.nextResponder }
        if !chain.contains(where: { $0 === window }) { chain.append(window) }
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        var swallowed: [String] = []
        var routed = 0
        for item in items(NSApp.mainMenu ?? NSMenu()) {
            guard let action = item.action, item.target == nil, c.responds(to: action) else { continue }
            routed += 1
            if let thief = chain.first(where: { $0.responds(to: action) }) {
                swallowed.append("\(item.title) -> \(type(of: thief))")
            }
        }
        check(routed >= 8 && swallowed.isEmpty, "menu shortcuts reach the window controller (\(routed) checked)",
              swallowed.joined(separator: ", "))

        // New tab opens in the current tab's directory.
        first.view.send(txt: "cd /tmp\r")
        check(await wait(5) { first.directory == "/tmp" }, "cwd is tracked", first.directory)
        let sentThroughMenu = NSApp.keyWindow === window
        if sentThroughMenu {
            NSApp.sendAction(#selector(TerminalWindowController.newTab(_:)), to: nil, from: nil)
        } else {
            note("window is not key (app launched in background); calling newTab directly")
            c.newTab(nil)
        }
        check(c.tabs.count == 2 && c.activeIndex == 1, "⌘T opens a second tab and selects it", "tabs=\(c.tabs.count) active=\(c.activeIndex)")
        let second = c.tabs[1]
        check(await wait(20) { second.status.integrated }, "second tab's shell starts")
        check(second.currentDirectory() == "/private/tmp", "new tab opens in the same directory", second.currentDirectory())

        // Foreground process lookup through the kernel.
        second.view.send(txt: "sleep 1.5\r")
        check(await wait(3) { ProcessInspector.foreground(ptyFileDescriptor: second.view.process.childfd,
                                                          shellPid: second.view.process.shellPid, shellName: "zsh")?.name == "sleep" },
              "foreground process is read from the pty")
        check(second.status.state == .working, "running command shows working", second.status.state.rawValue)
        check(await wait(5) { !second.status.running }, "command end is detected")

        // Failure in a background tab.
        second.view.send(txt: "sleep 1; false\r")
        check(await wait(3) { second.status.running }, "command start is detected")
        c.select(0)
        check(await wait(5) { second.status.state == .failed }, "background failure shows red", second.status.state.rawValue)
        check(second.status.exitCode == 1, "exit code is captured", "\(String(describing: second.status.exitCode))")
        check(NSApp.dockTile.badgeLabel == "1", "dock badge counts it", NSApp.dockTile.badgeLabel ?? "nil")
        c.select(1)
        c.refreshVisibility()
        if NSApp.isActive && window.isKeyWindow {
            check(second.status.state == .idle, "looking at the tab clears it", second.status.state.rawValue)
        } else {
            note("skipped 'looking clears it': app is not frontmost")
            second.status.setVisible(true)
        }

        // Success in a background tab.
        second.view.send(txt: "sleep 1\r")
        _ = await wait(3) { second.status.running }
        c.select(0)
        check(await wait(5) { second.status.state == .done }, "background success shows green", second.status.state.rawValue)

        // Bell in a background tab.
        c.select(1)
        second.status.setVisible(true)
        second.view.send(txt: "sleep 0.5; printf '\\a'\r")
        _ = await wait(3) { second.status.running }
        c.select(0)
        check(await wait(5) { second.status.state == .attention }, "bell shows attention", second.status.state.rawValue)

        // An agent: prints for a while, then waits for input without exiting.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nextterm-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let agent = dir.appendingPathComponent("claude")
        try? """
        #!/bin/sh
        i=0; while [ $i -lt 8 ]; do echo "thinking $i"; sleep 0.2; i=$((i+1)); done
        echo "waiting for you"; read answer; echo "got $answer"
        """.write(to: agent, atomically: true, encoding: .utf8)
        chmod(agent.path, 0o755)
        c.select(1)
        second.status.setVisible(true)
        second.view.send(txt: "PATH=\(dir.path):$PATH claude\r")
        _ = await wait(3) { second.status.running }
        check(second.status.kind == .agent, "agent is recognised", "\(second.status.kind)")
        c.select(0)
        check(await wait(3) { second.status.state == .working }, "agent printing shows working", second.status.state.rawValue)
        check(await wait(8) { second.status.state == .done }, "agent going quiet shows done (waiting for you)", second.status.state.rawValue)
        check(second.status.running, "agent is still running while it waits")
        c.select(1)
        second.view.send(txt: "yes\r")
        check(await wait(5) { !second.status.running }, "agent exits after input")

        // Security: output cannot fake the shell's status marks (no nonce), …
        c.select(1)
        second.status.setVisible(true)
        second.view.send(txt: "sleep 2; printf '\\e]6973;end;0\\a\\e]6973;deadbeef;end;0\\a'; sleep 1\r")
        _ = await wait(3) { second.status.running }
        await pause(2.4)
        check(second.status.running, "forged status marks in output are ignored")
        _ = await wait(4) { !second.status.running }

        // … programs cannot read the clipboard (OSC 52 query gets no answer), …
        let reply = dir.appendingPathComponent("osc52-reply")
        // read -k: any reply (it would start with ESC ] 52) arrives without a newline, so read raw characters.
        second.view.send(txt: "printf '\\e]52;c;?\\a'; read -s -t 1 -k 4 x; print -rn -- \"${x-}\" > \(reply.path)\r")
        _ = await wait(4) { FileManager.default.fileExists(atPath: reply.path) && !second.status.running }
        let answer = (try? String(contentsOf: reply, encoding: .utf8)) ?? "missing"
        check(answer.isEmpty, "OSC 52 clipboard reads get no answer", answer.prefix(40).description)

        // … a dropped file name cannot run a command, …
        let trap = dir.appendingPathComponent("notes\u{15} touch PWNED\r.txt")
        try? Data().write(to: trap)
        second.view.send(txt: "cd \(ShellQuote.quote(dir.path))\r")
        _ = await wait(3) { !second.status.running }
        second.view.typeIn("ls -l " + ShellQuote.quote(trap.path))
        await pause(1)
        check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("PWNED").path), "a hostile file name typed in runs nothing")
        second.view.send(txt: "\r")
        _ = await wait(3) { second.status.command.hasPrefix("ls -l") && !second.status.running }
        check(second.status.exitCode == 0 && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("PWNED").path),
              "… and still names the right file", "\(String(describing: second.status.exitCode))")

        // … and opening a script asks first, even behind a harmless-looking symlink.
        let script = dir.appendingPathComponent("x.command")
        try? "#!/bin/sh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        let disguise = dir.appendingPathComponent("readme.md")
        try? FileManager.default.createSymbolicLink(at: disguise, withDestinationURL: script)
        let doc = dir.appendingPathComponent("notes.md")
        try? "# notes".write(to: doc, atomically: true, encoding: .utf8)
        check(SafeOpen.runsCode(script) != nil, "a .command script is recognised as code")
        check(SafeOpen.target(of: disguise).flatMap(SafeOpen.runsCode) != nil, "a symlink disguised as readme.md is too")
        let alias = dir.appendingPathComponent("guide.md")
        if let bookmark = try? script.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil) {
            try? URL.writeBookmarkData(bookmark, to: alias)
            check(SafeOpen.target(of: alias)?.lastPathComponent == "x.command" && SafeOpen.target(of: alias).flatMap(SafeOpen.runsCode) != nil,
                  "so is a Finder alias disguised as guide.md")
        }
        check(SafeOpen.runsCode(doc) == nil, "a plain document opens without a prompt", SafeOpen.runsCode(doc) ?? "")
        let py = dir.appendingPathComponent("tool.py")
        try? "print(1)".write(to: py, atomically: true, encoding: .utf8)
        if let app = NSWorkspace.shared.urlForApplication(toOpen: py), Bundle(url: app)?.bundleIdentifier == "org.python.PythonLauncher" {
            check(SafeOpen.runsCode(py) != nil, "a .py that would run in Python Launcher asks first")
        }

        // A job suspended with Ctrl-Z makes closing ask, and says which job.
        c.select(1)
        second.status.setVisible(true)
        second.view.send(txt: "sleep 30\r")
        _ = await wait(3) { second.status.running }
        second.view.send(txt: "\u{1a}")
        check(await wait(4) { second.status.jobs == 1 }, "a suspended job is reported", "jobs=\(second.status.jobs)")
        check(second.closeWarning?.contains("sleep 30") == true, "closing warns about the suspended job", second.closeWarning ?? "nil")
        second.view.send(txt: "kill %1\r")
        check(await wait(4) { second.status.jobs == 0 && second.closeWarning == nil }, "and stops warning once it is gone")

        // The screen cannot be read back through DECRQCRA: every checksum is 0000.
        let checksum = dir.appendingPathComponent("decrqcra")
        second.view.send(txt: "printf 'XYZ\\e[1;1;1;1;1;3*y'; read -s -t 2 -d '\\\\' x; print -rn -- \"${x-}\" > \(checksum.path)\r")
        _ = await wait(4) { FileManager.default.fileExists(atPath: checksum.path) && !second.status.running }
        let checksumReply = (try? String(contentsOf: checksum, encoding: .isoLatin1)) ?? ""
        check(checksumReply.contains("!~0000"), "screen checksum requests are answered with 0000", checksumReply.debugDescription)

        // ⌘V drops escape characters (the user's clipboard is put back afterwards).
        let savedClipboard = NSPasteboard.general.string(forType: .string)
        let pasted = dir.appendingPathComponent("pasted")
        second.view.send(txt: "cat > \(pasted.path)\r")
        _ = await wait(3) { second.status.running }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("a\u{1b}[201~b\n", forType: .string)
        second.view.paste(self)
        second.view.send(txt: "\u{04}")
        _ = await wait(4) { !second.status.running }
        NSPasteboard.general.clearContents()
        if let savedClipboard { NSPasteboard.general.setString(savedClipboard, forType: .string) }
        let pastedText = (try? String(contentsOf: pasted, encoding: .utf8)) ?? "missing"
        check(pastedText == "a[201~b\n", "pasted text loses its escape characters", pastedText.debugDescription)

        // `exec bash`: the kernel reports the exec, and polling takes over: commands, cd, exit status.
        let fallback = c.addTab(directory: nil)
        _ = await wait(20) { fallback.status.integrated }
        fallback.view.send(txt: "exec /bin/bash --norc --noprofile\r")
        check(await wait(5) { !fallback.status.integrated }, "an exec'd shell drops back to process polling")
        fallback.view.send(txt: "cd /tmp\r")
        check(await wait(5) { fallback.directory == "/private/tmp" }, "polling follows cd", fallback.directory)
        fallback.view.send(txt: "sleep 1.5\r")
        check(await wait(3) { fallback.status.running && fallback.status.program == "sleep" }, "polling sees a command start", fallback.status.program)
        check(await wait(5) { !fallback.status.running }, "and finish")
        let tabsBefore = c.tabs.count
        fallback.view.send(txt: "exit 3\r")
        check(await wait(5) { fallback.exited }, "the shell's exit is noticed")
        check(c.tabs.contains { $0 === fallback } && c.tabs.count == tabsBefore, "a shell that fails keeps its tab open")
        check(fallback.status.exitCode == 3 && fallback.closeWarning == nil, "with its exit code, and closes without asking",
              "\(String(describing: fallback.status.exitCode))")
        c.requestClose(fallback)
        check(!c.tabs.contains { $0 === fallback }, "⌘W closes it")

        // Snapshot with every state on screen, for a visual check.
        await screenshotAllStates(c, dir: dir)

        // Closing an idle tab needs no confirmation.
        let before = c.tabs.count
        c.select(c.tabs.count - 1)
        c.closeTab(nil)
        check(c.tabs.count == before - 1 && window.attachedSheet == nil, "closing an idle tab is immediate")

        // Closing a busy tab asks first, and Cancel keeps it.
        let busy = c.addTab(directory: nil)
        _ = await wait(20) { busy.status.integrated }
        busy.view.send(txt: "sleep 30\r")
        _ = await wait(3) { busy.status.running }
        let shellPid = busy.view.process.shellPid
        let jobPid = tcgetpgrp(busy.view.process.childfd) // the `sleep 30`
        c.closeTab(nil)
        check(window.attachedSheet != nil, "closing a busy tab asks first")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        await pause(0.2)
        check(c.tabs.contains { $0 === busy }, "Cancel keeps the tab")
        c.closeTab(nil)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check(await wait(2) { !c.tabs.contains { $0 === busy } }, "Close Tab removes it")
        check(await wait(4) { kill(shellPid, 0) != 0 }, "its shell is stopped and reaped")
        check(jobPid > 0 && jobPid != shellPid, "the running job was identified", "\(jobPid)")
        check(await wait(4) { kill(jobPid, 0) != 0 }, "the job running in it is stopped too")

        // `exit` closes the tab.
        let exiting = c.addTab(directory: nil)
        _ = await wait(20) { exiting.status.integrated }
        let count = c.tabs.count
        exiting.view.send(txt: "exit\r")
        check(await wait(5) { c.tabs.count == count - 1 }, "`exit` closes the tab")

        // Project sidebar: follows the active tab's git root, loads in the background, live-updates, toggles.
        let proj = URL(fileURLWithPath: canonicalPath(dir.path)).appendingPathComponent("proj")
        try? FileManager.default.createDirectory(at: proj.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try? "# readme\n".write(to: proj.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try? "one\ntwo\n".write(to: proj.appendingPathComponent("src/app.txt"), atomically: true, encoding: .utf8)
        let gitPath = GitRunner.locateGit()
        func git(_ args: String...) {
            guard let gitPath else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gitPath)
            p.arguments = ["-C", proj.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main",
                           "-c", "commit.gpgsign=false"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        git("init")
        git("add", "-A")
        git("commit", "-m", "start")
        if !c.isSidebarVisible { c.toggleProjectSidebar(nil) }
        let inProject = c.addTab(directory: proj.appendingPathComponent("src/deep").path)
        _ = await wait(20) { inProject.status.integrated }
        c.refresh()
        check(c.sidebar.root?.path == proj.path, "sidebar shows the tab's git project", c.sidebar.root?.path ?? "nil")
        check(await wait(4) { c.sidebar.root?.children?.map(\.name) == ["src", "README.md"] },
              "sidebar lists folders first and hides .git (read in the background)", "\(c.sidebar.root?.children?.map(\.name) ?? [])")
        check(await wait(4) { c.sidebar.outline.numberOfRows == 3 }, "project root is expanded", "\(c.sidebar.outline.numberOfRows) rows")
        try? Data().write(to: proj.appendingPathComponent("AGENTS.md"))
        check(await wait(4) { c.sidebar.root?.children?.contains { $0.name == "AGENTS.md" } == true && c.sidebar.outline.numberOfRows == 4 },
              "a new file appears in the sidebar by itself")

        // Git: branch in the header, colours and +/− counts on changed files and their folders.
        if gitPath != nil {
            try? "one\n2\nthree\nfour\n".write(to: proj.appendingPathComponent("src/app.txt"), atomically: true, encoding: .utf8)
            check(await wait(6) { c.sidebar.git.snapshot?.files["src/app.txt"] == .modified }, "git sees the modified file")
            let snap = c.sidebar.git.snapshot
            check(snap?.branch == "main", "the header knows the branch", snap?.branch ?? "nil")
            check(snap?.stats(at: "src", isDirectory: true) == LineStats(added: 3, removed: 1, files: 1),
                  "its folder rolls up +3 −1", "\(String(describing: snap?.stats(at: "src", isDirectory: true)))")
            check(snap?.change(at: "AGENTS.md", isDirectory: false) == .untracked, "a new file is untracked")
            check(SidebarHeaderView.describe(snap!).contains("Branch main"), "the header tooltip describes it", SidebarHeaderView.describe(snap!))
            if let src = c.sidebar.root?.children?.first(where: { $0.name == "src" }) {
                let row = c.sidebar.outline.row(forItem: src)
                let cell = c.sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCellView
                c.sidebar.outline.layoutSubtreeIfNeeded()
                check(cell?.statsText == "+3 −1", "the folder row shows +3 −1", cell?.statsText ?? "no cell")
            }
        } else {
            note("no git on this machine: git checks skipped")
        }

        // File operations, each undone with ⌘Z.
        let undo = window.undoManager
        let notes = proj.appendingPathComponent("notes.md")
        try? "n\n".write(to: notes, atomically: true, encoding: .utf8)
        c.sidebar.transfer([notes], into: proj.appendingPathComponent("src"), copy: false)
        let movedNotes = proj.appendingPathComponent("src/notes.md")
        check(FileManager.default.fileExists(atPath: movedNotes.path) && !FileManager.default.fileExists(atPath: notes.path), "move into a folder")
        undo?.undo()
        check(FileManager.default.fileExists(atPath: notes.path), "⌘Z puts it back")
        c.sidebar.rename(notes, to: "NOTES.md")
        check((try? FileManager.default.contentsOfDirectory(atPath: proj.path))?.contains("NOTES.md") == true, "rename (case only)")
        undo?.undo()
        check((try? FileManager.default.contentsOfDirectory(atPath: proj.path))?.contains("notes.md") == true, "⌘Z renames it back")
        c.sidebar.trash([notes], confirm: false)
        check(!FileManager.default.fileExists(atPath: notes.path), "move to the Trash")
        undo?.undo()
        check(FileManager.default.fileExists(atPath: notes.path), "⌘Z restores it from the Trash")
        try? FileManager.default.removeItem(at: notes)

        // The tree remembers what was expanded when you switch to a tab in another folder and back.
        if let src = c.sidebar.root?.children?.first(where: { $0.name == "src" }) {
            c.sidebar.outline.expandItem(src)
            _ = await wait(3) { c.sidebar.outline.isItemExpanded(src) }
        }
        inProject.view.send(txt: "cd /tmp\r")
        check(await wait(5) { c.sidebar.root?.path == "/private/tmp" }, "sidebar follows `cd` out of the project", c.sidebar.root?.path ?? "nil")
        inProject.view.send(txt: "cd \(proj.path)\r")
        _ = await wait(5) { c.sidebar.root?.path == proj.path }
        let srcAgain = c.sidebar.root?.children?.first(where: { $0.name == "src" })
        check(srcAgain.map { c.sidebar.outline.isItemExpanded($0) } == true, "and back: the expanded folder is still expanded")

        let lightsInset = c.tabBar.leadingInset
        c.toggleProjectSidebar(nil)
        check(!c.isSidebarVisible && c.tabBar.leadingInset == 78, "⌘B hides the sidebar and the tabs move clear of the traffic lights")
        c.toggleProjectSidebar(nil)
        check(c.isSidebarVisible && c.tabBar.leadingInset == lightsInset, "⌘B shows it again")
        await screenshot(c, suffix: "-sidebar")
        c.requestClose(inProject)

        // Projects. The user's own settings are put back afterwards.
        let app = AppDelegate.shared!
        let savedTarget = app.projectTarget
        let savedRecents = UserDefaults.standard.stringArray(forKey: "recentProjects")
        app.projectTarget = .newWindow
        let windowsBefore = app.controllers.count
        app.openProject(at: proj, from: c)
        let projectWindow = app.controllers.last
        check(app.controllers.count == windowsBefore + 1 && projectWindow?.project == proj.path, "Open Project opens a project window")
        if let pw = projectWindow, let first = pw.tabs.first {
            _ = await wait(20) { first.status.integrated }
            check(first.currentDirectory() == proj.path, "its first tab starts in the project", first.currentDirectory())
            check(await wait(4) { pw.sidebar.root?.path == proj.path }, "its sidebar shows the project")
            first.view.send(txt: "cd /tmp\r")
            _ = await wait(4) { first.directory == "/tmp" }
            check(pw.sidebar.root?.path == proj.path, "the sidebar stays on the project after `cd`")
            pw.newTab(nil)
            let second = pw.tabs[pw.activeIndex]
            _ = await wait(20) { second.status.integrated }
            check(second.currentDirectory() == proj.path, "⌘T in a project window opens in the project", second.currentDirectory())
            app.openProject(at: proj, from: c)
            check(app.controllers.count == windowsBefore + 1, "opening the same project again reuses its window")
            check(app.recentProjects.first == proj.path, "it is first in Open Recent")
            pw.closeProject(nil)
            check(await wait(3) { !app.controllers.contains { $0 === pw } }, "Close Project closes its window")
        }
        // An untouched window becomes the project window instead of opening another.
        let fresh = app.openWindow(directory: nil)
        _ = await wait(20) { fresh.tabs.first?.status.integrated == true }
        check(fresh.isPristine, "a new window is untouched")
        let windowsNow = app.controllers.count
        app.openProject(at: proj, from: fresh)
        check(app.controllers.count == windowsNow && fresh.project == proj.path && fresh.tabs.count == 1, "an untouched window is reused for the project")
        fresh.closeProject(nil)
        _ = await wait(3) { !app.controllers.contains { $0 === fresh } }
        app.showWelcome(nil)
        check(NSApp.windows.contains { $0.title == "Welcome to Next Term" && $0.isVisible }, "the Welcome window lists recent projects")
        NSApp.windows.first { $0.title == "Welcome to Next Term" }?.close()
        app.projectTarget = savedTarget
        UserDefaults.standard.set(savedRecents, forKey: "recentProjects")
        c.window?.makeKeyAndOrderFront(nil)

        // Many tabs in a narrow window: the extras go behind », the selected tab always stays in view.
        let savedFrame = window.frame
        window.setContentSize(NSSize(width: 760, height: savedFrame.height))
        var extra: [TerminalTab] = []
        for _ in 0..<14 { extra.append(c.addTab(directory: nil)) }
        c.tabBar.layoutSubtreeIfNeeded()
        check(c.tabBar.isOverflowing, "tabs that do not fit overflow", "\(c.tabs.count) tabs")
        check(c.tabBar.visibleRange.contains(c.activeIndex), "the selected tab is visible")
        c.select(0)
        c.tabBar.layoutSubtreeIfNeeded()
        check(c.tabBar.visibleRange.contains(0), "selecting a hidden tab brings it into view", "\(c.tabBar.visibleRange)")
        c.select(c.tabs.count - 1)
        c.tabBar.layoutSubtreeIfNeeded()
        check(c.tabBar.visibleRange.contains(c.tabs.count - 1), "… at either end", "\(c.tabBar.visibleRange)")
        for tab in extra { c.requestClose(tab) }
        window.setFrame(savedFrame, display: true)
        c.tabBar.layoutSubtreeIfNeeded()
        check(!c.tabBar.isOverflowing, "and stops overflowing when they fit again")
        let glyphs = [TabState.done, .failed, .attention].compactMap { StatusGlyph.symbolName(for: $0) }
        check(Set(glyphs).count == 3, "done, failed and attention have different shapes, not just colours")

        // Rename, then clear back to the automatic title.
        c.tabBar(c.tabBar, didRename: 0, to: "API server")
        check(c.tabs[0].title == "API server", "rename sets the title")
        c.tabBar(c.tabBar, didRename: 0, to: nil)
        check(c.tabs[0].title != "API server", "empty rename restores the automatic title")

        // Reorder.
        if c.tabs.count < 2 { c.addTab(directory: nil) }
        let a = c.tabs[0], b = c.tabs[1]
        c.tabBar(c.tabBar, didMove: 0, to: 1)
        check(c.tabs[0] === b && c.tabs[1] === a, "drag reorder moves the tab")

        // Font size.
        let size = AppDelegate.shared.fontSize
        AppDelegate.shared.increaseFontSize(nil)
        check(AppDelegate.shared.fontSize == size + 1, "⌘+ grows the font")
        AppDelegate.shared.resetFontSize(nil)
        AppDelegate.shared.fontSize = size

        try? FileManager.default.removeItem(at: dir)
    }

    private static func screenshotAllStates(_ c: TerminalWindowController, dir: URL) async {
        let commands = ["sleep 1", "sleep 1; false", "sleep 0.5; printf '\\a'", "sleep 20"]
        var made: [TerminalTab] = []
        for cmd in commands {
            let tab = c.addTab(directory: "/tmp")
            made.append(tab)
            _ = await wait(20) { tab.status.integrated }
            tab.status.setVisible(true)
            tab.view.send(txt: "\(cmd)\r")
            _ = await wait(3) { tab.status.running }
        }
        c.select(0)
        _ = await wait(6) { made.prefix(3).allSatisfy { !$0.status.running } }
        await pause(0.5)
        c.refresh()
        await screenshot(c, suffix: "")
        note("tab states in screenshot: \(made.map { $0.status.state.rawValue })")
        for tab in made {
            tab.status.setVisible(true)
            if tab.status.running { tab.view.send(txt: "\u{03}") } // Ctrl-C the sleep
        }
        _ = await wait(3) { made.allSatisfy { !$0.status.running } }
        for tab in made { c.requestClose(tab) }
    }

    /// Captures the window exactly as it is on screen (an app may always capture its own windows).
    private static func screenshot(_ c: TerminalWindowController, suffix: String) async {
        guard let base = reportPath, let window = c.window else { return }
        await pause(0.4)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else {
            note("screenshot failed")
            return
        }
        let path = (base as NSString).deletingPathExtension + suffix + ".png"
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        note("screenshot: \(path)")
    }

    private static var reportPath: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--self-test"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        let report = lines.joined(separator: "\n") + "\n"
        if let path = reportPath { try? report.write(toFile: path, atomically: true, encoding: .utf8) }
        print(report, terminator: "")
        exit(failures == 0 ? 0 : 1)
    }
}

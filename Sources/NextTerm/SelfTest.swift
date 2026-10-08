import AppKit
import SwiftTerm
import Network
import NextTermCore
import SQLite3

/// End-to-end check of the real app: real shells, real tabs, real status changes.
/// Run with `NextTerm --self-test <report-path>`; writes PASS/FAIL lines and quits.
@MainActor
enum SelfTest {
    nonisolated static var isRequested: Bool { CommandLine.arguments.contains("--self-test") }
    /// The self-test's own MCP socket, so it never answers for (or takes over from) the Next Term you use.
    nonisolated static let mcpSocketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("nextterm-mcp-\(getpid()).sock")
    /// Where the self-test's Copilot CLI lock goes, so it never writes in your own ~/.copilot.
    nonisolated static let copilotLockFolder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nextterm-copilot-ide-\(getpid())", isDirectory: true)

    private static var lines: [String] = []
    private static var failures = 0

    static func run() {
        Task { @MainActor in
            await runAll()
            await welcomeReopenChecks() // last: it closes every window
            await welcomeRemoteChecks() // with only the Welcome window left
            finish()
        }
    }

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        let d = detail()
        record("\(ok ? "PASS" : "FAIL") \(name)\(ok || d.isEmpty ? "" : " — \(d)")")
    }

    static func note(_ text: String) { record("NOTE \(text)") }

    /// Each line goes into the report as it happens, so a run stopped part-way (the script's time limit)
    /// still says how far it got and what failed; the last line, ALL PASSED or N FAILED, comes at the end.
    private static func record(_ line: String) {
        lines.append(line)
        guard let handle = reportHandle else { return }
        handle.write(Data((line + "\n").utf8))
    }

    private static let reportHandle: FileHandle? = {
        guard let path = reportPath, FileManager.default.createFile(atPath: path, contents: nil) else { return nil }
        return FileHandle(forWritingAtPath: path)
    }()

    static func wait(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Whether Edit › Find › Replace… is on with `responder` holding the window's keyboard, as AppKit enables
    /// the menu item. Nil when the app is not in front: with no key window nothing is on.
    static func replaceIsOn(with responder: NSResponder, in window: NSWindow) -> Bool? {
        guard NSApp.isActive, window.isKeyWindow,
              let item = KeyboardShortcuts.shared.commands.first(where: { $0.id == "replaceInFile:" })?.item else { return nil }
        window.makeFirstResponder(responder)
        item.menu?.update()
        return item.isEnabled
    }

    private static func runAll() async {
        // The notifications checked along the way (a decision, below) come as they do by default.
        let restoreNotificationSettings = defaultNotificationSettings()
        defer { restoreNotificationSettings() }
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
        first.view.send(txt: "\u{15}cd /tmp\r")
        check(await wait(12) { first.directory == "/tmp" }, "cwd is tracked",
              first.directory + " — screen: " + first.screenTail(6).joined(separator: " | "))
        let sentThroughMenu = NSApp.keyWindow === window
        if sentThroughMenu {
            NSApp.sendAction(#selector(TerminalWindowController.newTab(_:)), to: nil, from: nil)
        } else {
            note("window is not key (app launched in background); calling newTab directly")
            c.newTab(nil)
        }
        check(c.tabs.count == 2 && c.activeIndex == 1, "⌘T opens a second tab and selects it", "tabs=\(c.tabs.count) active=\(c.activeIndex)")
        // Each tab says how to get to it: ⌘1…⌘8, and ⌘9 for the last; nothing while there is one tab.
        c.tabBar.layoutSubtreeIfNeeded()
        check(c.tabBar.items.map(\.shortcut) == ["⌘1", "⌘2"] && c.tabBar.shownShortcut(at: 0) == "⌘1",
              "tabs show the shortcut that selects them", "\(c.tabBar.items.map(\.shortcut)) shown \(c.tabBar.shownShortcut(at: 0) ?? "nil")")
        let ten = TerminalWindowController.tabShortcuts(count: 10)
        check(TerminalWindowController.tabShortcuts(count: 1) == [nil] && ten[7] == "⌘8" && ten[8] == nil && ten[9] == "⌘9",
              "⌘9 is the last tab's; one tab shows none", "\(ten)")
        let second = c.tabs[1]
        check(await wait(20) { second.status.integrated }, "second tab's shell starts")
        check(await wait(5) { second.currentDirectory() == "/private/tmp" }, "new tab opens in the same directory", second.currentDirectory())

        // Foreground process lookup through the kernel.
        second.view.send(txt: "sleep 1.5\r")
        check(await wait(3) { ProcessInspector.foreground(ptyFileDescriptor: second.view.process.childfd,
                                                          shellPid: second.view.process.shellPid, shellName: "zsh")?.name == "sleep" },
              "foreground process is read from the pty")
        check(second.status.running && second.status.state == .idle, "a plain command shows no spinner (only agents do)", second.status.state.rawValue)
        check(await wait(5) { !second.status.running }, "command end is detected")

        // Failure in a background tab.
        second.view.send(txt: "sleep 1; false\r")
        check(await wait(3) { second.status.running }, "command start is detected")
        c.select(0)
        check(await wait(5) { second.status.state == .failed }, "background failure shows red", second.status.state.rawValue)
        check(second.status.exitCode == 1, "exit code is captured", "\(String(describing: second.status.exitCode))")
        let unseenTabs = AppDelegate.shared.controllers.reduce(0) { $0 + $1.unseenTabCount }
        check(unseenTabs >= 1 && NSApp.dockTile.badgeLabel == String(unseenTabs), "dock badge counts the tabs that need you",
              "\(NSApp.dockTile.badgeLabel ?? "nil") vs \(unseenTabs)")
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

        // An agent's own screen drives its status: working ("esc to interrupt"), a decision with the
        // question, then done, while its idle status line keeps redrawing.
        let asker = dir.appendingPathComponent("claude")
        try? """
        #!/bin/sh
        printf '\\342\\234\\273 Pondering\\342\\200\\246 (2s \\302\\267 esc to interrupt)\\n'; sleep 1.5
        printf 'Do you want to make this edit to a.txt?\\n\\342\\235\\257 1. Yes\\n  2. Yes, and don'"'"'t ask again this session\\n  3. No, and tell Claude what to do differently (esc)\\n'
        read answer
        printf '\\033[2J\\033[H\\342\\234\\273 Applying\\342\\200\\246 (esc to interrupt)\\n'; sleep 1.5
        printf '\\033[2J\\033[HDone. Ready for your next prompt.\\n'
        while true; do printf '\\r  ? for shortcuts  %s' "$(date +%S)"; sleep 0.5; done
        """.write(to: asker, atomically: true, encoding: .utf8)
        chmod(asker.path, 0o755)
        c.select(1)
        second.status.setVisible(true)
        second.view.send(txt: "PATH=\(dir.path):$PATH claude\r")
        check(await wait(4) { second.status.running && second.status.kind == .agent && second.status.screenSynced },
              "the agent's working hint is read from its screen")
        c.select(0)
        check(await wait(5) { second.status.question == "Do you want to make this edit to a.txt?" }, "its question is read too",
              second.status.question ?? "none")
        // Posted as it is read; the self-test keeps it (AppDelegate.testNotifications) instead of showing it.
        check(await wait(2) { AppDelegate.shared.testNotifications.contains { $0.identifier == second.id.uuidString && $0.content.body == "Do you want to make this edit to a.txt?" } },
              "and a notification quotes it", "\(AppDelegate.shared.testNotifications.map(\.content.body))")
        check(second.status.state == .attention && second.stateDescription.hasPrefix("Needs your decision"), "and shows as a decision",
              second.stateDescription)
        second.view.send(txt: "1\r")
        check(await wait(4) { second.status.question == nil && second.status.state == .working }, "answering clears it; working again")
        check(await wait(6) { second.status.state == .done }, "done while its status line keeps redrawing", second.status.state.rawValue)
        second.view.send(txt: "\u{03}")
        _ = await wait(4) { !second.status.running }
        c.select(1)
        second.status.setVisible(true)

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
            check(!c.sidebar.header.summaryIsTruncated, "the header shows its counts in full")
            check(!c.sidebar.header.titleIsTruncated, "and the branch name in full (a short one never becomes “…”)")
            await syncButtonChecks(c, snap!)
            if let src = c.sidebar.root?.children?.first(where: { $0.name == "src" }) {
                let row = c.sidebar.outline.row(forItem: src)
                let cell = c.sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCellView
                c.sidebar.outline.layoutSubtreeIfNeeded()
                check(cell?.statsText == "+3 −1", "the folder row shows +3 −1", cell?.statsText ?? "no cell")
            }
        } else {
            note("no git on this machine: git checks skipped")
        }

        // A long name stays on one line, truncated in the middle as in Finder, never wrapped.
        let longName = proj.appendingPathComponent("claude-mcp-browser-bridge-mishuk-with-a-very-long-name")
        try? FileManager.default.createDirectory(at: longName, withIntermediateDirectories: true)
        if await wait(4, { c.sidebar.root?.children?.contains { $0.name == longName.lastPathComponent } == true }),
           let node = c.sidebar.root?.children?.first(where: { $0.name == longName.lastPathComponent }) {
            c.sidebar.outline.layoutSubtreeIfNeeded()
            let row = c.sidebar.outline.row(forItem: node)
            let cell = c.sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCellView
            check(cell?.nameLines(atWidth: 120) == 1, "a long folder name stays on one line", "\(cell?.nameLines(atWidth: 120) ?? -1) lines")
        } else {
            check(false, "a long folder name stays on one line", "folder not listed")
        }
        try? FileManager.default.removeItem(at: longName)

        // Typography helpers: one ellipsis character, no space before it, measured gaps instead of typed spaces.
        let shortened = Typography.shortened(String(repeating: "word ", count: 30), to: 60)
        check(shortened.count <= 60 && shortened.hasSuffix("…") && !shortened.hasSuffix(" …") && !shortened.contains("..."),
              "long titles shorten with one ellipsis character", shortened)
        let gap = Typography.gap(10, font: .systemFont(ofSize: 12))
        check(gap.string == " " && abs(gap.size().width - 10) < 1, "gaps are one space widened to a measured width", "\(gap.size().width)")

        // A named pipe in the tree gets an icon without anyone reading it (that would hang).
        let pipePath = proj.appendingPathComponent("events-pipe").path
        mkfifo(pipePath, 0o600)
        _ = FileIcons.icon(for: URL(fileURLWithPath: pipePath))
        check(true, "a named pipe in the project does not freeze the sidebar")
        check(c.editorArea.open(URL(fileURLWithPath: pipePath)) == .notText, "nor the editor")
        unlink(pipePath)

        // Open-source file icons: Material Icon Theme, by name, extension and folder.
        check(FileIcons.theme != nil, "the file-icon theme loads")
        let iconName = { (url: URL) in FileIcons.icon(for: url).accessibilityDescription ?? "" }
        check(iconName(proj.appendingPathComponent("routes/web.php")) == "routing" && iconName(proj.appendingPathComponent("a/welcome.blade.php")) == "laravel"
              && iconName(proj.appendingPathComponent("next.config.mjs")) == "next",
              "framework files get their icons (Laravel routes and Blade, Next.js)",
              [iconName(proj.appendingPathComponent("routes/web.php")), iconName(proj.appendingPathComponent("a/welcome.blade.php"))].joined(separator: ", "))
        if let src = c.sidebar.root?.children?.first(where: { $0.name == "src" }) {
            let closed = FileIcons.image(for: src, expanded: false).accessibilityDescription
            let open = FileIcons.image(for: src, expanded: true).accessibilityDescription
            check(closed == "folder-src" && open == "folder-src-open", "folders have open and closed icons", "\(closed ?? "-") / \(open ?? "-")")
        }

        // Configuration folders stay plain unless asked for (Settings > Editor > Sidebar).
        if let root = c.sidebar.root {
            let dotFolder = proj.appendingPathComponent(".claude")
            try? FileManager.default.createDirectory(at: dotFolder, withIntermediateDirectories: true)
            let node = FileNode(url: dotFolder, parent: root)
            let app = AppDelegate.shared!
            let saved = app.iconsOnDotFolders
            app.iconsOnDotFolders = false
            let plain = FileIcons.image(for: node, expanded: false).accessibilityDescription
            app.iconsOnDotFolders = true
            let branded = FileIcons.image(for: node, expanded: false).accessibilityDescription
            app.iconsOnDotFolders = saved
            check(plain == FileIcons.theme?.folder && branded == "folder-claude", "dot folders are plain, or branded when asked",
                  "\(plain ?? "-") / \(branded ?? "-")")
            try? FileManager.default.removeItem(at: dotFolder)
        }

        // Row tooltips: the path of the row under the pointer, and nothing outside the visible rows.
        c.sidebar.outline.layoutSubtreeIfNeeded()
        let firstRow = c.sidebar.outline.rect(ofRow: 0)
        let tipInside = c.sidebar.view(c.sidebar.outline, stringForToolTip: 0, point: NSPoint(x: firstRow.midX, y: firstRow.midY), userData: nil)
        let above = NSPoint(x: firstRow.midX, y: c.sidebar.outline.visibleRect.minY - 10)
        let tipAbove = c.sidebar.view(c.sidebar.outline, stringForToolTip: 0, point: above, userData: nil)
        check(tipInside.hasPrefix(proj.path) && tipAbove.isEmpty, "row tooltips show the row's path, and never outside the visible rows",
              "inside \(tipInside.debugDescription), above \(tipAbove.debugDescription)")
        // A cell reused for a file's row after a folder's "… N more items" row keeps none of that row's tooltip.
        let reused = FileCellView()
        reused.configureHidden(HiddenEntries(count: 12))
        let hiddenTip = reused.tipText
        if let root = c.sidebar.root { reused.configure(node: root, isRoot: false, expanded: false, change: nil, lines: nil) }
        check(hiddenTip == "This folder is too large to list in full." && reused.toolTip == nil && reused.tipText.hasPrefix(proj.path),
              "a reused row's tooltip is its own: “… more items” leaves nothing behind", "\(reused.toolTip ?? "nil") / \(reused.tipText)")

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

        await editorChecks(c, proj: proj, tab: inProject)
        await lineEditChecks(c, proj: proj, tab: inProject)
        await emptyEditorChecks(c, proj: proj, tab: inProject)
        await goToFileChecks(c, proj: proj)
        await gutterAndCollapseChecks(c, proj: proj)
        await railChecks(c, proj: proj)
        await blameChecks(c, proj: proj)
        await deletedFileChecks(c, proj: proj)
        await notebookChecks(c, proj: proj)
        await databaseChecks(c, proj: proj)
        await dataChecks(c, proj: proj)
        await updateChecks(c)
        await updateSignatureChecks()
        await updateWaitChecks()
        await platformLinkChecks(c)
        await branchChecks(c, proj: proj)
        await gitLogChecks(c, proj: proj)
        await gitLogPagingChecks(c)
        await gitLeftoverChecks(c)
        await branchCompareChecks(c)
        await backgroundFetchChecks(c)
        await ragColorChecks(c, proj: proj)
        await envValueChecks(c, proj: proj)
        await importChecks(c, proj: proj)
        await singleClickChecks(c, proj: proj, tab: inProject)

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
        check(c.tabBar.showsSidebarButton != c.editorArea.tabBar.showsSidebarButton, "the bar at the top-left offers a button to show it again")
        await screenshot(c, suffix: "-sidebar-hidden")
        c.toggleProjectSidebar(nil)
        check(c.isSidebarVisible && c.tabBar.leadingInset == lightsInset, "⌘B shows it again")
        check(!c.tabBar.showsSidebarButton && !c.editorArea.tabBar.showsSidebarButton
              && c.sidebar.header.hideButton.action == #selector(TerminalWindowController.toggleProjectSidebar(_:)),
              "with the sidebar shown, its own header has the hide button")
        await screenshot(c, suffix: "-sidebar")
        c.requestClose(inProject)

        // Find and Replace in Files, undoable.
        let calc = proj.appendingPathComponent("src/calc.swift")
        try? "let total = price * qty\nlet price = 3\n".write(to: calc, atomically: true, encoding: .utf8)
        c.finder.show(root: proj.path, replacing: true, initialText: nil, over: window)
        c.finder.setQuery("price")
        check(await wait(6) { !c.finder.isSearching && c.finder.matchCount == 2 && c.finder.fileCount == 1 }, "Find in Files finds both matches",
              "\(c.finder.matchCount) in \(c.finder.fileCount)")
        c.finder.setQuery("price", masks: "*.md")
        check(await wait(6) { !c.finder.isSearching && c.finder.matchCount == 0 }, "file masks narrow the search")
        let pattern = #"price \* (\w+)"#
        c.finder.setQuery(pattern, replacement: "$1 * price", regex: true)
        check(await wait(6) { !c.finder.isSearching && c.finder.matchCount == 1 }, "regular expressions search too")
        let found = ProjectSearch.matches(in: (try? String(contentsOf: calc, encoding: .utf8)) ?? "", relativePath: "src/calc.swift",
                                          expression: try! SearchQuery(text: pattern, isRegex: true).expression())
        c.finder.replace(found, confirm: false)
        check((try? String(contentsOf: calc, encoding: .utf8)) == "let total = qty * price\nlet price = 3\n", "Replace in Files with a regex group",
              (try? String(contentsOf: calc, encoding: .utf8)) ?? "")
        c.finder.window?.undoManager?.undo()
        check((try? String(contentsOf: calc, encoding: .utf8)) == "let total = price * qty\nlet price = 3\n", "⌘Z undoes the replacement")
        c.finder.close()
        c.window?.makeKeyAndOrderFront(nil)

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
            first.view.send(txt: "\u{15}cd /tmp\r")
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
        // Outside a repository Git Log is off, like the Git menu's other commands.
        let plain = app.openWindow(directory: dir.path)
        _ = await wait(20) { plain.tabs.first?.status.integrated == true }
        plain.refresh()
        let gitLogItem = NSMenuItem(title: "Git Log", action: #selector(TerminalWindowController.showGitLog(_:)), keyEquivalent: "")
        let branchesItem = NSMenuItem(title: "Branches…", action: #selector(TerminalWindowController.showBranches(_:)), keyEquivalent: "")
        check(!plain.validateMenuItem(gitLogItem) && !plain.validateMenuItem(branchesItem),
              "outside a repository Git Log is off, like Branches", plain.sidebar.root?.path ?? "no sidebar root")
        plain.window?.performClose(nil)
        _ = await wait(3) { !app.controllers.contains { $0 === plain } }
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

        await paneChecks(c)
        await menuChecks(c)
        await paneHeaderChecks(c)

        await sessionChecks(proj: proj)
        await moreSessionChecks(proj: proj)

        await lastTabChecks()
        await dockReopenChecks(c)

        // Font size.
        let size = AppDelegate.shared.fontSize
        AppDelegate.shared.increaseFontSize(nil)
        check(AppDelegate.shared.fontSize == size + 1, "⌘+ grows the font")
        AppDelegate.shared.resetFontSize(nil)
        AppDelegate.shared.fontSize = size

        await linkChecks(c)
        await notificationChecks(c)
        await skillsChecks()
        await mcpWriteChecks(c, proj: proj)

        try? FileManager.default.removeItem(at: dir)
    }

    /// A stand-in app with only its `nxtrm` script and bundle identifier: the script's path.
    private static func fakeApp(_ app: String, identifier: String = CommandLineLink.bundleIdentifier) -> String {
        let script = app + CommandLineLink.bundledPath
        try? FileManager.default.createDirectory(atPath: (script as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: script, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        NSDictionary(dictionary: ["CFBundleIdentifier": identifier]).write(toFile: app + "/Contents/Info.plist", atomically: true)
        return script
    }

    /// `nxtrm` for other terminals, on real folders: the first command folder on PATH that is writable
    /// takes the link, which is kept, repointed when the app moves, and never put over someone else's.
    private static func commandLineLinkChecks(_ c: TerminalWindowController) async {
        let fm = FileManager.default
        let home = (canonicalPath(NSTemporaryDirectory()) as NSString).appendingPathComponent("nt-nxtrm-\(getpid())")
        let local = home + "/.local/bin", own = home + "/bin", tools = home + "/tools"
        let locked = home + "/locked", gone = home + "/gone"
        defer {
            for folder in [own, locked, gone] { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
            try? fm.removeItem(atPath: home)
        }
        for folder in [local, own, tools, locked, gone] { try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        let script = fakeApp(home + "/Next Term.app")
        let moved = fakeApp(home + "/Moved/Next Term.app")
        // Links made with a password, as in a stock /usr/local/bin: to the first copy, and to one deleted since.
        try? fm.createSymbolicLink(atPath: locked + "/nxtrm", withDestinationPath: script)
        try? fm.createSymbolicLink(atPath: gone + "/nxtrm", withDestinationPath: home + "/Gone/Next Term.app/Contents/Resources/bin/nxtrm")
        for folder in [own, locked, gone] { try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder) } // need a password
        let path = [own, tools, local, "/usr/bin", "/bin"]

        let behind = CommandLineTool.plan(for: moved, path: [locked, local, "/usr/bin"], home: home)
        check(behind == .unavailable, "nxtrm: no link goes behind one to another copy, which the shell would still run", "\(behind)")
        let ahead = CommandLineTool.plan(for: moved, path: [local, locked, "/usr/bin"], home: home)
        check(ahead == .link(local + "/nxtrm"), "nxtrm: a writable folder ahead of a link to another copy takes it", "\(ahead)")
        let past = CommandLineTool.plan(for: moved, path: [gone, local, "/usr/bin"], home: home)
        check(past == .link(local + "/nxtrm"), "nxtrm: a link to a copy that is gone is passed over, as the shell does", "\(past)")

        let first = CommandLineTool.plan(for: script, path: path, home: home)
        check(first == .link(local + "/nxtrm"), "nxtrm: the first writable command folder on PATH takes the link", "\(first)")
        let linked = CommandLineTool.link(local + "/nxtrm", to: script)
        let target = try? fm.destinationOfSymbolicLink(atPath: local + "/nxtrm")
        check(linked && target == script, "nxtrm: the link points at the app", target ?? "no link")
        let again = CommandLineTool.plan(for: script, path: path, home: home)
        check(again == .linked(local + "/nxtrm"), "nxtrm: the next launch keeps it", "\(again)")

        let repoint = CommandLineTool.plan(for: moved, path: path, home: home)
        let repointed = CommandLineTool.link(local + "/nxtrm", to: moved)
        let movedTarget = try? fm.destinationOfSymbolicLink(atPath: local + "/nxtrm")
        check(repoint == .link(local + "/nxtrm") && repointed && movedTarget == moved, "nxtrm: a moved app repoints its own link", "\(repoint)")

        fm.createFile(atPath: tools + "/nxtrm", contents: Data("#!/bin/sh\n".utf8))
        let taken = CommandLineTool.plan(for: moved, path: path, home: home)
        let overwritten = CommandLineTool.link(tools + "/nxtrm", to: moved)
        check(taken == .taken(tools + "/nxtrm") && !overwritten && CommandLineTool.entry(at: tools + "/nxtrm") == .file,
              "nxtrm: someone else's comes first on PATH and is left alone", "\(taken)")

        // Laid out like Next Term, but another app: someone else's.
        let other = fakeApp(home + "/Other.app", identifier: "com.example.other")
        try? fm.removeItem(atPath: tools + "/nxtrm")
        try? fm.createSymbolicLink(atPath: tools + "/nxtrm", withDestinationPath: other)
        let lookalike = CommandLineTool.plan(for: moved, path: path, home: home)
        let replaced = CommandLineTool.link(tools + "/nxtrm", to: moved)
        check(lookalike == .taken(tools + "/nxtrm") && !replaced && CommandLineTool.entry(at: tools + "/nxtrm") == .link(other),
              "nxtrm: a link into another app laid out like Next Term is someone else's", "\(lookalike)")

        // The password route runs as root: it links only where nothing is, or over a link of Next Term's.
        func sh(_ command: String) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }
        let admin = home + "/admin/nxtrm"
        try? fm.createDirectory(atPath: home + "/admin", withIntermediateDirectories: true)
        fm.createFile(atPath: admin, contents: Data("#!/bin/sh\n".utf8))
        let overFile = CommandLineTool.rootCommand(linking: admin, to: moved)
        let overTheirs = CommandLineTool.rootCommand(linking: tools + "/nxtrm", to: moved)
        let overOurs = CommandLineTool.rootCommand(linking: local + "/nxtrm", to: script) ?? ""
        check(overFile == nil && overTheirs == nil && overOurs.contains(" -sfh "),
              "nxtrm: the password route never replaces someone else's file or link", overOurs)
        try? fm.removeItem(atPath: admin)
        let fresh = CommandLineTool.rootCommand(linking: admin, to: moved) ?? "false"
        fm.createFile(atPath: admin, contents: Data("#!/bin/sh\n".utf8)) // turns up before the command runs
        let refused = sh(fresh) != 0 && CommandLineTool.entry(at: admin) == .file
        try? fm.removeItem(atPath: admin)
        let made = sh(fresh) == 0 && CommandLineTool.entry(at: admin) == .link(moved)
        check(refused && made, "nxtrm: where nothing was, the password route links it, and replaces nothing that turned up since", fresh)

        // A launch links it once: deleted, it stays deleted until the menu command puts it back.
        let defaults = UserDefaults.standard
        let savedLink = defaults.object(forKey: CommandLineTool.linkedKey)
        defer { defaults.set(savedLink, forKey: CommandLineTool.linkedKey) }
        defaults.removeObject(forKey: CommandLineTool.linkedKey)
        let away = home + "/launch", awayLink = away + "/.local/bin/nxtrm"
        try? fm.createDirectory(atPath: away + "/.local/bin", withIntermediateDirectories: true)
        let launch = [away + "/.local/bin", "/usr/bin", "/bin"]
        let launched = CommandLineTool.register(moved, path: launch, home: away)
        let remembered = defaults.string(forKey: CommandLineTool.linkedKey)
        check(launched == .link(awayLink) && CommandLineTool.entry(at: awayLink) == .link(moved) && remembered == awayLink,
              "nxtrm: a launch links it in a free command folder, and remembers where", "\(launched), \(remembered ?? "nothing remembered")")
        try? fm.removeItem(atPath: awayLink)
        CommandLineTool.register(moved, path: launch, home: away)
        check(CommandLineTool.entry(at: awayLink) == .nothing, "nxtrm: once deleted, the next launch leaves it out", "\(CommandLineTool.entry(at: awayLink))")
        let putBack = CommandLineTool.link(awayLink, to: moved) && CommandLineTool.register(moved, path: launch, home: away) == .linked(awayLink)
        check(putBack, "nxtrm: the menu command puts it back, and launches keep it", "\(CommandLineTool.entry(at: awayLink))")

        let none = CommandLineTool.plan(for: script, path: [own, "/usr/bin", "/bin"], home: home)
        let unwritten = !CommandLineTool.link(own + "/nxtrm", to: script) && CommandLineTool.entry(at: own + "/nxtrm") == .nothing
        check(none == .unavailable && unwritten, "nxtrm: with no writable command folder on PATH, nothing is written", "\(none)")

        // The PATH a launch decides on, from the login shell (5 s at most, so not on the main thread), and the
        // menu command's fallback when the shell does not answer.
        let shellPath = await Task.detached { LoginShell.shellPath }.value
        check(shellPath.contains("/usr/bin"), "nxtrm: the login shell's PATH is read", shellPath.joined(separator: ":"))
        let standard = CommandLineTool.standardPath
        check(standard.contains("/usr/bin") && standard.allSatisfy { $0.hasPrefix("/") }, "nxtrm: the PATH from /etc/paths is read",
              standard.joined(separator: ":"))
        // The offer waits, however long, for a project window that is key with nothing in front of it.
        if let window = c.window {
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
            let free = CommandLineTool.offerWindow(key: window, modal: nil) === window
            let elsewhere = CommandLineTool.offerWindow(key: other, modal: nil) == nil && CommandLineTool.offerWindow(key: nil, modal: nil) == nil
            let modal = CommandLineTool.offerWindow(key: window, modal: other) == nil
            let focus = window.firstResponder
            window.beginSheet(other, completionHandler: nil)
            let sheet = await wait(2) { window.attachedSheet != nil } && CommandLineTool.offerWindow(key: window, modal: nil) == nil
            window.endSheet(other)
            _ = await wait(2) { window.attachedSheet == nil }
            window.makeKeyAndOrderFront(nil)
            if let focus { window.makeFirstResponder(focus) }
            check(free && elsewhere && modal && sheet, "nxtrm: the first-launch offer goes on the key project window, with nothing in the way",
                  "free \(free), elsewhere \(elsewhere), modal \(modal), sheet \(sheet)")
        }
        let buttons = CommandLineTool.offerAlert().buttons.map(\.title)
        check(buttons == ["Install…", "Not Now", "Don’t Ask Again"], "nxtrm: the first-launch offer can be taken, put off or declined for good",
              buttons.joined(separator: ", "))
    }

    /// Agent sessions: listed per project on the Welcome window and in ⌥⌘O, resumed in a tab in their folder.
    /// The header's "Pull 152": the words, what a click does, the spinner while git talks to a remote, and
    /// what gives way in a narrow sidebar.
    private static func syncButtonChecks(_ c: TerminalWindowController, _ real: GitSnapshot) async {
        let header = c.sidebar.header
        let frame = header.frame
        func layOut(width: CGFloat) {
            header.setFrameSize(NSSize(width: width, height: frame.height))
            header.needsLayout = true
            header.layoutSubtreeIfNeeded()
        }
        var fake = real
        fake.upstream = "origin/main"
        fake.behind = 152
        fake.lastFetch = Date(timeIntervalSinceNow: -18 * 60)
        header.show(fake)
        layOut(width: 460)
        check(header.syncText == "Pull 152" && !header.syncButton.busy, "152 commits behind shows “Pull 152” in the header", header.syncText)
        check(!header.summaryIsTruncated && !header.titleIsTruncated, "beside the branch and its line counts, all in full", "\(header.syncButton.frame)")
        let tip = header.syncButton.toolTip ?? ""
        check(tip.contains("152 commits") && tip.contains("Last fetched 18 minutes ago"),
              "its tooltip says they are commits and when it last fetched", tip)
        var asked: Bool?
        let onSync = header.onSync
        header.onSync = { asked = $0 }
        header.syncButton.performClick(nil)
        check(asked == true, "a click on it pulls")
        fake.ahead = 3
        fake.behind = 0
        header.show(fake)
        header.layoutSubtreeIfNeeded()
        asked = nil
        header.syncButton.performClick(nil)
        check(header.syncText == "Push 3" && asked == false, "3 commits ahead shows “Push 3”, and a click pushes", header.syncText)
        fake.behind = 152
        header.show(fake)
        header.layoutSubtreeIfNeeded()
        check(header.syncText == "↓152 ↑3", "both ways shows both counts", header.syncText)
        header.onSync = onSync
        // Narrow, with the window buttons beside the branch: the name stays whole, then the line counts give
        // way before “Pull” does, then the branch glyph, and only a sidebar too narrow for the word without
        // them shows “↓152”.
        fake.ahead = 0
        header.show(fake)
        let inset = header.inset
        header.inset = 70
        func clear() -> Bool { !header.syncButton.frame.intersects(header.hideButton.frame) && header.syncButton.frame.minX > 0 }
        func state() -> String {
            "\(header.syncText), counts shown \(header.summaryIsShown), glyph shown \(header.branchGlyphIsShown), \(header.syncButton.frame)"
        }
        layOut(width: 300)
        check(header.syncText == "Pull 152" && !header.summaryIsShown && header.branchGlyphIsShown && !header.titleIsTruncated && clear(),
              "in a narrow sidebar the line counts give way first: “Pull 152” keeps its word and the branch name stays whole", state())
        layOut(width: ProjectSidebarView.defaultWidth)
        let named = header.branchArea.contains(NSPoint(x: 70 + 4 + 2, y: header.bounds.midY))
        check(header.syncText == "Pull 152" && !header.summaryIsShown && !header.branchGlyphIsShown && !header.titleIsTruncated && clear() && named,
              "at the default width the branch glyph gives way too: still “Pull 152”, and a click on the whole name opens the branches", state())
        layOut(width: 266)
        check(header.syncText == "↓152" && !header.summaryIsShown && !header.branchGlyphIsShown && !header.titleIsTruncated && clear(),
              "narrower still, it shortens to “↓152” and the branch name stays whole", state())
        header.inset = inset
        // A fetch running here: the sync arrow spins, and a click does nothing until it ends.
        fake.behind = 0
        header.show(fake)
        check(header.syncText.isEmpty, "up to date: no button", header.syncText)
        GitWriter.shared.setActivity(.fetching, in: real.root)
        check(await wait(2) { header.syncButton.busy && header.syncText == "Fetching…" },
              "while fetching, the header says so with a spinning sync arrow", header.syncText)
        GitWriter.shared.setActivity(nil, in: real.root)
        check(await wait(2) { header.syncText.isEmpty }, "and it goes when the fetch ends", header.syncText)
        // A background fetch spins the arrow of a button that is there, and never makes one appear.
        GitWriter.shared.setFetchingInBackground(true, in: real.root)
        await pause(0.2)
        check(header.syncText.isEmpty && !header.syncButton.busy, "a background fetch never makes a “Fetching…” button appear", header.syncText)
        fake.behind = 2
        header.show(fake)
        layOut(width: 460)
        check(header.syncText == "Pull 2" && header.syncButton.busy, "but spins the arrow of one already there", "\(header.syncText), busy \(header.syncButton.busy)")
        GitWriter.shared.setFetchingInBackground(false, in: real.root)
        check(await wait(2) { !header.syncButton.busy && header.syncText == "Pull 2" }, "and stops when it ends", header.syncText)
        header.frame = frame
        header.show(c.sidebar.git.snapshot)
    }

    private static func sessionChecks(proj: URL) async {
        let app = AppDelegate.shared!
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-sessions-\(getpid())")
        let project = canonicalPath(proj.path)
        let claudeDir = home.appendingPathComponent(".claude/projects/" + AgentSessions.claudeFolderName(project))
        try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        func line(_ object: [String: Any]) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self) }
        let now = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let earlier = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400 * 3))
        try? [line(["type": "user", "cwd": project, "timestamp": now, "gitBranch": "main", "message": ["content": "Fix the login redirect"]]),
              line(["type": "assistant", "cwd": project, "timestamp": now, "message": ["model": "claude-opus-5-5"]]),
              line(["type": "ai-title", "aiTitle": "Fix the login redirect loop"])].joined(separator: "\n")
            .write(to: claudeDir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        try? [line(["type": "user", "cwd": project + "/src", "timestamp": earlier, "message": ["content": "Add rate limiting"]]),
              line(["type": "custom-title", "customTitle": "Rate limits"])].joined(separator: "\n")
            .write(to: home.appendingPathComponent(".claude/projects/" + AgentSessions.claudeFolderName(project + "/src") + ".jsonl"), atomically: true, encoding: .utf8)
        let srcDir = home.appendingPathComponent(".claude/projects/" + AgentSessions.claudeFolderName(project + "/src"))
        try? FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: home.appendingPathComponent(".claude/projects/" + AgentSessions.claudeFolderName(project + "/src") + ".jsonl"),
                                          to: srcDir.appendingPathComponent("s2.jsonl"))
        let ccDir = home.appendingPathComponent(".commandcode/projects/p")
        try? FileManager.default.createDirectory(at: ccDir, withIntermediateDirectories: true)
        try? line(["type": "session", "version": 3, "id": "c1", "timestamp": earlier, "cwd": project])
            .write(to: ccDir.appendingPathComponent("c1.jsonl"), atomically: true, encoding: .utf8)
        try? #"{"title": "Tidy the billing tests", "model": "claude-opus-5-5"}"#.write(to: ccDir.appendingPathComponent("c1.meta.json"), atomically: true, encoding: .utf8)
        // Command Code's last activity is its transcript's date.
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86400 * 2)], ofItemAtPath: ccDir.appendingPathComponent("c1.jsonl").path)
        SessionStore.home = home.path
        SessionStore.commandPrefix = "echo "
        defer {
            SessionStore.home = NSHomeDirectory()
            SessionStore.commandPrefix = ""
            try? FileManager.default.removeItem(at: home)
        }

        app.openFolder(project, newWindow: false) // a project you have opened is in the list
        app.showWelcome(nil)
        guard let welcome = app.welcomeController, let welcomeWindow = welcome.window else { return check(false, "the Welcome window opens") }
        welcome.select(project: project)
        let direct = AgentSessions.list(project: project, home: home.path)
        check(await wait(10) { welcome.shownSessionTitles.count == 3 }, "Welcome lists the project's agent sessions (subfolders too)",
              welcome.shownSessionTitles.joined(separator: " | ") + " — listed \(welcome.shownProjects.contains(project)), selected \(welcome.selectedProject ?? "none"), direct \(direct.sessions.map(\.title)) \(direct.problems), home \(SessionStore.home)")
        check(welcome.shownSessionTitles.first == "Fix the login redirect loop", "newest first, with the agent's own title")
        await pause(0.3)
        await screenshot(welcomeWindow, suffix: "welcome")
        welcome.resumeSelected()
        // In a new tab, or in the project window's untouched first tab when it is in that folder already.
        let resumed = await wait(10) { app.controllers.flatMap(\.tabs).contains { $0.screenTail(10).contains("claude --resume s1") } }
        let tab = app.controllers.flatMap(\.tabs).first { $0.screenTail(10).contains("claude --resume s1") }
        check(resumed && tab.map { canonicalPath($0.directory) == project } == true,
              "Resume runs `claude --resume <id>` in a new tab in the session's folder", tab?.screenTail(4).joined(separator: " | ") ?? "no tab")
        welcome.close()

        guard let holder = app.controllers.first(where: { $0.project == project }) ?? app.controllers.first(where: { $0.tabs.contains { $0 === tab } }),
              let window = holder.window else { return check(false, "a window for the project") }
        holder.resumeSession(nil)
        let panel = holder.sessionsPanel
        check(await wait(10) { panel.shownTitles.count == 3 }, "⌥⌘O lists them in the project window", panel.shownTitles.joined(separator: " | "))
        await pause(0.3)
        await screenshot(panel.panelWindow, suffix: "sessions")
        panel.query = "rate"
        check(panel.shownTitles == ["Rate limits"], "typing filters them", panel.shownTitles.joined(separator: " | "))
        let before2 = Set(holder.tabs.map(\.id))
        panel.resumeSelected(fork: true)
        check(await wait(10) { holder.tabs.contains { !before2.contains($0.id) && $0.screenTail(10).contains("claude --resume s2 --fork-session") } },
              "⌘↩ forks it instead, in the subfolder it was started in")
        if let forked = holder.tabs.first(where: { !before2.contains($0.id) }) {
            check(canonicalPath(forked.directory) == project + "/src" || canonicalPath(forked.currentDirectory()) == project + "/src" || !FileManager.default.fileExists(atPath: project + "/src"),
                  "in the folder the session was started in", forked.directory)
            holder.remove(forked)
        }
        if let tab { app.controllers.first { $0.tabs.contains { $0 === tab } }?.remove(tab) }
        _ = window
    }

    /// Shortcut presets (VS Code, JetBrains) over the menus, the user's own changes kept on top, and an
    /// import's preview, apply and exact undo.
    private static func importChecks(_ c: TerminalWindowController, proj: URL) async {
        let shortcuts = KeyboardShortcuts.shared
        func item(_ id: String) -> NSMenuItem? { shortcuts.commands.first { $0.id == id }?.item }
        check(shortcuts.commands.contains { $0.id == "setLineHeight:1.35" } && shortcuts.commands.contains { $0.id == "setLineHeight:2.0" },
              "each Line Height item has its own shortcut id")
        let savedPreset = shortcuts.preset
        let savedBindings = shortcuts.bindings
        shortcuts.set(KeyChord(key: "l", command: true, control: true), for: "goToLine:") // the user's own change
        shortcuts.preset = .vsCode
        check(item("replaceInFiles:")?.keyEquivalent == "h" && item("replaceInFiles:")?.keyEquivalentModifierMask == [.command, .shift]
              && item("splitRight:")?.keyEquivalent == "\\" && item("newWindow:")?.keyEquivalentModifierMask == [.command, .shift],
              "VS Code keys: Replace in Files ⇧⌘H, Split Right ⌘\\, New Window ⇧⌘N")
        shortcuts.preset = .jetBrains
        check(item("goToFile:")?.keyEquivalent == "o" && item("goToFile:")?.keyEquivalentModifierMask == [.command, .shift]
              && item("saveAllDocuments:")?.keyEquivalentModifierMask == .command && item("indentSelection:")?.keyEquivalent == "",
              "JetBrains keys: Go to File ⇧⌘O, Save All ⌘S, Indent has no key")
        check(item("replaceInFile:")?.keyEquivalent == "r" && item("replaceInFile:")?.keyEquivalentModifierMask == .command,
              "JetBrains keys: Replace… ⌘R")
        check(item("goToLine:")?.keyEquivalentModifierMask == [.command, .control], "your own shortcut changes stay on top of a preset")
        // ⌘P still opens Go to File under JetBrains keys, until a command takes ⌘P; then it's that command's.
        check(shortcuts.goToFileAliasActive, "with JetBrains keys, ⌘P still opens Go to File")
        shortcuts.set(KeyChord(key: "p", command: true), for: "goToLine:")
        let lineItem = item("goToLine:")
        check(!shortcuts.goToFileAliasActive && lineItem?.keyEquivalent == "p" && lineItem?.keyEquivalentModifierMask == .command,
              "a command given ⌘P gets it; Go to File keeps ⇧⌘O",
              "alias active: \(shortcuts.goToFileAliasActive), Go to Line: “\(lineItem?.keyEquivalent ?? "nil")” \(lineItem?.keyEquivalentModifierMask.rawValue ?? 0), Go to File: “\(item("goToFile:")?.keyEquivalent ?? "nil")”")
        shortcuts.set(KeyChord(key: "l", command: true, control: true), for: "goToLine:")
        check(shortcuts.goToFileAliasActive, "and ⌘P goes back to Go to File when that command gives it up")
        // Two commands trading keys both end up with them (AppKit won't give an item a key another still holds).
        let fileKey = KeyChord(key: "o", command: true, shift: true), lineKey = KeyChord(key: "l", command: true, control: true)
        shortcuts.set(fileKey, for: "goToLine:")
        shortcuts.set(lineKey, for: "goToFile:")
        let traded = item("goToLine:").flatMap(KeyboardShortcuts.chord(of:)) == fileKey && item("goToFile:").flatMap(KeyboardShortcuts.chord(of:)) == lineKey
        check(traded, "two commands can trade keys", "Go to Line: \(item("goToLine:").flatMap(KeyboardShortcuts.chord(of:))?.display ?? "none"), Go to File: \(item("goToFile:").flatMap(KeyboardShortcuts.chord(of:))?.display ?? "none")")
        shortcuts.set(lineKey, for: "goToLine:")
        shortcuts.set(fileKey, for: "goToFile:")
        check(item("goToFile:").flatMap(KeyboardShortcuts.chord(of:)) == fileKey && item("goToLine:").flatMap(KeyboardShortcuts.chord(of:)) == lineKey,
              "and trade them back")
        // ⌘K leaves the editor alone under a preset.
        c.openFile(proj.appendingPathComponent("gutter.txt"))
        if let editor = c.editorArea.activeEditor, let clear = item("clearBuffer:") {
            c.window?.makeFirstResponder(editor.textView)
            check(!c.validateMenuItem(clear), "with VS Code or JetBrains keys, ⌘K does not clear the terminal from the editor")
            c.editorArea.close(editor)
        }
        shortcuts.preset = .nextTerm
        check(item("replaceInFiles:")?.keyEquivalent == "r" && item("goToFile:")?.keyEquivalentModifierMask == .command
              && !shortcuts.goToFileAliasActive,
              "back to Next Term's keys (⌘P is Go to File's own key again, no alias)")
        check(item("replaceInFile:")?.keyEquivalent == "f" && item("replaceInFile:")?.keyEquivalentModifierMask == [.command, .option],
              "and Replace… is ⌥⌘F again")

        // Every command an imported shortcut can land on is a real menu command.
        let ids = Set(shortcuts.commands.map(\.id))
        let missing = ImportShortcuts.titles.keys.filter { !ids.contains($0) }.sorted()
        check(missing.isEmpty, "imported shortcuts only land on commands the menus have", missing.joined(separator: ", "))

        // An import: preview, apply, and undo exactly.
        let app = AppDelegate.shared!
        let fullList = app.recentProjects
        app.setRecentProjects(Array(fullList.prefix(3))) // room for an imported one (an import never pushes yours out)
        let before = (app.fontSize, app.softWrap, app.recentProjects, shortcuts.preset)
        let bindingsBefore = shortcuts.bindings // holds the Go to Line change made above
        // A font and terminal colours come over too, and go back exactly.
        let appearanceBefore = (Preferences.editorFontFamily, Preferences.terminalPalette, Preferences.customTerminalPalette)
        var ansi: [UInt32?] = Array(repeating: nil, count: 16)
        ansi[1] = 0xFF5555
        let colours = TerminalPalette(name: "VS Code terminal colours", ansi: ansi, background: 0x102030)
        let extra = proj.appendingPathComponent("imported-project")
        try? FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        // One of the user's own shortcuts (⌥⌘P for Go to File), and a Control key that is never taken.
        let mine = KeyChord(key: "p", command: true, option: true)
        let plan = ImportPlan(preset: .vsCode,
                              settings: [PlannedSetting(.fontSize(clamping: before.0 + 2), source: "editor.fontSize \(Int(before.0) + 2)"),
                                         PlannedSetting(.softWrap(!before.1), source: "editor.wordWrap"),
                                         PlannedSetting(.optionAsMeta(true), source: "terminal.integrated.macOptionIsMeta", ticked: false,
                                                        note: "Option types @ [ ] { } on your keyboard layout"),
                                         PlannedSetting(.editorFontFamily("Menlo"), source: "editor.fontFamily Menlo, monospace"),
                                         PlannedSetting(.terminalPalette(colours), source: "terminal colours in workbench.colorCustomizations",
                                                        note: "2 of 20 colours; the others stay Next Term's")],
                              shortcuts: [PlannedShortcut(command: "goToFile:", title: "Go to File…", chord: mine,
                                                          source: "keybindings.json: cmd+alt+p → workbench.action.quickOpen"),
                                          PlannedShortcut(command: "goToLine:", title: "Go to Line…", chord: KeyChord(key: "g", control: true),
                                                          source: "keybindings.json: ctrl+g → workbench.action.gotoLine", allowed: false,
                                                          note: "Control keys without ⌘ stay with your shell and agents")],
                              recentProjects: [canonicalPath(extra.path)],
                              skipped: [SkippedItem("Terminal font “Operator Mono”", "not installed on this Mac"),
                                        SkippedItem("terminal.integrated.env.osx", "never imported: can hold secrets")])
        let window = ImportWindowController.shared
        window.showPreview(for: DetectedApp(kind: .vsCode, name: "VS Code", configPath: "/tmp", lastUsed: Date()), plan: plan)
        await pause(0.4)
        if let previewWindow = window.window { await screenshot(previewWindow, suffix: "import") }
        check(window.applyTitle == "Apply \(KeymapPreset.vsCode.overrides.count + 6) Changes", "the preview counts what is ticked", window.applyTitle)
        func swatches(in view: NSView?) -> [PaletteSwatches] {
            guard let view else { return [] }
            return (view as? PaletteSwatches).map { [$0] } ?? view.subviews.flatMap { swatches(in: $0) }
        }
        let shownSwatches = swatches(in: window.window?.contentView)
        check(shownSwatches.count == 1 && shownSwatches.first?.colours == Theme.terminalColours(colours),
              "the preview shows the imported terminal colours as a swatch row", "\(shownSwatches.count)")
        window.applyForTest()
        let terminalView = c.tabs.first?.view
        check(Preferences.editorFontFamily == "Menlo" && EditorDocument.font.familyName == "Menlo"
              && Preferences.terminalPalette == colours && terminalView?.nativeBackgroundColor == NSColor(hex: 0x102030),
              "Apply sets the editor font and the terminal colours, at once in the open terminal",
              "\(EditorDocument.font.familyName ?? "none") \(String(describing: terminalView?.nativeBackgroundColor))")
        check(app.fontSize == before.0 + 2 && app.softWrap != before.1 && !Preferences.optionAsMeta
              && shortcuts.preset == .vsCode && app.recentProjects.contains(canonicalPath(extra.path)),
              "Apply sets the ticked changes and leaves the unticked one",
              "font \(app.fontSize) wrap \(app.softWrap) meta \(Preferences.optionAsMeta) preset \(shortcuts.preset) recents \(app.recentProjects)")
        check(item("goToFile:")?.keyEquivalent == "p" && item("goToFile:")?.keyEquivalentModifierMask == [.command, .option]
              && shortcuts.chord(for: "goToLine:") == KeyChord(key: "l", command: true, control: true),
              "your own shortcut comes over on top of the preset, and the Control key doesn't",
              "\(shortcuts.chord(for: "goToFile:")?.display ?? "none") \(shortcuts.chord(for: "goToLine:")?.display ?? "none")")
        check(ImportCoordinator.shared.last?.source == "VS Code", "the import is remembered for Undo")
        ImportCoordinator.shared.undo()
        check(app.fontSize == before.0 && app.softWrap == before.1 && shortcuts.preset == before.3 && app.recentProjects == before.2,
              "Undo Import puts everything back exactly", "\(app.fontSize) \(app.softWrap) \(shortcuts.preset) \(app.recentProjects.count)")
        let backgroundBefore = NSColor(hex: Theme.terminalColours(appearanceBefore.1).background)
        check(Preferences.editorFontFamily == appearanceBefore.0 && Preferences.terminalPalette == appearanceBefore.1
              && Preferences.customTerminalPalette == appearanceBefore.2 && terminalView?.nativeBackgroundColor == backgroundBefore,
              "Undo Import puts the editor font and the terminal colours back, in the open terminal too",
              "\(Preferences.editorFontFamily ?? "default") \(Preferences.terminalPalette?.name ?? "Next Term's")")
        check(shortcuts.bindings == bindingsBefore && item("goToFile:")?.keyEquivalent == "p"
              && item("goToFile:")?.keyEquivalentModifierMask == .command,
              "Undo Import gives Go to File its old shortcut back, and your other changes stay",
              shortcuts.chord(for: "goToFile:")?.display ?? "none")
        shortcuts.bindings = savedBindings
        shortcuts.preset = savedPreset
        app.setRecentProjects(fullList)
        try? FileManager.default.removeItem(at: extra)

        // SF Mono, the font of most of Terminal's profiles, is the system's monospaced face; the font menus
        // list it once their list, made in the background, is in.
        let sfMono = Theme.font(family: FontCatalog.systemMonospacedFamily, size: 13)
        let systemMono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        check(sfMono.isFixedPitch && sfMono.fontName == systemMono.fontName,
              "SF Mono, as an import brings it from Terminal, is the system's monospaced face", sfMono.fontName)
        let fontMenu = FontFamilyPopup()
        fontMenu.show(FontCatalog.systemMonospacedFamily)
        let menuFilled = await wait { fontMenu.numberOfItems > 3 }
        check(menuFilled && fontMenu.titleOfSelectedItem == "SF Mono" && fontMenu.itemTitles.contains("Menlo"),
              "the font menus fill in from the background, with SF Mono chosen",
              "\(fontMenu.numberOfItems) \(fontMenu.titleOfSelectedItem ?? "none")")
    }

    /// A deleted file keeps a row where it was (struck through, with its −N), so a folder's count always
    /// has a row that explains it; it opens as what was removed. A folder deleted whole has one too.
    /// A Jupyter notebook opens read-only as cells (never as raw JSON, never run), Open as JSON edits the
    /// file, and the view follows the file on disk.
    private static func notebookChecks(_ c: TerminalWindowController, proj: URL) async {
        let area = c.editorArea
        let file = proj.appendingPathComponent("rag.ipynb")
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAYAAAC09K7GAAAAEklEQVR4nGM4EaDxHxkzEBQAAKyxGvWvi7wBAAAAAElFTkSuQmCC"
        func cell(_ type: String, _ source: String, count: Int? = nil, outputs: [[String: Any]] = []) -> [String: Any] {
            var cell: [String: Any] = ["cell_type": type, "metadata": [String: Any](), "source": source]
            if type == "code" { cell["execution_count"] = count ?? NSNull(); cell["outputs"] = outputs }
            return cell
        }
        func write(_ cells: [[String: Any]], to url: URL) {
            let notebook: [String: Any] = ["cells": cells, "nbformat": 4, "nbformat_minor": 5, "metadata": [
                "kernelspec": ["display_name": "Python 3 (ipykernel)", "language": "python", "name": "python3"]]]
            try? JSONSerialization.data(withJSONObject: notebook).write(to: url)
        }
        var cells = [
            cell("markdown", "# RAG over a blog post\n\nLoad, split, **retrieve**."),
            cell("code", "def answer(question):\n    return retrieve(question)\n\nprint(\"Total characters: 43047\")", count: 1,
                 outputs: [["output_type": "stream", "name": "stdout", "text": "Total characters: 43047\n"]]),
            cell("code", "graph.invoke({\"query\": \"What is Task Decomposition?\"})", count: 2, outputs: [[
                "output_type": "error", "ename": "KeyError", "evalue": "'question'",
                "traceback": ["\u{1B}[0;31mKeyError\u{1B}[0m                Traceback (most recent call last)", "\u{1B}[0;31mKeyError\u{1B}[0m: 'question'"],
            ]]),
            cell("code", "display(Image(graph.get_graph().draw_mermaid_png()))", count: 3,
                 outputs: [["output_type": "display_data", "data": ["image/png": png, "text/plain": "<Image>"], "metadata": [String: Any]()]]),
        ]
        write(cells, to: file)
        let editorsBefore = area.editors.count
        c.openFile(file)
        guard let notebook = area.activeNotebook else { return check(false, "an .ipynb opens as a notebook", area.activeName ?? "nothing") }
        check(notebook.name == "rag.ipynb" && area.editors.count == editorsBefore, "an .ipynb opens as a notebook, not as text")
        check(area.tabBar.items.last { $0.title == "rag.ipynb" }?.icon?.accessibilityDescription == "jupyter", "its tab has the notebook icon")
        check(await wait(5) { notebook.isSettled }, "the notebook is read and coloured", notebook.loadError ?? "")
        let text = notebook.textView.string as NSString
        check(notebook.notebook?.cells.count == 4 && notebook.notebook?.language == "python", "its four cells, in Python",
              "\(notebook.notebook?.cells.count ?? -1) \(notebook.notebook?.language ?? "nil")")
        check(text.contains("RAG over a blog post") && text.contains("def answer(question):"), "Markdown and code show as text")
        check(text.contains("Total characters: 43047\n"), "a cell's printed output shows below it")
        let error = text.range(of: "KeyError: 'question'")
        let errorColor = error.location == NSNotFound ? nil : notebook.textView.textStorage?.attribute(.foregroundColor, at: error.location, effectiveRange: nil) as? NSColor
        check(errorColor == NotebookRenderer.errorText && !text.contains("\u{1B}"), "an error shows in red, its colour codes stripped")
        var images = 0
        notebook.textView.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if (value as? NSTextAttachment)?.attachmentCell is NotebookImageCell { images += 1 }
        }
        check(images == 1, "an image output is shown", "\(images) images")
        let def = text.range(of: "def answer")
        let defColor = (notebook.textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: def.location, effectiveRange: nil) as? NSColor)?
            .usingColorSpace(.sRGB).map { String(format: "%02X%02X%02X", Int(round($0.redComponent * 255)), Int(round($0.greenComponent * 255)), Int(round($0.blueComponent * 255))) }
        check(defColor == "CF8E6D", "code cells are coloured in the kernel's language", defColor ?? "none")
        check(!notebook.textView.isEditable && notebook.textView.usesFindBar, "read-only, with ⌘F")
        if let window = c.window, let on = replaceIsOn(with: notebook.textView, in: window) { check(!on, "and no Replace…") }
        await screenshot(c, suffix: "-notebook")

        // An agent adds a cell: the view follows the file.
        cells.append(cell("code", "len(all_splits)", count: 4, outputs: [["output_type": "execute_result", "execution_count": 4,
                                                                          "data": ["text/plain": "66"], "metadata": [String: Any]()]]))
        write(cells, to: file)
        check(await wait(5) { notebook.notebook?.cells.count == 5 && notebook.isSettled }, "a change on disk shows up in the notebook")

        // Open as JSON: the file itself, in the editor, beside the notebook.
        notebook.openAsJSONClicked()
        let json = area.activeEditor
        check(json?.document.path == canonicalPath(file.path) && json?.document.language == "json" && area.notebooks.count == 1,
              "Open as JSON opens the file in the editor, as JSON", json?.document.language ?? "no editor")
        if let json { area.close(json) }
        // Opening it again shows the notebook tab already open; a search result's line opens the JSON there.
        c.openFile(file)
        check(area.activeNotebook === notebook && area.notebooks.count == 1, "opening it again shows its tab")
        c.openFile(file, line: 3)
        check(area.activeEditor?.document.path == canonicalPath(file.path), "a line in it opens the JSON at that line")
        if let editor = area.activeEditor { area.close(editor) }

        // Renamed in the sidebar: the tab follows.
        c.sidebar.rename(file, to: "renamed.ipynb")
        check(notebook.name == "renamed.ipynb" && !notebook.isDeletedOnDisk, "a renamed notebook stays open under its new name", notebook.name)
        await pause(1.2)
        check(notebook.notebook?.cells.count == 5 && notebook.loadError == nil, "and is not reported as deleted")
        area.close(notebook)

        // Past the editor's 4 MiB highlighting limit (a big image): still a notebook.
        let big = proj.appendingPathComponent("big.ipynb")
        let heavy = png + String(repeating: "A", count: 5 * 1024 * 1024)
        write([cell("code", "plt.show()", count: 1, outputs: [["output_type": "display_data", "data": ["image/png": heavy], "metadata": [String: Any]()]])], to: big)
        c.openFile(big)
        let large = area.activeNotebook
        check(large?.name == "big.ipynb", "a 5 MB notebook opens as a notebook", area.activeName ?? "nothing")
        check(await wait(10) { large?.isSettled == true && large?.notebook?.cells.count == 1 }, "and is read", large?.loadError ?? "")
        if let large { area.close(large) }
        try? FileManager.default.removeItem(at: big)
        try? FileManager.default.removeItem(at: proj.appendingPathComponent("renamed.ipynb"))
    }

    /// A Laravel-style .env and a SQLite file: the Databases group lists both, masked; no password reaches
    /// a row, tooltip, accessibility label, menu or the clipboard; a remote host gets no terminal hand-off;
    /// the viewer reads the file's tables and first rows and leaves the folder as it was.
    private static func databaseChecks(_ c: TerminalWindowController, proj: URL) async {
        let fm = FileManager.default
        let secret = "Selftest-Secret-9f3"
        let env = proj.appendingPathComponent(".env")
        let folder = proj.appendingPathComponent("database")
        let file = folder.appendingPathComponent("app.sqlite")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        sqlite3_open(file.path, &handle)
        sqlite3_exec(handle, """
            CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT);
            INSERT INTO users (name, email) VALUES ('Ada', 'ada@example.com'), ('Grace', 'grace@example.com'), ('Linus', NULL);
            CREATE TABLE migrations (id INTEGER PRIMARY KEY, migration TEXT);
            """, nil, nil, nil)
        sqlite3_close(handle)
        try? """
            APP_NAME=Shop
            APP_URL=http://shop.test
            DB_CONNECTION=mysql
            DB_HOST=127.0.0.1
            DB_PORT=3306
            DB_DATABASE=shop
            DB_USERNAME=root
            DB_PASSWORD="\(secret)"
            ANALYTICS_DATABASE_URL=postgres://reader:\(secret)@analytics.example.com:5432/stats?sslmode=require
            """.write(to: env, atomically: true, encoding: .utf8)
        defer {
            try? fm.removeItem(at: env)
            try? fm.removeItem(at: folder)
        }
        let sidebar = c.sidebar
        let group = sidebar.databasesGroup
        check(await wait(10) { group.items.count == 3 }, "the Databases group lists the .env's databases and the SQLite file",
              group.items.map(\.database.name).joined(separator: ", "))
        check(sidebar.outline.item(atRow: 1) is DatabasesGroup && sidebar.outline.isItemExpanded(group), "at the top of the project tree, open")
        guard let mysql = group.items.first(where: { $0.database.engine == .mysql })?.database,
              let remote = group.items.first(where: { $0.database.engine == .postgres })?.database,
              let sqlite = group.items.first(where: { $0.database.engine == .sqlite })?.database else { return check(false, "MySQL, Postgres and SQLite rows") }
        check(mysql.masked == "mysql://root:•••@127.0.0.1:3306/shop" && mysql.environment == .local, "the MySQL row is local and masked", mysql.masked)
        check(remote.environment == .remote && remote.masked.contains("reader:•••@analytics.example.com"), "a remote host is tagged remote", remote.masked)

        // Every string the rows show, say or offer, and the clipboard after Copy Connection Name.
        sidebar.outline.layoutSubtreeIfNeeded()
        var shown: [String] = []
        for row in 0..<sidebar.outline.numberOfRows {
            let item = sidebar.outline.item(atRow: row)
            guard item is DatabaseItem || item is DatabasesGroup,
                  let cell = sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? DatabaseCellView else { continue }
            shown += [cell.tipText, cell.accessibilityLabel() ?? "", cell.nameText, cell.badge.text]
            let rect = sidebar.outline.rect(ofRow: row)
            shown.append(sidebar.view(sidebar.outline, stringForToolTip: 0, point: NSPoint(x: rect.midX, y: rect.midY), userData: nil))
            if let db = (item as? DatabaseItem)?.database { shown += sidebar.databaseMenu(for: db).items.map(\.title) }
        }
        shown += [DatabaseHandOff.confirmation(for: remote).title, DatabaseHandOff.confirmation(for: remote).detail, String(describing: sidebar.databaseScan)]
        let saved = NSPasteboard.general.string(forType: .string)
        let copyItem = sidebar.databaseMenu(for: mysql).items.first { $0.title == "Copy Connection Name" }
        if let copyItem { sidebar.copyDatabaseName(copyItem) }
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        NSPasteboard.general.clearContents()
        if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        check(copied == "shop", "Copy Connection Name copies the name", copied)
        let mysqlTip = DatabaseText.tooltip(mysql)
        check(mysqlTip.contains("mysql://root:•••@127.0.0.1:3306/shop") && shown.contains(mysqlTip), "the tooltip shows the connection masked")
        let leaks = shown.filter { $0.contains(secret) }
        check(!shown.isEmpty && leaks.isEmpty, "no password in a row, tooltip, accessibility label or menu", leaks.first ?? "")
        let remoteMenu = sidebar.databaseMenu(for: remote).items.map(\.title)
        check(!remoteMenu.contains { $0.hasPrefix("Open psql") || $0.hasPrefix("Open mysql") }, "a remote row has no terminal hand-off", remoteMenu.joined(separator: ", "))
        if DatabaseHandOff.tablePlus != nil {
            check(remoteMenu.contains("Open in TablePlus…") && DatabaseHandOff.confirmation(for: remote).title.contains("analytics.example.com"),
                  "TablePlus asks first for a remote host, naming it")
        }
        let command = DatabaseClientCommand.commandLine(for: mysql, program: "mysql", secretFile: "/tmp/handoff.cnf")
        check(!command.contains(secret) && command.contains("--defaults-extra-file="), "the mysql hand-off names a file, never the password", command)
        if let written = try? HandOffFile.write("[client]\npassword=\"x\"\n", suffix: ".cnf") {
            let mode = (try? fm.attributesOfItem(atPath: written.path)[.posixPermissions] as? Int) ?? 0
            let folderMode = (try? fm.attributesOfItem(atPath: HandOffFile.folder.path)[.posixPermissions] as? Int) ?? 0
            check(mode == 0o600 && folderMode == 0o700, "the hand-off's password file is 0600 in a 0700 folder", String(mode, radix: 8) + " " + String(folderMode, radix: 8))
            unlink(written.path)
        } else {
            check(false, "the hand-off's password file can be written")
        }
        await screenshot(c, suffix: "-databases")

        // The viewer: read-only, its tables and first rows, nothing new beside the file.
        let before = (try? fm.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []
        let stamp = FileStamp(path: file.path)
        c.sidebar(sidebar, database: sqlite, perform: .open)
        guard let pane = c.editorArea.activeDatabase else { return check(false, "Open shows the SQLite file in the viewer", c.editorArea.activeName ?? "nothing") }
        check(await wait(5) { pane.isSettled && pane.page != nil }, "the viewer reads the file", pane.loadError ?? "")
        check(pane.tables.map(\.name) == ["migrations", "users"], "it lists the tables", pane.tables.map(\.name).joined(separator: ", "))
        pane.select(table: "users")
        check(await wait(5) { pane.isSettled && pane.page?.table == "users" }, "a table opens on its first page")
        check(pane.total == 3 && pane.page?.columns == ["id", "name", "email"] && pane.page?.rows.first?[1] == .text("Ada", truncated: false)
              && pane.page?.rows.last?[2] == .null, "with its row count and first rows", "\(pane.total ?? -1) \(pane.page?.rows.count ?? -1)")
        check(pane.grid.numberOfRows == 3 && pane.grid.tableColumns.map(\.title) == ["id", "name", "email"], "the grid shows them")
        pane.grid.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        check(pane.export(TableExport.csv) == "id,name,email\n2,Grace,grace@example.com\n", "Copy As CSV takes the selected rows", pane.export(TableExport.csv))
        let item = pane.contextItem()
        check(item.path == canonicalPath(file.path) && item.note?.contains("table “users”") == true && item.code?.contains("| 2 | Grace |") == true,
              "Send to Agent names the file and table, with the selected row", item.note ?? "")
        check(c.agentText([item], for: "claude").contains("Grace"), "and types it into the agent's prompt")
        await screenshot(c, suffix: "-sqlite")
        check((try? fm.contentsOfDirectory(atPath: folder.path))?.sorted() == before && FileStamp(path: file.path) == stamp,
              "reading leaves the file and its folder as they were")
        c.editorArea.close(pane)

        try? fm.removeItem(at: env)
        try? fm.removeItem(at: folder)
        check(await wait(10) { group.items.isEmpty && !(sidebar.outline.item(atRow: 1) is DatabasesGroup) }, "the group goes when the files do")
    }

    /// Large data files open in the head view: a 20 MB JSON Lines file as a column per key, its bad line
    /// marked and Load More adding rows; a CSV with quoted newlines under its header; a 34 MB log the
    /// editor refuses. Nothing is written to them.
    private static func dataChecks(_ c: TerminalWindowController, proj: URL) async {
        let fm = FileManager.default
        let area = c.editorArea
        let jsonl = proj.appendingPathComponent("corpus.jsonl")
        let csv = proj.appendingPathComponent("eval.csv")
        let log = proj.appendingPathComponent("server.log")
        defer { for url in [jsonl, csv, log] { try? fm.removeItem(at: url) } }

        let embedding = (0..<16).map { String(format: "%.3f", Double($0) / 17) }.joined(separator: ",")
        fm.createFile(atPath: jsonl.path, contents: nil)
        guard let out = FileHandle(forWritingAtPath: jsonl.path) else { return check(false, "a 20 MB JSON Lines file can be written") }
        var written = 0, lines = 0
        while written < 20 << 20 {
            var chunk = ""
            for _ in 0..<5000 {
                let row = #"{"id":\#(lines),"text":"chunk \#(lines) of the corpus","embedding":[\#(embedding)],"meta":{"source":"doc-\#(lines % 50).md"}}"#
                chunk += (lines == 2 ? #"{"id":2,"text":oops}"# : row) + "\n"
                lines += 1
            }
            out.write(Data(chunk.utf8))
            written += chunk.utf8.count
        }
        try? out.close()
        let stamp = FileStamp(path: jsonl.path)
        c.openFile(jsonl)
        guard let pane = area.activeData else { return check(false, "a 20 MB .jsonl opens in the head view", area.activeName ?? "nothing") }
        check(await wait(10) { pane.isSettled && pane.records.count == DataHead.pageSize }, "it reads the first 1,000 rows", pane.loadError ?? "\(pane.records.count)")
        check(pane.columns == ["id", "text", "embedding", "meta"], "a column per top-level key, in the file’s order", pane.columns.joined(separator: ", "))
        let titles = pane.grid.tableColumns.map(\.title)
        let firstText = pane.records.first.map { pane.cellText($0, column: 1) }
        check(firstText == "chunk 0 of the corpus" && pane.grid.numberOfRows == 1000 && titles == ["#", "id", "text", "embedding", "meta"],
              "the grid shows them, strings without their quotes", titles.joined(separator: ", "))
        let bad = pane.records[2]
        check(bad.line == 3 && bad.error?.hasPrefix("Not valid JSON") == true && pane.records[3].error == nil, "the bad line is marked and the rest still read")
        check(pane.rowsText.contains("of about"), "the row count gives an estimated total", pane.rowsText)

        pane.loadMore()
        check(await wait(10) { pane.isSettled && pane.records.count == 2 * DataHead.pageSize }, "Load More adds the next 1,000", "\(pane.records.count)")
        let next = pane.records[1000]
        check(pane.grid.numberOfRows == 2000 && next.line == 1001 && next.value(for: "id") == "1000", "in order, after the first")
        check(await wait(15) { pane.lineCount != nil }, "the lines are counted in the background", pane.rowsText)
        check(pane.estimatedTotal == lines, "and the estimate becomes the count", "\(pane.estimatedTotal ?? -1) of \(lines)")

        pane.find("chunk 1500 ")
        check(await wait(5) { pane.isSettled && pane.visible == [1500] }, "search finds a loaded row", pane.rowsText)
        pane.grid.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        check(pane.exportJSON() == pane.records[1500].raw + "\n", "Copy As JSON copies the row as the file has it", pane.exportJSON())
        let csvCopy = pane.exportCSV()
        check(csvCopy.hasPrefix("id,text,embedding,meta\n1500,chunk 1500 of the corpus,\"[0.000,"), "Copy As CSV puts it under the keys", csvCopy)
        check(pane.contextItem().lines == 1501...1501, "Send to Agent points at its line")
        pane.find("")
        pane.show(lines: true)
        check(pane.grid.tableColumns.map(\.title) == ["#", "Text"] && pane.grid.numberOfRows == 2000, "Lines shows the records as the file has them")
        await screenshot(c, suffix: "-data")
        area.close(pane)
        check(FileStamp(path: jsonl.path) == stamp, "reading leaves the file as it was")

        // A CSV whose quoted fields hold newlines, commas and quotes, just over the 2 MB threshold.
        var text = "id,question,answer\n"
        var rows = 0
        while text.utf8.count < DataPane.threshold + 100_000 {
            text += "\(rows),\"What is \"\"RAG\"\" in row \(rows)?\nTwo lines.\",\"It retrieves, then generates.\"\n"
            rows += 1
        }
        try? text.write(to: csv, atomically: true, encoding: .utf8)
        c.openFile(csv)
        guard let table = area.activeData, table.path == canonicalPath(csv.path) else {
            return check(false, "a 2 MB .csv opens in the head view", area.activeName ?? "nothing")
        }
        check(await wait(10) { table.isSettled && table.records.count == DataHead.pageSize }, "it reads the CSV", table.loadError ?? "")
        check(table.hasHeader && table.columns == ["id", "question", "answer"], "the header row names the columns", table.columns.joined(separator: ", "))
        let row = table.records[1]
        let question = table.cellText(row, column: 1)
        check(question == "What is \"RAG\" in row 0?\nTwo lines." && row.fields[2] == "It retrieves, then generates." && row.line == 2,
              "a quoted field keeps its newline, comma and quotes", row.fields.joined(separator: " | "))
        check(table.records[2].line == 4 && table.grid.numberOfRows == 999, "the next row starts after it, and the header is not a row")
        table.show(lines: true)
        table.grid.selectAll(nil)
        let copied = table.exportCSV()
        check(table.grid.numberOfRows == 1000 && table.rowsText.hasPrefix("\(1000.formatted()) rows"),
              "Lines lists the header line too, and counts it", table.rowsText)
        check(copied.hasPrefix("id,question,answer\n0,") && table.exportJSON().hasPrefix("[\n  {\"id\": \"0\""),
              "but Copy As CSV and JSON do not copy it as a row", String(copied.prefix(60)))
        table.show(lines: false)
        table.onOpenInEditor?(table.url)
        let editor = area.activeEditor
        check(editor?.document.path == canonicalPath(csv.path), "Open in Editor opens it in the editor, which can take it")
        if let editor { area.close(editor) }

        // Written again in place and larger, as `cp` or a script's `>` do (same inode): read again, not
        // taken for a log that grew.
        if let out = FileHandle(forWritingAtPath: csv.path) {
            try? out.truncate(atOffset: 0)
            out.write(Data(("key,question,answer\n" + text).utf8))
            try? out.close()
        }
        table.refreshIfChanged()
        check(await wait(10) { table.isSettled && table.columns == ["key", "question", "answer"] },
              "a CSV written again in place is read again", table.columns.joined(separator: ", "))
        check(table.records[safe: 1]?.fields.first == "id", "from its new first row")
        area.close(table)

        await dataEncodingAndGrowthChecks(c, proj: proj)

        // Too large for the editor: the head view, not another app.
        fm.createFile(atPath: log.path, contents: nil)
        var logSize = 0
        if let out = FileHandle(forWritingAtPath: log.path) {
            let block = Data(String(repeating: "2026-10-07 12:00:00 INFO request served in 12 ms\n", count: 20_000).utf8)
            while logSize <= TextFile.maxEditableSize { // just past the editor's limit
                out.write(block)
                logSize += block.count
            }
            try? out.close()
        }
        c.openFile(log)
        let big = area.activeData
        check(big?.path == canonicalPath(log.path) && big?.kind == .lines, "a 34 MB log the editor refuses opens in the head view",
              area.activeName ?? "nothing")
        check(await wait(10) { big?.isSettled == true && big?.records.count == 1000 }, "with its first 1,000 lines")
        check(big?.isTooLargeForEditor == true && big?.grid.tableColumns.map(\.title) == ["#", "Text"], "as lines, without Open in Editor")
        if let big { area.close(big) }
        // Had it opened in the editor instead, close it before the file is deleted under it.
        if let editor = area.activeEditor, editor.document.path == canonicalPath(log.path) { area.close(editor) }
    }

    /// A UTF-16 data file opens in the editor; a JSON Lines file whose last line is half written reads it
    /// whole once it grows.
    private static func dataEncodingAndGrowthChecks(_ c: TerminalWindowController, proj: URL) async {
        let fm = FileManager.default
        let area = c.editorArea
        // UTF-16 with a BOM, as some spreadsheet exports write it: the head view does not read it, the editor does.
        let wide = proj.appendingPathComponent("keywords.csv")
        defer { try? fm.removeItem(at: wide) }
        var sheet = "keyword\tvolume\n"
        var units = sheet.utf16.count
        while units * 2 < DataPane.threshold + 10_000 {
            let row = "head view \(units)\t1000\n"
            sheet += row
            units += row.utf16.count
        }
        try? (Data([0xFF, 0xFE]) + (sheet.data(using: .utf16LittleEndian) ?? Data())).write(to: wide)
        c.openFile(wide)
        let sheetEditor = area.activeEditor
        check(sheetEditor?.document.path == canonicalPath(wide.path) && area.activeData == nil,
              "a 2 MB UTF-16 .csv opens in the editor, not the head view", area.activeName ?? "nothing")
        if let sheetEditor { area.close(sheetEditor) }

        // A log still being written: its last line has no line break yet. Once the file grows, that line
        // is read again, whole.
        let growing = proj.appendingPathComponent("growing.jsonl")
        defer { try? fm.removeItem(at: growing) }
        let pad = String(repeating: "x", count: 2400)
        var body = ""
        for i in 0..<900 { body += #"{"id":\#(i),"pad":"\#(pad)"}"# + "\n" }
        body += #"{"id":900,"text":"half"#
        try? body.write(to: growing, atomically: true, encoding: .utf8)
        c.openFile(growing)
        guard let feed = area.activeData, feed.path == canonicalPath(growing.path) else {
            return check(false, "a 2 MB .jsonl opens in the head view", area.activeName ?? "nothing")
        }
        check(await wait(10) { feed.isSettled && feed.isAtEnd && feed.records.count == 901 }, "it reads a growing file to its end",
              "\(feed.records.count)")
        check(feed.records.last?.error != nil, "its half-written last line is not JSON yet")
        if let out = FileHandle(forWritingAtPath: growing.path) {
            _ = try? out.seekToEnd()
            out.write(Data((#" written"}"# + "\n" + #"{"id":901}"# + "\n").utf8))
            try? out.close()
        }
        feed.refreshIfChanged()
        check(await wait(5) { feed.isSettled && !feed.isAtEnd && feed.records.count == 900 }, "it grew: the rows stay, the half line goes",
              "\(feed.records.count)")
        feed.loadMore()
        check(await wait(10) { feed.isSettled && feed.records.count == 902 }, "Load More reads on", "\(feed.records.count)")
        let whole = feed.records[safe: 900]
        check(whole?.error == nil && whole?.value(for: "text") == "\"half written\"" && whole?.line == 901
              && feed.records[safe: 901]?.value(for: "id") == "901", "the line reads whole, then the next", whole?.raw ?? "")
        area.close(feed)
    }

    private static func deletedFileChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let git = GitRunner.locateGit(), let root = c.sidebar.root else { return }
        func run(_ args: String...) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", proj.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        let fm = FileManager.default
        let gone = proj.appendingPathComponent("src/gone.txt")
        let folder = proj.appendingPathComponent("src/olddir")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "1\n2\n3\n".write(to: gone, atomically: true, encoding: .utf8)
        try? "x\n".write(to: folder.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        run("add", "src/gone.txt", "src/olddir")
        run("commit", "-qm", "to delete", "--", "src/gone.txt", "src/olddir")
        let outline = c.sidebar.outline
        guard let src = root.children?.first(where: { $0.name == "src" }) else { return check(false, "the test project has src") }
        outline.expandItem(src)
        _ = await wait(3) { outline.isItemExpanded(src) }
        try? fm.removeItem(at: gone)
        run("rm", "-q", "-r", "--cached", "src/olddir") // one staged deletion, one on disk only
        try? fm.removeItem(at: folder)

        func row(_ name: String) -> Int? {
            (0..<outline.numberOfRows).first { row in
                let item = outline.item(atRow: row)
                return (item as? DeletedEntry)?.name == name || (item as? FileNode)?.name == name && outline.parent(forItem: item) as? FileNode === src
            }
        }
        check(await wait(8) { row("gone.txt").map { outline.item(atRow: $0) is DeletedEntry } == true && row("olddir") != nil },
              "a deleted file and a deleted folder keep rows where they were")
        if let at = row("gone.txt"), let cell = outline.view(atColumn: 0, row: at, makeIfNecessary: true) as? FileCellView {
            check(cell.isDeletedRow && cell.statsText == "−3", "struck through, with the lines it had", cell.statsText)
        }
        if let diffRow = row("diff.txt"), let goneRow = row("gone.txt"), let mainRow = row("main.php") {
            check(diffRow < goneRow && goneRow < mainRow, "in name order among the files that are still there", "\(diffRow) \(goneRow) \(mainRow)")
        }
        if let at = row("olddir"), let entry = outline.item(atRow: at) as? DeletedEntry {
            outline.expandItem(entry)
            check(await wait(3) { row("x.txt").map { outline.item(atRow: $0) is DeletedEntry } == true }, "a deleted folder opens to show what was in it")
        }
        await screenshot(c, suffix: "deleted")

        if let at = row("gone.txt"), let entry = outline.item(atRow: at) as? DeletedEntry {
            c.sidebar.openDeleted(entry)
            let diff = c.editorArea.activeDiff
            check(diff?.matches(root: canonicalPath(proj.path), path: "src/gone.txt") == true, "it opens as a diff of what was removed")
            check(await wait(5) { diff?.sideTexts.0.contains("2\n") == true && diff?.sideTexts.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true },
                  "with the old lines on the left and nothing on the right", "\(diff?.sideTexts.0.count ?? -1) | \(diff?.sideTexts.1.count ?? -1)")
            check(diff?.contextItem()?.note == "deleted", "and Send to Agent from it says the file is gone", diff?.contextItem()?.note ?? "no note")
            if let diff {
                // A removed line, selected on the old side: no file has it any more, so it goes along as code.
                let old = diff.oldSideView
                c.window?.makeFirstResponder(old)
                old.setSelectedRange((old.string as NSString).range(of: "2\n"))
                let item = diff.contextItem()
                check(item?.code == "2" && item?.note == "deleted" && item?.lines == nil, "and the removed lines selected on the old side as code",
                      "\(String(describing: item))")
                old.setSelectedRange(NSRange(location: 0, length: 0))
                c.editorArea.close(diff)
            }
        }

        // Back as committed: the rows go, and the file's own row returns.
        run("reset", "-q", "--", "src/olddir")
        run("checkout", "-q", "--", "src/gone.txt", "src/olddir")
        check(await wait(8) { row("gone.txt").map { outline.item(atRow: $0) is FileNode } == true && row("olddir").map { outline.item(atRow: $0) is FileNode } == true },
              "restored, they are ordinary rows again")
        run("rm", "-q", "-r", "src/gone.txt", "src/olddir")
        run("commit", "-qm", "deleted test done")
        _ = await wait(8) { row("gone.txt") == nil && row("olddir") == nil }
    }

    /// What a RAG project is made of reads at a glance: prompt placeholders and templates in Python strings
    /// and Jinja files, keys in pyproject.toml and .env, docstrings, decorators, code inside README fences,
    /// requirements, Prompty, Mermaid and the data and query files. A skill's front matter and its fences
    /// colour whatever was opened before.
    private static func ragColorChecks(_ c: TerminalWindowController, proj: URL) async {
        let folder = proj.appendingPathComponent("rag")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        check(SyntaxEngine.shared?.assets.languageInfo(named: "markdown")?.embeddedLangs.contains("yaml") == true,
              "Markdown loads YAML with it, so front matter colours even if no YAML file was opened first")
        // Nothing else in the self-test opens Lua: its fence colours only because the editor loads it up front.
        let luaWasLoaded = SyntaxEngine.shared?.isLoaded("lua") == true
        let files: [(name: String, text: String, checks: [(word: String, hex: String, what: String)])] = [
            ("prompts.py", "PROMPT = \"\"\"Answer from {context} only.\"\"\"\n\n@tool\ndef search(q):\n    \"\"\"Search the docs.\"\"\"\n    return q\n",
             [("{context}", "C77DBB", "a {placeholder} in a Python prompt string"), ("Search the docs", "5F826B", "a docstring"),
              ("@tool", "B3AE60", "a decorator")]),
            ("qa.j2", "Question: {{ question }}\n{% for d in docs %}{{ d }}{% endfor %}\n",
             [("question }}", "C77DBB", "a Jinja prompt's variable"), ("{{ question", "CF8E6D", "and its {{ }}")]),
            ("pyproject.toml", "[project]\nname = \"rag\"\n", [("name =", "C77DBB", "a pyproject.toml key")]),
            (".env", "OPENAI_API_KEY=sk-test\n", [("OPENAI_API_KEY", "C77DBB", "a .env key")]),
            ("README.md", "# RAG\n\n```python\nchain = prompt | llm\ndef run(): pass\n```\n",
             [("chain =", "BCBEC4", "a name in a README's Python fence (not string green)"), ("def run", "CF8E6D", "and its keywords")]),
            ("SKILL.md", "---\nname: pdf-tools\ndescription: Fill and merge PDFs.\n---\n\n# PDF tools\n\n``` lua\nlocal pages = 2\n```\n",
             [("name:", "C77DBB", "a SKILL.md front-matter key"), ("local pages", "CF8E6D", "a keyword in a \"``` lua\" fence (space after the backticks)")]),
            // After SKILL.md: rst loads Ruby, and Ruby loads Lua.
            ("DIAGRAM.md", "# Flow\n\n```mermaid\ngraph TD\n  A[Ask] --> B[Retrieve]\n```\n",
             [("graph TD", "CF8E6D", "a Mermaid fence in Markdown"), ("--> B", "CF8E6D", "and its arrows")]),
            ("graph.mmd", "graph LR\n  Q[Question] --> R[Retriever]\n",
             [("graph LR", "CF8E6D", "a Mermaid file"), ("Retriever", "6AAB73", "and its node labels")]),
            ("eval.tsv", "question\tanswer\tscore\n", [("answer", "CF8E6D", "a TSV column")]),
            ("search.cypher", "// nearest chunks\nMATCH (c:Chunk) RETURN c LIMIT 5\n",
             [("MATCH", "CF8E6D", "a Cypher keyword"), ("// nearest", "7A7E85", "and comment")]),
            ("people.rq", "SELECT ?name WHERE { ?p a ?t }\n", [("SELECT", "CF8E6D", "a SPARQL keyword")]),
            ("graph.ttl", "@prefix foaf: <http://xmlns.com/foaf/0.1/> .\n<#me> a foaf:Person .\n",
             [("foaf:Person", "CF8E6D", "a Turtle prefixed name")]),
            ("index.rst", "Retrieval\n=========\n\n.. note:: Chunks are cached.\n", [(".. note::", "CF8E6D", "an rst directive")]),
            ("requirements.txt", "# app\nlangchain>=0.3.0\n",
             [("langchain", "56A8F5", "a package in requirements.txt"), (">=", "CF8E6D", "its version operator"), ("0.3.0", "2AACB8", "and its version")]),
            ("chat.prompty", "---\nname: Support chat\nmodel:\n  configuration:\n    azure_deployment: ${env:AZURE_DEPLOYMENT}\n---\n"
                + "system:\nAnswer from the documents.\n\nuser:\n{{question}}\n",
             [("name:", "C77DBB", "a Prompty front-matter key"), ("${env", "C77DBB", "an ${env:…} reference in it"),
              ("user:", "CF8E6D", "a Prompty role line"), ("question}}", "C77DBB", "a {{variable}} in a Prompty message")]),
            ("templates.py", #"""
                HAYSTACK = """{% for doc in documents %}{{ doc.content }}{% endfor %}"""
                MUSTACHE = "Hello {{name}}, {{ today | upper }}"
                JSON = """Return JSON: {{"nodes": [], "q": "{question}"}}"""
                def render(choices):
                    """Fills {{ x }} in."""
                    return '{%s}' % choices
                after = 1

                """#,
             [("{% for", "CF8E6D", "a Jinja tag in a Python string"), ("documents %}", "C77DBB", "and its variable"),
              ("name}}", "C77DBB", "a Mustache variable in a Python string"),
              (#"{{"nodes"#, "C77DBB", "str.format's escaped braces stay a placeholder"),
              (#""nodes""#, "6AAB73", "with the JSON in them still a string"), ("{{ x }} in", "5F826B", "a docstring stays a docstring"),
              ("after =", "BCBEC4", "and code after '{%s}' % x is still code")]),
        ]
        if luaWasLoaded { note("Lua was loaded before SKILL.md opened: its fence check does not prove the preload") }
        for file in files {
            let url = folder.appendingPathComponent(file.name)
            try? file.text.write(to: url, atomically: true, encoding: .utf8)
            c.openFile(url)
            guard let editor = c.editorArea.activeEditor, editor.document.url.lastPathComponent == file.name else {
                check(false, "\(file.name) opens"); continue
            }
            _ = await wait(5) { editor.document.highlighter?.pendingLines == 0 }
            let text = editor.document.text as NSString
            for (word, hex, what) in file.checks {
                let r = text.range(of: word)
                var found = "none"
                if r.location != NSNotFound, let color = editor.textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: r.location,
                                                                                                           effectiveRange: nil) as? NSColor,
                   let rgb = color.usingColorSpace(.sRGB) {
                    found = String(format: "%02X%02X%02X", Int(round(rgb.redComponent * 255)), Int(round(rgb.greenComponent * 255)),
                                   Int(round(rgb.blueComponent * 255)))
                }
                check(found == hex, "RAG files: \(what) has its own colour", "\(file.name): \(word) is \(found)")
            }
            c.editorArea.close(editor)
        }
    }

    /// Settings › Editor › Hide values in .env files: each value is drawn as bullets, on its row, while the
    /// text stays as it is (copy, undo); the caret's line shows its value once you type in it, and only
    /// that line of a private key; it hides again when the editor or its window loses the keyboard. View ›
    /// Hide .env Values for one file, with a checkmark. A .env that links to a file elsewhere counts too.
    private static func envValueChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let window = c.window, let app = AppDelegate.shared else { return }
        let saved = app.hidesEnvValues
        let folder = proj.appendingPathComponent("envmask")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            app.hidesEnvValues = saved
            try? FileManager.default.removeItem(at: folder)
        }
        let long = String(repeating: "abcdefghij", count: 30) // wraps
        var lines: [String] = ["# shared on screen", "API_KEY=sk-live-0123456789 # rotate monthly", "export DB_URL=\"postgres://u:p@h/db\"",
                               "LONG=" + long, "EMPTY="]
        lines.append(contentsOf: ["PEM=\"-----BEGIN KEY-----", "MIIabc", "-----END KEY-----\""]) // a private key, over three lines
        let original = lines.joined(separator: "\n") + "\n"
        let url = folder.appendingPathComponent(".env")
        try? original.write(to: url, atomically: true, encoding: .utf8)
        app.hidesEnvValues = true
        c.openFile(url)
        guard let editor = c.editorArea.activeEditor, editor.document.path.hasSuffix("envmask/.env") else { return check(false, "a .env file opens") }
        let view = editor.textView
        let doc = editor.document
        _ = await wait(5) { doc.highlighter?.pendingLines == 0 }
        window.makeFirstResponder(view)
        let text = doc.text as NSString
        let key = text.range(of: "API_KEY"), value = text.range(of: "sk-live-0123456789")
        // The caret at the end of the line, away from the key and the value.
        let lineEnd = NSMaxRange(text.range(of: "# rotate monthly"))
        view.setSelectedRange(NSRange(location: lineEnd, length: 0))
        func bullets(_ count: Int) -> String { String(repeating: "•", count: count) }
        var hidden: [String] = [lines[0]]
        hidden.append("API_KEY=" + bullets(18) + " # rotate monthly")
        hidden.append("export DB_URL=" + bullets(21))
        hidden.append("LONG=" + bullets(300))
        hidden.append("EMPTY=")
        hidden.append("PEM=" + bullets(20))
        hidden.append(bullets(6))
        hidden.append(bullets(18))
        let drawn = lines.indices.map { editor.drawnText(line: $0) }
        check(drawn == hidden, ".env values are drawn as bullets; keys, comments and the caret's line too until you type",
              drawn.joined(separator: " | "))
        check(doc.text == original && !doc.isDirty, "and the text itself is unchanged")
        await screenshot(c, suffix: "env-hidden")

        // What is really drawn over some characters on one row: the image, how many pixels are ink (unlike
        // the row's background, its most common colour), and whether ink touches the row's top or bottom
        // edge, as bullets drawn off their baseline would.
        struct Drawn { var image: Data?; var ink = 0; var atEdge = false }
        func pixels(_ characters: NSRange) -> Drawn {
            guard let manager = view.layoutManager, let container = view.textContainer else { return Drawn() }
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            let row = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container).intersection(row)
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            // Whole points inside the row, so no sliver of the next row (or of the caret line's band) comes in.
            let left = bounds.minX.rounded(.up), top = bounds.minY.rounded(.up)
            let right = bounds.maxX.rounded(.down), bottom = bounds.maxY.rounded(.down)
            let rect = NSRect(x: left, y: top, width: right - left, height: bottom - top)
            guard rect.width > 0, rect.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return Drawn() }
            view.cacheDisplay(in: rect, to: rep)
            var result = Drawn(image: rep.tiffRepresentation)
            var samples = [Int](repeating: 0, count: max(rep.samplesPerPixel, 4))
            func pixel(_ x: Int, _ y: Int) -> [Int] {
                rep.getPixel(&samples, atX: x, y: y)
                return Array(samples.prefix(rep.samplesPerPixel))
            }
            var counts: [[Int]: Int] = [:]
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide { counts[pixel(x, y), default: 0] += 1 }
            }
            guard let paper = counts.max(by: { $0.value < $1.value })?.key else { return result }
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    var difference = 0
                    for (sample, background) in zip(pixel(x, y), paper) { difference += abs(sample - background) }
                    guard difference > 48 else { continue }
                    result.ink += 1
                    if y == 0 || y == rep.pixelsHigh - 1 { result.atEdge = true }
                }
            }
            return result
        }
        /// The characters on a wrapped line's second row, or nil if it does not wrap.
        func secondRow(_ characters: NSRange) -> NSRange? {
            guard let manager = view.layoutManager else { return nil }
            var fragments: [NSRange] = []
            let glyphs = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, row, _ in fragments.append(row) }
            guard fragments.count > 1 else { return nil }
            return NSIntersectionRange(manager.characterRange(forGlyphRange: fragments[1], actualGlyphRange: nil), characters)
        }
        func rows() -> [NSRect] {
            guard let manager = view.layoutManager, let container = view.textContainer else { return [] }
            return (0..<doc.lines.count).map { line in
                manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: doc.lines.range(ofLine: line), actualCharacterRange: nil),
                                     in: container)
            }
        }
        let wrapped = secondRow(text.range(of: long))
        if wrapped == nil { note("LONG did not wrap (soft wrap off?): its second row is not measured") }
        let hiddenValue = pixels(value), hiddenKey = pixels(key), hiddenRows = rows()
        let hiddenWrap = wrapped.map(pixels)
        check(hiddenValue.ink > 0 && !hiddenValue.atEdge, "a hidden value's bullets are drawn, within its row",
              "\(hiddenValue.ink) pixels of ink, at the edge: \(hiddenValue.atEdge)")
        if let hiddenWrap {
            check(hiddenWrap.ink > 0 && !hiddenWrap.atEdge, "and on the second row of a value that wraps",
                  "\(hiddenWrap.ink) pixels of ink, at the edge: \(hiddenWrap.atEdge)")
        }

        // View › Hide .env Values: checked while this file's values are hidden.
        var menuItem: NSMenuItem?
        for top in NSApp.mainMenu?.items ?? [] where menuItem == nil {
            menuItem = top.submenu?.items.first(where: { $0.action == #selector(TerminalWindowController.toggleEnvValues(_:)) })
        }
        check(menuItem?.title == "Hide .env Values", "View › Hide .env Values is in the menu", menuItem?.title ?? "missing")
        let item = menuItem ?? NSMenuItem(title: "", action: #selector(TerminalWindowController.toggleEnvValues(_:)), keyEquivalent: "")
        check(c.validateMenuItem(item) && item.state == .on, "and is checked for a .env file whose values are hidden")
        c.toggleEnvValues(nil)
        check(!editor.hidesEnvValues && editor.drawnText(line: 1) == lines[1] && editor.drawnText(line: 3) == lines[3],
              "choosing it shows this file's values", editor.drawnText(line: 1))
        let shownValue = pixels(value)
        check(hiddenValue.image != nil && hiddenValue.image != shownValue.image, "a hidden value is drawn differently from its text")
        if let wrapped, let hiddenWrap {
            check(hiddenWrap.image != pixels(wrapped).image, "and so is the second row of one that wraps")
        }
        check(hiddenKey.image != nil && hiddenKey.image == pixels(key).image, "its key is drawn the same either way")
        check(!hiddenRows.isEmpty && hiddenRows == rows(), "the rows are laid out the same, hidden or shown: only the drawing differs",
              "\(hiddenRows.count) rows")
        _ = c.validateMenuItem(item)
        check(item.state == .off, "the menu item's checkmark then comes off")
        c.toggleEnvValues(nil)
        check(editor.drawnText(line: 1) == hidden[1], "choosing it again hides them again", editor.drawnText(line: 1))

        // Copy takes the real text.
        let clipboard = NSPasteboard.general.string(forType: .string)
        view.setSelectedRange(value)
        view.copy(nil)
        check(NSPasteboard.general.string(forType: .string) == "sk-live-0123456789" && editor.drawnText(line: 1) == hidden[1],
              "copying a hidden value copies the value; a selection shows nothing")
        NSPasteboard.general.clearContents()
        if let clipboard { NSPasteboard.general.setString(clipboard, forType: .string) }

        // Typing on a line shows that line's value, and only that line's, while the window has the keyboard.
        func press(_ characters: String, keyCode: UInt16) {
            let time = ProcessInfo.processInfo.systemUptime
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: time,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }
            view.keyDown(with: event)
        }
        window.makeKeyAndOrderFront(nil)
        let keyed = window.isKeyWindow
        if !keyed { note("the window does not have the keyboard (app not frontmost?): the lines typed in are only checked to stay hidden") }
        view.setSelectedRange(NSRange(location: lineEnd, length: 0))
        press("9", keyCode: 25)
        check(view.caretPlacedByUser, "a key in the editor counts as typing there")
        if doc.text == original {
            note("the synthetic key typed nothing (app not frontmost?); typing it through insertText")
            view.insertText("9", replacementRange: view.selectedRange())
        }
        let typed = editor.drawnText(line: 1)
        if keyed {
            check(typed == lines[1] + "9" && editor.drawnText(line: 2) == hidden[2],
                  "the line you type in shows its value; the others stay hidden", "\(typed) | \(editor.drawnText(line: 2))")
            _ = await wait(2) { doc.highlighter?.pendingLines == 0 } // the typed line coloured again
            check(pixels(value).image == shownValue.image, "and it is drawn as plain text")
        } else {
            check(typed == hidden[1] + "9", "a window without the keyboard shows no value, even on the line typed in", typed)
        }
        doc.undoManager.undo()
        check(doc.text == original, "undo works on the real text")

        // A private key: only the caret's line of it shows.
        let left = "\u{F702}" // NSLeftArrowFunctionKey
        func pemLines() -> [String] { (5...7).map { editor.drawnText(line: $0) } }
        let pemHidden = Array(hidden[5...7])
        var pemShown = pemHidden
        pemShown[1] = lines[6]
        view.setSelectedRange(NSRange(location: NSMaxRange(text.range(of: "MIIabc")), length: 0))
        press(left, keyCode: 123)
        if keyed {
            check(pemLines() == pemShown, "on one line of a value over several lines, only that line shows", pemLines().joined(separator: " | "))
        }
        window.makeFirstResponder(nil)
        check(pemLines() == pemHidden, "when the editor loses the keyboard, that line hides again", pemLines().joined(separator: " | "))
        window.makeFirstResponder(view)
        check(pemLines() == pemHidden, "and stays hidden when it comes back, until you click or type")
        if keyed {
            press(left, keyCode: 123)
            let before = pemLines()
            // What a switch to another app, such as a screen-share app, does to the window.
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            _ = await wait(1) { !view.caretPlacedByUser }
            let after = pemLines()
            check(before == pemShown && after == pemHidden && !view.caretPlacedByUser,
                  "when the window loses the keyboard (another app, such as a screen share), that line hides too", "\(before) then \(after)")
        }

        // The setting off shows every value.
        app.hidesEnvValues = false
        let plain = lines.indices.map { editor.drawnText(line: $0) }
        check(plain == lines, "turning the setting off shows every value", plain.joined(separator: " | "))
        if doc.isDirty { doc.reload() }
        c.editorArea.close(editor)

        // A .env that links to a file elsewhere is a .env file by the name it was opened by, and the
        // editor link shares nothing from it.
        app.hidesEnvValues = true
        let target = folder.appendingPathComponent("shared/app-secrets"), link = folder.appendingPathComponent("linked/.env")
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "DB_PASSWORD=hunter2\n".write(to: target, atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        c.openFile(link)
        if let linked = c.editorArea.activeEditor, linked.document.name == "app-secrets" {
            linked.textView.setSelectedRange(NSRange(location: 0, length: 11))
            let linkedHidden = "DB_PASSWORD=" + bullets(7)
            check(linked.isEnvFile && linked.drawnText(line: 0) == linkedHidden, "a .env that links to another file hides its values",
                  linked.drawnText(line: 0))
            let gemini = c.openFilesForGemini().contains { ($0["path"] as? String) == linked.document.path }
            check(c.currentSelectionForClaude()["filePath"] == nil && !gemini, "and the editor link shares nothing from it")
            c.editorArea.close(linked)
        } else {
            check(false, "a .env that links to another file opens", c.editorArea.activeEditor?.document.name ?? "nothing")
        }

        // A file that is not a .env file has nothing to hide.
        c.openFile(proj.appendingPathComponent("src/app.txt"))
        if let other = c.editorArea.activeEditor, other.document.name == "app.txt" {
            check(!c.validateMenuItem(item), "the menu item is off for files that are not .env files")
            c.editorArea.close(other)
        }
    }

    /// The branch popup: actions, branches in folders, agents' branches together, search; checkout that
    /// keeps uncommitted changes (stash, switch, reapply), new branch, delete with Undo, commit.
    private static func branchChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let git = GitRunner.locateGit(), let window = c.window else { return }
        @discardableResult func run(_ args: String...) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", proj.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// Presses a button in the sheet over the window (an alert from a git action).
        func press(_ title: String, within seconds: Double = 5) async -> Bool {
            func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
            guard await wait(seconds, { window.attachedSheet.flatMap { $0.contentView.map(buttons) }?.contains { $0.title == title } == true }),
                  let button = window.attachedSheet?.contentView.map(buttons)?.first(where: { $0.title == title }) else { return false }
            button.performClick(nil)
            return true
        }
        /// The text of the sheet over the window: an alert's title and message.
        func sheetText() -> String {
            func fields(_ view: NSView) -> [NSTextField] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields($0) } }
            return window.attachedSheet?.contentView.map(fields)?.map(\.stringValue).joined(separator: "\n") ?? ""
        }
        let start = run("rev-parse", "--abbrev-ref", "HEAD")
        let conf = proj.appendingPathComponent("conf.txt")
        try? "1\n2\n3\n4\nmain\n".write(to: conf, atomically: true, encoding: .utf8)
        run("add", "conf.txt")
        run("commit", "-qm", "conf")
        for name in ["feat/a", "fix/b", "claude/try"] { run("branch", name) }
        run("switch", "-q", "fix/b")
        try? "1\n2\n3\n4\nfix\n".write(to: conf, atomically: true, encoding: .utf8)
        run("commit", "-qam", "fix conf")
        run("switch", "-q", start)
        c.sidebar.git.refresh()
        _ = await wait(5) { c.sidebar.git.snapshot?.branch == start }

        // The popup: actions first, branches in folders, agents' branches in their own folder.
        c.showBranches(nil)
        let popup = c.branchPopup
        // Until the read it starts is in, it says so, rather than list what an earlier check read here
        // (without the branches made since). Under load that read can take seconds.
        check(popup.isReading && popup.rowTitles == ["note Reading branches…"], "the branch popup says “Reading branches…” until its read is in",
              popup.rowTitles.joined(separator: " | "))
        check(await wait(20) { popup.isVisible && !popup.isReading && popup.model?.current == start && popup.model?.local("claude/try") != nil },
              "⌥⌘B opens the branch popup", popup.rowTitles.joined(separator: " | "))
        let rows = popup.rowTitles
        check(["Update Project", "Commit…", "Push…", "New Branch…", "Checkout Tag or Revision…"].allSatisfy(rows.contains),
              "it starts with the git actions", rows.prefix(6).joined(separator: " | "))
        check(rows.contains("▸ feat/ 1") && rows.contains("▸ fix/ 1") && rows.contains("▸ Agent branches 1") && rows.contains("✓ \(start)"),
              "branches sit in folders by prefix, agents' branches together, the current one first", rows.joined(separator: " | "))
        // Row tooltips come from the popup, for rows in view only, as in the sidebar: none on the row views.
        let list = popup.tableView
        list.layoutSubtreeIfNeeded()
        if let row = rows.firstIndex(of: "✓ \(start)"), popup.rowToolTips != nil {
            let rect = list.rect(ofRow: row)
            let tip = RowToolTips.toolTip(for: list, at: NSPoint(x: rect.midX, y: rect.midY))
            let outside = RowToolTips.toolTip(for: list, at: NSPoint(x: rect.midX, y: list.visibleRect.minY - 10))
            let own = (0..<list.numberOfRows).compactMap { list.view(atColumn: 0, row: $0, makeIfNecessary: false)?.toolTip }
            check(tip.hasPrefix(start) && outside.isEmpty && own.isEmpty, "the popup's row tooltips are the popup's, for rows in view only",
                  "\(tip.debugDescription), outside \(outside.debugDescription), on rows \(own)")
        } else {
            check(false, "the popup's row tooltips: row ✓ \(start) not listed, or no tooltip area",
                  "tooltip area \(popup.rowToolTips != nil): " + rows.joined(separator: " | "))
        }
        popup.toggleFolder("local:fix")
        check(popup.rowTitles.contains("b"), "a folder opens to its branches", popup.rowTitles.joined(separator: " | "))
        await screenshot(popup.panelWindow, suffix: "branches")
        popup.query = "fxb"
        check(popup.rowTitles.contains("fix/b") && popup.rowTitles.first(where: { !$0.hasPrefix("#") }) != nil, "search finds a branch by a few letters",
              popup.rowTitles.joined(separator: " | "))
        popup.query = "new idea"
        check(popup.rowTitles.contains("new new-idea"), "and offers a new branch named from what was typed", popup.rowTitles.joined(separator: " | "))
        popup.close()

        // Checkout with an uncommitted change git would overwrite: stash, switch, put it back.
        try? "one\n2\n3\n4\nmain\n".write(to: conf, atomically: true, encoding: .utf8)
        let actions = GitActions(popup)
        guard let fix = popup.model?.local("fix/b") else { return check(false, "fix/b is listed") }
        actions.checkout(fix)
        _ = await press("Switch Anyway", within: 1) // an agent tab from an earlier check may still be open here
        check(await press("Stash, Switch and Reapply"), "checkout over changes git would overwrite offers to stash and reapply them")
        check(await wait(10) { run("rev-parse", "--abbrev-ref", "HEAD") == "fix/b" }, "and switches", run("rev-parse", "--abbrev-ref", "HEAD"))
        let after = (try? String(contentsOf: conf, encoding: .utf8)) ?? ""
        check(await wait(8) { ((try? String(contentsOf: conf, encoding: .utf8)) ?? "") == "one\n2\n3\n4\nfix\n" && !run("stash", "list").contains("Next Term: switching") },
              "with the change put back, and the stash gone", after.debugDescription + " | " + run("stash", "list"))
        check(GitCommandLog.shared.entries.contains { $0.command.hasPrefix("git stash push --include-untracked") } && GitCommandLog.shared.entries.contains { $0.command == "git switch fix/b" },
              "every command is in Git Commands as it would be typed")
        run("checkout", "-q", "--", "conf.txt")

        // New branch from here; delete with Undo.
        actions.createBranch("feat/new-idea", base: nil, switching: true)
        check(await wait(5) { run("rev-parse", "--abbrev-ref", "HEAD") == "feat/new-idea" }, "New Branch creates it and switches to it")
        await pause(0.5)
        if let a = popup.model?.local("feat/a") {
            actions.delete(a)
            check(await wait(5) { run("branch", "--list", "feat/a").isEmpty && GitToast.text?.hasPrefix("Deleted feat/a (was ") == true },
                  "Delete removes a merged branch and says what it was", GitToast.text ?? "no notice")
            GitToast.pressButtonForTest()
            check(await wait(5) { !run("branch", "--list", "feat/a").isEmpty }, "and Undo brings it back")
        }

        // Commit through the sheet.
        try? "one\n2\n3\n4\nfix\n".write(to: conf, atomically: true, encoding: .utf8)
        c.sidebar.git.refresh()
        _ = await wait(5) { c.sidebar.git.snapshot?.files["conf.txt"] != nil }
        actions.commit()
        check(await wait(5) { CommitSheet.current != nil }, "Commit… opens the commit sheet")
        if let sheet = CommitSheet.current {
            check(sheet.fileListText.contains("conf.txt"), "it lists what will be committed", sheet.fileListText)
            sheet.type("Change the first line")
            sheet.pressCommit()
            check(await wait(8) { run("log", "-1", "--format=%s") == "Change the first line" }, "and commits it", run("log", "-1", "--format=%s"))
        }

        // Undo on the commit's notice takes back that commit only: not one made after it, and after Amend
        // only the amend.
        check(await wait(5) { GitToast.text?.hasPrefix("Committed ") == true }, "the commit's notice comes up", GitToast.text ?? "no notice")
        let committed = run("rev-parse", "HEAD")
        run("commit", "--allow-empty", "-qm", "an agent's commit")
        GitToast.pressButtonForTest()
        let moved = await wait(5) { sheetText().contains("HEAD has moved since this commit") }
        check(moved, "its Undo after a newer commit says HEAD has moved", sheetText())
        _ = await press("OK")
        check(run("log", "-2", "--format=%s") == "an agent's commit\nChange the first line", "and takes back neither commit", run("log", "-2", "--format=%s"))
        run("reset", "-q", "--soft", committed)
        GitToast.dismiss()
        actions.commit()
        if await wait(5, { CommitSheet.current != nil }), let sheet = CommitSheet.current {
            sheet.setAmend(true)
            sheet.type("Change the first line again")
            sheet.pressCommit()
            check(await wait(8) { run("log", "-1", "--format=%s") == "Change the first line again" && GitToast.text?.hasPrefix("Committed ") == true },
                  "Amend replaces the last commit, with a notice", run("log", "-2", "--format=%s"))
            GitToast.pressButtonForTest()
            check(await wait(8) { run("rev-parse", "HEAD") == committed }, "and its Undo puts back the commit it replaced, not that one's parent",
                  run("log", "-2", "--format=%s"))
        }

        // Force push, after a rejected push: it lists what it would discard and replaces exactly that, and
        // it is refused for the branch the remote's HEAD names.
        let bare = proj.deletingLastPathComponent().appendingPathComponent("force-remote.git")
        let theirs = proj.deletingLastPathComponent().appendingPathComponent("force-theirs")
        run("init", "-q", "--bare", bare.path)
        run("switch", "-q", "-c", "feat/force")
        run("remote", "add", "st", bare.path)
        run("push", "-q", "-u", "st", "feat/force")
        run("clone", "-q", "-b", "feat/force", bare.path, theirs.path)
        func diverge(_ n: Int) {
            run("-C", theirs.path, "fetch", "-q", "origin")
            run("-C", theirs.path, "reset", "-q", "--hard", "origin/feat/force")
            run("-C", theirs.path, "commit", "--allow-empty", "-qm", "theirs \(n)")
            run("-C", theirs.path, "push", "-q", "origin", "feat/force")
            run("fetch", "-q", "st")
            run("commit", "--allow-empty", "-qm", "mine \(n)")
        }
        diverge(1)
        popup.reload()
        _ = await wait(5) { popup.model?.currentRef?.upstream == "st/feat/force" }
        GitToast.dismiss()
        actions.push()
        let pushed = await press("Push")
        let offered = await press("Force Push…")
        check(pushed && offered, "a rejected push offers Force Push…", sheetText())
        let listed = await wait(5) { sheetText().contains("theirs 1") }
        check(listed, "Force Push… lists the commits it would discard", sheetText())
        _ = await press("Force Push")
        check(await wait(10) { run("-C", bare.path, "rev-parse", "feat/force") == run("rev-parse", "HEAD") },
              "and replaces them with yours", GitToast.text ?? "no notice")
        run("remote", "set-head", "st", "feat/force")
        diverge(2)
        popup.reload()
        _ = await wait(5) { popup.model?.remoteHeads["st"] == "feat/force" }
        actions.push()
        let pushedAgain = await press("Push")
        let offeredAgain = await press("Force Push…")
        let refused = await wait(5) { sheetText().contains("Force push to feat/force is off") }
        check(pushedAgain && offeredAgain && refused, "force push is refused for the branch the remote's HEAD names", sheetText())
        _ = await press("OK")
        check(run("-C", bare.path, "log", "-1", "--format=%s", "feat/force") == "theirs 2", "and the remote keeps its commits")
        run("switch", "-q", start)
        run("branch", "-D", "feat/force")
        run("remote", "remove", "st")
        try? FileManager.default.removeItem(at: bare)
        try? FileManager.default.removeItem(at: theirs)

        // Back as it was.
        GitToast.dismiss()
        run("switch", "-q", start)
        for name in ["feat/a", "fix/b", "claude/try", "feat/new-idea"] { run("branch", "-D", name) }
        run("rm", "-q", "conf.txt")
        run("commit", "-qm", "branch checks done")
        c.sidebar.git.refresh()
    }

    /// The Git Log: commits newest first with graph lanes, filters by author and text, a commit's changed
    /// files, a file's diff in that commit, showCommit selecting a commit, one branch's history, and the
    /// way in from the branch popup and the Git menu.
    private static func gitLogChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let git = GitRunner.locateGit() else { return }
        @discardableResult func run(_ args: [String], author: String = "T") -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", proj.path, "-c", "user.name=\(author)", "-c", "user.email=\(author.lowercased().replacingOccurrences(of: " ", with: "."))@t",
                           "-c", "commit.gpgsign=false"] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let menu = items(NSApp.mainMenu ?? NSMenu())
        let logItem = menu.first { $0.action == #selector(TerminalWindowController.showGitLog(_:)) }
        check(logItem?.title == "Git Log" && logItem?.keyEquivalent == "l" && logItem?.keyEquivalentModifierMask == [.command, .option]
              && menu.contains { $0.title == "Git Commands" && $0.action == #selector(TerminalWindowController.showGitCommands(_:)) },
              "Git › Git Log is ⌥⌘L, and the commands Next Term ran are Git › Git Commands", logItem?.title ?? "no Git Log item")

        // A side branch with a commit by someone else, merged back: two lanes and a merge.
        let start = run(["rev-parse", "--abbrev-ref", "HEAD"])
        run(["switch", "-qc", "log/side"])
        try? "side\n".write(to: proj.appendingPathComponent("log-side.txt"), atomically: true, encoding: .utf8)
        run(["add", "log-side.txt"])
        run(["commit", "-qm", "Side work for the log"], author: "Ann Log")
        let side = run(["rev-parse", "HEAD"])
        run(["switch", "-q", start])
        try? "main\n".write(to: proj.appendingPathComponent("log-main.txt"), atomically: true, encoding: .utf8)
        run(["add", "log-main.txt"])
        run(["commit", "-qm", "Main work for the log"])
        run(["merge", "-q", "--no-ff", "--no-edit", "log/side"])
        let merge = run(["rev-parse", "HEAD"])
        c.sidebar.git.refresh()
        _ = await wait(5) { c.sidebar.git.snapshot?.head.map { merge.hasPrefix($0) } == true }

        c.showGitLog(nil)
        guard let log = c.editorArea.activeGitLog else { return check(false, "⌥⌘L opens the Git Log in an editor tab") }
        check(log.title == "Git Log" && canonicalPath(log.root) == canonicalPath(proj.path), "⌥⌘L opens the Git Log of the project in an editor tab")
        check(await wait(10) { !log.isLoading && log.commits.count >= 4 }, "it lists the commits", "\(log.commits.count) commits, \(log.failure ?? "")")
        check(log.commits.first?.sha == merge && log.rows.first?.isMerge == true, "newest first, the merge marked as one",
              log.commits.prefix(3).map(\.subject).joined(separator: " | "))
        check((log.rows.map(\.width).max() ?? 0) >= 2 && log.rows.count == log.commits.count, "the graph gives the side branch a lane of its own",
              log.rows.prefix(4).map { "\($0.column)/\($0.width)" }.joined(separator: " "))
        log.table.layoutSubtreeIfNeeded()
        let graphCell = log.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? GitGraphView
        let subjectCell = log.table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? GitSubjectView
        check(graphCell?.row?.isMerge == true && subjectCell?.accessibilityLabel()?.contains(start) == true,
              "rows draw the graph, and the subject with its branch badge", subjectCell?.accessibilityLabel() ?? "no subject cell")
        await screenshot(c, suffix: "git-log")

        // Filters.
        log.apply { $0.author = "ann log" }
        check(await wait(8) { !log.isLoading && log.commits.map(\.sha) == [side] }, "the author filter finds the side commit (ignoring case)",
              log.commits.map(\.subject).joined(separator: " | "))
        log.apply { $0.author = ""; $0.text = "MAIN WORK" }
        check(await wait(8) { !log.isLoading && log.commits.map(\.subject) == ["Main work for the log"] }, "the text filter searches messages, ignoring case",
              log.commits.map(\.subject).joined(separator: " | "))
        // Match case, beside .*: the text only as typed.
        log.apply { $0.matchCase = true }
        check(await wait(8) { !log.isLoading && log.commits.isEmpty && log.matchCaseToggle.state == .on }, "with Match case on, the text is found only as typed",
              log.commits.map(\.subject).joined(separator: " | "))
        log.apply { $0.text = "Main work" }
        check(await wait(8) { !log.isLoading && log.commits.map(\.subject) == ["Main work for the log"] }, "and in that case it is found",
              log.commits.map(\.subject).joined(separator: " | "))
        log.apply { $0.matchCase = false }
        check(log.matchCaseToggle.state == .off, "and the toggle goes off with it")
        log.apply { $0.text = String(side.prefix(8)) }
        check(await wait(8) { !log.isLoading && log.commits.map(\.sha) == [side] }, "a hash prefix finds its commit")
        log.apply { $0.text = "fix("; $0.regex = true }
        check(await wait(5) { log.failure?.hasPrefix("This is not a valid regular expression") == true },
              "a pattern with a typo says so, rather than that git failed", log.failure ?? "no message")
        log.apply { $0.text = ""; $0.regex = false }
        _ = await wait(8) { !log.isLoading && log.commits.count >= 4 }

        // Details, and a changed file's diff in that commit.
        log.select(sha: side)
        check(await wait(5) { log.selectedCommit?.sha == side }, "a commit can be selected")
        check(await wait(8) { log.details.fileNames == ["log-side.txt"] }, "the details list its changed files", log.details.fileNames.joined(separator: ", "))
        check(log.details.text.contains("Ann Log") && log.details.text.contains(side) && log.details.text.contains("Side work for the log"),
              "and show its message, author and full hash", log.details.text)
        log.details.openFile(at: 0)
        let diffTitle = "log-side.txt @ " + side.prefix(7)
        check(await wait(8) { c.editorArea.activeDiff?.title == diffTitle && (c.editorArea.activeDiff?.changedLineCount ?? 0) > 0 },
              "a changed file opens as its diff in that commit", c.editorArea.activeDiff?.title ?? "no diff in front")
        let commitNote = c.editorArea.activeDiff?.contextItem()?.note
        check(commitNote == "as of commit " + side.prefix(7), "Send to Agent from it names the commit", commitNote ?? "no note")
        if let diff = c.editorArea.activeDiff { c.editorArea.close(diff) }

        // showCommit, with a filter that hides the commit: the filter goes, the commit is selected.
        log.apply { $0.text = "nothing in this repository says this" }
        _ = await wait(8) { !log.isLoading }
        log.table.deselectAll(nil)
        c.showCommit(sha: side, root: proj.appendingPathComponent("src").path)
        check(await wait(10) { c.editorArea.activeGitLog === log && log.selectedCommit?.sha == side && log.query.text.isEmpty },
              "showCommit opens the log at that commit", log.selectedCommit?.subject ?? "nothing selected")

        // One branch's history, from the tree or the branch popup.
        log.show(ref: "refs/heads/log/side")
        check(await wait(8) { !log.isLoading && log.commits.first?.sha == side && !log.commits.contains { $0.sha == merge } },
              "one branch shows its own history", log.commits.map(\.subject).joined(separator: " | "))
        check(await wait(5) { log.refs.rowTitles.contains { $0.trimmingCharacters(in: .whitespaces) == "side" } }, "the branch tree lists branches in folders",
              log.refs.rowTitles.joined(separator: " | "))
        // Selecting a branch in the tree shows its history.
        log.show(ref: nil)
        _ = await wait(8) { !log.isLoading && log.query.scope == .all && log.commits.first?.sha == merge }
        if let row = log.refs.rowTitles.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "side" }) {
            log.refs.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        check(await wait(8) { log.query.scope == .ref("refs/heads/log/side") && !log.isLoading && log.commits.first?.sha == side },
              "selecting a branch in the tree shows its history", "\(log.query.scope), " + log.refs.rowTitles.joined(separator: " | "))
        // Its rows' tooltips come from the tree, for rows in view only, as in the sidebar: none on the row views.
        let tree = log.refs.outline
        tree.layoutSubtreeIfNeeded()
        if let row = log.refs.rowTitles.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "side" }), log.refs.rowToolTips != nil {
            let rect = tree.rect(ofRow: row)
            let tip = RowToolTips.toolTip(for: tree, at: NSPoint(x: rect.midX, y: rect.midY))
            let outside = RowToolTips.toolTip(for: tree, at: NSPoint(x: rect.midX, y: tree.visibleRect.minY - 10))
            let own = (0..<tree.numberOfRows).compactMap { tree.view(atColumn: 0, row: $0, makeIfNecessary: false)?.toolTip }
            check(tip == "refs/heads/log/side" && outside.isEmpty && own.isEmpty, "the branch tree's tooltips are the tree's, for rows in view only",
                  "\(tip.debugDescription), outside \(outside.debugDescription), on rows \(own)")
        } else {
            check(false, "the branch tree's tooltips: row side not listed, or no tooltip area",
                  "tooltip area \(log.refs.rowToolTips != nil): " + log.refs.rowTitles.joined(separator: " | "))
        }
        c.showBranches(nil)
        check(await wait(15) { c.branchPopup.isVisible && c.branchPopup.rowTitles.contains("Git Log") }, "the branch popup has a Git Log row",
              c.branchPopup.rowTitles.prefix(8).joined(separator: " | "))
        c.branchPopup.close()

        // Back as it was.
        c.editorArea.close(log)
        run(["branch", "-D", "log/side"])
        run(["rm", "-q", "log-side.txt", "log-main.txt"])
        run(["commit", "-qm", "git log checks done"])
        c.sidebar.git.refresh()
    }

    /// The Git Log of a history longer than a page, in a repository of its own: the second page, with
    /// the graph's line going on into it; a commit's menu with a remote branch and origin/HEAD; a new
    /// commit refreshing the log in place; and showCommit of a commit no branch lists.
    private static func gitLogPagingChecks(_ c: TerminalWindowController) async {
        guard let git = GitRunner.locateGit() else { return }
        let repo = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-selftest-log-\(getpid())")
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        @discardableResult func run(_ args: [String], input: URL? = nil) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = input.flatMap { try? FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        run(["init", "-q"])
        // 1,050 commits in one line of history, made at once, and a remote branch with its HEAD.
        var stream = ""
        for i in 1...1050 {
            let message = "Commit \(i)\n"
            stream += "commit refs/heads/main\nmark :\(i)\ncommitter T <t@t> \(1_700_000_000 + i * 60) +0000\ndata \(message.utf8.count)\n\(message)"
            stream += (i > 1 ? "from :\(i - 1)\n" : "") + "\n"
        }
        let streamFile = repo.appendingPathComponent(".git/nt-import")
        try? stream.write(to: streamFile, atomically: true, encoding: .utf8)
        run(["fast-import", "--quiet"], input: streamFile)
        try? FileManager.default.removeItem(at: streamFile)
        run(["update-ref", "refs/remotes/origin/main", "main"])
        run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])

        guard let log = c.openGitLog(root: repo.path) else { return check(false, "the Git Log opens on a history of 1,050 commits") }
        check(await wait(10) { !log.isLoading && log.commits.count == 1000 && log.order?.count == 1050 },
              "a long history lists its first 1,000 commits, of the 1,050 in its order", "\(log.commits.count) of \(log.order?.count ?? 0) \(log.failure ?? "")")

        // Scrolling near the end loads the next page, and the line goes on across the seam.
        log.table.scrollRowToVisible(990)
        log.table.displayIfNeeded()
        check(await wait(10) { log.isComplete && log.commits.count == 1050 && log.rows.count == 1050 }, "scrolling near the end loads the next page",
              "\(log.commits.count) commits, \(log.rows.count) rows")
        let seam = log.rows.count == 1050 && log.rows[999].bottom.count == 1 && log.rows[1000].top.count == 1
        let ends = log.commits.first?.subject == "Commit 1050" && log.commits.last?.subject == "Commit 1" && log.rows.last?.bottom.isEmpty == true
        check(seam && ends && log.rows.allSatisfy { $0.column == 0 }, "the graph's line goes on from the first page into the second",
              log.rows.dropFirst(998).prefix(3).map { "\($0.top.count)/\($0.bottom.count)" }.joined(separator: " "))

        // The menu of the commit at the top: its remote branch to check out, and not origin/HEAD.
        let menu = NSMenu()
        log.fill(menu, for: log.commits[0])
        let titles = menu.items.map(\.title)
        check(titles.contains("Copy Hash") && titles.contains("Checkout “origin/main”") && titles.contains("Checkout…") && !titles.contains { $0.contains("origin/HEAD") },
              "a commit's menu offers its remote branch, and not origin/HEAD", titles.joined(separator: " | "))

        // A new commit refreshes the log in place: the same commit selected, far down, and the same one at the top of the view.
        log.table.selectRowIndexes(IndexSet(integer: 600), byExtendingSelection: false)
        log.table.scrollRowToVisible(580)
        log.table.displayIfNeeded()
        let selected = log.selectedCommit?.sha
        let top = log.commits[safe: log.table.rows(in: log.table.visibleRect).location]?.sha
        run(["commit", "--allow-empty", "-qm", "refreshed"])
        check(await wait(10) { log.commits.first?.subject == "refreshed" && !log.isLoading }, "a new commit shows in the log without a click",
              log.commits.first?.subject ?? "nothing listed")
        check(selected != nil && log.selectedCommit?.sha == selected && log.commits.count == 1051, "the refresh keeps the commit selected 600 rows down",
              "\(log.selectedCommit?.subject ?? "nothing selected"), \(log.commits.count) commits")
        let nowTop = log.commits[safe: log.table.rows(in: log.table.visibleRect).location]?.sha
        check(top != nil && nowTop == top, "and keeps the same commit at the top of the view",
              "\(log.commits.first { $0.sha == top }?.subject ?? "-") then \(log.commits.first { $0.sha == nowTop }?.subject ?? "-")")

        // A commit no branch or tag lists: shown alone, and selected; Aa and .* go off, as its query has them.
        log.apply { $0.matchCase = true; $0.regex = true }
        _ = await wait(8) { !log.isLoading }
        let orphan = run(["commit-tree", "HEAD^{tree}", "-m", "orphan"])
        c.showCommit(sha: orphan, root: repo.path)
        check(await wait(10) { log.commits.map(\.sha) == [orphan] && log.selectedCommit?.sha == orphan && log.query.text == orphan },
              "showCommit of a commit no branch lists shows it alone", log.commits.prefix(3).map(\.subject).joined(separator: " | "))
        check(log.matchCaseToggle.state == .off && log.regexToggle.state == .off && !log.query.matchCase && !log.query.regex,
              "and Aa and .* are off, as the query that shows it has them", "Aa \(log.matchCaseToggle.state.rawValue), .* \(log.regexToggle.state.rawValue)")
        c.editorArea.close(log)
    }

    /// Compare with Current and Show Diff with Working Tree, in a repository of their own with two branches
    /// that parted: one commit cherry-picked across, a rename, a branch at the same commit. From a branch's
    /// menu in the popup (local and remote), the commits both ways with the cherry-pick marked, the files,
    /// a file's diff, a commit in the Git Log, the files on disk against the branch, the plain empty
    /// states, and both tabs following the repository.
    private static func branchCompareChecks(_ c: TerminalWindowController) async {
        guard let git = GitRunner.locateGit() else { return }
        let repo = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-selftest-compare-\(getpid())")
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        @discardableResult func run(_ args: String...) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ name: String, _ text: String) { try? text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        run("init", "-q")
        write("a.txt", "1\n2\n3\n")
        write("old.txt", "x\ny\nz\n")
        run("add", "-A")
        run("commit", "-qm", "Base")
        let base = run("rev-parse", "HEAD")
        run("switch", "-qc", "feat")
        write("f.txt", "feat\n")
        run("add", "f.txt")
        run("commit", "-qm", "Feat only")
        write("a.txt", "1\n2\n3\nfix\n")
        run("commit", "-qam", "The fix")
        let fix = run("rev-parse", "HEAD")
        run("mv", "old.txt", "new.txt")
        run("commit", "-qm", "Rename")
        run("switch", "-q", "main")
        write("m.txt", "main\n")
        run("add", "m.txt")
        run("commit", "-qm", "Main only")
        run("cherry-pick", fix)
        run("branch", "same")
        run("update-ref", "refs/remotes/origin/feat", "feat")

        // The menu of a branch, and of a remote one, in the popup.
        c.showBranches(at: repo.path, query: "feat")
        let popup = c.branchPopup
        func row(_ name: String, remote: Bool) -> Int? {
            popup.items.firstIndex { item in
                if case let .branch(ref, _, _, _) = item { return ref.name == name && ref.isRemote == remote }
                return false
            }
        }
        check(await wait(15) { popup.model.map { canonicalPath($0.root) == canonicalPath(repo.path) } == true && row("feat", remote: false) != nil },
              "the branch popup opens on the comparison's repository", popup.rowTitles.joined(separator: " | "))
        let localRow = row("feat", remote: false)
        let local: [NSMenuItem] = localRow.flatMap { popup.menu(forRow: $0) }?.items ?? []
        let remote: [NSMenuItem] = row("origin/feat", remote: true).flatMap { popup.menu(forRow: $0) }?.items ?? []
        let wanted = ["Compare with “main”", "Show Diff with Working Tree"]
        let inLocal = wanted.allSatisfy { title in local.contains { $0.title == title && $0.isEnabled } }
        let inRemote = wanted.allSatisfy { title in remote.contains { $0.title == title && $0.isEnabled } }
        let menus = local.map(\.title).joined(separator: " | ") + " / " + remote.map(\.title).joined(separator: " | ")
        check(inLocal && inRemote, "a branch's menu, local or remote, has Compare with “main” and Show Diff with Working Tree", menus)
        // A right-click on feat's row: the table finds the row under the click, and the menu fills in as it
        // opens, the same as →.
        var rightClicked: [String] = []
        if let localRow {
            let table = popup.tableView
            let rect = table.rect(ofRow: localRow)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                           windowNumber: popup.panelWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            if let event, let menu = table.menu(for: event) {
                popup.menuNeedsUpdate(menu)
                rightClicked = menu.items.map(\.title)
            }
        }
        let clickedRow = popup.tableView.clickedRow
        check(!rightClicked.isEmpty && rightClicked == local.map(\.title), "a right-click on a branch shows its menu",
              rightClicked.joined(separator: " | ") + " (clicked row \(clickedRow), feat's \(localRow ?? -1))")
        guard let compareItem = local.first(where: { $0.title == wanted[0] }), let diskItem = local.first(where: { $0.title == wanted[1] }) else { return popup.close() }
        (compareItem.target as? MenuBlock)?.run(nil)
        check(!popup.isVisible, "choosing it closes the popup")

        // Compare: the commits only on each side, newest first, the cherry-pick marked, then the files.
        guard let compare = c.editorArea.activeComparison else { return check(false, "Compare with Current opens an editor tab") }
        // What a tab lists, and why it couldn't, for the failure messages; a diff's two sides.
        func listed(_ pane: BranchComparePane) -> String {
            let why = pane.failure.map { " — " + $0 } ?? ""
            return pane.rowTitles.joined(separator: " | ") + why
        }
        func sides(_ diff: DiffPane?) -> String {
            guard let diff else { return "no diff in front" }
            return diff.sideTexts.0 + " | " + diff.sideTexts.1
        }
        let expected = [
            "# Only on feat · 3 commits, 1 also on main", "Rename", "= The fix", "Feat only",
            "# Only on main · 2 commits, 1 also on feat", "= The fix", "Main only",
            "# Files changed on feat · 3 files, since \(base.prefix(7))", "M a.txt", "A f.txt", "R new.txt ← old.txt",
        ]
        check(await wait(10) { !compare.isLoading && compare.rowTitles == expected }, "Compare lists the commits only on each side, the cherry-pick marked “=”, then the files",
              listed(compare))
        check(compare.title == "feat ↔ main" && compare.mode == .compare, "the tab is titled with both branches", compare.title)
        await screenshot(c, suffix: "branch-compare")
        if let index = compare.rowTitles.firstIndex(of: "M a.txt") {
            compare.open(row: index)
            let diff = c.editorArea.activeDiff
            check(await wait(8) { diff?.title == "a.txt @ feat" && (diff?.changedLineCount ?? 0) > 0 },
                  "a file opens as the branch's change to it, side by side", diff?.title ?? "no diff in front")
            let shared = diff?.sideTexts.0 ?? "", onBranch = diff?.sideTexts.1 ?? ""
            check(!shared.contains("fix") && onBranch.contains("fix"), "the commit they share on the left, the branch on the right", sides(diff))
            if let diff { c.editorArea.close(diff) }
        }
        if let index = compare.rowTitles.firstIndex(of: "Feat only") {
            compare.open(row: index)
            let wantedSHA = run("rev-parse", "feat~2")
            check(await wait(10) { c.editorArea.activeGitLog?.selectedCommit?.sha == wantedSHA }, "a commit opens in the Git Log",
                  c.editorArea.activeGitLog?.selectedCommit?.subject ?? "no commit selected")
            if let log = c.editorArea.activeGitLog { c.editorArea.close(log) }
        }
        // It follows the branch: a commit on feat (made elsewhere) shows without a click.
        let later = run("commit-tree", "feat^{tree}", "-p", "feat", "-m", "Later on feat")
        run("update-ref", "refs/heads/feat", later)
        check(await wait(10) { compare.rowTitles.contains("Later on feat") && compare.rowTitles.first == "# Only on feat · 4 commits, 1 also on main" },
              "the comparison reads again when the branch moves", compare.rowTitles.prefix(3).joined(separator: " | "))
        // A file's diff, opened again after the branch changed the file once more, is read again: the
        // same tab, as the branch has it now.
        if let index = compare.rowTitles.firstIndex(of: "A f.txt") {
            compare.open(row: index)
            let first = c.editorArea.activeDiff
            let opened = await wait(8) { first?.title == "f.txt @ feat" && (first?.sideTexts.1 ?? "").contains("feat") }
            run("switch", "-q", "feat")
            write("f.txt", "feat\nmore on feat\n")
            run("commit", "-qam", "More on feat")
            run("switch", "-q", "main")
            let moved = await wait(10) { compare.rowTitles.contains("More on feat") }
            if let again = compare.rowTitles.firstIndex(of: "A f.txt") { compare.open(row: again) }
            let reread = await wait(8) { c.editorArea.activeDiff === first && (first?.sideTexts.1 ?? "").contains("more on feat") }
            check(opened && moved && reread, "a file opened again after the branch moved shows its change as it is now", sides(c.editorArea.activeDiff))
            if let first { c.editorArea.close(first) }
        }
        c.editorArea.close(compare)

        // From the remote branch's menu: refs/remotes/origin/feat, where feat was, compared with main.
        if let remoteCompare = remote.first(where: { $0.title == wanted[0] }) {
            (remoteCompare.target as? MenuBlock)?.run(nil)
            let fromRemote = c.editorArea.activeComparison
            let read = await wait(10) { fromRemote?.isLoading == false && fromRemote?.rowTitles.first == "# Only on origin/feat · 3 commits, 1 also on main" }
            let said = (fromRemote?.title ?? "no comparison in front") + ": " + (fromRemote.map(listed) ?? "")
            check(read && fromRemote?.title == "origin/feat ↔ main", "Compare from a remote branch's menu compares the remote branch", said)
            if let fromRemote { c.editorArea.close(fromRemote) }
        }

        // The files on disk against the branch: changed, missing, new here, renamed; each opens side by side.
        write("a.txt", "on disk\n")
        (diskItem.target as? MenuBlock)?.run(nil)
        guard let disk = c.editorArea.activeComparison, disk.mode == .workingTree else { return check(false, "Show Diff with Working Tree opens an editor tab") }
        let onDisk = ["# On disk, different from feat · 4 files", "M a.txt", "D f.txt", "A m.txt", "R old.txt ← new.txt"]
        check(await wait(10) { !disk.isLoading && disk.rowTitles == onDisk }, "Show Diff with Working Tree lists the files on disk that differ from the branch",
              listed(disk))
        check(disk.title == "feat ↔ Working Tree", "its tab says so", disk.title)
        if let index = disk.rowTitles.firstIndex(of: "M a.txt") {
            disk.open(row: index)
            let diff = c.editorArea.activeDiff
            let branchLeft = await wait(8) { (diff?.sideTexts.0 ?? "").contains("fix") && (diff?.sideTexts.1 ?? "").contains("on disk") }
            check(branchLeft && diff?.title == "a.txt ↔ feat", "a file opens with the branch's version on the left and the file on disk on the right", sides(diff))
            write("a.txt", "changed again\n")
            check(await wait(8) { diff?.sideTexts.1.contains("changed again") == true }, "and follows the file as it changes", diff?.sideTexts.1 ?? "")
            if let diff { c.editorArea.close(diff) }
        }
        if let index = disk.rowTitles.firstIndex(of: "R old.txt ← new.txt") {
            disk.open(row: index)
            let renamed = c.editorArea.activeDiff
            let matched = await wait(8) { renamed?.messageText == "The file on disk is the same as new.txt on feat." }
            let said = (renamed?.title ?? "no diff") + ": " + (renamed?.messageText ?? "")
            check(matched && renamed?.title == "old.txt ↔ feat", "a file renamed since the branch is compared with its name there", said)
            if let renamed { c.editorArea.close(renamed) }
        }
        // A branch deleted meanwhile (a fetch prunes one): the diff says git can't read it, not that the
        // file is the same as there.
        run("branch", "gone", "feat")
        c.editorArea.openWorkingTreeDiff(root: repo.path, path: "a.txt", branch: "refs/heads/gone", renamedFrom: nil)
        let goneDiff = c.editorArea.activeDiff
        let read = await wait(8) { goneDiff?.title == "a.txt ↔ gone" && (goneDiff?.hunkCount ?? 0) > 0 }
        run("branch", "-D", "gone")
        write("a.txt", "and once more\n")
        let gone = await wait(8) { goneDiff?.messageText == "Git could not read gone: it may have been deleted." }
        check(read && gone, "a diff against a branch deleted since says git can't read it", goneDiff.map { $0.title + ": " + $0.messageText } ?? "no diff in front")
        if let goneDiff { c.editorArea.close(goneDiff) }
        // Put back as main has it: a.txt no longer differs from feat (main has the same fix), and the list follows.
        run("checkout", "-q", "--", "a.txt")
        check(await wait(10) { disk.rowTitles.first == "# On disk, different from feat · 3 files" && !disk.rowTitles.contains("M a.txt") },
              "the list follows the files on disk", disk.rowTitles.joined(separator: " | "))
        // Rewritten with the same text (git lists it until it reads it again), and m.txt gone: only m.txt
        // leaves the list.
        write("a.txt", "1\n2\n3\nfix\n")
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: repo.appendingPathComponent("a.txt").path)
        try? FileManager.default.removeItem(at: repo.appendingPathComponent("m.txt"))
        check(await wait(10) { disk.rowTitles.first == "# On disk, different from feat · 2 files" && !disk.rowTitles.contains("M a.txt") },
              "a file rewritten with the branch's text is not listed", disk.rowTitles.joined(separator: " | "))
        run("checkout", "-q", "--", "m.txt")
        c.editorArea.close(disk)

        // Nothing to show is said plainly.
        let same = c.openBranchComparison(root: repo.path, branch: "refs/heads/same", mode: .compare, current: "main")
        check(await wait(10) { same.messageText == "same and main are at the same commit: there is nothing to compare." }, "a branch at the same commit says so",
              same.messageText + " " + same.rowTitles.joined(separator: " | "))
        c.editorArea.close(same)
        let clean = c.openBranchComparison(root: repo.path, branch: "refs/heads/main", mode: .workingTree, current: "main")
        check(await wait(10) { clean.messageText.hasPrefix("The files on disk are the same as on main.") }, "files on disk that match the branch say so",
              clean.messageText + " " + clean.rowTitles.joined(separator: " | "))
        c.editorArea.close(clean)
    }

    /// Background fetch: a clone of a local bare remote that gets a new commit shows “Pull 1” without a
    /// click, FETCH_HEAD is never written, nothing asks for anything, and Git Commands lists the fetches
    /// only when asked to. Then the branch popup fetches as it opens, and its counts update in place. A
    /// remote that needs a password pauses quietly until a fetch of yours works, and a command of yours
    /// stops a slow fetch.
    private static func backgroundFetchChecks(_ c: TerminalWindowController) async {
        guard let git = GitRunner.locateGit() else { return }
        let base = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-selftest-fetch-\(getpid())")
        let remote = base.appendingPathComponent("remote.git"), work = base.appendingPathComponent("work")
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        @discardableResult func run(_ args: [String], in dir: URL) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", dir.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        run(["init", "-q", "--bare", remote.path], in: base)
        run(["init", "-q"], in: work)
        try? "hello\n".write(to: work.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        run(["add", "README.md"], in: work)
        run(["commit", "-qm", "first"], in: work)
        run(["remote", "add", "origin", remote.path], in: work)
        run(["push", "-q", "-u", "origin", "main"], in: work)
        /// Someone else's commit lands on the remote.
        func theirs(_ message: String) {
            run(["update-ref", "refs/heads/main", run(["commit-tree", "main^{tree}", "-p", "main", "-m", message], in: remote)], in: remote)
        }
        let fetchHead = work.appendingPathComponent(".git/FETCH_HEAD").path

        // A fetch every second, whatever the setting, as if Next Term were in front on an ordinary network.
        let fetcher = BackgroundFetcher.shared
        fetcher.test = (root: work.path, interval: 1, staleAfter: 3600)
        defer { fetcher.test = nil }
        let w = AppDelegate.shared.openWindow(directory: work.path, project: work.path)
        let header = w.sidebar.header
        check(await wait(10) { w.sidebar.git.snapshot?.upstream == "origin/main" }, "a clone of a local remote opens with its upstream",
              w.sidebar.git.snapshot?.upstream ?? "no upstream")
        var appeared = ""
        for _ in 0..<50 {
            if !header.syncText.isEmpty { appeared = header.syncText }
            await pause(0.05)
        }
        check(fetcher.lastFetch(at: work.path) != nil && appeared.isEmpty, "background fetches of a branch that is up to date show no button",
              "last fetch \(String(describing: fetcher.lastFetch(at: work.path))), shown \(appeared.debugDescription)")
        theirs("their change")
        check(await wait(10) { header.syncText == "Pull 1" || header.syncText == "↓1" }, "a commit pushed elsewhere shows “Pull 1” without a click",
              header.syncText.isEmpty ? "no button" : header.syncText)
        check(!FileManager.default.fileExists(atPath: fetchHead), "the background fetch leaves FETCH_HEAD alone (a git pull in a tab reads it)")
        check(header.syncButton.toolTip?.contains("Last fetched") == true, "the button says when Next Term last fetched", header.syncButton.toolTip ?? "")
        let env = GitWriter.backgroundEnvironment
        let refuses = env["GCM_INTERACTIVE"] == "never" && env["GIT_TERMINAL_PROMPT"] == "0" && env["GIT_ASKPASS"] == "/usr/bin/false"
        let asked = w.window?.attachedSheet != nil || NSApp.modalWindow != nil
        check(refuses && !asked, "and nothing asks for a password: no sheet, no prompt", "refuses \(refuses), asked \(asked)")

        // Git Commands: the background fetches only with "Show background fetches" on.
        let log = GitCommandLog.shared
        let shown = log.showBackground
        log.showBackground = false
        let hidden = !log.text.contains("--no-write-fetch-head")
        log.showBackground = true
        let porcelain = FetchSchedule.hasPorcelainFetch(GitWriter.version)
        let command = GitWriter.commandLine(FetchSchedule.arguments(remote: "origin", porcelain: porcelain))
        let listed = log.text.contains(command)
        log.showBackground = shown
        check(hidden && listed, "Git Commands lists background fetches only with “Show background fetches” on", "hidden \(hidden), listed \(listed)")
        // --porcelain only where git knows it (2.41 or later; macOS 13 and 14 have 2.39), submodules never.
        let numbers: [String] = (GitWriter.version ?? []).map { String($0) }
        let version = numbers.isEmpty ? "not read" : numbers.joined(separator: ".")
        let fits = GitWriter.version != nil && command.contains("--porcelain") == porcelain && command.contains("--no-recurse-submodules")
        let worked = log.entries.contains { $0.background && $0.command == command && $0.status == 0 }
        check(fits && worked, "the background fetch fits the installed git, and works with it", "git \(version): \(command), worked \(worked)")

        // The setting, in Settings › Editor.
        let choices = EditorSettingsView().backgroundFetch
        let titles = FetchFrequency.allCases.map(\.title)
        check(choices.itemTitles == titles && choices.titleOfSelectedItem == fetcher.frequency.title,
              "Settings › Editor › Git offers every 5, 10 or 30 minutes, only from the popup, or off", choices.itemTitles.joined(separator: " | "))

        // The branch popup, once the last fetch is old (here: at once), fetches as it opens; the timer is out of the way.
        fetcher.test = (root: work.path, interval: 3600, staleAfter: 0)
        // A timer fetch still under way would make the popup skip its own; the schedule knows from its start
        // (reading the tracked remotes), before GitWriter does.
        let repository = GitWriter.repository(of: work.path)
        _ = await wait(5) { !fetcher.schedule.isRunning(repository) }
        theirs("another change")
        w.showBranches(nil)
        let popup = w.branchPopup
        check(await wait(10) { popup.isVisible && popup.model?.currentRef?.behind == 2 },
              "opening the branch popup fetches when the last fetch is old, and its counts update in place", "behind \(popup.model?.currentRef?.behind ?? -1)")
        check(await wait(5) { header.syncText == "Pull 2" || header.syncText == "↓2" }, "and the header follows", header.syncText)
        check(!FileManager.default.fileExists(atPath: fetchHead), "FETCH_HEAD is still untouched")
        popup.close()

        // A remote that needs a password (here one that says so, as a server does): the fetch fails quietly,
        // background fetch leaves that remote alone, and nothing asks, opens a tab or tries again.
        run(["config", "remote.origin.uploadpack", "echo 'fatal: Authentication failed for x' >&2; exit 128; :"], in: work)
        let tabs = w.tabs.count
        fetcher.test = (root: work.path, interval: 1, staleAfter: 3600)
        let paused = await wait(10) { fetcher.schedule.isPausedForPerson(repository, remote: "origin") }
        func lastBackground() -> GitCommandLog.Entry? { GitCommandLog.shared.entries.last { $0.background } }
        let failure = lastBackground()
        await pause(2) // two intervals
        let retried = lastBackground()?.start != failure?.start
        let prompted = w.window?.attachedSheet != nil || NSApp.modalWindow != nil || w.tabs.count != tabs
        check(paused && failure?.status == 128 && !retried && !prompted,
              "a remote that needs a password pauses background fetch quietly: no sheet, no tab, no second try",
              "paused \(paused), exit \(failure?.status ?? -1), retried \(retried), prompted \(prompted)")
        // A fetch of yours that works takes the remote up again.
        run(["config", "--unset", "remote.origin.uploadpack"], in: work)
        fetcher.fetchedByHand(repository: repository)
        let resumed = await wait(10) {
            guard let entry = lastBackground(), entry.start != failure?.start else { return false }
            return entry.status == 0
        }
        check(resumed && !fetcher.schedule.isPausedForPerson(repository), "and a fetch of yours that works turns it back on",
              lastBackground()?.output ?? "no background fetch")
        fetcher.test = nil
        _ = await wait(5) { !fetcher.schedule.isRunning(repository) }

        // A command of yours never waits behind a background fetch: one from a remote that takes 20 seconds
        // to answer is stopped for it.
        run(["config", "remote.origin.uploadpack", "sleep 20; :"], in: work)
        fetcher.test = (root: work.path, interval: 1, staleAfter: 3600)
        let slow = await wait(5) { GitWriter.shared.isFetchingInBackground(in: work.path) }
        fetcher.test = nil // this one only
        let queued = Date()
        var waited: TimeInterval?, status: Int32 = -1
        GitWriter.shared.run("Status", in: work.path, repository: repository, steps: [["status", "--porcelain"]]) { result in
            waited = Date().timeIntervalSince(queued)
            status = result.status
        }
        let ran = await wait(10) { waited != nil }
        let soon: Bool = (waited ?? 99) < 5
        check(slow && ran && soon && status == 0, "a command of yours stops a slow background fetch rather than wait behind it",
              "fetching \(slow), waited \(waited.map { String(format: "%.1f s", $0) } ?? "over 10 s"), exit \(status)")
        let stopped = GitCommandLog.shared.entries.last { $0.background }
        check(stopped?.output.contains("Stopped, so a command of yours could run.") == true, "and Git Commands says why it stopped",
              stopped?.output ?? "no background entry")
        _ = await wait(5) { !fetcher.schedule.isRunning(repository) }

        fetcher.test = nil
        w.closeProject(nil)
        _ = await wait(5) { !AppDelegate.shared.controllers.contains { $0 === w } }
        c.window?.makeKeyAndOrderFront(nil)
    }

    /// The links agent platforms print (LangGraph's dev server, LangSmith, Weave, MLflow) are found whole:
    /// a Studio link with a second URL inside it, emoji and colour before them, and one long enough to
    /// wrap. Pinned here because it rests on SwiftTerm's link pattern, which can change under us.
    private static func platformLinkChecks(_ c: TerminalWindowController) async {
        let tab = c.addTab(directory: "/tmp")
        guard await wait(20, { tab.status.integrated }) else { return check(false, "a tab for the link checks starts") }
        await pause(0.3)
        let terminal = tab.view.getTerminal()
        let cases: [(prefix: String, url: String)] = [
            ("- \u{1b}[36m🎨 Studio UI: \u{1b}[0m", "https://smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2024"),
            ("URL: ", "https://smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2024&organizationId=0b0f2c3e-1d2a-4f5b-9c8d-7e6f5a4b3c2d"),
            ("- 📚 API Docs: ", "http://127.0.0.1:2024/docs"),
            ("View the run at ", "https://smith.langchain.com/o/0b0f2c3e-1d2a-4f5b-9c8d-7e6f5a4b3c2d/projects/p/4a1b2c3d-5e6f-4a7b-8c9d-0e1f2a3b4c5d/r/"
                + "9f8e7d6c-5b4a-4c3d-2e1f-0a9b8c7d6e5f?poll=true&trace_id=1c2d3e4f-5a6b-7c8d-9e0f-1a2b3c4d5e6f"),
            ("🍩 ", "https://wandb.ai/team/rag-eval/r/call/0192a3b4-c5d6-7e8f-9a0b-1c2d3e4f5a6b"),
            ("🏃 View run bright-cat-42 at: ", "http://127.0.0.1:5000/#/experiments/1/runs/3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8c"),
        ]
        var failures: [String] = []
        var wrapped = false
        for (prefix, url) in cases {
            tab.view.feed(text: "\u{1b}[H\u{1b}[2J" + prefix + url + "\r\n")
            // Columns before the URL: escape codes take none, these emoji two each.
            let plain = prefix.replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
            let start = plain.unicodeScalars.reduce(0) { $0 + ($1.properties.isEmojiPresentation ? 2 : 1) }
            let cols = terminal.cols
            for offset in [8, url.count - 2] {
                let index = start + offset
                if index / cols > 0 { wrapped = true }
                let found = terminal.link(at: .screen(SwiftTerm.Position(col: index % cols, row: index / cols)), mode: .explicitAndImplicit)
                if found != url { failures.append("\(url.prefix(40))… at \(offset): \(found ?? "nil")") }
            }
        }
        check(failures.isEmpty, "agent platforms' links are found whole (LangGraph Studio, LangSmith, Weave, MLflow)",
              failures.joined(separator: " | "))
        check(wrapped, "including a link that wraps onto the next line")
        tab.view.feed(text: "\u{1b}[H\u{1b}[2J")
        c.requestClose(tab)
    }

    /// A new version: the update window over the front window (the keyboard stays in the terminal), the
    /// Update button at the top right, Remind Me Later, the button bringing it back, Skip This Version.
    private static func updateChecks(_ c: TerminalWindowController) async {
        guard let window = c.window else { return }
        let defaults = UserDefaults.standard
        let keys = ["skippedVersion", "updateRemindTag", "updateRemindAfter"]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach(defaults.removeObject(forKey:))
        let updater = Updater.shared
        let page = URL(string: "https://github.com/MishukAdhikari/next-term/releases/tag/v99.0.0")!
        let notes = """
        **A test release.**

        ### Highlights
        - **The update window.** Skip it, or be reminded later.
          - Nested, with `code` and a [link](https://example.com).
        1. A numbered step

        ### Install
        Drag it to Applications.
        """
        let latest = ReleaseInfo(version: AppVersion("99.0.0")!, tag: "v99.0.0", pageURL: page,
                                 dmgURL: URL(string: "https://github.com/MishukAdhikari/next-term/releases/download/v99.0.0/NextTerm-99.0.0.dmg"),
                                 checksumURL: URL(string: "https://github.com/MishukAdhikari/next-term/releases/download/v99.0.0/NextTerm-99.0.0.dmg.sha256"),
                                 notes: notes, published: Date())
        let older = ReleaseInfo(version: AppVersion("98.1.0")!, tag: "v98.1.0", pageURL: page, dmgURL: nil, checksumURL: nil,
                                notes: "- An earlier fix.")
        let current = AppVersion("0.5.0")!
        let focus = c.activeTab?.view
        window.makeKeyAndOrderFront(nil)
        if let focus { window.makeFirstResponder(focus) }

        updater.offer(latest, current: current, userInitiated: false, notes: [latest, older])
        guard let prompt = updater.prompt, let promptWindow = prompt.window else { return check(false, "a new version opens the update window") }
        check(promptWindow.isVisible && promptWindow.parent === window, "a new version opens the update window over the front window")
        check(!promptWindow.isKeyWindow && (focus == nil || window.firstResponder === focus),
              "opened by the automatic check, it leaves the keyboard in the terminal")
        let text = prompt.notesView.string
        check(text.contains("Next Term 99.0.0") && text.contains("Next Term 98.1.0") && text.contains("•\tThe update window.")
              && text.contains("◦\tNested, with code and a link.") && !text.contains("Drag it to Applications"),
              "it shows the notes of every version since this one, without the install steps", text)
        check(prompt.installButton.title == "Install and Relaunch" && prompt.skipButton.title == "Skip This Version"
              && prompt.laterButton.title == "Remind Me Later", "with Install and Relaunch, Remind Me Later and Skip This Version")
        let bar = c.topRightBar
        let other = bar === c.tabBar ? c.editorArea.tabBar : c.tabBar
        bar.layoutSubtreeIfNeeded()
        check(!bar.updateButton.isHidden && bar.updateButton.title == "Update" && other.updateButton.isHidden,
              "the bar at the window's top-right shows the Update button")
        check(bar.updateButton.frame.maxX <= bar.bounds.width - 4 && bar.updateButton.frame.width > 40,
              "it sits at the bar's right end", "\(bar.updateButton.frame) in \(bar.bounds)")
        await screenshot(promptWindow, suffix: "update-window")
        await screenshot(c, suffix: "update-button")

        prompt.later()
        check(updater.prompt == nil && !promptWindow.isVisible && defaults.string(forKey: "updateRemindTag") == "v99.0.0",
              "Remind Me Later closes it and stays quiet about this version for a day")
        check(!bar.updateButton.isHidden, "the Update button stays")
        updater.offer(latest, current: current, userInitiated: false, notes: [latest])
        check(updater.prompt == nil, "the next automatic check does not open it again")

        bar.updateButton.performClick(nil)
        check(updater.prompt?.window?.isVisible == true, "the Update button opens it again")
        note("update window key after the button: \(updater.prompt?.window?.isKeyWindow == true), app active: \(NSApp.isActive)")

        updater.prompt?.skip()
        check(defaults.string(forKey: "skippedVersion") == "v99.0.0" && bar.updateButton.isHidden && other.updateButton.isHidden,
              "Skip This Version closes it and hides the Update button")
        updater.offer(latest, current: current, userInitiated: false, notes: [latest])
        check(updater.prompt == nil && bar.updateButton.isHidden, "a skipped version is not offered again by the automatic check")
        updater.offer(latest, current: current, userInitiated: true, notes: [latest])
        check(updater.prompt?.window?.isVisible == true, "Check for Updates… still shows it")
        updater.prompt?.window?.performClose(nil)
        check(updater.prompt == nil, "the close button answers like Remind Me Later")

        updater.withdraw()
        for (key, value) in zip(keys, saved) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        window.makeKeyAndOrderFront(nil)
        if let focus { window.makeFirstResponder(focus) }
    }

    /// The editor gutter marks lines changed since the last commit; the terminal folds to its tab bar and back.
    private static func gutterAndCollapseChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let window = c.window, let git = GitRunner.locateGit() else { return }
        let file = proj.appendingPathComponent("gutter.txt")
        try? "a\nb\nc\n".write(to: file, atomically: true, encoding: .utf8)
        for args in [["add", "gutter.txt"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "gutter", "--", "gutter.txt"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = ["-C", proj.path] + args
            try? process.run()
            process.waitUntilExit()
        }
        c.openFile(file)
        guard let editor = c.editorArea.activeEditor, editor.document.path.hasSuffix("gutter.txt") else { return check(false, "gutter.txt opens") }
        await pause(1)
        check(editor.changeMarks.isEmpty, "a committed file opens with no change marks")
        editor.textView.insertText("B", replacementRange: NSRange(location: 2, length: 1))
        editor.textView.insertText("d\n", replacementRange: NSRange(location: 6, length: 0))
        check(await wait(5) { editor.changeMarks.lines == [1: .modified, 3: .added] }, "the gutter marks a changed line and an added one, before saving",
              "\(editor.changeMarks.lines)")
        // Only a deletion: "b" gone from the committed "a b c".
        editor.textView.insertText("a\nc\n", replacementRange: NSRange(location: 0, length: (editor.textView.string as NSString).length))
        check(await wait(5) { editor.changeMarks.lines.isEmpty && editor.changeMarks.deletedBefore == [1] }, "and where lines were deleted",
              "\(editor.changeMarks)")
        await screenshot(c, suffix: "gutter")

        // Collapse the terminal to its tab bar, and back.
        let pane = c.tabBar.superview
        let before = pane?.frame.height ?? 0
        c.toggleTerminalCollapsed(nil)
        check(c.terminalCollapsed && abs((pane?.frame.height ?? 0) - TabBarView.height) < 2, "⌘J folds the terminal down to its tab bar",
              "\(pane?.frame.height ?? -1)")
        await screenshot(c, suffix: "collapsed")
        c.toggleTerminalCollapsed(nil)
        check(!c.terminalCollapsed && abs((pane?.frame.height ?? 0) - before) < 2, "and again brings it back to its size",
              "\(before) → \(pane?.frame.height ?? -1)")
        // A double-click on the bar's empty part does what the arrow does: fold, then back.
        func doubleClickBar() {
            let bar = c.tabBar
            let point = bar.convert(NSPoint(x: bar.bounds.maxX - 140, y: bar.bounds.midY), to: nil)
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)
            if let event { bar.mouseDown(with: event) }
        }
        let zoomedBefore = window.isZoomed
        doubleClickBar()
        check(c.terminalCollapsed && window.isZoomed == zoomedBefore, "a double-click on the empty part of the terminal's tab bar folds it, as the arrow does")
        doubleClickBar()
        check(!c.terminalCollapsed && abs((pane?.frame.height ?? 0) - before) < 2, "and a second one brings it back",
              "\(before) → \(pane?.frame.height ?? -1)")

        // Put the file back as committed.
        editor.textView.insertText("a\nb\nc\n", replacementRange: NSRange(location: 0, length: (editor.textView.string as NSString).length))
        c.editorArea.save(editor.document)
        check(await wait(5) { editor.changeMarks.isEmpty }, "the marks go once the file matches the commit again")
        c.editorArea.close(editor)
        _ = window
    }

    /// Beside the editor, ⌘J folds the terminal to a rail at the window's edge: the arrow back, each tab's
    /// mark, a few pulses when one finishes (none with Reduce Motion), a click on a mark opening its tab.
    private static func railChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let window = c.window, let app = AppDelegate.shared, let pane = c.tabBar.superview else { return }
        let file = proj.appendingPathComponent("rail.txt")
        try? "rail\n".write(to: file, atomically: true, encoding: .utf8)
        c.openFile(file)
        guard let editor = c.editorArea.activeEditor, editor.document.path.hasSuffix("rail.txt") else { return check(false, "rail.txt opens") }
        let savedPosition = app.terminalPosition
        let home = c.activeTab // the project's tab: the checks after this one read the project in the sidebar
        let rail = c.terminalRail
        // One tab in front, and one opened behind it (as an agent would).
        let front = c.addTab(directory: proj.path)
        let back = c.addTab(directory: proj.path, select: false)
        _ = await wait(20) { front.status.integrated && back.status.integrated }
        app.terminalPosition = .right
        c.applyLayout()
        window.layoutIfNeeded()
        let width = pane.frame.width
        let columns = front.view.getTerminal().cols
        // History that a squeeze to a few columns would rewrap past the scrollback's end.
        front.view.send(txt: "echo rail-top; seq -f '%070g' 1 400\r")
        _ = await wait(5) { !front.status.running && front.screenTail(4).contains { $0.hasSuffix("0400") } }
        await pause(0.3) // and the prompt after it
        let lastRow = front.lastTextRow()
        window.makeFirstResponder(front.view)
        c.toggleTerminalCollapsed(nil)
        window.layoutIfNeeded()
        check(c.terminalRailed && abs(pane.frame.width - TerminalRail.width) < 2 && !rail.isHidden && c.tabBar.isHidden && rail.pointsLeft,
              "beside the editor, ⌘J folds the terminal to a rail at the window's edge", "\(width) → \(pane.frame.width)")
        check(window.firstResponder === editor.textView, "folding gives the keyboard to the editor")
        check(front.view.getTerminal().cols == columns && lastRow != nil && front.lastTextRow() == lastRow,
              "folding to the rail never squeezes the terminals: their width and scrollback stay whole",
              "\(columns) → \(front.view.getTerminal().cols) columns, last row \(lastRow ?? -1) → \(front.lastTextRow() ?? -1)")
        // Dragging the line out of the rail: where the drag would leave the terminal (it is on the right).
        if let split = pane.superview as? NSSplitView {
            let room = split.bounds.width - split.dividerThickness
            let dragged = [60, 150, 400].map { (room - c.splitView(split, constrainSplitPosition: room - $0, ofSubviewAt: 0)).rounded() }
            check(dragged == [TerminalRail.width, 240, 400], "dragged out of the rail, the terminal is the rail or its usual width, never a few columns",
                  "60, 150, 400 → \(dragged)")
        }
        let states = c.tabBar.items.map(\.state)
        check(rail.marks.count == c.groups.count && rail.marks.map(\.state) == states && rail.marks[safe: c.activeIndex]?.selected == true,
              "the rail has a mark for each tab, in order, as the tab bar has them", "\(rail.marks.map(\.state)) vs \(states)")
        let backIndex = c.groups.firstIndex { $0.contains(back) } ?? 0
        let backButton = rail.markButtons[safe: backIndex]
        let backLabel = backButton?.accessibilityLabel() ?? ""
        // VoiceOver goes into a group, not into a button: the arrow and the marks are buttons side by side in it.
        let railChildren = rail.accessibilityChildren() ?? []
        let expandButton = railChildren.lazy.compactMap { $0 as? NSAccessibilityElement }.first { $0.accessibilityLabel() == "Expand terminal" }
        check(rail.accessibilityRole() == .group && expandButton?.accessibilityRole() == .button
              && railChildren.contains { ($0 as? NSButton) === backButton } && backButton?.isAccessibilityElement() == true
              && backButton?.accessibilityRole() == .button && backLabel.hasPrefix(back.title),
              "VoiceOver: the folded terminal is a group, an Expand terminal button and a button for each tab", backLabel)
        check(rail.markButtons[safe: backIndex]?.toolTip == back.title + "\n" + back.stateDescription, "a mark's tooltip is its tab's title and state",
              rail.markButtons[safe: backIndex]?.toolTip ?? "none")
        await screenshot(c, suffix: "-rail")
        // ⌘W with the keyboard outside the editor (in the sidebar): the tab in front is folded away, so nothing closes.
        window.makeFirstResponder(c.sidebar.outline)
        let tabCount = c.groups.count
        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(TerminalWindowController.closeTab(_:)), keyEquivalent: "w")
        c.closeTab(nil)
        check(!c.validateMenuItem(closeItem) && c.groups.count == tabCount && c.terminalRailed,
              "folded to the rail, ⌘W outside the editor closes no terminal tab out of sight", "\(tabCount) → \(c.groups.count) tabs")
        // More tabs than the rail has room for: its last place is "+N" for the rest.
        let realMarks = rail.marks
        let extraTabs = (0..<Int(rail.bounds.height / 24)).map { _ in NSObject() }
        rail.update(marks: realMarks + extraTabs.map {
            TerminalRail.Mark(id: ObjectIdentifier($0), state: .idle, toolTip: "zsh", label: "zsh, Idle", selected: false)
        })
        rail.layoutSubtreeIfNeeded()
        let shownMarks = rail.markButtons.filter { !$0.isHidden }
        let more = rail.overflowButton
        let lastShown = shownMarks.map(\.frame.maxY).max() ?? 0
        check(shownMarks.count < rail.marks.count && !more.isHidden && more.title == "+\(rail.marks.count - shownMarks.count)"
              && more.frame.minY >= lastShown && more.frame.maxY <= rail.bounds.height,
              "more tabs than the rail has room for: its last place is +N for the rest", "\(shownMarks.count) of \(rail.marks.count), \(more.title)")
        c.refresh()
        window.layoutIfNeeded()
        check(rail.marks.count == c.groups.count && more.isHidden, "and with room for them all it goes", more.title)

        // The tab in front fails while folded: nobody sees it, so its mark says so and the rail pulses a few times
        // (with motion, whatever Reduce Motion is on this Mac).
        let reducesMotion = TerminalRail.reducesMotion
        TerminalRail.reducesMotion = { false }
        let noticed = rail.changesNoticed
        front.view.send(txt: "sleep 0.3; false\r")
        let frontIndex = c.groups.firstIndex { $0.contains(front) } ?? 0
        check(await wait(5) { rail.marks[safe: frontIndex]?.state == .failed }, "the tab in front failing behind the rail shows on its mark",
              rail.marks[safe: frontIndex]?.state.rawValue ?? "none")
        check(rail.changesNoticed > noticed && rail.isPulsing, "and the rail pulses", "noticed \(rail.changesNoticed - noticed)")
        await screenshot(c, suffix: "-rail-pulse")
        check(await wait(4) { !rail.isPulsing } && rail.marks[safe: frontIndex]?.state == .failed, "a few times, then it stays still with the mark")
        // With Reduce Motion the mark just appears.
        TerminalRail.reducesMotion = { true }
        let noticedBefore = rail.changesNoticed
        back.view.send(txt: "sleep 0.3\r")
        check(await wait(5) { rail.marks[safe: backIndex]?.state == .done } && rail.changesNoticed > noticedBefore && !rail.isPulsing,
              "with Reduce Motion the mark appears and nothing moves", "pulsing \(rail.isPulsing)")
        // Done, busy, done again (an agent pausing in its output): the rail pulsed for it once, and stays still.
        let started = front.status.commandsStarted
        front.view.send(txt: "sleep 0.3\r")
        _ = await wait(5) { front.status.commandsStarted > started && rail.marks[safe: frontIndex]?.state == .done }
        let noticedDone = rail.changesNoticed
        front.view.send(txt: "sleep 1\r")
        let busy = await wait(3) { rail.marks[safe: frontIndex]?.state != .done } // running, the mark clears
        let doneAgain = await wait(5) { rail.marks[safe: frontIndex]?.state == .done }
        check(busy && doneAgain && rail.changesNoticed == noticedDone, "a tab done again behind the rail does not pulse again",
              "busy \(busy), done \(doneAgain), noticed \(rail.changesNoticed - noticedDone) more")
        TerminalRail.reducesMotion = reducesMotion

        // A click on a mark opens the terminal on that tab, at its size.
        rail.clickMark(backIndex)
        window.layoutIfNeeded()
        check(!c.terminalCollapsed && rail.isHidden && !c.tabBar.isHidden && c.activeIndex == backIndex && abs(pane.frame.width - width) < 2,
              "clicking a mark expands the terminal and selects that tab", "active \(c.activeIndex) of \(backIndex), width \(pane.frame.width)")
        check(window.firstResponder === back.view, "with the keyboard in it")
        // ⌘J folds and opens it again at the size it had; selecting a tab (⌃Tab, ⌘1) opens it too.
        c.toggleTerminalCollapsed(nil)
        c.toggleTerminalCollapsed(nil)
        window.layoutIfNeeded()
        check(!c.terminalCollapsed && rail.isHidden && abs(pane.frame.width - width) < 2, "⌘J brings the folded terminal back at its size",
              "\(width) → \(pane.frame.width)")
        // Pressing the rail itself: a click on it below the arrow, or VoiceOver's Expand terminal button.
        c.toggleTerminalCollapsed(nil)
        window.layoutIfNeeded()
        let onRail = rail.convert(NSPoint(x: rail.bounds.midX, y: rail.bounds.maxY - 8), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: onRail, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            if type == .leftMouseDown { rail.mouseDown(with: event) } else { rail.mouseUp(with: event) }
        }
        window.layoutIfNeeded()
        check(!c.terminalCollapsed && rail.isHidden && abs(pane.frame.width - width) < 2, "a click on the rail brings the terminal back at its size",
              "\(width) → \(pane.frame.width)")
        c.toggleTerminalCollapsed(nil)
        let pressed = expandButton?.accessibilityPerformPress() == true
        window.layoutIfNeeded()
        check(pressed && !c.terminalCollapsed && abs(pane.frame.width - width) < 2, "and so does VoiceOver's Expand terminal button",
              "\(width) → \(pane.frame.width)")
        c.toggleTerminalCollapsed(nil)
        c.cycleTab(by: 1)
        check(!c.terminalCollapsed && rail.isHidden, "switching tabs from the keyboard opens the rail")

        // On the left, the arrow points right and the editor's tabs take the corner.
        app.terminalPosition = .left
        c.applyLayout()
        c.toggleTerminalCollapsed(nil)
        window.layoutIfNeeded()
        let railFrame = pane.convert(pane.bounds, to: nil), editorFrame = c.editorArea.convert(c.editorArea.bounds, to: nil)
        check(c.terminalRailed && !rail.pointsLeft && railFrame.maxX <= editorFrame.minX + 1 && abs(railFrame.width - TerminalRail.width) < 2,
              "with the terminal on the left, the rail is at the left edge", "rail \(railFrame.integral)")
        await screenshot(c, suffix: "-rail-left")
        // At the window's top-left corner (the sidebar hidden) the traffic lights keep their strip: a press there
        // moves the window, as on the tab bars; the arrow and the marks come below it.
        let sidebarShown = c.isSidebarVisible
        c.setSidebarVisible(false)
        window.layoutIfNeeded()
        let firstMark = rail.markButtons.first { !$0.isHidden }
        check(rail.topInset == TabBarView.height && rail.isTitleBar(NSPoint(x: 12, y: rail.topInset - 4))
              && !rail.isTitleBar(NSPoint(x: 12, y: rail.topInset + 4)) && (firstMark?.frame.minY ?? 0) >= rail.topInset + TabBarView.height,
              "under the traffic lights the rail's top strip is title bar, with the arrow and the marks below it",
              "inset \(rail.topInset), first mark at \(firstMark?.frame.minY ?? -1)")
        c.setSidebarVisible(sidebarShown)
        c.toggleTerminalCollapsed(nil)

        // Above or below the editor, folding is as it was: down to the tab bar.
        for position in [AppDelegate.TerminalPosition.top, .bottom] {
            app.terminalPosition = position
            c.applyLayout()
            c.toggleTerminalCollapsed(nil)
            window.layoutIfNeeded()
            check(c.terminalCollapsed && !c.terminalRailed && rail.isHidden && !c.tabBar.isHidden && abs(pane.frame.height - TabBarView.height) < 2,
                  "terminal on the \(position.rawValue): folding still leaves its tab bar", "\(pane.frame.height)")
            c.toggleTerminalCollapsed(nil)
        }

        app.terminalPosition = savedPosition
        c.applyLayout()
        for tab in [front, back] { tab.status.setVisible(true); c.requestClose(tab) }
        // Switching tabs above went round past the last one: back to the tab that was in front.
        if let home { c.show(home) }
        c.editorArea.close(editor)
        try? FileManager.default.removeItem(at: file)
    }

    /// With nothing open the editor is hidden, and stays hidden whatever the pointer does at the work area's
    /// edge, with the terminal across the whole area. Its divider used to stay grabbable there, 3 points
    /// right of the sidebar with the terminal on the right (at the terminal's own edge in the other layouts):
    /// a press that slipped a point, dismissing the branch popup say, showed an editor with no tabs between
    /// the sidebar and the terminal, and saved its width as the editor's share. Real mouse events, as a hand
    /// makes them.
    private static func emptyEditorChecks(_ c: TerminalWindowController, proj: URL, tab: TerminalTab) async {
        guard let window = c.window, let work = c.editorArea.superview as? NSSplitView, let terminalPane = c.tabBar.superview,
              let outer = window.contentView as? NSSplitView else { return check(false, "the work area is a split view") }
        let app = AppDelegate.shared!
        let area = c.editorArea
        let defaults = UserDefaults.standard
        let saved = (position: app.terminalPosition, side: app.sidebarSide, fraction: defaults.object(forKey: "editorFraction"),
                     width: defaults.object(forKey: "sidebarWidth"), sidebar: c.isSidebarVisible, frame: window.frame)
        func restore(_ key: String, _ value: Any?) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        func restoreFraction() { restore("editorFraction", saved.fraction) }
        let readme = proj.appendingPathComponent("README.md")
        area.closeAll()
        c.show(tab) // in the git project: the sidebar has its branch
        if !c.isSidebarVisible { c.toggleProjectSidebar(nil) }
        // The user's layout: sidebar on the left, terminal on the right.
        app.terminalPosition = .right
        app.sidebarSide = .left
        c.applyLayout()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await pause(0.3)

        // First, with a file open: a drag on the line between editor and terminal moves it (so the drags
        // below reach the split view at all).
        c.openFile(readme)
        window.layoutIfNeeded()
        let editorWidth = area.frame.width
        let line = work.convert(NSPoint(x: area.frame.maxX + 0.5, y: work.bounds.midY), to: nil)
        await drag(in: window, from: line, to: NSPoint(x: line.x - 40, y: line.y))
        window.layoutIfNeeded()
        // If this drag didn't arrive, the "leaves it hidden" checks below would pass without a press reaching
        // the window: they fail too, saying so.
        let moved = abs(area.frame.width - (editorWidth - 40)) <= 2
        check(moved, "a drag on the line between editor and terminal moves it", "\(editorWidth) → \(area.frame.width)")
        let unproven = "the drag on the visible line did not move it, so these presses prove nothing"
        area.closeAll()
        restoreFraction()
        let fraction = app.editorFraction

        /// What is wrong while nothing is open: an editor showing, a terminal short of the whole work area.
        func problems() -> String {
            window.layoutIfNeeded()
            var found: [String] = []
            if !area.isHidden { found.append("an editor shows") }
            if !area.isEmpty || !area.tabBar.items.isEmpty { found.append("\(area.panes.count) panes, \(area.tabBar.items.count) tabs") }
            let length = work.isVertical ? work.bounds.width : work.bounds.height
            let frame = terminalPane.frame
            let (start, size) = work.isVertical ? (frame.minX, frame.width) : (frame.minY, frame.height)
            if abs(start) > 0.5 || abs(size - length) > 0.5 { found.append("the terminal has \(size) of \(length) from \(start)") }
            if c.tabBar.onToggleCollapse != nil { found.append("the terminal offers to collapse beside it") }
            if app.editorFraction != fraction { found.append("the editor's share went from \(fraction) to \(app.editorFraction)") }
            return found.joined(separator: "; ")
        }
        var shot = false
        func edgeCheck(_ name: String, from: NSPoint, to: NSPoint, steps: Int = 1) async {
            await drag(in: window, from: from, to: to, steps: steps)
            let found = problems()
            check(moved && found.isEmpty, name, moved ? found : unproven)
            guard !found.isEmpty else { return }
            if !shot { shot = true; await screenshot(c, suffix: "-empty-editor") }
            // Back to a clean start for the next check.
            c.openFile(readme)
            area.closeAll()
            restoreFraction()
        }
        let found = problems()
        check(found.isEmpty, "nothing open: the terminal fills the work area, edge to edge", found)

        let edge = work.convert(NSPoint.zero, to: nil).x // the sidebar's right edge, in the window
        let middle = work.convert(NSPoint(x: 0, y: work.bounds.midY), to: nil).y
        let header = c.sidebar.header
        let gitBar = header.convert(NSPoint(x: 0, y: header.bounds.midY), to: nil).y
        await edgeCheck("a press 3 pt right of the sidebar that slips 1 pt leaves the editor hidden",
                        from: NSPoint(x: edge + 3, y: middle), to: NSPoint(x: edge + 4, y: middle))
        await edgeCheck("… so does a drag from there", from: NSPoint(x: edge + 3, y: middle), to: NSPoint(x: edge + 43, y: middle), steps: 4)
        await edgeCheck("… and the same press level with the branch at the top",
                        from: NSPoint(x: edge + 3, y: gitBar), to: NSPoint(x: edge + 5, y: gitBar))
        // The user's steps: the branch clicked, then a click beside the sidebar to dismiss its popup.
        if c.sidebar.git.snapshot != nil {
            c.showBranches(nil)
            _ = await wait(3) { c.branchPopup.isVisible }
            await edgeCheck("a click there that closes the branch popup and slips 2 pt leaves the editor hidden",
                            from: NSPoint(x: edge + 3, y: gitBar), to: NSPoint(x: edge + 5, y: gitBar))
            if c.branchPopup.isVisible { c.branchPopup.close() }
        } else {
            note("no branch in the sidebar: the branch popup's step was skipped")
        }
        // The hidden editor's divider in the other layouts: the work area's top edge (terminal at the bottom,
        // the default), its right edge (terminal on the left) or its bottom edge (terminal on top).
        for (position, side) in [(AppDelegate.TerminalPosition.bottom, "top"), (.left, "right"), (.top, "bottom")] {
            app.terminalPosition = position
            c.applyLayout()
            window.layoutIfNeeded()
            let bounds = work.bounds
            let from: NSPoint, to: NSPoint
            switch position {
            case .bottom: // clear of the sidebar's divider and of the tabs (a press on a tab selects it)
                from = work.convert(NSPoint(x: 5, y: 2), to: nil)
                to = NSPoint(x: from.x, y: from.y - 40)
            case .left:
                from = work.convert(NSPoint(x: bounds.maxX - 2, y: bounds.midY), to: nil)
                to = NSPoint(x: from.x - 40, y: from.y)
            default:
                from = work.convert(NSPoint(x: bounds.midX, y: bounds.maxY - 2), to: nil)
                to = NSPoint(x: from.x, y: from.y + 40)
            }
            await edgeCheck("terminal on the \(position.rawValue): a drag in from the work area's \(side) edge leaves the editor hidden",
                            from: from, to: to, steps: 4)
        }

        // A hidden sidebar's divider at the window's edge is no handle either (a file open, so the editor's
        // own divider is out of the way).
        app.terminalPosition = .right
        c.applyLayout()
        c.openFile(readme)
        c.toggleProjectSidebar(nil)
        window.layoutIfNeeded()
        let main = outer.arrangedSubviews.first { $0 !== c.sidebar }
        await drag(in: window, from: NSPoint(x: 2, y: middle), to: NSPoint(x: 42, y: middle), steps: 4)
        window.layoutIfNeeded()
        let mainFrame = main?.frame ?? .zero
        check(moved && !c.isSidebarVisible && mainFrame.minX == 0 && mainFrame.width == outer.bounds.width,
              "with the sidebar hidden, a drag at the window's edge leaves it hidden",
              moved ? "sidebar hidden \(!c.isSidebarVisible), work area \(mainFrame) of \(outer.bounds.width)" : unproven)
        app.sidebarVisible = true
        restore("sidebarWidth", saved.width) // a sidebar dragged out by AppKit saves its width
        c.setSidebarVisible(true)
        area.closeAll()

        // Presses at the window's edge resize it (once no divider takes them): its frame back first, as
        // resizing it moves the sidebar, then the sizes it saved.
        window.setFrame(saved.frame, display: true)
        app.terminalPosition = saved.position
        app.sidebarSide = saved.side
        restore("sidebarWidth", saved.width)
        if c.isSidebarVisible != saved.sidebar { c.toggleProjectSidebar(nil) }
        c.applyLayout()
        restoreFraction()
        restore("sidebarWidth", saved.width) // laying out saves the width it placed (the default, if none was saved)
    }

    /// A press at `from`, moved to `to` in `steps` and released there (window coordinates): real mouse events
    /// through the app's event queue, as a hand makes them.
    private static func drag(in window: NSWindow, from: NSPoint, to: NSPoint, steps: Int = 1) async {
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)
        }
        let path = (1...max(1, steps)).map { i -> NSPoint in
            let t = CGFloat(i) / CGFloat(max(1, steps))
            return NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        }
        let events = [event(.leftMouseDown, at: from)] + path.map { event(.leftMouseDragged, at: $0) } + [event(.leftMouseUp, at: to)]
        for event in events.compactMap({ $0 }) { NSApp.postEvent(event, atStart: false) }
        await pause(0.5)
    }

    /// View › Annotate with Git Blame: who last changed each line, beside the numbers; edited lines are not
    /// committed, and the lines below keep their commit.
    private static func blameChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let git = GitRunner.locateGit(), let app = AppDelegate.shared else { return }
        func commit(_ author: String, _ message: String) {
            for args in [["add", "blame.txt"], ["-c", "user.name=\(author)", "-c", "user.email=\(author.prefix(3).lowercased())@example.com",
                                                "-c", "commit.gpgsign=false", "commit", "-qm", message, "--", "blame.txt"]] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: git)
                process.arguments = ["-C", proj.path] + args
                try? process.run()
                process.waitUntilExit()
            }
        }
        let file = proj.appendingPathComponent("blame.txt")
        try? "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
        commit("Ann Lee", "First lines")
        try? "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        commit("Bob Stone", "Add a third line")
        let saved = (app.blameAnnotations, app.currentLineBlame)
        if app.blameAnnotations { app.toggleBlameAnnotations(nil) }
        c.openFile(file)
        guard let editor = c.editorArea.activeEditor, editor.document.path.hasSuffix("blame.txt"),
              let ruler = editor.scrollView.verticalRulerView else { return check(false, "blame.txt opens") }
        let narrow = ruler.ruleThickness
        app.toggleBlameAnnotations(nil)
        func column(_ line: Int) -> String { editor.blameColumnText(line: line) ?? "off" }
        check(await wait(5) { column(0).hasPrefix("Ann ") && column(2).hasPrefix("Bob ") }, "blame shows who last changed each line",
              "\(column(0)) / \(column(2))")
        check(column(1).isEmpty, "only on the first line of a commit’s run of lines", column(1))
        check(ruler.ruleThickness > narrow + 100, "in a column beside the line numbers", "\(narrow) → \(ruler.ruleThickness)")
        if let gutter = ruler as? LineNumberRuler {
            gutter.display()
            check(await wait(2) { !gutter.blameToolTipRects.isEmpty }, "each commit’s lines get a hover area", "\(gutter.blameToolTipRects.count)")
            // Right-click on the first line, in the column: the way to that line's commit.
            let first = gutter.convert(NSPoint(x: 0, y: editor.textView.textContainerOrigin.y + 2), from: editor.textView)
            let menu = gutter.blameMenu(at: NSPoint(x: 10, y: first.y))
            let sha = editor.editedBlame?.commit(at: 0)?.sha ?? "none"
            let show = menu.items.first { $0.title == "Show Commit \(sha.prefix(7))" }
            let target = show?.representedObject as? [String]
            check(target == [sha, editor.editedBlame?.blame.root ?? ""], "right-clicking a commit’s lines offers to show that commit",
                  menu.items.map(\.title).joined(separator: ", "))
        }
        if let blame = editor.editedBlame {
            let tip = BlameText.toolTip(blame, line: 2)
            check(tip.hasPrefix("Add a third line\nBob Stone <bob@example.com>\n"), "hovering a commit’s lines tells its summary and author", tip)
        }
        await screenshot(c, suffix: "blame")

        // An edited line is not committed at once, and still after the diff; a line added above moves the rest down.
        editor.textView.insertText("TWO", replacementRange: NSRange(location: 4, length: 3))
        check(column(1) == "Not committed", "an edited line shows as not committed while typing", column(1))
        editor.textView.insertText("zero\n", replacementRange: NSRange(location: 0, length: 0))
        check(await wait(5) { editor.changeMarks.lines == [0: .added, 2: .modified] && column(1).hasPrefix("Ann ") },
              "after the diff, only the new and changed lines are not committed", "\(column(0)) / \(column(1)) / \(column(2)) / \(column(3))")
        check(column(0) == "Not committed" && column(2) == "Not committed" && column(3).hasPrefix("Bob "), "and the lines below keep their commit",
              "\(column(2)) / \(column(3))")

        // A commit while the file is open: blame follows at once, on the HEAD change (not the 5-second check).
        c.editorArea.save(editor.document)
        await pause(0.5) // the save's own refresh reads the old HEAD
        c.editorArea.periodicBaselineChecks = false
        commit("Cy Doe", "Third")
        check(await wait(3) { column(0).hasPrefix("Cy ") && column(2).hasPrefix("Cy ") && editor.changeMarks.isEmpty },
              "a commit re-annotates the open file at once", "\(column(0)) / \(column(1)) / \(column(2)) / \(column(3))")
        c.editorArea.periodicBaselineChecks = true
        check(column(1).hasPrefix("Ann ") && column(3).hasPrefix("Bob "), "and the lines it did not change keep theirs",
              "\(column(1)) / \(column(3))")

        // The caret line's note.
        if !app.currentLineBlame { app.toggleCurrentLineBlame(nil) }
        let note = editor.blameNoteText(line: 3) ?? "none"
        check(note.hasPrefix("Bob, ") && note.hasSuffix(" · Add a third line"), "View › Current Line Blame notes the caret line’s commit", note)

        // Off again, and the file as committed.
        if app.currentLineBlame { app.toggleCurrentLineBlame(nil) }
        app.toggleBlameAnnotations(nil)
        check(editor.blameColumnText(line: 0) == nil && abs(ruler.ruleThickness - narrow) < 1, "turned off, the column goes",
              "\(ruler.ruleThickness)")
        editor.textView.insertText("one\ntwo\nthree\n", replacementRange: NSRange(location: 0, length: (editor.textView.string as NSString).length))
        c.editorArea.save(editor.document)
        commit("Ann Lee", "Back to three lines")
        c.editorArea.close(editor)
        if app.blameAnnotations != saved.0 { app.toggleBlameAnnotations(nil) }
        if app.currentLineBlame != saved.1 { app.toggleCurrentLineBlame(nil) }
    }

    /// ⌘P: the project's files by a few letters; `name:line`; recently opened files first.
    private static func goToFileChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let window = c.window else { return }
        let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
        let menu = items.first { $0.action == #selector(TerminalWindowController.goToFile(_:)) }
        check(menu?.keyEquivalent == "p" && menu?.keyEquivalentModifierMask == .command, "File ▸ Go to File is ⌘P")
        for (path, text) in [("src/Http/Controllers/UserController.php", "<?php\n"), ("src/Models/User.php", "<?php\n"),
                             ("docs/user-guide.md", "# Users\n"), ("src/main.php", "<?php\necho 1;\necho 2;\necho 3;\n")] {
            let url = proj.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { try? text.write(to: url, atomically: true, encoding: .utf8) }
        }
        let finder = c.fileFinder
        finder.show(root: proj.path, recent: c.recentFiles, over: window)
        check(finder.isVisible && window.childWindows?.isEmpty == false, "⌘P opens over the window")
        check(await wait(10) { finder.footerText.contains("files") }, "it lists the project's files", finder.footerText)
        finder.query = "usrctl"
        check(await wait(5) { finder.shownPaths.first == "src/Http/Controllers/UserController.php" }, "“usrctl” finds UserController.php",
              finder.shownPaths.prefix(3).joined(separator: ", "))
        finder.query = "user"
        check(await wait(5) { finder.shownPaths.first == "src/Models/User.php" }, "a whole file name beats a longer one",
              finder.shownPaths.prefix(3).joined(separator: ", "))
        await pause(0.3)
        await screenshot(finder.panelWindow, suffix: "goto")
        finder.query = "main.php:3"
        check(await wait(5) { finder.shownPaths.first == "src/main.php" }, "“name:line” searches for the name")
        finder.openFirst()
        let opened = await wait(3) { c.editorArea.activeEditor?.document.path == canonicalPath(proj.appendingPathComponent("src/main.php").path) }
        var caretLine = -1
        if let editor = c.editorArea.activeEditor {
            caretLine = editor.document.lines.line(at: editor.textView.selectedRange().location) + 1
        }
        check(opened && caretLine == 3 && !finder.isVisible, "and opens the file at that line", "line \(caretLine)")
        // The sidebar follows: the folders open and the file is selected.
        let mainPath = canonicalPath(proj.appendingPathComponent("src/main.php").path)
        if c.sidebar.root?.path == canonicalPath(proj.path) {
            check(await wait(5) { c.sidebar.selection.contains { canonicalPath($0.url.path) == mainPath } },
                  "the project sidebar shows the file opened with ⌘P", c.sidebar.selection.map(\.url.lastPathComponent).joined(separator: ","))
            if let src = c.sidebar.root?.children?.first(where: { $0.name == "src" }) {
                c.sidebar.outline.collapseItem(src)
                c.sidebar.outline.deselectAll(nil)
                c.revealInSidebar(nil)
                check(await wait(5) { c.sidebar.selection.contains { canonicalPath($0.url.path) == mainPath } },
                      "the reveal button finds it again after its folder was closed")
                // Hidden and shown again (⌘B twice): the file in front is revealed.
                c.sidebar.outline.collapseItem(src)
                c.sidebar.outline.deselectAll(nil)
                c.toggleProjectSidebar(nil)
                c.toggleProjectSidebar(nil)
                let revealed = await wait(5) { c.sidebar.selection.contains { canonicalPath($0.url.path) == mainPath } }
                check(c.isSidebarVisible && revealed, "showing the sidebar again reveals the file in front",
                      c.sidebar.selection.map(\.url.lastPathComponent).joined(separator: ","))
            }
        } else {
            note("sidebar root is \(c.sidebar.root?.path ?? "none"), not the test project: reveal not checked here")
        }
        finder.show(root: proj.path, recent: c.recentFiles, over: window)
        check(await wait(5) { finder.shownPaths.first == "src/main.php" }, "with nothing typed, recently opened files come first",
              finder.shownPaths.prefix(3).joined(separator: ", "))
        finder.close()
        // A file git ignores is left out, until you open it: then it is listed with the recent files. A name no
        // earlier section opened (they open the project's .env, which is then rightly among the recent files).
        let exclude = proj.appendingPathComponent(".git/info/exclude")
        let excluded = try? String(contentsOf: exclude, encoding: .utf8)
        try? ((excluded ?? "") + "\n.env.goto\n").write(to: exclude, atomically: true, encoding: .utf8)
        let env = proj.appendingPathComponent(".env.goto")
        try? "APP_NAME=selftest\n".write(to: env, atomically: true, encoding: .utf8)
        finder.show(root: proj.path, recent: c.recentFiles, over: window)
        finder.query = "env.goto"
        await pause(1)
        check(!finder.shownPaths.contains(".env.goto"), "⌘P leaves out a file git ignores", finder.shownPaths.prefix(3).joined(separator: ", "))
        finder.close()
        c.openFile(env)
        finder.show(root: proj.path, recent: c.recentFiles, over: window)
        check(await wait(5) { finder.shownPaths.first == ".env.goto" }, "once opened, it comes first with nothing typed",
              finder.shownPaths.prefix(3).joined(separator: ", "))
        finder.query = "env.goto"
        check(await wait(5) { finder.shownPaths.first == ".env.goto" }, "and its name finds it", finder.shownPaths.prefix(3).joined(separator: ", "))
        finder.close()
        if let editor = c.editorArea.editors.first(where: { $0.document.path == canonicalPath(env.path) }) { c.editorArea.close(editor) }
        try? FileManager.default.removeItem(at: env)
        if let excluded { try? excluded.write(to: exclude, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: exclude) }
        // Selected text starts the search, as for Find.
        c.openFile(proj.appendingPathComponent("docs/user-guide.md"))
        if let editor = c.editorArea.activeEditor, editor.document.path.hasSuffix("user-guide.md") {
            window.makeFirstResponder(editor.textView)
            editor.textView.setSelectedRange(NSRange(location: 2, length: 5)) // "Users" in "# Users"
            c.goToFile(nil)
            check(finder.isVisible && finder.query == "Users", "⌘P with text selected starts from it", finder.query)
            finder.close()
            c.editorArea.close(editor)
        }
        finder.close()
        check(!finder.isVisible && window.childWindows?.isEmpty != false, "Esc closes it")
        if let editor = c.editorArea.activeEditor { c.editorArea.close(editor) }
    }

    /// Split panes: ⌘D and ⌘⇧D, moving between panes, zoom, closing one.
    private static func paneChecks(_ c: TerminalWindowController) async {
        guard let window = c.window, let base = c.activeTab, let group = c.activeGroup else { return check(false, "a tab to split") }
        c.show(base)
        window.makeFirstResponder(base.view)
        let tabsBefore = c.groups.count
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let all = items(NSApp.mainMenu ?? NSMenu())
        let right = all.first { $0.action == #selector(TerminalWindowController.splitRight(_:)) }
        let down = all.first { $0.action == #selector(TerminalWindowController.splitDown(_:)) }
        check(right?.keyEquivalent == "d" && right?.keyEquivalentModifierMask == .command
              && down?.keyEquivalent == "d" && down?.keyEquivalentModifierMask == [.command, .shift],
              "File ▸ Split Right is ⌘D and Split Down ⌘⇧D")
        if NSApp.keyWindow === window {
            NSApp.sendAction(#selector(TerminalWindowController.splitRight(_:)), to: nil, from: nil)
        } else {
            c.splitRight(nil)
        }
        guard let second = c.activeTab, second !== base else { return check(false, "Split Right adds a pane") }
        check(c.groups.count == tabsBefore && group.panes.count == 2, "a split stays one tab with two panes",
              "tabs \(c.groups.count), panes \(group.panes.count)")
        check(window.firstResponder === second.view, "the new pane has the keyboard")
        check(await wait(20) { second.status.integrated }, "the new pane's shell starts")
        func frame(_ tab: TerminalTab) -> NSRect { group.paneView(tab).convert(group.paneView(tab).bounds, to: group.view) }
        check(frame(base).maxX <= frame(second).minX + 2 && abs(frame(base).height - frame(second).height) < 2 && frame(base).width > 100,
              "Split Right puts them side by side", "\(frame(base)) \(frame(second))")
        check(second.currentDirectory() == base.currentDirectory(), "a new pane opens in the pane's folder", second.currentDirectory())

        c.splitDown(nil)
        guard let third = c.activeTab, third !== second else { return check(false, "Split Down adds a pane") }
        _ = await wait(20) { third.status.integrated }
        check(frame(third).maxY <= frame(second).minY + 2 && abs(frame(third).minX - frame(second).minX) < 2,
              "Split Down puts the new pane below", "\(frame(second)) \(frame(third))")
        check(group.paneView(base).dimmed && group.paneView(second).dimmed && !group.paneView(third).dimmed,
              "panes without the keyboard are shaded")
        third.view.send(txt: "\u{15}echo pane three\r")
        second.view.send(txt: "\u{15}echo pane two\r")
        await pause(0.5)
        await screenshot(c, suffix: "split")

        c.selectPaneLeft(nil)
        check(c.activeTab === base && window.firstResponder === base.view, "⌥⌘← moves to the pane on the left")
        c.selectPaneRight(nil)
        let landed = c.activeTab
        check(landed === second || landed === third, "⌥⌘→ moves back to the right")
        c.show(second)
        window.makeFirstResponder(second.view)
        c.selectPaneBelow(nil)
        check(c.activeTab === third, "⌥⌘↓ moves to the pane below")
        c.selectPaneAbove(nil)
        check(c.activeTab === second, "⌥⌘↑ moves to the pane above")
        c.selectNextPane(nil)
        check(c.activeTab === third, "⌥⌘] cycles through the panes")

        c.toggleZoomPane(nil)
        check(group.zoomed === third && third.view.window != nil && base.view.window == nil && second.view.window == nil,
              "⌘⇧↩ fills the tab with one pane")
        c.toggleZoomPane(nil)
        check(group.zoomed == nil && base.view.window != nil && second.view.window != nil, "and again brings the panes back")

        c.refresh()
        let bar = c.tabBar.items[safe: c.activeIndex]
        check(bar?.title.hasSuffix("+2") == true, "the tab says it holds more panes", bar?.title ?? "")
        c.equalizePanes(nil)

        // Typing goes to the pane with the keyboard; a pane that exits goes, and its neighbour takes over.
        third.view.send(txt: "\u{15}exit\r")
        check(await wait(5) { group.panes.count == 2 && !group.contains(third) }, "a pane whose shell exits closes")
        check(group.contains(c.activeTab ?? base) && c.groups.count == tabsBefore, "the tab stays with its other panes")
        window.makeFirstResponder(second.view)
        c.closeTab(nil)
        check(await wait(3) { group.panes.count == 1 } && group.focused === base && window.firstResponder === base.view,
              "⌘W closes the focused pane; the other takes the keyboard")
        check(!group.paneView(base).dimmed, "a single pane is never shaded")
    }

    private static func screenshotAllStates(_ c: TerminalWindowController, dir: URL) async {
        let busyAgent = dir.appendingPathComponent("busy")
        try? FileManager.default.createDirectory(at: busyAgent, withIntermediateDirectories: true)
        try? "#!/bin/sh\nwhile true; do printf '\\r\\342\\234\\273 Working (esc to interrupt) %s' $(date +%S); sleep 0.3; done\n"
            .write(to: busyAgent.appendingPathComponent("codex"), atomically: true, encoding: .utf8)
        chmod(busyAgent.appendingPathComponent("codex").path, 0o755)
        let commands = ["sleep 1", "sleep 1; false", "sleep 0.5; printf '\\a'", "PATH=\(busyAgent.path):$PATH codex"]
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

    // MARK: editor

    private static func editorChecks(_ c: TerminalWindowController, proj: URL, tab: TerminalTab) async {
        guard let window = c.window else { return }
        let php = proj.appendingPathComponent("src/app.php")
        let source = "<?php\r\n\r\nfunction greet(string $name): string {\r\n    return \"Hello, \" . $name; // hi\r\n}\r\n"
        try? Data(source.utf8).write(to: php)
        let topInset = c.tabBar.leadingInset
        c.openFile(php)
        let area = c.editorArea
        guard let editor = area.activeEditor else { return check(false, "a file opens in the editor") }
        let doc = editor.document
        check(!area.isHidden && doc.name == "app.php" && doc.language == "php", "a file opens in the editor, as PHP", doc.language ?? "plain")
        check(c.tabBar.leadingInset == 8 && area.tabBar.leadingInset == topInset, "the editor's tabs take the top; the terminal's move below")
        check(window.firstResponder === editor.textView && c.isEditorFocused, "the editor has the keyboard")
        check(doc.format.lineEnding == .crlf && !doc.text.contains("\r"), "Windows line endings are edited as plain newlines")
        check(SyntaxEngine.shared != nil, "syntax highlighting loads its grammars", SyntaxEngine.resourceFolder?.path ?? "no Highlighting folder")
        note("grammars from \(SyntaxEngine.resourceFolder?.path ?? "nowhere")")
        if Bundle.main.bundlePath.hasSuffix(".app") {
            check(SyntaxEngine.resourceFolder?.path.hasPrefix(Bundle.main.bundlePath) == true, "the app uses its own copy of the grammars")
        }

        // Colours: keyword, string and comment in the theme's colours.
        let text = doc.text as NSString
        func color(of word: String) -> String? {
            let r = text.range(of: word)
            guard r.location != NSNotFound, let layout = editor.textView.layoutManager,
                  let color = layout.temporaryAttribute(.foregroundColor, atCharacterIndex: r.location, effectiveRange: nil) as? NSColor,
                  let rgb = color.usingColorSpace(.sRGB) else { return nil }
            return String(format: "%02X%02X%02X", Int(round(rgb.redComponent * 255)), Int(round(rgb.greenComponent * 255)), Int(round(rgb.blueComponent * 255)))
        }
        _ = await wait(5) { doc.highlighter?.pendingLines == 0 }
        check(color(of: "function") == "CF8E6D", "keywords are coloured", color(of: "function") ?? "none")
        check(color(of: "\"Hello") == "6AAB73", "strings are coloured", color(of: "\"Hello") ?? "none")
        check(color(of: "// hi") == "7A7E85", "comments are coloured", color(of: "// hi") ?? "none")
        check(color(of: "greet") == "56A8F5", "function names are coloured", color(of: "greet") ?? "none")

        // Typing, auto-indent, undo back to clean.
        let view = editor.textView
        let braceLine = text.range(of: "string {")
        view.setSelectedRange(NSRange(location: braceLine.location + braceLine.length, length: 0))
        view.insertNewline(nil)
        let afterReturn = (doc.text as NSString).substring(with: (doc.text as NSString).lineRange(for: view.selectedRange()))
        check(afterReturn == "    \n", "Return after { indents one more level", afterReturn.debugDescription)
        check(doc.isDirty && area.tabBar.items.first?.modified == true, "an edit marks the tab as unsaved")
        doc.undoManager.undo()
        check(!doc.isDirty && doc.text == text as String, "undo back to the saved text is clean again")

        // ⌘/ comments the line in the file's language; again uncomments.
        view.go(toLine: 4)
        check(doc.lines.line(at: view.selectedRange().location) == 3, "go to line", "\(view.selectedRange())")
        view.toggleComment(nil)
        check((doc.text as NSString).substring(with: doc.lines.range(ofLine: 3)).hasPrefix("    // return"), "⌘/ comments the line out",
              (doc.text as NSString).substring(with: doc.lines.range(ofLine: 3)))
        view.toggleComment(nil)
        check(doc.text == text as String, "and back in")

        // Edit › Find › Replace… (⌥⌘F): the find bar grows its Replace row. Only the editor has the action, and
        // a sheet in front of it turns the item off (the menu would otherwise find the editor behind the sheet).
        if let inEditor = replaceIsOn(with: view, in: window), let inTerminal = replaceIsOn(with: c.activeTab?.view ?? tab.view, in: window) {
            check(inEditor && !inTerminal, "Replace… is on in the editor, off in the terminal", "editor \(inEditor), terminal \(inTerminal)")
            window.makeFirstResponder(view)
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
            window.beginSheet(sheet) { _ in }
            _ = await wait(3) { sheet.isKeyWindow }
            let replaceItem = KeyboardShortcuts.shared.commands.first { $0.id == "replaceInFile:" }?.item
            replaceItem?.menu?.update()
            check(sheet.isKeyWindow && replaceItem?.isEnabled == false, "and off while a sheet in front of the editor has the keyboard")
            window.endSheet(sheet)
            _ = await wait(3) { window.isKeyWindow }
        } else {
            note("skipped Replace…'s menu item checks: the app is not frontmost")
        }
        check(KeyboardShortcuts.shared.commands.first { $0.id == "replaceInFile:" }?.defaultChord == KeyChord(key: "f", command: true, option: true),
              "Replace… is ⌥⌘F")
        func finderAction(_ action: NSTextFinder.Action) -> NSMenuItem {
            let item = NSMenuItem()
            item.tag = action.rawValue
            return item
        }
        let scroll = view.enclosingScrollView
        window.makeFirstResponder(view)
        view.performFindPanelAction(finderAction(.showFindInterface))
        _ = await wait(3) { scroll?.isFindBarVisible == true && (scroll?.findBarView?.frame.height ?? 0) > 0 }
        let findHeight = scroll?.findBarView?.frame.height ?? 0
        check(findHeight > 0, "⌘F's find bar opens first", "\(findHeight) points high")
        view.replaceInFile(nil)
        check(await wait(3) { (scroll?.findBarView?.frame.height ?? 0) > findHeight + 4 }, "⌥⌘F opens the find bar with its Replace field",
              "find bar \(findHeight) then \(scroll?.findBarView?.frame.height ?? 0) points high")
        view.performFindPanelAction(finderAction(.hideFindInterface))
        _ = await wait(2) { scroll?.isFindBarVisible == false }
        // ⌘F starts from a selected name, as ⇧⌘F does (the lightweight way to find where it is used); a
        // selection over more than one line leaves the search as it was.
        let findBoard = NSPasteboard(name: .find)
        let findBefore = findBoard.string(forType: .string)
        view.setSelectedRange((view.string as NSString).range(of: "greet"))
        view.performFindPanelAction(finderAction(.showFindInterface))
        check(findBoard.string(forType: .string) == "greet", "⌘F with a name selected searches for that name",
              findBoard.string(forType: .string) ?? "nothing")
        view.setSelectedRange(NSRange(location: 0, length: min(20, (view.string as NSString).length)))
        view.performFindPanelAction(finderAction(.showFindInterface))
        check(findBoard.string(forType: .string) == "greet", "a selection of more than one line leaves the search as it was",
              findBoard.string(forType: .string) ?? "nothing")
        view.performFindPanelAction(finderAction(.hideFindInterface))
        _ = await wait(2) { scroll?.isFindBarVisible == false }
        findBoard.clearContents()
        if let findBefore { findBoard.setString(findBefore, forType: .string) }
        window.makeFirstResponder(view)

        // Save keeps the file's CRLF line endings.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("// saved\n", replacementRange: NSRange(location: 0, length: 0))
        c.saveDocument(nil)
        let saved = (try? Data(contentsOf: php)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(!doc.isDirty && saved.hasPrefix("// saved\r\n<?php\r\n") && !saved.contains("\r\r"), "⌘S saves, keeping CRLF", saved.prefix(30).debugDescription)

        // An agent changes the file: a clean editor follows; one with edits asks.
        try? Data((saved + "// agent\r\n").utf8).write(to: php)
        check(await wait(4) { doc.text.hasSuffix("// agent\n") }, "a change on disk shows up in a clean editor")
        view.insertText("mine ", replacementRange: NSRange(location: 0, length: 0))
        try? Data((saved + "// agent again\r\n").utf8).write(to: php)
        check(await wait(4) { doc.conflict == .changedOnDisk }, "with unsaved edits, a change on disk asks instead")
        check(doc.text.hasPrefix("mine "), "and keeps the edits meanwhile")
        doc.reload()
        check(doc.text.hasSuffix("// agent again\n") && !doc.isDirty && doc.conflict == nil, "Reload from Disk takes the new version")
        let reloadedStyle = doc.storage.attribute(.paragraphStyle, at: max(0, doc.storage.length - 3), effectiveRange: nil) as? NSParagraphStyle
        check((reloadedStyle?.minimumLineHeight ?? 0) > 0, "reloaded lines keep the editor's line height and indent styling")

        // ⌘-click on "…/app.php:4:10" in the terminal opens it there ("function greet": line 4 after the save).
        view.setSelectedRange(NSRange(location: 0, length: 0))
        tab.view.requestOpenLink(source: tab.view, link: php.path + ":4:10", params: [:])
        let caret = view.selectedRange().location
        let caretLine = doc.lines.line(at: caret)
        check(caretLine == 3 && caret - doc.lines.starts[3] == 9, "file:line:column links open the editor there",
              "line \(caretLine + 1), column \(caret - doc.lines.starts[caretLine] + 1), base \(tab.liveDirectory)")

        // Renaming the file in the sidebar keeps the editor on it.
        c.sidebar.rename(php, to: "main.php")
        check(doc.name == "main.php", "a file renamed in the sidebar stays open under its new name", doc.name)
        await pause(1.2)
        check(doc.conflict == nil, "and is not reported as deleted")

        // ⌘⇧F from the editor: the word at the caret is the query; this file, then its type, then the rest.
        try? "greet\n".write(to: proj.appendingPathComponent("a-greet.md"), atomically: true, encoding: .utf8)
        try? "<?php greet('x');\n".write(to: proj.appendingPathComponent("src/z.php"), atomically: true, encoding: .utf8)
        let greetAt = (doc.text as NSString).range(of: "greet")
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: greetAt.location + 2, length: 0))
        c.findInFiles(nil)
        check(c.finder.queryText == "greet", "⌘⇧F in the editor searches for the word at the caret", c.finder.queryText)
        _ = await wait(10) { !c.finder.isSearching && c.finder.fileCount >= 3 }
        let listed = c.finder.listedFiles
        check(listed.first == "src/main.php" && listed.firstIndex(of: "src/z.php").map { $0 < (listed.firstIndex(of: "a-greet.md") ?? 0) } == true,
              "results list this file, then .php files, then the rest", listed.joined(separator: ", "))
        if let panel = c.finder.window { await screenshot(panel, suffix: "-find") }
        c.finder.close()
        window.makeKeyAndOrderFront(nil)
        try? FileManager.default.removeItem(at: proj.appendingPathComponent("a-greet.md"))
        try? FileManager.default.removeItem(at: proj.appendingPathComponent("src/z.php"))

        // With no agent running, ⌥⌘K stays on in the editor and says why nothing was sent; with the keyboard in
        // the terminal, where it sends nothing, it is off.
        if c.agentTab == nil {
            c.openFile(proj.appendingPathComponent("src/main.php"))
            if let sendFrom = area.activeEditor { window.makeFirstResponder(sendFrom.textView) }
            let sendItem = NSMenuItem(title: "Send to Agent", action: #selector(TerminalWindowController.sendToAgent(_:)), keyEquivalent: "")
            check(c.isEditorFocused && c.validateMenuItem(sendItem), "Send to Agent stays on in the editor with no agent running",
                  "editor focused \(c.isEditorFocused)")
            c.sendToAgent(nil)
            func texts(_ view: NSView) -> [String] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0.stringValue] } ?? texts($0) } }
            check(await wait(2) { window.attachedSheet?.contentView.map(texts)?.contains("No agent is running in this window") == true },
                  "and sending says no agent is running", window.attachedSheet?.contentView.map(texts)?.joined(separator: " | ") ?? "no sheet")
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            _ = await wait(2) { window.attachedSheet == nil }
            window.makeFirstResponder(tab.view)
            check(!c.isEditorFocused && !c.validateMenuItem(sendItem), "and off with the keyboard in the terminal, where it would only beep")
        } else {
            check(false, "Send to Agent with no agent: an agent tab was still running", c.agentTab?.status.program ?? "")
        }

        // Send to Agent: an "agent" (cat under the name claude, so the tty echoes what it is given) in a tab.
        let fakeBin = proj.deletingLastPathComponent().appendingPathComponent("fake-agent-bin")
        try? FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: fakeBin.appendingPathComponent("claude"), withDestinationURL: URL(fileURLWithPath: "/bin/cat"))
        let agentTab = c.addTab(directory: proj.path)
        _ = await wait(20) { agentTab.status.integrated }
        // Its output goes nowhere: cat would write back the paste markers it is given, and "ESC [ 200 ~" on the
        // screen deletes columns (DECDC) on every row. The tty's echo shows what the agent was given.
        agentTab.view.send(txt: "\u{15}PATH=\(fakeBin.path):$PATH claude >/dev/null\r")
        _ = await wait(5) { agentTab.status.running && agentTab.status.kind == .agent }
        check(c.agentTab === agentTab, "the agent tab is found", agentTab.status.program)
        c.openFile(proj.appendingPathComponent("src/main.php"))
        if let sendEditor = area.activeEditor {
            let lines = sendEditor.document.lines
            sendEditor.textView.setSelectedRange(NSRange(location: lines.starts[2], length: lines.starts[4] - lines.starts[2]))
            c.sendEditorSelection()
            check(await wait(4) { agentTab.screenTail(4).joined().contains("@src/main.php#L3-4") }, "Send to Agent types the selection's lines in Claude's syntax",
                  agentTab.screenTail(3).joined(separator: " | "))
            check(c.activeTab === agentTab && window.firstResponder === agentTab.view, "and the agent's tab takes the keyboard for the instruction")
        }
        // From a diff: the selected lines of its new side (a file git doesn't know yet: every line is new).
        let fresh = proj.appendingPathComponent("src/send-diff.txt")
        if let git = GitRunner.locateGit() {
            func run(_ args: String...) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: git)
                p.arguments = ["-C", proj.path] + args
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
            }
            try? "one\ntwo\nthree\nfour\n".write(to: fresh, atomically: true, encoding: .utf8)
            c.showChanges(of: fresh)
            let freshDiff = area.activeDiff
            _ = await wait(5) { freshDiff?.hunkCount == 1 }
            if let freshDiff, let side = freshDiff.focusView as? NSTextView {
                let text = side.string as NSString
                let from = text.range(of: "two"), to = text.range(of: "three\n")
                if from.location != NSNotFound, to.location != NSNotFound {
                    side.setSelectedRange(NSRange(location: from.location, length: NSMaxRange(to) - from.location))
                }
                window.makeFirstResponder(side)
                c.sendEditorSelection()
                check(await wait(4) { agentTab.screenTail(4).joined().contains("@src/send-diff.txt#L2-3") },
                      "Send to Agent from a diff types the new side's selected lines", agentTab.screenTail(3).joined(separator: " | "))

                // From Staged the lines are the index's, not the file's: they go along as code, line by line, to an
                // agent that takes pastes (as every agent does; the tty under cat says it does).
                try? "one\nstaged two\nstaged three\nfour\n".write(to: fresh, atomically: true, encoding: .utf8)
                run("add", "src/send-diff.txt")
                try? "one\ntwo\nthree\nfour\n".write(to: fresh, atomically: true, encoding: .utf8)
                freshDiff.base = .staged
                _ = await wait(5) { freshDiff.sideTexts.1.contains("staged two\nstaged three\n") }
                let staged = side.string as NSString
                let start = staged.range(of: "staged two"), end = staged.range(of: "staged three\n")
                if start.location != NSNotFound, end.location != NSNotFound {
                    side.setSelectedRange(NSRange(location: start.location, length: NSMaxRange(end) - start.location))
                }
                window.makeFirstResponder(side)
                let code = freshDiff.contextItem()?.code
                agentTab.view.feed(text: "\u{1b}[?2004h")
                c.sendEditorSelection()
                // The fence as the tty echoes it: each line on a row of its own, after the ``` row.
                func onTheirOwnRows() -> Bool {
                    let rows = agentTab.screenTail(10)
                    guard let at = rows.firstIndex(of: "staged two"), rows.indices.contains(at + 1) else { return false }
                    return rows[at + 1] == "staged three" && rows[..<at].joined().contains("```")
                }
                let pasted = await wait(4) { onTheirOwnRows() }
                check(code == "staged two\nstaged three" && pasted, "from Staged, the selected lines reach the agent with their line breaks",
                      "\(code.debugDescription) | " + agentTab.screenTail(6).joined(separator: " | "))
                agentTab.view.feed(text: "\u{1b}[?2004l")
                run("reset", "-q", "--", "src/send-diff.txt")
                area.close(freshDiff)
            } else {
                check(false, "a new file opens as a diff", area.activeName ?? "nothing in front")
            }
            try? FileManager.default.removeItem(at: fresh)
        }
        c.sidebar(c.sidebar, sendToAgent: [(proj.appendingPathComponent("src"), true)])
        check(await wait(4) { agentTab.screenTail(4).joined().contains("@src/") }, "a folder from the sidebar goes in as @src/")
        check(c.agentText([ContextItem(path: "app/User.php", lines: 10...12)], for: "codex") == "app/User.php:10-12",
              "Codex and other agents get path:lines")
        await claudeLinkChecks(c, proj: proj, agentTab: agentTab)
        agentTab.view.send(txt: "\u{03}")
        _ = await wait(4) { !agentTab.status.running }
        c.requestClose(agentTab)
        try? FileManager.default.removeItem(at: fakeBin)

        // Line height: every line the chosen multiple of the font's height, text centred in it.
        if let layout = view.layoutManager, layout.numberOfGlyphs > 0 {
            let delegate = AppDelegate.shared!
            let savedHeight = delegate.editorLineHeight
            for factor: CGFloat in [1.0, 1.5] {
                delegate.editorLineHeight = factor
                layout.ensureLayout(for: view.textContainer!)
                let fragment = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                let font = EditorDocument.font
                let natural = ceil(font.ascender - font.descender + font.leading)
                check(abs(fragment.height - max(natural, round(natural * factor))) < 0.5, "line height \(factor)× sets each line's height",
                      "\(fragment.height) for natural \(natural)")
            }
            delegate.editorLineHeight = savedHeight
        }

        // Soft wrap: a long line wraps at the edge (the default) or scrolls sideways when it is off.
        let wide = proj.appendingPathComponent("wide.md")
        try? (String(repeating: "lorem ipsum dolor sit amet ", count: 40) + "\nshort\n").write(to: wide, atomically: true, encoding: .utf8)
        c.openFile(wide)
        if let wideEditor = area.activeEditor, wideEditor.document.name == "wide.md", let layout = wideEditor.textView.layoutManager,
           let container = wideEditor.textView.textContainer {
            func rows() -> Int {
                layout.ensureLayout(for: container)
                var count = 0, index = 0
                let glyphs = layout.glyphRange(forCharacterRange: wideEditor.document.lines.range(ofLine: 0), actualCharacterRange: nil)
                index = glyphs.location
                while index < NSMaxRange(glyphs) {
                    var fragment = NSRange()
                    layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &fragment)
                    index = NSMaxRange(fragment)
                    count += 1
                }
                return count
            }
            let app = AppDelegate.shared!
            let saved = app.softWrap
            app.softWrap = true
            area.applyWrap()
            let wrapped = rows()
            check(wrapped > 1 && wideEditor.textView.frame.width <= wideEditor.scrollView.contentSize.width + 1,
                  "soft wrap: a long line wraps at the edge", "\(wrapped) rows")
            if let layout = wideEditor.textView.layoutManager, layout.numberOfGlyphs > 0 {
                let firstRow = layout.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
                var range = NSRange()
                layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: &range)
                let secondRow = layout.lineFragmentUsedRect(forGlyphAt: NSMaxRange(range), effectiveRange: nil)
                check(secondRow.minX > firstRow.minX + 4, "a wrapped line continues indented, not at the margin",
                      "first \(firstRow.minX), second \(secondRow.minX)")
            }
            app.softWrap = false
            area.applyWrap()
            check(rows() == 1 && wideEditor.textView.frame.width > wideEditor.scrollView.contentSize.width,
                  "without it, the line scrolls sideways", "\(rows()) rows")
            // The View menu shows the state (validation reaches the app delegate).
            if let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu,
               let wrapItem = view.items.first(where: { $0.action == #selector(AppDelegate.toggleSoftWrap(_:)) }) {
                app.softWrap = true
                view.update()
                let shownOn = wrapItem.state == .on
                app.softWrap = false
                view.update()
                check(shownOn && wrapItem.state == .off, "View ▸ Soft Wrap has a checkmark exactly when it is on")
            } else {
                check(false, "View ▸ Soft Wrap is in the menu")
            }
            app.softWrap = saved
            area.applyWrap()
            area.closeActive()
        } else {
            check(false, "a markdown file opens")
        }
        try? FileManager.default.removeItem(at: wide)

        // nxtrm: a file at a line, in the window whose project holds it; a folder opens as a project.
        let delegate = AppDelegate.shared!
        let recentsBefore = UserDefaults.standard.stringArray(forKey: "recentProjects")
        defer { UserDefaults.standard.set(recentsBefore, forKey: "recentProjects") }
        let cliFile = proj.appendingPathComponent("src/cli.txt")
        try? (1...10).map { "line \($0)" }.joined(separator: "\n").write(to: cliFile, atomically: true, encoding: .utf8)
        delegate.handle(OpenCommand(items: [OpenRequest(path: cliFile.path, line: 7, column: 3)]))
        if let cliEditor = area.activeEditor, cliEditor.document.name == "cli.txt" {
            let at = cliEditor.textView.selectedRange().location
            check(cliEditor.document.lines.line(at: at) == 6 && at - cliEditor.document.lines.starts[6] == 2, "nxtrm file:7:3 opens the file there")
            area.closeActive()
        } else {
            check(false, "nxtrm file:7:3 opens the file", area.activeEditor?.document.name ?? "nothing")
        }
        let windows = delegate.controllers.count
        delegate.handle(OpenCommand(items: [OpenRequest(path: proj.path, isDirectory: true)]))
        if c.project == proj.path {
            check(delegate.controllers.count == windows, "nxtrm on an open project goes to its window")
        } else {
            let opened = delegate.controllers.first { $0.project == canonicalPath(proj.path) }
            check(opened != nil, "nxtrm on a folder opens it as a project")
            opened?.window?.close()
            check(await wait(8) { delegate.controllers.count == windows }, "and its window closes again")
        }
        if let script = CommandLineTool.script {
            let bin = script.deletingLastPathComponent().path
            check(c.tabs.allSatisfy { $0.environmentPath.split(separator: ":").contains(Substring(bin)) }, "nxtrm is on PATH in every tab")
            // The real thing, from a shell: the script runs this app's binary as the tool, which hands the
            // request to this running app.
            let shellFile = proj.appendingPathComponent("src/from-shell.txt")
            try? "a\nb\nc\n".write(to: shellFile, atomically: true, encoding: .utf8)
            let run = Process()
            run.executableURL = script
            run.arguments = [shellFile.path + ":2"]
            run.standardOutput = FileHandle.nullDevice
            run.standardError = FileHandle.nullDevice
            try? run.run()
            run.waitUntilExit()
            check(run.terminationStatus == 0, "the nxtrm script runs", "exit \(run.terminationStatus)")
            check(await wait(5) { area.activeEditor?.document.name == "from-shell.txt" }, "nxtrm from a shell opens the file in the running app",
                  area.activeEditor?.document.name ?? "nothing")
            if area.activeEditor?.document.name == "from-shell.txt" { area.closeActive() }
            try? FileManager.default.removeItem(at: shellFile)
        }
        try? FileManager.default.removeItem(at: cliFile)
        await commandLineLinkChecks(c)

        // What the editor cannot show does not open in it.
        let png = proj.appendingPathComponent("logo.png")
        try? Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]).write(to: png)
        check(area.open(png) == .notText && area.editors.count == 1, "binary files are not opened as text")
        try? FileManager.default.removeItem(at: png)

        await diffChecks(c, proj: proj)

        // A long file colours in the background without blocking typing.
        let long = proj.appendingPathComponent("long.ts")
        let body = (1...6000).map { "export function f\($0)(x: number): string { return `v${x}` + \"\($0)\"; } // \($0)" }.joined(separator: "\n")
        try? body.write(to: long, atomically: true, encoding: .utf8)
        let started = Date()
        c.openFile(long)
        let opened = Date().timeIntervalSince(started)
        guard let longEditor = area.activeEditor, longEditor.document.name == "long.ts" else { return check(false, "a long file opens") }
        check(opened < 1.5, "a 6,000-line file opens quickly", String(format: "%.2f s", opened))
        let coloured = await wait(15) { longEditor.document.highlighter?.pendingLines == 0 }
        check(coloured, "and is fully coloured in the background", String(format: "%.1f s", Date().timeIntervalSince(started)))
        let typed = Date()
        longEditor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        longEditor.textView.insertText("/* ", replacementRange: NSRange(location: 0, length: 0)) // recolours everything after
        let typing = Date().timeIntervalSince(typed)
        check(typing < 0.1, "typing that recolours the whole file stays responsive", String(format: "%.0f ms", typing * 1000))
        longEditor.document.undoManager.undo()
        // Scrolled to mid-line: the gutter's numbers must stay under the tab bar, not draw over it.
        let clip = longEditor.scrollView.contentView
        longEditor.textView.scroll(NSPoint(x: 0, y: 9.5))
        check(longEditor.scrollView.verticalRulerView?.clipsToBounds == true, "the line-number gutter is clipped to itself")
        if let ruler = longEditor.scrollView.verticalRulerView {
            let tv = longEditor.textView
            let rulerRight = ruler.convert(ruler.bounds, to: longEditor).maxX
            let codeLeft = tv.convert(NSPoint(x: tv.textContainerOrigin.x, y: 0), to: longEditor).x
            let codeTop = tv.convert(NSPoint(x: 0, y: tv.textContainerOrigin.y), to: clip).y
            check(codeLeft >= rulerRight - 0.5, "the code starts right of the gutter, not under it",
                  "ruler right \(rulerRight), code left \(codeLeft), clip x \(clip.bounds.minX)")
            tv.go(toLine: 1)
            _ = codeTop
            check(tv.convert(NSPoint(x: 0, y: tv.textContainerOrigin.y), to: clip).y >= clip.bounds.minY - 0.5,
                  "going to line 1 shows its top, not cut off under the tab bar", "\(tv.convert(NSPoint(x: 0, y: tv.textContainerOrigin.y), to: clip).y) vs \(clip.bounds.minY)")
            tv.scroll(NSPoint(x: 0, y: 9.5))
        }
        await screenshot(c, suffix: "-editor")

        // Every menu shortcut can be changed; the built menus are the defaults.
        let shortcuts = KeyboardShortcuts.shared
        let savedBindings = UserDefaults.standard.data(forKey: "keyBindings")
        UserDefaults.standard.removeObject(forKey: "keyBindings")
        shortcuts.apply()
        let ids = shortcuts.commands.map(\.id)
        check(shortcuts.commands.count >= 40 && Set(ids).count == ids.count, "every menu command is listed once (\(ids.count))")
        check(shortcuts.chord(for: "newTab:")?.display == "⌘T" && shortcuts.chord(for: "showNextTab:")?.display == "⇧⌘]",
              "today's shortcuts are the defaults", shortcuts.chord(for: "showNextTab:")?.display ?? "none")
        let newTabItem = shortcuts.commands.first { $0.id == "newTab:" }?.item
        shortcuts.set(KeyChord(key: "t", command: true, control: true), for: "newTab:")
        check(newTabItem?.keyEquivalent == "t" && newTabItem?.keyEquivalentModifierMask == [.command, .control],
              "a new shortcut goes straight into the menu", newTabItem.map { "\($0.keyEquivalentModifierMask.rawValue)" } ?? "")
        check(c.tabBar.newTabToolTip == "New tab (⌃⌘T)", "and into the tooltip that names it", c.tabBar.newTabToolTip ?? "none")
        check(shortcuts.bindings.owner(of: KeyChord(key: "f", command: true), defaults: shortcuts.defaults, except: "newTab:") == "performFindPanelAction:#1",
              "a shortcut already in use is found, so it can be moved deliberately")
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
                                        context: nil, characters: "}", charactersIgnoringModifiers: "}", isARepeat: false, keyCode: 30) {
            let pressed = KeyboardShortcuts.chord(from: event)
            check(pressed == KeyChord(key: "]", command: true, shift: true), "a pressed ⇧⌘] is recorded as ⇧⌘]", pressed?.display ?? "none")
        }
        shortcuts.set(nil, for: "clearBuffer:")
        check(shortcuts.commands.first { $0.id == "clearBuffer:" }?.item?.keyEquivalent == "", "a shortcut can be removed")
        AppDelegate.shared.showSettings(nil)
        check(NSApp.windows.contains { $0.title == "Settings" && $0.isVisible }, "Settings opens with ⌘, (Editor and Keyboard Shortcuts)")
        NSApp.windows.first { $0.title == "Settings" }?.close()
        shortcuts.resetAll()
        check(newTabItem?.keyEquivalentModifierMask == .command && shortcuts.chord(for: "clearBuffer:")?.display == "⌘K", "Restore All Defaults")
        let sidebarKey = shortcuts.chord(for: "toggleProjectSidebar:")?.display ?? "none"
        check(c.tabBar.newTabToolTip == "New tab (⌘T)" && c.sidebar.header.hideButton.toolTip == "Hide the project sidebar (\(sidebarKey))",
              "tooltips that name a key follow it back", "\(c.tabBar.newTabToolTip ?? "none") | \(c.sidebar.header.hideButton.toolTip ?? "none")")
        UserDefaults.standard.set(savedBindings, forKey: "keyBindings")
        shortcuts.apply()

        // The terminal can sit on any side of the editor, and the sidebar on either side of the window.
        let app = AppDelegate.shared!
        let savedPosition = app.terminalPosition, savedSide = app.sidebarSide
        let terminalPane = c.tabBar.superview!
        for position in AppDelegate.TerminalPosition.allCases {
            app.terminalPosition = position
            c.applyLayout()
            c.window?.layoutIfNeeded()
            let e = area.convert(area.bounds, to: nil), t = terminalPane.convert(terminalPane.bounds, to: nil)
            let placed: Bool
            switch position {
            case .bottom: placed = t.maxY <= e.minY + 1
            case .top: placed = t.minY >= e.maxY - 1
            case .right: placed = t.minX >= e.maxX - 1
            case .left: placed = t.maxX <= e.minX + 1
            }
            if let split = area.superview as? NSSplitView {
                check(split.dividerColor != Theme.background && split.dividerThickness >= 1,
                      "\(position.rawValue): a visible line between editor and terminal")
            }
            check(placed && e.width > 200 && t.width > 200 && e.height > 90 && t.height > 90, "terminal on the \(position.rawValue)",
                  "editor \(e.integral), terminal \(t.integral)")
            // Exactly one tab bar sits next to the traffic lights (the sidebar is on the left).
            check(c.tabBar.leadingInset == 8 && area.tabBar.leadingInset == 8, "\(position.rawValue): tab bars clear of the sidebar")
            check(c.tabBar.dragsWindow == (position != .bottom) && area.tabBar.dragsWindow == (position != .top),
                  "\(position.rawValue): only bars along the top drag the window")
            if position == .right { await screenshot(c, suffix: "-terminal-right") }
        }
        // The ⋯ menus offer the same choices where they apply.
        let terminalMenu = LayoutMenu.terminal()
        let titles = terminalMenu.items.map(\.title)
        check(["Bottom", "Right", "Left", "Top"].allSatisfy(titles.contains) && titles.contains { $0.hasPrefix("Move Project Sidebar") },
              "the terminal's ⋯ menu moves the terminal and the sidebar", titles.joined(separator: ", "))
        if let right = terminalMenu.items.first(where: { $0.title == "Right" }) {
            terminalMenu.performActionForItem(at: terminalMenu.index(of: right))
            check(app.terminalPosition == .right, "choosing Right there moves the terminal right")
        }
        let header = c.sidebar.header
        header.layoutSubtreeIfNeeded()
        let dotsCentre = NSPoint(x: header.moreButton.frame.midX, y: header.moreButton.frame.midY)
        check(header.hitTest(header.convert(dotsCentre, to: header.superview)) === header.moreButton,
              "the sidebar header's ⋯ button takes clicks (the rest of the header drags the window)")
        check(LayoutMenu.sidebar().items.contains { $0.title.hasPrefix("Move Project Sidebar") }, "the sidebar's ⋯ menu moves it")
        await screenshot(c, suffix: "-more")
        app.terminalPosition = .bottom
        app.sidebarSide = .right
        c.applyLayout()
        c.window?.layoutIfNeeded()
        let sidebarFrame = c.sidebar.convert(c.sidebar.bounds, to: nil), editorFrame = area.convert(area.bounds, to: nil)
        check(sidebarFrame.minX >= editorFrame.maxX - 1 && abs(sidebarFrame.width - app.sidebarWidth) < 2,
              "the sidebar can go on the right, at its width", "sidebar \(sidebarFrame.integral)")
        check(area.tabBar.leadingInset == 78 && c.sidebar.headerInset == 8, "with the sidebar on the right, the editor's tabs clear the traffic lights")
        await screenshot(c, suffix: "-sidebar-right")
        app.terminalPosition = savedPosition
        app.sidebarSide = savedSide
        c.applyLayout()

        // Closing the last file gives the terminal its space back.
        area.closeActive()
        area.closeActive()
        check(await wait(2) { area.isEmpty && area.isHidden }, "closing the last file hides the editor")
        check(c.tabBar.leadingInset == topInset, "and the terminal's tabs return to the top")
        try? FileManager.default.removeItem(at: long)
        try? FileManager.default.removeItem(at: proj.appendingPathComponent("src/main.php"))
    }

    // MARK: diff view

    private static func diffChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let git = GitRunner.locateGit() else { return }
        func run(_ args: String...) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", proj.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        let file = proj.appendingPathComponent("src/diff.txt")
        let original = (1...14).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try? original.write(to: file, atomically: true, encoding: .utf8)
        run("add", "src/diff.txt")
        run("commit", "-qm", "diff test")
        var lines = original.components(separatedBy: "\n")
        lines[1] = "line two"
        lines[11] = "line twelve"
        let changed = lines.joined(separator: "\n")
        try? changed.write(to: file, atomically: true, encoding: .utf8)

        c.showChanges(of: file)
        guard let diff = c.editorArea.activeDiff else { return check(false, "⌥⌘G shows the file’s changes") }
        check(await wait(5) { diff.hunkCount == 2 }, "the diff shows both changes", "\(diff.hunkCount) hunks")
        check(diff.sideTexts.0.contains("line 2\n") && diff.sideTexts.1.contains("line two\n")
              && diff.sideTexts.0.components(separatedBy: "\n").count == diff.sideTexts.1.components(separatedBy: "\n").count,
              "old on the left, new on the right, rows aligned")
        await screenshot(c, suffix: "-diff")

        // Send to Agent from the diff: the file, at the new side's selected lines.
        check(c.editorArea.activePath == file.path && diff.contextItem() == ContextItem(path: file.path),
              "Send to Agent from a diff sends its file when nothing is selected", c.editorArea.activePath ?? "nothing in front")
        if let side = diff.focusView as? NSTextView {
            let text = side.string as NSString
            let from = text.range(of: "line two"), to = text.range(of: "line 3\n")
            if from.location != NSNotFound, to.location != NSNotFound {
                side.setSelectedRange(NSRange(location: from.location, length: NSMaxRange(to) - from.location))
            }
            let item = diff.contextItem()
            check(item == ContextItem(path: file.path, lines: 2...3), "and the new side's lines when some are selected", "\(String(describing: item))")
            side.setSelectedRange(NSRange(location: 0, length: 0))
            // The same rows selected on the old side: the new side's lines in them.
            let old = diff.oldSideView, oldText = old.string as NSString
            let oldFrom = oldText.range(of: "line 2"), oldTo = oldText.range(of: "line 3\n")
            if oldFrom.location != NSNotFound, oldTo.location != NSNotFound {
                old.setSelectedRange(NSRange(location: oldFrom.location, length: NSMaxRange(oldTo) - oldFrom.location))
            }
            c.window?.makeFirstResponder(old)
            let fromOld = diff.contextItem()
            check(fromOld == ContextItem(path: file.path, lines: 2...3), "and from the old side, the new side's lines in the same rows",
                  "\(String(describing: fromOld))")
            old.setSelectedRange(NSRange(location: 0, length: 0))
            c.window?.makeFirstResponder(side)
        }
        if let window = c.window, let on = replaceIsOn(with: diff.focusView, in: window) { check(!on, "Replace… is off in a diff") }

        // Stage one hunk; it moves to Staged. Unstage it again.
        diff.base = .unstaged
        _ = await wait(5) { diff.hunkCount == 2 }
        diff.go(toHunk: 0)
        diff.perform(.stage)
        diff.base = .staged
        check(await wait(5) { diff.hunkCount == 1 && diff.sideTexts.1.contains("line two") }, "Stage Hunk stages just that change",
              "\(diff.hunkCount) staged")
        c.window?.makeFirstResponder(diff.focusView)
        c.showChanges(nil)
        check(diff.base == .staged && c.editorArea.activeDiff === diff, "⌥⌘G on the file's Staged diff leaves it on Staged",
              "\(diff.title), \(c.editorArea.activeDiff?.title ?? "no diff in front")")
        // The staged version is not the file on disk: Send to Agent says so and brings its lines along.
        if let side = diff.focusView as? NSTextView {
            let at = (side.string as NSString).range(of: "line two")
            if at.location != NSNotFound { side.setSelectedRange(at) }
            let item = diff.contextItem()
            check(item?.lines == 2...2 && item?.note == "as staged" && item?.code == "line two",
                  "from Staged, Send to Agent marks the lines as staged and sends them as code", "\(String(describing: item))")
            side.setSelectedRange(NSRange(location: 0, length: 0))
        }
        // Both changes staged, and lines selected across them: the lines between, not shown, are marked.
        diff.base = .unstaged
        _ = await wait(5) { diff.hunkCount == 1 && diff.sideTexts.1.contains("line twelve") && !diff.sideTexts.1.contains("line two") }
        diff.go(toHunk: 0)
        diff.perform(.stage)
        diff.base = .staged
        if await wait(5, { diff.hunkCount == 2 }), let side = diff.focusView as? NSTextView {
            let text = side.string as NSString
            let from = text.range(of: "line two"), to = text.range(of: "line twelve")
            if from.location != NSNotFound, to.location != NSNotFound {
                side.setSelectedRange(NSRange(location: from.location, length: NSMaxRange(to) - from.location))
            }
            let item = diff.contextItem()
            check(item?.lines == 2...12 && item?.code == "line two\nline 3\nline 4\nline 5\n⋯\nline 9\nline 10\nline 11\nline twelve",
                  "a selection across two hunks marks the lines between them with ⋯", "\(String(describing: item))")
            side.setSelectedRange(NSRange(location: 0, length: 0))
            diff.go(toHunk: 1)
            diff.perform(.unstage)
            _ = await wait(5) { diff.hunkCount == 1 }
        } else {
            check(false, "Stage Hunk stages the second change too", "\(diff.hunkCount) staged")
        }
        diff.go(toHunk: 0)
        diff.perform(.unstage)
        check(await wait(5) { diff.hunkCount == 0 }, "Unstage Hunk takes it back out")

        // Revert one change in the file; ⌘Z brings it back.
        diff.base = .head
        _ = await wait(5) { diff.hunkCount == 2 }
        diff.go(toHunk: 1)
        await pause(0.3)
        check(diff.currentHunk == 1, "the stepper's choice holds even when the whole diff fits on screen", "hunk \(diff.currentHunk + 1)")
        diff.perform(.revert)
        let reverted = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(reverted.contains("line 12\n") && reverted.contains("line two\n"), "Revert Hunk undoes just that change in the file")
        _ = await wait(5) { diff.hunkCount == 1 }
        c.window?.undoManager?.undo()
        check(((try? String(contentsOf: file, encoding: .utf8)) ?? "") == changed, "⌘Z brings the reverted change back")
        c.editorArea.closeActive()
        run("checkout", "--", "src/diff.txt")
    }

    // MARK: Claude Code link

    private static func claudeLinkChecks(_ c: TerminalWindowController, proj: URL, agentTab: TerminalTab) async {
        let server = ClaudeIDEServer.shared
        guard let port = server.port else { return check(false, "the Claude Code link is listening") }
        let lock = ClaudeIDEServer.lockFolder.appendingPathComponent("\(port).lock")
        let attributes = try? FileManager.default.attributesOfItem(atPath: lock.path)
        let lockJSON = (try? Data(contentsOf: lock)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check((attributes?[.posixPermissions] as? Int) == 0o600 && lockJSON?["ideName"] as? String == "Next Term"
              && lockJSON?["authToken"] as? String == server.token && lockJSON?["transport"] as? String == "ws",
              "the lock file announces Next Term to Claude Code, private to you (0600)")
        check(agentTab.claudePort == String(port), "tabs tell claude where Next Term listens (CLAUDE_CODE_SSE_PORT)", agentTab.claudePort ?? "none")

        // Strangers are refused: no token, a wrong token, or a browser page (it sends Origin).
        for (label, client) in [("no token", ClaudeTestClient(port: port, token: nil)),
                                ("a wrong token", ClaudeTestClient(port: port, token: String(repeating: "0", count: 64))),
                                ("a web page", ClaudeTestClient(port: port, token: server.token, origin: "https://evil.example"))] {
            client.send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25"]])
            await pause(0.6)
            check(client.received.isEmpty, "a client with \(label) gets nothing")
            client.close()
        }

        // Claude itself: handshake, then it says which process it is; that maps it to its tab.
        let claude = ClaudeTestClient(port: port, token: server.token)
        claude.send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                     "params": ["protocolVersion": "2025-11-25", "clientInfo": ["name": "claude-code", "version": "2.1.280"]]])
        let initialized = await wait(3) { claude.received.contains { ($0["id"] as? Int) == 1 } }
        let result = claude.received.first { ($0["id"] as? Int) == 1 }?["result"] as? [String: Any]
        check(initialized && result?["protocolVersion"] as? String == "2025-11-25", "Claude Code's handshake is answered")
        claude.send(["jsonrpc": "2.0", "id": 2, "method": "server/discover"])
        _ = await wait(2) { claude.received.contains { ($0["id"] as? Int) == 2 } }
        let unknown = claude.received.first { ($0["id"] as? Int) == 2 }?["error"] as? [String: Any]
        check(unknown?["code"] as? Int == -32601, "unknown methods get Method not found")
        claude.send(["jsonrpc": "2.0", "method": "ide_connected", "params": ["pid": Int(agentTab.view.process.shellPid)]])
        let mapped = await wait(3) { AppDelegate.shared.claudeClient(for: agentTab) != nil }
        check(mapped, "the connected claude is matched to the tab it runs in")

        // The editor's selection follows Claude: lines 2–3 of main.php, 0-based.
        c.openFile(proj.appendingPathComponent("src/main.php"))
        if let editor = c.editorArea.activeEditor {
            let lines = editor.document.lines
            c.window?.makeFirstResponder(editor.textView)
            editor.textView.setSelectedRange(NSRange(location: lines.starts[1], length: lines.starts[3] - lines.starts[1]))
            let shared = await wait(3) {
                let selection = claude.last("selection_changed")?["selection"] as? [String: Any]
                let start = selection?["start"] as? [String: Any], end = selection?["end"] as? [String: Any]
                return start?["line"] as? Int == 1 && end?["line"] as? Int == 3 && end?["character"] as? Int == 0
            }
            check(shared && claude.last("selection_changed")?["filePath"] as? String == editor.document.path,
                  "selecting lines in the editor tells Claude Code (⧉ 2 lines selected)",
                  "\(claude.last("selection_changed") ?? [:])")

            // ⌥⌘K with Claude connected: an @-mention in its prompt, nothing typed into the terminal.
            let screenBefore = agentTab.screenTail(3).joined()
            c.sendEditorSelection()
            let mentioned = await wait(3) { claude.last("at_mentioned")?["lineStart"] as? Int == 1 }
            check(mentioned && claude.last("at_mentioned")?["lineEnd"] as? Int == 2, "⌥⌘K sends the lines straight into Claude's prompt",
                  "\(claude.last("at_mentioned") ?? [:])")
            check(agentTab.screenTail(3).joined() == screenBefore, "and types nothing into the terminal")

            // A mention carries only the file and its lines: one with a note ("deleted") is typed instead.
            let mentions = claude.received.filter { $0["method"] as? String == "at_mentioned" }.count
            c.send([ContextItem(path: proj.appendingPathComponent("src/removed.txt").path, note: "deleted")])
            let typed = await wait(3) { agentTab.screenTail(4).joined().contains("@src/removed.txt (deleted)") }
            check(typed && claude.received.filter { $0["method"] as? String == "at_mentioned" }.count == mentions,
                  "with Claude connected, a deleted file is typed with its note, not mentioned", agentTab.screenTail(3).joined(separator: " | "))
        }

        await geminiLinkChecks(c)
        await copilotLinkChecks(c, proj: proj, agentTab: agentTab)
        await opencodeLinkChecks(c, proj: proj)
        await mcpChecks(c, proj: proj)
        await remoteChecks(c)
        if ProcessInfo.processInfo.environment["NEXTTERM_REAL_CLAUDE"] == "1" { await realClaudeCheck(c, proj: proj) }

        // Claude's proposed edits: shown as a diff to accept or reject; the file is never written by Next Term.
        let target = proj.appendingPathComponent("src/main.php")
        let before = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        let proposed = before.replacingOccurrences(of: "Hello", with: "Hi")
        func openDiff(_ id: Int, _ tab: String) {
            claude.send(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": "openDiff", "arguments": [
                "old_file_path": target.path, "new_file_path": target.path, "new_file_contents": proposed, "tab_name": tab]]])
        }
        func answer(_ id: Int) -> [String]? {
            ((claude.received.first { ($0["id"] as? Int) == id }?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
        }
        openDiff(30, "✻ [Claude Code] main.php (abc123) ⧉")
        let shown = await wait(4) { c.editorArea.proposals.count == 1 }
        if shown, let pane = c.editorArea.proposals.first {
            check(await wait(4) { pane.hunkCount >= 1 } && pane.sideTexts.1.contains("Hi"), "Claude's proposed edit opens as a diff to review")
            check(pane.changedLineCount == 1, "only the changed line is marked (CRLF files too)", "\(pane.changedLineCount) lines")
            await screenshot(c, suffix: "-proposal")
            pane.decide(true)
            c.editorArea.close(pane)
            check(await wait(3) { answer(30) == ["FILE_SAVED", proposed] }, "Accept tells Claude to write it (FILE_SAVED and the text)", "\(answer(30) ?? [])")
            check(((try? String(contentsOf: target, encoding: .utf8)) ?? "") == before, "Next Term itself never writes the file")
        } else {
            check(false, "Claude's proposed edit opens as a diff to review")
        }
        openDiff(31, "second")
        _ = await wait(4) { c.editorArea.proposals.count == 1 }
        if let pane = c.editorArea.proposals.first { c.editorArea.close(pane) } // closing the tab
        check(await wait(3) { answer(31) == ["DIFF_REJECTED"] }, "closing or rejecting it says DIFF_REJECTED", "\(answer(31) ?? [])")
        openDiff(32, "third")
        _ = await wait(4) { c.editorArea.proposals.count == 1 }
        claude.send(["jsonrpc": "2.0", "id": 33, "method": "tools/call", "params": ["name": "close_tab", "arguments": ["tab_name": "third"]]])
        check(await wait(3) { c.editorArea.proposals.isEmpty }, "when you answer in the terminal, Claude closes the diff tab")

        // .env files are never shared.
        let env = proj.appendingPathComponent(".env")
        try? "SECRET=1\n".write(to: env, atomically: true, encoding: .utf8)
        c.openFile(env)
        if let editor = c.editorArea.activeEditor, editor.document.name == ".env" {
            editor.textView.setSelectedRange(NSRange(location: 0, length: 6))
            _ = await wait(2) { claude.last("selection_changed")?["filePath"] == nil }
            check(claude.last("selection_changed")?["filePath"] == nil && claude.last("selection_changed")?["text"] == nil,
                  "a selection in .env is never shared")
            c.editorArea.closeActive()
        }
        try? FileManager.default.removeItem(at: env)
        claude.close()
    }

    /// Opt-in (NEXTTERM_REAL_CLAUDE=1): the real `claude` CLI connects and shows the editor's selection.
    /// Started in ~/Code (a folder the user trusts) and quit with Ctrl-C before any message is sent.
    private static func realClaudeCheck(_ c: TerminalWindowController, proj: URL) async {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Code").path
        let tab = c.addTab(directory: home)
        _ = await wait(20) { tab.status.integrated }
        let before = Set(ClaudeIDEServer.shared.clients.map(\.id))
        tab.view.send(txt: "\u{15}claude\r")
        let connected = await wait(40) { ClaudeIDEServer.shared.clients.contains { !before.contains($0.id) && $0.ready } }
        check(connected, "the real claude CLI connects to Next Term", tab.screenTail(6).joined(separator: " | "))
        if connected, let editor = c.editorArea.activeEditor {
            c.window?.makeFirstResponder(editor.textView)
            let lines = editor.document.lines
            editor.textView.setSelectedRange(NSRange(location: 0, length: lines.starts[min(2, lines.count - 1)]))
            let pill = await wait(10) { tab.screenTail(12).joined(separator: "\n").range(of: #"⧉ ?\d+ lines? selected|In \w"#, options: .regularExpression) != nil }
            check(pill, "and its prompt shows the editor's selection (⧉)", tab.screenTail(8).joined(separator: " | "))
            check(!tab.screenTail(12).joined().contains("CHILD_SESSION"), "and it runs as a session of its own (no inherited sub-agent marker)")
            await screenshot(c, suffix: "-real-claude")
        }
        for _ in 0..<3 { tab.view.send(txt: "\u{03}"); await pause(0.6) }
        _ = await wait(8) { !tab.status.running }
        c.requestClose(tab)
    }

    // MARK: Gemini CLI / Qwen Code link

    private static func geminiLinkChecks(_ c: TerminalWindowController) async {
        let server = GeminiIDEServer.shared
        guard let port = server.port else { return check(false, "the Gemini/Qwen link is listening") }
        let discovery = GeminiIDEServer.geminiFolder.appendingPathComponent("gemini-ide-server-\(getpid())-\(port).json")
        let json = (try? Data(contentsOf: discovery)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let mode = (try? FileManager.default.attributesOfItem(atPath: discovery.path))?[.posixPermissions] as? Int
        check(mode == 0o600 && (json?["ideInfo"] as? [String: Any])?["displayName"] as? String == "Next Term"
              && json?["authToken"] as? String == server.token, "Gemini CLI finds Next Term (discovery file, private)")

        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
        for (label, extra, token, code) in [("no token", "", nil as String?, "401"), ("a web page", "Origin: https://evil.example\r\n", server.token, "403")] {
            let client = RawHTTPClient(port: port)
            client.send(RawHTTPClient.post(initialize, port: port, token: token, extra: extra))
            _ = await wait(2) { client.text.hasPrefix("HTTP/1.1") }
            check(client.text.hasPrefix("HTTP/1.1 \(code)"), "Gemini link: \(label) is refused (\(code))", String(client.text.prefix(30)))
            client.close()
        }
        let rpc = RawHTTPClient(port: port)
        rpc.send(RawHTTPClient.post(initialize, port: port, token: server.token))
        _ = await wait(2) { rpc.text.contains("protocolVersion") }
        check(rpc.text.hasPrefix("HTTP/1.1 200") && rpc.text.contains("Mcp-Session-Id:") && rpc.text.contains("2025-06-18"),
              "Gemini link: the handshake is answered, with a session")
        rpc.close()

        // The event stream: the editor's state now, and again when the selection changes.
        let stream = RawHTTPClient(port: port)
        stream.send("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(server.token)\r\nAccept: text/event-stream\r\n\r\n")
        check(await wait(2) { stream.text.contains("ide/contextUpdate") }, "Gemini link: the event stream opens with the editor's state")
        if let editor = c.editorArea.activeEditor {
            c.window?.makeFirstResponder(editor.textView)
            editor.textView.setSelectedRange(NSRange(location: 0, length: min(5, (editor.textView.string as NSString).length)))
            let selected = (editor.textView.string as NSString).substring(to: min(5, (editor.textView.string as NSString).length))
            check(await wait(3) { stream.text.contains("\"selectedText\":\"\(selected)") && stream.text.contains("\"isActive\":true") },
                  "Gemini link: a selection goes out to Gemini and Qwen (active file, caret, text)")
        }
        // Gemini's proposed edit: a diff to accept; the decision goes back on the stream.
        let target = canonicalPath(c.editorArea.activeEditor?.document.path ?? "")
        if !target.isEmpty {
            let call = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"openDiff","arguments":{"filePath":"\#(target)","newContent":"proposed by gemini\n"}}}"#
            let caller = RawHTTPClient(port: port)
            caller.send(RawHTTPClient.post(call, port: port, token: server.token))
            check(await wait(3) { c.editorArea.proposals.contains { $0.proposal?.author == "Gemini" } }, "Gemini's proposed edit opens as a diff")
            if let pane = c.editorArea.proposals.first(where: { $0.proposal?.author == "Gemini" }) {
                pane.decide(true)
                c.editorArea.close(pane)
                check(await wait(3) { stream.text.contains("ide/diffAccepted") && stream.text.contains("proposed by gemini") },
                      "accepting it tells Gemini (ide/diffAccepted with the text)")
            }
            caller.close()
        }
        stream.close()
    }

    /// Next Term's MCP server, driven the way an orchestrating agent drives it: `nxtrm mcp` over stdio.
    private static func mcpChecks(_ c: TerminalWindowController, proj: URL) async {
        let server = MCPControlServer.shared
        let mode = (try? FileManager.default.attributesOfItem(atPath: server.path))?[.posixPermissions] as? Int
        check(server.isRunning && server.path == mcpSocketPath && mode == 0o600, "MCP: the control socket is up, owner-only",
              "\(server.path) \(String(describing: mode))")
        guard let mcp = MCPTestClient(socket: server.path) else { return check(false, "MCP: `nxtrm mcp` starts") }
        defer { mcp.close() }
        let initialized = await mcp.call(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "selftest", "version": "1"]])
        check((initialized?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18", "MCP: `nxtrm mcp` answers initialize")
        let listed = await mcp.call(2, "tools/list", [:])
        let tools = ((listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        check(tools.count == MCPServer.tools.count && tools.contains("send_to_tab"), "MCP: the tools are listed", tools.joined(separator: ","))

        var nextID = 10
        func tool(_ name: String, _ arguments: [String: Any] = [:], timeout: Double = 15) async -> (json: [String: Any]?, text: String, isError: Bool) {
            nextID += 1
            let reply = await mcp.call(nextID, "tools/call", ["name": name, "arguments": arguments], timeout: timeout)
            let result = reply?["result"] as? [String: Any]
            let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "(no answer: \(reply ?? [:]))"
            let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            return (json, text, result?["isError"] as? Bool ?? true)
        }

        let tabs = await tool("list_tabs")
        let windows = tabs.json?["windows"] as? [[String: Any]] ?? []
        let ids = windows.flatMap { ($0["tabs"] as? [[String: Any]]) ?? [] }.compactMap { $0["id"] as? String }
        check(!tabs.isError && ids.contains(c.tabs[0].id.uuidString.lowercased()), "MCP: list_tabs shows every window's tabs with their state", tabs.text.prefix(300).description)

        // An orchestrator starts a worker in the project, without taking the user's tab away.
        let owner = AppDelegate.shared.controllers.first { $0.project.map { proj.path == $0 || proj.path.hasPrefix($0 + "/") } ?? false }
        let frontBefore = owner?.activeTab
        let started = await tool("new_tab", ["directory": proj.path, "command": "printf 'mcp-%s\\n' started", "title": "worker"])
        let workerID = started.json?["id"] as? String ?? ""
        let worker = AppDelegate.shared.controllers.flatMap(\.tabs).first { $0.id.uuidString.lowercased() == workerID }
        check(!started.isError && worker?.title == "worker", "MCP: new_tab opens a titled tab in the project", started.text)
        guard let worker else { return }
        check(MCPControl.isDriven(worker), "MCP: an agent drives the tab it opened (in Next Term, its agent finishing is not your news)")
        if let holder = AppDelegate.shared.controllers.first(where: { $0.tabs.contains { $0 === worker } }), holder.tabs.count > 1 {
            check(holder.activeTab !== worker && (holder !== owner || holder.activeTab === frontBefore),
                  "MCP: and leaves the tab you are on in front")
        }
        let waited = await tool("wait_for_tab", ["tab_id": workerID, "timeout_seconds": 10])
        let screen = await tool("read_tab", ["tab_id": workerID, "lines": 20])
        check(waited.json?["timed_out"] as? Bool == false && (screen.json?["screen"] as? String)?.contains("mcp-started") == true,
              "MCP: the command ran; wait_for_tab and read_tab see its output", waited.text + " / " + screen.text)

        // A pane beside the worker, so both can be watched.
        let beside = await tool("new_tab", ["directory": proj.path, "split_beside": workerID, "direction": "down"])
        let besideID = beside.json?["id"] as? String ?? ""
        let holder = AppDelegate.shared.controllers.first { $0.tabs.contains { $0 === worker } }
        let shared = holder?.group(of: worker)
        check(!beside.isError && shared?.panes.contains { $0.id.uuidString.lowercased() == besideID } == true && shared?.focused === worker,
              "MCP: new_tab can open a pane beside another tab (without taking the keyboard)", beside.text)
        _ = await tool("close_tab", ["tab_id": besideID, "force": true])

        // A prompt with two lines arrives as one paste and runs on Return.
        _ = await tool("send_to_tab", ["tab_id": workerID, "text": "echo multi-1\necho multi-2"])
        _ = await tool("wait_for_tab", ["tab_id": workerID, "timeout_seconds": 10])
        let lines = worker.screenTail(30)
        check(lines.contains("multi-1") && lines.contains("multi-2"), "MCP: send_to_tab types a multi-line prompt and submits it",
              lines.suffix(6).joined(separator: " | "))

        // Keys: Ctrl-C stops what runs; closing a busy tab needs force.
        _ = await tool("send_to_tab", ["tab_id": workerID, "text": "sleep 30"])
        _ = await wait(5) { worker.status.running }
        let refused = await tool("close_tab", ["tab_id": workerID])
        check(refused.isError && refused.text.contains("force"), "MCP: close_tab will not stop a running command unless forced", refused.text)
        _ = await tool("press_keys", ["tab_id": workerID, "keys": ["ctrl+c"]])
        check(await wait(5) { !worker.status.running }, "MCP: press_keys ctrl+c interrupts it")
        let bogus = await tool("press_keys", ["tab_id": workerID, "keys": ["\u{1b}[200~"]])
        check(bogus.isError, "MCP: raw escape sequences are not keys", bogus.text)
        let unknown = await tool("send_to_tab", ["tab_id": "no-such-tab", "text": "x"])
        check(unknown.isError, "MCP: an unknown tab is an error, not a guess")

        // The caller's own tab is marked, and it cannot type into itself.
        let out = proj.appendingPathComponent(".mcp-self.json")
        let binary = ShellQuote.quote(Bundle.main.executablePath ?? CommandLine.arguments[0])
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_tabs","arguments":{}}}"#
        worker.view.send(txt: "\u{15}printf '%s\\n' \(ShellQuote.quote(request)) | \(binary) --cli mcp > \(ShellQuote.quote(out.path))\r")
        _ = await wait(10) { ((try? String(contentsOf: out, encoding: .utf8)) ?? "").contains("\\\"you\\\"") }
        let selfText = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        check(selfText.contains("\\\"you\\\" : true") && selfText.contains(workerID), "MCP: an agent sees which tab is its own", String(selfText.prefix(200)))
        try? FileManager.default.removeItem(at: out)

        // The editor.
        let file = proj.appendingPathComponent("mcp-target.txt")
        try? "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        let opened = await tool("open_in_editor", ["path": file.path, "line": 2])
        let selection = await tool("get_editor_selection")
        let open = await tool("get_open_files")
        check(!opened.isError && selection.json?["file"] as? String == canonicalPath(file.path)
              && (selection.json?["start"] as? [String: Any])?["line"] as? Int == 2 && open.text.contains("mcp-target.txt"),
              "MCP: open_in_editor, get_editor_selection and get_open_files", selection.text)
        // A selection in a file that holds secrets is never handed over.
        let envFile = proj.appendingPathComponent(".env.local")
        try? "OPENAI_API_KEY=sk-test-not-real\n".write(to: envFile, atomically: true, encoding: .utf8)
        _ = await tool("open_in_editor", ["path": envFile.path])
        if let editor = c.editorArea.activeEditor, editor.document.path.hasSuffix(".env.local") {
            editor.textView.setSelectedRange(NSRange(location: 0, length: (editor.document.text as NSString).length))
            let secret = await tool("get_editor_selection")
            check(secret.json?["text"] == nil && secret.json?["withheld"] != nil && !secret.text.contains("sk-test"),
                  "MCP: a selection in a .env file is withheld", secret.text)
            c.editorArea.close(editor)
        }
        try? FileManager.default.removeItem(at: envFile)
        let projects = await tool("list_projects")
        check((projects.json?["open"] as? [String])?.isEmpty == false, "MCP: list_projects", projects.text)

        // Project files and git, as an agent reads them (the worker's tab opened proj as a project).
        let readable = proj.appendingPathComponent("mcp-read.txt")
        let secrets = proj.appendingPathComponent(".env.mcp")
        try? "first\nsecond mcp-needle\nthird\n".write(to: readable, atomically: true, encoding: .utf8)
        try? "TOKEN=sk-abcdefghijklmnopqrstuvwx mcp-needle\n".write(to: secrets, atomically: true, encoding: .utf8)
        let page = await tool("read_file", ["path": "mcp-read.txt", "project": proj.path, "offset": 2, "limit": 1])
        check(!page.isError && page.json?["text"] as? String == "second mcp-needle" && page.json?["total_lines"] as? Int == 3
              && page.json?["next_offset"] as? Int == 3, "MCP: read_file reads a project file's lines from an offset", page.text)
        let refusedSecret = await tool("read_file", ["path": ".env.mcp", "project": proj.path])
        check(refusedSecret.isError && refusedSecret.text.contains("environment file"), "MCP: read_file refuses a secrets file and says why", refusedSecret.text)
        let refusedOutside = await tool("read_file", ["path": "/etc/hosts"])
        check(refusedOutside.isError && refusedOutside.text.contains("outside"), "MCP: read_file refuses files outside the open projects", refusedOutside.text)
        let found = await tool("find_in_files", ["query": "mcp-needle", "project": proj.path], timeout: 60)
        let hits = found.json?["matches"] as? [[String: Any]] ?? []
        check(!found.isError && hits.count == 1 && hits.first?["path"] as? String == "mcp-read.txt" && hits.first?["line"] as? Int == 2,
              "MCP: find_in_files gives file and line, and skips secrets files", found.text.prefix(400).description)
        let status = await tool("git_status", ["project": proj.path], timeout: 30)
        let changed = status.json?["files"] as? [[String: Any]] ?? []
        check(!status.isError && (status.json?["branch"] is String || status.json?["detached"] as? Bool == true)
              && changed.contains { $0["path"] as? String == "mcp-read.txt" && $0["state"] as? String == "untracked" },
              "MCP: git_status gives the branch and each change", status.text.prefix(400).description)
        let diff = await tool("get_diff", ["path": "mcp-read.txt", "project": proj.path], timeout: 30)
        check(!diff.isError && (diff.json?["diff"] as? String)?.contains("+second mcp-needle") == true, "MCP: get_diff gives a file's unified diff",
              diff.text.prefix(400).description)
        try? FileManager.default.removeItem(at: readable)
        try? FileManager.default.removeItem(at: secrets)

        // answer_agent: picks a choice of an agent's question with the arrows and Return, guarded by the
        // question's id. The stand-in agent draws its list with a cursor and moves it on ↑/↓, like Claude Code.
        let agentBin = proj.deletingLastPathComponent().appendingPathComponent("mcp-agent-bin")
        try? FileManager.default.createDirectory(at: agentBin, withIntermediateDirectories: true)
        let asker = agentBin.appendingPathComponent("claude")
        try? """
        #!/bin/zsh
        labels=("Yes" "Yes, and don't ask again this session" "No, and tell Claude what to do differently (esc)")
        sel=1
        draw() {
          printf '\\033[2J\\033[H'
          print -r -- 'Do you want to make this edit to b.txt?'
          for i in 1 2 3; do
            if (( i == sel )); then print -r -- "❯ $i. ${labels[$i]}"; else print -r -- "  $i. ${labels[$i]}"; fi
          done
        }
        printf '\\342\\234\\273 Pondering\\342\\200\\246 (2s \\302\\267 esc to interrupt)\\n'; sleep 1
        draw
        while read -rsk1 key; do
          if [[ $key == $'\\e' ]]; then
            read -rsk2 rest
            [[ $rest == '[B' ]] && (( sel < 3 )) && (( sel += 1 ))
            [[ $rest == '[A' ]] && (( sel > 1 )) && (( sel -= 1 ))
            draw
          elif [[ $key == $'\\r' || $key == $'\\n' ]]; then
            break
          fi
        done
        printf '\\033[2J\\033[Hpicked %s\\n' "$sel"
        while true; do sleep 1; done
        """.write(to: asker, atomically: true, encoding: .utf8)
        chmod(asker.path, 0o755)
        let asking = await tool("new_tab", ["directory": proj.path, "command": "PATH=\(agentBin.path):$PATH claude", "title": "asker"])
        let askerID = asking.json?["id"] as? String ?? ""
        if let askerTab = AppDelegate.shared.controllers.flatMap(\.tabs).first(where: { $0.id.uuidString.lowercased() == askerID }) {
            check(await wait(10) { askerTab.status.question == "Do you want to make this edit to b.txt?" }, "MCP: the stand-in agent asks its question",
                  askerTab.status.question ?? askerTab.screenTail(6).joined(separator: " | "))
            let read = await tool("read_tab", ["tab_id": askerID, "lines": 10])
            let questionID = read.json?["question_id"] as? String ?? ""
            check(questionID.hasPrefix("q_") && (read.json?["choices"] as? [String])?.count == 3,
                  "MCP: read_tab gives the question's id and its choices", read.text.prefix(400).description)
            let stale = await tool("answer_agent", ["tab_id": askerID, "question_id": "q_0000000000000000", "choice": 2])
            check(stale.isError && stale.text.contains("gone"), "MCP: answer_agent refuses an answer meant for another question", stale.text)
            let answered = await tool("answer_agent", ["tab_id": askerID, "question_id": questionID, "choice": 2])
            check(!answered.isError && answered.json?["answered"] as? String == "Yes, and don't ask again this session",
                  "MCP: answer_agent picks the choice", answered.text)
            check(await wait(5) { askerTab.screenTail(10).contains { $0.contains("picked 2") } },
                  "MCP: the agent got choice 2 (the arrows, then Return)", askerTab.screenTail(6).joined(separator: " | "))
            let again = await tool("answer_agent", ["tab_id": askerID, "question_id": questionID, "choice": 1])
            check(again.isError, "MCP: answering it again is refused (the question is gone)", again.text)
            _ = await tool("close_tab", ["tab_id": askerID, "force": true])
        } else {
            check(false, "MCP: new_tab starts the stand-in agent", asking.text)
        }

        // Claude Code's own question form (AskUserQuestion), drawn as Claude Code 2.1 draws it: the model's
        // question and options, then rows of its own. A decision too, answered the same way.
        try? """
        #!/bin/zsh
        labels=("Rewrite it" "Patch the bug" "Leave it")
        sel=1
        draw() {
          printf '\\033[2J\\033[H'
          print -r -- ' ☐ Approach'
          print -r -- ''
          print -r -- 'Which approach should I take for the parser?'
          print -r -- ''
          for i in 1 2 3; do
            if (( i == sel )); then print -r -- "❯ $i. ${labels[$i]}"; else print -r -- "  $i. ${labels[$i]}"; fi
            print -r -- '     What that means'
          done
          print -r -- '  4. Type something.'
          print -r -- '────────────────────────────────────────'
          print -r -- '  5. Chat about this'
          print -r -- ''
          print -r -- 'Enter to select · ↑/↓ to navigate · Esc to cancel'
        }
        printf '\\342\\234\\273 Pondering\\342\\200\\246 (2s \\302\\267 esc to interrupt)\\n'; sleep 1
        draw
        while read -rsk1 key; do
          if [[ $key == $'\\e' ]]; then
            read -rsk2 rest
            [[ $rest == '[B' ]] && (( sel < 3 )) && (( sel += 1 ))
            [[ $rest == '[A' ]] && (( sel > 1 )) && (( sel -= 1 ))
            draw
          elif [[ $key == $'\\r' || $key == $'\\n' ]]; then
            break
          fi
        done
        printf '\\033[2J\\033[Hpicked %s\\n' "$sel"
        while true; do sleep 1; done
        """.write(to: asker, atomically: true, encoding: .utf8)
        chmod(asker.path, 0o755)
        let form = await tool("new_tab", ["directory": proj.path, "command": "PATH=\(agentBin.path):$PATH claude", "title": "form"])
        let formID = form.json?["id"] as? String ?? ""
        if let formTab = AppDelegate.shared.controllers.flatMap(\.tabs).first(where: { $0.id.uuidString.lowercased() == formID }) {
            check(await wait(10) { formTab.status.question == "Which approach should I take for the parser?" },
                  "Claude Code's question form is a decision, with the model's question",
                  formTab.status.question ?? formTab.screenTail(8).joined(separator: " | "))
            let read = await tool("read_tab", ["tab_id": formID, "lines": 20])
            let questionID = read.json?["question_id"] as? String ?? ""
            check(read.json?["choices"] as? [String] == ["Rewrite it", "Patch the bug", "Leave it"],
                  "MCP: its choices are the model's options, without the form's own rows", read.text.prefix(400).description)
            let answered = await tool("answer_agent", ["tab_id": formID, "question_id": questionID, "answer": "Patch the bug"])
            check(!answered.isError && answered.json?["answered"] as? String == "Patch the bug", "MCP: answer_agent answers the form", answered.text)
            check(await wait(5) { formTab.screenTail(10).contains { $0.contains("picked 2") } },
                  "MCP: the form got option 2", formTab.screenTail(6).joined(separator: " | "))
            _ = await tool("close_tab", ["tab_id": formID, "force": true])
        } else {
            check(false, "MCP: new_tab starts the stand-in question form", form.text)
        }
        try? FileManager.default.removeItem(at: agentBin)

        let closed = await tool("close_tab", ["tab_id": workerID])
        check(!closed.isError && !AppDelegate.shared.controllers.flatMap(\.tabs).contains { $0 === worker }, "MCP: close_tab closes an idle tab", closed.text)
        check(!MCPControl.isDriven(worker), "MCP: and forgets that an agent drove it")
        if let editor = c.editorArea.editors.first(where: { $0.document.path == canonicalPath(file.path) }) { c.editorArea.close(editor) }
        try? FileManager.default.removeItem(at: file)
    }

    /// Captures the window exactly as it is on screen (an app may always capture its own windows).
    private static func screenshot(_ c: TerminalWindowController, suffix: String) async {
        guard let window = c.window else { return }
        await screenshot(window, suffix: suffix)
    }

    static func screenshot(_ window: NSWindow, suffix: String) async {
        guard let base = reportPath else { return }
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
        ClaudeIDEServer.shared.stop() // remove the test run's lock file
        CopilotIDEServer.shared.stop()
        try? FileManager.default.removeItem(at: copilotLockFolder)
        record(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        try? reportHandle?.close()
        let report = lines.joined(separator: "\n") + "\n"
        print(report, terminator: "")
        exit(failures == 0 ? 0 : 1)
    }
}

/// A stand-in for the `claude` CLI's IDE client, for the self-test: connects the way it does (WebSocket,
/// subprotocol mcp, the token header) and records what Next Term sends. Without the subprotocol and the
/// token, it connects the way opencode does from a tab.
final class ClaudeTestClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "selftest.claude-client")
    private var messages: [[String: Any]] = []
    private(set) var closed = false

    init(port: UInt16, token: String?, origin: String? = nil, subprotocol: Bool = true) {
        let options = NWProtocolWebSocket.Options()
        if subprotocol { options.setSubprotocols(["mcp"]) }
        var headers: [(name: String, value: String)] = []
        if let token { headers.append((name: "X-Claude-Code-Ide-Authorization", value: token)) }
        if let origin { headers.append((name: "Origin", value: origin)) }
        options.setAdditionalHeaders(headers)
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        connection = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)/")!), using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.closed = true }
            if case .cancelled = state { self?.closed = true }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { self?.closed = true; return }
            if let data, let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.messages.append(message)
            }
            self.receive()
        }
    }

    func send(_ object: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        let context = NWConnection.ContentContext(identifier: "t", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: body, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    var received: [[String: Any]] { queue.sync { messages } }

    func last(_ method: String) -> [String: Any]? {
        received.last { $0["method"] as? String == method }?["params"] as? [String: Any]
    }

    func close() { connection.cancel() }
}

/// A plain HTTP client for the self-test: sends raw requests and keeps everything that comes back.
final class RawHTTPClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "selftest.http-client")
    private var buffer = Data()

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if done || error != nil { return }
            self.receive()
        }
    }

    func send(_ text: String) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    var text: String { queue.sync { String(decoding: buffer, as: UTF8.self) } }
    func close() { connection.cancel() }

    static func post(_ body: String, port: UInt16, token: String?, extra: String = "") -> String {
        var request = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\n"
        if let token { request += "Authorization: Bearer \(token)\r\n" }
        request += extra + "Content-Length: \(Data(body.utf8).count)\r\n\r\n" + body
        return request
    }
}

/// An agent's side of `nxtrm mcp`, for the self-test: the real command, over stdio.
final class MCPTestClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()

    init?(socket: String) {
        process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        process.arguments = ["--cli", "mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment[MCPServer.socketVariable] = socket
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(data)
            self.lock.unlock()
        }
        guard (try? process.run()) != nil else { return nil }
    }

    /// Sends a request and waits (without blocking the main thread) for the answer with its id.
    @MainActor
    func call(_ id: Int, _ method: String, _ params: [String: Any], timeout: Double = 15) async -> [String: Any]? {
        guard var data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]) else { return nil }
        data.append(0x0A)
        input.fileHandleForWriting.write(data)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let reply = response(id) { return reply }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return response(id)
    }

    private func response(_ id: Int) -> [String: Any]? {
        lock.lock()
        let text = String(decoding: buffer, as: UTF8.self)
        lock.unlock()
        for line in text.split(separator: "\n") {
            if let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], object["id"] as? Int == id {
                return object
            }
        }
        return nil
    }

    func close() {
        try? input.fileHandleForWriting.close()
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}

import AppKit
import SwiftTerm
import Network
import NextTermCore

/// End-to-end check of the real app: real shells, real tabs, real status changes.
/// Run with `NextTerm --self-test <report-path>`; writes PASS/FAIL lines and quits.
@MainActor
enum SelfTest {
    nonisolated static var isRequested: Bool { CommandLine.arguments.contains("--self-test") }
    /// The self-test's own MCP socket, so it never answers for (or takes over from) the Next Term you use.
    nonisolated static let mcpSocketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("nextterm-mcp-\(getpid()).sock")

    private static var lines: [String] = []
    private static var failures = 0

    static func run() {
        Task { @MainActor in
            await runAll()
            finish()
        }
    }

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        let d = detail()
        lines.append("\(ok ? "PASS" : "FAIL") \(name)\(ok || d.isEmpty ? "" : " — \(d)")")
    }

    static func note(_ text: String) { lines.append("NOTE \(text)") }

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
        await goToFileChecks(c, proj: proj)
        await gutterAndCollapseChecks(c, proj: proj)
        await blameChecks(c, proj: proj)
        await deletedFileChecks(c, proj: proj)
        await notebookChecks(c, proj: proj)
        await updateChecks(c)
        await platformLinkChecks(c)
        await branchChecks(c, proj: proj)
        await ragColorChecks(c, proj: proj)
        await importChecks(c, proj: proj)

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

        await sessionChecks(proj: proj)

        // Font size.
        let size = AppDelegate.shared.fontSize
        AppDelegate.shared.increaseFontSize(nil)
        check(AppDelegate.shared.fontSize == size + 1, "⌘+ grows the font")
        AppDelegate.shared.resetFontSize(nil)
        AppDelegate.shared.fontSize = size

        await linkChecks(c)

        try? FileManager.default.removeItem(at: dir)
    }

    /// Agent sessions: listed per project on the Welcome window and in ⌥⌘O, resumed in a tab in their folder.
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
        check(item("goToLine:")?.keyEquivalentModifierMask == [.command, .control], "your own shortcut changes stay on top of a preset")
        // ⌘K leaves the editor alone under a preset.
        c.openFile(proj.appendingPathComponent("gutter.txt"))
        if let editor = c.editorArea.activeEditor, let clear = item("clearBuffer:") {
            c.window?.makeFirstResponder(editor.textView)
            check(!c.validateMenuItem(clear), "with VS Code or JetBrains keys, ⌘K does not clear the terminal from the editor")
            c.editorArea.close(editor)
        }
        shortcuts.preset = .nextTerm
        check(item("replaceInFiles:")?.keyEquivalent == "r" && item("goToFile:")?.keyEquivalentModifierMask == .command,
              "back to Next Term's keys")

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
        let extra = proj.appendingPathComponent("imported-project")
        try? FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        // One of the user's own shortcuts (⌥⌘P for Go to File), and a Control key that is never taken.
        let mine = KeyChord(key: "p", command: true, option: true)
        let plan = ImportPlan(preset: .vsCode,
                              settings: [PlannedSetting(.fontSize(clamping: before.0 + 2), source: "editor.fontSize \(Int(before.0) + 2)"),
                                         PlannedSetting(.softWrap(!before.1), source: "editor.wordWrap"),
                                         PlannedSetting(.optionAsMeta(true), source: "terminal.integrated.macOptionIsMeta", ticked: false,
                                                        note: "Option types @ [ ] { } on your keyboard layout")],
                              shortcuts: [PlannedShortcut(command: "goToFile:", title: "Go to File…", chord: mine,
                                                          source: "keybindings.json: cmd+alt+p → workbench.action.quickOpen"),
                                          PlannedShortcut(command: "goToLine:", title: "Go to Line…", chord: KeyChord(key: "g", control: true),
                                                          source: "keybindings.json: ctrl+g → workbench.action.gotoLine", allowed: false,
                                                          note: "Control keys without ⌘ stay with your shell and agents")],
                              recentProjects: [canonicalPath(extra.path)],
                              skipped: [SkippedItem("editor.fontFamily", "font choice is coming"),
                                        SkippedItem("terminal.integrated.env.osx", "never imported: can hold secrets")])
        let window = ImportWindowController.shared
        window.showPreview(for: DetectedApp(kind: .vsCode, name: "VS Code", configPath: "/tmp", lastUsed: Date()), plan: plan)
        await pause(0.4)
        if let previewWindow = window.window { await screenshot(previewWindow, suffix: "import") }
        check(window.applyTitle == "Apply \(KeymapPreset.vsCode.overrides.count + 4) Changes", "the preview counts what is ticked", window.applyTitle)
        window.applyForTest()
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
        check(shortcuts.bindings == bindingsBefore && item("goToFile:")?.keyEquivalent == "p"
              && item("goToFile:")?.keyEquivalentModifierMask == .command,
              "Undo Import gives Go to File its old shortcut back, and your other changes stay",
              shortcuts.chord(for: "goToFile:")?.display ?? "none")
        shortcuts.bindings = savedBindings
        shortcuts.preset = savedPreset
        app.setRecentProjects(fullList)
        try? FileManager.default.removeItem(at: extra)
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
            if let diff { c.editorArea.close(diff) }
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
        check(await wait(5) { popup.isVisible && popup.model?.current == start }, "⌥⌘B opens the branch popup", popup.rowTitles.joined(separator: " | "))
        let rows = popup.rowTitles
        check(["Update Project", "Commit…", "Push…", "New Branch…", "Checkout Tag or Revision…"].allSatisfy(rows.contains),
              "it starts with the git actions", rows.prefix(6).joined(separator: " | "))
        check(rows.contains("▸ feat/ 1") && rows.contains("▸ fix/ 1") && rows.contains("▸ Agent branches 1") && rows.contains("✓ \(start)"),
              "branches sit in folders by prefix, agents' branches together, the current one first", rows.joined(separator: " | "))
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
        check(GitLog.shared.entries.contains { $0.command.hasPrefix("git stash push --include-untracked") } && GitLog.shared.entries.contains { $0.command == "git switch fix/b" },
              "every command is in the Git Log as it would be typed")
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

        // Back as it was.
        GitToast.dismiss()
        run("switch", "-q", start)
        for name in ["feat/a", "fix/b", "claude/try", "feat/new-idea"] { run("branch", "-D", name) }
        run("rm", "-q", "conf.txt")
        run("commit", "-qm", "branch checks done")
        c.sidebar.git.refresh()
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

        // Put the file back as committed.
        editor.textView.insertText("a\nb\nc\n", replacementRange: NSRange(location: 0, length: (editor.textView.string as NSString).length))
        c.editorArea.save(editor.document)
        check(await wait(5) { editor.changeMarks.isEmpty }, "the marks go once the file matches the commit again")
        c.editorArea.close(editor)
        _ = window
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
        commit("Cy Doe", "Third")
        check(await wait(3) { column(0).hasPrefix("Cy ") && column(2).hasPrefix("Cy ") && editor.changeMarks.isEmpty },
              "a commit re-annotates the open file at once", "\(column(0)) / \(column(1)) / \(column(2)) / \(column(3))")
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
        check(menu?.keyEquivalent == "p" && menu?.keyEquivalentModifierMask == .command, "Shell ▸ Go to File is ⌘P")
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
            }
        } else {
            note("sidebar root is \(c.sidebar.root?.path ?? "none"), not the test project: reveal not checked here")
        }
        finder.show(root: proj.path, recent: c.recentFiles, over: window)
        check(await wait(5) { finder.shownPaths.first == "src/main.php" }, "with nothing typed, recently opened files come first",
              finder.shownPaths.prefix(3).joined(separator: ", "))
        finder.close()
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
              "Shell ▸ Split Right is ⌘D and Split Down ⌘⇧D")
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

        // Send to Agent: an "agent" (cat under the name claude, so the tty echoes what it is given) in a tab.
        let fakeBin = proj.deletingLastPathComponent().appendingPathComponent("fake-agent-bin")
        try? FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: fakeBin.appendingPathComponent("claude"), withDestinationURL: URL(fileURLWithPath: "/bin/cat"))
        let agentTab = c.addTab(directory: proj.path)
        _ = await wait(20) { agentTab.status.integrated }
        agentTab.view.send(txt: "\u{15}PATH=\(fakeBin.path):$PATH claude\r")
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

        // Stage one hunk; it moves to Staged. Unstage it again.
        diff.base = .unstaged
        _ = await wait(5) { diff.hunkCount == 2 }
        diff.go(toHunk: 0)
        diff.perform(.stage)
        diff.base = .staged
        check(await wait(5) { diff.hunkCount == 1 && diff.sideTexts.1.contains("line two") }, "Stage Hunk stages just that change",
              "\(diff.hunkCount) staged")
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
        }

        await geminiLinkChecks(c)
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
        let projects = await tool("list_projects")
        check((projects.json?["open"] as? [String])?.isEmpty == false, "MCP: list_projects", projects.text)

        let closed = await tool("close_tab", ["tab_id": workerID])
        check(!closed.isError && !AppDelegate.shared.controllers.flatMap(\.tabs).contains { $0 === worker }, "MCP: close_tab closes an idle tab", closed.text)
        if let editor = c.editorArea.editors.first(where: { $0.document.path == canonicalPath(file.path) }) { c.editorArea.close(editor) }
        try? FileManager.default.removeItem(at: file)
    }

    /// Captures the window exactly as it is on screen (an app may always capture its own windows).
    private static func screenshot(_ c: TerminalWindowController, suffix: String) async {
        guard let window = c.window else { return }
        await screenshot(window, suffix: suffix)
    }

    private static func screenshot(_ window: NSWindow, suffix: String) async {
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
        lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        let report = lines.joined(separator: "\n") + "\n"
        if let path = reportPath { try? report.write(toFile: path, atomically: true, encoding: .utf8) }
        print(report, terminator: "")
        exit(failures == 0 ? 0 : 1)
    }
}

/// A stand-in for the `claude` CLI's IDE client, for the self-test: connects the way it does (WebSocket,
/// subprotocol mcp, the token header) and records what Next Term sends.
final class ClaudeTestClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "selftest.claude-client")
    private var messages: [[String: Any]] = []
    private(set) var closed = false

    init(port: UInt16, token: String?, origin: String? = nil) {
        let options = NWProtocolWebSocket.Options()
        options.setSubprotocols(["mcp"])
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

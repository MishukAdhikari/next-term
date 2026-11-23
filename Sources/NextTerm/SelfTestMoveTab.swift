import AppKit
import NextTermCore

#if DEBUG
/// A tab moved live from one window to another (AppDelegate.moveTab): its program keeps running and printing, with the
/// same process, its scrollback and its prompt box draft; it keeps its id, belongs to the window it moved into (its exit,
/// its ⌘-click), and the window it left keeps its other tabs, or closes without stopping it when it was the last.
/// NEXTTERM_SELFTEST_ONLY=moveTab.
extension SelfTest {
    static func moveTabChecks() async {
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-movetab-\(getpid())"
        try? fm.removeItem(atPath: base)
        let from = base + "/app", into = base + "/app-wt", lone = base + "/lone"
        for dir in [from, into, lone] { try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        try? "one\ntwo\nthree\n".write(toFile: into + "/notes.txt", atomically: true, encoding: .utf8)
        // This Window would replace the window the tab leaves: a move opens a window of its own instead.
        let savedTarget = app.projectTarget
        app.projectTarget = .thisWindow
        let source = app.openWindow(directory: from, project: from)
        var made: [TerminalWindowController] = [source]
        defer {
            app.projectTarget = savedTarget
            for controller in made where !controller.hasClosed {
                _ = TerminalTab.terminate(controller.tabs, finishLater: true)
                controller.window?.close()
            }
            try? fm.removeItem(atPath: base)
        }
        guard let kept = source.activeTab else { return check(false, "move tab: the source window opens with a tab") }
        let mover = source.addTab(directory: from)
        guard await wait(20, { kept.status.integrated && mover.status.integrated }) else {
            return check(false, "move tab: the source window's shells start")
        }

        let marker = "move line"
        mover.view.send(txt: "i=0; while :; do i=$((i+1)); echo \"\(marker) $i\"; sleep 0.05; done\r")
        func lastLine() -> Int {
            mover.screenTail(12).reversed().lazy.compactMap { line -> Int? in
                guard let range = line.range(of: marker + " ") else { return nil }
                return Int(line[range.upperBound...].prefix { $0.isNumber })
            }.first ?? 0
        }
        func history() -> Int {
            let terminal = mover.view.getTerminal()
            var row = 0, count = 0
            while let line = terminal.getScrollInvariantLine(row: row) {
                if line.translateToString(trimRight: true).hasPrefix(marker) { count += 1 }
                row += 1
            }
            return count
        }
        guard await wait(10, { lastLine() > 40 }) else { return check(false, "move tab: the program prints", "\(lastLine())") }

        let pane = source.paneView(of: mover)
        pane?.setPromptBox(shown: true)
        let draft = "a prompt not sent yet"
        pane?.promptBox?.textView.string = draft
        source.window?.makeFirstResponder(mover.view)

        let id = mover.id, pid = mover.view.process.shellPid
        let closedBefore = ClosedTabs.entries.count
        let linesBefore = lastLine(), historyBefore = history()
        guard let into1 = app.moveTab(mover, toProject: into) else { return check(false, "move tab: the move happens") }
        made.append(into1)

        check(into1 !== source && into1.project == into && into1.window?.isVisible == true,
              "move tab: with Open Projects In set to This Window, the tab moves into a window of its own for the project",
              "\(into1.project ?? "no project")")
        check(into1.tabs.count == 1 && into1.tabs.first === mover, "move tab: the new window has the moved tab and no shell of its own",
              "\(into1.tabs.count) tabs")
        check(!source.hasClosed && source.tabs.count == 1 && source.tabs.first === kept && !source.tabs.contains { $0 === mover },
              "move tab: the window it left keeps its other tab", "\(source.tabs.count) tabs")
        check(mover.id == id && mover.delegate === into1, "move tab: the tab keeps its id and answers to its new window")
        let listed = MCPControl.allTabs.filter { $0.id == id }
        check(listed.count == 1 && into1.tabs.contains { $0.id == id }, "move tab: list_tabs finds it once, in its new window", "\(listed.count)")
        check(mover.view.process.shellPid == pid && !mover.exited && kill(pid, 0) == 0, "move tab: the same process runs, nothing restarted",
              "\(pid) → \(mover.view.process.shellPid)")
        check(into1.paneView(of: mover) === pane && pane?.promptBox?.textView.string == draft,
              "move tab: its pane comes along, with the prompt box draft", pane?.promptBox?.textView.string ?? "no box")
        check(ClosedTabs.entries.count == closedBefore, "move tab: Reopen Closed Tab does not list the moved tab")
        check(mover.view.window === into1.window && into1.window?.firstResponder === mover.view,
              "move tab: its terminal is in the new window, with the keyboard")

        let printing = await wait(10) { lastLine() > linesBefore + 20 }
        check(printing, "move tab: the program goes on printing in the new window", "\(linesBefore) → \(lastLine())")
        check(history() >= historyBefore, "move tab: the scrollback is at least what it was", "\(historyBefore) → \(history())")

        let notes = URL(fileURLWithPath: into + "/notes.txt")
        mover.view.openFile?(notes, 2, 1)
        let opened = await wait(5) { into1.editorArea.documents.contains { $0.path == notes.path } }
        check(opened && !source.editorArea.documents.contains { $0.path == notes.path },
              "move tab: ⌘-click on a file in its output opens the new window's editor")

        guard let sibling = source.split(vertical: true, from: kept) else { return check(false, "move tab: a split to move a pane from") }
        _ = await wait(20) { sibling.status.integrated }
        let groupsBefore = source.groups.count
        let into2 = app.moveTab(sibling, toProject: into)
        check(into2 === into1 && into1.tabs.contains { $0 === sibling } && source.groups.count == groupsBefore
                && source.group(of: kept)?.isSplit == false && source.tabs.count == 1,
              "move tab: one pane of a split moves into the window already open on the project, the pane beside it stays",
              "\(source.tabs.count) tabs left")

        let alone = app.openWindow(directory: lone, project: lone)
        made.append(alone)
        guard let solo = alone.activeTab, await wait(20, { solo.status.integrated }) else {
            return check(false, "move tab: a window with one tab opens")
        }
        solo.view.send(txt: "sleep 300\r")
        _ = await wait(5) { solo.status.running }
        let soloPid = solo.view.process.shellPid
        _ = app.moveTab(solo, toProject: into)
        let closed = await wait(5) { alone.hasClosed }
        check(closed && !solo.exited && kill(soloPid, 0) == 0 && into1.tabs.contains { $0 === solo },
              "move tab: moving a window's only tab closes the window without stopping its program",
              "closed \(closed), exited \(solo.exited)")
        check(ClosedTabs.entries.count == closedBefore, "move tab: nor is it listed under Reopen Closed Tab")

        mover.view.send(txt: "\u{03}")
        await pause(0.3)
        mover.view.send(txt: "exit\r")
        let gone = await wait(10) { !into1.tabs.contains { $0 === mover } }
        check(gone && into1.tabs.contains { $0 === solo } && source.tabs.count == 1,
              "move tab: exit after the move closes the tab in its new window")
    }
}
#endif

import AppKit
import NextTermCore
import SwiftTerm

/// The restore's build and its actions in one process (plan 003's U10), as the launch hook runs them, on made-up crash
/// snapshots: the windows, tabs and splits come back with their ids and divider positions, and a tab whose id an open tab
/// has gets a fresh one; `npm run dev` waits on the prompt line and does not run; a resume runs the stand-in at its
/// absolute path once its shell is ready, and once; a key the user presses first cancels a tab's action; a folder named
/// with ESC shows as plain text in its note; no restored tab is taken for reuse; and safe mode types nothing until Try
/// Again, then puts the line back once. The relaunch harness checks the rest across a real quit (SelfTestRestore).
extension SelfTest {
    static func restoreBuildChecks(proj: URL) async {
        #if DEBUG
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let home = canonicalPath(NSTemporaryDirectory()) + "/nt-restore-build-\(getpid())"
        try? fm.removeItem(atPath: home)
        let escaped = home + "/red\u{1B}[31mfolder"
        let resumed = home + "/resumed"
        let standIn = home + "/bin/claude"
        let zdotdir = home + "/zdot"
        for folder in [escaped, home + "/bin", zdotdir] { try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        let script = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \(ShellQuote.quote(resumed))\n"
        let made = fm.createFile(atPath: standIn, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        // The shells' own zsh config, as the other restore checks give theirs: a short prompt, and the history in this
        // check's folder, so the user's prompt, plugins and history file stay out of it.
        let zshrc = "HISTFILE=\(ShellQuote.quote(home + "/history"))\nPROMPT='%1~ %# '\n"
        let configured = (try? zshrc.write(toFile: zdotdir + "/.zshrc", atomically: true, encoding: .utf8)) != nil
        var opened: [TerminalWindowController] = []
        defer {
            for controller in opened { controller.window?.close() }
            try? fm.removeItem(atPath: home)
        }
        guard made && configured else { return check(false, "the restore's stand-in agent and zsh config are written") }

        func typed(_ line: String, running: Bool = true, exit: Int32? = nil) -> SessionSnapshot.Command {
            SessionSnapshot.Command(line: line, check: .kept, source: .integration, running: running, exitCode: exit)
        }
        func pane(_ id: UUID, _ folder: String, _ command: SessionSnapshot.Command) -> SessionSnapshot.Pane {
            var pane = SessionSnapshot.Pane(id: id, folder: folder, command: command)
            pane.systemZsh = true
            return pane
        }
        func group(_ pane: SessionSnapshot.Pane) -> SessionSnapshot.Group {
            SessionSnapshot.Group(root: .pane(pane), focused: pane.id)
        }

        // One project window: a split at 0.3 (a dev server running, an idle pane), Claude Code, a build the user will
        // type over, and a tab whose id an open tab has. A plain window: a tab whose folder, named with ESC, is gone.
        let session = UUID().uuidString.lowercased()
        let taken = app.controllers.first?.tabs.first?.id ?? UUID()
        let dev = pane(UUID(), proj.path, typed("npm run dev"))
        let idle = pane(UUID(), proj.path, typed("ls", running: false, exit: 0))
        var agent = pane(UUID(), proj.path, typed("claude"))
        agent.agent = SessionSnapshot.Evidence(agent: .claude, sessionID: session, source: .sessionFile, sessionFolder: proj.path)
        let touched = pane(UUID(), proj.path, typed("npm run build"))
        let twin = pane(taken, proj.path, typed("pwd", running: false, exit: 0))
        let gone = pane(UUID(), escaped + "/gone", typed("pwd", running: false, exit: 0))
        let split = SessionSnapshot.Split(vertical: true, children: [.pane(dev), .pane(idle)], dividers: [0.3])
        let groups: [SessionSnapshot.Group] = [SessionSnapshot.Group(root: .split(split), focused: dev.id), group(agent), group(touched),
                                               group(twin)]
        let header = SessionSnapshot.Header(launchID: UUID(), generation: 1, clean: false, savedAt: Date())
        let windows = [SessionSnapshot.Window(project: proj.path, groups: groups), SessionSnapshot.Window(groups: [group(gone)])]
        let snapshot = SessionSnapshot(header: header, windows: windows)

        // A crash restore puts the agent's resume command on the line; here it resumes, as after a consented quit, through
        // the stand-in at its absolute path. SelfTestRestoreInput runs the planner's own command, past a shell function
        // named `claude`.
        var planned = RestorePlanning.plan(snapshot, kind: .crash, safeMode: false, quitConsent: false)
        if let index = planned.plans.firstIndex(where: { (plan: PanePlan) -> Bool in plan.pane == agent.id }) {
            planned.plans[index].outcome = .resume
            planned.plans[index].line = ShellQuote.quote(standIn) + " --resume " + session
        }
        TerminalTab.testUserZDOTDIR = zdotdir
        let built = RestoreBuild.build(snapshot, planned: planned, scrollback: [:], savedAt: nil)
        TerminalTab.testUserZDOTDIR = nil
        opened = built.windows
        var byPane: [UUID: TerminalTab] = [:]
        for restored in built.panes { byPane[restored.plan.pane] = restored.tab }
        let kept = [dev, idle, agent, touched, gone].allSatisfy { (pane: SessionSnapshot.Pane) -> Bool in byPane[pane.id]?.id == pane.id }
        let fresh = byPane[taken].map { (tab: TerminalTab) -> Bool in tab.id != taken } ?? false
        check(built.windows.count == 2 && kept && fresh,
              "the restore builds both windows, each tab with the id it had, and one whose id an open tab has gets a fresh one",
              "windows \(built.windows.count), kept \(kept), fresh \(fresh)")
        guard let project = built.windows.first, let window = project.window else { return }
        var fractions: [CGFloat] = []
        if let first = project.groups.first, case .split(let shown) = first.root { fractions = shown.dividers }
        let atThird = fractions.count == 1 && abs((fractions.first ?? 0) - 0.3) < 0.02
        check(project.groups.count == 4 && atThird, "the project window's tabs come back in order, and a split left at 0.3 at 0.3",
              "tabs \(project.groups.count), dividers \(fractions)")

        // A key the user presses before the shell is ready: the tab is theirs, and its action is dropped.
        if let tab = byPane[touched.id] {
            project.select(2)
            window.makeFirstResponder(tab.view)
            pressKey(window, String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), code: 124)
        }
        let actions = RestoreActions(panes: built.panes, safeMode: false)
        actions.sessionAvailable = { (_: SessionSnapshot.Evidence) -> Bool in true }
        actions.start()
        let settled = await wait(30) { !actions.isWaiting }
        check(settled, "every restored tab's action is applied, or dropped, once its shell is ready")

        if let tab = byPane[dev.id] {
            await pause(0.5)
            let line = lastLine(tab)
            let back = line.contains("npm run dev") && !line.contains("back on the line")
            check(tab.restoredRecord?.pending?.state == .applied && back && tab.status.command.isEmpty,
                  "npm run dev, running before the restart, waits on the prompt line and does not run", "line “\(line)”")
        }
        let ran = await wait(10) { ((try? String(contentsOfFile: resumed, encoding: .utf8)) ?? "").contains(session) }
        await pause(1)
        let runs: [String] = ((try? String(contentsOfFile: resumed, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        check(ran && runs == ["--resume " + session],
              "a resume runs the stand-in at its absolute path once its shell is ready, and once", "\(runs)")
        if let tab = byPane[touched.id] {
            let line = lastLine(tab)
            check(tab.restoredRecord?.pending?.state == .cancelled && !line.hasSuffix("npm run build") && tab.status.command.isEmpty,
                  "a key pressed in a tab before its shell is ready cancels its action, and nothing is typed",
                  "\(String(describing: tab.restoredRecord?.pending?.state)), line “\(line)”")
        }
        if let tab = byPane[gone.id] {
            let shown = tab.screenTail(20).joined()
            check(shown.contains("red[31mfolder/gone is gone, so this tab opened in"),
                  "a folder named with ESC shows in its tab's note as plain text", shown)
        }

        // Nothing restored is taken for reuse: the plain window is not unused, and ⌥⌘O's resume opens a tab of its own.
        if let plain = built.windows.last, let tab = byPane[gone.id] {
            let pristine = plain.isPristine
            let reused = plain.runInNewTab(directory: tab.directory, command: "true", title: nil) === tab
            check(!pristine && !tab.isUntouched && !reused, "a restored idle tab is not taken for reuse by nxtrm, ⌥⌘O or MCP new_tab",
                  "pristine \(pristine), untouched \(tab.isUntouched), reused \(reused)")
        }

        // Safe mode: the tab says what it held and nothing is typed, until Try Again puts it back on the line, once.
        let held = pane(UUID(), proj.path, typed("npm test"))
        let safeSnapshot = SessionSnapshot(header: header, windows: [SessionSnapshot.Window(groups: [group(held)])])
        let safePlanned = RestorePlanning.plan(safeSnapshot, kind: .crash, safeMode: true, quitConsent: false)
        TerminalTab.testUserZDOTDIR = zdotdir
        let safeBuilt = RestoreBuild.build(safeSnapshot, planned: safePlanned, scrollback: [:], savedAt: nil)
        TerminalTab.testUserZDOTDIR = nil
        opened += safeBuilt.windows
        guard let tab = safeBuilt.panes.first?.tab else { return check(false, "safe mode builds its window") }
        let safe = RestoreActions(panes: safeBuilt.panes, safeMode: true)
        safe.start()
        _ = await wait(20) { tab.status.integrated }
        await pause(1)
        let noted = tab.screenTail(20).joined().contains("Nothing ran, because the last two restores did not finish.")
        let waited = safe.isWaiting && tab.restoredRecord?.pending?.state == .pending && !lastLine(tab).hasSuffix("npm test")
        check(noted && waited, "safe mode shows what a tab held, types nothing, and keeps its action pending",
              "noted \(noted), waiting \(safe.isWaiting), line “\(lastLine(tab))”")
        safe.tryAgain()
        let applied = await wait(10) { tab.restoredRecord?.pending?.state == .applied }
        await pause(0.5)
        let line = lastLine(tab)
        let back = line.contains("npm test") && !line.contains("was running")
        check(applied && !safe.isWaiting && back && tab.status.command.isEmpty,
              "Try Again puts what the tab held back on the line, once, and runs nothing", "line “\(line)”")
        #else
        note("Restore build: skipped in a release build (its tabs need the debug build's own zsh config)")
        #endif
    }

    /// A tab's last line with text, its wrapped rows joined: a line put back at the prompt of a narrow pane reads whole,
    /// where the screen's last row holds only its end. Lines of blanks below it are passed over.
    static func lastLine(_ tab: TerminalTab) -> String {
        let terminal = tab.view.getTerminal()
        guard var end = tab.lastTextRow() else { return "" }
        let top = max(terminal.buffer.totalLinesTrimmed, end - terminal.rows)
        while end >= top {
            var start = end
            while start > top, terminal.getScrollInvariantLine(row: start)?.isWrapped == true { start -= 1 }
            // Every row of the line but its last wraps on, so the blanks it ends with are the line's own.
            let text = (start...end).map { (row: Int) -> String in
                terminal.getScrollInvariantLine(row: row)?.translateToString(trimRight: row == end, skipNullCellsFollowingWide: true) ?? ""
            }.joined()
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
            end = start - 1
        }
        return ""
    }
}

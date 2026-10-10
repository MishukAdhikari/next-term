import AppKit
import NextTermCore

/// What the user puts in a restored tab before its action runs, and what a resume runs (plan 003's U10, KTD5, KTD6), in
/// one process, on a made-up update snapshot. A letter, Ctrl-C, a folder dropped, Insert Path from the project tree and a
/// suggested command each cancel their tab's action, and nothing restored is typed after them; so does text typed into
/// the tab that never said it was the user's, as the line is no longer empty. A prompt that asks the terminal where its
/// cursor is, which the terminal answers, does not. Each tab said beforehand what happens once its shell is ready,
/// unless the user types first. A resume runs the planner's own command, the agent's absolute path behind
/// `/usr/bin/env`, with a shell function named `claude` in the way, and runs it once; one whose session a process took
/// since goes on the line, unrun, and its tab says why. `nxtrm` and a Dock click while the restore waits open no second
/// window, and Open Project from the restored window, with "Open Projects In" at This Window, opens a window of its own.
extension SelfTest {
    static func restoreInputChecks(proj: URL) async {
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let home = canonicalPath(NSTemporaryDirectory()) + "/nt-restore-input-\(getpid())"
        try? fm.removeItem(atPath: home)
        let project = home + "/app"
        let store = home + "/.claude"
        let zdotdir = home + "/zdot"
        let resumed = home + "/resumed"
        let standIn = home + "/bin/claude"
        for folder in [project + "/scripts", store, zdotdir, home + "/bin", home + "/api"] {
            try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        let script = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \(ShellQuote.quote(resumed))\n"
        let made = fm.createFile(atPath: standIn, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        // The shells' own config: a function named `claude` that says so when it runs, and, in the one tab that starts in
        // `scripts`, a prompt that asks the terminal where its cursor is and reads the answer, as some prompt themes do. Its
        // read would take what was typed ahead too, so the other tabs, whose input is checked on the line, do without it.
        let zshrc = "claude() { print -r -- function >> \(ShellQuote.quote(resumed)); }\n"
            + "__nt_where() { print -n '\\e[6n'; read -s -t 1 -d R __nt_answer; }\n"
            + "[[ $PWD == */scripts ]] && precmd_functions+=(__nt_where)\n"
        let configured = (try? zshrc.write(toFile: zdotdir + "/.zshrc", atomically: true, encoding: .utf8)) != nil
        var opened: [TerminalWindowController] = []
        // The user's own settings, put back afterwards: `nxtrm` and Open Project add to the recent projects.
        let savedTarget = app.projectTarget
        let savedRecents = UserDefaults.standard.stringArray(forKey: "recentProjects")
        defer {
            for controller in opened { controller.window?.close() }
            app.projectTarget = savedTarget
            UserDefaults.standard.set(savedRecents, forKey: "recentProjects")
            try? fm.removeItem(atPath: home)
        }
        guard made && configured else { return check(false, "the restore input checks' stand-in agent and zsh config are written") }

        func typed(_ line: String) -> SessionSnapshot.Command {
            SessionSnapshot.Command(line: line, check: .kept, source: .integration, running: true, exitCode: nil)
        }
        func pane(_ line: String, in folder: String = project, agent: SessionSnapshot.Evidence? = nil) -> SessionSnapshot.Pane {
            var pane = SessionSnapshot.Pane(id: UUID(), folder: folder, command: typed(line))
            pane.systemZsh = true
            pane.agent = agent
            return pane
        }
        func claude(_ id: String) -> SessionSnapshot.Evidence {
            var evidence = SessionSnapshot.Evidence(agent: .claude, sessionID: id, source: .sessionFile, sessionFolder: project,
                                                    store: store, executable: standIn, startedAt: Date(), routingMatchesShell: true,
                                                    autoContinueOff: true, ranAsTyped: true)
            evidence.options = []
            return evidence
        }
        let session = UUID().uuidString.lowercased()
        let tookSession = UUID().uuidString.lowercased()
        let letter = pane("npm run lint")
        let interrupt = pane("npm run e2e")
        let drop = pane("npm run fmt")
        let insert = pane("npm run deploy")
        let suggest = pane("npm run seed")
        let query = pane("npm run watch", in: project + "/scripts")
        let flagless = pane("npm run build")
        let agent = pane("claude", agent: claude(session))
        let took = pane("claude", agent: claude(tookSession))
        let panes = [letter, interrupt, drop, insert, suggest, query, flagless, agent, took]
        let groups: [SessionSnapshot.Group] = panes.map { (pane: SessionSnapshot.Pane) -> SessionSnapshot.Group in
            SessionSnapshot.Group(root: .pane(pane), focused: pane.id)
        }
        let header = SessionSnapshot.Header(launchID: UUID(), generation: 1, clean: false, savedAt: Date())
        let snapshot = SessionSnapshot(header: header, windows: [SessionSnapshot.Window(project: project, groups: groups)])

        // The gate's facts, made up so that it passes for the stand-in: the planner builds the command that runs, as on an
        // update restore, from each pane's own evidence.
        let user = geteuid()
        let files: [String: FileFacts] = [
            standIn: FileFacts(realPath: standIn, owner: user, mode: 0o755, isRegular: true),
            project: FileFacts(realPath: project, owner: user, mode: 0o755, isDirectory: true),
            store: FileFacts(realPath: store, owner: user, mode: 0o700, isDirectory: true),
        ]
        let facts = ResumeFacts(user: user, files: files, sessionAvailable: true, projectConfigChanged: false, settingsAutoContinue: false)
        let none = SessionLookup(read: { _, _, _ in [] }, newest: { _, _, _, _ in nil })
        let world = RestorePlanner.World(home: home, resumeFacts: { _, _, _ in facts }, sessions: none)
        let plans = RestorePlanner.plan(snapshot, kind: .update, world: world)
        let commands: [String] = plans.filter { (plan: PanePlan) -> Bool in plan.outcome == .resume }.compactMap(\.line)
        let absolute = commands.count == 2 && commands.allSatisfy { (line: String) -> Bool in
            line.hasPrefix("/usr/bin/env -u ") && line.contains(ShellQuote.quote(standIn) + " --resume ")
        }
        check(absolute, "the planner's resume runs the agent's recorded absolute path behind /usr/bin/env", "\(commands)")

        TerminalTab.testUserZDOTDIR = zdotdir
        let planned = RestorePlanning.Planned(plans: plans, folders: [:])
        let built = RestoreBuild.build(snapshot, planned: planned, scrollback: [:], savedAt: nil)
        TerminalTab.testUserZDOTDIR = nil
        opened = built.windows
        var byPane: [UUID: TerminalTab] = [:]
        for restored in built.panes { byPane[restored.plan.pane] = restored.tab }
        guard let window = built.windows.first, let frame = window.window, byPane.count == panes.count else {
            return check(false, "the restore input checks' window is built with every tab", "tabs \(byPane.count)")
        }

        // What the user puts in each tab before its shell is ready.
        func focus(_ pane: SessionSnapshot.Pane) -> TerminalTab? {
            guard let tab = byPane[pane.id], let index = window.groups.firstIndex(where: { $0.contains(tab) }) else { return nil }
            window.select(index)
            frame.makeFirstResponder(tab.view)
            return tab
        }
        if focus(letter) != nil { pressKey(frame, "l", code: 37) }
        if focus(interrupt) != nil { pressKey(frame, "\u{3}", code: 8, flags: .control) }
        if let tab = focus(drop) {
            let dropped = FolderDrop([URL(fileURLWithPath: project + "/scripts", isDirectory: true)])
            _ = tab.view.performDragOperation(dropped)
            dropped.done()
        }
        if focus(insert) != nil { window.sidebar(window.sidebar, insert: ShellQuote.quote(project + "/scripts/deploy.sh") + " ") }
        if let tab = focus(suggest), case .success(let suggestion) = CommandSuggestion.check("git status") {
            CommandSuggestionPanel.put(suggestion, on: tab)
        }
        let queriedFirst = byPane[query.id]?.touchedByUser ?? true

        let actions = RestoreActions(panes: built.panes, safeMode: false)
        actions.sessionAvailable = { (evidence: SessionSnapshot.Evidence) -> Bool in evidence.sessionID != tookSession }
        actions.start()
        // Text typed into a tab by a path that never says it is the user's: the line is not empty any more.
        byPane[flagless.id]?.view.typeIn("echo flagless ")

        // `nxtrm` naming the restored project, and a Dock click, while the restore waits: the restored window comes forward.
        let windows = app.controllers.count
        app.handle(OpenCommand(items: [OpenRequest(path: project, isDirectory: true)]))
        _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        await pause(0.5)
        let forProject = app.controllers.filter { (controller: TerminalWindowController) -> Bool in controller.project == project }.count
        check(app.controllers.count == windows && forProject == 1, "nxtrm and a Dock click while a restore waits open no second window",
              "windows \(windows) then \(app.controllers.count), for the project \(forProject)")

        let settled = await wait(40) { !actions.isWaiting }
        check(settled, "every restored tab's action is applied, or dropped, once its shell is ready")
        _ = await wait(10) { ((try? String(contentsOfFile: resumed, encoding: .utf8)) ?? "").contains(session) }
        await pause(1)

        func state(_ pane: SessionSnapshot.Pane) -> SessionSnapshot.ActionState? { byPane[pane.id]?.restoredRecord?.pending?.state }
        func bottomLine(_ tab: TerminalTab) -> String {
            tab.liveTail(4).last { (line: String) -> Bool in !line.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        }
        /// The tab's screen with every blank left out, so a sentence wrapped across rows still reads whole.
        func shown(_ tab: TerminalTab) -> String {
            tab.screenTail(40).joined().replacingOccurrences(of: " ", with: "")
        }
        let inputs: [(pane: SessionSnapshot.Pane, input: String)] = [(letter, "a letter typed"), (interrupt, "Ctrl-C"),
                                                                     (drop, "a folder dropped"), (insert, "Insert Path"),
                                                                     (suggest, "a suggested command")]
        for (pane, input) in inputs {
            guard let tab = byPane[pane.id], let line = pane.command?.line else { continue }
            let bottom = bottomLine(tab)
            let promise = line.replacingOccurrences(of: " ", with: "") + "goesbackontheline,notrun,oncetheshellisready,unlessyoutypefirst"
            let said = shown(tab).contains(promise)
            let cancelled = state(pane) == .cancelled
            let nothingTyped = !bottom.contains(line) && tab.status.command.isEmpty
            check(cancelled && nothingTyped && said,
                  "\(input) before the shell is ready cancels the tab's action: nothing restored is typed after it, as its note said",
                  "\(String(describing: state(pane))), line “\(bottom)”, said \(said)")
        }
        if let tab = byPane[insert.id] {
            let bottom = bottomLine(tab)
            check(bottom.contains("deploy.sh") && !bottom.contains("npm run deploy") && tab.status.command.isEmpty,
                  "the path Insert Path typed stays on the line alone, not run", "line “\(bottom)”")
        }
        if let tab = byPane[flagless.id] {
            let bottom = bottomLine(tab)
            let cancelled = state(flagless) == .cancelled && !tab.touchedByUser
            check(cancelled && bottom.contains("echo flagless") && !bottom.contains("npm run build") && tab.status.command.isEmpty,
                  "text typed into a tab without the user's flag cancels its action too: nothing restored is typed after it",
                  "\(String(describing: state(flagless))), line “\(bottom)”")
        }
        if let tab = byPane[query.id] {
            let bottom = bottomLine(tab)
            let untouched = !queriedFirst && !tab.touchedByUser
            let back = state(query) == .applied && bottom.contains("npm run watch") && tab.status.command.isEmpty
            check(untouched && back,
                  "a prompt that asks the terminal where its cursor is, and reads the answer, does not cancel the tab's action",
                  "\(String(describing: state(query))), line “\(bottom)”")
        }

        // The resume ran the stand-in once, and the shell function named `claude`, which is there, did not run for it.
        if let tab = byPane[agent.id] {
            let said = shown(tab).contains("ClaudeCodesession\(session)resumesoncetheshellisready,unlessyoutypefirst.")
            tab.view.send(txt: "claude probe\r")
            _ = await wait(10) { ((try? String(contentsOfFile: resumed, encoding: .utf8)) ?? "").contains("function") }
            let runs: [String] = ((try? String(contentsOfFile: resumed, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            check(state(agent) == .applied && said && runs == ["--resume " + session, "function"],
                  "a resume runs the agent at its recorded absolute path once, past a shell function named claude, which is there",
                  "said \(said), runs \(runs)")
        }
        // Open Project from the restored window, with "Open Projects In" at This Window: its tabs stay, and the project
        // opens in a window of its own (R32).
        app.projectTarget = .thisWindow
        let tabsBefore = window.tabs.count
        app.openProject(at: URL(fileURLWithPath: home + "/api", isDirectory: true), from: window)
        let api = app.controllers.first { (controller: TerminalWindowController) -> Bool in controller.project == home + "/api" }
        if let api { opened.append(api) }
        check(window.holdsRestore && api != nil && api !== window && window.project == project && window.tabs.count == tabsBefore,
              "Open Project from a restored window, set to This Window, opens a window of its own and leaves the restored tabs",
              "project \(window.project ?? "none"), tabs \(tabsBefore) then \(window.tabs.count)")

        // A session a process took since: its resume command on the line, unrun, and the tab says why.
        if let tab = byPane[took.id] {
            let bottom = bottomLine(tab)
            let why = shown(tab).contains("ClaudeCodesession\(tookSession)didnotresume,becauseanotherprocesshasitopen.")
            let runs = (try? String(contentsOfFile: resumed, encoding: .utf8)) ?? ""
            let back = state(took) == .applied && bottom.hasSuffix("claude --resume " + tookSession)
            check(back && why && !runs.contains(tookSession),
                  "a resume whose session a process took since puts its resume command on the line, unrun, and says why",
                  "why \(why), line “\(bottom)”")
        }
    }
}

/// A drop of files or folders, as Finder makes one: only what `NextTermView.performDragOperation` reads of it is real.
private final class FolderDrop: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard

    init(_ urls: [URL]) {
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("Next Term restore drop \(getpid())"))
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(urls.map { (url: URL) -> NSURL in url as NSURL })
        super.init()
    }

    /// The pasteboard goes once the drop is done.
    func done() { draggingPasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

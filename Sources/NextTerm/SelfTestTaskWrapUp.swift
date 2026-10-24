import AppKit
import CryptoKit
import NextTermCore

#if DEBUG
/// Wrap Up and Post Update end to end, in a git project of the part's own with one commit today by a made-up
/// address and its handoff folder set to notes/handoffs. Three agent tabs (a script run under the name claude): one ready, one working, one with "abc" typed. The
/// ready one reads the request, writes a fixed handoff to the path named in it, and waits. Wrap Up, opened from the
/// menu item, asks only that tab, with one Return, naming notes/handoffs; its handoff becomes two ticked tasks, one
/// holding a stored key as •••, and Add writes two todo files and two lines in the posted record. Post Update then drafts the handoff's Done item, its Next items and the commit;
/// Save writes docs/updates/<day>.md, Copy goes to the self-test's own pasteboard, never the user's, and Send types
/// into the ready tab with no Return. Nothing opens outside Next Term, and everything is put back. Called from
/// `tasksChecks`.
extension SelfTest {
    static func wrapUpChecks() async {
        wrapUpKeyChecks()
        guard let git = GitRunner.locateGit(), let app = AppDelegate.shared else {
            return note("wrap up: skipped, no git")
        }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-wrapup-\(getpid())"
        try? fm.removeItem(atPath: base)
        let project = base + "/shop", bin = base + "/bin"
        try? fm.createDirectory(atPath: project, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        @discardableResult func sh(_ args: String...) -> String { gitOutput(git, project, args) }
        sh("init", "-q", "-b", "main")
        sh("config", "user.email", "selftest@example.com")
        sh("config", "user.name", "Self Test")
        sh("commit", "-q", "--allow-empty", "-m", "Add the cart total")
        // A stored key the handoff holds: everything shown or sent holds it as •••.
        let savedMask = SecretMask.current
        let value = "sk-ant-wrapup-" + UUID().uuidString.prefix(12)
        let key = SymmetricKey(size: .bits256)
        SecretMask.current = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        let savedRecordsOnly = TaskOpen.recordsOnly
        TaskOpen.recordsOnly = true
        TaskOpen.opened = []
        let board = NSPasteboard(name: NSPasteboard.Name("NextTerm.selftest"))
        PostUpdate.testPasteboard = board
        let general = NSPasteboard.general.changeCount
        let c = app.openWindow(directory: project, project: project)
        defer {
            SecretMask.current = savedMask
            TaskOpen.recordsOnly = savedRecordsOnly
            TaskOpen.opened = []
            PostUpdate.testPasteboard = nil
            board.releaseGlobally()
            WrapUpSheet.current?.pressCancel()
            if !c.hasClosed { c.window?.close() }
            try? fm.removeItem(atPath: base)
        }
        let tabs = await fakeAgents(c, project: project, bin: bin, value: value)
        guard tabs.count == 3 else { return check(false, "wrap up: three fake agent tabs start") }
        await wrapUpSheetChecks(c, ready: tabs[0], project: project, value: value)
        await wrapUpTypedOverChecks(c, ready: tabs[0], project: project)
        await postUpdateChecks(c, ready: tabs[0], project: project, value: value)
        check(TaskOpen.opened.isEmpty, "wrap up: nothing opened outside Next Term",
              TaskOpen.opened.map(\.absoluteString).joined(separator: ", "))
        check(NSPasteboard.general.changeCount == general, "wrap up: the user's clipboard is untouched")
        for tab in tabs {
            tab.view.send(txt: "\u{15}\u{03}")
            _ = await wait(4) { !tab.status.running }
            c.requestClose(tab)
        }
    }

    /// The fake agent: reads one line, writes the handoff to the path after " to ", then waits for one more line.
    static func fakeAgentScript(value: String) -> String {
        let handoff: [String] = [
            "## Done", "- Wired the cart total into checkout", "",
            "## Next", "- Add a test for an empty cart", "- Move token=\(value) out of the config", "",
            "## Open questions", "- None", "", "## How to resume", "Run the cart tests.",
        ]
        let lines: String = handoff.map { "'" + $0 + "'" }.joined(separator: " ")
        return """
        IFS= read -r line
        path="${line#* to }"
        path="${path%% (create*}"
        mkdir -p "$(dirname "$path")"
        printf '%s\\n' \(lines) > "$path"
        IFS= read -r more

        """
    }

    /// Three tabs in the project's top folder running the script under the name claude: ready, working, and with
    /// "abc" typed. Empty when one doesn't start.
    private static func fakeAgents(_ c: TerminalWindowController, project: String, bin: String,
                                   value: String) async -> [TerminalTab] {
        let fm = FileManager.default
        let script = bin + "/agent.sh"
        try? fakeAgentScript(value: value).write(toFile: script, atomically: true, encoding: .utf8)
        try? fm.createSymbolicLink(atPath: bin + "/claude", withDestinationPath: "/bin/bash")
        var tabs: [TerminalTab] = []
        for name in ["nt-ready", "nt-busy", "nt-typed"] {
            let tab = c.addTab(directory: project)
            tab.userTitle = name
            _ = await wait(20) { tab.status.integrated }
            tab.view.send(txt: "\u{15}PATH=\(bin):$PATH claude \(script) >/dev/null\r")
            guard await wait(5, { tab.status.running && tab.status.kind == .agent }) else { return [] }
            tabs.append(tab)
        }
        let busy = await showWorking(tabs[1], true)
        tabs[2].view.send(txt: "abc")
        let typed = await wait(3) { AgentReadiness.shared.check(tabs[2]) == .notReady(.hasText) }
        let ready = await wait(3) { AgentReadiness.shared.check(tabs[0]) == .ready }
        check(busy && typed && ready, "wrap up: one agent tab is ready, one works and one has text in its prompt",
              "\(AgentReadiness.shared.check(tabs[0])) \(tabs[1].status.state) \(AgentReadiness.shared.check(tabs[2]))")
        return tabs
    }

    /// The agent's screen shows the working hint, or nothing.
    private static func showWorking(_ tab: TerminalTab, _ working: Bool) async -> Bool {
        tab.view.feed(text: working ? "\u{1b}[H\u{1b}[2J✻ Working… (esc to interrupt)\r\n" : "\u{1b}[H\u{1b}[2J")
        return await wait(5) { (tab.status.state == .working) == working }
    }

    /// The Handoff folder row: a pick inside the project is stored relative and named in the request; the home folder
    /// is refused in red and saves nothing; Use Default goes back to docs/handoffs.
    private static func handoffFolderRowChecks(project: String) {
        let key = TaskSettings.projectKey(project)
        let row = TaskHandoffFolderRow()
        row.update(project: project, key: key)
        check(row.shownValue == TaskSettings.defaultHandoffFolder, "wrap up: the Handoff folder row shows docs/handoffs")
        row.picked(project + "/notes/handoffs")
        let stored = TaskSettings(defaults: .standard).projects[key]?.handoffFolder
        let named = TaskSettings(defaults: .standard).handoffFolder(for: project)
        let request = named.flatMap { HandoffRequest.text(path: $0 + "/x.md") } ?? ""
        let relative: Bool = stored == "notes/handoffs" && row.shownValue == "notes/handoffs"
        check(relative && request.contains(" to notes/handoffs/x.md "),
              "wrap up: a folder picked inside the project is stored relative and named in the request", stored ?? "none")
        row.picked(NSHomeDirectory())
        let after = TaskSettings(defaults: .standard).projects[key]?.handoffFolder
        check(row.problemText == TaskHandoffFolderRow.outside && after == "notes/handoffs",
              "wrap up: the home folder is refused in red and nothing is saved", row.problemText ?? "no line")
        row.pressUseDefault()
        let cleared = TaskSettings(defaults: .standard).projects[key]?.handoffFolder
        check(cleared == nil && row.shownValue == TaskSettings.defaultHandoffFolder,
              "wrap up: Use Default goes back to docs/handoffs")
        // Wrap Up below runs with the picked folder; tasksChecks puts the saved settings back after.
        row.picked(project + "/notes/handoffs")
    }

    /// Wrap Up's key changed in Settings › Keyboard Shortcuts moves the menu item's key, and Reset brings ⌃⌘W back.
    /// tasksChecks puts the saved bindings back after.
    private static func wrapUpKeyChecks() {
        let shortcuts = KeyboardShortcuts.shared
        let item: () -> NSMenuItem? = { shortcuts.commands.first { $0.id == "wrapUp:" }?.item }
        let mine = KeyChord(key: "u", command: true, option: true, control: true)
        shortcuts.set(mine, for: "wrapUp:")
        let moved = item().flatMap(KeyboardShortcuts.chord(of:))
        check(moved == mine, "wrap up: a key set for Wrap Up… in Settings moves the menu item's key",
              moved?.display ?? "no key")
        shortcuts.reset("wrapUp:")
        let back = item().flatMap(KeyboardShortcuts.chord(of:))
        check(back?.display == "⌃⌘W", "wrap up: Reset gives Wrap Up… ⌃⌘W again", back?.display ?? "no key")
    }

    /// Wrap Up from the menu item: one row ticked and two with why, one line typed with its Return, the handoff read
    /// and reviewed with the key as •••, then Add writes two todo files.
    private static func wrapUpSheetChecks(_ c: TerminalWindowController, ready: TerminalTab, project: String,
                                          value: String) async {
        handoffFolderRowChecks(project: project)
        let menu = NSApp.mainMenu?.items.first { $0.title == "Tasks" }?.submenu
        guard let item = menu?.items.first(where: { $0.action == #selector(TasksMenu.wrapUp(_:)) }) else {
            return check(false, "wrap up: the Tasks menu has Wrap Up…")
        }
        check(TasksMenu.shared.validate(item, front: c) && !TasksMenu.shared.validate(item, front: nil),
              "wrap up: Wrap Up… needs a project window in front")
        c.window?.makeKeyAndOrderFront(nil)
        _ = await wait(3) { TasksMenu.shared.front === c }
        TasksMenu.shared.wrapUp(item)
        guard await wait(5, { WrapUpSheet.current != nil }), let sheet = WrapUpSheet.current,
              let model = sheet.model else {
            return check(false, "wrap up: Wrap Up… opens its sheet over the window")
        }
        let rows: [String] = model.rows.map { $0.title + ($0.reason.map { " · " + $0 } ?? "") + ($0.ticked ? " ✓" : "") }
        let expected = ["nt-ready ✓", "nt-busy · working", "nt-typed · has your text in its prompt"]
        check(rows == expected && sheet.primaryTitle == "Ask 1 Agent",
              "wrap up: the ready tab is ticked and the other two say why", rows.joined(separator: " | "))
        sheet.pressPrimary()
        let file = "notes/handoffs/\(TaskDay(Date(), calendar: .current))-nt-ready.md"
        let request = HandoffRequest.text(path: file) ?? "none"
        let asked = "Write a short handoff for this session to notes/handoffs/"
        let typed = await wait(5) { ready.screenTail(12).joined().contains(asked) }
        check(typed, "wrap up: Ask types the request, naming the picked folder, into the ready tab",
              ready.screenTail(6).joined())
        let written = await wait(10) { FileManager.default.fileExists(atPath: project + "/" + file) }
        check(written, "wrap up: one Return sent it, and the agent wrote \(file)", request)
        let reviewable = await wait(15) { sheet.model?.canReview == true }
        check(reviewable && sheet.primaryTitle == "Review", "wrap up: the handoff is ready to review",
              sheet.model?.rows.compactMap(\.phaseText).joined(separator: ", ") ?? "")
        sheet.pressPrimary()
        let tasks: [WrapUpReview.Task] = sheet.review?.sections.flatMap(\.tasks) ?? []
        let titles: [String] = tasks.map(\.title)
        check(tasks.count == 2 && tasks.allSatisfy(\.ticked) && sheet.primaryTitle == "Add 2 Tasks",
              "wrap up: its two Next items are two ticked tasks", titles.joined(separator: " | "))
        check(titles.contains { $0.contains("token=•••") } && !titles.contains { $0.contains(value) },
              "wrap up: the review holds the stored key as •••")
        let todo = project + "/" + TaskSettings.defaultFolder
        let recordedBefore = await recordedToday(project)
        sheet.pressPrimary()
        let added = await wait(5) { WrapUpSheet.current == nil && todoFiles(todo).count == 2 }
        let bodies: String = todoFiles(todo).compactMap { readText(todo + "/" + $0) }.joined()
        check(added && bodies.contains("token=•••") && !bodies.contains(value),
              "wrap up: Add writes two todo files, the key as •••", todoFiles(todo).joined(separator: ", "))
        // The record is written off the main thread: give it a moment.
        var recorded = await recordedToday(project)
        for _ in 0..<40 where recorded < recordedBefore + 2 {
            await pause(0.05)
            recorded = await recordedToday(project)
        }
        check(recorded == recordedBefore + 2, "wrap up: Add writes two lines in the posted record",
              "\(recordedBefore) then \(recorded)")
    }

    /// A key the user presses in the tab between the request and its Return: the Return is held back, nothing is sent,
    /// no handoff is written, and the row says why. The prompt is cleared afterwards for the checks after.
    private static func wrapUpTypedOverChecks(_ c: TerminalWindowController, ready: TerminalTab, project: String) async {
        let menu = NSApp.mainMenu?.items.first { $0.title == "Tasks" }?.submenu
        guard let item = menu?.items.first(where: { $0.action == #selector(TasksMenu.wrapUp(_:)) }) else { return }
        c.window?.makeKeyAndOrderFront(nil)
        _ = await wait(3) { TasksMenu.shared.front === c }
        TasksMenu.shared.wrapUp(item)
        guard await wait(5, { WrapUpSheet.current != nil }), let sheet = WrapUpSheet.current else {
            return check(false, "wrap up: Wrap Up… opens again for the typed-over check")
        }
        defer { WrapUpSheet.current?.pressCancel() }
        let handoffs: String = project + "/notes/handoffs"
        let before: Int = (try? FileManager.default.contentsOfDirectory(atPath: handoffs).count) ?? 0
        let commands: Int = ready.status.commandsStarted
        sheet.pressPrimary()
        ready.view.send(txt: "x")
        let skipped = await wait(3) { () -> Bool in
            sheet.model?.rows.first?.phaseText?.contains("you typed in it") == true
        }
        await pause(1.5)
        let after: Int = (try? FileManager.default.contentsOfDirectory(atPath: handoffs).count) ?? 0
        check(skipped && after == before && ready.status.commandsStarted == commands,
              "wrap up: a key typed before the Return holds it back, and the row says the request wasn’t sent",
              sheet.model?.rows.compactMap(\.phaseText).joined(separator: ", ") ?? "no sheet")
        ready.view.send(txt: "\u{15}")
    }

    /// The posted record's lines today for `project`, read off the main thread as the store asks.
    private static func recordedToday(_ project: String) async -> Int {
        let key = TaskSettings.projectKey(project)
        let read = Task.detached { () -> Int in TaskRecordStore.shared.today(project: key).count }
        return await read.value
    }

    private static func todoFiles(_ folder: String) -> [String] {
        let names: [String] = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0.hasSuffix(".md") }.sorted()
    }

    private static func readText(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Post Update in the same project: the handoff's Done item, its Next items and today's commit; Save writes
    /// docs/updates/<day>.md; Copy puts masked text on the self-test's pasteboard; Send types into the ready tab
    /// with no Return.
    private static func postUpdateChecks(_ c: TerminalWindowController, ready: TerminalTab, project: String,
                                         value: String) async {
        _ = await showWorking(ready, false)
        let menu = NSApp.mainMenu?.items.first { $0.title == "Tasks" }?.submenu
        let item = menu?.items.first { $0.action == #selector(TasksMenu.postUpdate(_:)) }
        check(item.map { TasksMenu.shared.validate($0, front: c) && !TasksMenu.shared.validate($0, front: nil) } == true,
              "post update: Post Update… needs a project window in front")
        guard let sheet = PostUpdateSheet.present(over: c) else { return check(false, "post update: the sheet opens") }
        defer { sheet.cancel() }
        guard await wait(10, { sheet.draft != nil }) else { return check(false, "post update: the draft fills") }
        let text = sheet.textView.string
        let parts = ["- Wired the cart total into checkout", "- Add a test for an empty cart", "- Add the cart total",
                     "token=•••"]
        check(parts.allSatisfy { text.contains($0) } && !text.contains(value),
              "post update: the draft holds the handoff's Done and Next items and today's commit, the key as •••", text)
        sheet.savePressed()
        let day = TaskDay(Date(), calendar: .current).description
        let saved = readText(project + "/docs/updates/\(day).md")
        check(saved?.contains("token=•••") == true && saved?.contains(value) == false,
              "post update: Save writes docs/updates/\(day).md, masked", sheet.status.stringValue)
        sheet.copyPressed()
        let copied = PostUpdate.pasteboard.string(forType: .string) ?? ""
        check(PostUpdate.pasteboard != NSPasteboard.general && copied.contains("token=•••") && !copied.contains(value),
              "post update: Copy puts the masked text on the self-test's own pasteboard")
        sheet.place.stringValue = "the team channel"
        sheet.sendStepPressed()
        sheet.sendPressed()
        let typed = await wait(5) { ready.screenTail(12).joined().contains("Post this update to the team channel") }
        check(typed, "post update: Send types the update into the ready tab", ready.screenTail(6).joined())
        // A Return would have sent the line to the agent and emptied its prompt; the update still sits there.
        check(AgentReadiness.shared.check(ready) == .notReady(.hasText), "post update: no Return goes in with it")
    }
}
#endif

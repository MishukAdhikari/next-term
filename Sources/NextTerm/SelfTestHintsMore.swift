import AppKit
import NextTermCore

#if DEBUG
/// The four hints after the window column's three (plan 035), in the hints part's windows with its clocks stood in:
/// - H7, terminal beside: a divider let go at an extreme puts “Move terminal to the right” in the terminal's tab bar,
///   whole, over no tab or button; not at the middle, nor in a narrow window; its button moves the terminal and retires
///   it; set_layout retires it; a real press-drag-release on the divider reaches the release hook.
/// - H4, send the selection: three lines selected with a stand-in agent put “⌥⌘K Ask Claude Code” (the diff's words) in
///   the editor's tab bar, whole, the editor keeping the keyboard; one line or a .env shows nothing; the button types the
///   reference into the agent's prompt and retires it; ⌥⌘K and get_editor_selection retire it; narrowing the window
///   takes it away before a tab narrows.
/// - H8, fold worktrees: a repository and two worktree windows put “Fold worktrees” at the hover list's foot once H1 is
///   done (H1 first while it isn't); its button folds them and retires it; the arrow retires it; pinned, a worktree more
///   puts it at the column's foot.
/// - H5, switch back: the second switch by a click on a row says “Press ⌘O then ↩ to go back” at that window's column
///   foot, as static text with the agent's way as help; ⌘O then ↩ and open_project retire it.
/// And the seeding: each hint new to an install is seeded once from its facts, a rebound key retires it, a traceless one
/// is watched on an install used before, and the first seeding's three are not seeded again. Each hint is screenshotted.
extension SelfTest {
    static func moreHintsChecks(_ app: AppDelegate, _ c: TerminalWindowController, _ other: TerminalWindowController,
                                freshTips: () -> Void, nextDay: () -> Void) async {
        guard let window = c.window else { return }
        let frame: NSRect = window.frame
        let defaults = UserDefaults.standard
        let saved = (position: defaults.object(forKey: "terminalPosition"), folded: defaults.object(forKey: WindowColumnSettings.foldedKey),
                     expanded: app.windowColumnExpanded, dwell: BarHints.selectionDwell)
        defer {
            window.setFrame(frame, display: true)
            BarHints.selectionDwell = saved.dwell
            app.terminalPosition = TerminalPosition(stored: saved.position as? String)
            for controller in app.controllers { controller.applyLayout() }
            restoreDefault(saved.position, "terminalPosition")
            restoreDefault(saved.folded, WindowColumnSettings.foldedKey)
            app.windowColumnExpanded = saved.expanded
        }
        BarHints.selectionDwell = 0.1
        // Wide enough for the terminal to go beside the editor, and for the bars' free room.
        window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: max(frame.width, 1500), height: max(frame.height, 860)), display: true)
        window.layoutIfNeeded()
        /// Every hint retired but `keep`: a check sees only its own.
        func only(_ keep: Hint) {
            freshTips()
            for hint in Hint.allCases where hint != keep { HintCenter.shared.retire(hint, reason: .closed) }
        }
        await terminalBesideChecks(app, c, only: only, nextDay: nextDay)
        await sendChecks(app, c, only: only)
        await foldChecks(app, c, only: only)
        await switchBackChecks(app, c, other, only: only)
        seedingChecks(app)
    }

    /// Whether `line` lies inside `bar`, its words whole, over no other control the bar shows.
    private static func clearInBar(_ line: HintLine?, _ bar: TabBarView) -> (ok: Bool, detail: String) {
        guard let line, line.superview === bar, !line.isHidden else { return (false, "not in the bar") }
        bar.layoutSubtreeIfNeeded()
        let others: [NSView] = bar.subviews.filter { $0 !== line && !$0.isHidden && $0.frame.width > 0 && $0.frame.height > 0 }
        let over: [NSView] = others.filter { $0.frame.intersects(line.frame) }
        let inside: Bool = bar.bounds.contains(line.frame)
        let ok: Bool = inside && over.isEmpty && line.wordsWhole && line.place == .bar && line.layer?.backgroundColor == nil
        return (ok, "line \(line.frame) in \(bar.bounds), over \(over.map { "\(type(of: $0))@\($0.frame)" }), whole \(line.wordsWhole), room \(bar.hintRoom)")
    }

    // MARK: H7

    private static func terminalBesideChecks(_ app: AppDelegate, _ c: TerminalWindowController, only: (Hint) -> Void, nextDay: () -> Void) async {
        guard let window = c.window else { return }
        let fm = FileManager.default
        let dir = canonicalPath(NSTemporaryDirectory()) + "/nt-hint-beside-\(getpid())"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/notes.txt"
        try? (1...40).map { "line \($0)" }.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
        defer {
            c.editorArea.closeAll()
            try? fm.removeItem(atPath: dir)
        }
        only(.terminalBeside)
        app.terminalPosition = .bottom
        c.applyLayout()
        c.openFile(URL(fileURLWithPath: file))
        guard await wait(3, { !c.editorArea.isHidden }) else { return check(false, "hints H7: a file opens above the terminal") }
        window.layoutIfNeeded()
        let split: WorkSplitView = c.workSplit
        /// The terminal at `share` of the work area, as a drag leaves it.
        func terminal(at share: CGFloat) {
            split.setPosition((split.bounds.height * (1 - share)).rounded(), ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
        }
        terminal(at: 0.1)
        c.workDividerReleased()
        let up: Bool = await wait(2) { c.tabBar.hint?.hint == .terminalBeside }
        if up { await screenshot(c, suffix: "-hint-terminal-beside") }
        let line: HintLine? = c.tabBar.hint
        let placed = clearInBar(line, c.tabBar)
        let words = HintWords.terminalBeside
        check(up && placed.ok && line?.button?.title == words.words && line?.button?.toolTip == words.help && line?.button?.refusesFirstResponder == true,
              "hints H7: the divider let go with the terminal at a tenth puts “Move terminal to the right” in its tab bar, whole, over no tab, + or ⋯",
              "up \(up), \(placed.detail), “\(line?.button?.title ?? "")”")
        let counted: Bool = await wait(1) { HintCenter.shared.record(.terminalBeside).shown == 1 }
        line?.button?.performClick(nil)
        let moved: Bool = await wait(2) { app.terminalPosition == .right && c.workSplit.isVertical }
        check(counted && moved && HintCenter.shared.record(.terminalBeside).retired == .actionPerformed && c.tabBar.hint == nil,
              "hints H7: it counts once seen, and its button moves the terminal to the right and retires it",
              "counted \(counted), moved \(moved), \(HintCenter.shared.record(.terminalBeside))")

        // At the middle, or in a window too narrow for the two side by side: nothing.
        only(.terminalBeside)
        app.terminalPosition = .bottom
        c.applyLayout()
        window.layoutIfNeeded()
        terminal(at: 0.5)
        c.workDividerReleased()
        await pause(0.3)
        let middle: Bool = c.tabBar.hint == nil && !HintStage.shared.isWaiting(.terminalBeside)
        let wide: NSRect = window.frame
        window.setFrame(NSRect(x: wide.minX, y: wide.minY, width: 900, height: wide.height), display: true)
        window.layoutIfNeeded()
        terminal(at: 0.1)
        c.workDividerReleased()
        await pause(0.3)
        let narrow: Bool = c.tabBar.hint == nil && !c.terminalDividerAtExtreme
        window.setFrame(wide, display: true)
        window.layoutIfNeeded()
        check(middle && narrow, "hints H7: not at the middle, nor in a work area under 960 points wide", "middle \(middle), narrow \(narrow)")

        // A real press, drag and release on the divider reaches the release hook: AppKit's tracking returns on release.
        let hooked = split.onDividerReleased
        var released = false
        split.onDividerReleased = { released = true; hooked?() }
        terminal(at: 0.3)
        let divider: CGFloat = c.editorArea.frame.maxY + split.dividerThickness / 2
        let from: NSPoint = split.convert(NSPoint(x: split.bounds.midX, y: divider), to: nil)
        let to = NSPoint(x: from.x, y: from.y - split.bounds.height * 0.2)
        func mouse(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = mouse(.leftMouseDown, from), let drag = mouse(.leftMouseDragged, to), let up = mouse(.leftMouseUp, to) {
            NSApp.postEvent(drag, atStart: false)
            NSApp.postEvent(up, atStart: false)
            split.mouseDown(with: down)
        }
        split.onDividerReleased = hooked
        check(released, "hints H7: a press, drag and release on the divider reaches the release hook (the tracking returns on release)")

        // set_layout retires it, and Settings' route (moveTerminal) does.
        only(.terminalBeside)
        var reply = MCPServer.CallResult(text: "", isError: false)
        MCPControl.call("set_layout", ["terminal_position": "right"], caller: nil, approval: .preApprovedByGrant("g-selftest")) { reply = $0 }
        _ = await wait(10) { !reply.text.isEmpty }
        check(HintCenter.shared.record(.terminalBeside).retired == .actionPerformed, "hints H7: set_layout terminal_position retires it", reply.text)
        only(.terminalBeside)
        app.moveTerminal(to: .left, announce: true)
        check(HintCenter.shared.record(.terminalBeside).retired == .actionPerformed, "hints H7: Settings › Terminal's position (moveTerminal) retires it")
        app.terminalPosition = .bottom
        c.applyLayout()
    }

    // MARK: H4

    private static func sendChecks(_ app: AppDelegate, _ c: TerminalWindowController, only: (Hint) -> Void) async {
        guard let window = c.window else { return }
        let fm = FileManager.default
        let dir = canonicalPath(NSTemporaryDirectory()) + "/nt-hint-send-\(getpid())"
        let bin = dir + "-bin"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: bin + "/claude", withDestinationPath: "/bin/cat")
        let file = dir + "/main.swift", secret = dir + "/.env"
        try? (1...30).map { "let line\($0) = \($0)" }.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
        try? "A=1\nB=2\nC=3\n".write(toFile: secret, atomically: true, encoding: .utf8)
        let agentTab: TerminalTab = c.addTab(directory: dir)
        defer {
            c.editorArea.closeAll()
            c.remove(agentTab)
            try? fm.removeItem(atPath: dir)
            try? fm.removeItem(atPath: bin)
        }
        guard await wait(20, { agentTab.status.integrated }) else { return check(false, "hints H4: the agent's tab starts its shell") }
        agentTab.view.send(txt: "\u{15}PATH=\(bin):$PATH claude >/dev/null\r")
        guard await wait(5, { agentTab.status.running && agentTab.status.kind == .agent && c.agentTab === agentTab }) else {
            return check(false, "hints H4: a stand-in agent runs in a tab")
        }
        /// `file` open in front with lines `first`…`last` (one-based) selected and the keyboard in the editor.
        func select(_ path: String, _ first: Int, _ last: Int) -> CodeEditorView? {
            c.openFile(URL(fileURLWithPath: path))
            guard let editor = c.editorArea.activeEditor else { return nil }
            window.makeFirstResponder(editor.textView)
            let starts: [Int] = editor.document.lines.starts
            let end: Int = last < starts.count ? starts[last] - 1 : (editor.document.text as NSString).length
            editor.textView.setSelectedRange(NSRange(location: starts[first - 1], length: max(1, end - starts[first - 1])))
            return editor
        }
        let bar: TabBarView = c.editorArea.tabBar

        only(.sendSelection)
        let editor: CodeEditorView? = select(file, 3, 5)
        let up: Bool = await wait(3) { bar.hint?.hint == .sendSelection }
        if up { await screenshot(c, suffix: "-hint-send-selection") }
        let key: String? = KeyboardShortcuts.shared.key(for: #selector(TerminalWindowController.sendToAgent(_:)))?.display
        let words = HintWords.sendSelection(agent: "Claude Code", key: key)
        let line: HintLine? = bar.hint
        let placed = clearInBar(line, bar)
        let keyboard: Bool = window.firstResponder === editor?.textView
        check(up && placed.ok && line?.button?.title == words.words && line?.button?.toolTip == words.help && keyboard
                && line?.button?.refusesFirstResponder == true,
              "hints H4: three lines selected with an agent waiting put “\(words.words)” in the editor's tab bar, whole, the editor keeping the keyboard",
              "up \(up), \(placed.detail), “\(line?.button?.title ?? "")”, keyboard \(keyboard)")
        // The same phrase as the diff's Ask button for the same agent and key.
        let ask = AskAgentHint()
        ask.set(agent: "Claude Code", tab: agentTab.title, key: key)
        check(ask.title == words.words, "hints H4: its words are the diff's Ask button's", "“\(ask.title)” and “\(words.words)”")
        _ = await wait(1) { HintCenter.shared.record(.sendSelection).shown == 1 }
        line?.button?.performClick(nil)
        let typed: Bool = await wait(4) { agentTab.screenTail(4).joined().contains("main.swift#L3-5") }
        check(typed && HintCenter.shared.record(.sendSelection).retired == .actionPerformed && bar.hint == nil,
              "hints H4: its button types the lines into the agent's prompt and retires it",
              "typed \(typed), \(HintCenter.shared.record(.sendSelection)), screen \(agentTab.screenTail(2).joined(separator: " | "))")

        // One line, or a file that usually holds secrets: nothing.
        only(.sendSelection)
        _ = select(file, 7, 7)
        await pause(0.4)
        let oneLine: Bool = bar.hint == nil && !HintStage.shared.isWaiting(.sendSelection)
        _ = select(secret, 1, 3)
        await pause(0.4)
        let env: Bool = bar.hint == nil
        check(oneLine && env, "hints H4: a one-line selection shows nothing, nor lines of a .env", "one line \(oneLine), .env \(env)")

        // ⌥⌘K from the terminal's selection retires it too, as every Send to Agent does; so does an agent reading the selection.
        only(.sendSelection)
        c.send([ContextItem(path: file, lines: 1...2)])
        check(HintCenter.shared.record(.sendSelection).retired == .actionPerformed, "hints H4: Send to Agent by another route retires it")
        only(.sendSelection)
        _ = select(file, 2, 4)
        var reply = ""
        MCPControl.call("get_editor_selection", [:], caller: nil) { reply = $0.text }
        _ = await wait(5) { !reply.isEmpty }
        check(HintCenter.shared.record(.sendSelection).retired == .actionPerformed, "hints H4: get_editor_selection with lines selected retires it",
              String(reply.prefix(200)))

        // Narrowed, the hint goes before a tab would narrow.
        only(.sendSelection)
        _ = select(file, 3, 6)
        if await wait(3, { bar.hint != nil }) {
            let tabWidth: CGFloat = bar.tabView(at: 0)?.frame.width ?? 0
            let wide: NSRect = window.frame
            var width: CGFloat = wide.width
            var widthWhenGone: CGFloat?
            while width > 640 {
                width -= 20
                window.setFrame(NSRect(x: wide.minX, y: wide.minY, width: width, height: wide.height), display: true)
                window.layoutIfNeeded()
                bar.layoutSubtreeIfNeeded()
                if bar.hint == nil || bar.hint?.isHidden == true {
                    widthWhenGone = bar.tabView(at: 0)?.frame.width
                    break
                }
            }
            window.setFrame(wide, display: true)
            check(widthWhenGone == tabWidth, "hints H4: narrowing the window takes the hint away while the tabs keep their width",
                  "tab \(tabWidth), when it went \(widthWhenGone.map { "\($0)" } ?? "never")")
            await pause(0.2)
        } else {
            check(false, "hints H4: the hint comes back after a reset, for the narrowing check")
        }
        HintStage.shared.resetForTest()
    }

    // MARK: H8

    private static func foldChecks(_ app: AppDelegate, _ c: TerminalWindowController, only: (Hint) -> Void) async {
        guard let git = GitRunner.locateGit() else { return note("hints H8: skipped, no git") }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-hint-fold-\(getpid())"
        try? fm.removeItem(atPath: base)
        let repo = base + "/app"
        let trees: [String] = [base + "/app-wt-one", base + "/app-wt-two", base + "/app-wt-three"]
        try? fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        @discardableResult func sh(_ args: String...) -> String { gitOutput(git, repo, args) }
        try? "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        sh("init", "-q", "-b", "main")
        sh("add", "-A")
        sh("commit", "-q", "-m", "start")
        for (index, tree) in trees.enumerated() { sh("worktree", "add", "-q", "-b", "wt/\(index)", tree) }
        var opened: [TerminalWindowController] = []
        defer {
            for controller in opened where !controller.hasClosed { controller.window?.close() }
            for tree in trees { sh("worktree", "remove", "--force", tree) }
            try? fm.removeItem(atPath: base)
            app.windowColumnExpanded = false
        }
        opened.append(app.openFolder(repo, newWindow: true))
        opened.append(app.openWorktreeWindow(trees[0]))
        opened.append(app.openWorktreeWindow(trees[1]))
        if let window = c.window { _ = await bringToFront(window) }
        let host: WindowColumnHost = c.columnHost
        guard await wait(10, { !app.windowColumns.list.foldable().isEmpty && host.column.list.foldable().first?.worktrees == 2 }) else {
            return check(false, "hints H8: the repository's row has its two worktrees' rows under it", "\(app.windowColumns.list.rows.map(\.name))")
        }

        // With H1 still due, the list shows H1, not H8.
        only(.foldWorktrees)
        UserDefaults.standard.removeObject(forKey: HintRules.key(.columnSide, .retired))
        host.showList()
        _ = await wait(2) { host.hint != nil }
        let first: Hint? = host.hint?.hint
        host.hideList(animated: false)
        check(first == .columnSide, "hints H8: while the column-side hint is due, the list shows it first", "\(String(describing: first))")

        only(.foldWorktrees)
        host.showList()
        let up: Bool = await wait(2) { host.hint?.hint == .foldWorktrees }
        host.list?.layoutSubtreeIfNeeded()
        if up { await screenshot(c, suffix: "-hint-fold-worktrees") }
        let line: HintLine? = host.hint
        let words = HintWords.foldWorktrees(repository: "app")
        check(up && host.hintInList && line?.wordsWhole == true && line?.button?.title == words.words && line?.button?.toolTip == words.help,
              "hints H8: with H1 done, the list open a moment shows “Fold worktrees” at its foot, a button whole",
              "up \(up), “\(line?.button?.title ?? "")”, tip “\(line?.button?.toolTip ?? "")”")
        _ = await wait(1) { HintCenter.shared.record(.foldWorktrees).shown == 1 }
        line?.button?.performClick(nil)
        let folded: Bool = await wait(2) { app.windowColumns.list.foldable().isEmpty && app.windowColumns.list.rows.contains { $0.isFolded } }
        check(folded && HintCenter.shared.record(.foldWorktrees).retired == .actionPerformed && host.hint == nil,
              "hints H8: its button folds the worktrees into the repository's row and retires it",
              "folded \(folded), \(HintCenter.shared.record(.foldWorktrees))")
        host.hideList(animated: false)
        let key: String = app.windowColumns.list.rows.first { $0.isFolded }?.foldKey ?? ""

        // The arrow, as the column's own fold, retires it too.
        only(.foldWorktrees)
        host.column.onFold?(key)
        check(HintCenter.shared.record(.foldWorktrees).retired == .actionPerformed && app.windowColumns.list.foldable().count == 1,
              "hints H8: the row's arrow unfolding or folding retires it", "\(HintCenter.shared.record(.foldWorktrees))")

        // Pinned, a worktree's window more puts it at the column's foot, never beside the rail.
        only(.foldWorktrees)
        app.windowColumnExpanded = true
        _ = await wait(3) { host.shown.form == .expanded }
        opened.append(app.openWorktreeWindow(trees[2]))
        if let window = c.window { _ = await bringToFront(window) }
        let pinned: Bool = await wait(4) { host.hint?.hint == .foldWorktrees }
        if pinned { await screenshot(c, suffix: "-hint-fold-worktrees-pinned") }
        check(pinned && host.hint?.beside == false && host.hint?.superview === host.column && host.hint?.wordsWhole == true,
              "hints H8: pinned, a third worktree's window puts “Fold worktrees” at the column's foot", "up \(pinned), beside \(host.hint?.beside == true)")
        HintStage.shared.resetForTest()
        app.windowColumnExpanded = false
    }

    // MARK: H5

    private static func switchBackChecks(_ app: AppDelegate, _ c: TerminalWindowController, _ other: TerminalWindowController,
                                         only: (Hint) -> Void) async {
        let host: WindowColumnHost = c.columnHost
        only(.switchBack)
        guard let key = KeyboardShortcuts.shared.chord(for: "openProjectPanel:")?.display, let words = HintWords.switchBack(key: key) else {
            return note("hints H5: Open Project… has no key here, so it has no hint")
        }
        // Away from the first window by a click on the second's row, then back: the second switch.
        host.column.onSelect?(other.indexID)
        other.columnHost.column.onSelect?(c.indexID)
        if let window = c.window { _ = await bringToFront(window) }
        let up: Bool = await wait(3) { host.hint?.hint == .switchBack }
        if up { await screenshot(c, suffix: "-hint-switch-back") }
        let line: HintLine? = host.hint
        let help: String = HintWords.switchBackHelp(project: other.project.map { URL(fileURLWithPath: $0).lastPathComponent })
        check(up && line?.words == words && line?.label?.accessibilityRole() == .staticText && line?.label?.toolTip == help && line?.wordsWhole == true,
              "hints H5: the second switch by a click on a row says “\(words)” at that window's column foot, static text, the agent's way as help",
              "up \(up), “\(line?.words ?? "")”, help “\(line?.label?.toolTip ?? "")”")
        // Beside the rail only over the project sidebar: with it hidden, the words wait rather than cover text.
        if line?.beside == true {
            HintStage.shared.hide()
            let wasShown: Bool = c.isSidebarVisible
            c.setSidebarVisible(false)
            await pause(0.3)
            let probe = HintLine(.switchBack, words: words)
            let overText: Bool = host.showHint(probe, inList: false)
            if overText { host.removeHint() }
            c.setSidebarVisible(wasShown)
            check(!overText, "hints H5: with the project sidebar hidden, its words go over no text")
        }
        HintStage.shared.hide()

        // ⌘O, then Return on the other window's row, brings it forward and retires it.
        app.openProjectPanel(nil)
        if await wait(3, { app.welcomeController?.window?.isVisible == true }), let welcome = app.welcomeController, let project = other.project {
            welcome.select(project: project)
            welcome.openSelectedProject()
            check(await wait(3) { other.window?.isKeyWindow == true } && HintCenter.shared.record(.switchBack).retired == .actionPerformed,
                  "hints H5: ⌘O then ↩ on the other window goes back to it and retires the hint", "\(HintCenter.shared.record(.switchBack))")
        } else {
            check(false, "hints H5: ⌘O shows the Welcome list, the other window's project in it")
        }
        app.welcomeController?.close()
        if let window = c.window { _ = await bringToFront(window) }

        // open_project on a project already open retires it.
        only(.switchBack)
        if let project = other.project {
            var reply = ""
            MCPControl.call("open_project", ["path": project], caller: nil) { reply = $0.text }
            _ = await wait(5) { !reply.isEmpty }
            check(HintCenter.shared.record(.switchBack).retired == .actionPerformed, "hints H5: open_project on an open project retires it",
                  String(reply.prefix(200)))
        }
        if let window = c.window { _ = await bringToFront(window) }
        HintStage.shared.resetForTest()
    }

    // MARK: seeding

    /// Each hint new to an install, once: from what the install shows. Run on the real store with every hint's keys
    /// saved by the hints part, which puts them back.
    private static func seedingChecks(_ app: AppDelegate) {
        let defaults = UserDefaults.standard
        func reset(seeded: [Hint]?, firstSeeding: Bool = false) {
            HintRules.reset(defaults)
            if let seeded { defaults.set(seeded.map(\.rawValue), forKey: HintRules.seededHintsKey) } else { defaults.removeObject(forKey: HintRules.seededHintsKey) }
            defaults.set(firstSeeding, forKey: HintRules.seededKey)
        }
        // An install from the first seeding, used before, that chose a terminal position, folded worktrees and rebound
        // Send to Agent: the three it seeded are left alone; the four new ones each get their own fact.
        reset(seeded: nil, firstSeeding: true)
        HintCenter.shared.seed(HintRules.InUse(columnSideChosen: true, terminalPositionChosen: true, worktreesFoldedEver: true,
                                               existingInstall: true, overrides: ["sendToAgent:"]))
        let record = { (hint: Hint) -> HintRules.Record in HintCenter.shared.record(hint) }
        check(record(.columnSide) == .init() && record(.nextAgent) == .init() && record(.columnBasics) == .init(),
              "hints seeding: an install from the first seeding has its three hints left as they were")
        check(record(.terminalBeside).retired == .actionPerformed && record(.foldWorktrees).retired == .actionPerformed
                && record(.sendSelection).retired == .actionPerformed && record(.switchBack).watchFrom != nil && record(.switchBack).retired == nil,
              "hints seeding: a terminal position chosen, worktrees folded and Send to Agent's key rebound retire their hints; switching back is watched",
              Hint.allCases.map { "\($0): \(record($0))" }.joined(separator: "; "))
        let watched: HintRules.HeldBack? = HintRules.heldBack(.switchBack, HintRules.Situation(record: record(.switchBack), now: Date(), sinceKey: 60, windowAge: 600))
        check(watched == .watching, "hints seeding: a watched hint holds back for its two weeks", "\(String(describing: watched))")
        // Seeded once: a fact arriving later changes nothing.
        reset(seeded: Hint.allCases)
        HintCenter.shared.seed(HintRules.InUse(terminalPositionChosen: true, existingInstall: true))
        check(Hint.allCases.allSatisfy { record($0) == .init() }, "hints seeding: a hint seeded once is never seeded again")
        // What the launch reads is the install's own facts.
        let facts: HintRules.InUse = app.hintsInUse
        check(facts.terminalPositionChosen == (defaults.object(forKey: "terminalPosition") != nil)
                && facts.worktreesFoldedEver == (defaults.object(forKey: WindowColumnSettings.foldedKey) != nil)
                && facts.overrides == Set(KeyboardShortcuts.shared.bindings.overrides.keys),
              "hints seeding: the launch reads the terminal position, the fold and the rebound keys as kept", "\(facts)")
        reset(seeded: Hint.allCases)
    }
}
#endif

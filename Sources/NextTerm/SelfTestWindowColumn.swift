import AppKit
import NextTermCore

#if DEBUG
/// The window column, on made-up folders: a project with no git, a git repository and its linked worktree beside it, a
/// ⌘N window and a window with no project. One window shows no column; a second brings the folded column to both, the
/// work area giving it 28 points and the hairline while the sidebar keeps its width and each terminal resizes once;
/// closing it gives them back. With the sidebar on the right the column is at the far right, outside the project files.
/// With the setting off no window shows one, View says Show Window Column, and choosing it brings the column back with
/// Settings' checkbox on. Five windows show five badges in the order they opened, the worktree under its repository; a
/// bell in the worktree's tab behind puts a dot on its badge alone, and a click on it brings that window forward with its
/// tab as it was; a click on a window's own badge does nothing. A narrow window hides its column alone, an unfolded one
/// folds first; the traffic lights keep their room; ⌘B leaves the column; ⌃⌘S folds and unfolds every window's; ⌘1 to ⌘9
/// select tabs beside it, folded or not, and a click on it leaves the keyboard in the terminal. VoiceOver
/// reads each badge's window and marks, and the column agrees with ⌘O's rows. Unfolded, a row whose marks change draws
/// again. Unfolding beside a sidebar of its usual width leaves the sidebar as it is, and the width new windows take. A
/// restore lists its windows in the order they opened, whichever was used last, and each pane starts at its real size.
/// The budget: idle, nothing; a bell, one badge; focus and titles, no draw; a window opening or closing, one layout per
/// column and one rebuild.
/// NEXTTERM_SELFTEST_ONLY=windowColumn runs it alone.
extension SelfTest {
    static func windowColumnChecks() async {
        guard let app = AppDelegate.shared, let git = GitRunner.locateGit() else { return note("window column: skipped, no git") }
        let defaults = UserDefaults.standard
        let saved = (shown: defaults.object(forKey: WindowColumnSettings.shownKey), expanded: defaults.object(forKey: WindowColumnSettings.expandedKey),
                     colors: defaults.object(forKey: ProjectColors.key), next: defaults.object(forKey: ProjectColors.nextKey),
                     colorsShown: defaults.object(forKey: ProjectColors.shownKey), side: app.sidebarSide, sidebar: app.sidebarVisible)
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-wincol-\(getpid())"
        try? fm.removeItem(atPath: base)
        let named = base + "/next-term", repo = base + "/xCloud", tree = base + "/xCloud-wt-7027-sso", loose = base + "/loose"
        for folder in [named, repo, loose] { try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        @discardableResult func sh(_ args: String...) -> String { gitOutput(git, repo, args) }
        try? "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        sh("init", "-q", "-b", "main")
        sh("add", "-A")
        sh("commit", "-q", "-m", "start")
        sh("worktree", "add", "-q", "-b", "sso", tree)
        var windows: [TerminalWindowController] = []
        WindowColumns.suppressed = false
        app.showsWindowColumn = true
        app.windowColumnExpanded = false
        ProjectColorStore.isShown = true
        if app.sidebarSide != .left { app.toggleSidebarSide(nil) }
        app.windowColumns.rebuild()
        defer {
            app.welcomeController?.close()
            for window in windows where !window.hasClosed { window.window?.close() }
            sh("worktree", "remove", "--force", tree)
            try? fm.removeItem(atPath: base)
            if app.sidebarSide != saved.side { app.toggleSidebarSide(nil) }
            restoreDefault(saved.shown, WindowColumnSettings.shownKey)
            restoreDefault(saved.expanded, WindowColumnSettings.expandedKey)
            restoreDefault(saved.colors, ProjectColors.key)
            restoreDefault(saved.next, ProjectColors.nextKey)
            restoreDefault(saved.colorsShown, ProjectColors.shownKey)
            NotificationCenter.default.post(name: ProjectColorStore.changed, object: nil)
            WindowColumns.suppressed = true
            app.windowColumns.rebuild()
        }
        func open(_ path: String?, project: Bool = false) async -> TerminalWindowController? {
            let controller = app.openWindow(directory: path, project: project ? path : nil)
            windows.append(controller)
            guard let tab = controller.activeTab, await wait(20, { tab.status.integrated }) else { return nil }
            controller.refresh()
            return controller
        }
        func closeWindow(_ controller: TerminalWindowController) async {
            controller.window?.close()
            _ = await wait(5) { !app.controllers.contains { $0 === controller } }
        }
        let atStart: [TerminalWindowController] = app.controllers.filter { !$0.hasClosed }
        guard let first = atStart.first, let firstWindow = first.window else { return check(false, "window column: a window to start from") }
        guard await bringToFront(firstWindow) else { return note("window column: skipped, " + notFrontmost(firstWindow)) }
        if !first.isSidebarVisible { first.toggleProjectSidebar(nil) }

        await appearsWithASecondWindowChecks(app, first, alone: atStart.count == 1, open: atStart)
        await rightSideChecks(app, first)
        await settingOffChecks(app, first, open: { await open(loose) }, close: closeWindow)

        // Five windows of every kind, opened in order, after the window the run started with.
        guard let project = await open(named, project: true), let main = await open(repo, project: true) else {
            return check(false, "window column: the two projects' windows open, their shells started")
        }
        let worktree = app.openWorktreeWindow(tree)
        windows.append(worktree)
        guard let treeTab = worktree.activeTab, await wait(20, { treeTab.status.integrated }) else {
            return check(false, "window column: the worktree's window opens, its shell started")
        }
        worktree.refresh()
        app.newWindow(nil)
        guard let home = app.controllers.last, home !== worktree, let homeTab = home.activeTab, await wait(20, { homeTab.status.integrated }) else {
            return check(false, "window column: ⌘N opens a window, its shell started")
        }
        windows.append(home)
        home.refresh()
        guard let plain = await open(loose) else { return check(false, "window column: a window with no project opens, its shell started") }
        // What the checks before left marked is seen, so a bell here is the only mark.
        for controller in app.controllers { for tab in controller.tabs { tab.status.setVisible(true) } }
        await pause(1)
        for controller in app.controllers { controller.refresh() }
        let five: [TerminalWindowController] = [project, main, worktree, home, plain]
        badgeChecks(app, five)
        await screenshot(plain, suffix: "-column-folded")
        await idleBudget(app)
        await bellChecks(app, five, worktree: worktree, tree: tree)
        await unfoldedMarksChecks(app, worktree: worktree)
        await overflowChecks(app, project)
        await roomChecks(app, project)
        await sidebarKeepsItsWidthChecks(app, project)
        await insetChecks(app, project)
        await foldKeyChecks(app, project)
        await tabKeyChecks(app, project)
        await focusBudget(app, [project, main, plain])
        await openCloseBudget(app, open: { await open(loose) }, close: closeWindow)
        await restoreChecks(app, [project, main, plain], close: closeWindow)
    }

    // MARK: AE1: one window, then two

    /// Alone, the window has no column. ⌘N: both have the folded column, counting 2, at their left edge; the work area
    /// gave it 28 points and the hairline, the sidebar kept its width, and each terminal resized once. The second closed:
    /// the column goes and the work area has its width back.
    private static func appearsWithASecondWindowChecks(_ app: AppDelegate, _ first: TerminalWindowController, alone: Bool,
                                                       open: [TerminalWindowController]) async {
        guard alone else {
            return note("window column: AE1 not checked, as \(open.count) windows were open at the start, not one")
        }
        guard let window = first.window else { return }
        window.layoutIfNeeded()
        check(first.columnHost.shown.form == .hidden && first.windowColumn.isHidden,
              "window column: with one window open, it shows no column", "\(first.columnHost.shown)")
        let work: CGFloat = first.workSplit.frame.width
        let sidebar: CGFloat = first.sidebar.frame.width
        let terminals: [NSView] = first.tabs.map { (tab: TerminalTab) -> NSView in tab.view }
        let front: NSView? = first.activeTab?.view
        var resizes = TerminalResizes(terminals)
        app.newWindow(nil)
        guard let second = app.controllers.last, second !== first, let tab = second.activeTab, await wait(20, { tab.status.integrated }) else {
            resizes.stop()
            return check(false, "window column: ⌘N opens a second window")
        }
        window.layoutIfNeeded()
        second.window?.layoutIfNeeded()
        await pause(0.5)
        resizes.stop()
        let both: [TerminalWindowController] = [first, second]
        let folded: Bool = both.allSatisfy { (c: TerminalWindowController) -> Bool in
            c.columnHost.shown.form == .folded && !c.windowColumn.isHidden && c.windowColumn.list.count == 2
                && c.windowColumn.frame.minX == 0 && c.windowColumn.frame.width == WindowColumnWidth.folded + WindowColumnWidth.hairline
        }
        check(folded, "window column: ⌘N shows the folded column in both windows, counting 2, at their left edge",
              both.map { "\($0.columnHost.shown.form) \($0.windowColumn.list.count) \($0.windowColumn.frame)" }.joined(separator: "; "))
        let narrower: CGFloat = work - first.workSplit.frame.width
        let frontOnce: Bool = front.map { resizes.count($0) == 1 } ?? false
        let sizes: String = terminals.map { resizes.sizes($0) }.joined(separator: "; ")
        check(abs(narrower - 29) < 0.5 && abs(first.sidebar.frame.width - sidebar) < 0.5 && frontOnce && resizes.most == 1,
              "window column: the work area gives it 28 points and the hairline, the sidebar keeps its width, and each terminal resizes once",
              "work \(work) → \(first.workSplit.frame.width), sidebar \(sidebar) → \(first.sidebar.frame.width), resized at most \(resizes.most): \(sizes)")
        resizes = TerminalResizes(terminals)
        second.window?.close()
        _ = await wait(5) { !app.controllers.contains { $0 === second } }
        window.layoutIfNeeded()
        await pause(0.3)
        resizes.stop()
        check(first.columnHost.shown.form == .hidden && first.windowColumn.isHidden && abs(first.workSplit.frame.width - work) < 0.5
              && abs(first.sidebar.frame.width - sidebar) < 0.5 && resizes.most == 1,
              "window column: the second closed, the column goes and the work area widens back by exactly as much",
              "\(first.columnHost.shown.form), work \(first.workSplit.frame.width) of \(work), resized at most \(resizes.most): "
                  + terminals.map { resizes.sizes($0) }.joined(separator: "; "))
    }

    // MARK: AE2: the sidebar on the right

    /// With the sidebar on the right the column is at each window's far right, outside the project files, its hairline on
    /// its left and its chevron pointing left, into the window.
    private static func rightSideChecks(_ app: AppDelegate, _ first: TerminalWindowController) async {
        app.toggleSidebarSide(nil)
        defer { if app.sidebarSide == .right { app.toggleSidebarSide(nil) } }
        app.newWindow(nil)
        guard let second = app.controllers.last, second !== first, let tab = second.activeTab, await wait(20, { tab.status.integrated }) else {
            return check(false, "window column: a second window opens with the sidebar on the right")
        }
        defer { second.window?.close() }
        var found: [String] = []
        var right = true
        for c in [first, second] {
            c.window?.layoutIfNeeded()
            let host: WindowColumnHost = c.columnHost
            let column: NSRect = c.windowColumn.frame
            let files: NSRect = c.sidebar.convert(c.sidebar.bounds, to: host)
            let work: NSRect = c.workSplit.convert(c.workSplit.bounds, to: host)
            let outside: Bool = abs(column.maxX - host.bounds.maxX) < 0.5 && files.maxX <= column.minX + 0.5 && work.maxX <= files.minX + 0.5
            right = right && outside && c.windowColumn.onRight && !c.windowColumn.chevronPointsRight && !c.windowColumn.isHidden
            found.append("column \(column), files \(files), work \(work), on right \(c.windowColumn.onRight)")
        }
        await screenshot(second, suffix: "-column-right")
        check(right, "window column: with the sidebar on the right, the column is at each window's right edge, outside the project files, "
              + "its hairline on its left and its chevron pointing into the window", found.joined(separator: "; "))
        app.toggleSidebarSide(nil)
        first.window?.layoutIfNeeded()
        check(first.windowColumn.frame.minX == 0 && !first.windowColumn.onRight && first.windowColumn.chevronPointsRight,
              "window column: back on the left, it is at the left edge again, its chevron pointing right", "\(first.windowColumn.frame)")
    }

    // MARK: AE3: the setting off

    /// With the setting off, a third window opens and no window shows a column; View says Show Window Column, Expand
    /// Window Column is off, and choosing Show brings the column back with Settings' checkbox on. The checkbox turns it
    /// off again and the menu follows.
    private static func settingOffChecks(_ app: AppDelegate, _ first: TerminalWindowController,
                                         open: () async -> TerminalWindowController?,
                                         close: (TerminalWindowController) async -> Void) async {
        guard let second = await open() else { return check(false, "window column: a second window opens") }
        let settings = GeneralSettingsView(frame: .zero)
        app.showsWindowColumn = false
        guard let third = await open() else { return check(false, "window column: a third window opens") }
        let three: [TerminalWindowController] = [first, second, third]
        for c in three { c.window?.layoutIfNeeded() }
        check(three.allSatisfy { $0.columnHost.shown.form == .hidden && $0.windowColumn.isHidden } && settings.windowColumn.state == .off,
              "window column: with the setting off, three windows show no column, and Settings' checkbox is off",
              three.map { "\($0.columnHost.shown.form)" }.joined(separator: ", "))
        let items: [NSMenuItem] = viewMenuItems()
        let hide: NSMenuItem? = items.first { $0.action == #selector(AppDelegate.toggleWindowColumn(_:)) }
        let fold: NSMenuItem? = items.first { $0.action == #selector(AppDelegate.toggleWindowColumnExpanded(_:)) }
        let foldOn: Bool = fold.map(app.validateMenuItem) ?? true
        _ = hide.map(app.validateMenuItem)
        check(hide?.title == "Show Window Column" && fold != nil && !foldOn,
              "window column: View says Show Window Column, and Expand Window Column is off", "\(hide?.title ?? "no item"), fold on \(foldOn)")
        if let hide { app.toggleWindowColumn(hide) }
        for c in three { c.window?.layoutIfNeeded() }
        _ = hide.map(app.validateMenuItem)
        let foldNow: Bool = fold.map(app.validateMenuItem) ?? false
        let shownAgain: Bool = three.allSatisfy { $0.columnHost.shown.form == .folded && $0.windowColumn.list.count >= 3 }
        let boxes: Bool = settings.windowColumn.state == .on && GeneralSettingsView(frame: .zero).windowColumn.state == .on
        let titles: Bool = hide?.title == "Hide Window Column" && fold?.title == "Expand Window Column"
        check(shownAgain && boxes && titles && foldNow,
              "window column: Show Window Column brings it back in every window, with Settings' checkbox on and the menu's titles flipped",
              "\(three.map { "\($0.columnHost.shown.form)" }), checkbox \(settings.windowColumn.state.rawValue), \(hide?.title ?? ""), \(fold?.title ?? "")")
        settings.windowColumn.performClick(nil)
        _ = hide.map(app.validateMenuItem)
        let offByBox: Bool = !app.showsWindowColumn && hide?.title == "Show Window Column" && three.allSatisfy { $0.windowColumn.isHidden }
        settings.windowColumn.performClick(nil)
        check(offByBox && app.showsWindowColumn && defaultsValue(WindowColumnSettings.shownKey) == true,
              "window column: Settings' checkbox turns it off and on, the View menu following, the choice kept")
        // A right-click below the top row offers the same two items.
        let column: WindowColumnView = first.windowColumn
        if let event = rightClick(at: NSPoint(x: 10, y: 200), in: column) {
            let offered: [String] = (column.menu(for: event)?.items ?? []).map { (item: NSMenuItem) -> String in
                _ = app.validateMenuItem(item)
                return item.title
            }
            check(offered == ["Hide Window Column", "Expand Window Column"], "window column: a right-click below its top row offers its two View items",
                  "\(offered)")
        }
        await close(second)
        await close(third)
    }

    // MARK: AE4: five windows

    /// Five windows of every kind, after the window the run started with: a badge each, in the order they opened, the
    /// worktree under its repository with its own part, each with its two letters, the worktree in its repository's colour
    /// and the windows with no project in none; the same in every window's column, each outlining its own; the same
    /// windows as ⌘O lists, with the same marks.
    private static func badgeChecks(_ app: AppDelegate, _ five: [TerminalWindowController]) {
        let ids: [Int] = five.map(\.indexID)
        for c in app.controllers { c.window?.layoutIfNeeded() }
        guard let reference = five.first?.windowColumn.list else { return }
        let ours: [WindowColumnRow] = reference.rows.filter { ids.contains($0.id) }
        let order: [Int] = ours.map(\.id)
        let depths: [Int] = ours.map(\.depth)
        let letters: [String] = ours.map(\.letters)
        let names: [String] = ours.map(\.name)
        // The ⌘N window's folder is where Settings › Terminal starts new windows: "~" at home.
        let home: String = WindowColumnBadge.letters(name: five[3].windowName, kind: five[3].windowKind)
        let expected: [String] = ["NT", "XC", "7S", home, "Lo"]
        let inOrder: Bool = order == ids && depths == [0, 0, 1, 0, 0]
        check(inOrder && letters == expected && names.count == 5 && names[2] == "7027-sso",
              "window column: five windows show five badges in the order they opened, the worktree under its repository's",
              "\(order) of \(ids), depths \(depths), letters \(letters), names \(names)")
        let colors: [ProjectColor?] = ours.map(\.color)
        check(colors[0] != nil && colors[1] != nil && colors[2] == colors[1] && colors[3] == nil && colors[4] == nil,
              "window column: a badge has its project's colour, a worktree its repository's, a window with no project none",
              "\(colors.map { $0?.name ?? "none" })")
        let everywhere: Bool = app.controllers.filter { !$0.hasClosed }.allSatisfy { (c: TerminalWindowController) -> Bool in
            let column: WindowColumnView = c.windowColumn
            let outlined: [Int] = column.shownButtons.filter(\.isCurrent).map(\.id)
            return column.list == reference && outlined == [c.indexID] && column.shownButtons.count == reference.count
        }
        check(everywhere, "window column: every window's column lists the same badges, each outlining its own window's")
        // ⌘O lists the same windows, from the same index, with the same marks.
        app.refreshWindowIndex()
        let index: [WindowIndex.Window] = app.windowIndex.windows
        let switcher: SwitcherList = SwitcherList.build(open: index, history: [], recents: [], servers: [])
        var listed: Set<Int> = []
        for row in switcher.projects where row.isOpen {
            if let window = row.window { listed.insert(window.id) } else {
                for window in index where window.project == row.path { listed.insert(window.id) }
            }
        }
        let column: Set<Int> = Set(reference.rows.map(\.id))
        let marks: Bool = index.allSatisfy { (window: WindowIndex.Window) -> Bool in
            reference.row(window.id)?.marks == window.marks.shown(working: AgentSpinner.current != .off)
        }
        check(listed == column && marks, "window column: it lists the same windows as ⌘O's rows, with the same marks",
              "⌘O \(listed.sorted()), column \(column.sorted())")
    }

    /// A bell in the worktree's tab behind: a dot on its badge alone, in every column, the one button configured once and
    /// drawn twice at most, nothing else drawn or laid out. Its badge and VoiceOver say so. A click on it in another
    /// window's column brings the worktree's window forward with its tab as it was; a click on a window's own badge does
    /// nothing.
    private static func bellChecks(_ app: AppDelegate, _ five: [TerminalWindowController], worktree: TerminalWindowController,
                                   tree: String) async {
        let behind: TerminalTab = worktree.addTab(directory: tree, select: false)
        guard await wait(20, { behind.status.integrated }) else { return check(false, "window column: the worktree's tab behind starts its shell") }
        worktree.select(0)
        await pause(1.5)
        for c in app.controllers { c.refresh() }
        await pause(0.5)
        let columns: [WindowColumnView] = app.controllers.filter { !$0.hasClosed }.map(\.windowColumn)
        columns.forEach { $0.resetCounters() }
        app.windowColumns.resetCounters()
        behind.view.send(txt: "printf '\\a'\r")
        let rang: Bool = await wait(5) { behind.status.state == .attention }
        await pause(1.5) // every window's refresh, a hidden one's once a second
        let id: Int = worktree.indexID
        var dots: [String] = []
        var budget: [String] = []
        var onlyIt = true
        var kept = true
        for column in columns {
            let marked: [Int] = column.shownButtons.filter { $0.row?.urgent != nil }.map(\.id)
            onlyIt = onlyIt && marked == [id] && column.button(for: id)?.row?.urgent == .attention
            dots.append("\(marked)")
            let its: WindowColumnButton? = column.button(for: id)
            let others: [WindowColumnButton] = column.shownButtons.filter { $0.id != id }
            let otherWork: Int = others.reduce(0) { $0 + $1.drawCount + $1.configureCount }
            // Drawn when its window next displays: a window covered by others may not have yet.
            let ok: Bool = its?.configureCount == 1 && (its?.drawCount ?? 3) <= 2 && otherWork == 0 && column.layoutCount == 0
            kept = kept && ok
            budget.append("its button \(its?.configureCount ?? -1) configures, \(its?.drawCount ?? -1) draws; others \(otherWork); "
                          + "\(column.layoutCount) layouts")
        }
        await screenshot(five[0], suffix: "-column-bell")
        check(rang && onlyIt, "window column: a bell in the worktree's tab behind puts a dot on that badge only, in every window",
              "rang \(rang); marked \(dots.joined(separator: " "))")
        note("window column budget: a bell, in each column: " + budget.joined(separator: " | "))
        check(rang && kept, "window column budget: a bell configures that window's badge once and draws it twice at most, and nothing else in any column",
              budget.joined(separator: " | "))
        let button: WindowColumnButton? = five[0].windowColumn.button(for: id)
        let label: String = button?.accessibilityLabel() ?? ""
        check(label == "xCloud ▸ 7027-sso: 1 needs you" && button?.toolTip == "xCloud ▸ 7027-sso\n1 needs you"
              && button?.accessibilityRole() == .button,
              "window column: VoiceOver reads the badge's window and its marks, and so does its tooltip", "\(label) / \(button?.toolTip ?? "")")
        let quiet: WindowColumnButton? = five[0].windowColumn.button(for: five[0].indexID)
        check(quiet?.accessibilityLabel() == five[0].window?.title && quiet?.isAccessibilitySelected() == true
              && five[0].windowColumn.accessibilityLabel() == WindowColumnView.groupLabel(five[0].windowColumn.list.count)
              && five[0].windowColumn.chevronButton.accessibilityLabel() == "Expand Window Column",
              "window column: a window with no marks is read by its title alone, its own selected, the column as “Windows, N open”",
              "\(quiet?.accessibilityLabel() ?? "none"), \(five[0].windowColumn.accessibilityLabel() ?? "")")
        // A click on it from another window's column.
        guard let from = five.last, let fromWindow = from.window, await bringToFront(fromWindow) else {
            return note("window column: the click not checked, as " + notFrontmost(five.last?.window ?? NSWindow()))
        }
        let selected: Int = worktree.activeIndex
        from.windowColumn.button(for: id)?.performClick(nil)
        let forward: Bool = await wait(3) { worktree.window?.isKeyWindow == true }
        check(forward && worktree.activeIndex == selected && behind.status.state == .attention,
              "window column: a click on the worktree's badge brings its window forward with its tab as it was",
              "key \(NSApp.keyWindow?.title ?? "none"), tab \(worktree.activeIndex) of \(selected), behind \(behind.status.state.rawValue)")
        // Its own badge: nothing more.
        worktree.windowColumn.button(for: id)?.performClick(nil)
        await pause(0.3)
        check(worktree.window?.isKeyWindow == true && worktree.activeIndex == selected && behind.status.state == .attention,
              "window column: a click on the window's own badge changes nothing")
    }

    /// Unfolded, a change of a row's marks alone draws that row again, as its name's room ends where its marks start: the
    /// bell in the worktree's tab behind seen, its mark gone, then a bell again. In every column only that row is
    /// configured, once, and drawn (or due to be, in a window not displayed yet); nothing else is drawn or laid out.
    private static func unfoldedMarksChecks(_ app: AppDelegate, worktree: TerminalWindowController) async {
        guard let behind = worktree.tabs.last, worktree.tabs.count > 1 else { return check(false, "window column: the worktree's tab behind is there") }
        app.windowColumnExpanded = true
        defer { app.windowColumnExpanded = false }
        let all: [TerminalWindowController] = app.controllers.filter { !$0.hasClosed }
        for c in all { c.window?.layoutIfNeeded() }
        guard all.allSatisfy({ $0.columnHost.shown.form == .expanded }) else {
            return note("window column: unfolded marks not checked, as a window had no room to unfold its column")
        }
        await pause(1)
        let id: Int = worktree.indexID
        var found: [String] = []
        var drawn = true
        for step in ["seen", "rang again"] {
            let columns: [WindowColumnView] = all.map(\.windowColumn)
            columns.forEach { $0.resetCounters() }
            if step == "seen" {
                behind.status.setVisible(true)
                worktree.refresh()
                await pause(0.5)
            } else {
                behind.view.send(txt: "printf '\\a'\r")
                _ = await wait(5) { behind.status.state == .attention }
                await pause(1.5) // every window's refresh, a hidden one's once a second
            }
            var marks: [String] = []
            for column in columns {
                guard let its = column.button(for: id) else {
                    drawn = false
                    continue
                }
                let others: Int = column.shownButtons.filter { $0.id != id }.reduce(0) { $0 + $1.drawCount + $1.configureCount }
                let redrawn: Bool = its.drawCount >= 1 || its.needsDisplay
                drawn = drawn && its.configureCount == 1 && redrawn && others == 0 && column.layoutCount == 0
                marks.append("\(its.row?.marks.count ?? -1) marks, \(its.configureCount) configures, drawn \(redrawn), others \(others), "
                             + "\(column.layoutCount) layouts")
            }
            found.append(step + ": " + marks.joined(separator: "; "))
        }
        check(drawn, "window column: unfolded, a row whose marks alone change draws again, that row only, in every column",
              found.joined(separator: " | "))
    }

    /// Room for fewer badges than windows: the last place says how many more, in the colour of the most urgent of them,
    /// and opens ⌘O.
    private static func overflowChecks(_ app: AppDelegate, _ c: TerminalWindowController) async {
        guard let window = c.window else { return }
        let frame: NSRect = window.frame
        defer { window.setFrame(frame, display: true) }
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - 240, width: frame.width, height: 240), display: true)
        window.layoutIfNeeded()
        let column: WindowColumnView = c.windowColumn
        let count: Int = column.list.count
        let shown: Int = column.shownButtons.count
        let more: NSButton = column.overflowButton
        check(!more.isHidden && more.title == "+\(count - shown)" && shown > 0 && shown < count,
              "window column: with room for fewer badges than windows, the last place says how many more",
              "\(shown) of \(count) shown, \(more.isHidden ? "no count" : more.title)")
        more.performClick(nil)
        let welcome: Bool = await wait(3) { app.welcomeController?.window?.isVisible == true }
        check(welcome, "window column: its “+N” opens ⌘O, which lists every window")
        app.welcomeController?.close()
    }

    // MARK: AE5: room

    /// Narrowed below the room the column, a minimal sidebar and the work area need (the sidebar narrows with the window), a
    /// window hides its column alone and shows it again when widened, the column's room going to the work area and never
    /// to the sidebar; unfolded, it folds first, and comes back unfolded.
    private static func roomChecks(_ app: AppDelegate, _ c: TerminalWindowController) async {
        guard let window = c.window else { return }
        let frame: NSRect = window.frame
        defer {
            app.windowColumnExpanded = false
            window.setFrame(frame, display: true)
        }
        let sidebar: CGFloat = c.isSidebarVisible ? ProjectSidebarView.minimumWidth + c.outerSplitView.dividerThickness : 0
        let folded: CGFloat = sidebar + WindowColumnWidth.folded + WindowColumnWidth.hairline + WindowColumnWidth.workMinimum
        let unfolded: CGFloat = sidebar + WindowColumnWidth.expanded + WindowColumnWidth.hairline + WindowColumnWidth.workMinimum
        let room: CGFloat = window.screen?.visibleFrame.width ?? 1440
        var steps: [String] = []
        func width(_ w: CGFloat) {
            window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: max(window.minSize.width, w), height: frame.height), display: true)
            window.layoutIfNeeded()
            steps.append("asked \(Int(w)): window \(Int(window.frame.width)), host \(Int(c.columnHost.bounds.width)), sidebar "
                         + "\(Int(c.sidebar.frame.width)), work \(Int(c.workSplit.frame.width)), \(c.columnHost.shown.form)")
        }
        let others: [TerminalWindowController] = app.controllers.filter { $0 !== c && !$0.hasClosed }
        guard folded - 5 >= window.minSize.width else {
            return note("window column: AE5 not checked, as the sidebar (\(sidebar)) leaves no narrower window than its minimum")
        }
        width(folded - 5)
        let hid: Bool = c.columnHost.shown.form == .hidden && c.windowColumn.isHidden && c.columnHost.shown.byRoom
        let othersKept: Bool = others.allSatisfy { $0.columnHost.shown.form == .folded }
        width(folded + 5)
        let back: Bool = c.columnHost.shown.form == .folded && !c.windowColumn.isHidden
        check(hid && othersKept && back, "window column: a window narrowed below its room hides its column alone, and gains it again when widened",
              "at \(folded - 5): hid \(hid), others kept \(othersKept); at \(folded + 5): \(c.columnHost.shown); "
                  + steps.joined(separator: " | "))
        // Narrowed past it again, with the sidebar as narrow as the window's resize left it (under its minimum, this
        // narrow): the column's room goes to the work area, and the sidebar is never made wider than that.
        let before = (sidebar: c.sidebar.frame.width, work: c.workSplit.frame.width)
        width(folded - 5)
        let after = (sidebar: c.sidebar.frame.width, work: c.workSplit.frame.width)
        check(c.columnHost.shown.form == .hidden && after.sidebar <= before.sidebar + 0.5 && after.work > before.work,
              "window column: a window narrowed past its room gives the column's room to the work area, never widening the sidebar",
              "sidebar \(before.sidebar) → \(after.sidebar), work \(before.work) → \(after.work)")
        // Unfolded, it is measured beside the sidebar as the window's resize leaves it: room to spare, then none.
        app.windowColumnExpanded = true
        let wide: CGFloat = min(room, max(frame.width, unfolded + 300))
        width(wide)
        let open: Bool = c.columnHost.shown.form == .expanded
        width(folded + 5)
        let foldedFirst: Bool = c.columnHost.shown.form == .folded && c.columnHost.shown.byRoom && app.windowColumnExpanded
        width(folded - 5)
        let gone: Bool = c.columnHost.shown.form == .hidden
        width(wide)
        let reopened: Bool = c.columnHost.shown.form == .expanded
        check(open && foldedFirst && gone && reopened,
              "window column: unfolded, a narrowed window folds its column first, then hides it, and has it unfolded again when widened",
              "open \(open), folded first \(foldedFirst), gone \(gone), reopened \(reopened); " + steps.joined(separator: " | "))
    }

    /// A sidebar of its usual width, 280, unfolding: in a 680-point window the work area would keep too little beside it,
    /// so the column stays folded; in a 760-point one it unfolds and the work area gives it the room, past the drag's
    /// limit. Either way, and folded again, the sidebar keeps its width, and so does the width new windows take.
    private static func sidebarKeepsItsWidthChecks(_ app: AppDelegate, _ c: TerminalWindowController) async {
        guard let window = c.window else { return }
        let frame: NSRect = window.frame
        let defaults = UserDefaults.standard
        let savedWidth: Any? = defaults.object(forKey: "sidebarWidth")
        defer {
            app.windowColumnExpanded = false
            window.setFrame(frame, display: true)
            restoreDefault(savedWidth, "sidebarWidth")
        }
        if !c.isSidebarVisible { c.toggleProjectSidebar(nil) }
        app.windowColumnExpanded = false
        var found: [String] = []
        var kept = true
        for (across, unfolds) in [(CGFloat(680), false), (CGFloat(760), true)] {
            window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: across, height: frame.height), display: true)
            window.layoutIfNeeded()
            c.placeSidebar(width: 280)
            window.layoutIfNeeded()
            let width: CGFloat = c.sidebar.frame.width
            let saved: CGFloat = app.sidebarWidth
            app.windowColumnExpanded = true
            window.layoutIfNeeded()
            let form: WindowColumnShown.Form = c.columnHost.shown.form
            let open = (width: c.sidebar.frame.width, saved: app.sidebarWidth)
            app.windowColumnExpanded = false
            window.layoutIfNeeded()
            let shut = (width: c.sidebar.frame.width, saved: app.sidebarWidth)
            let same: Bool = abs(open.width - width) < 0.5 && abs(shut.width - width) < 0.5 && open.saved == saved && shut.saved == saved
            kept = kept && same && abs(width - 280) < 0.5 && form == (unfolds ? .expanded : .folded) && c.columnHost.shown.form == .folded
            found.append("\(Int(across)): sidebar \(width), unfolded \(form) \(open.width), folded \(shut.width); "
                         + "new windows' \(saved) → \(open.saved) → \(shut.saved)")
        }
        check(kept, "window column: unfolding beside a sidebar of its usual width keeps it as it is (folded where there is no room), "
              + "and folding again too, with the width new windows take unchanged", found.joined(separator: " | "))
    }

    // MARK: R8 and R9: the traffic lights and ⌘B

    /// On the left outside full screen: folded, a strip of title bar over its chevron, the sidebar header's inset 70 less
    /// the column, and with the sidebar hidden (⌘B, which leaves the column where it is) the corner bar's 78 less it;
    /// unfolded, its header's words after the lights and the others at 8. In full screen it starts at the top.
    private static func insetChecks(_ app: AppDelegate, _ c: TerminalWindowController) async {
        guard let window = c.window else { return }
        defer {
            c.isFullScreen = false
            c.updateInsets()
            app.windowColumnExpanded = false
            if !c.isSidebarVisible { c.toggleProjectSidebar(nil) }
        }
        app.windowColumnExpanded = false
        if !c.isSidebarVisible { c.toggleProjectSidebar(nil) }
        window.layoutIfNeeded()
        let column: WindowColumnView = c.windowColumn
        let width: CGFloat = WindowColumnWidth.folded + WindowColumnWidth.hairline
        // Its hairline starts at the strip's bottom line, so none runs between the lights.
        let foldedLights: Bool = column.topInset == TabBarView.height && c.sidebar.headerInset == max(8, 70 - width)
            && column.hairlineRect.minY == TabBarView.height - 1
        let where1: NSRect = column.frame
        c.toggleProjectSidebar(nil) // ⌘B
        window.layoutIfNeeded()
        let corner: CGFloat = c.editorArea.isHidden ? c.tabBar.leadingInset : c.editorArea.tabBar.leadingInset
        let stays: Bool = column.frame == where1 && !column.isHidden
        check(foldedLights && corner == max(8, 78 - width) && stays,
              "window column: folded on the left, its top is title bar for the traffic lights, the sidebar header's inset and the corner bar's "
                  + "make room for the column, and ⌘B leaves the column in place",
              "top \(column.topInset), hairline from \(column.hairlineRect.minY), sidebar header \(c.sidebar.headerInset), corner \(corner), "
                  + "column \(where1) → \(column.frame)")
        c.toggleProjectSidebar(nil)
        app.windowColumnExpanded = true
        window.layoutIfNeeded()
        let header: Bool = column.topInset == 0 && column.headerLeading == 78 && c.sidebar.headerInset == 8 && column.hairlineRect.minY == 0
        c.toggleProjectSidebar(nil)
        window.layoutIfNeeded()
        let cornerOpen: CGFloat = c.editorArea.isHidden ? c.tabBar.leadingInset : c.editorArea.tabBar.leadingInset
        c.toggleProjectSidebar(nil)
        check(header && cornerOpen == 8, "window column: unfolded on the left, its header's words come after the traffic lights and the bars beside it start at 8",
              "top \(column.topInset), header from \(column.headerLeading), sidebar header \(c.sidebar.headerInset), corner \(cornerOpen)")
        app.windowColumnExpanded = false
        window.layoutIfNeeded()
        c.isFullScreen = true
        c.updateInsets()
        check(column.topInset == 0 && column.headerLeading == 8 && c.sidebar.headerInset == 8 && column.hairlineRect.minY == 0,
              "window column: in full screen it starts at the top, with no room kept for the traffic lights",
              "top \(column.topInset), header from \(column.headerLeading), sidebar header \(c.sidebar.headerInset)")
    }

    // MARK: R17: ⌃⌘S

    /// ⌃⌘S as the keyboard sends it: every window's column unfolds, the View menu says Collapse Window Column and the
    /// choice is kept; again, every one folds.
    private static func foldKeyChecks(_ app: AppDelegate, _ c: TerminalWindowController) async {
        guard let window = c.window, await bringToFront(window) else { return note("window column: ⌃⌘S not checked, as " + notFrontmost(c.window ?? NSWindow())) }
        let chord: KeyChord? = KeyboardShortcuts.shared.chord(for: "toggleWindowColumnExpanded:")
        check(chord?.display == "⌃⌘S", "window column: Expand Window Column has ⌃⌘S", chord?.display ?? "none")
        let all: [TerminalWindowController] = app.controllers.filter { !$0.hasClosed }
        let fold: NSMenuItem? = viewMenuItems().first { $0.action == #selector(AppDelegate.toggleWindowColumnExpanded(_:)) }
        controlCommandS()
        for each in all { each.window?.layoutIfNeeded() }
        let unfolded: Bool = all.allSatisfy { $0.columnHost.shown.form == .expanded } && defaultsValue(WindowColumnSettings.expandedKey) == true
        _ = fold.map(app.validateMenuItem)
        let title: String = fold?.title ?? ""
        let chevron: Bool = !c.windowColumn.chevronPointsRight // unfolded on the left, it points the way it folds
        await screenshot(c, suffix: "-column-expanded")
        controlCommandS()
        for each in all { each.window?.layoutIfNeeded() }
        let refolded: Bool = all.allSatisfy { $0.columnHost.shown.form == .folded } && defaultsValue(WindowColumnSettings.expandedKey) == false
        check(unfolded && title == "Collapse Window Column" && chevron && refolded,
              "window column: ⌃⌘S unfolds the column in every window and folds it again, the choice kept and the menu following",
              "unfolded \(unfolded), menu \(title), chevron left \(chevron), folded again \(refolded)")
    }

    // MARK: ⌘1 to ⌘9

    /// ⌘1 to ⌘8 as the keyboard sends them select a window's first eight tabs and ⌘9 its last, in a window showing the
    /// column folded, then unfolded, then after a real click on the window's own badge: the column takes none of the
    /// keys, and never the keyboard, which stays in the terminal. The keys go ⌘2 to ⌘9, then ⌘1, so each is a switch.
    /// Ten tabs; the nine added close after.
    private static func tabKeyChecks(_ app: AppDelegate, _ c: TerminalWindowController) async {
        guard let window = c.window, await bringToFront(window) else {
            return note("window column: ⌘1 to ⌘9 not checked, as " + notFrontmost(c.window ?? NSWindow()))
        }
        let folder: String = c.project ?? canonicalPath(NSTemporaryDirectory())
        var added: [TerminalTab] = []
        while c.groups.count < 10 { added.append(c.addTab(directory: folder, select: false)) }
        for tab in added { _ = await wait(20) { tab.status.integrated } }
        let codes: [(key: Int, code: UInt16)] = [(2, 19), (3, 20), (4, 21), (5, 23), (6, 22), (7, 26), (8, 28), (9, 25), (1, 18)]
        let expected: [Int] = codes.map { $0.key == 9 ? c.groups.count - 1 : $0.key - 1 }
        /// From the first tab: the tab each key selected, and whether the terminal shown kept the keyboard after every one.
        func pressAll() -> (tabs: [Int], keyboard: Bool) {
            var tabs: [Int] = []
            var keyboard = true
            for (_, code) in codes {
                pressKey(window, code: code, .command)
                tabs.append(c.activeIndex)
                keyboard = keyboard && window.firstResponder === c.activeTab?.view
            }
            return (tabs, keyboard)
        }
        /// `click`: before the keys, a real click on the window's own badge, which reaches it and leaves the keyboard in the
        /// terminal.
        func checkKeys(_ form: WindowColumnShown.Form, _ name: String, click: Bool = false) async {
            // A key sent while another app or window has the keyboard selects nothing here: the window takes it back first.
            if !(NSApp.isActive && window.isKeyWindow), !(await bringToFront(window)) {
                return note("window column: ⌘1 to ⌘9 not checked with the column \(name), as " + notFrontmost(window))
            }
            c.select(0)
            window.layoutIfNeeded()
            let shows: Bool = c.columnHost.shown.form == form && !c.windowColumn.isHidden
            var clicked = true
            if click {
                guard let own = c.windowColumn.button(for: c.indexID), !own.isHidden else {
                    return check(false, "window column: the window's own badge shows, to click",
                                 "\(c.windowColumn.shownButtons.map(\.id)), own \(c.indexID)")
                }
                // The badge's own action proves the click arrived; a click on the window's own badge does nothing more (R18),
                // so it never reaches onSelect: the window stays key, on its first tab, with the keyboard in the terminal.
                let recorder = ClickRecorder(target: own.target, action: own.action)
                own.target = recorder
                own.action = #selector(ClickRecorder.fire(_:))
                clickThroughWindow(own)
                await pause(0.3)
                own.target = recorder.target
                own.action = recorder.action
                clicked = recorder.hits == 1 && window.isKeyWindow && window.firstResponder === c.activeTab?.view && c.activeIndex == 0
            }
            let held: Bool = NSApp.isActive && window.isKeyWindow
            let (tabs, keyboard) = pressAll()
            check(shows && held && clicked && tabs == expected && keyboard,
                  "window column: ⌘1 to ⌘8 select the first eight tabs and ⌘9 the last, in a window showing the column \(name)",
                  "column \(c.columnHost.shown), keyboard held \(held)"
                      + (click ? ", the click reached the badge and left the keyboard in the terminal \(clicked)" : "")
                      + "; selected \(tabs) of \(expected), the terminal kept the keyboard \(keyboard)")
        }
        await checkKeys(.folded, "folded")
        app.windowColumnExpanded = true
        await checkKeys(.expanded, "unfolded")
        app.windowColumnExpanded = false
        await checkKeys(.folded, "folded, after a click on its own badge", click: true)
        for tab in added { c.requestClose(tab) }
        let closed: Bool = await wait(5) { added.allSatisfy { (tab: TerminalTab) -> Bool in !c.tabs.contains { $0 === tab } } }
        _ = await endSheets(over: window)
        check(closed, "window column: the tabs added for ⌘1 to ⌘9 close again", "\(c.groups.count) tabs left")
        c.select(0)
    }

    /// Stands in for a button's target while a check clicks it: counts the clicks that arrive, then sends the button's own action.
    private final class ClickRecorder: NSObject {
        let target: AnyObject?
        let action: Selector?
        private(set) var hits = 0

        init(target: AnyObject?, action: Selector?) {
            self.target = target
            self.action = action
        }

        @objc func fire(_ sender: Any?) {
            hits += 1
            if let action { NSApp.sendAction(action, to: target, from: sender) }
        }
    }

    // MARK: the budget

    /// Five seconds of every window's tick with nothing happening: no column lays out, and no badge configures or draws.
    private static func idleBudget(_ app: AppDelegate) async {
        let columns: [WindowColumnView] = app.controllers.filter { !$0.hasClosed }.map(\.windowColumn)
        await pause(2)
        columns.forEach { $0.resetCounters() }
        app.windowColumns.resetCounters()
        await pause(5)
        let layouts: Int = columns.reduce(0) { $0 + $1.layoutCount }
        let configures: Int = columns.reduce(0) { sum, column in sum + column.shownButtons.reduce(0) { $0 + $1.configureCount } }
        let draws: Int = columns.reduce(0) { sum, column in sum + column.shownButtons.reduce(0) { $0 + $1.drawCount } }
        let numbers = "\(columns.count) columns: \(layouts) layouts, \(configures) configures, \(draws) badge draws, "
            + "\(app.windowColumns.rebuildCount) rebuilds, \(app.windowColumns.passCount) passes"
        note("window column budget: idle, 5 s, " + numbers)
        check(columns.count >= 3 && layouts == 0 && configures == 0 && draws == 0 && app.windowColumns.rebuildCount == 0,
              "window column budget: idle, no column lays out and no badge configures or draws", numbers)
    }

    /// The key window switched across three windows, and a command retitling a tab: no badge draws and no column lays
    /// out (a tooltip may change).
    private static func focusBudget(_ app: AppDelegate, _ three: [TerminalWindowController]) async {
        let columns: [WindowColumnView] = app.controllers.filter { !$0.hasClosed }.map(\.windowColumn)
        await pause(1)
        columns.forEach { $0.resetCounters() }
        app.windowColumns.resetCounters()
        for c in three + three {
            c.window?.makeKeyAndOrderFront(nil)
            await pause(0.4)
        }
        if let tab = three.last?.activeTab {
            three.last?.window?.makeKeyAndOrderFront(nil)
            tab.view.send(txt: "sleep 1\r")
            _ = await wait(3) { tab.status.running }
            await pause(0.6)
            _ = await wait(5) { !tab.status.running }
        }
        await pause(1)
        let layouts: Int = columns.reduce(0) { $0 + $1.layoutCount }
        let draws: Int = columns.reduce(0) { sum, column in sum + column.shownButtons.reduce(0) { $0 + $1.drawCount } }
        let configures: Int = columns.reduce(0) { sum, column in sum + column.shownButtons.reduce(0) { $0 + $1.configureCount } }
        let strips: Int = columns.reduce(0) { $0 + $1.drawCount }
        let numbers = "\(layouts) layouts, \(draws) badge draws, \(configures) configures (tooltips), \(strips) top-row draws (the glow dims "
            + "with the window), \(app.windowColumns.rebuildCount) rebuilds"
        note("window column budget: focus across three windows twice and a retitled tab: " + numbers)
        check(layouts == 0 && draws == 0 && app.windowColumns.rebuildCount == 0,
              "window column budget: switching the key window and retitling a tab draw no badge and lay out no column", numbers)
    }

    /// A window opening, then closing: each other window's column lays out once, the hub makes its list once, and no
    /// terminal elsewhere changes size more than once (none, as the column showed already).
    private static func openCloseBudget(_ app: AppDelegate, open: () async -> TerminalWindowController?,
                                        close: (TerminalWindowController) async -> Void) async {
        let before: [TerminalWindowController] = app.controllers.filter { !$0.hasClosed }
        let columns: [WindowColumnView] = before.map(\.windowColumn)
        let terminals: [NSView] = before.flatMap { $0.tabs.map { (tab: TerminalTab) -> NSView in tab.view } }
        await pause(1)
        columns.forEach { $0.resetCounters() }
        app.windowColumns.resetCounters()
        var resizes = TerminalResizes(terminals)
        guard let extra = await open() else { return check(false, "window column budget: a window opens") }
        for c in before { c.window?.layoutIfNeeded() }
        await pause(1)
        resizes.stop()
        let opened = (layouts: columns.map(\.layoutCount), rebuilds: app.windowColumns.rebuildCount, resized: resizes.most)
        columns.forEach { $0.resetCounters() }
        app.windowColumns.resetCounters()
        resizes = TerminalResizes(terminals)
        await close(extra)
        for c in before { c.window?.layoutIfNeeded() }
        await pause(1)
        resizes.stop()
        let closed = (layouts: columns.map(\.layoutCount), rebuilds: app.windowColumns.rebuildCount, resized: resizes.most)
        let numbers = "opened: layouts \(opened.layouts), \(opened.rebuilds) rebuilds, terminals resized at most \(opened.resized); "
            + "closed: layouts \(closed.layouts), \(closed.rebuilds) rebuilds, resized at most \(closed.resized)"
        note("window column budget: a window opening and closing, " + numbers)
        check(opened.layouts.allSatisfy { $0 == 1 } && opened.rebuilds == 1 && opened.resized <= 1
              && closed.layouts.allSatisfy { $0 == 1 } && closed.rebuilds == 1 && closed.resized <= 1,
              "window column budget: a window opening or closing lays out each other column once and makes the list once", numbers)
    }

    // MARK: R11 and R7 across a restore

    /// Three windows saved as a quit saves them (SessionCapture), after they were used in another order than they opened,
    /// and built back as a launch builds them (RestoreBuild), planned with nothing read of the user's: they are listed in
    /// the order the originals opened, as every window's column and ⌘O read the index, with the one used last in front;
    /// and every restored pane starts its shell at the size it keeps, the column there from the start.
    private static func restoreChecks(_ app: AppDelegate, _ three: [TerminalWindowController],
                                      close: (TerminalWindowController) async -> Void) async {
        // Used last to first: the middle one, the first, the last.
        for c in [three[2], three[0], three[1]] {
            guard let window = c.window, await bringToFront(window) else {
                return note("window column: the restore not checked, as " + notFrontmost(c.window ?? NSWindow()))
            }
            await pause(0.3)
        }
        let saved: [SessionSnapshot.Window] = SessionCapture.windows(three)
        let used: [TerminalWindowController] = three.sorted { $0.lastKey > $1.lastKey }
        let header = SessionSnapshot.Header(launchID: UUID(), generation: 1, clean: true, savedAt: Date())
        let snapshot = SessionSnapshot(header: header, windows: saved)
        let nothing = SessionLookup(read: { (_: AgentKind, _: String, _: Date) -> [AgentSession] in [] },
                                    newest: { (_: AgentKind, _: String, _: Date, _: Set<String>) -> AgentSession? in nil })
        let world = RestorePlanner.World(home: NSHomeDirectory(), checkFolder: { (_: String) -> FolderCheck in .found },
                                         resumeFacts: { (_: SessionSnapshot.Evidence, _: String?, _: [String]) -> ResumeFacts in
                                             ResumeFacts()
                                         }, sessions: nothing)
        let plans: [PanePlan] = RestorePlanner.plan(snapshot, kind: .quit, quitConsent: true, world: world)
        let built: RestoreBuild.Built = RestoreBuild.build(snapshot, planned: RestorePlanning.Planned(plans: plans, folders: [:]),
                                                           scrollback: [:], savedAt: nil)
        guard built.windows.count == 3 else {
            for c in built.windows { await close(c) }
            return check(false, "window column: the restore builds the three windows", "\(built.windows.count)")
        }
        for c in built.windows { c.window?.layoutIfNeeded() }
        await pause(1)
        // The built windows are front to back, as saved: each is the copy of the one used at its place.
        let index: [Int] = app.windowIndex.windows.map(\.id)
        let originals: [Int] = three.map(\.indexID).sorted { (index.firstIndex(of: $0) ?? 0) < (index.firstIndex(of: $1) ?? 0) }
        let copies: [Int] = built.windows.map(\.indexID).sorted { (index.firstIndex(of: $0) ?? 0) < (index.firstIndex(of: $1) ?? 0) }
        let copiedFrom: [Int] = copies.compactMap { (id: Int) -> Int? in
            built.windows.firstIndex { $0.indexID == id }.map { used[$0].indexID }
        }
        let front: Bool = built.windows.first?.window?.isKeyWindow == true
        check(copiedFrom == originals && front && saved.map(\.opened) == used.map { three.firstIndex(of: $0) },
              "window column: a restore lists its windows in the order they opened, whichever was used last, that one in front",
              "copies of \(copiedFrom), opened \(originals); saved places \(saved.map { $0.opened.map(String.init) ?? "none" }); "
                  + "front \(NSApp.keyWindow?.title ?? "none")")
        let panes: [TerminalTab] = built.panes.map(\.tab).filter { $0.remote == nil }
        let sizes: [String] = panes.map { (tab: TerminalTab) -> String in
            let start: String = tab.sizeAtStart.map { "\(Int($0.width))×\(Int($0.height))" } ?? "not started"
            return "\(start) → \(Int(tab.view.frame.width))×\(Int(tab.view.frame.height))"
        }
        let once: Bool = !panes.isEmpty && panes.allSatisfy { (tab: TerminalTab) -> Bool in
            guard let start = tab.sizeAtStart else { return false }
            return abs(start.width - tab.view.frame.width) < 0.5 && abs(start.height - tab.view.frame.height) < 0.5
        }
        let columns: Bool = built.windows.allSatisfy { $0.columnHost.shown.form == .folded && !$0.windowColumn.isHidden }
        check(once && columns, "window column: each restored pane starts its shell at the size it keeps, the column there from the start",
              sizes.joined(separator: "; "))
        for c in built.windows { await close(c) }
    }

    // MARK: helpers

    /// Every item of the View menu, its submenus' too.
    private static func viewMenuItems() -> [NSMenuItem] {
        guard let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu else { return [] }
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
        return all(view)
    }

    private static func defaultsValue(_ key: String) -> Bool? { UserDefaults.standard.object(forKey: key) as? Bool }

    /// A right-click at `point` in `view`'s own coordinates.
    private static func rightClick(at point: NSPoint, in view: NSView) -> NSEvent? {
        guard let window = view.window else { return nil }
        let location: NSPoint = view.convert(point, to: nil)
        return NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    /// A click in the middle of `view` as a hand makes one: the mouse-up waits in the queue, and the mouse-down goes
    /// through the window, which hit-tests it and hands out the keyboard as it does for a real click.
    private static func clickThroughWindow(_ view: NSView) {
        guard let window = view.window else { return }
        let location: NSPoint = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let time: TimeInterval = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, after delay: TimeInterval) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: time + delay, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        guard let down = event(.leftMouseDown, after: 0), let up = event(.leftMouseUp, after: 0.05) else { return }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        // A mouse-up nothing tracked must not arrive later.
        while NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) != nil {}
    }

    /// ⌃⌘S as the keyboard sends it: a CGEvent, so AppKit reads its characters off the layout, sent to the app, which
    /// gives the menus their keys first.
    private static func controlCommandS() {
        guard let key = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 1, keyDown: true) else { return }
        key.flags = [.maskCommand, .maskControl]
        guard let event = NSEvent(cgEvent: key) else { return }
        NSApp.sendEvent(event)
    }
}
#endif

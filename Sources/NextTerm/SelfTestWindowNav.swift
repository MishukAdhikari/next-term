import AppKit
import NextTermCore

/// Many windows, and where to go, on made-up folders: a project's window with a second tab behind its first, a window
/// with no project with one behind its first too, and the Welcome window. Each window's title leads with its name, and
/// the index of every window has each of them, of its kind. A bell rung in a tab behind (the amber mark) makes it wait
/// for you: Agents › Go to Next Agent Needing You goes to the one that rang first, its window in front and its tab
/// selected; seen there, it waits no more, and the next press goes to the other; with none left, a notice says so and
/// nothing moves. The Welcome window gives every window a row, with the marks its tab bar shows: a project's other
/// window under it, saying so, and the window with no project with a terminal in its gutter. The Dock menu lists the
/// window waiting first, and its item goes to the tab. A window closed leaves the index at once, and its row the list.
/// What the checks before left marked in other windows is seen first, so the bells here are the only marks.
/// NEXTTERM_SELFTEST_ONLY=windowNav runs it alone.
extension SelfTest {
    static func windowNavChecks() async {
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-windownav-\(getpid())"
        try? fm.removeItem(atPath: base)
        let shop = base + "/shop", loose = base + "/loose"
        for folder in [shop, loose] { try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        var windows: [TerminalWindowController] = []
        defer {
            app.welcomeController?.close()
            GitToast.dismiss()
            for window in windows where !window.hasClosed { window.window?.close() }
            try? fm.removeItem(atPath: base)
        }
        func open(_ path: String, project: Bool) async -> TerminalWindowController? {
            let controller = app.openWindow(directory: path, project: project ? path : nil)
            windows.append(controller)
            guard let tab = controller.activeTab, await wait(20, { tab.status.integrated }) else { return nil }
            controller.refresh()
            return controller
        }
        guard let project = await open(shop, project: true), let plain = await open(loose, project: false),
              let projectWindow = project.window, let plainWindow = plain.window else {
            return check(false, "window nav: a project's window and a window with no project open, their shells started")
        }
        windowTitleChecks(project, plain)
        windowIndexChecks(app, project, plain)
        guard await bringToFront(projectWindow) else {
            return note("window nav: the keys' checks skipped, as " + notFrontmost(projectWindow))
        }
        await runningTitleChecks(project)

        // A tab behind the first in each window, where a bell marks it: nobody is looking there.
        let behind = project.addTab(directory: shop, select: false)
        let alsoBehind = plain.addTab(directory: loose, select: false)
        guard await wait(20, { behind.status.integrated && alsoBehind.status.integrated }) else {
            return check(false, "window nav: the tabs behind start their shells")
        }
        for controller in app.controllers where !windows.contains(where: { $0 === controller }) {
            for tab in controller.tabs { tab.status.setVisible(true) }
        }
        guard await bringToFront(plainWindow) else { return note("window nav: ⇧⌘U not checked, as " + notFrontmost(plainWindow)) }
        await goToNextChecks(app, project, plain, behind: behind, alsoBehind: alsoBehind)
        await welcomeRowChecks(app, project, plain, behind: behind, windows: &windows)
        await dockMenuChecks(app, project, behind: behind)
        await closedWindowChecks(app, plain)
    }

    /// A bell in `tab`, rung while it is behind another tab: the amber mark, as a program asking for you shows it.
    private static func ring(_ tab: TerminalTab) async -> Bool {
        tab.view.send(txt: "sleep 0.5; printf '\\a'\r")
        return await wait(5) { tab.status.state == .attention }
    }

    /// The window's name first: the project's ("shop", alone at its prompt, as its tab there is named after the folder);
    /// with no project, its tab's folder as a path ("~/…", or the whole path outside the home folder).
    private static func windowTitleChecks(_ project: TerminalWindowController, _ plain: TerminalWindowController) {
        let home: String = FileManager.default.homeDirectoryForCurrentUser.path
        let folder: String = plain.activeTab.map { (tab: TerminalTab) -> String in
            WindowTitle.name(ofFolder: tab.directory, home: home)
        } ?? ""
        check(project.window?.title == "shop" && project.windowKind == .project,
              "window nav: a project's window is titled by its project, the tab at its prompt there not said again",
              project.window?.title ?? "no title")
        check(plain.window?.title == folder && folder.hasSuffix("loose") && plain.windowKind == .plain,
              "window nav: a window with no project is titled by its tab's folder, as a path", plain.window?.title ?? "no title")
    }

    /// With the project's window in front, what runs in its tab follows the project in the title: "shop — sleep". It ends
    /// while seen, so it leaves no mark.
    private static func runningTitleChecks(_ project: TerminalWindowController) async {
        guard let tab = project.activeTab else { return }
        tab.view.send(txt: "sleep 1\r")
        let running: Bool = await wait(3) { tab.status.running }
        project.refresh()
        check(running && project.window?.title == "shop — sleep", "window nav: what runs in front follows the project in the title",
              project.window?.title ?? "no title")
        _ = await wait(5) { !tab.status.running }
        project.refresh()
    }

    /// Every terminal window is in the index, of its kind, named and titled as it is.
    private static func windowIndexChecks(_ app: AppDelegate, _ project: TerminalWindowController,
                                          _ plain: TerminalWindowController) {
        app.refreshWindowIndex()
        let index: WindowIndex = app.windowIndex
        let open: Set<Int> = Set(app.controllers.filter { !$0.hasClosed }.map(\.indexID))
        let listed: Set<Int> = Set(index.windows.map(\.id))
        let ours: WindowIndex.Window? = index.window(project.indexID)
        let theirs: WindowIndex.Window? = index.window(plain.indexID)
        let projectKept: Bool = ours?.kind == .project && ours?.project == project.project && ours?.name == "shop"
        let plainKept: Bool = theirs?.kind == .plain && theirs?.project == nil && theirs?.title == plain.window?.title
        check(open == listed && projectKept && plainKept,
              "window nav: the index has every terminal window, each of its kind, with its name and title",
              "\(listed.count) listed of \(open.count) open; \(ours?.kind.rawValue ?? "missing") \(ours?.name ?? ""); "
                  + "\(theirs?.kind.rawValue ?? "missing") \(theirs?.title ?? "")")
    }

    /// ⇧⌘U from the window with no project: the tab that rang first, in the project's window; seen, the next press goes
    /// to the other, back in this window; then nothing waits, and a notice says so.
    private static func goToNextChecks(_ app: AppDelegate, _ project: TerminalWindowController, _ plain: TerminalWindowController,
                                       behind: TerminalTab, alsoBehind: TerminalTab) async {
        let first: Bool = await ring(behind)
        let second: Bool = await ring(alsoBehind)
        app.refreshWindowIndex()
        let order: [UUID] = app.windowIndex.waiting.map(\.tab)
        check(first && second && order == [behind.id, alsoBehind.id],
              "window nav: the bells make both tabs wait, the one that rang first first",
              "\(behind.status.state.rawValue) \(alsoBehind.status.state.rawValue), \(order.count) waiting")
        app.goToNextAgentNeedingYou(nil)
        let went: Bool = await wait(3) { project.window?.isKeyWindow == true && project.activeTab === behind }
        check(went, "window nav: Go to Next Agent Needing You brings the project's window forward with the tab that rang first",
              "key \(NSApp.keyWindow?.title ?? "none"), its tab \(project.activeTab?.title ?? "none")")
        let seen: Bool = await wait(3) { behind.status.state == .idle }
        app.goToNextAgentNeedingYou(nil)
        let next: Bool = await wait(3) { plain.window?.isKeyWindow == true && plain.activeTab === alsoBehind }
        check(seen && next, "window nav: seen there, it waits no more, and the next press goes to the other window's tab",
              "seen \(seen), key \(NSApp.keyWindow?.title ?? "none"), its tab \(plain.activeTab?.title ?? "none")")
        _ = await wait(3) { alsoBehind.status.state == .idle }
        app.goToNextAgentNeedingYou(nil)
        let said: Bool = await wait(2) { GitToast.text == WindowIndex.nothingWaiting }
        check(said && plain.window?.isKeyWindow == true && plain.activeTab === alsoBehind,
              "window nav: with nothing waiting, a notice says so, and no window or tab changes", GitToast.text ?? "no notice")
        GitToast.dismiss()
    }

    /// The Welcome window's rows: the project's, which goes to its window in front last, with the amber mark of its tab
    /// behind and "2 windows"; its second window's under it ("another window"); the window with no project's, titled as
    /// the window, a terminal in its gutter and "No project" for a folder.
    private static func welcomeRowChecks(_ app: AppDelegate, _ project: TerminalWindowController, _ plain: TerminalWindowController,
                                         behind: TerminalTab, windows: inout [TerminalWindowController]) async {
        let path: String = project.project ?? ""
        let second: TerminalWindowController = app.openFolder(path, newWindow: true)
        windows.append(second)
        _ = await wait(5) { second.window?.isVisible == true }
        guard let projectWindow = project.window, await bringToFront(projectWindow) else {
            return note("window nav: the Welcome window's rows not checked, as the project's window could not come forward")
        }
        project.select(0)
        guard await ring(behind) else { return check(false, "window nav: the tab behind rings again, for the Welcome window") }
        app.showWelcome(nil)
        guard let welcome = app.welcomeController, await wait(3, { welcome.window?.isVisible == true }) else {
            return check(false, "window nav: the Welcome window shows")
        }
        let list: WelcomeSwitcherList = welcome.switcherList
        func row(_ found: (SwitcherProject) -> Bool) -> SwitcherProjectCell? {
            list.shown.projects.firstIndex(where: found).flatMap { (index: Int) -> SwitcherProjectCell? in list.projectCell(at: index) }
        }
        let isProject = { (row: SwitcherProject) -> Bool in row.path == path && row.window == nil }
        let marked: Bool = await wait(3) { row(isProject)?.shownMarks.contains { $0.state == .attention } == true }
        let projectCell: SwitcherProjectCell? = row(isProject)
        check(marked && projectCell?.shownFolder.hasSuffix("2 windows") == true,
              "window nav: ⌘O's row for a project shows the amber mark of its window's tab that needs you, and its two windows",
              "\(projectCell?.shownMarks.map(\.state.rawValue) ?? []), \(projectCell?.shownFolder ?? "no row")")
        let otherCell: SwitcherProjectCell? = row { (row: SwitcherProject) -> Bool in row.window?.id == second.indexID }
        check(otherCell?.shownFolder.hasSuffix("another window") == true && otherCell?.shownMarks.isEmpty == true,
              "window nav: its second window has a row of its own, saying “another window”, with no mark",
              otherCell?.shownFolder ?? "no row")
        let plainCell: SwitcherProjectCell? = row { (row: SwitcherProject) -> Bool in row.window?.id == plain.indexID }
        check(plainCell?.shownName == plain.window?.title && plainCell?.shownSymbol == true
              && plainCell?.shownFolder == SwitcherText.noProject,
              "window nav: a window with no project has a row, titled as the window, a terminal in its gutter",
              "\(plainCell?.shownName ?? "no row") / \(plain.window?.title ?? "")")
        welcome.close()
        second.window?.close()
        _ = await wait(5) { !app.controllers.contains { $0 === second } }
    }

    /// The Dock menu lists the window waiting first, with its mark, and its item goes to the tab that needs you.
    private static func dockMenuChecks(_ app: AppDelegate, _ project: TerminalWindowController, behind: TerminalTab) async {
        let menu: NSMenu? = app.applicationDockMenu(NSApp)
        let first: NSMenuItem? = menu?.items.first
        check(first?.tag == project.indexID && first?.title == project.window?.title && first?.image != nil,
              "window nav: the Dock menu lists the window waiting for you first, with its mark", first?.title ?? "no item")
        guard let first, first.tag == project.indexID else { return }
        app.goToWaitingWindow(first)
        let went: Bool = await wait(3) { project.window?.isKeyWindow == true && project.activeTab === behind }
        check(went, "window nav: its Dock menu item brings the window forward with the tab that needs you",
              "key \(NSApp.keyWindow?.title ?? "none")")
    }

    /// Closed, a window leaves the index at once: nothing goes to it, and the Welcome window lists it no more.
    private static func closedWindowChecks(_ app: AppDelegate, _ plain: TerminalWindowController) async {
        let id: Int = plain.indexID
        plain.window?.close()
        check(app.windowIndex.window(id) == nil, "window nav: a window closed leaves the index at once")
        app.showWelcome(nil)
        guard let welcome = app.welcomeController else { return }
        let gone: Bool = await wait(3) {
            !welcome.switcherList.shown.projects.contains { (row: SwitcherProject) -> Bool in row.window?.id == id }
        }
        check(gone, "window nav: and the Welcome window has no row for it")
        welcome.close()
    }
}

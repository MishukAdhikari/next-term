import AppKit
import NextTermCore
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    // Set in main.swift before the app runs; every window controller talks to it.
    nonisolated(unsafe) static var shared: AppDelegate!

    private(set) var controllers: [TerminalWindowController] = []
    private(set) var isTerminating = false
    private var lastBadge = -1
    /// Last notification per tab, to rate-limit noisy programs.
    private var lastNotified: [UUID: (at: Date, key: String)] = [:]

    var fontSize: CGFloat {
        get {
            let saved = UserDefaults.standard.double(forKey: "fontSize")
            return saved > 0 ? CGFloat(saved) : Theme.defaultFontSize
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "fontSize") }
    }

    var sidebarVisible: Bool {
        get { UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sidebarVisible") }
    }

    var sidebarWidth: CGFloat {
        get {
            let saved = UserDefaults.standard.double(forKey: "sidebarWidth")
            return saved >= 160 ? CGFloat(saved) : ProjectSidebarView.defaultWidth
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "sidebarWidth") }
    }

    /// Where the terminal sits relative to the editor.
    enum TerminalPosition: String, CaseIterable {
        case bottom, right, left, top
        var title: String { rawValue.capitalized }
    }

    enum SidebarSide: String { case left, right }

    var terminalPosition: TerminalPosition {
        get { TerminalPosition(rawValue: UserDefaults.standard.string(forKey: "terminalPosition") ?? "") ?? .bottom }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "terminalPosition") }
    }

    var sidebarSide: SidebarSide {
        get { SidebarSide(rawValue: UserDefaults.standard.string(forKey: "sidebarSide") ?? "") ?? .left }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "sidebarSide") }
    }

    @objc func setTerminalPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let position = TerminalPosition(rawValue: raw) else { return }
        terminalPosition = position
        controllers.forEach { $0.applyLayout() }
    }

    /// Long lines in the editor wrap at the edge (on unless turned off).
    var softWrap: Bool {
        get { UserDefaults.standard.object(forKey: "softWrap") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "softWrap") }
    }

    @objc func toggleSoftWrap(_ sender: Any?) {
        softWrap.toggle()
        controllers.forEach { $0.editorArea.applyWrap() }
    }

    @objc func toggleSidebarSide(_ sender: Any?) {
        sidebarSide = sidebarSide == .left ? .right : .left
        controllers.forEach { $0.applyLayout() }
    }

    /// How much of the work area open files get; the terminal has the rest.
    var editorFraction: CGFloat {
        get {
            let saved = UserDefaults.standard.double(forKey: "editorFraction")
            return saved >= 0.15 && saved <= 0.9 ? CGFloat(saved) : 0.62
        }
        set { UserDefaults.standard.set(Double(min(0.9, max(0.15, newValue))), forKey: "editorFraction") }
    }

    /// Notifications need a real bundle (`swift run` has none).
    private var notificationCenter: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        setUpNotifications()
        // Write the shell integration before the first shell starts. Without it tabs fall back to process polling.
        if AppSupport.zshIntegrationDirectory == nil { NSLog("Next Term: could not install zsh integration") }
        NSApp.activate(ignoringOtherApps: true)
        // `nxtrm` in a terminal, while Next Term runs.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(commandLineRequest(_:)),
                                                            name: .init(CommandLineOpen.notificationName), object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        if SelfTest.isRequested {
            newWindow(nil)
            SelfTest.run()
            return
        }
        CommandLineTool.registerQuietly()
        // `nxtrm` started us: open what it asked for, not the last session.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--open-request"), flag + 1 < arguments.count,
           let command = try? JSONDecoder().decode(OpenCommand.self, from: Data(arguments[flag + 1].utf8)) {
            handle(command)
            if !controllers.isEmpty { return }
        }
        // A folder dropped on the app or `open -a "Next Term" dir` arrives before this and opens itself.
        guard controllers.isEmpty else { return }
        if !reopenLastProjects() { chooseStartingFolder() }
    }

    // MARK: nxtrm

    @objc private func commandLineRequest(_ notification: Notification) {
        guard let text = notification.userInfo?["request"] as? String,
              let command = try? JSONDecoder().decode(OpenCommand.self, from: Data(text.utf8)),
              command.app == Bundle.main.bundlePath else { return } // another copy of Next Term's request
        handle(command)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens what `nxtrm` asked for: folders as projects, files in the editor at their line.
    func handle(_ command: OpenCommand) {
        if command.items.isEmpty {
            if command.newWindow || controllers.isEmpty { newWindow(nil) }
            return
        }
        for item in command.items {
            if item.isDirectory {
                openFolder(item.path, newWindow: command.newWindow)
            } else {
                openFile(item.path, line: item.line, column: item.column ?? 1, newWindow: command.newWindow)
            }
        }
    }

    /// A folder from outside (nxtrm, Finder): its window if it is open, an unused window, or a new one.
    private func openFolder(_ path: String, newWindow: Bool) {
        let path = canonicalPath(path)
        recent.add(path)
        welcome?.close()
        if !newWindow, let open = controllers.first(where: { $0.project == path }) {
            open.window?.makeKeyAndOrderFront(nil)
        } else if !newWindow, let unused = controllers.first(where: \.isPristine) {
            unused.adoptProject(path)
            unused.window?.makeKeyAndOrderFront(nil)
        } else {
            openWindow(directory: path, project: path)
        }
    }

    /// A file from outside: in the window whose project holds it, else the front window, else a new window
    /// on the file's project (its git root, or its folder).
    private func openFile(_ path: String, line: Int?, column: Int, newWindow: Bool) {
        let path = canonicalPath(path)
        let owners = controllers.filter { controller in controller.project.map { path.hasPrefix($0 + "/") } ?? false }
        let owner = owners.max { ($0.project?.count ?? 0) < ($1.project?.count ?? 0) }
        let front = (NSApp.keyWindow?.windowController as? TerminalWindowController) ?? controllers.last
        let target: TerminalWindowController
        if !newWindow, let window = owner ?? front {
            target = window
        } else {
            let root = ProjectRoot.find(from: (path as NSString).deletingLastPathComponent)
            recent.add(root)
            target = openWindow(directory: root, project: root)
        }
        welcome?.close()
        target.window?.makeKeyAndOrderFront(nil)
        target.openFile(URL(fileURLWithPath: path), line: line, column: column)
    }

    @objc func installCommandLineTool(_ sender: Any?) {
        CommandLineTool.install(from: NSApp.keyWindow)
    }

    /// The project windows open when Next Term last quit, so it starts where you left off.
    private var sessionProjects: [String] {
        get { UserDefaults.standard.stringArray(forKey: "sessionProjects") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "sessionProjects") }
    }

    /// Reopens the projects from last time, or the most recent one. False when there is none to reopen.
    @discardableResult
    private func reopenLastProjects() -> Bool {
        let last = sessionProjects.isEmpty ? Array(recent.paths.prefix(1)) : sessionProjects
        let existing = last.filter(isFolder)
        for path in existing { openWindow(directory: path, project: path) }
        return !existing.isEmpty
    }

    private func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The first launch (or when the last folder is gone): ask where to start. That folder opens as the
    /// project, and next time Next Term opens there by itself.
    private func chooseStartingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose the folder to work in. Next Term opens it as a project, and reopens it next time."
        let code = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Code")
        panel.directoryURL = isFolder(code.path) ? code : URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url, isFolder(url.path) {
            let path = canonicalPath(url.path)
            recent.add(path)
            openWindow(directory: path, project: path)
        } else {
            newWindow(nil) // a terminal in the home folder; ⌘O opens a project any time
        }
    }

    private func setUpNotifications() {
        guard let center = notificationCenter, !SelfTest.isRequested else { return }
        center.delegate = self
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon with no windows open: back to the last project, else a terminal.
        if !flag, welcome?.window?.isVisible != true {
            if let path = recent.existing().first { openWindow(directory: path, project: path) } else { newWindow(nil) }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = controllers.flatMap(\.editorArea.dirtyDocuments)
        if !dirty.isEmpty && !SelfTest.isRequested {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = dirty.count == 1 ? "Save changes to “\(dirty[0].name)” before quitting?"
                : "Save changes to \(dirty.count) files before quitting?"
            alert.informativeText = "Your changes are lost if you don’t save them."
            alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save").keyEquivalent = "d"
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard controllers.allSatisfy({ $0.editorArea.saveAll() }) else { return .terminateCancel }
            case .alertThirdButtonReturn:
                break
            default:
                return .terminateCancel
            }
        }
        let busy = controllers.flatMap(\.busyTabs)
        if !busy.isEmpty && !SelfTest.isRequested {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Quit Next Term?"
            alert.informativeText = "Quitting stops " + TerminalWindowController.stopList(busy)
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        isTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !SelfTest.isRequested { sessionProjects = controllers.compactMap(\.project) }
        for controller in controllers { for tab in controller.tabs { tab.terminate() } }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controllers.forEach { $0.refreshVisibility() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        controllers.forEach { $0.refreshVisibility() }
    }

    // MARK: windows

    @discardableResult
    func openWindow(directory: String?, project: String? = nil) -> TerminalWindowController {
        let controller = TerminalWindowController(directory: directory, project: project)
        controller.onClose = { [weak self] closed, closedProject in
            // Defer: the window is still mid-close in this call.
            DispatchQueue.main.async {
                guard let self else { return }
                self.controllers.removeAll { $0 === closed }
                self.updateBadge()
                // Closing the last project leaves the Welcome window, with recent projects, like an IDE.
                if closedProject && self.controllers.isEmpty && !self.isTerminating { self.showWelcome(nil) }
            }
        }
        welcome?.close()
        // Cascade from the terminal window in front (not the About panel or a sheet), at its size unless it
        // is in full screen, and never below the minimum.
        let front = (NSApp.keyWindow?.windowController as? TerminalWindowController)?.window ?? controllers.last?.window
        if let previous = front, previous.isVisible, let window = controller.window {
            var frame = previous.styleMask.contains(.fullScreen) ? window.frame : previous.frame
            frame.size.width = max(frame.width, window.minSize.width)
            frame.size.height = max(frame.height, window.minSize.height)
            window.setFrame(frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        } else {
            controller.window?.center()
        }
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(directory: nil)
    }

    // MARK: projects

    private var recent: RecentProjects {
        get { RecentProjects(UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []) }
        set { UserDefaults.standard.set(newValue.paths, forKey: "recentProjects") }
    }

    var recentProjects: [String] { recent.existing() }

    /// Where Open Project goes when the current window is in use: ask, this window, or a new one.
    enum ProjectTarget: String { case ask, thisWindow, newWindow }

    var projectTarget: ProjectTarget {
        get { ProjectTarget(rawValue: UserDefaults.standard.string(forKey: "openProjectsIn") ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "openProjectsIn") }
    }

    private var welcome: WelcomeWindowController?

    /// ⌘O: choose a folder to open as a project.
    @objc func openProjectPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a project folder"
        let from = NSApp.keyWindow?.windowController as? TerminalWindowController
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openProject(at: url, from: from)
        }
        if let window = from?.window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    @objc func openRecentProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openProject(at: URL(fileURLWithPath: path), from: NSApp.keyWindow?.windowController as? TerminalWindowController)
    }

    @objc func clearRecentProjects(_ sender: Any?) {
        recent = RecentProjects()
    }

    @objc func setProjectTarget(_ sender: NSMenuItem) {
        if let target = sender.representedObject as? String, let value = ProjectTarget(rawValue: target) { projectTarget = value }
    }

    /// Opens a folder as a project. Reuses an untouched window; otherwise this window or a new one,
    /// as the user chooses (and may remember), like an IDE.
    func openProject(at url: URL, from controller: TerminalWindowController?) {
        let path = canonicalPath(url.path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” is not a folder."
            alert.runModal()
            recent.remove(path)
            return
        }
        recent.add(path)
        welcome?.close()
        if let open = controllers.first(where: { $0.project == path }) {
            open.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let target = controller ?? controllers.last(where: { $0.window?.isVisible == true }) else {
            openWindow(directory: path, project: path)
            return
        }
        if target.isPristine {
            target.adoptProject(path)
            target.window?.makeKeyAndOrderFront(nil)
            return
        }
        var choice = projectTarget
        if choice == .ask {
            let alert = NSAlert()
            alert.messageText = "Where do you want to open “\(url.lastPathComponent)”?"
            alert.informativeText = "You can open it in a new window, or in this window in place of its tabs."
            alert.addButton(withTitle: "New Window")
            alert.addButton(withTitle: "This Window")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Remember my choice"
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn: choice = .newWindow
            case .alertSecondButtonReturn: choice = .thisWindow
            default: return
            }
            if alert.suppressionButton?.state == .on { projectTarget = choice }
        }
        if choice == .newWindow {
            openWindow(directory: path, project: path)
            return
        }
        // This window: its tabs make way for the project's, so ask if that would stop anything.
        let busy = target.busyTabs
        if !busy.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = target.project == nil ? "Replace the tabs in this window?" : "Replace the project in this window?"
            alert.informativeText = "This stops " + TerminalWindowController.stopList(busy)
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        target.adoptProject(path)
        target.window?.makeKeyAndOrderFront(nil)
    }

    /// Folders dropped on the Dock icon, or `open -a "Next Term" ~/Code/app`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                openProject(at: url, from: NSApp.keyWindow?.windowController as? TerminalWindowController)
            } else {
                openFile(url.path, line: nil, column: 1, newWindow: false) // Finder's Open With
            }
        }
    }

    @objc func showWelcome(_ sender: Any?) {
        if welcome == nil { welcome = WelcomeWindowController() }
        welcome?.showWindow(nil)
        welcome?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "").target = self
        let projects = recentProjects
        if !projects.isEmpty {
            menu.addItem(.separator())
            for path in projects.prefix(8) {
                let item = menu.addItem(withTitle: (path as NSString).lastPathComponent, action: #selector(openRecentProject(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = path
                item.toolTip = path
            }
        }
        return menu
    }

    /// Open Recent and Open Projects In are rebuilt each time they open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu.title == "Open Recent" {
            let projects = recentProjects
            for path in projects {
                let item = menu.addItem(withTitle: (path as NSString).lastPathComponent, action: #selector(openRecentProject(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = path
                let title = NSMutableAttributedString(string: (path as NSString).lastPathComponent)
                title.append(Typography.gap(10, font: .menuFont(ofSize: 0)))
                title.append(NSAttributedString(string: RecentProjects.abbreviate(path), attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
                item.attributedTitle = title
                item.toolTip = path
            }
            if !projects.isEmpty { menu.addItem(.separator()) }
            let clear = menu.addItem(withTitle: "Clear Menu", action: projects.isEmpty ? nil : #selector(clearRecentProjects(_:)), keyEquivalent: "")
            clear.target = self
        } else if menu.title == "Open Projects In" {
            for (title, value) in [("Ask Each Time", ProjectTarget.ask), ("This Window", .thisWindow), ("New Window", .newWindow)] {
                let item = menu.addItem(withTitle: title, action: #selector(setProjectTarget(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = value.rawValue
                item.state = projectTarget == value ? .on : .off
            }
        }
    }

    /// ⌘T with no window open (every window closed, app still running).
    @objc func newTab(_ sender: Any?) {
        newWindow(sender)
    }

    // MARK: Option as Meta

    @objc func toggleOptionAsMeta(_ sender: Any?) {
        Preferences.optionAsMeta.toggle()
        for controller in controllers { for tab in controller.tabs { tab.view.optionAsMetaKey = Preferences.optionAsMeta } }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleOptionAsMeta(_:)) { item.state = Preferences.optionAsMeta ? .on : .off }
        if item.action == #selector(setTerminalPosition(_:)) {
            item.state = item.representedObject as? String == terminalPosition.rawValue ? .on : .off
        }
        if item.action == #selector(toggleSidebarSide(_:)) { item.state = sidebarSide == .right ? .on : .off }
        if item.action == #selector(toggleSoftWrap(_:)) { item.state = softWrap ? .on : .off }
        return true
    }

    // MARK: font size

    @objc func increaseFontSize(_ sender: Any?) { setFontSize(fontSize + 1) }
    @objc func decreaseFontSize(_ sender: Any?) { setFontSize(fontSize - 1) }
    @objc func resetFontSize(_ sender: Any?) { setFontSize(Theme.defaultFontSize) }

    private func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, Theme.fontSizeRange.lowerBound), Theme.fontSizeRange.upperBound)
        fontSize = clamped
        controllers.forEach { $0.applyFontSize(clamped) }
    }

    // MARK: dock badge and notifications

    func updateBadge() {
        let count = controllers.reduce(0) { $0 + $1.unseenTabCount }
        guard count != lastBadge else { return }
        lastBadge = count
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    /// Posts a system notification for a background tab, only when Next Term is not in front:
    /// while you are in the app, the tab dot says it already.
    func post(_ notice: TabNotice, tab: TerminalTab, in controller: TerminalWindowController) {
        guard let center = notificationCenter else { return }
        let program = Typography.shortened(notice.program, to: 60)
        let content = UNMutableNotificationContent()
        if let question = notice.question {
            // An agent is blocked on a decision: say so even while Next Term is in front (the tab itself
            // is not on screen, or there would be no notice). Clicking it opens the tab.
            content.title = "\(program.isEmpty ? "The agent" : program) needs your decision"
            content.subtitle = Typography.shortened(tab.title, to: 80)
            content.body = question
        } else {
            // Finished work: only when you are in another app; in Next Term the tab mark says it.
            guard !NSApp.isActive else { return }
            content.title = Typography.shortened(tab.title, to: 80)
            switch notice.state {
            case .done:
                // Only an agent that is still running is waiting; one that exited (`claude -p …`) finished.
                content.body = notice.kind == .agent && notice.stillRunning
                    ? "\(program) is waiting for you" : "\(program.isEmpty ? "Command" : program) finished"
            case .failed:
                content.body = "\(program.isEmpty ? "Command" : program) failed" + (tab.status.exitCode.map { " (exit \($0))" } ?? "")
            case .attention:
                content.body = "\(program.isEmpty ? "The terminal" : program) needs your attention"
            case .idle, .working:
                return
            }
        }
        // One per tab every 10 s unless it says something new; each replaces the tab's previous one.
        let key = content.title + "\u{0}" + content.body
        if let last = lastNotified[tab.id], Date().timeIntervalSince(last.at) < 10, last.key == key { return }
        lastNotified[tab.id] = (Date(), key)
        content.sound = .default
        content.userInfo = ["tab": tab.id.uuidString]
        center.add(UNNotificationRequest(identifier: tab.id.uuidString, content: content, trigger: nil))
    }

    /// Show banners even while Next Term is in front (decisions in tabs you are not looking at).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let tabID = response.notification.request.content.userInfo["tab"] as? String
        DispatchQueue.main.async { [self] in
            NSApp.activate(ignoringOtherApps: true)
            for controller in controllers {
                if let index = controller.tabs.firstIndex(where: { $0.id.uuidString == tabID }) {
                    controller.window?.makeKeyAndOrderFront(nil)
                    controller.select(index)
                    break
                }
            }
            completionHandler()
        }
    }

    // MARK: menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Next Term")
        app.addItem(withTitle: "About Next Term", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        item(app, "Install Command Line Tool (nxtrm)…", #selector(installCommandLineTool(_:)), "", target: self)
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Next Term", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Next Term", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let shell = submenu(main, "Shell")
        item(shell, "New Tab", #selector(TerminalWindowController.newTab(_:)), "t")
        item(shell, "New Window", #selector(newWindow(_:)), "n", target: self)
        shell.addItem(.separator())
        item(shell, "Open Project…", #selector(openProjectPanel(_:)), "o", target: self)
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        shell.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = recentMenu
        let targetMenu = NSMenu(title: "Open Projects In")
        targetMenu.delegate = self
        shell.addItem(withTitle: "Open Projects In", action: nil, keyEquivalent: "").submenu = targetMenu
        item(shell, "Close Project", #selector(TerminalWindowController.closeProject(_:)), "")
        shell.addItem(.separator())
        item(shell, "Save", #selector(TerminalWindowController.saveDocument(_:)), "s")
        item(shell, "Save All", #selector(TerminalWindowController.saveAllDocuments(_:)), "s", [.command, .option])
        shell.addItem(.separator())
        item(shell, "Rename Tab…", #selector(TerminalWindowController.renameTab(_:)), "r", [.command, .option])
        item(shell, "Use Option as Meta Key", #selector(toggleOptionAsMeta(_:)), "", target: self)
        shell.addItem(.separator())
        item(shell, "Close Tab", #selector(TerminalWindowController.closeTab(_:)), "w")
        item(shell, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])

        let edit = submenu(main, "Edit")
        item(edit, "Undo", Selector(("undo:")), "z")
        item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "").submenu = find
        findItem(find, "Find…", .showFindPanel, "f")
        findItem(find, "Find Next", .next, "g")
        findItem(find, "Find Previous", .previous, "g", [.command, .shift])
        findItem(find, "Use Selection for Find", .setFindString, "e")
        find.addItem(.separator())
        item(find, "Find in Files…", #selector(TerminalWindowController.findInFiles(_:)), "f", [.command, .shift])
        item(find, "Replace in Files…", #selector(TerminalWindowController.replaceInFiles(_:)), "r", [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Go to Line…", #selector(TerminalWindowController.goToLine(_:)), "l")
        item(edit, "Comment Line", #selector(CodeTextView.toggleComment(_:)), "/")
        item(edit, "Indent", #selector(CodeTextView.indentSelection(_:)), "]")
        item(edit, "Outdent", #selector(CodeTextView.outdentSelection(_:)), "[")
        edit.addItem(.separator())
        item(edit, "Clear Buffer", #selector(TerminalWindowController.clearBuffer(_:)), "k")

        let view = submenu(main, "View")
        item(view, "Hide Project Sidebar", #selector(TerminalWindowController.toggleProjectSidebar(_:)), "b") // title follows the state
        item(view, "Focus Editor", #selector(TerminalWindowController.toggleEditorFocus(_:)), "`", [.control]) // title follows the focus
        view.addItem(.separator())
        let positions = NSMenu(title: "Terminal Position")
        for position in TerminalPosition.allCases {
            let entry = item(positions, position.title, #selector(setTerminalPosition(_:)), "", target: self)
            entry.representedObject = position.rawValue
        }
        view.addItem(withTitle: "Terminal Position", action: nil, keyEquivalent: "").submenu = positions
        item(view, "Soft Wrap", #selector(toggleSoftWrap(_:)), "", target: self)
        item(view, "Project Sidebar on the Right", #selector(toggleSidebarSide(_:)), "", target: self)
        view.addItem(.separator())
        item(view, "Bigger", #selector(increaseFontSize(_:)), "+", target: self)
        let biggerAlt = item(view, "Bigger", #selector(increaseFontSize(_:)), "=", target: self)
        biggerAlt.isHidden = true
        biggerAlt.allowsKeyEquivalentWhenHidden = true
        item(view, "Smaller", #selector(decreaseFontSize(_:)), "-", target: self)
        item(view, "Actual Size", #selector(resetFontSize(_:)), "0", target: self)
        view.addItem(.separator())
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let window = submenu(main, "Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        item(window, "Show Next Tab", #selector(TerminalWindowController.showNextTab(_:)), "]", [.command, .shift])
        item(window, "Show Previous Tab", #selector(TerminalWindowController.showPreviousTab(_:)), "[", [.command, .shift])
        window.addItem(.separator())
        for n in 1...9 {
            let tabItem = item(window, n == 9 ? "Select Last Tab" : "Select Tab \(n)",
                               #selector(TerminalWindowController.selectTabByNumber(_:)), "\(n)")
            tabItem.tag = n
        }
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        item(window, "Welcome to Next Term", #selector(showWelcome(_:)), "", target: self)
        NSApp.windowsMenu = window

        return main
    }

    private func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }

    @discardableResult
    private func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                      _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
        return item
    }

    private func findItem(_ menu: NSMenu, _ title: String, _ action: NSFindPanelAction, _ key: String,
                          _ modifiers: NSEvent.ModifierFlags = .command) {
        let item = self.item(menu, title, #selector(NSTextView.performFindPanelAction(_:)), key, modifiers)
        item.tag = Int(action.rawValue)
    }
}

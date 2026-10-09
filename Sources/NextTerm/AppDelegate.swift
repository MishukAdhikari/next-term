import AppKit
import NextTermCore
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate, NSMenuItemValidation {
    // Set in main.swift before the app runs; every window controller talks to it.
    nonisolated(unsafe) static var shared: AppDelegate!

    private(set) var controllers: [TerminalWindowController] = []
    private(set) var isTerminating = false
    private var lastBadge = -1
    /// Last notification per tab, to rate-limit noisy programs.
    private var lastNotified: [UUID: (at: Date, key: String)] = [:]
    /// When a notification last played its sound: tabs finishing together make one sound, not one each.
    var lastSoundAt = Date.distantPast

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

    /// The editor's line height, as a multiple of the font's natural line height (1.35: readable code).
    static let lineHeights: [CGFloat] = [1.0, 1.15, 1.25, 1.35, 1.5, 1.75, 2.0]

    var editorLineHeight: CGFloat {
        get {
            let saved = UserDefaults.standard.double(forKey: "editorLineHeight")
            return saved >= 1 && saved <= 2.5 ? CGFloat(saved) : 1.35
        }
        set {
            UserDefaults.standard.set(Double(min(2.5, max(1, newValue))), forKey: "editorLineHeight")
            controllers.forEach { $0.editorArea.applyFont() }
        }
    }

    @objc func setLineHeight(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { editorLineHeight = CGFloat(value) }
    }

    // MARK: Claude Code link

    /// Claude Code in a tab sees the editor's selection (and ⌥⌘K goes straight into its prompt).
    var shareWithClaude: Bool {
        get { UserDefaults.standard.object(forKey: "shareWithClaude") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "shareWithClaude")
            if newValue { startClaudeLink() } else { ClaudeIDEServer.shared.stop(); GeminiIDEServer.shared.stop() }
        }
    }

    // MARK: MCP

    /// Any AI agent can drive Next Term through its MCP server (`nxtrm mcp`): list projects and tabs,
    /// start agents, give them prompts, read their screens. On unless turned off in Settings.
    var agentControl: Bool {
        get { UserDefaults.standard.object(forKey: "agentControl") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "agentControl")
            if newValue { startAgentControl() } else { MCPControlServer.shared.stop(); MCPRegistration.update(on: false) }
        }
    }

    func startAgentControl() {
        MCPControlServer.shared.start(path: SelfTest.isRequested ? SelfTest.mcpSocketPath : nil)
        MCPRegistration.update(on: true)
    }

    /// Which tab each connected `claude` runs in.
    private(set) var claudeTabs: [ClaudeIDEServer.ClientID: Weak<TerminalTab>] = [:]

    private func startClaudeLink() {
        let server = ClaudeIDEServer.shared
        server.onClientReady = { [weak self] client, pid in
            guard let self else { return }
            let tabs = self.controllers.flatMap(\.tabs)
            if let pid, let tab = ClaudeIDEServer.tab(for: pid, among: tabs) { self.claudeTabs[client] = Weak(tab) }
            // It starts with whatever the editor shows now.
            let window = self.claudeTabs[client]?.value.flatMap { tab in self.controllers.first { $0.tabs.contains { $0 === tab } } }
            (window ?? self.controllers.last)?.shareSelectionWithClaude(only: [client])
        }
        server.onClientGone = { [weak self] client in self?.claudeTabs.removeValue(forKey: client) }
        // opencode connects without the token: only from a process in one of these shells (IDEPeer).
        server.tabShells = { [weak self] in
            guard let self else { return [] }
            let tabs = self.controllers.flatMap(\.tabs).filter { $0.remote == nil }
            return tabs.map { $0.view.process.shellPid }
        }
        // Claude's proposed edits: shown as a diff in the window of the tab it runs in.
        server.onOpenDiff = { [weak self] client, path, proposed, tabName in
            guard let self else { return }
            let tab = self.claudeTabs[client]?.value
            let controller = tab.flatMap { tab in self.controllers.first { $0.tabs.contains { $0 === tab } } }
                ?? (NSApp.keyWindow?.windowController as? TerminalWindowController) ?? self.controllers.last
            guard let controller else { return ClaudeIDEServer.shared.resolveDiff(tabName, accepted: false, text: nil) }
            let original: String = {
                guard isRegularFile(path), let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let (text, _) = TextFile.decode(data) else { return "" }
                return text
            }()
            let proposal = DiffPane.Proposal(original: original, proposed: proposed, author: "Claude", tag: tabName, client: client)
            controller.editorArea.openProposal(for: canonicalPath(path), proposal: proposal) { accepted, text in
                ClaudeIDEServer.shared.resolveDiff(tabName, accepted: accepted, text: text)
            }
        }
        server.onCloseDiffs = { [weak self] client, names in
            guard let self else { return }
            for controller in self.controllers {
                for pane in controller.editorArea.proposals where pane.proposal?.client == client && names.contains(pane.proposal?.tag ?? "") {
                    controller.editorArea.close(pane)
                }
            }
        }
        server.start(workspaces: controllers.compactMap(\.project))
        let gemini = GeminiIDEServer.shared
        gemini.onOpenDiff = { [weak self] path, proposed in
            guard let self, let controller = (NSApp.keyWindow?.windowController as? TerminalWindowController) ?? self.controllers.last else { return }
            let original = isRegularFile(path) ? ((try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { TextFile.decode($0)?.text } ?? "") : ""
            // One proposal per file: a new one replaces the old.
            for pane in controller.editorArea.proposals where pane.proposal?.tag == "gemini:" + path { controller.editorArea.close(pane) }
            let proposal = DiffPane.Proposal(original: original, proposed: proposed, author: "Gemini", tag: "gemini:" + path, client: nil)
            controller.editorArea.openProposal(for: canonicalPath(path), proposal: proposal) { accepted, text in
                GeminiIDEServer.shared.decided(path, accepted: accepted, content: text)
            }
        }
        gemini.onCloseDiff = { [weak self] path in
            for controller in self?.controllers ?? [] {
                for pane in controller.editorArea.proposals where pane.proposal?.tag == "gemini:" + path {
                    controller.editorArea.close(pane)
                }
            }
        }
        gemini.start(workspaces: agentWorkspaces)
        enableAgentIDEModes()
    }

    /// Gemini CLI and Qwen Code read their IDE switch when they start: keep it on while Next Term's is.
    func enableAgentIDEModes() {
        if agentControl { MCPRegistration.update(on: true) } // Gemini can drop it when it rewrites its settings
        guard shareWithClaude, !SelfTest.isRequested else { return } // the self-test never edits your settings
        DispatchQueue.global(qos: .utility).async {
            for file in AgentIDESettings.settingsFiles() { AgentIDESettings.ensureEnabled(file, overridingOff: true) }
        }
    }

    /// Every folder a tab works in (projects, the sidebar's roots, each tab's own root): Gemini CLI and
    /// Qwen Code connect only from inside one of these.
    var agentWorkspaces: [String] {
        var roots: [String] = []
        for controller in controllers {
            if let project = controller.project { roots.append(project) }
            if let root = controller.sidebar.root?.path { roots.append(root) }
            roots += controller.tabs.map { ProjectRoot.find(from: $0.directory) }
        }
        var seen = Set<String>()
        return roots.map(canonicalPath).filter { seen.insert($0).inserted }
    }

    /// The `claude` clients whose tab is in `controller` (and, for the key window, ones whose tab is unknown).
    func claudeClients(in controller: TerminalWindowController) -> Set<ClaudeIDEServer.ClientID> {
        var result = Set<ClaudeIDEServer.ClientID>()
        for client in ClaudeIDEServer.shared.clients where client.ready {
            if let tab = claudeTabs[client.id]?.value {
                if controller.tabs.contains(where: { $0 === tab }) { result.insert(client.id) }
            } else if NSApp.keyWindow === controller.window {
                result.insert(client.id)
            }
        }
        return result
    }

    func claudeClient(for tab: TerminalTab) -> ClaudeIDEServer.ClientID? {
        claudeTabs.first { $0.value.value === tab }?.key
    }

    /// The open projects, so a `claude` started in another terminal inside one finds Next Term too.
    func projectsChanged() {
        ClaudeIDEServer.shared.updateWorkspaces(controllers.compactMap(\.project))
        GeminiIDEServer.shared.updateWorkspaces(agentWorkspaces)
        updateCopilotFolders()
    }

    /// Brand icons on configuration folders (.github, .claude, .idea); off: they stay plain and quiet.
    var iconsOnDotFolders: Bool {
        get { UserDefaults.standard.bool(forKey: "iconsOnDotFolders") }
        set {
            UserDefaults.standard.set(newValue, forKey: "iconsOnDotFolders")
            controllers.forEach { $0.sidebar.outline.reloadData() }
        }
    }

    /// One click on a file in the project sidebar opens it, in a preview tab (off: a double-click does, as
    /// in Finder). Read at each click, so it applies to every window at once. Turning it off keeps every
    /// preview as an ordinary tab.
    var sidebarSingleClickOpens: Bool {
        get { UserDefaults.standard.bool(forKey: "sidebarSingleClickOpens") }
        set {
            UserDefaults.standard.set(newValue, forKey: "sidebarSingleClickOpens")
            if !newValue { controllers.forEach { $0.editorArea.keepPreview() } }
        }
    }

    @objc func toggleSidebarSingleClick(_ sender: Any?) {
        sidebarSingleClickOpens.toggle()
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

    /// The values in .env files drawn as bullets, for screen shares (off unless turned on). Changing it
    /// also undoes each file's own choice from the View menu.
    var hidesEnvValues: Bool {
        get { UserDefaults.standard.bool(forKey: "hideEnvValues") }
        set {
            UserDefaults.standard.set(newValue, forKey: "hideEnvValues")
            controllers.forEach { $0.editorArea.applyEnvValuesSetting() }
        }
    }

    /// Who last changed each line, in a column beside the line numbers (off unless turned on).
    var blameAnnotations: Bool {
        get { UserDefaults.standard.bool(forKey: "blameAnnotations") }
        set { UserDefaults.standard.set(newValue, forKey: "blameAnnotations") }
    }

    @objc func toggleBlameAnnotations(_ sender: Any?) {
        blameAnnotations.toggle()
        applyBlame(announce: blameAnnotations)
    }

    /// The caret line's last commit, dimmed after its text (off unless turned on).
    var currentLineBlame: Bool {
        get { UserDefaults.standard.bool(forKey: "currentLineBlame") }
        set { UserDefaults.standard.set(newValue, forKey: "currentLineBlame") }
    }

    @objc func toggleCurrentLineBlame(_ sender: Any?) {
        currentLineBlame.toggle()
        applyBlame(announce: currentLineBlame)
    }

    /// Turning blame on says so when the file in front has none (outside git, too large).
    private func applyBlame(announce: Bool) {
        controllers.forEach { $0.editorArea.applyBlame(announce: announce && $0.window?.isKeyWindow == true) }
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

    /// Where a launch reads Settings › General and the flag "Relaunch Now" leaves. The update that keeps sessions
    /// passes its test harness's own suite here.
    let launchDefaults = UserDefaults.standard
    /// Kept remote tabs (tmux, herdr) wait for the first terminal window: they never open one of their own while the
    /// Welcome window is up.
    private(set) var remoteRestorePending = false
    /// A folder or file came through `application(_:open:)`. Read once, as the launch finishes: the launch named one.
    private var openedAtLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        RemotePoller.shared.start() // status of remote tabs, from their hosts
        // Claude Code's IDE link, before the first tab so every tab can use it.
        if shareWithClaude { startClaudeLink() }
        if shareWithCopilot { startCopilotLink() } // Copilot CLI's, in CopilotIDE.swift
        // The MCP socket too: tabs are told where it is. Off, the Claude app may still have the entry: it was
        // open when the setting was turned off, and closed after Next Term.
        if agentControl { startAgentControl() } else { MCPRegistration.update(on: false, claudeAppOnly: true) }
        MCPRegistration.watchClaudeApp()
        // The menus as built are the defaults, read before they are the menu bar (which keeps one item per key).
        let menu = buildMenu()
        KeyboardShortcuts.shared.capture(menu)
        NSApp.mainMenu = menu
        setUpNotifications()
        // Fetches the open repositories now and then (Settings › Editor › Git); in the self-test, only its own.
        BackgroundFetcher.shared.start()
        // Write the shell integration before the first shell starts. Without it tabs fall back to process polling.
        if AppSupport.zshIntegrationDirectory == nil { NSLog("Next Term: could not install zsh integration") }
        NSApp.activate(ignoringOtherApps: true)
        // `nxtrm` in a terminal, while Next Term runs.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(commandLineRequest(_:)),
                                                            name: .init(CommandLineOpen.notificationName), object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        if SelfTest.isRequested {
            // A normal launch, with the Welcome window whatever is saved and no import offer. The self-test's first
            // check opens the window the others use.
            openAtLaunch(kind: .normal, settings: LaunchSettings(), mayOfferImport: false)
            restoreRemoteTabsOnceAWindowOpens()
            SelfTest.run()
            return
        }
        // `nxtrm` started us: what it asked for opens, and the launch shows nothing more. A folder dropped on the app,
        // `open -a "Next Term" dir` and Finder's Open With usually arrive before this and open themselves.
        let command = Self.openRequest(in: CommandLine.arguments)
        // First, so the flag "Relaunch Now" leaves never outlives the launch after it.
        let kind = Self.takeLaunchKind(request: command != nil || openedAtLaunch, defaults: launchDefaults, now: Date())
        // `nxtrm` in other terminals: linked where that needs no password, else offered once with one.
        CommandLineTool.registerQuietly()
        MainActor.assumeIsolated { Updater.shared.start() }
        // An update's disk image and folder that a quit or a crash left mid-staging.
        Updater.removeLeftovers()
        // Skill updates, once a day, for Agents › Skills…' count.
        MainActor.assumeIsolated { SkillsUpdateCheck.start() }
        if let command { handle(command) }
        let show = { [self] in
            openAtLaunch(kind: kind)
            restoreRemoteTabsOnceAWindowOpens()
        }
        // A launch to open a document can get it just after this: a turn later, its window is open, and the launch
        // shows nothing more.
        let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if isDefault { show() } else { DispatchQueue.main.async { show() } }
    }

    /// What `nxtrm` asked for, when it started Next Term (`--open-request`).
    private static func openRequest(in arguments: [String]) -> OpenCommand? {
        guard let flag = arguments.firstIndex(of: "--open-request"), flag + 1 < arguments.count else { return nil }
        return try? JSONDecoder().decode(OpenCommand.self, from: Data(arguments[flag + 1].utf8))
    }

    /// The relaunch after "Relaunch Now" (the flag `Updater.flagRelaunch` left, 0 to 15 minutes old), else a launch
    /// that named a folder or file, else a normal one. The flag is taken either way. Until the update that keeps
    /// sessions, whose launch hook tells its relaunch.
    static func takeLaunchKind(request: Bool, defaults: UserDefaults, now: Date) -> LaunchKind {
        let flagged = defaults.object(forKey: Updater.relaunchFlagKey) as? Date
        defaults.removeObject(forKey: Updater.relaunchFlagKey)
        if LaunchDecision.isUpdateRelaunch(flaggedAt: flagged, now: now) { return .updateRelaunch }
        return request ? .request : .normal
    }

    /// What a launch shows, and a Dock click with no window (LaunchDecision): the projects to reopen, the Welcome
    /// window, or on the first run "Coming from another app?" and then the Welcome window. Nothing more once a
    /// terminal window is open. Settings › General is read each time, so a change applies from the next one.
    private func openAtLaunch(kind: LaunchKind) {
        let settings = LaunchSettings(defaults: launchDefaults)
        let offered = UserDefaults.standard.bool(forKey: "importOffered")
        openAtLaunch(kind: kind, settings: settings, mayOfferImport: !offered && recentProjects.isEmpty)
    }

    private func openAtLaunch(kind: LaunchKind, settings: LaunchSettings, mayOfferImport: Bool) {
        // Nothing restores yet: the update that keeps sessions fills in `restore`.
        let input = LaunchInput(kind: kind, restore: .notRun, terminalWindowOpen: !controllers.isEmpty, settings: settings,
                                sessionProjects: sessionProjects, recentProjects: recent.paths, mayOfferImport: mayOfferImport)
        switch LaunchDecision.opening(input, exists: isFolder) {
        case .nothing: break
        case .reopen(let paths): for path in paths { openWindow(directory: path, project: path) }
        case .welcome: showWelcome(nil)
        case .importThenWelcome: offerImportThenWelcome()
        }
    }

    /// Kept remote tabs reattach once the launch has a terminal window: now if it opened one, else when the first one
    /// opens (`openWindow`).
    private func restoreRemoteTabsOnceAWindowOpens() {
        if controllers.isEmpty { remoteRestorePending = true } else { restoreRemoteTabs() }
    }

    private func restoreRemoteTabs() {
        remoteRestorePending = false
        // A turn later: the window may have closed by then, and the Welcome window come back, so the tabs wait for the
        // next one rather than open a window of their own. Closed while the restore reads the login shell, in the first
        // seconds after launch, they still open one, until the update that keeps sessions holds them.
        DispatchQueue.main.async { [self] in
            if controllers.isEmpty { remoteRestorePending = true } else { RemoteConnection.restoreTabs() }
        }
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

    /// A folder from outside (nxtrm, Finder, an agent): its window if it is open, an unused window, or a new one.
    @discardableResult
    func openFolder(_ path: String, newWindow: Bool) -> TerminalWindowController {
        let path = canonicalPath(path)
        recent.add(path)
        welcome?.close()
        if !newWindow, let open = controllers.first(where: { $0.project == path }) {
            open.window?.makeKeyAndOrderFront(nil)
            return open
        } else if !newWindow, let unused = controllers.first(where: \.isPristine) {
            unused.adoptProject(path)
            unused.window?.makeKeyAndOrderFront(nil)
            return unused
        } else {
            return openWindow(directory: path, project: path)
        }
    }

    /// A file from outside: in the window whose project holds it, else the front window, else a new window
    /// on the file's project (its git root, or its folder).
    func openFile(_ path: String, line: Int?, column: Int, newWindow: Bool) {
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

    private var settings: SettingsWindowController?

    @objc func showSettings(_ sender: Any?) { showSettings(tab: nil) }

    /// Settings, on the tab it was left on, or on `tab` ("skills", SettingsWindowController's identifiers).
    func showSettings(tab: String?) {
        // The Claude app may have been opened since the last pass: what waits for it to quit, under the setting, is
        // worked out again (nothing is written while it is open).
        MCPRegistration.update(on: agentControl, claudeAppOnly: true)
        if settings == nil { settings = SettingsWindowController() }
        settings?.reload()
        if let tab { settings?.showTab(tab) }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        MainActor.assumeIsolated { Updater.shared.check(userInitiated: true) }
    }

    @objc func toggleAutomaticUpdates(_ sender: Any?) {
        MainActor.assumeIsolated { Updater.shared.automaticChecks.toggle() }
    }

    @objc func installCommandLineTool(_ sender: Any?) {
        CommandLineTool.install(from: NSApp.keyWindow)
    }

    /// The project windows open when Next Term last quit: a launch reopens them when Settings › General says so, and
    /// the relaunch after "Relaunch Now" does whatever it says. Written at every quit, so changing the setting later
    /// works.
    private var sessionProjects: [String] {
        get { UserDefaults.standard.stringArray(forKey: "sessionProjects") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "sessionProjects") }
    }

    private func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The first run: "Coming from another app?" when an app to import from is found (only once), then the Welcome
    /// window, which lists the projects brought over and their agents' sessions.
    private func offerImportThenWelcome() {
        guard !ImportSources.detect().isEmpty else { return showWelcome(nil) }
        UserDefaults.standard.set(true, forKey: "importOffered")
        ImportWindowController.shared.showChooser(firstRun: true) { [weak self] _ in
            // Not when a window opened meanwhile (`nxtrm`, a folder dropped on the Dock icon).
            guard let self, self.controllers.isEmpty else { return }
            self.showWelcome(nil)
        }
    }

    private func setUpNotifications() {
        guard let center = notificationCenter, !SelfTest.isRequested else { return }
        center.delegate = self
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, welcome?.window?.isVisible != true else { return true }
        // Windows open but none visible (every one minimized): the one used last comes back, and nothing else
        // (no second window for its project, nor AppKit's own reopen on top).
        if let last = controllers.max(by: { $0.lastKey < $1.lastKey }), let window = last.window {
            if window.isMiniaturized { window.deminiaturize(nil) } else { window.makeKeyAndOrderFront(nil) }
            return false
        }
        // Only the Welcome window, minimized: it comes back (opening the last project would close it).
        if let window = welcome?.window, window.isMiniaturized {
            window.deminiaturize(nil)
            return false
        }
        // No windows open: what Settings › General says, the Welcome window or the most recent project. AppKit's own
        // reopen adds nothing. A moment later, as `nxtrm` with no window open sends its request and this reopen in
        // either order: when the request has opened its window, or the Welcome window is up, nothing more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            guard controllers.isEmpty, welcome?.window?.isVisible != true else { return }
            openAtLaunch(kind: .dockReopen)
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Set while a quit asks its questions. They are app-modal, and main-queue work still runs under them (a download
    /// that ends, an MCP call): a second quit then is cancelled, and "Relaunch Now" is not offered (`Updater`).
    var askingToQuit = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !askingToQuit else { return .terminateCancel }
        askingToQuit = true
        defer { askingToQuit = false }
        guard askBeforeQuitting() else { return .terminateCancel }
        isTerminating = true
        // A skill change part-way finishes, and records its Undo, before Next Term quits.
        SkillsStore.waitForChanges()
        return .terminateNow
    }

    /// The quit's questions (QuitPolicy), one at a time: the save-changes and "Quitting stops…" alerts whenever they
    /// apply, as always, with the reopen question on one of them, or else on its own. False when one cancels the
    /// quit. The reopen answer is saved only once the quit goes ahead.
    private func askBeforeQuitting() -> Bool {
        let dirty = controllers.flatMap(\.editorArea.dirtyDocuments)
        let projects = openProjects
        let settings = LaunchSettings(defaults: launchDefaults)
        let sheetAttached = NSApp.windows.contains { $0.attachedSheet != nil }
        let busyCount = controllers.flatMap(\.busyTabs).count
        let input = QuitInput(unsavedFiles: dirty.count, busyTabs: busyCount, projectWindows: projects.count,
                              sheetAttached: sheetAttached, reason: quitReason, settings: settings)
        let questions: [QuitQuestion] = QuitPolicy.questions(input)
        guard !questions.isEmpty else { return true }
        // A quit from the Dock while Next Term is behind another app: its first question shows in front.
        NSApp.activate(ignoringOtherApps: true)
        var answer: QuitAnswer?
        var busyCheckbox: Bool?
        for question in questions {
            switch question {
            case .saveChanges(let checkbox):
                let alert = Self.saveBeforeQuittingAlert(dirty.map(\.name))
                let reopen = checkbox.map { QuitReopenPrompt.addCheckbox(to: alert, checked: $0, projects: projects) }
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    guard controllers.allSatisfy({ $0.editorArea.saveAll() }) else { return false }
                case .alertThirdButtonReturn:
                    break
                default:
                    return false
                }
                if let reopen { answer = .checkbox(checked: reopen.state == .on) }
            case .busy(let checkbox):
                busyCheckbox = checkbox // asked below, once the busy tabs are read again
            case .reopen(let returnKeyReopens):
                let prompt = QuitReopenPrompt(projects: projects, returnKeyReopens: returnKeyReopens)
                guard let reopen = prompt.run() else { return false }
                answer = reopen
            }
        }
        // Read again, as today: a tab that turned busy under a question before still gets "Quitting stops…". Only the
        // alert the policy chose carries the checkbox, so the question is never asked twice; when that alert no longer
        // applies, nothing is asked about reopening and the setting stays as it is.
        let busy = controllers.flatMap(\.busyTabs)
        if !busy.isEmpty {
            let alert = Self.quitStopsAlert(busy)
            let reopen = busyCheckbox.map { QuitReopenPrompt.addCheckbox(to: alert, checked: $0, projects: projects) }
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if let reopen { answer = .checkbox(checked: reopen.state == .on) }
        }
        if let answer { QuitPolicy.settings(after: answer, from: settings).save(to: launchDefaults) }
        return true
    }

    /// Why this quit happens: the self-test, "Relaunch Now", a logout, restart or shutdown (the quit Apple event), or
    /// else the user.
    private var quitReason: QuitReason {
        if SelfTest.isRequested { return .selfTest }
        if MainActor.assumeIsolated({ Updater.shared.relaunching }) { return .updateRelaunch }
        return QuitReopenPrompt.reason(of: NSAppleEventManager.shared().currentAppleEvent)
    }

    /// The windows' projects, each once, in window order: what the reopen question names.
    private var openProjects: [String] {
        var seen = Set<String>()
        return controllers.compactMap(\.project).filter { seen.insert($0).inserted }
    }

    /// "Save changes to … before quitting?", for the unsaved files' names: Save (Save All), Cancel, Don’t Save (⌘D).
    static func saveBeforeQuittingAlert(_ names: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = names.count == 1 ? "Save changes to “\(names[0])” before quitting?"
            : "Save changes to \(names.count) files before quitting?"
        alert.informativeText = "Your changes are lost if you don’t save them."
        alert.addButton(withTitle: names.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save").keyEquivalent = "d"
        return alert
    }

    /// "Quit Next Term?", with what quitting stops: Quit, Cancel.
    static func quitStopsAlert(_ busy: [TerminalTab]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Next Term?"
        alert.informativeText = "Quitting stops " + TerminalWindowController.stopList(busy)
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    func applicationWillTerminate(_ notification: Notification) {
        MCPControlServer.shared.stop()
        ClaudeIDEServer.shared.stop() // removes the lock file
        GeminiIDEServer.shared.stop()
        CopilotIDEServer.shared.stop()
        MainActor.assumeIsolated { Updater.shared.installStagedUpdateOnQuit() }
        if !SelfTest.isRequested { sessionProjects = controllers.compactMap(\.project) }
        RemoteConnection.saveTabs(controllers)
        for controller in controllers { for tab in controller.tabs { tab.terminate() } }
        RemoteConnection.shutdown() // the master connections; sessions kept by tmux or herdr stay on their hosts
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
        controller.onClose = { [weak self] closed, welcome in
            // Defer: the window is still mid-close in this call.
            DispatchQueue.main.async {
                guard let self else { return }
                self.controllers.removeAll { $0 === closed }
                self.updateBadge()
                self.projectsChanged()
                // Closing the last project (or the last window's last tab) leaves the Welcome window, with
                // recent projects, like an IDE.
                if welcome && self.controllers.isEmpty && !self.isTerminating { self.showWelcome(nil) }
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
        if remoteRestorePending { restoreRemoteTabs() } // the launch's first terminal window
        projectsChanged()
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
        set {
            UserDefaults.standard.set(newValue.paths, forKey: "recentProjects")
            // A folder dropped as missing, Clear Menu, or an import under the Welcome window: it lists them as they are now.
            if welcome?.window?.isVisible == true { welcome?.reloadProjects() }
        }
    }

    var recentProjects: [String] { recent.existing() }

    /// Projects brought over by an import: after Next Term's own, never pushing them out.
    func importRecentProjects(_ paths: [String]) -> [String] {
        var list = recent
        let added = list.appendImported(paths)
        recent = list
        return added
    }

    /// Undo of an import: the list exactly as it was.
    func setRecentProjects(_ paths: [String]) {
        recent = RecentProjects(paths)
    }

    /// Where Open Project goes when the current window is in use: ask, this window, or a new one.
    enum ProjectTarget: String { case ask, thisWindow, newWindow }

    var projectTarget: ProjectTarget {
        get { ProjectTarget(rawValue: UserDefaults.standard.string(forKey: "openProjectsIn") ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "openProjectsIn") }
    }

    private var welcome: WelcomeWindowController?
    /// For the self-test.
    var welcomeController: WelcomeWindowController? { welcome }

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
        // Read as the launch finishes: it named something, even when every item below is skipped. It then goes on
        // as a normal launch, without the first run's import offer.
        openedAtLaunch = true
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

    /// ⌘T with no window open (every window closed, app still running), where Settings › Terminal › New tabs says.
    @objc func newTab(_ sender: Any?) {
        openWindow(directory: newTabWindowDirectory)
    }

    /// The terminal window used last, for a tab command given while another window is in front (Welcome,
    /// Settings).
    private var lastUsedController: TerminalWindowController? { controllers.max { $0.lastKey < $1.lastKey } }

    /// ⌥⌘T with no terminal window in front, and the Welcome window's Connect to Server…. From the Welcome
    /// window (in front, or the only one open) the sheet comes over it: Connect opens a window for the tab,
    /// Cancel leaves things as they were. Otherwise it comes over the terminal window used last (Settings in
    /// front), or with no window at all, over a new one.
    @objc func newRemoteTab(_ sender: Any?) {
        if let window = welcome?.window, window.isVisible, window.isKeyWindow || controllers.isEmpty {
            return RemoteTabSheet.show(over: window) { [weak self] remote in self?.openWindow(remote: remote) }
        }
        if let last = lastUsedController {
            last.window?.makeKeyAndOrderFront(nil)
            return last.newRemoteTab(sender)
        }
        openWindow(directory: nil).newRemoteTab(sender)
    }

    /// A window for a tab on a server: the shell a new window starts with makes way for it.
    @discardableResult
    func openWindow(remote: RemoteTab) -> TerminalWindowController {
        let controller = openWindow(directory: nil)
        closeFirstShell(of: controller, keeping: controller.addRemoteTab(remote))
        return controller
    }

    /// The shell a new window starts with, closed for the tab the window was opened for. Only while the
    /// window holds just the two and nothing has run in that shell: no other tab, and nothing that runs,
    /// is ever closed this way.
    func closeFirstShell(of controller: TerminalWindowController, keeping tab: TerminalTab) {
        guard controller.tabs.count == 2, let first = controller.tabs.first, first !== tab, first.remote == nil else { return }
        guard first.userTitle == nil, first.status.commandsStarted == 0, !first.leftStartFolder, !first.status.running else { return }
        controller.remove(first)
    }

    /// A saved host on the Welcome window: a window with a tab on it, in its folder.
    func connect(to host: RemoteHost) {
        UserDefaults.standard.set(host.id, forKey: "lastRemoteHost") // the sheet offers it first next time
        openWindow(remote: RemoteTab(host: host))
    }

    /// ⇧⌘T with no terminal window in front: in the terminal window used last, else in a new window that
    /// holds the tab alone.
    @objc func reopenClosedTab(_ sender: Any?) {
        if let last = lastUsedController {
            last.window?.makeKeyAndOrderFront(nil)
            return last.reopenClosedTab(sender)
        }
        guard let entry = ClosedTabs.takeLast() else { return NSSound.beep() }
        let controller = openWindow(directory: nil)
        if let tab = controller.reopen(entry) { closeFirstShell(of: controller, keeping: tab) }
    }

    // MARK: Option as Meta

    @objc func toggleOptionAsMeta(_ sender: Any?) {
        Preferences.optionAsMeta.toggle()
        for controller in controllers { for tab in controller.tabs { tab.view.optionAsMetaKey = Preferences.optionAsMeta } }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(reopenClosedTab(_:)) { return !ClosedTabs.isEmpty }
        if item.action == #selector(toggleOptionAsMeta(_:)) { item.state = Preferences.optionAsMeta ? .on : .off }
        if item.action == #selector(setTerminalPosition(_:)) {
            item.state = item.representedObject as? String == terminalPosition.rawValue ? .on : .off
        }
        if item.action == #selector(toggleSidebarSide(_:)) { item.state = sidebarSide == .right ? .on : .off }
        if item.action == #selector(toggleSidebarSingleClick(_:)) { item.state = sidebarSingleClickOpens ? .on : .off }
        if item.action == #selector(toggleSoftWrap(_:)) { item.state = softWrap ? .on : .off }
        if item.action == #selector(toggleBlameAnnotations(_:)) { item.state = blameAnnotations ? .on : .off }
        if item.action == #selector(toggleCurrentLineBlame(_:)) { item.state = currentLineBlame ? .on : .off }
        if item.action == #selector(setLineHeight(_:)), let value = item.representedObject as? Double {
            item.state = abs(CGFloat(value) - editorLineHeight) < 0.001 ? .on : .off
        }
        if item.action == #selector(toggleAutomaticUpdates(_:)) {
            item.state = MainActor.assumeIsolated { Updater.shared.automaticChecks } ? .on : .off
        }
        return true
    }

    // MARK: font size

    @objc func increaseFontSize(_ sender: Any?) { setFontSize(fontSize + 1) }
    @objc func decreaseFontSize(_ sender: Any?) { setFontSize(fontSize - 1) }
    @objc func resetFontSize(_ sender: Any?) { setFontSize(Theme.defaultFontSize) }

    func setFontSize(_ size: CGFloat) {
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

    /// Posts a system notification for a tab you are not looking at, as Settings › Notifications says. The
    /// settings are read each time, so a change applies at once. `appActive` stands in for whether Next Term
    /// is in front, for the self-test.
    func post(_ notice: TabNotice, tab: TerminalTab, in controller: TerminalWindowController, appActive: Bool? = nil) {
        let settings = NotificationSettings(defaults: .standard)
        let active = appActive ?? NSApp.isActive
        let visible = controller.isOnScreen(tab)
        guard settings.shouldNotify(notice, appActive: active, tabVisible: visible, drivenByAgent: MCPControl.isDriven(tab)) else { return }
        let program = Typography.shortened(notice.program, to: 60)
        let title = Typography.shortened(tab.title, to: 80)
        // Which project the tab is in (or its folder), unless its title says it already.
        let place = Typography.shortened(controller.placeName(of: tab), to: 60)
        let shownPlace = place == title ? nil : place
        let content = UNMutableNotificationContent()
        if let question = notice.question {
            // An agent is blocked on a decision. Clicking the notification opens the tab.
            content.title = "\(program.isEmpty ? "The agent" : program) needs your decision"
            content.subtitle = [title, shownPlace].compactMap { $0 }.joined(separator: " — ")
            content.body = question
        } else {
            content.title = title
            content.subtitle = shownPlace ?? ""
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
        let audible = settings.sound && Date().timeIntervalSince(lastSoundAt) >= 3
        content.sound = audible ? .default : nil
        if audible { lastSoundAt = Date() }
        // A window's notifications stack together in Notification Center.
        content.threadIdentifier = controller.placeName(of: tab)
        content.userInfo = ["tab": tab.id.uuidString]
        deliver(UNNotificationRequest(identifier: tab.id.uuidString, content: content, trigger: nil))
    }

    /// While the self-test runs, notifications land here instead of in Notification Center: it checks what
    /// would be shown, and shows you nothing.
    var testNotifications: [UNNotificationRequest] = []

    private func deliver(_ request: UNNotificationRequest) {
        if SelfTest.isRequested { return testNotifications.append(request) }
        notificationCenter?.add(request)
    }

    /// Settings › Notifications › Send Test Notification: one like a tab's, with the sound as set. Asks macOS
    /// first if it has not asked yet (once answered, asking again changes nothing). `done` says whether macOS
    /// took it: false when Next Term's notifications are off.
    func sendTestNotification(then done: @escaping (Bool) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = "Next Term"
        content.body = "This is how Next Term tells you a tab needs you. Clicking a tab’s notification takes you to it."
        content.sound = NotificationSettings(defaults: .standard).sound ? .default : nil
        let request = UNNotificationRequest(identifier: "test", content: content, trigger: nil)
        if SelfTest.isRequested {
            deliver(request)
            return done(true)
        }
        guard let center = notificationCenter else { return done(false) }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return DispatchQueue.main.async { done(false) } }
            center.add(request) { error in
                DispatchQueue.main.async { done(error == nil) }
            }
        }
    }

    /// What macOS lets Next Term do (System Settings › Notifications), for Settings › Notifications.
    enum NotificationPermission {
        case allowed, off, notAsked
        /// Allowed, with the alert style None: they go to Notification Center without a banner.
        case quiet
        /// `swift run`: no app bundle, so no notifications.
        case unavailable

        init(_ status: UNAuthorizationStatus, alertStyle: UNAlertStyle) {
            switch status {
            case .denied: self = .off
            case .notDetermined: self = .notAsked
            case .authorized, .provisional: self = alertStyle == .none ? .quiet : .allowed
            default: self = .allowed
            }
        }
    }

    func notificationPermission(_ done: @escaping (NotificationPermission) -> Void) {
        guard let center = notificationCenter else { return done(.unavailable) }
        center.getNotificationSettings { settings in
            let permission = NotificationPermission(settings.authorizationStatus, alertStyle: settings.alertStyle)
            DispatchQueue.main.async { done(permission) }
        }
    }

    /// Show banners even while Next Term is in front (decisions and finished agents in tabs you are not looking at).
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
                if let tab = controller.tabs.first(where: { $0.id.uuidString == tabID }) {
                    controller.window?.makeKeyAndOrderFront(nil)
                    controller.show(tab)
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
        item(app, "Settings…", #selector(showSettings(_:)), ",", target: self)
        item(app, "Check for Updates…", #selector(checkForUpdates(_:)), "", target: self)
        item(app, "Check for Updates Automatically", #selector(toggleAutomaticUpdates(_:)), "", target: self)
        item(app, "Install Command Line Tool (nxtrm)…", #selector(installCommandLineTool(_:)), "", target: self)
        item(app, "Import Settings and Shortcuts…", #selector(showImport(_:)), "", target: self)
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

        let shell = submenu(main, "File") // tabs, projects and windows, where Mac apps keep them
        item(shell, "New Tab", #selector(TerminalWindowController.newTab(_:)), "t")
        item(shell, "New Window", #selector(newWindow(_:)), "n", target: self)
        item(shell, "New Remote Tab…", #selector(TerminalWindowController.newRemoteTab(_:)), "t", [.command, .option])
        item(shell, "Duplicate Tab", #selector(TerminalWindowController.duplicateTab(_:)), "")
        item(shell, "Reopen Closed Tab", #selector(TerminalWindowController.reopenClosedTab(_:)), "t", [.command, .shift])
        shell.addItem(.separator())
        item(shell, "Open Project…", #selector(openProjectPanel(_:)), "o", target: self)
        item(shell, "Go to File…", #selector(TerminalWindowController.goToFile(_:)), "p")
        // ⌘P keeps opening Go to File when a shortcut set moves it (JetBrains: ⇧⌘O), unless a command takes ⌘P.
        let goToFileAlias = item(shell, "Go to File…", #selector(TerminalWindowController.goToFile(_:)), "")
        goToFileAlias.isHidden = true
        goToFileAlias.allowsKeyEquivalentWhenHidden = true
        goToFileAlias.identifier = KeyboardShortcuts.goToFileAlias
        item(shell, "Open Served URL", #selector(TerminalWindowController.openServedURL(_:)), "")
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
        // The file in front in the editor, as its tab's right-click menu has them.
        item(shell, "Reveal in Finder", #selector(TerminalWindowController.revealInFinder(_:)), "")
        item(shell, "Copy Path", #selector(TerminalWindowController.copyFilePath(_:)), "")
        item(shell, "Copy Relative Path", #selector(TerminalWindowController.copyRelativeFilePath(_:)), "")
        shell.addItem(.separator())
        item(shell, "Split Right", #selector(TerminalWindowController.splitRight(_:)), "d")
        item(shell, "Split Down", #selector(TerminalWindowController.splitDown(_:)), "d", [.command, .shift])
        shell.addItem(.separator())
        item(shell, "Rename Tab…", #selector(TerminalWindowController.renameTab(_:)), "r", [.command, .option])
        item(shell, "Use Option as Meta Key", #selector(toggleOptionAsMeta(_:)), "", target: self)
        shell.addItem(.separator())
        item(shell, "Close Tab", #selector(TerminalWindowController.closeTab(_:)), "w")
        item(shell, "Close Other Tabs", #selector(TerminalWindowController.closeOtherTabs(_:)), "")
        item(shell, "Close Tabs to the Right", #selector(TerminalWindowController.closeTabsToTheRight(_:)), "")
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
        item(find, "Replace…", #selector(CodeTextView.replaceInFile(_:)), "f", [.command, .option])
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
        // The editor's own: their keys work while it has the keyboard, so ⌘D splits the terminal everywhere else.
        let line = NSMenu(title: "Line")
        edit.addItem(withTitle: "Line", action: nil, keyEquivalent: "").submenu = line
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        item(line, "Duplicate Line", #selector(CodeTextView.duplicateLine(_:)), "d")
        item(line, "Delete Line", #selector(CodeTextView.deleteLine(_:)), "k", [.command, .shift])
        item(line, "Move Line Up", #selector(CodeTextView.moveLineUp(_:)), up, [.command, .control])
        item(line, "Move Line Down", #selector(CodeTextView.moveLineDown(_:)), down, [.command, .control])
        line.addItem(.separator())
        item(line, "Copy Path with Line", #selector(CodeTextView.copyPathWithLine(_:)), "")
        edit.addItem(.separator())
        item(edit, "Clear Buffer", #selector(TerminalWindowController.clearBuffer(_:)), "k")

        let view = submenu(main, "View")
        item(view, "Hide Project Sidebar", #selector(TerminalWindowController.toggleProjectSidebar(_:)), "b") // title follows the state
        item(view, "Focus Editor", #selector(TerminalWindowController.toggleEditorFocus(_:)), "`", [.control]) // title follows the focus
        item(view, "Collapse Terminal", #selector(TerminalWindowController.toggleTerminalCollapsed(_:)), "j") // title follows the state
        item(view, "Show File in Project Sidebar", #selector(TerminalWindowController.revealInSidebar(_:)), "")
        view.addItem(.separator())
        let positions = NSMenu(title: "Terminal Position")
        for position in TerminalPosition.allCases {
            let entry = item(positions, position.title, #selector(setTerminalPosition(_:)), "", target: self)
            entry.representedObject = position.rawValue
        }
        view.addItem(withTitle: "Terminal Position", action: nil, keyEquivalent: "").submenu = positions
        item(view, "Show Changes", #selector(TerminalWindowController.showChanges(_:)), "g", [.command, .option])
        item(view, "Unified Diffs", #selector(DiffLayoutMenu.toggleUnifiedDiffs(_:)), "", target: DiffLayoutMenu.shared) // checked: one column
        item(view, "Annotate with Git Blame", #selector(toggleBlameAnnotations(_:)), "", target: self)
        item(view, "Current Line Blame", #selector(toggleCurrentLineBlame(_:)), "", target: self)
        view.addItem(.separator())
        item(view, "Soft Wrap", #selector(toggleSoftWrap(_:)), "", target: self)
        item(view, "Hide .env Values", #selector(TerminalWindowController.toggleEnvValues(_:)), "") // checked: the file in front
        let heights = NSMenu(title: "Line Height")
        for value in Self.lineHeights {
            let title = ["1.0", "1.15", "1.25", "1.35 (default)", "1.5", "1.75", "2.0"][Self.lineHeights.firstIndex(of: value) ?? 0]
            let entry = item(heights, title, #selector(setLineHeight(_:)), "", target: self)
            entry.representedObject = Double(value)
        }
        view.addItem(withTitle: "Line Height", action: nil, keyEquivalent: "").submenu = heights
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

        // The agents' own: their skills, their sessions, and what goes to them. Ids are the actions, so keys changed in
        // Settings before these moved here from File and Edit stay theirs. Window › Skills finds new skills.
        let agents = submenu(main, "Agents")
        let skills = item(agents, SkillsMenuItem.title, #selector(showSkillsSettings(_:)), "", target: self)
        MainActor.assumeIsolated { SkillsMenuItem.follow(skills) } // with the count of skill updates
        agents.addItem(.separator())
        item(agents, "Resume Agent Session…", #selector(TerminalWindowController.resumeSession(_:)), "o", [.command, .option])
        item(agents, "Send to Agent", #selector(TerminalWindowController.sendToAgent(_:)), "k", [.command, .option])
        item(agents, "Suggest a Command…", #selector(CommandSuggestionController.suggestCommand(_:)), "k", [.command, .control],
             target: CommandSuggestionController.shared)

        let git = submenu(main, "Git")
        item(git, "Branches…", #selector(TerminalWindowController.showBranches(_:)), "b", [.command, .option])
        git.addItem(.separator())
        item(git, "Fetch", #selector(TerminalWindowController.gitFetch(_:)), "")
        item(git, "Update Project", #selector(TerminalWindowController.gitUpdate(_:)), "")
        item(git, "Commit…", #selector(TerminalWindowController.gitCommit(_:)), "")
        item(git, "Push…", #selector(TerminalWindowController.gitPush(_:)), "")
        item(git, "New Branch…", #selector(TerminalWindowController.gitNewBranch(_:)), "")
        git.addItem(.separator())
        item(git, "Git Log", #selector(TerminalWindowController.showGitLog(_:)), "l", [.command, .option])
        item(git, "Git Diff", #selector(TerminalWindowController.showGitDiff(_:)), "g", [.command, .control])
        item(git, "Git Commands", #selector(TerminalWindowController.showGitCommands(_:)), "")

        let window = submenu(main, "Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        item(window, "Show Next Tab", #selector(TerminalWindowController.showNextTab(_:)), "]", [.command, .shift])
        item(window, "Show Previous Tab", #selector(TerminalWindowController.showPreviousTab(_:)), "[", [.command, .shift])
        window.addItem(.separator())
        let arrow = { (key: Int) in String(Character(UnicodeScalar(key)!)) }
        item(window, "Select Pane on the Left", #selector(TerminalWindowController.selectPaneLeft(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option])
        item(window, "Select Pane on the Right", #selector(TerminalWindowController.selectPaneRight(_:)), arrow(NSRightArrowFunctionKey), [.command, .option])
        item(window, "Select Pane Above", #selector(TerminalWindowController.selectPaneAbove(_:)), arrow(NSUpArrowFunctionKey), [.command, .option])
        item(window, "Select Pane Below", #selector(TerminalWindowController.selectPaneBelow(_:)), arrow(NSDownArrowFunctionKey), [.command, .option])
        item(window, "Select Next Pane", #selector(TerminalWindowController.selectNextPane(_:)), "]", [.command, .option])
        item(window, "Select Previous Pane", #selector(TerminalWindowController.selectPreviousPane(_:)), "[", [.command, .option])
        item(window, "Maximize Pane", #selector(TerminalWindowController.toggleZoomPane(_:)), "\r", [.command, .shift])
        item(window, "Make Panes Equal", #selector(TerminalWindowController.equalizePanes(_:)), "")
        window.addItem(.separator())
        for n in 1...9 {
            let tabItem = item(window, n == 9 ? "Select Last Tab" : "Select Tab \(n)",
                               #selector(TerminalWindowController.selectTabByNumber(_:)), "\(n)")
            tabItem.tag = n
        }
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        item(window, "Welcome to Next Term", #selector(showWelcome(_:)), "", target: self)
        item(window, "Skills", #selector(showSkills(_:)), "", target: self)
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

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

    /// The editor's font size, which terminals use too while they have no size of their own.
    var fontSize: CGFloat {
        get {
            let saved = UserDefaults.standard.double(forKey: "fontSize")
            return saved > 0 ? CGFloat(saved) : Theme.defaultFontSize
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "fontSize") }
    }

    /// The terminal's own font size (Settings › Terminal), or nil while terminals use the editor's: saved only
    /// once it is set, so nothing changes for anyone until then.
    var terminalOwnFontSize: CGFloat? {
        get {
            let saved = UserDefaults.standard.double(forKey: "terminalFontSize")
            return saved > 0 ? CGFloat(saved) : nil
        }
        set {
            if let newValue { UserDefaults.standard.set(Double(newValue), forKey: "terminalFontSize") }
            else { UserDefaults.standard.removeObject(forKey: "terminalFontSize") }
        }
    }

    /// The size terminals use: their own, else the editor's.
    var terminalFontSize: CGFloat { terminalOwnFontSize ?? fontSize }

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
    typealias TerminalPosition = NextTermCore.TerminalPosition

    enum SidebarSide: String { case left, right }

    var terminalPosition: TerminalPosition {
        get { TerminalPosition(stored: UserDefaults.standard.string(forKey: "terminalPosition")) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "terminalPosition") }
    }

    var sidebarSide: SidebarSide {
        get { SidebarSide(rawValue: UserDefaults.standard.string(forKey: "sidebarSide") ?? "") ?? .left }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "sidebarSide") }
    }

    /// Where the terminal's tabs show: along its bar at the top, or in a list down its left or right.
    var terminalTabs: TerminalTabsSetting {
        get { TerminalTabsSetting(stored: UserDefaults.standard.string(forKey: TerminalTabsSetting.key)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: TerminalTabsSetting.key) }
    }

    /// Show Folders: every row of the tab list gets a second line, the tab's folder or the question its agent asks.
    var tabListShowsFolders: Bool {
        get { UserDefaults.standard.bool(forKey: "tabListShowsFolders") }
        set { UserDefaults.standard.set(newValue, forKey: "tabListShowsFolders") }
    }

    @objc func setTerminalPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let position = TerminalPosition(rawValue: raw) else { return }
        moveTerminal(to: position, announce: true)
    }

    /// Settings › Terminal › Position follows the menus.
    static let terminalPositionChanged = Notification.Name("NextTermTerminalPositionChanged")

    /// Moves the terminal in every window. The position it has already changes nothing: no window is laid out
    /// again, so a folded terminal stays folded and no divider moves. `announce`: the user chose it (a menu,
    /// Settings); with no file open in the window in front its terminal fills it, so a notice says where the
    /// terminal goes once a file opens, rather than the choice seeming ignored.
    func moveTerminal(to position: TerminalPosition, announce: Bool = false) {
        guard position != terminalPosition else { return }
        terminalPosition = position
        controllers.forEach { $0.applyLayout() }
        NotificationCenter.default.post(name: Self.terminalPositionChanged, object: nil)
        guard announce, let front = TerminalWindow.front, let controller = front.windowController as? TerminalWindowController,
              controller.editorArea.isHidden else { return }
        GitToast.show(position.noticeWithNoFileOpen, in: front)
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

    /// Settings › Editor › "Agents offer to run parallel work in tabs" (MCP: agents_offer_tabs): Next Term's next-term-tabs
    /// skill (BuiltInSkill) in its skill library over MCP (list_skills, get_skill), and its line first in the MCP
    /// instructions an agent in a tab gets (MCPBridge). On by default; nothing is written in the agents' folders, so off
    /// takes both out at once.
    static let offerTabsKey = "agentsOfferTabs"
    static let offerTabsChanged = Notification.Name("NextTermAgentsOfferTabsChanged")
    var agentsOfferTabs: Bool {
        get { UserDefaults.standard.object(forKey: Self.offerTabsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.offerTabsKey)
            NotificationCenter.default.post(name: Self.offerTabsChanged, object: nil)
        }
    }

    /// Next Term's own skills in its library: none while agents may not control Next Term, next-term-tabs only while
    /// agents offer tabs.
    var builtInSkills: [BuiltInSkill] { agentControl ? BuiltInSkill.offered(tabs: agentsOfferTabs) : [] }

    /// Settings › Editor › "When an agent opens a tab" (MCP: agents_bring_tabs_forward): its window comes forward and
    /// takes focus, comes forward only, or stays where it is (AgentArrival). The tab never takes the keyboard by itself.
    static let agentArrivalKey = "agentsBringTabsForward"
    static let agentArrivalChanged = Notification.Name("NextTermAgentArrivalChanged")
    var agentArrival: AgentArrival.Mode {
        get { UserDefaults.standard.string(forKey: Self.agentArrivalKey).flatMap(AgentArrival.Mode.init(rawValue:)) ?? .focus }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.agentArrivalKey)
            NotificationCenter.default.post(name: Self.agentArrivalChanged, object: nil)
        }
    }

    func startAgentControl() {
        SecretsStore.marksLoadedBeforeSocket = SecretsStore.marksLoaded
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

    /// Every folder a tab works in (projects, the sidebar's roots, each tab's own project): Gemini CLI and
    /// Qwen Code connect only from inside one of these. Never a folder that is never a project (the home folder, /:
    /// ProjectRoot.isNeverRoot), from which they would connect wherever they start.
    var agentWorkspaces: [String] {
        var roots: [String] = []
        for controller in controllers {
            if let project = controller.project { roots.append(project) }
            if let root = controller.sidebar.root?.path { roots.append(root) }
            roots += controller.tabs.compactMap { (tab: TerminalTab) -> String? in ProjectRoot.project(from: tab.directory) }
        }
        var seen = Set<String>()
        return roots.map(canonicalPath).filter { !ProjectRoot.isNeverRoot($0) && seen.insert($0).inserted }
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

    /// The open projects, so a `claude` started in another terminal inside one finds Next Term too, and a kept remote
    /// tab waiting for its project's window reattaches once it opens.
    func projectsChanged() {
        ClaudeIDEServer.shared.updateWorkspaces(controllers.compactMap(\.project))
        GeminiIDEServer.shared.updateWorkspaces(agentWorkspaces)
        updateCopilotFolders()
        RemoteConnection.projectsChanged()
        MainActor.assumeIsolated { ProjectHistoryRecorder.shared.update(controllers) }
    }

    /// Brand icons on configuration folders (.github, .claude, .idea); off: they stay plain and quiet.
    var iconsOnDotFolders: Bool {
        get { UserDefaults.standard.bool(forKey: "iconsOnDotFolders") }
        set {
            UserDefaults.standard.set(newValue, forKey: "iconsOnDotFolders")
            controllers.forEach { $0.sidebar.outline.reloadData() }
        }
    }

    /// One click in the project sidebar opens a file, in a preview tab, and opens or closes a folder (off: a click
    /// selects, and a double-click does those). Read at each click, so it applies to every window at once. Turning it
    /// off keeps every preview as an ordinary tab. A new install has it on, stored at its first launch
    /// (`SidebarClick.settleDefault`); an install used before that never chose keeps it off, and a key never written
    /// reads off.
    var sidebarSingleClickOpens: Bool {
        get { UserDefaults.standard.bool(forKey: SidebarClick.settingKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: SidebarClick.settingKey)
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

    /// View › Suggestions While Typing: on or off for every tab, as Settings › Terminal › While typing sets it (stored).
    @objc func toggleSuggestionsWhileTyping(_ sender: Any?) {
        GhostPreferences.set(!GhostPreferences.isOn)
    }

    /// View › Private Mode (suggestions while typing): none show and nothing is recorded, for every tab, until it is
    /// turned off or Next Term quits.
    @objc func togglePrivateMode(_ sender: Any?) {
        GhostPreferences.setPrivateMode(!GhostPreferences.privateMode)
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

    /// Markdown files open in Live Preview (on unless turned off in Settings › Editor). A file's own choice from View ›
    /// Markdown Live Preview wins (markdownViewChoices); changing this, every open file without one follows.
    var markdownLivePreview: Bool {
        get { UserDefaults.standard.object(forKey: "markdownLivePreview") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "markdownLivePreview")
            controllers.forEach { $0.editorArea.applyMarkdownPreviewSetting() }
        }
    }

    /// Each Markdown file's own choice of Live Preview or Source, the newest 500.
    var markdownViewChoices: MarkdownViewChoices {
        get { MarkdownViewChoices.decode(UserDefaults.standard.data(forKey: MarkdownViewChoices.defaultsKey)) }
        set { UserDefaults.standard.set(newValue.encoded(), forKey: MarkdownViewChoices.defaultsKey) }
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

    /// Current Line Blame on or off, as the menu sets it, without a word about a file that has none (an import).
    func setCurrentLineBlame(_ on: Bool) {
        currentLineBlame = on
        applyBlame(announce: false)
    }

    /// Turning blame on says so when the file in front has none (outside git, too large).
    private func applyBlame(announce: Bool) {
        controllers.forEach { $0.editorArea.applyBlame(announce: announce && $0.window?.isKeyWindow == true) }
    }

    @objc func toggleSidebarSide(_ sender: Any?) {
        sidebarSide = sidebarSide == .left ? .right : .left
        controllers.forEach { $0.applyLayout() }
    }

    @objc func setTerminalTabs(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tabs = TerminalTabsSetting(rawValue: raw) else { return }
        moveTerminalTabs(to: tabs)
    }

    /// Settings › Terminal › Tabs follows the menus.
    static let terminalTabsChanged = Notification.Name("NextTermTerminalTabsChanged")

    /// Puts the terminal's tabs on top, or in a list down its left or right, in every window. Only the tabs move: the
    /// sidebar, the editor, the terminal's position and every split stay where they are, and a folded terminal stays
    /// folded. The place they have already changes nothing.
    func moveTerminalTabs(to tabs: TerminalTabsSetting) {
        guard tabs != terminalTabs else { return }
        terminalTabs = tabs
        controllers.forEach { $0.applyTerminalTabs() }
        NotificationCenter.default.post(name: Self.terminalTabsChanged, object: nil)
    }

    /// View › Terminal Tabs › Show Folders, in every window.
    @objc func toggleTabListFolders(_ sender: Any?) {
        tabListShowsFolders.toggle()
        controllers.forEach { $0.refresh() }
    }

    /// How much of the work area open files get; the terminal has the rest. Kept apart for the terminal beside
    /// the editor and above or below it, as a width dragged for one is no height for the other.
    func editorFraction(sideBySide: Bool) -> CGFloat {
        let defaults = UserDefaults.standard
        let own = defaults.object(forKey: EditorShare.key(sideBySide: sideBySide)) as? Double
        return EditorShare.share(own: own, shared: defaults.object(forKey: EditorShare.sharedKey) as? Double)
    }

    func setEditorFraction(_ share: CGFloat, sideBySide: Bool) {
        UserDefaults.standard.set(Double(EditorShare.kept(share)), forKey: EditorShare.key(sideBySide: sideBySide))
    }

    /// Notifications need a real bundle (`swift run` has none).
    private var notificationCenter: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    // MARK: lifecycle

    /// Where a launch reads Settings › General, and where the projects open at quit are kept: the user's defaults, or the
    /// relaunch harness's own suite (`SelfTest.keptDefaults`).
    let launchDefaults = SelfTest.keptDefaults ?? .standard
    /// Kept remote tabs (tmux, herdr) wait for the first terminal window: they never open one of their own while the
    /// Welcome window is up.
    private(set) var remoteRestorePending = false
    /// A folder or file came through `application(_:open:)`. Read once, as the launch finishes: the launch named one.
    private var openedAtLaunch = false
    /// What `application(_:open:)` names, by when it comes (R32): held until the launch hook has built the restored
    /// windows, then opened in front of them as `nxtrm` opens it until the launch has shown what it shows.
    private var requests = ProjectOpening.LaunchRequests()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single clicks in the sidebar: on for a new install, kept as it was for one used before. First, before this
        // launch writes any of the keys that tell the two apart (SidebarClick.usedInstallKeys). Not in the self-test,
        // whose defaults look new at every run: its clicks part sets the setting itself.
        if !SelfTest.isRequested { SidebarClick.settleDefault(in: .standard) }
        // Secrets' marks first, with no crypto, so the first MCP answer and IDE message are already masked; then the
        // load check, off the main thread.
        MainActor.assumeIsolated { SecretsStore.shared.loadMarks() }
        MainActor.assumeIsolated { SecretReminders.start() } // key rotation reminders: first checked once the load is done
        Task { @MainActor in await SecretsStore.shared.load() }
        // Every key in Next Term, in any of its windows: the typing an agent's window waits out (AgentArrival).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            UserKeys.pressed()
            return event
        }
        RemotePoller.shared.start() // status of remote tabs, from their hosts
        followAgentSpinner()
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
        #if DEBUG
        // The relaunch harness's shells read its own zsh config, from the first tab the restore opens.
        if SelfTest.mode == .relaunchHarness { SelfTestRestore.prepareShells() }
        #endif
        // The launch hook (KTD14): the sessions folder taken, unless another Next Term holds it, and what the last update,
        // quit or crash left brought back, as Settings › General and the restore step say. Its windows are built by the
        // time it returns, before the self-test branch and `--open-request`, so a request launch keeps the quit's session
        // too and opens in front of it (R32). From here on the session is saved, and at the quit.
        let restore = MainActor.assumeIsolated { SessionRestore.shared.launch(settings: LaunchSettings(defaults: launchDefaults)) }
        let named = requests.restored()
        NSApp.activate(ignoringOtherApps: true)
        // `nxtrm` in a terminal, while Next Term runs.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(commandLineRequest(_:)),
                                                            name: .init(CommandLineOpen.notificationName), object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        #if DEBUG
        // A step of the relaunch harness: a launch as the app's own, in the harness's folder and defaults, with no update
        // check, no `nxtrm` link and no clean-up in Application Support. SelfTestRestore drives the rest.
        if SelfTest.mode == .relaunchHarness {
            // A step launched as `nxtrm` launches the app opens what it names, as the app's own launch does.
            let command = Self.openRequest(in: CommandLine.arguments)
            if let command { handle(command) }
            open(named, asRequest: true)
            let kind: LaunchKind = command != nil || openedAtLaunch ? .request : .normal
            openAtLaunch(kind: kind, restore: restore, settings: LaunchSettings(defaults: launchDefaults), mayOfferImport: false)
            requests.shown()
            restoreRemoteTabsOnceAWindowOpens()
            GhostPreferences.testIsOn = false // its tabs record nothing, and → moves the cursor
            return SelfTestRestore.run(restore: restore)
        }
        #endif
        if SelfTest.isRequested {
            // A normal launch, with the Welcome window whatever is saved and no import offer. The self-test's first
            // check opens the window the others use.
            var welcomeFirst = LaunchSettings()
            welcomeFirst.opens = .welcome
            openAtLaunch(kind: .normal, restore: .notRun, settings: welcomeFirst, mayOfferImport: false)
            requests.shown()
            restoreRemoteTabsOnceAWindowOpens()
            SelfTest.run()
            return
        }
        // `nxtrm` started us: what it asked for opens, in front of what the restore brought back, and the launch shows
        // nothing more. So does a folder dropped on the app, `open -a "Next Term" dir` and Finder's Open With: those that
        // arrived before the hook open now, and those that arrive before the launch has shown what it shows open as they
        // come, each as `nxtrm` opens it (`application(_:open:)`).
        let command = Self.openRequest(in: CommandLine.arguments)
        let kind: LaunchKind = command != nil || openedAtLaunch ? .request : .normal
        // `nxtrm` in other terminals: linked where that needs no password, else offered once with one.
        CommandLineTool.registerQuietly()
        MainActor.assumeIsolated { Updater.shared.start() }
        // An update's disk image and folder that a quit or a crash left mid-staging.
        Updater.removeLeftovers()
        // Skill updates, once a day, for Agents › Skills…' count.
        MainActor.assumeIsolated { SkillsUpdateCheck.start() }
        if let command { handle(command) }
        open(named, asRequest: true)
        let show = { [self] in
            openAtLaunch(kind: kind, restore: restore)
            requests.shown()
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

    /// What a launch shows, and a Dock click with no window (LaunchDecision): the projects to reopen, the Welcome
    /// window, or on the first run "Coming from another app?" and then the Welcome window. Nothing more once a
    /// terminal window is open: one the launch hook restored, or one a request opened. Settings › General is read each
    /// time, so a change applies from the next one.
    private func openAtLaunch(kind: LaunchKind, restore: LaunchRestoreResult = .notRun) {
        let settings = LaunchSettings(defaults: launchDefaults)
        let offered = UserDefaults.standard.bool(forKey: "importOffered")
        openAtLaunch(kind: kind, restore: restore, settings: settings, mayOfferImport: !offered && recentProjects.isEmpty)
    }

    private func openAtLaunch(kind: LaunchKind, restore: LaunchRestoreResult, settings: LaunchSettings, mayOfferImport: Bool) {
        let input = LaunchInput(kind: kind, restore: restore, terminalWindowOpen: !controllers.isEmpty, settings: settings,
                                sessionProjects: sessionProjects, recentProjects: recent.paths, mayOfferImport: mayOfferImport)
        switch LaunchDecision.opening(input, exists: isFolder) {
        case .nothing: break
        case .reopen(let paths): for path in paths { openWindow(directory: path, project: path) }
        case .welcome: showWelcome(nil)
        case .importThenWelcome: offerImportThenWelcome()
        case .newTerminal: openWindow(directory: newWindowDirectory) // where Settings › Terminal › New tabs says, as ⌘N
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
        // next one rather than open a window of their own. Each waits for its own project's window (RemoteConnection).
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
    /// A linked worktree's folder is kept out of Recent Projects, as Open in New Window keeps it (openWorktreeWindow).
    /// `forAgent`: an agent asked over MCP. Nothing comes forward here (the caller's presentForAgent brings it as
    /// AgentArrival says), a new window's first tab waits for the user's choice, the Welcome window stays while the user
    /// types in it, and the empty window the user is in is not taken for the project.
    @discardableResult
    func openFolder(_ path: String, newWindow: Bool, forAgent: Bool = false) -> TerminalWindowController {
        let path = canonicalPath(path)
        if WorktreeWindow.repository(ofLinkedWorktree: path) == nil { recent.add(path) }
        closeWelcome(forAgent: forAgent)
        if !newWindow, let open = controllers.first(where: { $0.project == path && !$0.hasClosed }) {
            if !forAgent { open.window?.makeKeyAndOrderFront(nil) }
            return open
        } else if !newWindow, let unused = controllers.first(where: { $0.isPristine && !$0.hasClosed && !(forAgent && $0.hasUsersKeyboard) }) {
            unused.adoptProject(path)
            if !forAgent { unused.window?.makeKeyAndOrderFront(nil) }
            return unused
        } else {
            return openWindow(directory: path, project: path, forAgent: forAgent)
        }
    }

    /// The Welcome window closes as a project opens, unless an agent opened it while the user types in the Welcome window.
    private func closeWelcome(forAgent: Bool) {
        if forAgent, let window = welcome?.window, window.isKeyWindow { return }
        welcome?.close()
    }

    /// A file from outside: in the window whose project holds it, else the front window, else a new window
    /// on the file's project (its git root, or its folder), or one with no project when its folder is never one.
    /// `forAgent`: open_in_editor. The file opens without taking the keyboard, and its window comes forward as
    /// AgentArrival says, not as a window the user went to.
    func openFile(_ path: String, line: Int?, column: Int, newWindow: Bool, forAgent: Bool = false) {
        let path = canonicalPath(path)
        let owners = controllers.filter { controller in !controller.hasClosed && (controller.project.map { path.hasPrefix($0 + "/") } ?? false) }
        let owner = owners.max { ($0.project?.count ?? 0) < ($1.project?.count ?? 0) }
        let front = (NSApp.keyWindow?.windowController as? TerminalWindowController) ?? controllers.last
        let target: TerminalWindowController
        if !newWindow, let window = owner ?? front {
            target = window
        } else if let root = ProjectRoot.project(from: (path as NSString).deletingLastPathComponent) {
            recent.add(root)
            target = openWindow(directory: root, project: root, forAgent: forAgent)
        } else {
            // A file in a folder that is never a project (~/notes.txt): a window with no project, in that folder.
            target = openWindow(directory: (path as NSString).deletingLastPathComponent, forAgent: forAgent)
        }
        closeWelcome(forAgent: forAgent)
        if forAgent {
            target.openFile(URL(fileURLWithPath: path), line: line, column: column, focus: false)
            target.presentForAgent(nil)
            return
        }
        target.window?.makeKeyAndOrderFront(nil)
        target.openFile(URL(fileURLWithPath: path), line: line, column: column)
    }

    private var settings: SettingsWindowController?
    /// The Settings window while it is open, for the self-test.
    var openSettings: SettingsWindowController? { settings?.window?.isVisible == true ? settings : nil }

    @objc func showSettings(_ sender: Any?) { showSettings(tab: nil) }

    /// Settings, on the tab it was left on, or on `tab` ("skills", SettingsWindowController's identifiers). `forAgent`
    /// (MCP show_settings): in front, but the keyboard stays where the user has it, as the approval window does.
    func showSettings(tab: String?, forAgent: Bool = false) {
        // The Claude app may have been opened since the last pass: what waits for it to quit, under the setting, is
        // worked out again (nothing is written while it is open).
        MCPRegistration.update(on: agentControl, claudeAppOnly: true)
        if settings == nil { settings = SettingsWindowController() }
        settings?.reload()
        if let tab { settings?.showTab(tab) }
        guard !forAgent else {
            if settings?.window?.isMiniaturized == true { settings?.window?.deminiaturize(nil) }
            settings?.window?.orderFront(nil)
            return
        }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    /// What Agents › Suggest a Command… does while it is off: Settings › Terminal at its Suggestions row, which says so
    /// and how to turn it on.
    func showSuggestionSettings() {
        showSettings(tab: "terminal")
        settings?.showSuggestions()
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

    /// The project windows open when Next Term last quit: a launch whose restore built no window reopens them when
    /// Settings › General says so, each with one fresh shell. Written at every quit, so changing the setting later works.
    private var sessionProjects: [String] {
        get { launchDefaults.stringArray(forKey: "sessionProjects") ?? [] }
        set { launchDefaults.set(newValue, forKey: "sessionProjects") }
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
    /// that ends, an MCP call): a second quit then is cancelled, and the update sheet is not offered (`Updater`).
    var askingToQuit = false
    /// Why the quit that went ahead happens, read as it went ahead: the quit's last save and the install go by it.
    private var terminatingFor: QuitReason?
    /// The update consent the quit went ahead under, read as it went ahead: the update's intent and its relaunch.
    private var terminatingUpdate: UpdateConsent?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A second quit while the first asks: cancelled, and the first's answers, its quit consent among them, stay its own.
        guard !askingToQuit else { return .terminateCancel }
        askingToQuit = true
        defer { askingToQuit = false }
        // The quit consent comes only from a press in this quit's questions (R30): none is left from a quit cancelled
        // before, and a cancel clears what this one gave. The update consent is Updater's, cleared when this quit is
        // cancelled.
        MainActor.assumeIsolated { SessionRestore.shared.quitConsent = false }
        // Why it quits is read once, before the questions: a download that ends under them never turns an update quit into
        // a user quit.
        let update = MainActor.assumeIsolated { Updater.shared.validConsent }
        let reason = quitReason
        guard let asking = askBeforeQuitting(update: update, reason: reason) else {
            MainActor.assumeIsolated { SessionRestore.shared.quitConsent = false }
            return .terminateCancel
        }
        let now = MainActor.assumeIsolated { Updater.shared.validConsent }
        guard case .goAhead(let ending) = QuitPolicy.ending(reason: reason, consentBefore: update, consentNow: now) else {
            // Another version was staged while it asked: the consent covered the one before, so the sheet asks again.
            MainActor.assumeIsolated { SessionRestore.shared.quitConsent = false }
            DispatchQueue.main.async { MainActor.assumeIsolated { Updater.shared.offerStaged() } }
            return .terminateCancel
        }
        MainActor.assumeIsolated { SessionRestore.shared.quitConsent = asking.quitConsent }
        isTerminating = true
        terminatingFor = ending
        terminatingUpdate = update
        // A skill change part-way finishes, and records its Undo, before Next Term quits.
        SkillsStore.waitForChanges()
        return .terminateNow
    }

    /// The quit's questions (QuitPolicy), one at a time: the save-changes and "Quitting stops…" alerts whenever they
    /// apply, as always, with the resume question on one of them, or else the plain quit dialog on its own. Under an
    /// update consent: the unsaved-files question alone, with no checkbox, and when the plan got worse than the one the
    /// consent covers, no question at all but the update sheet again (R16). Nil when the quit is cancelled. The answer is
    /// saved only once the quit goes ahead; the quit consent comes from it (QuitAsking).
    private func askBeforeQuitting(update consent: UpdateConsent?, reason: QuitReason) -> QuitAsking? {
        let dirty = controllers.flatMap(\.editorArea.dirtyDocuments)
        let projects = openProjects
        let settings = LaunchSettings(defaults: launchDefaults)
        let sheetAttached = NSApp.windows.contains { $0.attachedSheet != nil }
        let busyCount = controllers.flatMap(\.busyTabs).count
        // The update quit plans again, to compare with the plan its consent covers (KTD2).
        let update: UpdateQuit? = consent.map { (consent: UpdateConsent) -> UpdateQuit in
            UpdateQuit(consent: consent, current: MainActor.assumeIsolated { UpdatePlanning.plan() })
        }
        let input = QuitInput(unsavedFiles: dirty.count, busyTabs: busyCount, terminalWindows: controllers.count,
                              sheetAttached: sheetAttached, reason: reason, settings: settings, update: update)
        let questions: [QuitQuestion] = QuitPolicy.questions(input)
        var asking = QuitAsking()
        guard !questions.isEmpty else { return asking }
        if questions == [.updateSheet], let update {
            // Worse than what the user agreed to: this quit is cancelled, and the sheet shows again once it has returned.
            DispatchQueue.main.async { MainActor.assumeIsolated { UpdateKeepSessions.shared.showAgain(update) } }
            return nil
        }
        // A quit from the Dock while Next Term is behind another app: its first question shows in front.
        NSApp.activate(ignoringOtherApps: true)
        var plannedBusy: QuitQuestion?
        for question in questions {
            switch question {
            case .saveChanges(let checkbox):
                let alert = Self.saveBeforeQuittingAlert(dirty.map(\.name))
                let box = checkbox.map { QuitReopenPrompt.addCheckbox(to: alert, checked: $0, projects: projects) }
                // Save, Cancel, Don’t Save, as they were added. The box is read once a button is pressed (QuitAsking.ask).
                let dialog = QuitAlertDialog(alert, presses: [.save, .cancel, .goOn], box: box)
                switch asking.ask(question, on: dialog) {
                case .save:
                    guard controllers.allSatisfy({ $0.editorArea.saveAll() }) else { return nil }
                case .goOn:
                    break
                case .cancel:
                    return nil
                }
            case .busy:
                plannedBusy = question // asked below, once the busy tabs are read again
            case .quit(let checkbox):
                guard askPlain(checked: checkbox, projects: projects, into: &asking) else { return nil }
            case .updateSheet:
                return nil
            }
        }
        if let update {
            // The update path asks nothing about busy tabs: the sheet showed what stops. A tab that turned busy under the
            // unsaved-files question makes the plan worse: the sheet again, never "Quitting stops…".
            let now = UpdateQuit(consent: update.consent, current: MainActor.assumeIsolated { UpdatePlanning.plan() })
            guard UpdateFlow.worse(now.current, than: now.consent) == nil else {
                DispatchQueue.main.async { MainActor.assumeIsolated { UpdateKeepSessions.shared.showAgain(now) } }
                return nil
            }
            return asking
        }
        // Read again, as today: a tab that turned busy under a question before still gets "Quitting stops…". Only the
        // alert the policy chose carries the checkbox, so the question is never asked twice; when no tab is busy any more
        // and that alert was to carry it, the plain dialog asks instead (AE22, QuitPolicy.lastQuestion).
        let busy = controllers.flatMap(\.busyTabs)
        switch QuitPolicy.lastQuestion(planned: plannedBusy, busyTabs: busy.count) {
        case .busy(let checkbox):
            let alert = Self.quitStopsAlert(busy)
            let box = checkbox.map { QuitReopenPrompt.addCheckbox(to: alert, checked: $0, projects: projects) }
            let dialog = QuitAlertDialog(alert, presses: [.goOn, .cancel], box: box)
            guard asking.ask(.busy(resumeCheckbox: checkbox), on: dialog) == .goOn else { return nil }
        case .quit(let checkbox):
            guard askPlain(checked: checkbox, projects: projects, into: &asking) else { return nil }
        case .saveChanges, .updateSheet, nil:
            break
        }
        asking.settings(from: settings)?.save(to: launchDefaults)
        return asking
    }

    /// The plain quit dialog, "Quit Next Term?", its answer put into `asking`. False when it was cancelled.
    private func askPlain(checked: Bool, projects: [String], into asking: inout QuitAsking) -> Bool {
        let prompt = QuitReopenPrompt(projects: projects, checked: checked)
        return asking.ask(.quit(resumeCheckbox: checked), on: prompt.dialog) == .goOn
    }

    /// Why this quit happens: the plain self-test, the reason the relaunch harness sets, a valid update consent (the update
    /// sheet's "Update Now", or "Wait for Them" at its countdown's end), a logout, restart or shutdown (the quit Apple
    /// event), or else the user. The relaunch harness checks it.
    var quitReason: QuitReason {
        var harness: QuitReason?
        #if DEBUG
        harness = SelfTestRestore.quitReason
        #endif
        let consent = MainActor.assumeIsolated { Updater.shared.validConsent != nil }
        let code = QuitReopenPrompt.reasonCode(of: NSAppleEventManager.shared().currentAppleEvent)
        return QuitReason.of(plainSelfTest: SelfTest.mode == .plain, harness: harness, updateConsent: consent, appleEventReason: code)
    }

    /// The windows' projects, each once, in window order: what the resume checkbox's tooltip names.
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

    /// "Quit Next Term?", with what quitting stops: Quit, Cancel. Quit is not the default, so Return quits nothing (R29);
    /// NSAlert gives Cancel ⎋.
    static func quitStopsAlert(_ busy: [TerminalTab]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Next Term?"
        alert.informativeText = TerminalWindowController.stopText("Quitting stops", busy)
        alert.addButton(withTitle: "Quit").keyEquivalent = ""
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Each MCP call in flight hears that Next Term quits, or that it restarts for the update (KTD17).
        var restart: UpdateConsent?
        if (terminatingFor ?? quitReason) == .updateRelaunch {
            restart = terminatingUpdate ?? MainActor.assumeIsolated { Updater.shared.validConsent }
        }
        MCPRestoredTabs.drainAtQuit(update: restart)
        ClaudeIDEServer.shared.stop() // removes the lock file
        GeminiIDEServer.shared.stop()
        CopilotIDEServer.shared.stop()
        // The quit's last save (KTD18): the update's, under its consent, or what Settings › General says now, with the quit's
        // answer saved; scrollback only while "Keep scrollback" is on.
        let reason = terminatingFor ?? quitReason
        let settings = LaunchSettings(defaults: launchDefaults)
        let update = terminatingUpdate
        MainActor.assumeIsolated {
            let sessions = SessionRestore.shared
            var finished = SessionRestore.Finished()
            var intent = QuitIntent.ordinary(reason: reason, settings: settings, consent: sessions.quitConsent)
            if reason == .updateRelaunch, let consent = update ?? Updater.shared.validConsent {
                intent = QuitIntent.forUpdate(consent, from: Updater.shared.current?.description ?? "")
                // The open decisions the restart drops get a definite answer now.
                UpdateHolds.shared.cancelAll()
            }
            if let intent { finished = sessions.finishAtQuit(intent, keepScrollback: settings.keepScrollback) }
            #if DEBUG
            // The relaunch harness reads the quit's last save as it left the sessions folder, before the install.
            if SelfTest.mode == .relaunchHarness { SelfTestRestore.quitSaved() }
            #endif
            // A logout, restart or shutdown installs nothing: it could end the install part-way. It waits for the next quit.
            // Only the update's quit starts the new version; any other installs it alone (R17).
            let relaunch = intent?.relaunches ?? false
            if reason.installsStagedUpdate { Updater.shared.installStagedUpdateOnQuit(sessions: finished, relaunch: relaunch) }
        }
        if SelfTest.mode != .plain { sessionProjects = controllers.compactMap(\.project) }
        RemoteConnection.saveTabs(controllers)
        // Every tab from one snapshot taken before any signal; what outlives the hangup gets SIGTERM after one
        // shared second at most (no wait at all when nothing does), tabs closed just before included.
        let waiting = TerminalTab.terminate(controllers.flatMap(\.tabs), finishLater: false)
        RemoteConnection.shutdown() // the master connections; sessions kept by tmux or herdr stay on their hosts
        TabHangup.finishAtQuit(waiting)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controllers.forEach { $0.refreshVisibility() }
        controllers.forEach { $0.activityChanged() } // the window in front has its project's glow at full strength again
    }

    func applicationDidResignActive(_ notification: Notification) {
        controllers.forEach { $0.refreshVisibility() }
        controllers.forEach { $0.activityChanged() }
    }

    // MARK: windows

    /// `forAgent`: an agent asked over MCP. The window is placed but not shown here (the caller's presentForAgent brings
    /// it), and its first tab waits for the user's choice.
    @discardableResult
    func openWindow(directory: String?, project: String? = nil, forAgent: Bool = false) -> TerminalWindowController {
        let controller = TerminalWindowController(directory: directory, project: project, byAgent: forAgent)
        controller.onClose = { [weak self] closed, welcome in self?.windowClosed(closed, welcome: welcome) }
        closeWelcome(forAgent: forAgent)
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
        if forAgent { return controller }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    /// A window the restore built, placed and filled (SessionRestore): shown as it is, with no cascade and no first tab.
    func openWindow(restored controller: TerminalWindowController) {
        controller.onClose = { [weak self] closed, welcome in self?.windowClosed(closed, welcome: welcome) }
        welcome?.close()
        controllers.append(controller)
        if remoteRestorePending { restoreRemoteTabs() } // the launch's first terminal window
        projectsChanged()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// A terminal window closed.
    private func windowClosed(_ closed: TerminalWindowController, welcome: Bool) {
        // Out of the index at once: Go to Next Agent Needing You and the Welcome window never go to a closed window.
        windowIndex.remove(window: closed.indexID)
        self.welcome?.windowsChanged()
        // Defer: the window is still mid-close in this call.
        DispatchQueue.main.async { [self] in
            controllers.removeAll { $0 === closed }
            updateBadge()
            projectsChanged()
            // Closing the last project (or the last window's last tab) leaves the Welcome window, with
            // recent projects, like an IDE.
            if welcome && controllers.isEmpty && !isTerminating { showWelcome(nil) }
        }
    }

    /// New Terminal (File › New Window, ⌘N, the Welcome window's row): a window with no project, its shell where Settings ›
    /// Terminal › New tabs says, as ⌘T with no window open (the home folder unless a folder is chosen there).
    @objc func newWindow(_ sender: Any?) {
        openWindow(directory: newWindowDirectory)
    }

    /// A worktree's own window, with one shell tab in its folder, titled "xCloud ▸ 7027-sso": the window
    /// already open on it brought forward, else a new one. Kept out of Recent Projects, which a repository's
    /// many worktrees would fill.
    @discardableResult
    func openWorktreeWindow(_ path: String) -> TerminalWindowController {
        let path = canonicalPath(path)
        welcome?.close()
        if let open = controllers.first(where: { $0.project == path }) {
            open.window?.makeKeyAndOrderFront(nil)
            return open
        }
        return openWindow(directory: path, project: path)
    }

    /// Where Open in New Worktree… puts new folders (Settings › Editor › Git): beside the repository, or in
    /// its `.claude/worktrees` when it ignores that folder.
    var worktreeLocation: WorktreeLocation {
        get { WorktreeLocation(rawValue: UserDefaults.standard.string(forKey: "worktreeLocation") ?? "") ?? .beside }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "worktreeLocation") }
    }

    /// Open in New Worktree's choice for the ignored files (Copy, Link or Leave Out), as it was last left for the
    /// repository whose main checkout is `main`: before there was a choice, Copy where "Copy ignored files too" was
    /// ticked; Leave Out for one never seen. Saved when Create is pressed; the choice is the setting.
    func ignoredFilesChoice(for main: String) -> WorktreeCopy.Choice {
        let path = canonicalPath(main)
        let saved = UserDefaults.standard.dictionary(forKey: "worktreeIgnoredFiles")?[path] as? String
        let before = UserDefaults.standard.dictionary(forKey: "worktreeCopiesIgnored")?[path] as? Bool
        return WorktreeCopy.Choice.remembered(saved, copiedBefore: before)
    }

    func setIgnoredFilesChoice(_ choice: WorktreeCopy.Choice, for main: String) {
        let path = canonicalPath(main)
        var choices = UserDefaults.standard.dictionary(forKey: "worktreeIgnoredFiles") ?? [:]
        choices = choices.filter { FileManager.default.fileExists(atPath: $0.key) } // repositories gone since
        choices[path] = choice.rawValue
        UserDefaults.standard.set(choices, forKey: "worktreeIgnoredFiles")
        // The checkbox's own setting, now the choice holds it.
        if var before = UserDefaults.standard.dictionary(forKey: "worktreeCopiesIgnored"), before.removeValue(forKey: path) != nil {
            if before.isEmpty {
                UserDefaults.standard.removeObject(forKey: "worktreeCopiesIgnored")
            } else {
                UserDefaults.standard.set(before, forKey: "worktreeCopiesIgnored")
            }
        }
    }

    // MARK: projects

    private var recent: RecentProjects {
        get { RecentProjects(UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []) }
        set {
            UserDefaults.standard.set(newValue.paths, forKey: "recentProjects")
            // A folder dropped as missing, Clear Menu, or an import under the Welcome window: it lists them as they are now.
            if welcome?.window?.isVisible == true { welcome?.reloadProjects() }
            // And every window's "No project open", which otherwise refreshes only when its window becomes key.
            let showing: [TerminalWindowController] = controllers.filter { (controller: TerminalWindowController) -> Bool in
                controller.sidebar.showsNoProject
            }
            guard !showing.isEmpty else { return }
            let shown: [String] = newValue.existing()
            for controller in showing { controller.sidebar.noProject.show(recent: shown) }
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

    /// Sets the list as given (Undo of an import gives today’s list less what the import added).
    func setRecentProjects(_ paths: [String]) {
        recent = RecentProjects(paths)
    }

    /// A worktree removed or forgotten (GitActions.runRemoval): it leaves the list, with any project inside it, as its
    /// folder is gone. `places` spells the folder each way it may have been kept (as git and as the kernel spell it).
    func forgetRecentProjects(under places: [String]) {
        var list = recent
        for project in list.paths where places.contains(where: { project == $0 || project.hasPrefix($0 + "/") }) { list.remove(project) }
        if list.paths != recent.paths { recent = list }
        // The Welcome window's history too, so a removed worktree is not kept there as a folder gone for now.
        MainActor.assumeIsolated { ProjectHistoryRecorder.shared.forget(under: places) }
    }

    /// Where Open Project goes when the current window is in use: ask, this window, or a new one.
    typealias ProjectTarget = ProjectOpening.Setting

    /// File › Open Projects In, Settings › General's Projects row, the Ask dialog's remembered choice or an import set
    /// `projectTarget`: the Settings row follows.
    static let projectTargetChanged = Notification.Name("NextTermProjectTargetChanged")

    var projectTarget: ProjectTarget {
        get { ProjectTarget(rawValue: UserDefaults.standard.string(forKey: "openProjectsIn") ?? "") ?? .ask }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "openProjectsIn")
            NotificationCenter.default.post(name: Self.projectTargetChanged, object: self)
        }
    }

    private var welcome: WelcomeWindowController?
    /// For the self-test.
    var welcomeController: WelcomeWindowController? { welcome }

    /// File › Open Project… (⌘O): the Welcome window, as at the first launch: your projects with a search, their agents'
    /// sessions and your servers, and Open… for a folder not listed. A project chosen there opens as if from the window
    /// you asked in (`welcomeOrigin`). Asked again with the Welcome window in front, it is that Open….
    @objc func openProjectPanel(_ sender: Any?) {
        if let window = welcome?.window, window.isVisible {
            if let sheet = window.attachedSheet { return sheet.makeKeyAndOrderFront(nil) } // the panel is up already
            if window.isKeyWindow { return chooseProjectFolder(sender) }
        }
        showWelcome(sender)
    }

    /// Open…: the panel to choose a folder as a project. On the Welcome window in front (its Open… button, ⌘O there,
    /// Return with no project chosen) it comes over it; otherwise over the terminal window in front, or on its own.
    @objc func chooseProjectFolder(_ sender: Any?) {
        let overWelcome = welcome?.window.flatMap { $0.isVisible && $0.isKeyWindow ? $0 : nil }
        let from = overWelcome == nil ? NSApp.keyWindow?.windowController as? TerminalWindowController : welcomeOrigin
        chooseProjectFolder(from: from, over: overWelcome)
    }

    /// The same panel for a window that asked itself, not the key one (a notice in it, which can't be key): over `sheet`,
    /// else over `from`'s window, or on its own with neither; the folder chosen opens as if from `from`.
    func chooseProjectFolder(from: TerminalWindowController?, over sheet: NSWindow? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a project folder"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openProject(at: url, from: from)
        }
        if let window = sheet ?? from?.window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    /// The terminal window the Welcome window was last asked from, while it is open and shown: where a project chosen
    /// on the Welcome window opens (`openProject`'s “this window”). Nil when it was shown with none in front.
    var welcomeOrigin: TerminalWindowController? {
        guard let origin = welcomeOriginController, controllers.contains(where: { $0 === origin }), origin.window?.isVisible == true else { return nil }
        return origin
    }
    private weak var welcomeOriginController: TerminalWindowController?

    @objc func openRecentProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openProject(at: URL(fileURLWithPath: path), from: NSApp.keyWindow?.windowController as? TerminalWindowController)
    }

    @objc func clearRecentProjects(_ sender: Any?) {
        MainActor.assumeIsolated { ProjectHistoryRecorder.shared.clear() }
        recent = RecentProjects()
    }

    @objc func setProjectTarget(_ sender: NSMenuItem) {
        if let target = sender.representedObject as? String, let value = ProjectTarget(rawValue: target) { projectTarget = value }
    }

    /// Opens a folder as a project. Reuses an untouched window; otherwise this window or a new one,
    /// as the user chooses (and may remember), like an IDE. A window the restore brought back is neither: while it holds
    /// what came back, the folder opens in a window of its own (ProjectOpening.placement).
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
        let target = controller ?? controllers.last(where: { $0.window?.isVisible == true })
        let from = target.map { (target: TerminalWindowController) -> ProjectOpening.Target in
            ProjectOpening.Target(pristine: target.isPristine, holdsRestore: target.holdsRestore)
        }
        var choice = projectTarget
        let placement = ProjectOpening.placement(from: from, setting: choice)
        guard let target, placement != .newWindow else {
            openWindow(directory: path, project: path)
            return
        }
        if placement == .adopt {
            target.adoptProject(path)
            target.window?.makeKeyAndOrderFront(nil)
            return
        }
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
            alert.informativeText = TerminalWindowController.stopText("This stops", busy)
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
        switch requests.arrive(urls) {
        case .held: break // until the restore has built its windows
        case .asRequest: open(urls, asRequest: true)
        case .asProject: open(urls, asRequest: false)
        }
    }

    /// Opens what `application(_:open:)` named. `asRequest`: the launch's own request (R32), which opens as `nxtrm` does,
    /// in front, each folder in its own window, its project's, an unused one or a new one, never in place of a window the
    /// restore brought back. Otherwise a folder opens as Open Project does (`openProject`): an unused key window is taken
    /// over and a used one may be replaced, as "Open Projects In" says, but one the restore brought back is neither.
    private func open(_ urls: [URL], asRequest: Bool) {
        for url in urls {
            var isDir: ObjCBool = false
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue && asRequest {
                openFolder(url.path, newWindow: false)
            } else if isDir.boolValue {
                openProject(at: url, from: NSApp.keyWindow?.windowController as? TerminalWindowController)
            } else {
                openFile(url.path, line: nil, column: 1, newWindow: false) // Finder's Open With
            }
        }
    }

    @objc func showWelcome(_ sender: Any?) {
        // Asked again from the Welcome window itself, it keeps the window it came from.
        if !(welcome?.window?.isKeyWindow ?? false) { welcomeOriginController = NSApp.keyWindow?.windowController as? TerminalWindowController }
        if welcome == nil { welcome = WelcomeWindowController() }
        welcome?.showWindow(nil)
        welcome?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        // The windows with a terminal that needs you, first: the one Go to Next Agent Needing You goes to at the top, each
        // with its most urgent mark, as its tab bar shows it.
        refreshWindowIndex()
        for window in windowIndex.windowsWaiting {
            guard let waiting = windowIndex.firstWaiting(in: window.id) else { continue }
            let item = menu.addItem(withTitle: window.title, action: #selector(goToWaitingWindow(_:)), keyEquivalent: "")
            item.target = self
            item.tag = window.id
            item.image = StatusGlyph.image(for: waiting.state)
            item.toolTip = window.marks.spoken(working: false)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
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
            // On while the Welcome window lists a closed project too: Recent Projects can be empty while it does.
            let clears: Bool = !projects.isEmpty || MainActor.assumeIsolated { ProjectHistoryRecorder.shared.canClear }
            let clearAction: Selector? = clears ? #selector(clearRecentProjects(_:)) : nil
            let clear = menu.addItem(withTitle: "Clear Menu", action: clearAction, keyEquivalent: "")
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
        openWindow(directory: newWindowDirectory)
    }

    /// The terminal window used last, for a tab command given while another window is in front (Welcome,
    /// Settings).
    /// The terminal window the user went to last (one brought forward for an agent doesn't count: keyingForAgent).
    var lastUsedController: TerminalWindowController? { controllers.max { $0.lastKey < $1.lastKey } }

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
        if item.action == #selector(setTerminalTabs(_:)) {
            item.state = item.representedObject as? String == terminalTabs.rawValue ? .on : .off
        }
        if item.action == #selector(toggleTabListFolders(_:)) {
            item.state = tabListShowsFolders ? .on : .off
            return terminalTabs.listSide != nil // a second line for the list's rows: the bar has none
        }
        if item.action == #selector(toggleSidebarSingleClick(_:)) { item.state = sidebarSingleClickOpens ? .on : .off }
        if item.action == #selector(toggleProjectColors(_:)) { item.state = ProjectColorStore.isShown ? .on : .off }
        if item.action == #selector(toggleSoftWrap(_:)) { item.state = softWrap ? .on : .off }
        if item.action == #selector(toggleSuggestionsWhileTyping(_:)) { item.state = GhostPreferences.isOn ? .on : .off }
        if item.action == #selector(togglePrivateMode(_:)) { item.state = GhostPreferences.privateMode ? .on : .off }
        if item.action == #selector(toggleBlameAnnotations(_:)) { item.state = blameAnnotations ? .on : .off }
        if item.action == #selector(toggleCurrentLineBlame(_:)) { item.state = currentLineBlame ? .on : .off }
        if item.action == #selector(setAgentSpinner(_:)) { item.state = item.representedObject as? String == AgentSpinner.current.rawValue ? .on : .off }
        if item.action == #selector(setLineHeight(_:)), let value = item.representedObject as? Double {
            item.state = abs(CGFloat(value) - editorLineHeight) < 0.001 ? .on : .off
        }
        if item.action == #selector(toggleAutomaticUpdates(_:)) {
            item.state = MainActor.assumeIsolated { Updater.shared.automaticChecks } ? .on : .off
        }
        return true
    }

    /// View › Project Color › Show Project Colors (and Settings › General): every window's colour, shown or not. Each
    /// project keeps its own while they are hidden.
    @objc func toggleProjectColors(_ sender: Any?) {
        ProjectColorStore.isShown.toggle()
    }

    /// View › Agent Spinner: Spinning, Still or Off, for every window at once.
    @objc func setAgentSpinner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = AgentSpinner(rawValue: raw) else { return }
        AgentSpinner.current = choice
    }

    /// The tabs' marks and titles drawn again when Agent Spinner (or Reduce Motion) changes.
    private func followAgentSpinner() {
        AgentSpinner.followSystemMotion()
        NotificationCenter.default.addObserver(forName: AgentSpinner.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controllers.forEach { $0.refresh() } }
        }
    }

    // MARK: font size

    // ⌘+, ⌘- and ⌘0 change the size of what has the keyboard: a terminal's own size while a terminal has the
    // keyboard and a size of its own, else the editor's (which terminals without their own follow).
    @objc func increaseFontSize(_ sender: Any?) { changeFontSize(by: 1) }
    @objc func decreaseFontSize(_ sender: Any?) { changeFontSize(by: -1) }
    @objc func resetFontSize(_ sender: Any?) { changeFontSize(by: nil) }

    /// nil: back to the default size.
    private func changeFontSize(by step: CGFloat?) {
        if let own = terminalOwnFontSize, NSApp.keyWindow?.firstResponder is NextTermView {
            setTerminalFontSize(step.map { own + $0 } ?? Theme.defaultFontSize)
        } else {
            setFontSize(step.map { fontSize + $0 } ?? Theme.defaultFontSize)
        }
    }

    /// The editor's size, in every editor, and in every terminal that has no size of its own.
    func setFontSize(_ size: CGFloat) {
        fontSize = Self.clampedFontSize(size)
        controllers.forEach { $0.applyFontSizes() }
    }

    /// The terminal's own size in every terminal (nil: terminals use the editor's size again).
    func setTerminalFontSize(_ size: CGFloat?) {
        terminalOwnFontSize = size.map(Self.clampedFontSize)
        controllers.forEach { $0.applyFontSizes() }
    }

    static func clampedFontSize(_ size: CGFloat) -> CGFloat {
        min(max(size, Theme.fontSizeRange.lowerBound), Theme.fontSizeRange.upperBound)
    }

    // MARK: every window's agents

    /// Every terminal window and what its terminals show (WindowIndex): for Agents › Go to Next Agent Needing You, the
    /// Welcome window's rows and the Dock menu. Each window tells it as it refreshes, from its tabs' own status, so
    /// nothing is polled for it, and leaves it as it closes.
    private(set) var windowIndex = WindowIndex()

    /// A window refreshed: its entry as it is now. A change reaches the Welcome window while it shows.
    func indexed(_ controller: TerminalWindowController) {
        // A window being made is told once it is listed; one closing, never again.
        guard !controller.hasClosed, controllers.contains(where: { $0 === controller }) else { return }
        guard windowIndex.update(controller.indexEntry) else { return }
        welcome?.windowsChanged()
    }

    /// Every window's entry as it is this moment, not at its last refresh (a window no one can see refreshes once a
    /// second): before a key or a menu reads the index.
    func refreshWindowIndex() {
        for controller in controllers where !controller.hasClosed { windowIndex.update(controller.indexEntry) }
    }

    /// Agents › Go to Next Agent Needing You: the terminal that has waited longest for you (a decision, then a failure,
    /// then a finished agent or command), its window brought forward and its tab or pane selected; pressed again there,
    /// the next one, round to the first. With none, a notice says so and nothing beeps.
    @objc func goToNextAgentNeedingYou(_ sender: Any?) {
        refreshWindowIndex()
        let key = NSApp.keyWindow?.windowController as? TerminalWindowController
        // The tab in front counts as gone to only while it shows; folded, what it holds is news like any other tab's.
        let front: TerminalTab? = key?.activeTab.flatMap { (tab: TerminalTab) -> TerminalTab? in
            key?.isOnScreen(tab) == true ? tab : nil
        }
        guard let next = windowIndex.next(from: front?.id) else {
            let shown: NSWindow? = NSApp.keyWindow ?? TerminalWindow.front
            GitToast.show(WindowIndex.nothingWaiting, in: shown)
            return
        }
        go(to: next)
    }

    /// The Dock menu's item for a window waiting for you (its `tag`, the window's id): its terminal that needs you most;
    /// seen since, the window as it is.
    @objc func goToWaitingWindow(_ sender: NSMenuItem) {
        refreshWindowIndex()
        if let waiting = windowIndex.firstWaiting(in: sender.tag) { return go(to: waiting) }
        let controller = controllers.first { $0.indexID == sender.tag && !$0.hasClosed }
        NSApp.activate(ignoringOtherApps: true)
        controller?.window?.makeKeyAndOrderFront(nil)
    }

    /// `waiting`'s window in front, with its tab selected and its pane focused, as a click on its notification does.
    private func go(to waiting: WindowIndex.Waiting) {
        guard let controller = controllers.first(where: { $0.indexID == waiting.window && !$0.hasClosed }),
              let tab = controller.tabs.first(where: { $0.id == waiting.tab }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.show(tab)
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

    func deliver(_ request: UNNotificationRequest) {
        // A tab's title, a question or a command can hold a stored key's value: masked, in a copy.
        var request = request
        let mask = SecretMask.current
        if !mask.isEmpty, let content = request.content.mutableCopy() as? UNMutableNotificationContent {
            content.title = mask.mask(content.title)
            content.subtitle = mask.mask(content.subtitle)
            content.body = mask.mask(content.body)
            request = UNNotificationRequest(identifier: request.identifier, content: content, trigger: request.trigger)
        }
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
        let reminder = SecretReminder(userInfo: response.notification.request.content.userInfo)
        DispatchQueue.main.async { [self] in
            NSApp.activate(ignoringOtherApps: true)
            if let reminder { // a key rotation reminder: Rotate… for its key
                SecretReminders.open(reminder)
                return completionHandler()
            }
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

    @objc func showAcknowledgements(_ sender: Any?) {
        MainActor.assumeIsolated { AcknowledgementsWindowController.show() }
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Next Term")
        app.addItem(withTitle: "About Next Term", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        item(app, "Acknowledgements", #selector(showAcknowledgements(_:)), "", target: self)
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
        // ⇧⌘O, VS Code's Go to Symbol (headings, in a Markdown file); ⌘F12 under JetBrains' keys, whose ⇧⌘O is Go to File.
        item(edit, "Go to Heading…", #selector(TerminalWindowController.goToHeading(_:)), "o", [.command, .shift])
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
        // A Markdown file's, in the markers it already uses; their keys work while its editor has the keyboard, so ⌘B hides
        // the sidebar everywhere else. ⌥⌘0 to ⌥⌘6 for the headings, as ⌘1 to ⌘9 select tabs.
        let markdown = NSMenu(title: "Markdown")
        edit.addItem(withTitle: "Markdown", action: nil, keyEquivalent: "").submenu = markdown
        item(markdown, "Bold", #selector(CodeTextView.toggleMarkdownBold(_:)), "b")
        item(markdown, "Italic", #selector(CodeTextView.toggleMarkdownItalic(_:)), "i")
        item(markdown, "Strikethrough", #selector(CodeTextView.toggleMarkdownStrikethrough(_:)), "x", [.command, .shift])
        item(markdown, "Code", #selector(CodeTextView.toggleMarkdownCode(_:)), "")
        item(markdown, "Link", #selector(CodeTextView.insertMarkdownLink(_:)), "k")
        markdown.addItem(.separator())
        let headings = NSMenu(title: "Heading")
        markdown.addItem(withTitle: "Heading", action: nil, keyEquivalent: "").submenu = headings
        item(headings, "Body Text", #selector(CodeTextView.markdownBodyText(_:)), "0", [.command, .option])
        for level in 1...6 {
            item(headings, "Heading \(level)", #selector(CodeTextView.markdownHeading(_:)), "\(level)", [.command, .option]).tag = level
        }
        item(markdown, "Bulleted List", #selector(CodeTextView.toggleMarkdownBullets(_:)), "")
        item(markdown, "Numbered List", #selector(CodeTextView.toggleMarkdownNumbers(_:)), "")
        item(markdown, "Toggle Task", #selector(CodeTextView.toggleMarkdownTask(_:)), "l", [.command, .shift])
        item(markdown, "Quote", #selector(CodeTextView.toggleMarkdownQuote(_:)), "")
        item(markdown, "Code Block", #selector(CodeTextView.insertMarkdownCodeBlock(_:)), "")
        edit.addItem(.separator())
        item(edit, "Clear Buffer", #selector(TerminalWindowController.clearBuffer(_:)), "k")
        // While a suggestion shows after the cursor: that command leaves Next Term's record of yours.
        item(edit, "Forget This Suggestion", #selector(TerminalWindowController.forgetSuggestion(_:)), "\u{8}", [.command, .shift])

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
        view.addItem(withTitle: "Terminal Tabs", action: nil, keyEquivalent: "").submenu = TabListMenus.view(target: self)
        item(view, "Show Changes", #selector(TerminalWindowController.showChanges(_:)), "g", [.command, .option])
        // ⌃⌘ as Git Diff's ⌃⌘G: U for Unified. The blame toggles are A for Annotate (Xcode's Authors key) and L for Line.
        item(view, "Unified Diffs", #selector(DiffLayoutMenu.toggleUnifiedDiffs(_:)), "u", [.command, .control], target: DiffLayoutMenu.shared) // checked: one column
        item(view, "Annotate with Git Blame", #selector(toggleBlameAnnotations(_:)), "a", [.command, .shift, .control], target: self)
        item(view, "Current Line Blame", #selector(toggleCurrentLineBlame(_:)), "l", [.command, .shift, .control], target: self)
        view.addItem(.separator())
        // ⌥⌘W, as TextMate has it: VS Code's ⌥Z types a letter on some keyboards (ż in Polish), so it can't be a default here.
        item(view, "Soft Wrap", #selector(toggleSoftWrap(_:)), "w", [.command, .option], target: self)
        item(view, "Hide .env Values", #selector(TerminalWindowController.toggleEnvValues(_:)), "") // checked: the file in front
        // ⇧⌘V, the Markdown preview's key in VS Code. Checked for the file in front; off for any other file.
        item(view, "Markdown Live Preview", #selector(TerminalWindowController.toggleMarkdownPreview(_:)), "v", [.command, .shift])
        item(view, "Suggestions While Typing", #selector(toggleSuggestionsWhileTyping(_:)), "", target: self).toolTip =
            "A command you ran before, dimmed after the cursor at a zsh prompt. Off, none shows and no command is recorded."
        item(view, "Private Mode", #selector(togglePrivateMode(_:)), "", target: self).toolTip =
            "No suggestions while typing, and no command of yours recorded, until you turn it off or quit Next Term."
        let heights = NSMenu(title: "Line Height")
        for value in Self.lineHeights {
            let title = ["1.0", "1.15", "1.25", "1.35 (default)", "1.5", "1.75", "2.0"][Self.lineHeights.firstIndex(of: value) ?? 0]
            let entry = item(heights, title, #selector(setLineHeight(_:)), "", target: self)
            entry.representedObject = Double(value)
        }
        view.addItem(withTitle: "Line Height", action: nil, keyEquivalent: "").submenu = heights
        // How a terminal tab shows its agent working; also in Settings › Notifications.
        let spinner = NSMenu(title: "Agent Spinner")
        for choice in AgentSpinner.allCases {
            item(spinner, choice.title, #selector(setAgentSpinner(_:)), "", target: self).representedObject = choice.rawValue
        }
        view.addItem(withTitle: "Agent Spinner", action: nil, keyEquivalent: "").submenu = spinner
        // The window's colour along its top row; also a right-click there, and Show Project Colors in Settings › General.
        view.addItem(withTitle: ProjectColorMenu.title, action: nil, keyEquivalent: "").submenu = ProjectColorMenu.submenu()
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
        // Across every window, the agent waiting longest, then the next. ⇧⌘U, U for Unread, as agent apps have it; free in
        // every shortcut set (MenuKeys).
        item(agents, "Go to Next Agent Needing You", #selector(goToNextAgentNeedingYou(_:)), "u", [.command, .shift], target: self)
        agents.addItem(.separator())
        item(agents, "Resume Agent Session…", #selector(TerminalWindowController.resumeSession(_:)), "o", [.command, .option])
        item(agents, "Send to Agent", #selector(TerminalWindowController.sendToAgent(_:)), "k", [.command, .option])
        item(agents, "Suggest a Command…", #selector(CommandSuggestionController.suggestCommand(_:)), "k", [.command, .control],
             target: CommandSuggestionController.shared)

        // Prompts as tasks in the project's todo folder, for tomorrow's agent.
        MainActor.assumeIsolated { TasksMenu.shared.fill(submenu(main, "Tasks")) }
        // Secrets, after Tasks, whose servers and commands use its keys. Show Secrets keeps Window › Secrets' action, so its key stays.
        MainActor.assumeIsolated { SecretsMenu.shared.fill(submenu(main, "Secrets")) }

        let git = submenu(main, "Git")
        item(git, "Branches…", #selector(TerminalWindowController.showBranches(_:)), "b", [.command, .option])
        // The branch popup at its Worktrees: where each is listed, opened, unlocked and removed.
        item(git, "Worktrees…", #selector(TerminalWindowController.showWorktrees(_:)), "")
        git.addItem(.separator())
        // Fetch is ⌘R, as in the branch popup (the same fetch of every remote). Update Project can change files without
        // asking (it fast-forwards), so it takes three keys, U for Update. Commit… is Tower's and Sourcetree's ⇧⌘C, New Branch… Fork's
        // and Sourcetree's ⇧⌘B; Push… is ⌥⌘P, P beside Branches… and Git Log (⇧⌘P is Push in some apps, Pull or the
        // command palette in others).
        item(git, "Fetch", #selector(TerminalWindowController.gitFetch(_:)), "r")
        item(git, "Update Project", #selector(TerminalWindowController.gitUpdate(_:)), "u", [.command, .option])
        item(git, "Commit…", #selector(TerminalWindowController.gitCommit(_:)), "c", [.command, .shift])
        item(git, "Push…", #selector(TerminalWindowController.gitPush(_:)), "p", [.command, .option])
        item(git, "New Branch…", #selector(TerminalWindowController.gitNewBranch(_:)), "b", [.command, .shift])
        git.addItem(.separator())
        // ⌥⌘Z, the JetBrains IDEs' Rollback: the file's uncommitted changes back to the last commit, with Undo.
        item(git, "Rollback…", #selector(TerminalWindowController.gitRollback(_:)), "z", [.command, .option])
        git.addItem(.separator())
        item(git, "Git Log", #selector(TerminalWindowController.showGitLog(_:)), "l", [.command, .option])
        item(git, "Git Diff", #selector(TerminalWindowController.showGitDiff(_:)), "g", [.command, .control])
        item(git, "Git Commands", #selector(TerminalWindowController.showGitCommands(_:)), "")

        // Settings › Notifications, in the menu bar: each choice with its checkmark.
        MainActor.assumeIsolated { NotificationsMenu.shared.fill(submenu(main, "Notifications")) }

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

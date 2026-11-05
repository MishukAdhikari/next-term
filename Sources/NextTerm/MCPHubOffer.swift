import AppKit
import NextTermCore

/// The one offer Next Term makes for an MCP server newly added to an agent's own config (R11): “Codex has a new MCP
/// server, “linear”. Use it in every agent in Next Term?”, with Add… (Settings › MCP Servers' sheet for it, the paste
/// path's key handling) and Not Now. Calm by its rules:
/// - **Never for what was there.** The first time this version looks, every server in the agents' configs is the
///   baseline, seen and never offered (it is listed under Found in your agents); so is one the user's list has. A file
///   that couldn't be read then (too large, caught mid-save) is its own baseline the first time it reads.
/// - **Once a server.** A server offered is seen from the moment the offer shows, whatever the answer, or none.
/// - **At a quiet moment**, as hints come (HintCenter): never while the user types, while the agent in front works or
///   asks, or while another hint or notice is up; it waits, as a notice at the bottom of the window in front that takes
///   no keyboard (GitToast).
/// - **Cheap.** The agents' own files are watched (each, and its folder, for an agent that saves by renaming), and read
///   again only when one changed (MCPHubAgentServers), at most every `spacing` seconds; and once each time Next Term
///   comes to the front. No loop reads them. Projects' own files are not read here: a project opened is not news.
/// Never in a self-test, and nothing is offered while agent control is off (the hub rides it): what is added meanwhile
/// is seen then.
@MainActor
enum MCPHubOffer {
    /// The servers seen: the baseline, and each one offered since. In UserDefaults, by name.
    static let seenKey = "mcpHubAgentServersSeen"
    /// The agents' files whose servers were taken as the baseline (MCPHubAgents.Seen.files), by path.
    static let seenFilesKey = "mcpHubAgentFilesSeen"
    /// The least time between two reads of the agents' files.
    static let spacing: TimeInterval = 30
    /// How long a due offer waits for a quieter moment before it looks again.
    static let retryAfter: TimeInterval = 5

    private static var started = false
    private static let reader = MCPHubAgentServers.Reader()
    private static var due: [MCPHubAgents.Server] = []
    private static var lastRead: TimeInterval = -.infinity
    private static var scheduled: DispatchWorkItem?
    private static var retry: DispatchWorkItem?
    private static var watches: [DispatchSourceFileSystemObject] = []

    /// At launch: a first look once the launch has settled, then on each change and each return to the front.
    static func start() {
        guard !started, !SelfTest.isRequested else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { check() }
        }
        schedule(after: 15)
    }

    /// The agents' own configs: no project's.
    static var sources: [SecretImport.Source] { SecretImport.sources(projects: []) }

    /// Reads the configs that changed, at most every `spacing` seconds, then offers what is due.
    static func check() {
        let wait = lastRead + spacing - ProcessInfo.processInfo.systemUptime
        if wait > 0 { return schedule(after: wait) }
        lastRead = ProcessInfo.processInfo.systemUptime
        let sources = sources
        let userFile = MCPHubEdits.userFile
        MCPHubAgentServers.readFiles(sources, with: reader) { files in
            let user = MCPHubScope.sources(folder: nil, home: NSHomeDirectory(), userFile: userFile).user
            let added = Set(MCPHubOverview.personal(user).map(\.name))
            let seen = storedSeen()
            var (offer, now) = MCPHubAgents.due(files, seen: seen, added: added)
            if !AppDelegate.shared.agentControl {
                now.servers.formUnion(offer.map(\.name))
                offer = []
            }
            if now != seen {
                UserDefaults.standard.set(now.servers.sorted(), forKey: seenKey)
                UserDefaults.standard.set(now.files.sorted(), forKey: seenFilesKey)
            }
            due = offer
            watch(sources)
            present()
        }
    }

    /// What was seen, as UserDefaults keeps it: nil before this version's first look.
    private static func storedSeen() -> MCPHubAgents.Seen? {
        guard let servers = UserDefaults.standard.stringArray(forKey: seenKey) else { return nil }
        return MCPHubAgents.Seen(servers: Set(servers), files: Set(UserDefaults.standard.stringArray(forKey: seenFilesKey) ?? []))
    }

    private static func schedule(after seconds: TimeInterval) {
        scheduled?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { check() } }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 0.5), execute: work)
    }

    // MARK: watching

    /// Watches each config there and each folder that holds one, afresh after every read (a file saved by renaming is a
    /// new file). A change waits two seconds for the writer to finish.
    private static func watch(_ sources: [SecretImport.Source]) {
        for watch in watches { watch.cancel() }
        watches = []
        let files = sources.map(\.path)
        let folders = Set(files.map { ($0 as NSString).deletingLastPathComponent })
        for path in files + folders.sorted() {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete],
                                                                   queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { schedule(after: 2) } }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watches.append(source)
        }
    }

    // MARK: offering

    /// Shows the first due offer when the moment is quiet, else looks again shortly (while Next Term is in front; else
    /// when it comes back).
    static func present() {
        retry?.cancel()
        guard let server = due.first else { return }
        guard let window = quietWindow() else {
            guard NSApp.isActive else { return }
            let work = DispatchWorkItem { MainActor.assumeIsolated { present() } }
            retry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + retryAfter, execute: work)
            return
        }
        due.removeFirst()
        var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        seen.insert(server.name)
        UserDefaults.standard.set(seen.sorted(), forKey: seenKey)
        GitToast.show(MCPHubAgents.offerText(server), in: window, button: "Add\u{2026}", action: { add(server) }, other: "Not Now",
                      otherAction: {}, primary: true)
    }

    /// The project window in front, when the moment is one a hint could come in: Next Term in front, no key for
    /// HintRules.quietKeys, the tab in front not an agent at work or asking, and no hint or notice up.
    static func quietWindow() -> NSWindow? {
        guard NSApp.isActive, let controller = NSApp.keyWindow?.windowController as? TerminalWindowController, let window = controller.window,
              window.attachedSheet == nil, HintCenter.shared.visible == nil, !GitToast.isShowing,
              HintCenter.sinceKey() >= HintRules.quietKeys else { return nil }
        let state = controller.activeTab?.status.state
        return state == .working || state == .attention ? nil : window
    }

    /// Add…: Settings › MCP Servers, with the sheet for this server.
    static func add(_ server: MCPHubAgents.Server) {
        AppDelegate.shared.showSettings(tab: "mcp")
        AppDelegate.shared.openSettings?.mcpServers?.addFound(server)
    }
}

import AppKit
import NextTermCore

/// Which tabs are chat tabs, and their hosts (plan 037 KTD9): a chat tab is a `TerminalTab` whose `start()` hands it to
/// a `ChatTabHost` instead of starting a shell. A chat is opened through the window's own `addTab` or `split`, with its
/// start set around that call (`open`), or registered by a restored tab's id before its `start()` (`register`). Main
/// thread, as `AgentSessionSocket.reports` is; the agents' process ids are read on any thread.
enum ChatTabs {
    /// Each chat tab's host, by tab id.
    nonisolated(unsafe) static var hosts: [UUID: ChatTabHost] = [:]

    /// The start the next `TerminalTab.start()` claims: set only around `open`'s synchronous `addTab` or `split`.
    nonisolated(unsafe) private static var opening: ChatStart?

    /// Starts registered by a restored tab's id, claimed by its `start()`; `idle`: shown with a Resume button, nothing run.
    nonisolated(unsafe) private static var registered: [UUID: (start: ChatStart, idle: Bool, note: String?)] = [:]

    /// The handoff's key as the user has it (⇧⌘J by default), for the note on a terminal-only command; nil until the
    /// menu item exists.
    nonisolated(unsafe) static var handoffShortcut: String?

    static func isChat(_ tab: TerminalTab) -> Bool { hosts[tab.id] != nil }

    static func host(for tab: TerminalTab) -> ChatTabHost? { hosts[tab.id] }

    /// The kind glyph the tab strips show at rest: a chat bubble for a chat tab, none for a terminal tab.
    static func glyph(for tab: TerminalTab) -> String? { isChat(tab) ? "bubble.left" : nil }

    /// A restored tab's chat, claimed when that tab starts. `idle` brings it back with Resume instead of running it
    /// (a crash restore, safe mode, or a conversation open elsewhere, which `note` says).
    static func register(_ start: ChatStart, idle: Bool, note: String? = nil, for id: UUID) {
        registered[id] = (start, idle, note)
    }

    /// `TerminalTab.start()`'s hook: true when `tab` is a chat, which its host now runs; no shell starts then.
    static func start(_ tab: TerminalTab) -> Bool {
        let claimed: (start: ChatStart, idle: Bool, note: String?)
        if let spec = registered.removeValue(forKey: tab.id) {
            claimed = spec
        } else if let spec = opening {
            opening = nil
            claimed = (spec, false, nil)
        } else {
            return false
        }
        let host = ChatTabHost(tab: tab, start: claimed.start)
        hosts[tab.id] = host
        observeQuit()
        if claimed.idle { host.showIdle(note: claimed.note) } else { host.begin() }
        return true
    }

    /// `TerminalTab.terminate`'s hook: the chat's agent and its whole group end (KTD7), its report goes.
    static func closed(_ tab: TerminalTab) {
        guard let host = hosts.removeValue(forKey: tab.id) else { return }
        host.close()
        AgentSessionSocket.reports[tab.id] = nil
    }

    /// Opens a chat tab for `start` in `controller`: a new tab (right after `source`'s group when given, else beside the
    /// active one), or a pane split beside `splitBeside`. The tab, or nil when it didn't become a chat.
    @discardableResult
    static func open(_ start: ChatStart, in controller: TerminalWindowController, after source: TerminalTab? = nil,
                     splitBeside: TerminalTab? = nil, select: Bool = true, byAgent: Bool = false) -> TerminalTab? {
        opening = start
        defer { opening = nil }
        let tab: TerminalTab?
        if let beside = splitBeside {
            tab = controller.split(vertical: true, from: beside, directory: start.folder, focus: select, byAgent: byAgent)
        } else {
            tab = controller.addTab(directory: start.folder, select: select, byAgent: byAgent)
        }
        guard let tab, isChat(tab) else { return nil }
        if splitBeside == nil, let source, let from = controller.groups.firstIndex(where: { $0.contains(tab) }),
           let at = controller.groups.firstIndex(where: { $0.contains(source) }), from != at + 1 {
            controller.tabBar(controller.tabBar, didMove: from, to: from > at ? at + 1 : at)
        }
        return tab
    }

    // MARK: the agents' processes (KTD8)

    private static let pidsLock = NSLock()
    nonisolated(unsafe) private static var agentPids: [UUID: pid_t] = [:]

    /// The agent `tab` runs now, or none.
    static func setAgentPid(_ pid: pid_t?, for tab: UUID) {
        pidsLock.lock()
        defer { pidsLock.unlock() }
        agentPids[tab] = pid
    }

    /// The chat tab whose agent is process `pid`, on any thread.
    static func tabID(agentPid pid: pid_t) -> UUID? {
        pidsLock.lock()
        defer { pidsLock.unlock() }
        return agentPids.first { $0.value == pid }?.key
    }

    // MARK: Next Term's quit

    nonisolated(unsafe) private static var quitObserver: NSObjectProtocol?

    /// Ends every chat's agent group when Next Term quits (KTD7), observed here rather than by the app delegate.
    private static func observeQuit() {
        guard quitObserver == nil else { return }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                              queue: .main) { _ in endAll() }
    }

    /// Every chat's input closed at once, then their groups ended together, waited for here: 5 seconds at most.
    static func endAll() {
        let groups = hosts.values.compactMap { $0.closeForQuit() }
        hosts.removeAll()
        guard !groups.isEmpty else { return }
        AgentSessionProcess.endGroups(groups)
    }
}

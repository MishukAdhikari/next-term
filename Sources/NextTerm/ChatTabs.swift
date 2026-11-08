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

    /// A restored tab's chat, claimed by its `start()`.
    private struct Registered {
        var start: ChatStart
        /// Shown with a Resume button, nothing run.
        var idle: Bool
        var note: String?
        var draft: String?
    }

    /// Starts registered by a restored tab's id, claimed by its `start()`.
    nonisolated(unsafe) private static var registered: [UUID: Registered] = [:]

    /// The handoff's key as the user has it (⇧⌘J by default), for the note on a terminal-only command; nil when it has
    /// none.
    static var handoffShortcut: String? {
        KeyboardShortcuts.shared.key(for: #selector(TerminalWindowController.handOffConversation(_:)))?.display
    }

    static func isChat(_ tab: TerminalTab) -> Bool { hosts[tab.id] != nil }

    static func host(for tab: TerminalTab) -> ChatTabHost? { hosts[tab.id] }

    /// The kind mark the tab strips show at rest (plan 037 U5): a chat bubble for a chat tab, none for a terminal tab.
    /// The tab strips ask on every refresh, so a chat tab renamed back to automatic takes its agent's name here too.
    static func glyph(for tab: TerminalTab) -> TabKindGlyph? {
        guard isChat(tab) else { return nil }
        tab.applyChatTitle()
        return .chat
    }

    /// A restored tab's chat, claimed when that tab starts. `idle` brings it back with Resume instead of running it
    /// (a crash restore, safe mode, or a conversation open elsewhere); `note` says why, in the transcript. `draft` goes
    /// back in the input box.
    static func register(_ start: ChatStart, idle: Bool, note: String? = nil, draft: String? = nil, for id: UUID) {
        registered[id] = Registered(start: start, idle: idle, note: note, draft: draft)
    }

    /// `TerminalTab.start()`'s hook: true when `tab` is a chat, which its host now runs; no shell starts then.
    static func start(_ tab: TerminalTab) -> Bool {
        let claimed: Registered
        if let spec = registered.removeValue(forKey: tab.id) {
            claimed = spec
        } else if let spec = opening {
            opening = nil
            claimed = Registered(start: spec, idle: false)
        } else {
            return false
        }
        let host = ChatTabHost(tab: tab, start: claimed.start)
        if let draft = claimed.draft { host.draft = draft }
        hosts[tab.id] = host
        observeQuit()
        // The tab was placed in its pane as a terminal before it started: the pane takes the chat's view instead.
        (tab.view.superview as? PaneView)?.adopt()
        if claimed.idle { host.showIdle(note: claimed.note) } else { host.begin() }
        tab.delegate?.tabDidChange(tab)
        return true
    }

    /// `TerminalTab.terminate`'s hook: true for a chat tab, whose agent and whole group end (KTD7) and whose report goes;
    /// it has no shell to hang up. While Next Term quits, every chat's group ends at once and is waited for here, as the
    /// quit's own observer may come after the tabs are closed.
    @discardableResult
    static func closed(_ tab: TerminalTab) -> Bool {
        registered[tab.id] = nil
        guard let host = hosts[tab.id] else { return false }
        if AppDelegate.shared?.isTerminating == true { endAll() } else { host.close() }
        hosts[tab.id] = nil
        AgentSessionSocket.reports[tab.id] = nil
        return true
    }

    /// Opens a chat tab for `start` in `controller`: a new tab (right after `source`'s group when given, else beside the
    /// active one), or a pane split beside `splitBeside`. The tab, or nil when it didn't become a chat.
    /// `vertical` false splits below `splitBeside` instead of to its right.
    @discardableResult
    static func open(_ start: ChatStart, in controller: TerminalWindowController, after source: TerminalTab? = nil,
                     splitBeside: TerminalTab? = nil, vertical: Bool = true, select: Bool = true, byAgent: Bool = false) -> TerminalTab? {
        opening = start
        defer { opening = nil }
        let tab: TerminalTab?
        if let beside = splitBeside {
            tab = controller.split(vertical: vertical, from: beside, directory: start.folder, focus: select, byAgent: byAgent)
        } else {
            tab = controller.addTab(directory: start.folder, select: select, byAgent: byAgent)
        }
        guard let tab, isChat(tab) else { return nil }
        if splitBeside == nil, let source { place(tab, after: source, in: controller) }
        return tab
    }

    /// Moves `tab`'s tab to just after `source`'s, as a handoff opens the other kind beside its source.
    static func place(_ tab: TerminalTab, after source: TerminalTab, in controller: TerminalWindowController) {
        guard let from = controller.groups.firstIndex(where: { $0.contains(tab) }),
              let at = controller.groups.firstIndex(where: { $0.contains(source) }), from != at + 1, from != at else { return }
        controller.tabBar(controller.tabBar, didMove: from, to: from > at ? at + 1 : at)
    }

    // MARK: the keyboard

    /// What takes the keyboard when something gives it to a chat tab's terminal, which is never shown (plan 037 U6):
    /// the chat's view instead (its card or its input box). Anything else is given as it is. `TerminalWindow` asks,
    /// so every place that hands a tab the keyboard by its terminal reaches the chat.
    static func keyboardTarget(for responder: NSResponder?) -> NSResponder? {
        if let chat = responder as? ChatView { return chat.preferredResponder }
        guard let terminal = responder as? NextTermView, let host = hosts.values.first(where: { $0.tab?.view === terminal }) else {
            return responder
        }
        return host.view.preferredResponder
    }

    /// The chat tab's terminal, for a responder inside a chat's view: the window focuses that pane as it does for a click
    /// in a terminal. Anything else is told as it is.
    static func paneResponder(for responder: NSResponder?) -> NSResponder? {
        guard let view = responder as? NSView, !(view is NextTermView), !hosts.isEmpty,
              let host = hosts.values.first(where: { view.isDescendant(of: $0.view) }), let terminal = host.tab?.view else {
            return responder
        }
        return terminal
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

    /// Every chat's input closed at once, then their groups ended together, waited for here: 5 seconds at most. The hosts
    /// stay, closed, so the quit's save still reads each chat (whichever of the quit's observers runs first), and a
    /// second call ends nothing more.
    static func endAll() {
        let groups = hosts.values.compactMap { $0.closeForQuit() }
        guard !groups.isEmpty else { return }
        AgentSessionProcess.endGroups(groups)
    }
}

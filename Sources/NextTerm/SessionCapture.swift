import AppKit
import NextTermCore

/// The session as the snapshot records it (SessionSnapshot), read from the open windows on the main thread: each window,
/// the one used last first, with its frame, screen, project and tabs in order; each tab's splits, focus and zoom; and
/// each pane's folder, the title the user gave it, its command line, its state, its agent and its server.
///
/// A command line is kept only when the secret check passes on what was typed and on what it expanded to; the expanded
/// line itself is never kept. Only the user's title is kept, never a program's. A pane restored at launch whose action
/// has not run is saved as it was restored (`TerminalTab.restoredRecord`), with only its scrollback this quit's.
@MainActor
enum SessionCapture {
    /// The secret check's verdict on each tab's line, by tab id, while the line stays the same: a periodic save reads it
    /// again every 2 seconds.
    private static var verdicts: [UUID: (typed: String, expanded: String, secret: Bool)] = [:]

    /// Every terminal window. `scrollback` names the scrollback a quit saves for each tab, by tab id.
    static func windows(_ controllers: [TerminalWindowController], scrollback: [UUID: UUID] = [:]) -> [SessionSnapshot.Window] {
        let numbered: [(offset: Int, element: TerminalWindowController)] = Array(controllers.enumerated())
        let ordered = numbered.sorted { (a: (offset: Int, element: TerminalWindowController),
                                         b: (offset: Int, element: TerminalWindowController)) -> Bool in
            a.element.lastKey != b.element.lastKey ? a.element.lastKey > b.element.lastKey : a.offset < b.offset
        }
        let windows = ordered.map { (entry: (offset: Int, element: TerminalWindowController)) -> SessionSnapshot.Window in
            window(entry.element, scrollback: scrollback)
        }
        let open = Set(controllers.flatMap(\.tabs).map(\.id))
        verdicts = verdicts.filter { (entry: (key: UUID, value: (typed: String, expanded: String, secret: Bool))) -> Bool in
            open.contains(entry.key)
        }
        return windows
    }

    static func window(_ controller: TerminalWindowController, scrollback: [UUID: UUID]) -> SessionSnapshot.Window {
        let project = controller.project
        let groups: [SessionSnapshot.Group] = controller.groups.map { (group: PaneGroup) -> SessionSnapshot.Group in
            SessionSnapshot.Group(root: node(group.root, project: project, scrollback: scrollback), focused: group.focused.id,
                                  zoomed: group.zoomed?.id)
        }
        var window = SessionSnapshot.Window(project: project, groups: groups, selected: controller.activeIndex)
        if let shown = controller.window {
            let frame = shown.frame
            window.frame = SessionSnapshot.Frame(x: Double(frame.origin.x), y: Double(frame.origin.y), width: Double(frame.width),
                                                 height: Double(frame.height))
            window.screen = shown.screen?.localizedName
            window.minimized = shown.isMiniaturized
            window.fullScreen = shown.styleMask.contains(.fullScreen)
        }
        return window
    }

    static func node(_ node: PaneGroup.Node, project: String?, scrollback: [UUID: UUID]) -> SessionSnapshot.Node {
        switch node {
        case .pane(let tab):
            return .pane(pane(tab, project: project, scrollback: scrollback[tab.id]))
        case .split(let split):
            let children: [SessionSnapshot.Node] = split.children.map { (child: PaneGroup.Node) -> SessionSnapshot.Node in
                self.node(child, project: project, scrollback: scrollback)
            }
            let dividers: [Double] = split.dividers.map { (divider: CGFloat) -> Double in Double(divider) }
            return .split(SessionSnapshot.Split(vertical: split.vertical, children: children, dividers: dividers))
        }
    }

    /// A pane's record. On a server: RemoteConnection's record of it, a plain connection when tmux or herdr fell back.
    /// Here: its folder, its shell, and the agent it runs, read now (ProcessInspector.agentEvidence).
    static func pane(_ tab: TerminalTab, project: String?, scrollback: UUID?) -> SessionSnapshot.Pane {
        if var restored = tab.restoredRecord, restored.pending?.state == .pending {
            restored.scrollback = scrollback
            return restored
        }
        let status = tab.status
        var pane = SessionSnapshot.Pane(id: tab.id, userTitle: tab.userTitle, command: command(tab), stateBefore: state(tab),
                                        interrupted: interrupted(tab), lastSelected: tab.lastSelected, scrollback: scrollback)
        if let remote = tab.remote {
            let keep: KeepMode = tab.fellBack ? .off : remote.keep
            pane.remote = RemoteTabRecord(hostID: remote.host.id, destination: remote.host.destination, port: remote.host.port,
                                          directory: keep == .tmux ? remote.directory : tab.directory, session: remote.session,
                                          keep: keep, project: project, title: tab.userTitle)
        } else {
            pane.folder = tab.liveDirectory
            pane.systemZsh = tab.shellPath == "/bin/zsh"
            if status.running && !tab.exited {
                pane.agent = ProcessInspector.agentEvidence(ptyFileDescriptor: tab.view.process.childfd,
                                                            shellPid: tab.view.process.shellPid, status: status,
                                                            home: RestorePlanning.agentHome, shownSession: tab.shownSessionID)
            }
        }
        return pane
    }

    /// The tab's line, typed, with the secret check's verdict on it and on its expanded form (R11).
    static func command(_ tab: TerminalTab) -> SessionSnapshot.Command? {
        let status = tab.status
        guard !status.command.isEmpty else { return nil }
        let typed = status.command, expanded = status.expandedCommand
        let secret: Bool
        if let known = verdicts[tab.id], known.typed == typed, known.expanded == expanded {
            secret = known.secret
        } else {
            secret = ScrollbackText.holdsSecret(typed: typed, expanded: expanded.isEmpty ? nil : expanded)
            verdicts[tab.id] = (typed, expanded, secret)
        }
        return SessionSnapshot.Command(status: status, check: secret ? .secret : .kept)
    }

    /// The tab's state as MCP's `list_tabs` reports it.
    static func state(_ tab: TerminalTab) -> SessionSnapshot.PriorState {
        if tab.exited { return .exited }
        if tab.disconnected { return .disconnected }
        if tab.remote != nil && !tab.remoteConnected { return .connecting }
        let state = tab.status.state
        if state == .idle && tab.status.running && tab.status.kind != .agent { return .running }
        return SessionSnapshot.PriorState(rawValue: state.rawValue) ?? .unknown
    }

    /// Whether quitting cuts its work off: a command still running, or an agent mid-turn or waiting on a question. Work
    /// that tmux or herdr keeps on a server goes on there.
    static func interrupted(_ tab: TerminalTab) -> Bool {
        let status = tab.status
        guard status.running, !tab.exited, !tab.isKept else { return false }
        guard status.kind == .agent else { return true }
        return status.state == .working || status.state == .attention
    }
}

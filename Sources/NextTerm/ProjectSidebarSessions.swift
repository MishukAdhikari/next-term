import AppKit
import NextTermCore

/// The Agent Sessions rows' cells, menus (right-click and ⋯) and what their items do.
extension ProjectSidebarView {
    func sessionCell(for item: Any) -> NSView {
        let id = NSUserInterfaceItemIdentifier("session")
        let cell = outline.makeView(withIdentifier: id, owner: self) as? SessionRowCellView ?? SessionRowCellView()
        cell.identifier = id
        if let session = item as? SessionItem {
            cell.configure(session)
            cell.onMenu = { [weak self, weak session] in
                guard let self, let session else { return NSMenu() }
                return self.sessionMenu(for: session)
            }
        } else if item is SessionsGroup {
            cell.configureGroup(sessionsGroup)
            cell.onMenu = { [weak self] in self?.sessionsGroupMenu() ?? NSMenu() }
        } else {
            cell.configureMore(sessionsGroup)
            cell.onMenu = nil
        }
        return cell
    }

    /// The right-click menu of an Agent Sessions row, nil for any other row.
    func sessionsMenu(forRow row: Int) -> NSMenu? {
        let item = row >= 0 ? outline.item(atRow: row) : nil
        if let session = item as? SessionItem { return sessionMenu(for: session) }
        if item is SessionsGroup || item is MoreSessionsItem { return sessionsGroupMenu() }
        return nil
    }

    /// Resume (Go to Tab when a tab has it open; Open's ⌘↓), Fork where the agent can, Copy Resume Command.
    func sessionMenu(for item: SessionItem) -> NSMenu {
        let menu = NSMenu(title: "Session")
        let session = item.session
        add(to: menu, item.inTab ? "Go to Tab" : "Resume", #selector(resumeSessionFromMenu(_:)), session, "sidebar.open")
        if session.agent.canFork { add(to: menu, "Fork", #selector(forkSessionFromMenu(_:)), session, "sidebar.forkSession") }
        menu.addItem(.separator())
        add(to: menu, "Copy Resume Command", #selector(copyResumeCommand(_:)), session, "sidebar.copyResumeCommand")
        return menu
    }

    /// Continue Latest for each agent that has a session in this folder, the whole list (File › Resume Agent Session…,
    /// with its key), Refresh. Continue Latest Session's key is the first agent's: one key can do one of them.
    func sessionsGroupMenu() -> NSMenu {
        let menu = NSMenu(title: "Agent Sessions")
        if let root {
            for agent in sessionsGroup.agents(in: root.path) {
                let command = menu.items.isEmpty ? "sidebar.continueLatest" : nil
                let item = add(to: menu, "Continue Latest \(agent.name) Session", #selector(continueLatestFromMenu(_:)), nil, command)
                item.representedObject = agent.rawValue
                item.toolTip = agent.continueCommand
            }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        add(to: menu, "Show All Sessions…", #selector(showAllSessionsFromMenu(_:)), nil, "resumeSession:")
        add(to: menu, "Refresh Sessions", #selector(refreshSessionsFromMenu(_:)), nil, "sidebar.refresh")
        return menu
    }

    /// An item, as `command` with its key (KeyboardShortcuts.show), or with none.
    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ action: Selector, _ session: AgentSession?, _ command: String?) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        if let session { item.representedObject = SessionBox(session) }
        if let command { KeyboardShortcuts.show(command, on: item) }
        return item
    }

    private func session(of sender: Any?) -> AgentSession? { ((sender as? NSMenuItem)?.representedObject as? SessionBox)?.session }

    @objc func resumeSessionFromMenu(_ sender: Any?) {
        if let session = session(of: sender) { delegate?.sidebar(self, session: session, perform: .resume) }
    }

    @objc func forkSessionFromMenu(_ sender: Any?) {
        if let session = session(of: sender) { delegate?.sidebar(self, session: session, perform: .fork) }
    }

    @objc func copyResumeCommand(_ sender: Any?) {
        guard let session = session(of: sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.resumeCommand(), forType: .string)
    }

    @objc func continueLatestFromMenu(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let agent = AgentKind(rawValue: raw) else { return }
        delegate?.sidebar(self, session: nil, perform: .continueLatest(agent))
    }

    @objc func showAllSessionsFromMenu(_ sender: Any?) { delegate?.sidebar(self, session: nil, perform: .showAll) }
    @objc func refreshSessionsFromMenu(_ sender: Any?) { loadSessions() }
}

/// A session in a menu item's `representedObject` (which takes an object).
final class SessionBox {
    let session: AgentSession
    init(_ session: AgentSession) { self.session = session }
}

/// Agent Sessions in the sidebar: the actions, and reading them again when the agents in tabs change.
extension TerminalWindowController {
    func sidebar(_ sidebar: ProjectSidebarView, session: AgentSession?, perform action: SessionAction) {
        let folder = sidebar.root?.path ?? project ?? searchRoot
        switch action {
        case .resume, .fork:
            guard let session else { return }
            let fork = action == .fork
            if !fork, let open = sidebar.sessionsGroup.tabs.tab(of: session) { return AppDelegate.shared.goTo(open.tab, in: open.controller) }
            let directory = FileManager.default.fileExists(atPath: session.cwd) ? session.cwd : folder
            runInNewTab(directory: directory, command: SessionStore.commandPrefix + session.resumeCommand(fork: fork), title: nil)
        case .continueLatest(let agent):
            runInNewTab(directory: folder, command: SessionStore.commandPrefix + agent.continueCommand, title: nil)
        case .showAll:
            resumeSession(nil)
        }
    }

    /// Called with every refresh: notes when each agent in a tab started (by the wall clock, while it is
    /// fresh), and when an agent starts or stops in any tab the sidebar reads its sessions again (a new
    /// session, a "running" badge that comes or goes). New titles wait for the window to come to the front:
    /// a read after every turn would read every agent's store each time.
    func noteAgentTabs() {
        guard let app = AppDelegate.shared else { return }
        var marks: [String] = []
        var agents = Set<String>()
        for tab in app.controllers.flatMap(\.tabs) where tab.status.running && tab.status.kind == .agent {
            if let since = tab.status.runningSince { _ = SessionStore.startDate(of: tab, since: since) }
            agents.insert(tab.id.uuidString)
            marks.append(tab.id.uuidString + "\(tab.status.runningSince ?? 0)")
        }
        SessionStore.agentStarts.forget(allBut: agents)
        let signature = marks.joined(separator: ",")
        guard signature != sidebar.sessionsGroup.agentTabs else { return }
        sidebar.sessionsGroup.agentTabs = signature
        sidebar.scheduleSessionsReload()
    }
}

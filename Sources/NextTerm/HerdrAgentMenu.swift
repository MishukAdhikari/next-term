import AppKit
import NextTermCore

/// Getting to an agent: Window › Go to Agent… (⌃⌘A), an agent's row in the tab list, and its notice. herdr's agents
/// and Next Term's own agent tabs are one queue (AgentQueue), so the user never has to know which kind waits. Choosing
/// one of herdr's agents brings the tab that shows herdr forward and asks herdr to show that agent's pane (`agent
/// focus`, through HerdrRunner); the user chose it, so nothing asks. Built from what the last checks left: nothing runs
/// to make it.
enum HerdrAgentMenu {
    /// Some window has an agent to go to.
    static var hasAgents: Bool { !queue().isEmpty }

    /// Every agent in every window, as the queue orders them: herdr's agents of each tab that follows herdr, in herdr's
    /// order, and each tab whose program is an agent, in tab order.
    static func queue() -> AgentQueue {
        var items: [AgentQueue.Item] = []
        for tab in AppDelegate.shared.controllers.flatMap(\.tabs) where !tab.exited {
            if tab.followsHerdr {
                items += herdrItems(tab)
            } else if let item = tabItem(tab) {
                items.append(item)
            }
        }
        return AgentQueue(items)
    }

    /// The agents of a tab that follows herdr, under its host and herdr session.
    private static func herdrItems(_ tab: TerminalTab) -> [AgentQueue.Item] {
        let tracker = tab.herdrTracker
        let group = heading(tab)
        return tab.herdrRows.map { row -> AgentQueue.Item in
            let question = tracker.question(row.pane)
            let name = row.disambiguation.map { "\(row.name) (\($0))" } ?? row.name
            return AgentQueue.Item(target: .herdr(tab: tab.id.uuidString, pane: row.pane), key: "herdr \(tab.herdrPlace)\u{0}\(row.pane)",
                                   name: name, group: group, state: row.state, words: row.words, needsSince: row.needsSince,
                                   workSince: row.workSince, onScreen: tracker.isOnScreen(row.pane), question: question?.text,
                                   choices: question?.choices ?? [], tooltip: row.tooltip(now: TerminalTab.now))
        }
    }

    /// A tab whose program is an agent (not herdr, whose agents are their own items), under This Mac or its host.
    private static func tabItem(_ tab: TerminalTab) -> AgentQueue.Item? {
        let status = tab.status
        guard status.running, status.kind == .agent, status.program != "herdr", tab.remote?.keep != .herdr else { return nil }
        let controller = MCPControl.controller(of: tab)
        let name = TerminalWindowController.agentName(of: tab)
        let words = tab.ownStateDescription ?? (status.state == .working ? "Working" : "Idle")
        return AgentQueue.Item(target: .tab(tab.id.uuidString), key: "tab \(tab.id.uuidString)", name: name.isEmpty ? tab.title : name,
                               group: tab.remote?.host.name ?? AgentQueue.thisMac, state: status.state, words: words,
                               needsSince: tab.needsSince, onScreen: controller?.isOnScreen(tab) ?? false, question: status.question,
                               tooltip: tab.tooltip)
    }

    /// "web-1", or "web-1 — review" for a named herdr session.
    private static func heading(_ tab: TerminalTab) -> String {
        let session = tab.herdrSessionName.map { " — \($0)" } ?? ""
        return (tab.remote?.host.name ?? AgentQueue.thisMac) + session
    }

    /// The tab an item's target names, if it is still open.
    static func tab(_ id: String) -> TerminalTab? {
        AppDelegate.shared.controllers.flatMap(\.tabs).first { $0.id.uuidString == id && !$0.exited }
    }

    /// Goes to the item: for one of herdr's agents, as `show(tab:pane:)`; for an agent tab, its tab comes forward.
    static func go(to target: AgentQueue.Item.Target) {
        switch target {
        case let .herdr(id, pane):
            guard let tab = tab(id) else { return NSSound.beep() }
            show(tab: tab, pane: pane)
        case .tab(let id):
            guard let tab = tab(id), let controller = MCPControl.controller(of: tab) else { return NSSound.beep() }
            controller.window?.makeKeyAndOrderFront(nil)
            controller.show(tab)
        }
    }

    /// The agent Go to Next Agent Needing You went to last, so pressing it again moves on.
    private static var lastNext: String?

    /// Go to Next Agent Needing You (⌃⌘N), and the Dock menu's items: the next agent that needs the user after the one it
    /// went to last; a beep when none does.
    static func goToNext() {
        guard let item = queue().next(after: lastNext) else {
            lastNext = nil
            return NSSound.beep()
        }
        lastNext = item.key
        NSApp.activate(ignoringOtherApps: true)
        go(to: item.target)
    }

    /// The Dock menu's agents: what needs the user, in Go to Agent's order, 8 at most ("codex — web-1 — Needs your
    /// decision"), each going where choosing it in Go to Agent would.
    static func dockItems() -> [NSMenuItem] {
        let mask = SecretMask.current
        return queue().dockItems().map { item in
            let entry = NSMenuItem(title: mask.mask(item.dockTitle), action: #selector(Target.chooseFromDock(_:)), keyEquivalent: "")
            entry.target = Target.shared
            entry.representedObject = Choice(item.target, key: item.key)
            entry.image = StatusGlyph.image(for: item.state)
            return entry
        }
    }

    /// Brings `tab` forward in its window and moves herdr's view there to `pane`; Next Term's unread flag for it clears.
    /// What herdr could not do is said in the tab, in a line over its top; herdr's own screen is never written to.
    static func show(tab: TerminalTab, pane: String) {
        guard let controller = MCPControl.controller(of: tab) else { return }
        controller.window?.makeKeyAndOrderFront(nil)
        controller.show(tab)
        tab.herdrSeen(pane)
        HerdrRunner.focus(pane, in: tab) { result in
            switch result {
            case .json, .text:
                break
            case .unsupported:
                tab.view.showNote("This herdr cannot move its view to an agent: herdr 0.7.5 and later can.")
            case .error(_, let message):
                tab.view.showNote("herdr: \(message)")
            case .unreachable(let why):
                tab.view.showNote(why)
            case .cut:
                tab.view.showNote("herdr did not answer in time.")
            }
        }
    }

    /// One item in a menu: what choosing it goes to.
    private final class Choice: NSObject {
        let target: AgentQueue.Item.Target
        let key: String?

        init(_ target: AgentQueue.Item.Target, key: String? = nil) {
            self.target = target
            self.key = key
        }
    }

    /// ⌃⌘A's menu: Needs You first (a decision, then a finish not seen, oldest first), then every other agent under a
    /// heading for its place ("This Mac", "web-1", "web-1 — review"). Each item starts with the agent's name, so typing it
    /// selects it, and the first nine take 1-9. A menu does not change while it is open.
    static func menu() -> NSMenu {
        let menu = NSMenu(title: "Go to Agent")
        menu.autoenablesItems = false
        let now = TerminalTab.now
        var shown = 0
        for section in queue().sections {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            let header = menu.addItem(withTitle: section.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            for item in section.items {
                let mask = SecretMask.current
                let digit = AgentQueue.digit(shown) ?? ""
                shown += 1
                let entry = NSMenuItem(title: mask.mask(item.menuTitle(now: now)), action: #selector(Target.choose(_:)), keyEquivalent: digit)
                entry.keyEquivalentModifierMask = []
                entry.target = Target.shared
                entry.representedObject = Choice(item.target)
                entry.indentationLevel = 1
                entry.toolTip = mask.mask(item.tooltip)
                entry.image = StatusGlyph.image(for: item.state)
                menu.addItem(entry)
            }
        }
        return menu
    }

    /// ⌃⌘A: the menu over the window's terminal, the first agent selected for Return (the first that needs you, when one
    /// does).
    static func popUp(in controller: TerminalWindowController) {
        let menu = menu()
        let first = menu.items.first { $0.representedObject is Choice }
        let shown: NSView? = controller.activeTab?.view ?? controller.window?.contentView
        guard let first, let view = shown else { return NSSound.beep() }
        let point = NSPoint(x: view.bounds.midX - 120, y: view.bounds.midY + 80)
        menu.popUp(positioning: first, at: point, in: view)
    }

    /// An agent's row's right-click menu: Show in herdr, Keep as Unread, Mute Notices, then its pane id and folder.
    static func rowMenu(tab: TerminalTab, pane: String) -> NSMenu {
        let menu = NSMenu(title: "herdr Agent")
        menu.autoenablesItems = false
        let row = tab.herdrRows.first { $0.pane == pane }
        func add(_ title: String, _ action: Selector, _ object: Any?, on: Bool = false, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = Target.shared
            item.representedObject = object
            item.state = on ? .on : .off
            item.isEnabled = enabled
            menu.addItem(item)
        }
        let agent = AgentChoice(tab: tab, pane: pane)
        add("Show in herdr", #selector(Target.show(_:)), agent)
        menu.addItem(.separator())
        // Next Term's own flag: herdr's state stays as it is. Not for an agent at work or waiting on a decision.
        let unread = tab.herdrTracker.isUnread(pane)
        let keepable = row.map { $0.status != .working && $0.status != .blocked } ?? false
        add("Keep as Unread", #selector(Target.keepUnread(_:)), agent, on: unread, enabled: unread || keepable)
        add("Mute Notices", #selector(Target.mute(_:)), agent, on: tab.herdrTracker.isMuted(pane))
        menu.addItem(.separator())
        add("Copy Pane ID", #selector(Target.copy(_:)), pane)
        add("Copy Folder", #selector(Target.copy(_:)), row?.directory, enabled: row?.directory != nil)
        return menu
    }

    /// One of herdr's agents in a row's menu: its tab, held weakly, and herdr's pane id.
    private final class AgentChoice: NSObject {
        weak var tab: TerminalTab?
        let pane: String

        init(tab: TerminalTab, pane: String) {
            self.tab = tab
            self.pane = pane
        }
    }

    /// The menus' items' target: one object for the app's life.
    final class Target: NSObject {
        static let shared = Target()

        @objc func choose(_ sender: NSMenuItem) {
            guard let choice = sender.representedObject as? Choice else { return NSSound.beep() }
            HerdrAgentMenu.go(to: choice.target)
        }

        /// A Dock menu item: Next Term comes forward, and ⌃⌘N goes on from there.
        @objc func chooseFromDock(_ sender: NSMenuItem) {
            guard let choice = sender.representedObject as? Choice else { return NSSound.beep() }
            HerdrAgentMenu.lastNext = choice.key
            NSApp.activate(ignoringOtherApps: true)
            HerdrAgentMenu.go(to: choice.target)
        }

        @objc func show(_ sender: NSMenuItem) {
            guard let choice = sender.representedObject as? AgentChoice, let tab = choice.tab, !tab.exited else { return NSSound.beep() }
            HerdrAgentMenu.show(tab: tab, pane: choice.pane)
        }

        @objc func keepUnread(_ sender: NSMenuItem) {
            guard let choice = sender.representedObject as? AgentChoice, let tab = choice.tab else { return }
            tab.keepHerdrUnread(choice.pane, sender.state != .on)
        }

        @objc func mute(_ sender: NSMenuItem) {
            guard let choice = sender.representedObject as? AgentChoice, let tab = choice.tab else { return }
            tab.muteHerdr(choice.pane, sender.state != .on)
        }

        @objc func copy(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

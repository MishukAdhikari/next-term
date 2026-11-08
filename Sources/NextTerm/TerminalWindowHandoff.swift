import AppKit
import NextTermCore

/// Continue in Chat and Open in Terminal in a window (plan 037 U8, R17): ⇧⌘J and the Agents item act on the tab (or
/// pane) with the keyboard; the chat's own Open in Terminal (its header, its end card, a note's link) acts on that chat;
/// the tab's right-click menu acts on that tab's pane with the keyboard, in front or not. All of them run HandoffRunner,
/// which says in the tab why a handoff is refused.
extension TerminalWindowController {
    /// ⇧⌘J, Agents › Continue in Chat or Open in Terminal, and a chat's Open in Terminal.
    @objc func handOffConversation(_ sender: Any?) {
        guard let tab = handoffTab(sender), HandoffRunner.offer(for: tab) != nil else { return NSSound.beep() }
        HandoffRunner.start(tab: tab)
    }

    /// The tab a handoff acts on: the chat whose view sent it, else the pane with the keyboard.
    private func handoffTab(_ sender: Any?) -> TerminalTab? {
        if let view = sender as? NSView,
           let host = ChatTabs.hosts.values.first(where: { view.isDescendant(of: $0.view) }), let tab = host.tab {
            return tab
        }
        return activeTab
    }

    /// The right-click menu of tab `group`: its pane with the keyboard.
    func handOff(_ group: PaneGroup) {
        let tab = group.focused
        guard HandoffRunner.offer(for: tab) != nil else { return }
        HandoffRunner.start(tab: tab)
    }

    /// The Agents item: titled for the tab with the keyboard ("Continue in Chat" in front of a terminal tab running Claude
    /// Code or Codex, "Open in Terminal" in front of their chat tab), and off where neither is offered or one runs
    /// already. A tab that offers a handoff but would refuse it keeps the item on: its use says why in the tab.
    func validateHandoff(_ item: NSMenuItem) -> Bool {
        let offer: ConversationHandoff.Offer? = activeTab.flatMap { HandoffRunner.offer(for: $0) }
        let title = offer?.title ?? Self.handoffMenuTitle
        if item.title != title { item.title = title }
        guard let offer else { return false }
        return !offer.handingOff
    }

    /// The item's name when no tab offers a handoff, as the menu is built with it.
    static let handoffMenuTitle = "Continue in Chat"

    /// The tab's right-click menu's item, after Rename…, while its pane with the keyboard offers a handoff.
    func addHandoff(to menu: NSMenu, for group: PaneGroup) {
        guard let offer = HandoffRunner.offer(for: group.focused) else { return }
        menu.addCommand(offer.title, "handOffConversation:", enabled: !offer.handingOff) { [weak self, weak group] in
            guard let self, let group else { return }
            self.handOff(group)
        }
    }
}

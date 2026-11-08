import AppKit
import NextTermCore

/// A chat tab is a `TerminalTab` with a host (plan 037 KTD9): these are what the rest of the window asks of it. Its
/// `NextTermView` exists but is never shown, and no shell ever starts in it.
extension TerminalTab {
    /// The tab hosts a chat.
    var isChat: Bool { ChatTabs.isChat(self) }

    /// The chat's host, or nil for a terminal tab.
    var chatHost: ChatTabHost? { ChatTabs.host(for: self) }

    /// What its pane shows and gives the keyboard to: the chat's view, or the terminal.
    var contentView: NSView { chatHost?.view ?? view }

    /// Whether the tab holds `window`'s keyboard: its terminal, or anything in its chat's view.
    func holdsKeyboard(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window.firstResponder === view { return true }
        return chatHost?.view.hasKeyboard ?? false
    }

    /// A chat tab's automatic name is its agent's ("Claude Code"), never the session program's: a tab renamed back to
    /// automatic gets its agent's name again. Nothing for a terminal tab.
    func applyChatTitle() {
        guard let host = chatHost, userTitle?.isEmpty != false else { return }
        userTitle = host.automaticTitle
    }
}

import AppKit
import NextTermCore

/// The strip above an agent's terminal while it has a live chat (plan 041 D6): a terminal button and a chat button at
/// its right end, the one showing marked. It takes its own 22 points, so it never covers the agent's text.
final class LiveChatStrip: NSView {
    static let height: CGFloat = 22
    let terminalButton = LiveChatStrip.button("terminal", help: "Show the agent's own terminal screen")
    let chatButton = LiveChatStrip.button("bubble.left.and.text.bubble.right", help: "Show this session as a chat (\u{21E7}\u{2318}J)")
    /// A click: true for the chat, false for the terminal.
    var onPick: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        terminalButton.setAccessibilityLabel("Terminal view")
        chatButton.setAccessibilityLabel("Chat view")
        terminalButton.target = self
        terminalButton.action = #selector(pickTerminal)
        chatButton.target = self
        chatButton.action = #selector(pickChat)
        let pair = NSStackView(views: [terminalButton, chatButton])
        pair.orientation = .horizontal
        pair.spacing = 2
        pair.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pair)
        NSLayoutConstraint.activate([
            pair.trailingAnchor.constraint(equalTo: trailingAnchor),
            pair.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        showing(chat: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func button(_ symbol: String, help: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryChange)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        button.imagePosition = .imageOnly
        button.toolTip = help
        button.refusesFirstResponder = true
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 18),
        ])
        return button
    }

    /// Marks the view that shows: its button tinted with a quiet backdrop, the other dim.
    func showing(chat: Bool) {
        for (button, on) in [(terminalButton, !chat), (chatButton, chat)] {
            button.contentTintColor = on ? Theme.accent : Theme.textDim
            button.layer?.backgroundColor = on ? Theme.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
            button.setAccessibilityValue(on ? "selected" : "")
        }
        isShowingChat = chat
    }

    private(set) var isShowingChat = false

    @objc private func pickTerminal() { onPick?(false) }
    @objc private func pickChat() { onPick?(true) }
}

extension LiveChatView {
    static let settingKey = "liveChatView"

    /// Settings › Agents › "Chat view for agent tabs" (plan 041 D7), on unless turned off.
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }
}

extension TerminalWindowController {
    /// The pane of the tab with the keyboard.
    var activeChatPane: PaneView? {
        guard let tab = activeTab, let group = groups.first(where: { $0.contains(tab) }) else { return nil }
        return group.paneView(tab)
    }

    /// View › Show as Chat (⇧⌘J): the tab with the keyboard shows its agent's session as a chat, or its terminal again.
    @objc func toggleLiveChat(_ sender: Any?) {
        guard let pane = activeChatPane, LiveChatView.isOn, LiveChatWatch.offers(pane.tab) else { return NSSound.beep() }
        pane.setChat(shown: !pane.showsChat)
    }

    /// Whether the active tab can show a live chat, and whether it does.
    func liveChatState() -> (offered: Bool, shown: Bool) {
        guard let pane = activeChatPane else { return (false, false) }
        return (LiveChatView.isOn && LiveChatWatch.offers(pane.tab), pane.showsChat)
    }

    /// Settings turned the chat view off: every pane goes back to its terminal and loses its strip.
    func liveChatSettingChanged() {
        refreshPaneHeaders()
    }
}

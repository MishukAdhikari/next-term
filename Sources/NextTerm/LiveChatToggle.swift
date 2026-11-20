import AppKit
import NextTermCore

/// The terminal and chat buttons of an agent tab with a live chat (plan 041 D6): a small floating control in the pane's
/// top-right corner, over the terminal and over the chat, so neither gives up a row for it. Two borderless symbols on
/// the system's translucent material, inset from the corner, the one showing marked. Over the chat it always shows;
/// over the terminal it never sits on the agent's own text: it fades in while the pointer is in the pane's top-right
/// corner (`hoverRegion`) and out when it leaves. VoiceOver reaches it either way, and ⇧⌘J and View › Show as Chat
/// switch without it.
final class LiveChatStrip: NSView {
    /// The control's size, and its inset from the pane's top-right corner.
    static let size = NSSize(width: 52, height: 22)
    static let inset: CGFloat = 6
    /// Kept clear at the right for the terminal's and the transcript's scroller.
    static let scrollerRoom: CGFloat = 6
    /// Over the terminal, the corner whose hover shows the control.
    static let hoverRegion = NSSize(width: 120, height: 44)
    private static let fade: TimeInterval = 0.15
    let terminalButton = LiveChatStrip.button("terminal", help: "Show the agent's own terminal screen")
    let chatButton = LiveChatStrip.button("bubble.left.and.text.bubble.right", help: "Show this session as a chat")
    private let material = NSVisualEffectView()
    /// A click: true for the chat, false for the terminal.
    var onPick: ((Bool) -> Void)?

    /// The terminal button's tip: an agent session (plan 047, D4) has no screen of its agent's own, only Next Term's
    /// text view of it.
    func describe(sessionAgent: String?) {
        let tip = sessionAgent.map { "This session runs without \($0)\u{2019}s own screen. Terminal shows Next Term\u{2019}s text view of it." }
            ?? "Show the agent's own terminal screen"
        if terminalButton.toolTip != tip { terminalButton.toolTip = tip }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material.material = .menu
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 6
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 0.5
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)
        terminalButton.setAccessibilityLabel("Terminal view")
        chatButton.setAccessibilityLabel("Chat view")
        terminalButton.target = self
        terminalButton.action = #selector(pickTerminal)
        chatButton.target = self
        chatButton.action = #selector(pickChat)
        let pair = NSStackView(views: [terminalButton, chatButton])
        pair.orientation = .horizontal
        pair.spacing = 0
        pair.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(pair)
        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: topAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            pair.centerXAnchor.constraint(equalTo: material.centerXAnchor),
            pair.centerYAnchor.constraint(equalTo: material.centerYAnchor),
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Terminal or chat")
        showing(chat: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        showing(chat: isShowingChat)
    }

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
            button.widthAnchor.constraint(equalToConstant: 24),
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
        let changed = isShowingChat != chat
        isShowingChat = chat
        reveal(animated: changed && !chat)
        // A hairline that holds the control's edge on any background; stronger with Increase Contrast.
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            material.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(contrast ? 1 : 0.6).cgColor
        }
    }

    private(set) var isShowingChat = false
    /// Whether the pointer is in the pane's top-right corner (the pane's tracking area reports it here).
    private(set) var isPointerNear = false

    /// Whether the control is meant to be seen: always over the chat, over the terminal only with the pointer near.
    var isRevealed: Bool { isShowingChat || isPointerNear }

    /// The pointer came into the pane's corner, or left it.
    func pointerNear(_ near: Bool) {
        guard near != isPointerNear else { return }
        isPointerNear = near
        reveal(animated: true)
    }

    override func mouseEntered(with event: NSEvent) { pointerNear(true) }
    override func mouseExited(with event: NSEvent) { pointerNear(false) }

    /// Fades to what `isRevealed` says; at once with Reduce Motion.
    private func reveal(animated: Bool) {
        let alpha: CGFloat = isRevealed ? 1 : 0
        guard alphaValue != alpha else { return }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, window != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fade
                animator().alphaValue = alpha
            }
        } else {
            alphaValue = alpha
        }
    }

    /// Faded out, clicks go through to the terminal under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue < 0.01 ? nil : super.hitTest(point)
    }

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

    static let tokenUsageKey = "chatTokenUsage"

    /// Settings › Agents › "Show token usage in chat": one quiet line under the composer. On unless turned off.
    static var showsTokenUsage: Bool {
        get { UserDefaults.standard.object(forKey: tokenUsageKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: tokenUsageKey) }
    }

    /// The catalog id of `tab`'s agent: a session's own (plan 047), or the live chat's (plan 041).
    static func agentID(of tab: TerminalTab) -> String? {
        if let id = AgentSessionSocket.reports[tab.id]?.agentID { return id }
        return tab.localAgent.flatMap(LiveChat.Agent.init).map(ChatFirst.id(of:))
    }

    /// Settings › Agents › the agent's "Opens as": whether a new session of `tab`'s agent shows its chat first.
    static func opensAsChat(_ tab: TerminalTab) -> Bool {
        agentID(of: tab).map { ChatFirst.opensAsChat($0) } ?? false
    }
}

extension TerminalWindowController {
    /// The pane of the tab with the keyboard.
    var activeChatPane: PaneView? {
        guard let tab = activeTab, let group = groups.first(where: { $0.contains(tab) }) else { return nil }
        return group.paneView(tab)
    }

    /// View › Show as Chat (⇧⌘J, or the key the user gives it in Keyboard Shortcuts): the tab with the keyboard shows its agent's session as a chat, or its terminal again.
    @objc func toggleLiveChat(_ sender: Any?) {
        guard let pane = activeChatPane, LiveChatView.isOn, LiveChatView.offers(pane.tab) else { return NSSound.beep() }
        pane.setChat(shown: !pane.showsChat)
    }

    /// Whether the active tab can show a live chat, and whether it does.
    func liveChatState() -> (offered: Bool, shown: Bool) {
        guard let pane = activeChatPane else { return (false, false) }
        return (LiveChatView.isOn && LiveChatView.offers(pane.tab), pane.showsChat)
    }

    /// Settings turned the chat view off: every pane goes back to its terminal and loses its buttons.
    func liveChatSettingChanged() {
        refreshPaneHeaders()
    }
}

import AppKit
import NextTermCore

/// Settings › Editor's "Open Claude Code in" and "Open Codex in" (plan 037 R18, from plan 036): Terminal or Chat, for the
/// starts Next Term makes itself. Each is a popup bound to AgentOpenView's key for its agent.
enum AgentOpenViewControls {
    /// "Open Claude Code in: [Terminal]", as one row's views.
    static func control(_ agent: ConversationHandoff.Agent) -> NSView {
        let popup = AgentOpenViewPopup(agent)
        let label = NSTextField(labelWithString: "Open " + agent.name + " in:")
        let stack = NSStackView(views: [label, popup])
        stack.spacing = 8
        return stack
    }
}

/// One agent's popup: it reads the setting each time it is shown, so a change made elsewhere shows.
private final class AgentOpenViewPopup: NSPopUpButton {
    private let agent: ConversationHandoff.Agent

    init(_ agent: ConversationHandoff.Agent) {
        self.agent = agent
        super.init(frame: .zero, pullsDown: false)
        for kind in ConversationHandoff.Kind.allCases {
            addItem(withTitle: kind.title)
            lastItem?.representedObject = kind.rawValue
        }
        target = self
        action = #selector(changed)
        let starts = "a new tab an agent asks for with \(agent.rawValue) alone, the Welcome window\u{2019}s Set up with your agent, and Resume in Agent Sessions"
        toolTip = "Where \(agent.name) opens when Next Term starts it: \(starts). Terminal is \(agent.name)\u{2019}s own interface; Chat is Next Term\u{2019}s native chat tab. Continue in Chat and Open in Terminal move a conversation between them. What you type in a shell is never changed."
        setAccessibilityLabel("Open " + agent.name + " in")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    private func refresh() {
        let kind = AgentOpenView.opensIn(agent, defaults: AgentOpenView.defaults)
        selectItem(at: ConversationHandoff.Kind.allCases.firstIndex(of: kind) ?? 0)
    }

    @objc private func changed() {
        guard let raw = selectedItem?.representedObject as? String, let kind = ConversationHandoff.Kind(rawValue: raw) else { return }
        AgentOpenView.set(kind, for: agent, defaults: AgentOpenView.defaults)
    }
}

/// The starts the setting applies to, in the app (R18): each gives the chat to open, or nil to keep its own terminal line.
extension AgentOpenView {
    /// Where the setting is kept: the app's defaults, or a self-test's suite.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// The Welcome window's Set up with your agent: a chat with the setup prompt when its agent opens in Chat.
    static func setupStart(_ agent: SetupAgent, folder: String) -> ChatStart? {
        newTabStart(command: agent.id, prompt: MCPServer.setupPrompt, folder: folder, defaults: defaults)
    }

    /// Agents › Resume Agent Session… and the sidebar's Resume: a chat that goes on with `session` when its agent opens in
    /// Chat; nil for a fork, the terminal default, or another agent.
    static func resumeStart(_ session: AgentSession, fork: Bool, folder: String) -> ChatStart? {
        guard let agent = ConversationHandoff.Agent(kind: session.agent) else { return nil }
        return resumeStart(agent: agent, sessionID: session.id, fork: fork, folder: folder, defaults: defaults)
    }
}

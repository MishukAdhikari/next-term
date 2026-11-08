import AppKit
import NextTermCore

/// Settings › Editor's "Open Claude Code in" and "Open Codex in" (plan 036 R11, KTD11): Terminal or Chat, for the starts
/// Next Term makes itself. Each is a popup bound to AgentOpenView's key for its agent.
enum AgentOpenViewControls {
    /// "Open Claude Code in: [Terminal]", as one row's views.
    static func control(_ agent: ViewSwitch.Agent) -> NSView {
        let popup = AgentOpenViewPopup(agent)
        let label = NSTextField(labelWithString: "Open " + agent.name + " in:")
        let stack = NSStackView(views: [label, popup])
        stack.spacing = 8
        return stack
    }
}

/// One agent's popup: it reads the setting each time it is shown, so a change made elsewhere shows.
private final class AgentOpenViewPopup: NSPopUpButton {
    private let agent: ViewSwitch.Agent

    init(_ agent: ViewSwitch.Agent) {
        self.agent = agent
        super.init(frame: .zero, pullsDown: false)
        for view in ViewSwitch.View.allCases {
            addItem(withTitle: view.title)
            lastItem?.representedObject = view.rawValue
        }
        target = self
        action = #selector(changed)
        let starts = "a new tab an agent asks for with \(agent.rawValue) alone, the Welcome window\u{2019}s Set up with your agent, and Resume in Agent Sessions"
        toolTip = "Where \(agent.name) opens when Next Term starts it: \(starts). Terminal is \(agent.name)\u{2019}s own interface; Chat is Next Term\u{2019}s agent session. The icon before a tab\u{2019}s × switches a tab between them. What you type in a shell is never changed."
        setAccessibilityLabel("Open " + agent.name + " in")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    private func refresh() {
        let view = AgentOpenView.opensIn(agent, defaults: AgentOpenView.defaults)
        selectItem(at: ViewSwitch.View.allCases.firstIndex(of: view) ?? 0)
    }

    @objc private func changed() {
        guard let raw = selectedItem?.representedObject as? String, let view = ViewSwitch.View(rawValue: raw) else { return }
        AgentOpenView.set(view, for: agent, defaults: AgentOpenView.defaults)
    }
}

/// The starts the setting applies to, in the app (KTD11): each gives its line, or nil to keep its own.
extension AgentOpenView {
    /// Where the setting is kept: the app's defaults, or a self-test's suite.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// `new_tab`'s command (R11): the line and the view a bare `claude` or `codex` opens in, nil for any other command.
    /// The line is nil when it stays as given, in the terminal view.
    static func newTabStart(command: String, prompt: String?) -> (line: String?, view: ViewSwitch.View, agent: ViewSwitch.Agent)? {
        guard let agent = ViewSwitch.Agent(program: command.trimmingCharacters(in: .whitespaces)) else { return nil }
        // The launcher is looked for along PATH: only for a start that needs it.
        guard opensIn(agent, defaults: defaults) == .chat,
              let start = startLine(command: command, prompt: prompt, launcher: ACPSessionTabs.launcher, defaults: defaults) else {
            return (nil, .terminal, agent)
        }
        return (start.line, start.view, agent)
    }

    /// The Welcome window's Set up with your agent: the session with the setup prompt when its agent opens in chat.
    static func setupLine(_ agent: SetupAgent) -> String {
        guard let kind = ViewSwitch.Agent(program: agent.id), opensIn(kind, defaults: defaults) == .chat,
              let start = startLine(command: agent.program, prompt: MCPServer.setupPrompt, launcher: ACPSessionTabs.launcher,
                                    defaults: defaults) else { return agent.commandLine }
        return start.line
    }

    /// Agents › Resume Agent Session… and the sidebar's Resume: the session that goes on with it when its agent opens in
    /// chat, else the agent's own resume command; a fork always the agent's own. With SessionStore's prefix either way.
    static func resumeCommand(_ session: AgentSession, fork: Bool) -> String {
        if let agent = ViewSwitch.Agent(kind: session.agent), opensIn(agent, defaults: defaults) == .chat,
           let line = resumeLine(agent: agent, sessionID: session.id, fork: fork, launcher: ACPSessionTabs.launcher, defaults: defaults) {
            return SessionStore.commandPrefix + line
        }
        return SessionStore.commandPrefix + session.resumeCommand(fork: fork)
    }
}

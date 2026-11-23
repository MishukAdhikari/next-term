import AppKit
import NextTermCore

/// “Set up with your agent” (claudedocs/research_first-run-setup_2026-11-02, R4): the agents on PATH that Next Term added
/// its tools to (`MCPRegistration.setupAgents`), each a click from a new tab in the home folder running it with the setup
/// prompt as its first message. It shows as a card under the Welcome window's three ways in, and as a line in the first
/// run's “Coming from another app?”. With no such agent neither shows, and importing stays the way in.
enum SetupWithAgent {
    static let title = "Set up with your agent"
    /// What the card says it does, under its title.
    static let sentence = "Your agent looks at what you used before and proposes a setup. Nothing changes until you approve it on your Mac."

    /// The tooltip and VoiceOver's help for an agent's button.
    static func help(_ agent: SetupAgent) -> String {
        "Open a tab in your home folder running \(agent.name), asked to set Next Term up"
    }

    /// A tab in the home folder, in the window in front (a new window when none is open), running the agent with the setup
    /// prompt. The agent asks its
    /// own questions there (trusting the folder, using Next Term’s tools), for the user to answer.
    static func start(_ agent: SetupAgent) {
        let home: String = NSHomeDirectory()
        // A tab in the window in front, if there is one: a new window only on a first launch with none open.
        let front: TerminalWindowController? = TerminalWindow.front?.windowController as? TerminalWindowController
        let controller: TerminalWindowController = front ?? AppDelegate.shared.openWindow(directory: home)
        controller.runInNewTab(directory: home, command: agent.commandLine, title: nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Calls `body` on the main thread after each registration pass, which can add or take away agents; the observer to
    /// remove.
    static func observe(_ body: @escaping () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: MCPRegistration.changed, object: nil, queue: .main) { _ in body() }
    }
}

/// An agent's button on the Welcome window's card: its name on a capsule darker than the card, lit under the pointer as
/// the cards are. Space or a click opens its tab; it never takes Return, which stays the Welcome list's.
final class SetupAgentChip: FillButton {
    let agent: SetupAgent
    static let height: CGFloat = 26
    private static let font: NSFont = .systemFont(ofSize: 12)

    init(_ agent: SetupAgent) {
        self.agent = agent
        super.init(title: agent.name)
        target = self
        action = #selector(start)
        toolTip = SetupWithAgent.help(agent)
        setAccessibilityHelp(SetupWithAgent.help(agent))
        // The name is the button, drawn by its own cell over the fill, and the chip is as wide as its name and padding.
        imagePosition = .noImage
        attributedTitle = NSAttributedString(string: agent.name, attributes: [.font: Self.font, .foregroundColor: Theme.text])
        let width: CGFloat = (attributedTitle.size().width + 24).rounded(.up)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            widthAnchor.constraint(equalToConstant: width),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var shape: NSBezierPath {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
    }
    override var restingFill: NSColor? { Theme.background }

    /// The fill, then the name centred on it: FillButton draws only the fill.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let size: NSSize = attributedTitle.size()
        attributedTitle.draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded()))
    }

    @objc private func start() { SetupWithAgent.start(agent) }
}

/// The fourth card on a first launch's Welcome window, under the three ways in and as wide as the three: its symbol and
/// title, one sentence, and a button for each agent, three to a row, centred. Hidden while no agent is offered; it
/// follows each registration pass, so an agent found after the window showed appears in it.
final class SetupAgentCard: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: SetupWithAgent.title)
    private let sentence = NSTextField(wrappingLabelWithString: SetupWithAgent.sentence)
    private let chipRows = NSStackView()
    private var observer: NSObjectProtocol?
    /// Agents' buttons to a row: three of the longest names fit the narrowest card.
    static let perRow = 3
    static let padding: CGFloat = 14
    /// The buttons shown, in order, for the self-test.
    private(set) var chips: [SetupAgentChip] = []

    init() {
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = Theme.textDim
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Theme.text
        Typography.singleLine(label, truncation: .byTruncatingTail)
        sentence.font = .systemFont(ofSize: 12)
        sentence.textColor = Theme.textDim
        sentence.alignment = .center
        sentence.maximumNumberOfLines = 3
        chipRows.orientation = .vertical
        chipRows.alignment = .centerX
        chipRows.spacing = 8
        let header = NSStackView(views: [icon, label])
        header.orientation = .horizontal
        header.spacing = 6
        for view in [icon, label, sentence] as [NSView] {
            view.setAccessibilityElement(false)
            (view as? NSControl)?.cell?.setAccessibilityElement(false)
        }
        for view in [header, sentence, chipRows] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let pad: CGFloat = Self.padding
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            header.centerXAnchor.constraint(equalTo: centerXAnchor),
            header.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: pad),
            sentence.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            sentence.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            sentence.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            chipRows.topAnchor.constraint(equalTo: sentence.bottomAnchor, constant: 12),
            chipRows.centerXAnchor.constraint(equalTo: centerXAnchor),
            chipRows.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: pad),
            chipRows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        // A group VoiceOver names, with what it does as its help, and the agents' buttons in it.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(SetupWithAgent.title)
        setAccessibilityHelp(SetupWithAgent.sentence)
        isHidden = true
        show(MCPRegistration.setupAgents)
        observer = SetupWithAgent.observe { [weak self] in self?.show(MCPRegistration.setupAgents) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// A button for each of `agents`, in their order; none hides the card.
    func show(_ agents: [SetupAgent]) {
        guard agents != chips.map(\.agent) else { return }
        chipRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chips = agents.map(SetupAgentChip.init)
        for start in stride(from: 0, to: chips.count, by: Self.perRow) {
            let row = NSStackView(views: Array(chips[start..<min(start + Self.perRow, chips.count)]))
            row.orientation = .horizontal
            row.spacing = 8
            chipRows.addArrangedSubview(row)
        }
        isHidden = agents.isEmpty
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bar.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    /// The sentence wraps at the card's width, less its padding.
    override func layout() {
        let width: CGFloat = max(0, bounds.width - 2 * Self.padding)
        if sentence.preferredMaxLayoutWidth != width { sentence.preferredMaxLayoutWidth = width }
        super.layout()
    }
}

/// The first run's “Coming from another app?” line for the same agents: “Or set up with your agent:” and a small button
/// for each. A click opens the agent's tab and closes the chooser (`onStart`). Hidden while no agent is offered; it
/// follows each registration pass, and `onChange` refits the window when it appears or changes.
final class SetupAgentLine: NSStackView {
    private let label = NSTextField(labelWithString: "Or set up with your agent:")
    private var observer: NSObjectProtocol?
    private var agents: [SetupAgent] = []
    /// After a button opened its agent's tab.
    var onStart: (() -> Void)?
    /// After the line appeared, went or changed.
    var onChange: (() -> Void)?
    /// The buttons shown, for the self-test.
    private(set) var buttons: [NSButton] = []

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityElement(false)
        label.cell?.setAccessibilityElement(false)
        show(MCPRegistration.setupAgents)
        observer = SetupWithAgent.observe { [weak self] in
            guard let self, self.show(MCPRegistration.setupAgents) else { return }
            self.onChange?()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// The label and a button for each agent; none hides the line. True when anything changed.
    @discardableResult
    func show(_ agents: [SetupAgent]) -> Bool {
        guard agents != self.agents || arrangedSubviews.isEmpty else { return false }
        self.agents = agents
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = agents.enumerated().map { (index: Int, agent: SetupAgent) -> NSButton in
            let button = NSButton(title: agent.name, target: self, action: #selector(chosen(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.tag = index
            button.toolTip = SetupWithAgent.help(agent)
            button.setAccessibilityHelp(SetupWithAgent.help(agent))
            return button
        }
        // VoiceOver hears the label with each button, as its group's name.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(SetupWithAgent.title)
        for view in [label] + buttons as [NSView] { addArrangedSubview(view) }
        isHidden = agents.isEmpty
        return true
    }

    @objc private func chosen(_ sender: NSButton) {
        guard agents.indices.contains(sender.tag) else { return }
        SetupWithAgent.start(agents[sender.tag])
        onStart?()
    }
}

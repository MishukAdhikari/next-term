import AppKit
import NextTermCore

/// The chat view's "Open in Terminal" (plan 036 U5, R13): a bar over a session tab's top when its session offered the
/// agent's terminal view, for what only that view does (signing in, a terminal-only command, Claude Code's own trust
/// question, a resume that couldn't go on). Its button runs the switch to the terminal view, as ⇧⌘J does while it is open.
///
/// Only Next Term's own `nxtrm agent` reports on the socket (AgentSessionSocket), so no other program can raise it. It
/// leaves when the switch runs, when it is closed, or when the tab's next command starts. It is drawn in the style of
/// the tab's notes, and never takes the terminal's keyboard: its button has no key of its own.
@MainActor
final class ViewSwitchOfferBar: NSView {
    /// The open bars, by tab id. Main thread.
    nonisolated(unsafe) private static var shown: [UUID: ViewSwitchOfferBar] = [:]

    let offer: ViewSwitch.TerminalOffer
    let agent: ViewSwitch.Agent
    private weak var tab: TerminalTab?
    private let tabID: UUID
    /// The tab's commands started when the offer came: one more means the tab moved on.
    private let commandsStarted: Int
    private var watch: Timer?

    /// Shows `offer` over `tab`, in place of a bar it shows already.
    static func show(_ offer: ViewSwitch.TerminalOffer, agent: ViewSwitch.Agent, in tab: TerminalTab) {
        close(tab)
        guard !tab.exited, tab.remote == nil else { return }
        let bar = ViewSwitchOfferBar(offer: offer, agent: agent, tab: tab)
        shown[tab.id] = bar
        bar.place(in: tab.view)
        NSAccessibility.post(element: bar, notification: .announcementRequested,
                             userInfo: [.announcement: offer.text(agent: agent), .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The open offer of `tab`, while it still applies: the same command runs, or has ended with nothing after it.
    static func open(for tab: TerminalTab) -> ViewSwitchOfferBar? {
        guard let bar = shown[tab.id] else { return nil }
        guard bar.applies else {
            bar.dismiss()
            return nil
        }
        return bar
    }

    /// Takes the bar off `tab`, if it shows one.
    static func close(_ tab: TerminalTab) {
        shown[tab.id]?.dismiss()
    }

    private init(offer: ViewSwitch.TerminalOffer, agent: ViewSwitch.Agent, tab: TerminalTab) {
        self.offer = offer
        self.agent = agent
        self.tab = tab
        tabID = tab.id
        commandsStarted = tab.status.commandsStarted
        super.init(frame: .zero)
        build()
        watch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.applies else { return }
                self.dismiss()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var applies: Bool {
        guard let tab, !tab.exited, tab.view.acceptsInput, superview != nil else { return false }
        return tab.status.commandsStarted == commandsStarted
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(offer.text(agent: agent))

        let words = NSTextField(labelWithString: offer.text(agent: agent))
        words.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        words.textColor = .white
        words.lineBreakMode = .byTruncatingTail
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let open = NSButton(title: "Open in Terminal", target: self, action: #selector(openInTerminal))
        open.bezelStyle = .rounded
        open.controlSize = .small
        open.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        open.keyEquivalent = "" // never the window's default key while the terminal has the keyboard
        let tip = KeyboardShortcuts.shared.hint("Open in Terminal", #selector(TerminalWindowController.switchView(_:)))
        open.toolTip = tip
        open.setAccessibilityLabel("Open in Terminal")

        let closer = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
            ?? NSImage(), target: self, action: #selector(closeBar))
        closer.isBordered = false
        closer.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        closer.imagePosition = .imageOnly
        closer.refusesFirstResponder = true
        closer.setAccessibilityLabel("Close")
        closer.toolTip = "Close"

        let row = NSStackView(views: [words, open, closer])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// At the terminal's top, centred, below the hint of a tab an agent opened.
    private func place(in view: NextTermView) {
        view.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: view.topAnchor, constant: view.awaitsChoice ? 30 : 6),
            centerXAnchor.constraint(equalTo: view.centerXAnchor),
            widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -16),
        ])
    }

    @objc private func openInTerminal() {
        guard let tab, applies else { return dismiss() }
        ViewSwitchRunner.start(tab: tab, wanted: .terminal)
    }

    @objc private func closeBar() {
        dismiss()
    }

    private func dismiss() {
        watch?.invalidate()
        watch = nil
        removeFromSuperview()
        if Self.shown[tabID] === self { Self.shown[tabID] = nil }
    }

    #if DEBUG
    /// The self-test's view of the bar: its words, and its button pressed as a click would.
    var shownText: String { offer.text(agent: agent) }
    func pressOpen() { openInTerminal() }
    #endif
}

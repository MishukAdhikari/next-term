import AppKit
import NextTermCore

/// An agent tab's live chat (plan 041 U3): the same session its terminal shows, drawn as a chat from the file the agent
/// writes (LiveChatFeed). The agent and its screen stay the source of truth:
/// - the composer is the prompt box, so a message is typed into the agent's own prompt, as one paste and Return;
/// - a question or permission the screen shows is a card answered with the keys answer_agent sends;
/// - while the agent works, a row says so with its newest tool;
/// - anything the chat can't show (the agent's own menus, /login, a trust question it can't map) is one click away in
///   the terminal.
///
/// Claude Code writes whole messages, so a reply appears when its message ends; tool calls show as they are made.
final class LiveChatView: NSView {
    let tab: TerminalTab
    let feed: LiveChatFeed
    let transcript: ChatTranscriptView
    let card = ChatDecisionCard()
    let composer: AgentPromptBox
    /// "Working…" with the newest tool, while the agent works.
    private let working = NSTextField(labelWithString: "")
    /// "The terminal shows something the chat can't" with Open Terminal, when the screen asks what the card can't map.
    private let elsewhere = NSTextField(labelWithString: "")
    private let elsewhereButton = NSButton(title: "Open Terminal", target: nil, action: nil)
    private var expanded: Set<String> = []
    private var timer: Timer?
    private var shownQuestion: String?
    /// The terminal button: the pane goes back to the agent's own screen.
    var onShowTerminal: (() -> Void)?

    init(tab: TerminalTab, feed: LiveChatFeed) {
        self.tab = tab
        self.feed = feed
        transcript = ChatTranscriptView(sizes: Self.sizes)
        composer = AgentPromptBox(tab: tab)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true
        setAccessibilityLabel("Chat view of the agent's session")

        working.font = .systemFont(ofSize: CGFloat(Self.sizes.secondary))
        working.textColor = Theme.textDim
        working.lineBreakMode = .byTruncatingTail
        working.isHidden = true
        elsewhere.font = .systemFont(ofSize: CGFloat(Self.sizes.secondary))
        elsewhere.textColor = Theme.textDim
        elsewhere.lineBreakMode = .byTruncatingTail
        elsewhereButton.controlSize = .small
        elsewhereButton.bezelStyle = .rounded
        elsewhereButton.target = self
        elsewhereButton.action = #selector(showTerminal)
        let elsewhereRow = NSStackView(views: [elsewhere, elsewhereButton])
        elsewhereRow.orientation = .horizontal
        elsewhereRow.spacing = 8
        elsewhereRow.isHidden = true
        card.isHidden = true

        for view in [transcript, working, elsewhereRow, card, composer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let column = ChatTranscriptView.columnWidth
        func centred(_ view: NSView) -> [NSLayoutConstraint] {
            let wide = view.widthAnchor.constraint(equalToConstant: column)
            wide.priority = .defaultHigh
            return [view.centerXAnchor.constraint(equalTo: centerXAnchor), wide,
                    view.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
                    view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)]
        }
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: topAnchor),
            transcript.leadingAnchor.constraint(equalTo: leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: trailingAnchor),
            working.topAnchor.constraint(equalTo: transcript.bottomAnchor, constant: 4),
            elsewhereRow.topAnchor.constraint(equalTo: working.bottomAnchor, constant: 4),
            card.topAnchor.constraint(equalTo: elsewhereRow.bottomAnchor, constant: 4),
            composer.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 6),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ] + centred(working) + centred(elsewhereRow) + centred(card) + centred(composer))
        self.elsewhereRow = elsewhereRow

        transcript.onLink = { [weak self] link in self?.follow(link) }
        card.onChoose = { [weak self] index in self?.answer(index) }
        feed.onChange = { [weak self] _, _ in self?.refresh() }
        refresh()
    }

    private var elsewhereRow: NSStackView?

    required init?(coder: NSCoder) { fatalError("not used") }

    static var sizes: ChatTextSizes { ChatTextSizes(base: Double(AppDelegate.shared?.fontSize ?? Theme.defaultFontSize)) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        // The tab's state (working, a question) is read from its screen: looked at while the chat shows.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshState() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Theme.background.cgColor
        transcript.redrawAll()
    }

    override func updateLayer() {
        layer?.backgroundColor = Theme.background.cgColor
    }

    /// The transcript from the feed's items, then the state rows.
    func refresh() {
        transcript.show(LiveChat.blocks(feed.items, expanded: expanded), sizes: Self.sizes, offersTerminal: true)
        refreshState()
    }

    /// The working row, the card, and the note when the screen asks something the card can't show.
    private func refreshState() {
        let status = tab.status
        let blocks = transcript.blocks
        if status.state == .working {
            let tool: String? = blocks.last.flatMap { block -> String? in
                if case .tool(let tool) = block.content, tool.status == .inProgress { return tool.shownTitle }
                return nil
            }
            working.stringValue = "\(TerminalWindowController.agentName(of: tab)) is working\u{2026}" + (tool.map { "  \u{00B7}  " + $0 } ?? "")
            working.isHidden = false
        } else {
            working.isHidden = true
        }
        if let question = status.question {
            if let menu = MCPControl.fieldMenu(tab, question: question), !menu.choices.isEmpty {
                let decision = ChatDecision.from(question: question, choices: menu.choices, highlighted: menu.highlighted ?? 0,
                                                 escape: menu.escape)
                card.show(decision, agent: TerminalWindowController.agentName(of: tab), sizes: Self.sizes, draftWaits: false)
                card.isHidden = false
                elsewhereRow?.isHidden = true
                if shownQuestion != question { card.announceOnce(agent: TerminalWindowController.agentName(of: tab)) }
            } else {
                card.isHidden = true
                elsewhere.stringValue = "\(TerminalWindowController.agentName(of: tab)) asks something in its own screen."
                elsewhereRow?.isHidden = false
            }
            shownQuestion = question
        } else {
            card.isHidden = true
            elsewhereRow?.isHidden = true
            shownQuestion = nil
        }
    }

    /// A choice on the card: answered as answer_agent answers, if the question is still the one shown.
    private func answer(_ index: Int) {
        guard let id = MCPControl.questionID(tab) else { return NSSound.beep() }
        MCPControl.call("answer_agent", ["tab_id": tab.id.uuidString.lowercased(), "question_id": id, "choice": index + 1],
                        caller: nil) { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if result.isError { NSSound.beep() }
                    self?.refreshState()
                }
            }
        }
    }

    private func follow(_ link: ChatLink) {
        switch link {
        case .toggle(let id):
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            refresh()
        case .diff(let id):
            let toolID = id.hasSuffix("#change") ? String(id.dropLast(7)) : id
            guard let item = feed.items.first(where: { $0.id == toolID }), case .tool(let call) = item.kind,
                  let path = call.diff?.path, !path.isEmpty else { return NSSound.beep() }
            let url = URL(fileURLWithPath: path.hasPrefix("/") ? path : (tab.directory as NSString).appendingPathComponent(path))
            (window?.windowController as? TerminalWindowController)?.showChanges(of: url)
        case .showAll:
            break
        case .openInTerminal:
            showTerminal()
        }
    }

    @objc private func showTerminal() { onShowTerminal?() }

    /// For the self-test: the blocks shown, and whether the card shows.
    var shownBlocks: [ChatBlock] { transcript.blocks }
    var showsCard: Bool { !card.isHidden }
}

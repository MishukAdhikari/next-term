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
        // The labels give way to the column; they never widen it.
        for label in [working, elsewhere] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let elsewhereRow = NSStackView(views: [elsewhere, elsewhereButton])
        elsewhereRow.orientation = .horizontal
        elsewhereRow.spacing = 8
        elsewhereRow.isHidden = true
        card.isHidden = true

        // Under the conversation, in the same column: the working row, the note, the card and the composer. A hidden
        // row takes no room and no gap, so with nothing to say the composer sits right under the conversation.
        let rows = NSStackView(views: [working, elsewhereRow, card, composer])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Self.rowGap
        rows.detachesHiddenViews = true
        rows.setClippingResistancePriority(.defaultLow, for: .horizontal)
        rows.setHuggingPriority(.defaultHigh, for: .vertical)
        // The first line starts under the floating terminal and chat buttons, not beside them.
        transcript.scrollView.automaticallyAdjustsContentInsets = false
        transcript.scrollView.contentInsets = NSEdgeInsets(top: Self.toggleRoom, left: 0, bottom: 0, right: 0)
        for view in [transcript, rows] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // The column (ChatColumn), as constraints that move with the view and so can never make it, its pane or the
        // window wider: centred, the width less both margins, at most the cap.
        let fill = rows.widthAnchor.constraint(equalTo: widthAnchor, constant: -2 * Self.margin)
        fill.priority = .init(999)
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: topAnchor),
            transcript.leadingAnchor.constraint(equalTo: leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: transcript.bottomAnchor, constant: Self.composerGap),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomMargin),
            rows.centerXAnchor.constraint(equalTo: centerXAnchor),
            rows.widthAnchor.constraint(lessThanOrEqualToConstant: CGFloat(ChatColumn.cap)),
            rows.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            fill,
        ] + [working, elsewhereRow, card, composer].map { $0.widthAnchor.constraint(equalTo: rows.widthAnchor) })
        self.elsewhereRow = elsewhereRow

        transcript.onLink = { [weak self] link in self?.follow(link) }
        card.onChoose = { [weak self] index in self?.answer(index) }
        feed.onChange = { [weak self] _, _ in self?.refresh() }
        refresh()
    }

    private var elsewhereRow: NSStackView?
    /// Between the conversation and the first row under it.
    static let composerGap: CGFloat = 8
    /// Between the rows under the conversation.
    static let rowGap: CGFloat = 6
    /// Under the composer.
    static let bottomMargin: CGFloat = 10
    /// Above the conversation, with its own 16 pt: the first line sits 34 pt down, clear of the floating buttons.
    static let toggleRoom: CGFloat = 18
    private static var margin: CGFloat { CGFloat(ChatColumn.margin) }

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

    override var wantsUpdateLayer: Bool { true }

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
            // Set only when it changes: this runs twice a second, and a label set again lays the view out again.
            let words = "\(TerminalWindowController.agentName(of: tab)) is working\u{2026}" + (tool.map { "  \u{00B7}  " + $0 } ?? "")
            if working.stringValue != words { working.stringValue = words }
            if working.isHidden { working.isHidden = false }
        } else if !working.isHidden {
            working.isHidden = true
        }
        if let question = status.question {
            if let menu = MCPControl.fieldMenu(tab, question: question), !menu.choices.isEmpty {
                let decision = ChatDecision.from(question: question, choices: menu.choices, highlighted: menu.highlighted ?? 0,
                                                 escape: menu.escape)
                if card.decision != decision || card.isHidden {
                    card.show(decision, agent: TerminalWindowController.agentName(of: tab), sizes: Self.sizes, draftWaits: false)
                }
                if card.isHidden { card.isHidden = false }
                if elsewhereRow?.isHidden == false { elsewhereRow?.isHidden = true }
                if shownQuestion != question { card.announceOnce(agent: TerminalWindowController.agentName(of: tab)) }
            } else {
                if !card.isHidden { card.isHidden = true }
                let words = "\(TerminalWindowController.agentName(of: tab)) asks something in its own screen."
                if elsewhere.stringValue != words { elsewhere.stringValue = words }
                if elsewhereRow?.isHidden == true { elsewhereRow?.isHidden = false }
            }
            shownQuestion = question
        } else {
            if !card.isHidden { card.isHidden = true }
            if elsewhereRow?.isHidden == false { elsewhereRow?.isHidden = true }
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
    /// The rows under the conversation that show (working, the note, the card).
    var showsStateRows: Bool { !working.isHidden || elsewhereRow?.isHidden == false || !card.isHidden }
}

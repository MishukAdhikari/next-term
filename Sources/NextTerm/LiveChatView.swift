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
///
/// An agent session Next Term runs itself (`nxtrm agent`, plan 047) is drawn from its journal instead (AgentChatFeed):
/// its replies stream, its permission is the card from the session's own request, and a choice is the digit (or the
/// arrows and Return) its menu takes in the tab. Its terminal is Next Term's text view of the same session.
final class LiveChatView: NSView {
    /// Where the chat is read from.
    enum Source {
        /// The file a Claude Code, Codex or Command Code in the tab writes (plan 041).
        case live(LiveChatFeed)
        /// The journal of an agent session in the tab (plan 047).
        case session(AgentChatFeed)

        /// The feed, for telling a view of it from a view of another.
        var object: AnyObject {
            switch self {
            case .live(let feed): return feed
            case .session(let feed): return feed
            }
        }
    }

    let tab: TerminalTab
    let source: Source
    let transcript: ChatTranscriptView
    let card = ChatDecisionCard()
    let planRow = NSTextField(labelWithString: "")
    let composer: AgentPromptBox
    /// "Working…" with the newest tool, while the agent works.
    private let working = NSTextField(labelWithString: "")
    /// "The terminal shows something the chat can't" with Open Terminal, when the screen asks what the card can't map.
    private let elsewhere = NSTextField(labelWithString: "")
    private let elsewhereButton = NSButton(title: "Open Terminal", target: nil, action: nil)
    /// The tokens the agent itself recorded for its last request, and how full its context is (ChatUsageLine).
    let usageLine = NSTextField(labelWithString: "")
    private var shownUsage: AgentUsage?
    /// The budget's hairline under the usage line, while the user has set one (TokenBudgets).
    let budgetBar = BudgetBar()
    private var shownBudget: (spent: Int?, tokens: Int)?
    private var expanded: Set<String> = []
    private var timer: Timer?
    private var shownQuestion: String?
    /// The terminal button: the pane goes back to the agent's own screen.
    var onShowTerminal: (() -> Void)?

    init(tab: TerminalTab, source: Source) {
        self.tab = tab
        self.source = source
        transcript = ChatTranscriptView(sizes: Self.sizes)
        composer = AgentPromptBox(tab: tab)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true
        // The "/" menu: an agent session's own commands; a command whose screen the chat can't draw shows the terminal.
        if case .session(let feed) = source { composer.sessionCommands = { [weak feed] in feed?.session.commands ?? [] } }
        composer.onSent = { [weak self] _, command in
            guard let self, command?.opensScreen == true, case .live = self.source else { return }
            self.onShowTerminal?()
        }
        setAccessibilityLabel("Chat view of the agent's session")

        // The plan row (plan 048 R4): the latest plan's progress while it has steps left; a click shows the checklist.
        planRow.font = .monospacedDigitSystemFont(ofSize: CGFloat(Self.sizes.secondary), weight: .regular)
        planRow.textColor = Theme.textDim
        planRow.lineBreakMode = .byTruncatingTail
        planRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        planRow.isHidden = true
        planRow.toolTip = "Show the plan"
        planRow.setAccessibilityRole(.button)
        planRow.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showPlan)))
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
        usageLine.font = .monospacedDigitSystemFont(ofSize: CGFloat(Self.sizes.secondary), weight: .regular)
        usageLine.textColor = Theme.textDim
        usageLine.lineBreakMode = .byTruncatingTail
        usageLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        usageLine.isHidden = true
        usageLine.setAccessibilityLabel("Token usage")
        budgetBar.isHidden = true
        let usageMenu = NSMenu()
        usageMenu.addItem(withTitle: "Set Token Budget\u{2026}", action: #selector(setBudget), keyEquivalent: "").target = self
        usageMenu.addItem(withTitle: "Clear Token Budget", action: #selector(clearBudget), keyEquivalent: "").target = self
        usageLine.menu = usageMenu
        let rows = NSStackView(views: [planRow, working, elsewhereRow, card, composer, usageLine, budgetBar])
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
        // window wider: from the leading margin, the width less both margins.
        let fill = rows.widthAnchor.constraint(equalTo: widthAnchor, constant: -2 * Self.margin)
        fill.priority = .init(999)
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: topAnchor),
            transcript.leadingAnchor.constraint(equalTo: leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: transcript.bottomAnchor, constant: Self.composerGap),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomMargin),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin),
            fill,
            budgetBar.heightAnchor.constraint(equalToConstant: BudgetBar.height),
        ] + [planRow, working, elsewhereRow, card, composer, usageLine, budgetBar].map { $0.widthAnchor.constraint(equalTo: rows.widthAnchor) })
        self.elsewhereRow = elsewhereRow

        transcript.onLink = { [weak self] link in self?.follow(link) }
        card.onChoose = { [weak self] index in self?.answer(index) }
        switch source {
        case .live(let feed): feed.onChange = { [weak self] _, _ in self?.refresh() }
        case .session(let feed): feed.onChange = { [weak self] _ in self?.refresh() }
        }
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
        themedBackground(Theme.background)
        transcript.redrawAll()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        themedBackground(Theme.background)
    }

    /// The transcript from the feed's items, then the state rows.
    func refresh() {
        let blocks: [ChatBlock]
        switch source {
        case .live(let feed): blocks = LiveChat.blocks(feed.items, expanded: expanded)
        case .session(let feed): blocks = ChatTranscript.blocks(from: feed.session, expanded: expanded, thoughtTimes: [:])
        }
        // One pass for both kinds of chat (plan 048): short paths, look-ups grouped, each turn's changes on its line.
        let shown = ChatPresentation.shown(blocks, folder: tab.directory, home: NSHomeDirectory(), expanded: expanded)
        transcript.show(shown, sizes: Self.sizes, offersTerminal: true)
        let plan = ChatPresentation.planLine(shown)
        if planRow.stringValue != (plan ?? "") { planRow.stringValue = plan ?? "" }
        if planRow.isHidden != (plan == nil) { planRow.isHidden = plan == nil }
        composer.refreshPlaceholder() // a session names its agent once it reports
        refreshState()
    }

    /// The agent's name as the chat says it: the session's own agent, or the tab's.
    private var agentName: String {
        if case .session = source, let agent = AgentSessionSocket.reports[tab.id]?.agent, !agent.isEmpty { return agent }
        return TerminalWindowController.agentName(of: tab)
    }

    /// What the session waits on now: its own request (a session), or what the agent's screen asks (a live chat).
    private func decision() -> (decision: ChatDecision?, asksElsewhere: Bool, question: String?) {
        if case .session(let feed) = source {
            guard let pending = feed.session.pending else { return (nil, false, nil) }
            let decision = ChatDecision.from(permission: pending, agent: agentName)
            return (decision, false, decision.question)
        }
        guard let question = tab.status.question else { return (nil, false, nil) }
        guard let menu = MCPControl.fieldMenu(tab, question: question), !menu.choices.isEmpty else { return (nil, true, question) }
        return (ChatDecision.from(question: question, choices: menu.choices, highlighted: menu.highlighted ?? 0, escape: menu.escape),
                false, question)
    }

    /// What the agent recorded: its transcript's last request (the context gauge's reader), or a session's usage_update.
    private var usage: AgentUsage? {
        switch source {
        case .live: return tab.contextUsage
        case .session(let feed): return feed.session.contextUsage
        }
    }

    /// The usage line and the budget's hairline, set only when what they show changes: the agent records usage once a
    /// request, not every frame.
    private func refreshUsage() {
        let usage = Self.showsTokenUsage ? self.usage : nil
        let budget = TokenBudgets.budgets[tab.id].map { (spent: TokenBudgets.spent(tab), tokens: $0) }
        if budget != nil { TokenBudgets.refresh(tab) { [weak self] in self?.refreshUsage() } }
        guard usage != shownUsage || budget?.spent != shownBudget?.spent || budget?.tokens != shownBudget?.tokens
              || usageLine.isHidden != (usage == nil && budget == nil) else { return }
        shownUsage = usage
        shownBudget = budget
        let font = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(Self.sizes.secondary), weight: .regular)
        let line = NSMutableAttributedString()
        var words: [String] = []
        var tips: [String] = []
        func add(_ text: String, warn: Bool = false) {
            if line.length > 0 { line.append(NSAttributedString(string: " \u{00B7} ", attributes: [.font: font, .foregroundColor: Theme.textDim])) }
            line.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: warn ? Theme.system(.orange) : Theme.textDim]))
            words.append(text)
        }
        if let usage {
            let parts = ChatUsageLine.parts(usage)
            add(parts.tokens)
            add(parts.percent, warn: parts.nearLimit)
            tips.append(ChatUsageLine.tooltip(usage))
        }
        if let budget {
            if let spent = budget.spent {
                let shown = TokenBudget.words(spent: spent, budget: budget.tokens)
                add(shown.text, warn: shown.fraction >= TokenBudget.warnFraction)
                budgetBar.show(fraction: shown.fraction)
                tips.append("Budget: \(shown.text), the session's tokens as the agent recorded them (cache reads apart). Shown, never enforced.")
            } else {
                add("budget \(AgentUsage.tokens(budget.tokens))")
                budgetBar.show(fraction: 0)
                tips.append("Budget: \(AgentUsage.tokens(budget.tokens)) tokens; counted once the agent records its next request.")
            }
        }
        budgetBar.isHidden = budget == nil
        usageLine.attributedStringValue = line
        usageLine.toolTip = tips.isEmpty ? nil : tips.joined(separator: "\n")
        usageLine.setAccessibilityValue(words.joined(separator: ", "))
        usageLine.isHidden = line.length == 0
    }

    /// The usage line's menu: Set Token Budget…, as an agent's set_token_budget sets it.
    @objc private func setBudget() {
        guard TokenBudgets.source(tab) != nil else {
            let alert = NSAlert()
            alert.messageText = "No budget for this agent"
            alert.informativeText = "Its sessions record no running total of their tokens that Next Term reads. Claude Code and Codex tabs do."
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Token Budget"
        alert.informativeText = "Shown under the chat as the session goes: its tokens as the agent records them, cache reads apart. Never enforced."
        let field = NSTextField(string: TokenBudgets.budgets[tab.id].map { AgentUsage.tokens($0) } ?? "")
        field.placeholderString = "2M"
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard let tokens = TokenBudget.parse(field.stringValue) else { return NSSound.beep() }
            TokenBudgets.set(tokens, for: self.tab)
            self.refreshUsage()
        }
    }

    @objc private func clearBudget() {
        TokenBudgets.set(nil, for: tab)
        refreshUsage()
    }

    private var isWorking: Bool {
        if case .session(let feed) = source { return feed.session.working }
        return tab.status.state == .working
    }

    /// The working row, the card, and the note when the screen asks something the card can't show.
    private func refreshState() {
        refreshUsage()
        let blocks = transcript.blocks
        let agent = agentName
        if isWorking {
            let tool: String? = blocks.last.flatMap { block -> String? in
                if case .tool(let tool) = block.content, tool.status == .inProgress { return tool.shownTitle }
                return nil
            }
            // Set only when it changes: this runs twice a second, and a label set again lays the view out again.
            let words = "\(agent) is working\u{2026}" + (tool.map { "  \u{00B7}  " + $0 } ?? "")
            if working.stringValue != words { working.stringValue = words }
            if working.isHidden { working.isHidden = false }
        } else if !working.isHidden {
            working.isHidden = true
        }
        let asked = decision()
        if let question = asked.question {
            if let decision = asked.decision {
                if card.decision != decision || card.isHidden {
                    card.show(decision, agent: agent, sizes: Self.sizes, draftWaits: false)
                }
                if card.isHidden { card.isHidden = false }
                if elsewhereRow?.isHidden == false { elsewhereRow?.isHidden = true }
                if shownQuestion != question { card.announceOnce(agent: agent) }
            } else {
                if !card.isHidden { card.isHidden = true }
                let words = "\(agent) asks something in its own screen."
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
        if case .session(let feed) = source {
            // The session's menu, as its keys pick: the digit, or past nine the arrows from the highlight and Return.
            guard let pending = feed.session.pending, pending.options.indices.contains(index), MCPControl.canType(tab) else {
                return NSSound.beep()
            }
            tab.view.onKeyboard?()
            if index < 9 {
                tab.view.send(txt: String(index + 1))
            } else {
                let step = index - pending.highlighted
                tab.view.send(txt: String(repeating: step < 0 ? "\u{1b}[A" : "\u{1b}[B", count: abs(step)) + "\r")
            }
            return
        }
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

    /// The plan row's click: the transcript scrolls to the plan's checklist.
    @objc private func showPlan() {
        guard let id = transcript.blocks.last(where: { if case .plan = $0.content { return true } else { return false } })?.id,
              let range = transcript.range(of: id) else { return }
        transcript.textView.scrollRangeToVisible(range)
        transcript.textView.showFindIndicator(for: range)
    }

    private func follow(_ link: ChatLink) {
        switch link {
        case .toggle(let id):
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            refresh()
        case .diff(let id):
            let toolID = id.hasSuffix("#change") ? String(id.dropLast(7)) : id
            let found: String?
            switch source {
            case .live(let feed):
                if let item = feed.items.first(where: { $0.id == toolID }), case .tool(let call) = item.kind { found = call.diff?.path } else { found = nil }
            case .session(let feed):
                found = feed.session.tools[toolID]?.changes.first?.path
            }
            guard let path = found, !path.isEmpty else { return NSSound.beep() }
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

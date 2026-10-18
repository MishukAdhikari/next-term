import AppKit
import NextTermCore

/// Peek: one agent read, answered or given a line, in a popover over its row (or over the terminal, from Go to Agent),
/// without bringing its tab forward and without moving the view herdr shows every client attached to its session.
/// For one of herdr's agents its recent text comes from herdr (`agent read --source recent-unwrapped`), once per check
/// while Peek is open and never after; for an agent tab, from the tab's own buffer, so nothing runs. Both are masked as
/// read_tab masks. A blocked agent's question shows with a button per choice (1-9 when the text area has the keyboard),
/// answered the way answer_agent answers, which reads the pane again first; the field sends one line (Return), kept as
/// a draft per agent until it is sent. ⌘2 shows its conversation instead, from its own transcript (AgentTranscript),
/// and ⌘1 the screen again, the choice kept for the app's run; ⌘E shows why herdr gives its state (`agent explain`);
/// ⌘Return opens the agent as its row's click does; Esc closes. What the user does here is the user's own: it never
/// asks, and the agent is no longer an MCP agent's to drive.
final class AgentPeek: NSObject, NSPopoverDelegate, NSTextFieldDelegate {
    /// One of herdr's agents (its pane in the tab's herdr, on one of that herdr's machines when `machine` is set), or the
    /// tab's own agent.
    enum Subject: Equatable {
        case herdr(machine: String?, pane: String)
        case tab
    }

    /// What the text area shows: the agent's screen, its conversation (from its own transcript), or herdr's reasons for
    /// its state.
    private enum Lens: Equatable {
        case screen
        case conversation
        case explain
    }

    /// The screen or the conversation, as the user last chose (⌘1, ⌘2), for the app's run.
    private static var chosen = Lens.screen

    /// The Peek open now: one at a time.
    private(set) static var current: AgentPeek?
    /// Each agent's unsent line, by its id, until it is sent, the agent is gone, or Next Term quits.
    private static var drafts: [String: String] = [:]

    /// The lines it shows.
    static let lines = 40

    private weak var tab: TerminalTab?
    let subject: Subject
    /// The agent's id: a herdr agent's (HerdrTarget), or the tab's.
    let key: String
    private let popover = NSPopover()
    private let content = PeekView()
    private let header = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private let question = NSTextField(wrappingLabelWithString: "")
    private let choices = NSStackView()
    private let field = NSTextField()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let hints = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var reading = false
    private var lens = AgentPeek.chosen
    /// The transcript's size at the last read, so an unchanged one is not read again.
    private var transcriptSize: Int?
    /// The question the buttons answer, by its id; nil while it asks none.
    private var shownQuestion: String?

    private init(tab: TerminalTab, subject: Subject) {
        self.tab = tab
        self.subject = subject
        switch subject {
        case let .herdr(machine, pane): key = HerdrTarget(tabID: tab.id.uuidString, machine: machine, pane: pane).id
        case .tab: key = tab.id.uuidString.lowercased()
        }
        super.init()
        build()
    }

    /// The herdr agent it peeks at, if it peeks at one.
    private var ref: HerdrAgentRef? {
        guard let tab, case let .herdr(machine, pane) = subject else { return nil }
        return HerdrAgentRef(tab: tab, machine: machine, pane: pane)
    }

    // MARK: opening

    /// Peek at one of herdr's agents of `tab`, or at the tab's own agent (`pane` nil), over `rect` of `view`; with no
    /// view, over the middle of the tab's window's terminal.
    static func show(_ tab: TerminalTab, machine: String? = nil, pane: String?, relativeTo rect: NSRect? = nil, of view: NSView? = nil) {
        current?.close()
        let peek = AgentPeek(tab: tab, subject: pane.map { .herdr(machine: machine, pane: $0) } ?? .tab)
        let anchor: NSView? = view ?? MCPControl.controller(of: tab)?.activeTab?.view ?? MCPControl.controller(of: tab)?.window?.contentView
        guard let anchor else { return NSSound.beep() }
        let middle = NSRect(x: anchor.bounds.midX - 1, y: anchor.bounds.midY + 60, width: 2, height: 2)
        current = peek
        peek.refresh()
        guard current === peek else { return NSSound.beep() } // its agent is gone
        // Beside a row, toward the terminal: to its right in a list on the left, to its left in one on the right.
        let inLeftHalf = view.map { row in
            row.convert(row.bounds, to: nil).midX < (row.window?.frame.width ?? 0) / 2
        } ?? true
        let edge: NSRectEdge = view == nil ? .maxY : (inLeftHalf ? .maxX : .minX)
        peek.popover.show(relativeTo: rect ?? middle, of: anchor, preferredEdge: edge)
        peek.focus()
        peek.timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak peek] _ in peek?.refresh() }
    }

    /// Peek at an agent from Go to Agent (⌥): over the terminal of the window in front.
    static func show(_ target: AgentQueue.Item.Target) {
        switch target {
        case let .herdr(id, pane):
            guard let tab = HerdrAgentMenu.tab(id) else { return NSSound.beep() }
            show(tab, pane: pane)
        case .tab(let id):
            guard let tab = HerdrAgentMenu.tab(id) else { return NSSound.beep() }
            show(tab, pane: nil)
        case let .machine(id, machine, pane):
            guard !pane.isEmpty, let tab = HerdrAgentMenu.tab(id) else { return NSSound.beep() }
            show(tab, machine: machine, pane: pane)
        case .host, .saved:
            NSSound.beep() // no herdr tab to read it through: choosing it opens one
        }
    }

    private func build() {
        popover.behavior = .transient
        popover.animates = !AgentSpinner.reducesMotion
        popover.delegate = self
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        content.peek = self

        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.lineBreakMode = .byTruncatingTail
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = true
        text.backgroundColor = Theme.background
        text.textColor = Theme.text
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("The agent's recent text")
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.background
        question.font = .systemFont(ofSize: 12, weight: .medium)
        question.textColor = Theme.attention
        choices.orientation = .horizontal
        choices.spacing = 6
        field.delegate = self
        field.placeholderString = "A line to send"
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        hints.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hints.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [header, scroll, question, choices, field, note, hints])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 560),
            scroll.heightAnchor.constraint(equalToConstant: 300),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            question.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        field.stringValue = Self.drafts[key] ?? ""
    }

    /// The keyboard: the text area while the agent waits on a decision (so 1-9 answer), else the field.
    private func focus() {
        let window = content.window
        window?.makeKey()
        window?.makeFirstResponder(shownQuestion != nil ? content : field)
    }

    func close() {
        popover.performClose(nil)
        ended()
    }

    func popoverDidClose(_ notification: Notification) { ended() }

    private func ended() {
        timer?.invalidate()
        timer = nil
        if Self.current === self { Self.current = nil }
    }

    // MARK: what it shows

    /// The agent as the last check left it: its name, state and time, its question and choices, and its text, read
    /// again (one read at a time). It closes once its agent is gone.
    func refresh() {
        guard let tab, !tab.exited else { return close() }
        switch subject {
        case .herdr(_, let pane):
            guard tab.followsHerdr, let ref, let tracker = ref.tracker, let agent = ref.agent else {
                Self.drafts[key] = nil
                return close()
            }
            let row = tracker.rows.first { $0.pane == pane }
            let time = row?.time(now: TerminalTab.now).map { " · " + $0 } ?? ""
            let place = ref.machineLabel.map { " · on " + $0 } ?? ""
            header.stringValue = SecretMask.current.mask(HerdrAgents.label(agent) + place + " · " + (row?.words ?? "") + time)
            let asked = agent.status == .blocked ? tracker.question(pane) : nil
            let id = asked.map { HerdrMCP.questionID($0, id: ref.id) }
            showQuestion(asked?.text, id: id, choices: asked?.choices ?? [])
            field.placeholderString = agent.status == .working
                ? "\(agent.name) is working: it gets this the way it gets typed input" : "A line to send \(agent.name)"
            if lens == .conversation { return readConversation() }
            guard lens == .screen, !reading else { return }
            reading = true
            ref.run(.read(pane: pane, source: .recentUnwrapped, lines: Self.lines)) { [weak self] result in
                guard let self else { return }
                self.reading = false
                guard self.lens == .screen else { return }
                switch result {
                case .text(let screen): self.show(text: HerdrMCP.screen(screen, lines: Self.lines))
                default: self.note.stringValue = HerdrMCP.problem(result, pane: pane, sent: false) ?? ""
                }
            }
        case .tab:
            let name = TerminalWindowController.agentName(of: tab)
            header.stringValue = SecretMask.current.mask([name.isEmpty ? tab.title : name, tab.ownStateDescription ?? "Idle"].joined(separator: " · "))
            let asked = tab.status.question
            let menu = asked.flatMap { MCPControl.fieldMenu(tab, question: $0) }
            showQuestion(asked.map { MCPControl.field($0) }, id: MCPControl.questionID(tab), choices: menu?.choices ?? [])
            field.placeholderString = "A line to send \(name.isEmpty ? "it" : name)"
            if lens == .conversation { return readConversation() }
            if lens == .screen { show(text: MCPControl.fieldTail(tab, Self.lines).joined(separator: "\n")) }
        }
        updateHints()
    }

    // MARK: the conversation

    /// ⌘2: the agent's last turns from its own transcript, read once now and then once per check while the size
    /// changed; anything that keeps it from being read shows the screen, with the reason in the note line.
    func showConversation() {
        guard lens != .conversation else { return }
        lens = .conversation
        Self.chosen = .conversation
        transcriptSize = nil
        refresh()
    }

    private func readConversation() {
        updateHints()
        guard let tab, !reading else { return }
        switch locateTranscript() {
        case .failure(let unread):
            fallBack(unread)
        case .success(let found):
            let (locator, name) = found
            reading = true
            if let remote = tab.remote, let path = tab.controlPath {
                let script = AgentTranscript.script(locator, knownSize: transcriptSize)
                RemoteConnection.run(remote.host, path: path, script: script, timeout: 20) { [weak self] output in
                    guard let self else { return }
                    self.reading = false
                    guard self.lens == .conversation else { return }
                    switch AgentTranscript.answer(output.output) {
                    case .failure(let unread): self.fallBack(unread)
                    case .success(let read): self.take(read.tail, size: read.size, kind: locator.kind, name: name)
                    }
                }
                return
            }
            let known = transcriptSize
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let found = AgentTranscript.only(AgentTranscript.candidates(locator, home: NSHomeDirectory(),
                                                                            environment: ProcessInfo.processInfo.environment))
                let read = (try? found.get()).flatMap(AgentTranscript.readTail)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.reading = false
                    guard self.lens == .conversation else { return }
                    if case .failure(let unread) = found { return self.fallBack(unread) }
                    guard let read else { return self.fallBack(.none) }
                    self.take(read.size == known ? nil : read.tail, size: read.size, kind: locator.kind, name: name)
                }
            }
        }
    }

    /// Where its transcript is, and the agent's name for the turns: herdr's session for one of its agents; the session
    /// Next Term's readers tie to an agent tab on this Mac.
    private func locateTranscript() -> Result<(AgentTranscript.Locator, String), AgentTranscript.Unread> {
        guard let tab else { return .failure(.none) }
        switch subject {
        case .herdr(let machine, _):
            guard let agent = ref?.agent else { return .failure(.none) }
            if machine != nil {
                return .failure(.unreachable("An agent on one of herdr's machines is reached only through herdr, which gives no conversation."))
            }
            let home: String? = tab.remote == nil ? NSHomeDirectory() : nil
            return AgentTranscript.locate(agent: agent.kind, session: agent.session, home: home).map { ($0, agent.name) }
        case .tab:
            guard tab.remote == nil else {
                return .failure(.unreachable("Next Term reads the conversation of an agent tab on this Mac only."))
            }
            guard let kind = AgentKind(program: tab.status.program) else { return .failure(.notRead(agent: tab.status.program)) }
            let pid = tcgetpgrp(tab.view.process.childfd)
            let id = pid > 0 ? AgentSessions.sessionID(of: kind, pid: pid) : nil
            let session = id ?? kind.resumedID(in: tab.status.command)
            return AgentTranscript.locate(agent: kind, sessionID: session).map { ($0, kind.name) }
        }
    }

    /// A read's tail as turns (nil: the size did not change, so what shows stays).
    private func take(_ tail: Data?, size: Int, kind: AgentTranscript.Kind, name: String) {
        transcriptSize = size
        guard let tail else { return }
        guard let turns = AgentTranscript.turns(tail: tail, kind: kind) else { return fallBack(.unparsed) }
        note.stringValue = ""
        show(text: AgentTranscript.text(turns, agent: name))
    }

    /// No conversation: the screen, and why in the note line.
    private func fallBack(_ unread: AgentTranscript.Unread) {
        note.stringValue = unread.reason
        transcriptSize = nil
        switch subject {
        case .herdr(_, let pane):
            guard let ref, !reading else { return }
            reading = true
            ref.run(.read(pane: pane, source: .recentUnwrapped, lines: Self.lines)) { [weak self] result in
                guard let self else { return }
                self.reading = false
                if case .text(let screen) = result, self.lens == .conversation { self.show(text: HerdrMCP.screen(screen, lines: Self.lines)) }
            }
        case .tab:
            guard let tab else { return }
            show(text: MCPControl.fieldTail(tab, Self.lines).joined(separator: "\n"))
        }
    }

    private func show(text shown: String) {
        guard text.string != shown else { return }
        let atEnd = scroll.verticalScroller.map { $0.floatValue > 0.98 } ?? true
        text.string = shown
        if atEnd { text.scrollToEndOfDocument(nil) }
    }

    private func showQuestion(_ asked: String?, id: String?, choices given: [String]) {
        question.stringValue = asked ?? ""
        question.isHidden = asked == nil
        guard id != shownQuestion || choices.arrangedSubviews.count != min(9, given.count) else { return }
        shownQuestion = asked == nil ? nil : id
        choices.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, choice) in given.prefix(9).enumerated() {
            let button = NSButton(title: "\(index + 1) " + Typography.shortened(choice, to: 40), target: self, action: #selector(chose(_:)))
            button.tag = index + 1
            button.bezelStyle = .rounded
            button.toolTip = choice
            choices.addArrangedSubview(button)
        }
        choices.isHidden = choices.arrangedSubviews.isEmpty
    }

    private func updateHints() {
        var keys = ["⌘↩ Open", "esc Close"]
        keys.insert(lens == .conversation ? "⌘1 Screen" : "⌘2 Conversation", at: 1)
        if case .herdr = subject, lens != .explain { keys.insert("⌘E Why This State?", at: 2) }
        if lens == .explain { keys.insert("⌘1 Screen", at: 1) }
        if shownQuestion != nil { keys.insert("1-9 Answer", at: 0) }
        hints.stringValue = keys.joined(separator: "   ")
    }

    // MARK: what the user does

    @objc private func chose(_ sender: NSButton) { answer(sender.tag) }

    /// Answers with choice `number` (1-based) the question the buttons show, as answer_agent does: read again first, and
    /// a question that changed meanwhile is not answered.
    func answer(_ number: Int) {
        guard let tab, let asked = shownQuestion, number <= choices.arrangedSubviews.count else { return NSSound.beep() }
        note.stringValue = "Answering…"
        switch subject {
        case .herdr:
            guard let ref else { return }
            let id = key
            HerdrMCP.answer(ref, expected: asked, choice: number, answer: nil, typing: { HerdrMCP.userActed(on: id) }) { [weak self] said in
                switch said {
                case .answered(let label, _): self?.note.stringValue = "Answered “\(MCPControl.field(label))”."
                case .refused(let refusal): self?.note.stringValue = refusal.sentence
                case .failed(let problem): self?.note.stringValue = problem
                }
                self?.refresh()
            }
        case .tab:
            let arguments: [String: Any] = ["tab_id": key, "question_id": asked, "choice": number]
            MCPControl.call("answer_agent", arguments, caller: nil) { [weak self] result in
                MCPControl.typedByUser(tab) // the user's own answer
                self?.note.stringValue = result.isError ? result.text : "Answered."
                self?.refresh()
            }
        }
    }

    /// Sends the field's line: to one of herdr's agents as a prompt (herdr writes it in order, even while the agent
    /// works), never while it waits on a decision; to an agent tab as send_to_tab types it.
    private func send() {
        guard let tab else { return }
        let line = field.stringValue.trimmingCharacters(in: .newlines)
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return NSSound.beep() }
        switch subject {
        case .herdr(_, let pane):
            guard let ref else { return }
            if ref.agent?.status == .blocked {
                note.stringValue = "It waits on a decision: answer it above."
                return NSSound.beep()
            }
            if let refusal = HerdrMCP.textRefusal(line) {
                note.stringValue = refusal
                return NSSound.beep()
            }
            HerdrMCP.userActed(on: key)
            note.stringValue = "Sending…"
            ref.run(.prompt(pane: pane), input: line) { [weak self] result in
                guard let self else { return }
                if case .error("agent_blocked", _) = result {
                    self.note.stringValue = "It waits on a decision: answer it above."
                } else if let problem = HerdrMCP.problem(result, pane: pane) {
                    self.note.stringValue = problem
                } else {
                    self.sent()
                }
            }
        case .tab:
            guard MCPControl.canType(tab) else {
                note.stringValue = "That tab cannot take input now."
                return NSSound.beep()
            }
            MCPControl.type(line, into: tab, submit: true)
            MCPControl.typedByUser(tab) // the user's own line
            sent()
        }
    }

    private func sent() {
        field.stringValue = ""
        Self.drafts[key] = nil
        note.stringValue = "Sent."
    }

    /// ⌘Return: the agent, as a click on its row: its tab comes forward and herdr shows its pane. One on a herdr machine
    /// is focused there (`--machine … agent focus`), and the herdr tab comes forward: herdr shows that machine's
    /// workspaces once the user picks it in herdr's own sidebar, which nothing outside herdr can do.
    func open() {
        guard let tab else { return }
        close()
        switch subject {
        case .herdr(nil, let pane):
            HerdrAgentMenu.show(tab: tab, pane: pane)
        case .herdr(.some, let pane):
            guard let ref, let controller = MCPControl.controller(of: tab) else { return }
            controller.window?.makeKeyAndOrderFront(nil)
            controller.show(tab)
            let label = ref.machineLabel ?? "that machine"
            ref.run(.focus(pane: pane, tab: nil)) { result in
                let said = HerdrMCP.problem(result, pane: pane, sent: false)
                tab.view.showNote(said ?? "herdr shows \(label)'s workspaces once you pick it in herdr's sidebar.")
            }
        case .tab:
            HerdrAgentMenu.go(to: .tab(tab.id.uuidString))
        }
    }

    /// ⌘E: herdr's own reasons for the agent's state, once, in the text area; ⌘1 or Esc goes back to its screen.
    func explain() {
        guard let tab, let ref else { return NSSound.beep() }
        let pane = ref.pane
        lens = .explain
        updateHints()
        show(text: "Asking herdr why…")
        ref.run(.explain(pane: pane)) { [weak self] result in
            guard let self, self.lens == .explain else { return }
            switch result {
            case .json(let said), .text(let said):
                self.show(text: HerdrExplain.shown(said))
            case .unsupported:
                HerdrRunner.run(.version, for: tab) { [weak self] version in
                    var has = ""
                    if case .text(let words) = version, let first = words.split(separator: "\n").first { has = " (this one is \(first))" }
                    self?.show(text: "herdr 0.6.9 or later explains states\(has).")
                }
            case .error(_, let message):
                self.show(text: "herdr: " + (message.split(separator: "\n").first.map(String.init) ?? message))
            default:
                self.show(text: HerdrMCP.problem(result, pane: pane, sent: false) ?? "")
            }
        }
    }

    /// ⌘1: the agent's screen again.
    func showScreen() {
        guard lens != .screen else { return }
        lens = .screen
        Self.chosen = .screen
        note.stringValue = ""
        refresh()
    }

    /// Esc: back to the screen or the conversation from herdr's reasons, else closed.
    func escape() {
        guard lens == .explain else { return close() }
        lens = AgentPeek.chosen
        transcriptSize = nil
        refresh()
    }

    // MARK: the field

    func controlTextDidChange(_ notification: Notification) {
        let line = field.stringValue
        Self.drafts[key] = line.isEmpty ? nil : line
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            send()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            escape()
            return true
        default:
            return false
        }
    }
}

/// Peek's content: the keys that act on the agent while the text area or the buttons have the keyboard.
final class PeekView: NSView {
    weak var peek: AgentPeek?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let keys = event.charactersIgnoringModifiers ?? ""
        if let digit = Int(keys), (1...9).contains(digit), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            peek?.answer(digit)
            return
        }
        switch event.keyCode {
        case 53: peek?.escape() // Esc
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let keys = event.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: event) }
        switch keys {
        case "\r": peek?.open()
        case "e": peek?.explain()
        case "1": peek?.showScreen()
        case "2": peek?.showConversation()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

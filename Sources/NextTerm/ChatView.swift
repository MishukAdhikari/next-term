import AppKit
import NextTermCore

/// What a chat view reads and asks of the session it shows: a chat tab's host, or a fixture in a debug snapshot.
/// Main thread.
protocol ChatViewSource: AnyObject {
    var session: ACPSession { get }
    var expanded: Set<String> { get set }
    var thoughtTimes: [Int: TimeInterval] { get }
    var draft: String { get set }
    var lastPrompt: String? { get }
    var header: ChatHeader { get }
    var inputState: ChatInputState { get }
    var state: ChatHostState { get }
    /// Why the chat isn't running, when it isn't: the end card shows it.
    var endState: ChatEndState? { get }
    /// A conversation id is known: Resume and Restart go on with it.
    var resumable: Bool { get }
    var agentName: String { get }
    /// The folder the agent runs in, for a file change's path.
    var folder: String { get }
    /// Claude Code or Codex: a terminal tab can go on with the conversation (Open in Terminal).
    var offersTerminal: Bool { get }
    var onChange: ((_ soon: Bool) -> Void)? { get set }
    func send(_ text: String) -> ChatTabHost.SendOutcome
    func stop()
    func choose(_ index: Int)
    func moveHighlight(_ step: Int)
    func restart()
    /// The end card's Show Tab, once the conversation went on in another tab.
    func showContinuedTab()
}

extension ChatViewSource {
    func showContinuedTab() {}

    /// The card the open permission or question docks as, or nil.
    var decision: ChatDecision? { session.pending.map { ChatDecision.from($0, agent: agentName) } }
}

/// A chat tab's view (plan 037 U6): the header, the transcript, the docked decision or end card, and the input box,
/// top to bottom. The card, the input and the transcript's text share one centred column at most 760 points wide.
/// Text sizes follow the editor's (View › Bigger and Smaller). Focus goes input → card → transcript with Tab.
final class ChatView: NSView {
    private weak var source: ChatViewSource?
    let header = ChatHeaderView()
    let transcript: ChatTranscriptView
    let card = ChatDecisionCard()
    let endCard = ChatEndCard()
    let input = ChatInputView()
    private let dock = NSStackView()
    private var sizes: ChatTextSizes
    private var pendingRefresh = false
    /// The turns ended so far, to announce a new one once.
    private var turnsSeen = 0
    private var defaultsObserver: NSObjectProtocol?

    init(source: ChatViewSource) {
        self.source = source
        sizes = Self.currentSizes
        transcript = ChatTranscriptView(sizes: sizes)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true
        setAccessibilityElement(false)

        for view in [header, transcript, dock, input] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        dock.orientation = .vertical
        dock.alignment = .leading
        dock.spacing = 8
        dock.detachesHiddenViews = true
        dock.addArrangedSubview(card)
        dock.addArrangedSubview(endCard)
        card.isHidden = true
        endCard.isHidden = true
        card.translatesAutoresizingMaskIntoConstraints = false
        endCard.translatesAutoresizingMaskIntoConstraints = false

        let column = ChatTranscriptView.columnWidth
        let margin = ChatTranscriptView.sideMargin
        var constraints: [NSLayoutConstraint] = [
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            transcript.topAnchor.constraint(equalTo: header.bottomAnchor),
            transcript.leadingAnchor.constraint(equalTo: leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: trailingAnchor),
            dock.topAnchor.constraint(equalTo: transcript.bottomAnchor, constant: 4),
            input.topAnchor.constraint(equalTo: dock.bottomAnchor, constant: 8),
            input.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            card.widthAnchor.constraint(equalTo: dock.widthAnchor),
            endCard.widthAnchor.constraint(equalTo: dock.widthAnchor),
        ]
        for view in [dock, input] as [NSView] {
            constraints += [
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
                view.widthAnchor.constraint(lessThanOrEqualToConstant: column),
                view.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: margin),
            ]
            let wide = view.widthAnchor.constraint(equalToConstant: column)
            wide.priority = .defaultHigh
            constraints.append(wide)
            let fill = view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin)
            fill.priority = .defaultLow
            constraints.append(fill)
        }
        NSLayoutConstraint.activate(constraints)

        header.onStop = { [weak self] in self?.source?.stop() }
        header.onOpenInTerminal = { [weak self] in self?.openInTerminal() }
        transcript.onLink = { [weak self] link in self?.follow(link) }
        card.onChoose = { [weak self] index in self?.source?.choose(index) }
        card.onMove = { [weak self] step in self?.source?.moveHighlight(step) }
        endCard.onAction = { [weak self] action in self?.endAction(action) }
        input.onSend = { [weak self] text in self?.send(text) }
        input.onStop = { [weak self] in self?.source?.stop() }
        input.onDraft = { [weak self] text in self?.source?.draft = text }
        input.lastPrompt = { [weak self] in self?.source?.lastPrompt }
        input.commands = { [weak self] in self?.source?.session.commands ?? [] }
        input.turnRuns = { [weak self] in self?.source?.inputState.showsStop ?? false }

        // Tab: input → card → transcript → input.
        input.textView.nextKeyView = card
        card.nextKeyView = endCard
        endCard.nextKeyView = transcript.textView
        transcript.textView.nextKeyView = input.textView

        source.onChange = { [weak self] soon in self?.changed(soon: soon) }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followFontSize() }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Self.background.setFill()
        dirtyRect.fill()
    }

    /// The terminal theme's background in dark (no flash between tabs), the text background in light.
    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? Theme.background : .textBackgroundColor
    }

    // MARK: sizes

    /// The editor's size (View › Bigger and Smaller) as the chat's text sizes.
    static var currentSizes: ChatTextSizes {
        let saved = UserDefaults.standard.double(forKey: "fontSize")
        return ChatTextSizes(base: saved > 0 ? saved : Double(Theme.defaultFontSize))
    }

    private func followFontSize() {
        let now = Self.currentSizes
        guard now != sizes else { return }
        sizes = now
        refresh()
    }

    // MARK: updating

    /// The host changed: drawn now, or for streamed chunks once a frame (16 ms), coalesced.
    private func changed(soon: Bool) {
        guard soon else { return refresh() }
        guard !pendingRefresh else { return }
        pendingRefresh = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self, self.pendingRefresh else { return }
            self.refresh()
        }
    }

    func refresh() {
        pendingRefresh = false
        guard let source else { return }
        let session = source.session
        let terminal = canOpenInTerminal
        header.show(source.header, sizes: sizes, offersTerminal: terminal)
        let blocks = ChatTranscript.blocks(from: session, expanded: source.expanded, thoughtTimes: source.thoughtTimes)
        transcript.show(blocks, sizes: sizes, offersTerminal: terminal)

        let hadCardKeyboard = window?.firstResponder === card
        if let decision = source.decision {
            let appearing = card.isHidden
            card.show(decision, agent: source.agentName, sizes: sizes, draftWaits: !source.draft.isEmpty)
            card.isHidden = false
            if appearing, source.draft.isEmpty, hasKeyboard { window?.makeFirstResponder(card) }
            card.announceOnce(agent: source.agentName)
        } else {
            card.isHidden = true
            if hadCardKeyboard { window?.makeFirstResponder(input.textView) }
        }
        if let end = source.endState {
            endCard.show(end, agent: source.agentName, resumable: source.resumable, offersTerminal: terminal, sizes: sizes)
            endCard.isHidden = false
        } else {
            if window?.firstResponder === endCard { window?.makeFirstResponder(input.textView) }
            endCard.isHidden = true
        }
        input.show(source.inputState, draft: source.draft, sizes: sizes)
        announceTurnEnd(session)
    }

    /// A finished turn is said once to VoiceOver, when the tab is in front.
    private func announceTurnEnd(_ session: ACPSession) {
        var ended = 0
        var last: ACPSession.StopReason?
        for item in session.items {
            if case .turnEnded(let reason) = item { ended += 1; last = reason }
        }
        defer { turnsSeen = ended }
        guard ended > turnsSeen, turnsSeen > 0 || ended == 1, let last, let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else { return }
        let agent = source?.agentName ?? "The agent"
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: "\(agent): \(last.words)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    // MARK: focus

    /// Whatever in the chat has the keyboard.
    var hasKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    /// What takes the keyboard when the chat's tab does: the card while it waits and the draft is empty, else the
    /// input box.
    var preferredResponder: NSResponder {
        if !card.isHidden, source?.draft.isEmpty ?? true { return card }
        return input.textView
    }

    override var acceptsFirstResponder: Bool { true }

    /// The chat itself handed the keyboard: it passes it on.
    override func becomeFirstResponder() -> Bool {
        let target = preferredResponder
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder === self else { return }
            self.window?.makeFirstResponder(target)
        }
        return true
    }

    // MARK: actions

    private func send(_ text: String) {
        guard let source else { return }
        switch source.send(text) {
        case .sent: input.clear()
        case .terminalOnly: break
        case .refused: NSSound.beep()
        }
    }

    private func follow(_ link: ChatLink) {
        guard let source else { return }
        switch link {
        case .toggle(let id):
            if source.expanded.contains(id) { source.expanded.remove(id) } else { source.expanded.insert(id) }
            refresh()
        case .diff(let id):
            openDiff(id)
        case .openInTerminal:
            openInTerminal()
        case .showAll:
            break
        }
    }

    /// A file change in the editor: its changes against the last commit when the file is in git, else the file.
    private func openDiff(_ id: String) {
        guard let source, let block = transcript.blocks.first(where: { $0.id == id }), case .change(let change) = block.content else { return }
        let path = change.path.hasPrefix("/") ? change.path : (source.folder as NSString).appendingPathComponent(change.path)
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let controller = window?.windowController as? TerminalWindowController else { return }
        let root = ProjectRoot.find(from: (url.path as NSString).deletingLastPathComponent)
        let inGit = FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git"))
        if inGit, url.path.hasPrefix(root + "/") {
            controller.showChanges(of: url)
        } else if FileManager.default.fileExists(atPath: url.path) {
            controller.openFile(url)
        } else {
            NSSound.beep()
        }
    }

    static let handoffAction = #selector(TerminalWindowController.handOffConversation(_:))

    /// Open in Terminal is offered for Claude Code and Codex once the window answers the handoff (plan 037 U8).
    private var canOpenInTerminal: Bool {
        guard source?.offersTerminal == true else { return false }
        return NSApp.target(forAction: Self.handoffAction, to: nil, from: self) != nil
    }

    /// The handoff, through the responder chain.
    private func openInTerminal() {
        NSApp.sendAction(Self.handoffAction, to: nil, from: self)
    }

    private func endAction(_ action: ChatEndCard.Action) {
        switch action {
        case .restart, .resume: source?.restart()
        case .openInTerminal: openInTerminal()
        case .showTab: source?.showContinuedTab()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension ChatTabHost: ChatViewSource {
    var agentName: String { agent?.name ?? start.agentID }

    var endState: ChatEndState? {
        if state == .ended, let note = continuedNote { return .continued(note, tabOpen: continuedTab != nil) }
        switch state {
        case .idle: return .idle
        case .ended: return .ended(ending ?? .closed)
        default: return nil
        }
    }

    var resumable: Bool { sessionID.map(AgentSessionVersion.isSessionID) ?? false }

    var offersTerminal: Bool { ConversationHandoff.Agent(rawValue: start.agentID) != nil }
}

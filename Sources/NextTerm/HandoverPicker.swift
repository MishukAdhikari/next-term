import AppKit
import NextTermCore

/// forward_prompt's question to the user when more than one session could take the prompts (plan 042, R9): which one.
/// It is an agent's ask at a moment of the agent's choosing, so it looks and behaves as AgentApprovalWindow does: it
/// comes up in front without taking the keyboard, Send Here is the one primary and only a click presses it, and Escape
/// or closing it cancels, which moves nothing. Each row is a session (its title, then its project and agent, and
/// whether it is open or would be resumed); under them, the exact text that would be typed.
@MainActor
final class HandoverPicker: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Request {
        /// What would be typed in the chosen session.
        var text: String
        /// The tab the prompts were typed in.
        var from: String
        var candidates: [PromptHandover.Candidate]
    }

    /// The one picker up now; a second hand-over meanwhile is told to wait.
    private(set) static var current: HandoverPicker?

    static func ask(_ request: Request, answer: @escaping (PromptHandover.Candidate?) -> Void) {
        guard current == nil else { return answer(nil) }
        let picker = HandoverPicker(request, answer: answer)
        current = picker
        picker.present()
    }

    private let request: Request
    private let onAnswer: (PromptHandover.Candidate?) -> Void
    private var answered = false
    private let table = NSTableView()
    private(set) var sendButton: PrimaryButton!
    private(set) var cancelButton: NSButton!

    private static let width: CGFloat = 520

    init(_ request: Request, answer: @escaping (PromptHandover.Candidate?) -> Void) {
        self.request = request
        onAnswer = answer
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 360), styleMask: [.titled, .closable, .utilityWindow],
                             backing: .buffered, defer: false)
        window.title = "Where should these prompts go?"
        window.keepsItsOwnFrame()
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let content = window?.contentView else { return }
        let inner = ApprovalLayout.inner(Self.width)
        let heading = ApprovalLayout.heading("Where should these prompts go?", width: inner)
        let from = SecretApprovalPanel.sanitized(request.from, limit: 80)
        let lead = ApprovalLayout.secondary("These prompts were typed in the \u{201C}\(from)\u{201D} tab, meant for another session. "
            + "Next Term types them there when that agent is idle.", width: inner)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.width = inner - 4
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = false
        table.refusesFirstResponder = true
        table.setAccessibilityLabel("Sessions")
        let rows = NSScrollView()
        rows.documentView = table
        rows.hasVerticalScroller = true
        rows.borderType = .bezelBorder
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.heightAnchor.constraint(equalToConstant: CGFloat(min(request.candidates.count, 5)) * 38 + 8).isActive = true

        let caption = ApprovalLayout.caption("What will be typed there")
        let typed = ApprovalLayout.body(SecretMask.current.mask(SecretApprovalPanel.sanitized(request.text, limit: 2_000)), width: inner - 20)
        let typedBox = UpdateListScroll(maxHeight: 120, bordered: true)
        typedBox.stack.addArrangedSubview(typed)

        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        sendButton = PrimaryButton(title: "Send Here", target: self, action: #selector(send))
        let buttons = ApprovalLayout.buttonRow(left: [], decline: cancelButton, primary: sendButton)
        let views: [NSView] = [ApprovalLayout.group([heading, lead]), rows, ApprovalLayout.group([caption, typedBox]), buttons]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ApprovalLayout.groupSpacing
        stack.edgeInsets = DialogFit.insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        for view in views { view.widthAnchor.constraint(equalToConstant: inner).isActive = true }
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        typedBox.fit()
        DialogFit.fit(window, width: Self.width)
    }

    func present() {
        guard let window else { return }
        window.layoutIfNeeded()
        window.center()
        window.orderFront(nil)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    // MARK: rows

    func numberOfRows(in tableView: NSTableView) -> Int { request.candidates.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let candidate = request.candidates[row]
        let title = NSTextField(labelWithString: SecretApprovalPanel.sanitized(Self.name(candidate), limit: 120))

        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        let state = candidate.open ? "open tab" : "closed, opens in a new tab"
        let named = Self.name(candidate)
        let parts = (named == candidate.project ? [] : [candidate.project]) + [candidate.agent, state]
        let detail = NSTextField(labelWithString: parts.joined(separator: " \u{00B7} "))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.setAccessibilityElement(true)
        stack.setAccessibilityLabel("\(title.stringValue), \(detail.stringValue)")
        return stack
    }

    /// A row's name: the session's title, or its project when the title says nothing more than the agent's name.
    static func name(_ candidate: PromptHandover.Candidate) -> String {
        let title = candidate.title.trimmingCharacters(in: .whitespaces)
        let plain = title.lowercased()
        let agentWords: Set<String> = ["claude", "codex", "cmd", "opencode", "gemini", candidate.agent.lowercased()]
        return title.isEmpty || agentWords.contains(plain) ? candidate.project : title
    }

    // MARK: answers

    var chosen: PromptHandover.Candidate? {
        let row = table.selectedRow
        return row >= 0 && row < request.candidates.count ? request.candidates[row] : nil
    }

    /// Chooses a row, for the self-test.
    func select(_ row: Int) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }

    @objc private func send() { finish(chosen) }

    @objc private func cancel() { finish(nil) }

    override func cancelOperation(_ sender: Any?) { finish(nil) }

    private func finish(_ candidate: PromptHandover.Candidate?) {
        guard !answered else { return }
        answered = true
        Self.current = nil
        onAnswer(candidate)
        close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !answered else { return }
        answered = true
        Self.current = nil
        onAnswer(nil)
    }
}

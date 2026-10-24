import AppKit
import NextTermCore

/// Tasks › Post Update…: today's draft, Done, Next and Blocked, in one text the user can change in full, then Copy,
/// Save to Project, or Send Through an Agent Tab…, which types it with no Return. The draft opens at once and fills
/// when the sources are read; nothing is kept between openings. Every way out masks the text first, and the text view
/// then shows what left. Nothing is logged, posted or opened by Next Term itself.
@MainActor
final class PostUpdateSheet: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    enum Step { case edit, send }

    private static var shown: PostUpdateSheet?
    let window: NSWindow
    private weak var controller: TerminalWindowController?
    private let project: String?
    private(set) var step = Step.edit
    /// The draft as built, nil while the sources are read.
    private(set) var draft: UpdateDraft?
    /// The text as built, to tell whether the user changed it.
    private var built = ""
    private(set) var choices: [TaskAgentRequest.Choice] = []
    private weak var pickedTab: TerminalTab?

    private let heading = NSTextField(labelWithString: "Post Update")
    let textView: NSTextView
    private let textScroll: NSScrollView
    let sourceLine = NSTextField(wrappingLabelWithString: "Gathering today’s work…")
    let status = NSTextField(wrappingLabelWithString: "")
    private let reveal = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    /// The file Save wrote last, for Reveal.
    private(set) var saved: URL?

    private let sendBox = NSStackView()
    let agent = NSPopUpButton()
    let place = NSTextField()
    private let sendNote = NSTextField(wrappingLabelWithString: "")

    private let startOver = NSButton(title: "Start Over", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let saveButton = NSButton(title: "Save to Project", target: nil, action: nil)
    let sendStepButton = NSButton(title: "Send Through an Agent Tab…", target: nil, action: nil)
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    let sendButton = NSButton(title: "Send", target: nil, action: nil)

    /// The sheet over `controller`'s window, or the one already open there brought forward.
    @discardableResult
    static func present(over controller: TerminalWindowController) -> PostUpdateSheet? {
        guard let parent = controller.window else { return nil }
        if let shown { return shown.controller === controller ? shown : nil }
        let sheet = PostUpdateSheet(controller: controller)
        shown = sheet
        parent.beginSheet(sheet.window) { _ in
            if shown === sheet { shown = nil }
        }
        sheet.gather()
        return sheet
    }

    private init(controller: TerminalWindowController) {
        self.controller = controller
        project = controller.project
        textScroll = NSTextView.scrollableTextView()
        textView = textScroll.documentView as! NSTextView
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 460), styleMask: [.titled],
                          backing: .buffered, defer: false)
        super.init()
        build()
        render()
    }

    private func build() {
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isEditable = false
        textView.delegate = self
        textView.setAccessibilityLabel("Update")
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textScroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        for label in [sourceLine, status, sendNote] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 11)
        }
        reveal.bezelStyle = .inline
        reveal.target = self
        reveal.action = #selector(revealPressed)
        let statusRow = NSStackView(views: [status, reveal])
        statusRow.orientation = .horizontal
        statusRow.alignment = .firstBaseline
        buildSendBox()
        let buttons = buildButtons()
        let stack = NSStackView(views: [heading, textScroll, sourceLine, statusRow, sendBox, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [textScroll, sourceLine, statusRow, sendBox, buttons] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 600),
        ])
        window.contentView = content
        window.initialFirstResponder = textView
    }
}

// MARK: building and showing

extension PostUpdateSheet {
    private func buildSendBox() {
        agent.autoenablesItems = false
        agent.target = self
        agent.action = #selector(agentPicked)
        NotificationCenter.default.addObserver(self, selector: #selector(agentsWillOpen),
                                               name: NSPopUpButton.willPopUpNotification, object: agent)
        place.placeholderString = "Slack #team, the Linear project update…"
        place.delegate = self
        place.setAccessibilityLabel("Where to post")
        let agentLabel = NSTextField(labelWithString: "Agent tab:")
        let placeLabel = NSTextField(labelWithString: "Where to post:")
        let grid = NSGridView(views: [[agentLabel, agent], [placeLabel, place]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        place.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        sendNote.stringValue = "The update is typed into the tab’s prompt with no Return. You read it there and "
            + "press Return to send it."
        sendBox.orientation = .vertical
        sendBox.alignment = .leading
        sendBox.spacing = 8
        sendBox.addArrangedSubview(grid)
        sendBox.addArrangedSubview(sendNote)
        sendNote.widthAnchor.constraint(equalTo: sendBox.widthAnchor).isActive = true
    }

    private func buildButtons() -> NSStackView {
        let pairs: [(NSButton, Selector)] = [
            (startOver, #selector(startOverPressed)), (cancelButton, #selector(cancel)),
            (saveButton, #selector(savePressed)), (sendStepButton, #selector(sendStepPressed)),
            (copyButton, #selector(copyPressed)), (backButton, #selector(backPressed)),
            (sendButton, #selector(sendPressed)),
        ]
        for (button, action) in pairs {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        cancelButton.keyEquivalent = "\u{1b}"
        // Return is a new line in the draft: the default button takes ⌘Return, as Add Task's does.
        for button in [copyButton, sendButton] {
            button.keyEquivalent = "\r"
            button.keyEquivalentModifierMask = .command
        }
        let views: [NSView] = [startOver, backButton, NSView(), cancelButton, saveButton, sendStepButton, copyButton,
                               sendButton]
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        return row
    }

    /// Shows the step and turns each button on or off for the text as it is now.
    func render() {
        let editing = step == .edit
        let ready = draft != nil
        let hasText = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        textView.isEditable = ready && editing
        for button in [startOver, saveButton, sendStepButton, copyButton] { button.isHidden = !editing }
        for button in [backButton, sendButton] { button.isHidden = editing }
        sendBox.isHidden = editing
        startOver.isEnabled = ready
        for button in [saveButton, sendStepButton, copyButton] { button.isEnabled = ready && hasText }
        reveal.isHidden = saved == nil || !editing
        sendButton.isEnabled = canSend
        status.isHidden = status.stringValue.isEmpty
    }

    /// Send can type now: a ready tab picked, a place to post, and a text short enough.
    var canSend: Bool {
        guard step == .send, let pickedTab, choices.contains(where: { $0.tab === pickedTab && $0.isReady }) else {
            return false
        }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return UpdateDraft.request(text: text, to: place.stringValue) != nil
    }

    /// Reads today's sources; the draft replaces the text when they return.
    func gather() {
        guard let project else {
            sourceLine.stringValue = "This window has no project: Post Update reads today’s work in a project."
            return render()
        }
        PostUpdate.gather(project: project) { [weak self] draft in
            guard let self else { return }
            self.fill(draft)
        }
    }

    /// The text view holds `draft`'s text, and the lines under it say where it came from.
    func fill(_ draft: UpdateDraft) {
        self.draft = draft
        built = draft.text(date: Date())
        textView.string = built
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        sourceLine.stringValue = ([draft.sourceLine] + draft.notes).joined(separator: "\n")
        status.stringValue = ""
        render()
        window.makeFirstResponder(textView)
    }

    func textDidChange(_ notification: Notification) { render() }

    func controlTextDidChange(_ notification: Notification) { render() }
}

// MARK: the actions

extension PostUpdateSheet {
    static let keyReplaced = "A stored key was replaced with •••."

    /// The text as it may leave: masked, and the view shows the masked text when masking changed it.
    private func leavingText() -> (text: String, note: String?) {
        let masked = PostUpdate.masked(textView.string)
        guard masked.changed else { return (masked.text, nil) }
        textView.string = masked.text
        return (masked.text, Self.keyReplaced)
    }

    private func say(_ line: String, _ note: String?) {
        status.stringValue = [line, note].compactMap { $0 }.joined(separator: " ")
        render()
    }

    @objc func copyPressed() {
        guard copyButton.isEnabled, step == .edit else { return }
        let leaving = leavingText()
        PostUpdate.copy(leaving.text)
        saved = nil
        say("Copied.", leaving.note)
    }

    @objc func savePressed() {
        guard saveButton.isEnabled, let project else { return }
        let leaving = leavingText()
        switch PostUpdate.save(leaving.text, in: project) {
        case .success(let file):
            saved = URL(fileURLWithPath: canonicalPath(project), isDirectory: true).appendingPathComponent(file)
            say("Saved " + file + ".", leaving.note)
        case .failure(let failure):
            saved = nil
            say(failure.message, leaving.note)
        }
    }

    @objc private func revealPressed() {
        guard let saved, let project else { return }
        // The folder may have been made a link since the save: nothing is shown through one.
        guard HandoffFile.folderIsPlain(UpdateFile.folder, in: canonicalPath(project)) else {
            return say(UpdateFile.Failure.notPlainFolder.message, nil)
        }
        TaskOpen.reveal(saved)
    }

    @objc private func startOverPressed() {
        guard draft != nil else { return }
        guard textView.string != built else { return gather() }
        let alert = NSAlert()
        alert.messageText = "Replace your edits?"
        alert.informativeText = "The draft is built again from today’s handoffs, tasks and commits."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.gather() }
        }
    }

    @objc func sendStepPressed() {
        guard sendStepButton.isEnabled, let project else { return }
        step = .send
        status.stringValue = ""
        if place.stringValue.isEmpty { place.stringValue = PostUpdate.defaultPlace(project: project) }
        fillAgents()
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if UpdateDraft.isTooLong(text) { status.stringValue = PostUpdate.tooLong }
        render()
        window.makeFirstResponder(place.stringValue.isEmpty ? place : agent)
    }

    @objc private func backPressed() {
        step = .edit
        status.stringValue = ""
        render()
        window.makeFirstResponder(textView)
    }

    @objc func cancel() {
        close()
    }

    private func close() {
        if PostUpdateSheet.shown === self { PostUpdateSheet.shown = nil }
        window.sheetParent?.endSheet(window)
    }
}

// MARK: the agent tab

extension PostUpdateSheet {
    /// The window's agent tabs on this Mac, each ready or greyed with why. The one picked stays picked while it is
    /// ready; else the preferred ready tab is picked, and with none ready nothing is.
    func fillAgents() {
        guard let controller else { return }
        choices = PostUpdate.choices(in: controller)
        let stillReady = choices.contains { $0.tab === pickedTab && $0.isReady }
        if !stillReady { pickedTab = TaskAgentRequest.preferred(choices, in: controller)?.tab }
        agent.removeAllItems()
        for (index, choice) in choices.enumerated() {
            agent.addItem(withTitle: choice.title)
            agent.lastItem?.tag = index
            agent.lastItem?.isEnabled = choice.isReady
        }
        if choices.isEmpty {
            agent.addItem(withTitle: "No agent tab")
            agent.lastItem?.isEnabled = false
        } else if let index = choices.firstIndex(where: { $0.tab === pickedTab }) {
            agent.selectItem(withTag: index)
        } else {
            agent.insertItem(withTitle: "No Tab Is Ready", at: 0)
            agent.item(at: 0)?.tag = -1
            agent.item(at: 0)?.isEnabled = false
            agent.selectItem(at: 0)
        }
    }

    @objc private func agentsWillOpen() { fillAgents() }

    @objc private func agentPicked() {
        let tag = agent.selectedTag()
        pickedTab = choices.indices.contains(tag) ? choices[tag].tab : nil
        render()
    }

    /// Types the update into the picked tab, checked once more now; the sheet goes first so the tab takes the keys.
    @objc func sendPressed() {
        fillAgents()
        guard canSend, let tab = pickedTab, let controller else {
            let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            status.stringValue = UpdateDraft.isTooLong(text) ? PostUpdate.tooLong : ""
            return render()
        }
        let leaving = leavingText()
        if let why = TaskAgentRequest.refusal(tab, tasks: 1) { return say(why, leaving.note) }
        let where_ = place.stringValue
        let notice = controller.window
        close()
        if let why = PostUpdate.send(leaving.text, to: where_, into: tab, in: controller) {
            return GitToast.show(why, in: notice)
        }
        let name = SecretMask.current.mask(tab.title)
        let line = "Typed into “\(name)”. Press Return there to send it."
        GitToast.show([line, leaving.note].compactMap { $0 }.joined(separator: " "), in: notice)
    }
}

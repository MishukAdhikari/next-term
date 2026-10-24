import AppKit
import NextTermCore

/// Tasks › Wrap Up…: one sheet in three steps. First the window's agent tabs, each ready one ticked and every other
/// greyed with why; Ask types the fixed handoff request into the ticked ones. Then each asked tab's handoff, waited
/// for with Skip and Keep Waiting. Then the review: each Next item a ticked, editable task for tomorrow, sent only
/// when the user presses Add, through the same planner and sender as Add Task. Cancel posts nothing at any step, and
/// the handoff files stay in the project. All text shown is masked; nothing is logged.
@MainActor
final class WrapUpSheet: NSObject, NSTextFieldDelegate {
    enum Step { case pick, waiting, review }

    private static var shown: WrapUpSheet?
    private let window: NSWindow
    private weak var controller: TerminalWindowController?
    private weak var parent: NSWindow?
    /// nil when the window can't wrap up: no project, or no usable handoff folder; `problem` says why.
    private let wrapUp: WrapUp?
    private let problem: String?
    private(set) var step = Step.pick
    private(set) var review: WrapUpReview?
    private let heading = NSTextField(labelWithString: "Wrap Up")
    private let body = NSStackView()
    private let scroll = NSScrollView()
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    /// Each control's tag points into this: the row, or the section and task, it edits.
    private var refs: [(section: UUID, task: UUID?)] = []
    /// Sections whose file text is open.
    private var opened: Set<UUID> = []
    private var sending = false
    let destination: TaskDestination
    private var facts = DestinationFacts()

    static func present(over controller: TerminalWindowController) {
        guard let parent = controller.window, shown == nil else { return }
        let sheet = WrapUpSheet(controller: controller)
        shown = sheet
        sheet.parent = parent
        parent.beginSheet(sheet.window) { _ in
            if shown === sheet { shown = nil }
        }
        sheet.wrapUp?.start()
    }

    private init(controller: TerminalWindowController) {
        self.controller = controller
        let settings = TaskSettings(defaults: .standard)
        let project = controller.project
        destination = settings.destination(for: project.map(TaskSettings.projectKey))
        if let project, let folder = settings.handoffFolder(for: project) {
            wrapUp = WrapUp(controller: controller, project: project, folder: folder)
            problem = nil
        } else {
            wrapUp = nil
            problem = project == nil
                ? "This window has no project: Wrap Up asks agents for handoffs inside a project."
                : "The handoff folder isn’t a plain folder inside this project. Choose another in Settings › Tasks."
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
        super.init()
        build()
        wrapUp?.changed = { [weak self] in self?.modelChanged() }
        render()
    }

    private func build() {
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.translatesAutoresizingMaskIntoConstraints = false
        let document = WrapUpListView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: document.topAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 120)
        scrollHeight?.isActive = true
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 11)
        primary.target = self
        primary.action = #selector(primaryPressed)
        primary.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancelButton, primary])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [heading, scroll, footer, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [scroll, footer, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 560),
        ])
        window.contentView = content
    }

    private var scrollHeight: NSLayoutConstraint?

    /// The rows fit, up to a height past which the list scrolls.
    private func fit() {
        body.layoutSubtreeIfNeeded()
        let wanted: CGFloat = max(24, body.fittingSize.height)
        let limit: CGFloat = step == .review ? 380 : 260
        scrollHeight?.constant = min(wanted, limit)
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 560, height: content.fittingSize.height))
    }
}

/// A document view that lays out from the top, as a list reads.
private final class WrapUpListView: NSView {
    override var isFlipped: Bool { true }
}

extension WrapUpSheet {
    /// The step as it stands, drawn again.
    private func render() {
        for view in body.arrangedSubviews {
            body.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        refs = []
        guard let wrapUp else {
            body.addArrangedSubview(NSTextField(wrappingLabelWithString: problem ?? ""))
            footer.stringValue = ""
            primary.title = "Close"
            primary.isEnabled = true
            cancelButton.isHidden = true
            return fit()
        }
        switch step {
        case .pick: renderPick(wrapUp)
        case .waiting: renderWaiting(wrapUp)
        case .review: renderReview()
        }
        fit()
    }

    private func renderPick(_ wrapUp: WrapUp) {
        let model = wrapUp.model
        guard !model.rows.isEmpty else {
            body.addArrangedSubview(NSTextField(labelWithString: WrapUpModel.noAgents))
            footer.stringValue = ""
            primary.title = "Close"
            primary.isEnabled = true
            cancelButton.isHidden = true
            return
        }
        cancelButton.isHidden = false
        for row in model.rows {
            let box = NSButton(checkboxWithTitle: "“\(row.title)” (\(row.agent.name))", target: self,
                               action: #selector(tickRow(_:)))
            box.state = row.ticked ? .on : .off
            box.isEnabled = row.isReady
            box.tag = refs.count
            refs.append((row.id, nil))
            let line = NSStackView(views: [box])
            if let reason = row.reason { line.addArrangedSubview(Self.secondary(reason)) }
            body.addArrangedSubview(line)
        }
        footer.stringValue = WrapUpModel.footer(folder: wrapUp.folder)
        primary.title = model.askTitle
        primary.isEnabled = model.canAsk
    }

    private func renderWaiting(_ wrapUp: WrapUp) {
        let model = wrapUp.model
        for row in model.askedRows {
            let name = NSTextField(labelWithString: "“\(row.title)” (\(row.agent.name))")
            let line = NSStackView(views: [name, Self.secondary(row.phaseText ?? "")])
            if row.canKeepWaiting { line.addArrangedSubview(button("Keep Waiting", #selector(keepWaiting(_:)), row.id)) }
            if row.canSkip { line.addArrangedSubview(button("Skip", #selector(skipRow(_:)), row.id)) }
            body.addArrangedSubview(line)
        }
        footer.stringValue = model.isWaiting
            ? "Review opens with the handoffs written so far; the rest are skipped."
            : "Every asked agent has answered or was skipped."
        primary.title = "Review"
        primary.isEnabled = model.canReview
    }

    /// A small button whose tag points at `section` (and `task`) in `refs`.
    private func button(_ title: String, _ action: Selector, _ section: UUID, _ task: UUID? = nil) -> NSButton {
        let made = NSButton(title: title, target: self, action: action)
        made.controlSize = .small
        made.bezelStyle = .rounded
        made.tag = refs.count
        refs.append((section, task))
        return made
    }

    static func secondary(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        return label
    }

    private func ref(_ sender: NSControl) -> (section: UUID, task: UUID?)? {
        refs.indices.contains(sender.tag) ? refs[sender.tag] : nil
    }

    /// The timer saw a change. The review is drawn only on the user's own edits, so typing is never interrupted.
    private func modelChanged() {
        guard step != .review else { return }
        render()
    }

    @objc private func tickRow(_ sender: NSButton) {
        guard let id = ref(sender)?.section else { return }
        wrapUp?.setTicked(id, sender.state == .on)
        render()
    }

    @objc private func keepWaiting(_ sender: NSButton) {
        guard let id = ref(sender)?.section else { return }
        wrapUp?.keepWaiting(id)
        render()
    }

    @objc private func skipRow(_ sender: NSButton) {
        guard let id = ref(sender)?.section else { return }
        wrapUp?.skip(id)
        render()
    }

    @objc private func primaryPressed() {
        guard let wrapUp else { return close() }
        switch step {
        case .pick:
            guard !wrapUp.model.rows.isEmpty else { return close() }
            guard wrapUp.model.canAsk else { return }
            wrapUp.ask()
            step = .waiting
            render()
        case .waiting:
            guard wrapUp.model.canReview else { return }
            wrapUp.stopWaiting()
            review = WrapUpReview(rows: wrapUp.model.rows, reads: wrapUp.reads)
            step = .review
            readFacts()
            render()
        case .review:
            add()
        }
    }

    @objc private func cancel() {
        guard !sending else { return }
        close()
    }

    /// The timer stops with the sheet: a handoff written afterwards changes nothing.
    private func close() {
        guard Self.shown === self else { return }
        wrapUp?.stop()
        wrapUp?.changed = nil
        Self.shown = nil
        parent?.endSheet(window)
    }
}

extension WrapUpSheet {
    /// One section per asked tab: its title and file, Show File and Reveal, the reason when there are no tasks from
    /// it, its tasks, and Add Row.
    private func renderReview() {
        guard let review else { return }
        cancelButton.isHidden = false
        // Return ends a title's editing; Add takes ⌘↩, as the Add Task sheet's does.
        primary.keyEquivalentModifierMask = [.command]
        for section in review.sections {
            let title = NSTextField(labelWithString: "“\(section.title)”")
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            let head = NSStackView(views: [title])
            if let file = section.file { head.addArrangedSubview(Self.secondary(file)) }
            if section.raw != nil, !section.showsText {
                let shown = opened.contains(section.id)
                head.addArrangedSubview(button(shown ? "Hide File" : "Show File", #selector(toggleFile(_:)), section.id))
            }
            if section.file != nil, section.raw != nil {
                head.addArrangedSubview(button("Reveal", #selector(reveal(_:)), section.id))
            }
            body.addArrangedSubview(head)
            if let note = section.note { body.addArrangedSubview(Self.secondary(note)) }
            if section.truncated { body.addArrangedSubview(Self.secondary("Only the start of a long file was read.")) }
            if let raw = section.raw, section.showsText || opened.contains(section.id) {
                body.addArrangedSubview(Self.fileText(raw))
            }
            for task in section.tasks { body.addArrangedSubview(taskRow(task, in: section.id)) }
            body.addArrangedSubview(button("Add Row", #selector(addRow(_:)), section.id))
        }
        updateReviewState()
    }

    /// A task: ticked, its title editable, its day, and where it goes.
    private func taskRow(_ task: WrapUpReview.Task, in section: UUID) -> NSView {
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(tickTask(_:)))
        box.state = task.ticked ? .on : .off
        box.tag = refs.count
        refs.append((section, task.id))
        let field = NSTextField(string: task.title)
        field.placeholderString = "What to do"
        field.delegate = self
        field.tag = refs.count
        refs.append((section, task.id))
        field.setAccessibilityLabel("Task")
        field.widthAnchor.constraint(equalToConstant: 270).isActive = true
        let when = NSPopUpButton()
        for choice in WrapUpReview.When.allCases {
            when.addItem(withTitle: choice.title)
            when.lastItem?.tag = choice.rawValue
        }
        when.selectItem(withTag: task.when.rawValue)
        when.controlSize = .small
        when.target = self
        when.action = #selector(whenChanged(_:))
        when.setAccessibilityLabel("When")
        let whenRef = refs.count
        refs.append((section, task.id))
        when.tag = whenRef
        let place = Self.secondary(DestinationChoices.name(destination))
        return NSStackView(views: [box, field, when, place])
    }

    /// The masked file text, read-only and selectable.
    static func fileText(_ text: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.string = text
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.borderType = .bezelBorder
        let lines: CGFloat = CGFloat(min(12, text.split(separator: "\n", omittingEmptySubsequences: false).count))
        scroll.heightAnchor.constraint(equalToConstant: min(160, max(48, lines * 14 + 10))).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return scroll
    }

    /// The count on Add, and the line that says where the tasks go, from the plan Add would use now.
    private func updateReviewState() {
        guard let review else { return }
        primary.title = review.addTitle
        guard review.canAdd else {
            primary.isEnabled = false
            footer.stringValue = "Tick a task to add it. Nothing is posted until you press Add."
            footer.textColor = .secondaryLabelColor
            return
        }
        let all = drafts()
        if opensPages(all.count) {
            footer.stringValue = sending ? "Sending…" : "Opens \(all.count), \(DestinationPlan.pagesAtOnce) at a time: "
                + "nothing is created until you press Create there."
            footer.textColor = .secondaryLabelColor
            primary.isEnabled = !sending
            return
        }
        let made = plan(all, looking: false)
        footer.stringValue = sending ? "Sending…" : made.plan.line
        footer.textColor = made.plan.refused && !sending ? Theme.failed : .secondaryLabelColor
        primary.isEnabled = made.plan.canAdd && !sending
    }

    @objc func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let ref = ref(field), let task = ref.task else { return }
        review?.setTitle(ref.section, task, field.stringValue)
        updateReviewState()
    }

    @objc private func tickTask(_ sender: NSButton) {
        guard let ref = ref(sender), let task = ref.task else { return }
        review?.setTicked(ref.section, task, sender.state == .on)
        updateReviewState()
    }

    @objc private func whenChanged(_ sender: NSPopUpButton) {
        guard let ref = ref(sender), let task = ref.task,
              let when = WrapUpReview.When(rawValue: sender.selectedTag()) else { return }
        review?.setWhen(ref.section, task, when)
        updateReviewState()
    }

    @objc private func addRow(_ sender: NSButton) {
        guard let section = ref(sender)?.section else { return }
        review?.addRow(section)
        render()
    }

    @objc private func toggleFile(_ sender: NSButton) {
        guard let section = ref(sender)?.section else { return }
        if opened.contains(section) { opened.remove(section) } else { opened.insert(section) }
        render()
    }

    @objc private func reveal(_ sender: NSButton) {
        guard let section = ref(sender)?.section, let wrapUp,
              let file = review?.sections.first(where: { $0.id == section })?.file else { return }
        TaskOpen.reveal(wrapUp.url(file))
    }
}

extension WrapUpSheet {
    /// The review's ticked tasks, as Add would send them now.
    private func drafts(now: Date = Date()) -> [TaskDraft] {
        review?.drafts(now: now, calendar: .current, contexts: wrapUp?.contexts ?? [:]) ?? []
    }

    /// The agent tab Through your agent types into: the one Send to Agent would use when ready, else the first ready.
    private var agentChoice: TaskAgentRequest.Choice? {
        guard destination.kind == .throughAgent, let controller else { return nil }
        return TaskAgentRequest.preferred(TaskAgentRequest.choices(in: controller), in: controller)
    }

    /// The one planner's plan, with the first task's day in its line.
    private func plan(_ drafts: [TaskDraft], looking: Bool, now: Date = Date()) -> TaskDestinations.Planned {
        var facts = self.facts
        facts.agentTab = agentChoice?.facts
        let first = review?.sections.flatMap(\.tasks).first { $0.ticked && !$0.title.isEmpty }
        if let first, let choice = AddTaskSheet.Choice(rawValue: first.when.rawValue) {
            facts.day = AddTaskSheet.dayWords(first.when.scheduled(now: now, calendar: .current), choice: choice)
        }
        return TaskDestinations.plan(drafts, to: destination, project: wrapUp?.project, facts: facts, now: now,
                                     looking: looking)
    }

    /// The destination opens one page or Quick Add per task and these are more than it opens at once: Add asks once,
    /// then opens them a handful at a time.
    private func opensPages(_ count: Int) -> Bool {
        guard count > DestinationPlan.pagesAtOnce else { return false }
        switch destination.kind {
        case .todoist, .omnifocus, .github, .gitlab, .linear, .trello, .azureBoards: return true
        case .todoFolder, .reminders, .things, .shortcut, .throughAgent: return false
        }
    }

    /// What only the app knows, read once as the review opens: the apps installed and where Reminders stands.
    private func readFacts() {
        let apps: [TaskLink.Kind] = [.things, .todoist, .omnifocus]
        facts.installed = Set(apps.filter { TaskOpen.installed($0) })
        facts.reminders = TaskReminders.step
        if case .reminders = destination {
            TaskReminders.makesList(destination) { [weak self] makes in
                self?.facts.makesList = makes
                self?.updateReviewState()
            }
        }
    }

    private func add() {
        guard let review, review.canAdd, !sending else { return }
        let now = Date()
        let all = drafts(now: now)
        let pages = opensPages(all.count)
        let whole = plan(all, looking: true, now: now)
        guard pages || whole.plan.canAdd else { return updateReviewState() }
        if let tab = agentChoice?.tab, let why = TaskAgentRequest.refusal(tab, tasks: all.count) {
            footer.stringValue = why
            footer.textColor = Theme.failed
            return
        }
        TaskDestinations.duplicate(whole) { [weak self] title in
            guard let self, Self.shown === self else { return }
            guard let title else { return self.confirmPages(all, pages: pages, now: now) }
            // The same task sent the same way within the last minute: asked, not sent twice by a double press.
            let alert = NSAlert()
            alert.messageText = "Added a minute ago. Add again?"
            let place = whole.files.first?.shownFolder ?? DestinationChoices.name(self.destination)
            alert.informativeText = "“\(title)” went to \(place) less than a minute ago."
            alert.addButton(withTitle: "Add Again")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: self.window) { [weak self] response in
                MainActor.assumeIsolated {
                    if response == .alertFirstButtonReturn { self?.confirmPages(all, pages: pages, now: now) }
                }
            }
        }
    }

    /// More pages than open at once: asked once, "Open 7 pages in your browser?".
    private func confirmPages(_ drafts: [TaskDraft], pages: Bool, now: Date) {
        guard pages else { return send(drafts[...], now: now) }
        let alert = NSAlert()
        let app = destination.kind == .todoist || destination.kind == .omnifocus
        alert.messageText = app ? "Open \(drafts.count) Quick Add windows?" : "Open \(drafts.count) pages in your browser?"
        alert.informativeText = app
            ? "Each task opens in its own Quick Add; nothing is added until you press Add there."
            : "Each task opens its own page; nothing is created until you press Create there."
        alert.addButton(withTitle: app ? "Open \(drafts.count) Windows" : "Open \(drafts.count) Pages")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { self?.send(drafts[...], now: now) }
            }
        }
    }

    /// Hands the tasks to the one sender, a handful at a time for pages. The sheet closes once all went; a failure
    /// keeps it open with the line, and what went already stays sent.
    private func send(_ drafts: ArraySlice<TaskDraft>, now: Date) {
        guard !drafts.isEmpty else {
            sending = false
            return close()
        }
        let size: Int = opensPages(drafts.count) ? DestinationPlan.pagesAtOnce : drafts.count
        let chunk: [TaskDraft] = Array(drafts.prefix(size))
        let made = plan(chunk, looking: true, now: now)
        sending = true
        updateReviewState()
        let place = TaskDestinations.Place(sheet: window, controller: controller, tab: agentChoice?.tab)
        TaskDestinations.send(made, at: place) { [weak self] outcome in
            guard let self, Self.shown === self else { return }
            switch outcome {
            case .done: self.send(drafts.dropFirst(size), now: now)
            case .cancelled:
                self.sending = false
                self.updateReviewState()
            case .failed(let line):
                self.sending = false
                self.updateReviewState()
                self.footer.stringValue = line
                self.footer.textColor = Theme.failed
            }
        }
    }
}

#if DEBUG
extension WrapUpSheet {
    // MARK: for the self-test

    static var current: WrapUpSheet? { shown }
    var model: WrapUpModel? { wrapUp?.model }
    var primaryTitle: String { primary.title }
    var primaryEnabled: Bool { primary.isEnabled }
    var footerText: String { footer.stringValue }
    var timerRunning: Bool { wrapUp?.isRunning ?? false }
    func pressPrimary() { if primary.isEnabled { primaryPressed() } }
    func pressCancel() { cancel() }
    func tick() { wrapUp?.tick() }
    func setTicked(_ id: UUID, _ on: Bool) {
        wrapUp?.setTicked(id, on)
        render()
    }
    func setTitle(section: UUID, task: UUID, _ text: String) {
        review?.setTitle(section, task, text)
        render()
    }
    func addRow(section: UUID) {
        review?.addRow(section)
        render()
    }
}
#endif

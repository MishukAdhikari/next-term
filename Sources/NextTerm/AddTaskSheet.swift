import AppKit
import NextTermCore

/// Tasks › Add Task…: a prompt becomes a task by TaskDraft's rules (the first line is the task, list lines its steps,
/// the rest notes), and Add (⌘↩) sends it where the Destination popup says: the project's destination unless changed
/// for this Add, which saves nothing. Esc cancels. The prompt starts as the terminal's selection, else the editor's,
/// else the question an agent waits on. The line under Destination says exactly where the task goes before anything
/// leaves, and What's sent shows the exact masked text Add hands over; both come from the plan Add itself uses.
@MainActor
final class AddTaskSheet: NSObject, NSTextViewDelegate {
    /// When the task is planned for, as the When menu offers it.
    enum Choice: Int, CaseIterable {
        case today, tomorrow, nextWeek, noDate, date

        var title: String {
            switch self {
            case .today: return "Today"
            case .tomorrow: return "Tomorrow"
            case .nextWeek: return "Next Week"
            case .noDate: return "No Date"
            case .date: return "Choose Date…"
            }
        }
    }

    private static var shown: AddTaskSheet?
    private let window: NSWindow
    private let prompt: NSTextView
    private let when = NSPopUpButton()
    private let date = NSDatePicker()
    private let whereYouAre = NSButton(checkboxWithTitle: "Include where you are (project, branch, tab, agent)", target: nil, action: nil)
    /// "Finish the login fix · 2 steps · notes · Tomorrow, Fri 16 Oct".
    private let summary = NSTextField(labelWithString: "")
    /// "Saves to todo/2026-10-15-finish-the-login-fix.md in next-term".
    private let place = NSTextField(labelWithString: "")
    private var addButton: NSButton!
    private weak var controller: TerminalWindowController?
    private weak var parent: NSWindow?
    private var views: AddTaskDestinationViews!
    /// Where the project's tasks go, as Settings says; the popup's first row.
    private var projectDestination: TaskDestination = .todoFolder
    /// Where this Add goes.
    private var chosen: TaskDestination = .todoFolder
    /// The popup is on "(this project’s)": a change saved meanwhile moves this Add with it. Any other row the user
    /// picked stays, whatever is saved.
    private var followsProject = true
    private var rows: [DestinationChoices.Row] = []
    private var agents: [TaskAgentRequest.Choice] = []
    private var facts = DestinationFacts()
    /// The plan the line and What's sent show now.
    private var planned: TaskDestinations.Planned?
    /// Add was pressed and the destination has not answered yet.
    private var sending = false
    /// What's sent opened by itself once for a cut text.
    private var openedForCut = false
    private var keyObserver: NSObjectProtocol?
    /// The agent tab picked for Through your agent.
    private weak var pickedTab: TerminalTab?
    /// Where you are, read once as the sheet opens: the branch, the tab and its agent.
    private let context: TaskContext
    private let project: String?

    static func present(over controller: TerminalWindowController) {
        guard let parent = controller.window, shown == nil else { return }
        let sheet = AddTaskSheet(controller: controller, text: prefill(controller))
        shown = sheet
        sheet.parent = parent
        parent.beginSheet(sheet.window) { _ in
            if shown === sheet { shown = nil }
        }
        sheet.window.makeFirstResponder(sheet.prompt)
    }

    /// The text the prompt starts with: the terminal's selection, else the editor's, else the question an agent waits on.
    static func prefill(_ controller: TerminalWindowController) -> String {
        if let tab = controller.terminalSelectionToSend, let text = tab.view.getSelection(),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let editor = controller.editorArea.activeEditor {
            let range = editor.textView.selectedRange()
            if range.length > 0 { return (editor.textView.string as NSString).substring(with: range) }
        }
        return controller.agentTab?.status.question ?? ""
    }

    private init(controller: TerminalWindowController, text: String) {
        self.controller = controller
        project = controller.project
        // The agent you are in, or the one Send to Agent would type into; else the tab in front.
        let tab = controller.agentTab ?? controller.activeTab
        context = TaskWriter.context(of: tab, in: controller, addedBy: TaskContext.you, whereYouAre: true)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        prompt = scroll.documentView as! NSTextView
        super.init()

        let title = NSTextField(labelWithString: "Add Task")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        prompt.string = text
        prompt.font = .systemFont(ofSize: 13)
        prompt.isRichText = false
        prompt.allowsUndo = true
        prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        prompt.isAutomaticTextReplacementEnabled = false
        prompt.textContainerInset = NSSize(width: 6, height: 6)
        prompt.delegate = self
        prompt.setAccessibilityLabel("What to do")
        prompt.toolTip = "The first line is the task; lines starting -, * or 1. are its steps; the rest are notes. A prompt that is only a list adds one task per item."
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        for choice in Choice.allCases {
            if choice == .date { when.menu?.addItem(.separator()) }
            when.addItem(withTitle: choice.title)
            when.lastItem?.tag = choice.rawValue
        }
        when.selectItem(withTag: Choice.tomorrow.rawValue)
        when.target = self
        when.action = #selector(choiceChanged)
        when.setAccessibilityLabel("When")
        when.toolTip = "The day the task is planned for, never a deadline. Next Week is the coming first day of the week."
        date.datePickerElements = .yearMonthDay
        date.datePickerStyle = .textFieldAndStepper
        date.minDate = Calendar.current.startOfDay(for: Date())
        date.dateValue = When.days(1, after: Date(), calendar: .current).start(in: .current) ?? Date()
        date.isHidden = true
        date.target = self
        date.action = #selector(updateState)
        date.setAccessibilityLabel("Date")
        let whenRow = NSStackView(views: [NSTextField(labelWithString: "When:"), when, date])
        whenRow.spacing = 8

        whereYouAre.state = TaskSettings(defaults: .standard).includeContext ? .on : .off
        whereYouAre.target = self
        whereYouAre.action = #selector(updateState)
        whereYouAre.toolTip = "The branch, the tab’s title, its agent and the command that resumes the agent’s session go in the file, "
            + "so tomorrow’s session can pick up where you were."

        for label in [summary, place] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            Typography.singleLine(label, truncation: .byTruncatingMiddle)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        addButton = NSButton(title: "Add Task", target: self, action: #selector(add))
        addButton.keyEquivalent = "\r"
        addButton.keyEquivalentModifierMask = .command
        addButton.toolTip = "⌘↩"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, addButton])
        buttons.spacing = 8

        views = AddTaskDestinationViews(target: self, destinationChanged: #selector(destinationChanged),
                                        agentChanged: #selector(agentChanged), useTodoFolder: #selector(useTodoFolder),
                                        toggleSent: #selector(toggleSent), choose: #selector(chooseOffer),
                                        dismissOffer: #selector(dismissOffer))
        let placeRow = NSStackView(views: [place, views.useTodoFolder])
        placeRow.spacing = 6
        let stack = NSStackView(views: [title, scroll, whenRow, views.destinationRow, views.agentRow, whereYouAre, summary,
                                        placeRow, views.sentRow, views.sentScroll, views.offerRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: summary)
        stack.setCustomSpacing(4, after: placeRow)
        stack.setCustomSpacing(4, after: views.sentRow)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        for view in [scroll, summary, placeRow, views.sentScroll, views.offerRow, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = stack
        let settings = TaskSettings(defaults: .standard)
        projectDestination = settings.destination(for: project.map(TaskSettings.projectKey))
        chosen = projectDestination
        views.offerRow.isHidden = !AddTaskOffer.shows(project: project)
        readFacts()
        fillDestinations()
        fillAgents()
        updateState()
        fitWindow()
        // Apps, permissions and agent tabs change while the sheet is open: they are read again when it is in front.
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(agentsWillOpen),
                                               name: NSPopUpButton.willPopUpNotification, object: views.agent)
        // Send Tasks To ▸ changed where the project's tasks go: a popup still on "(this project’s)" follows it.
        NotificationCenter.default.addObserver(self, selector: #selector(destinationSaved),
                                               name: .taskDestinationChanged, object: nil)
    }

    @objc private func destinationSaved() { refresh() }

    func textDidChange(_ notification: Notification) { updateState() }

    @objc private func choiceChanged() {
        date.isHidden = when.selectedTag() != Choice.date.rawValue
        updateState()
    }

    /// The day chosen, by the calendar of this Mac.
    private func scheduled(now: Date = Date()) -> TaskDraft.Scheduled {
        let calendar = Calendar.current
        switch Choice(rawValue: when.selectedTag()) ?? .tomorrow {
        case .today: return .day(TaskDay(now, calendar: calendar))
        case .tomorrow: return .day(When.days(1, after: now, calendar: calendar))
        case .nextWeek: return .day(When.nextWeek(after: now, calendar: calendar))
        case .noDate: return .none
        case .date: return .day(TaskDay(date.dateValue, calendar: calendar))
        }
    }

    /// The tasks the prompt makes now, each with the day and where you are; stored keys masked.
    private func drafts(now: Date = Date()) -> [TaskDraft] {
        let day = scheduled(now: now)
        let said = whereYouAre.state == .on ? context : TaskContext(addedBy: TaskContext.you)
        return TaskDraft.drafts(prompt: prompt.string) { SecretMask.current.mask($0) }.map { draft in
            var draft = draft
            draft.scheduled = day
            draft.context = said
            return draft
        }
    }

    /// "Tomorrow, Fri 16 Oct", "No date".
    private static func describe(_ scheduled: TaskDraft.Scheduled, choice: Choice) -> String {
        guard case .day(let day) = scheduled, let start = day.start(in: .current) else { return "No date" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        let shown = formatter.string(from: start)
        switch choice {
        case .today, .tomorrow, .nextWeek: return choice.title + ", " + shown
        case .noDate, .date: return shown
        }
    }

    @objc private func updateState() {
        let drafts = drafts()
        let choice = Choice(rawValue: when.selectedTag()) ?? .tomorrow
        place.textColor = .secondaryLabelColor
        guard let first = drafts.first else {
            summary.stringValue = "Write what to do: the first line is the task, lines starting - its steps."
            place.stringValue = ""
            addButton.isEnabled = false
            views.sentText.string = ""
            views.useTodoFolder.isHidden = true
            planned = nil
            return
        }
        var parts = drafts.count == 1 ? [first.title] : ["Adds \(drafts.count) tasks"]
        if drafts.count == 1 {
            if !first.steps.isEmpty { parts.append(first.steps.count == 1 ? "1 step" : "\(first.steps.count) steps") }
            if !first.notes.isEmpty { parts.append("notes") }
        }
        parts.append(Self.describe(first.scheduled, choice: choice))
        if drafts.contains(where: \.masked) { parts.append("A stored key shows as •••") }
        summary.stringValue = parts.joined(separator: " · ")
        facts.day = Self.dayWords(first.scheduled, choice: choice)
        facts.agentTab = pickedAgent?.facts
        let made = TaskDestinations.plan(drafts, to: chosen, project: project, facts: facts)
        show(made)
    }

    /// The line, What's sent, Use Todo Folder and Add, from the plan Add would use now.
    private func show(_ made: TaskDestinations.Planned) {
        planned = made
        let plan = made.plan
        place.stringValue = sending ? "Sending…" : plan.line
        place.textColor = plan.refused && !sending ? Theme.failed : .secondaryLabelColor
        views.useTodoFolder.isHidden = !plan.offersTodoFolder
        views.sentText.string = plan.sent
        addButton.title = plan.addTitle
        addButton.isEnabled = plan.canAdd && !sending
        // A cut is seen before Add: What's sent opens by itself the first time.
        if plan.cut && !openedForCut {
            openedForCut = true
            if views.sentToggle.state != .on { setSentOpen(true) }
        }
    }

    /// A line in red that Add brought back: nothing more was sent.
    private func refuse(_ line: String) {
        place.stringValue = line
        place.textColor = Theme.failed
    }

    /// "Tomorrow, Sat 19 Oct" for the line; nil for No Date.
    private static func dayWords(_ scheduled: TaskDraft.Scheduled, choice: Choice) -> String? {
        guard case .day = scheduled else { return nil }
        return describe(scheduled, choice: choice)
    }

    /// Why a task can't be added from this window, for the sheet.
    static func sentence(_ refusal: TaskWriter.Refusal) -> String {
        switch refusal {
        case .noProject: return "This window has no project: choose a folder for tasks outside projects in Settings › Tasks."
        case .missing(let folder): return "The todo folder \(folder) is not there (an unmounted disk?)."
        case .unusable(let why): return why
        }
    }

    // MARK: the destination

    /// The agent tab picked, as it stands now, while Through your agent is chosen.
    private var pickedAgent: TaskAgentRequest.Choice? {
        guard chosen.kind == .throughAgent, let tab = pickedTab,
              let listed = agents.first(where: { $0.tab === tab }) else { return nil }
        return TaskAgentRequest.Choice(tab: tab, agent: listed.agent, verdict: AgentReadiness.shared.check(tab))
    }

    /// What only the app knows: the apps installed, where Reminders stands, and whether Add makes the list. Nothing
    /// is launched, nothing is asked, and no Process starts: a shortcut is looked for only once one is chosen.
    private func readFacts() {
        let apps: [TaskLink.Kind] = [.things, .todoist, .omnifocus]
        facts.installed = Set(apps.filter { TaskOpen.installed($0) })
        facts.reminders = TaskReminders.step
        lookUpChosen()
    }

    /// The facts that need a moment: whether Add makes the Reminders list, and whether the shortcut is still there.
    private func lookUpChosen() {
        let destination = chosen
        if case .reminders = destination {
            TaskReminders.makesList(destination) { [weak self] makes in
                guard let self, self.chosen == destination else { return }
                self.facts.makesList = makes
                self.updateState()
            }
        }
    }

    /// The popup's rows: this project's destination first, then every kind.
    private func fillDestinations() {
        let settings = TaskSettings(defaults: .standard)
        rows = DestinationChoices.rows(current: projectDestination, default: settings.defaultDestination,
                                       inProject: project != nil, facts: facts)
        let selected = rows.firstIndex { $0.action == .use(chosen) } ?? 0
        views.fill(rows, selected: selected, setUp: #selector(setUpDestinations), target: self)
        views.agentRow.isHidden = chosen.kind != .throughAgent
    }

    /// The window's agent tabs, each ready or greyed with why. The one picked stays picked while it is ready; else
    /// the preferred ready tab is picked, and with none ready nothing is.
    private func fillAgents() {
        guard let controller, chosen.kind == .throughAgent else { return }
        agents = TaskAgentRequest.choices(in: controller)
        let stillReady = agents.contains { $0.tab === pickedTab && $0.isReady }
        if !stillReady { pickedTab = TaskAgentRequest.preferred(agents, in: controller)?.tab }
        views.fill(agents, selected: agents.firstIndex { $0.tab === pickedTab })
    }

    /// The sheet is in front again: apps, permissions, settings and tabs are read again.
    private func refresh() {
        guard !sending else { return }
        let settings = TaskSettings(defaults: .standard)
        let now = settings.destination(for: project.map(TaskSettings.projectKey))
        projectDestination = now
        guard followsProject, chosen != now else {
            readFacts()
            fillDestinations()
            fillAgents()
            updateState()
            return
        }
        readFacts()
        choose(now, followsProject: true)
    }

    /// This Add goes to `destination`; nothing is saved. What was looked up for the last choice is looked up again.
    private func choose(_ destination: TaskDestination, followsProject: Bool = false) {
        self.followsProject = followsProject
        chosen = destination
        facts.makesList = nil
        facts.shortcutListed = nil
        lookUpChosen()
        if case .shortcut(let id, _) = destination {
            TaskShortcut.isListed(id) { [weak self] listed in
                guard let self, self.chosen == destination else { return }
                self.facts.shortcutListed = listed
                self.updateState()
            }
        }
        fillDestinations()
        fillAgents()
        updateState()
        fitWindow()
    }

    @objc private func destinationChanged() {
        let tag = views.destination.selectedTag()
        guard rows.indices.contains(tag) else { return }
        switch rows[tag].action {
        case .use(let destination): choose(destination, followsProject: tag == 0)
        case .setUp: setUpDestinations()
        }
    }

    /// Settings › Tasks, with the sheet left open and its choice as it was.
    @objc private func setUpDestinations() {
        fillDestinations()
        AppDelegate.shared.showSettings(tab: "tasks")
    }

    @objc private func agentChanged() {
        let tag = views.agent.selectedTag()
        if agents.indices.contains(tag) { pickedTab = agents[tag].tab }
        updateState()
    }

    @objc private func agentsWillOpen() { fillAgents() }

    @objc private func useTodoFolder() { choose(.todoFolder) }

    @objc private func toggleSent() { setSentOpen(views.sentToggle.state == .on) }

    private func setSentOpen(_ open: Bool) {
        views.showSent(open)
        fitWindow()
    }

    private func fitWindow() {
        guard let content = window.contentView else { return }
        window.setContentSize(NSSize(width: 520, height: content.fittingSize.height))
    }

    // MARK: the first-time offer

    @objc private func chooseOffer() {
        let things = facts.installed.contains(.things)
        AddTaskOffer.choose(over: window, thingsInstalled: things) { [weak self] choice in
            guard let self, let choice else { return }
            AddTaskOffer.markDone()
            self.views.offerRow.isHidden = true
            switch choice {
            case .reminders:
                let reminders = TaskDestination.reminders(listID: nil, listName: DestinationChoices.remindersList)
                self.adopt(reminders)
                // Next Term explains before macOS asks, now rather than at the first Add.
                TaskReminders.allow(from: self.window) { [weak self] _ in self?.refresh() }
            case .things: self.adopt(.things(list: nil))
            case .todoFolder: self.adopt(.todoFolder)
            case .shortcut, .more: AppDelegate.shared.showSettings(tab: "tasks")
            }
            self.fitWindow()
        }
    }

    /// `destination` becomes the default, and this Add goes there.
    private func adopt(_ destination: TaskDestination) {
        AddTaskOffer.makeDefault(destination)
        projectDestination = TaskSettings(defaults: .standard).destination(for: project.map(TaskSettings.projectKey))
        choose(destination, followsProject: destination == projectDestination)
    }

    @objc private func dismissOffer() {
        AddTaskOffer.markDone()
        views.offerRow.isHidden = true
        fitWindow()
    }

    // MARK: adding

    @objc private func add() {
        guard !sending else { return }
        let now = Date()
        facts.agentTab = pickedAgent?.facts
        let made = TaskDestinations.plan(drafts(now: now), to: chosen, project: project, facts: facts, now: now,
                                         looking: true)
        show(made)
        guard made.plan.canAdd, !made.drafts.isEmpty else { return }
        // The tab is asked again at this moment: it may have started working since the sheet opened.
        if let tab = pickedAgent?.tab, chosen.kind == .throughAgent,
           let why = TaskAgentRequest.refusal(tab, tasks: made.drafts.count) {
            return refuse(why)
        }
        TaskDestinations.duplicate(made) { [weak self] title in
            guard let self, Self.shown === self else { return }
            guard let title else { return self.send(made) }
            // The same task sent the same way within the last minute: asked, not sent twice by a double press.
            let alert = NSAlert()
            alert.messageText = "Added a minute ago. Add again?"
            let place = made.files.first?.shownFolder ?? DestinationChoices.name(self.chosen)
            alert.informativeText = "“\(title)” went to \(place) less than a minute ago."
            alert.addButton(withTitle: "Add Again")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: self.window) { [weak self] response in
                MainActor.assumeIsolated {
                    if response == .alertFirstButtonReturn { self?.send(made) }
                }
            }
        }
    }

    /// Hands the plan to the one sender. The sheet closes when it says done; a failure keeps it open with the line.
    private func send(_ made: TaskDestinations.Planned) {
        sending = true
        show(made)
        let where_ = TaskDestinations.Place(sheet: window, controller: controller, tab: pickedAgent?.tab)
        TaskDestinations.send(made, at: where_) { [weak self] outcome in
            // Only this sheet's own send answers here; a sheet that is gone takes no answer.
            guard let self, Self.shown === self else { return }
            self.sending = false
            switch outcome {
            case .done: self.close()
            case .cancelled: self.updateState()
            case .failed(let line):
                self.updateState()
                self.refuse(line)
            }
        }
    }

    @objc private func cancel() {
        guard sending else { return close() }
        // A shortcut still running is stopped; the line then says nothing more was sent. Any other send is already
        // with Reminders or the app and answers in a moment: the sheet waits for it, so a failure is still seen here.
        if chosen.kind == .shortcut { TaskShortcut.stop() }
    }

    private func close() {
        guard Self.shown === self else { return }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        NotificationCenter.default.removeObserver(self)
        Self.shown = nil
        parent?.endSheet(window)
    }

    // MARK: for the self-test

    static var current: AddTaskSheet? { shown }
    var promptText: String { prompt.string }
    var summaryText: String { summary.stringValue }
    var placeText: String { place.stringValue }
    var canAdd: Bool { addButton.isEnabled }
    func type(_ text: String) {
        prompt.string = text
        updateState()
    }
    func choose(_ choice: Choice) {
        when.selectItem(withTag: choice.rawValue)
        choiceChanged()
    }
    func setWhereYouAre(_ on: Bool) {
        whereYouAre.state = on ? .on : .off
        updateState()
    }
    func pressAdd() { if addButton.isEnabled { add() } }
    var addTitle: String { addButton.title }
    var sentText: String { views.sentText.string }
    var whatsSentOpen: Bool { !views.sentScroll.isHidden }
    var placeIsRed: Bool { place.textColor == Theme.failed }
    var destinationTitles: [String] { rows.map(\.title) }
    var agentTitles: [String] { views.agentRow.isHidden ? [] : agents.map(\.title) }
    var offerShown: Bool { !views.offerRow.isHidden }
    var chosenDestination: TaskDestination { chosen }
    /// Picks the popup's row with this title, as a click on it does.
    func pickDestination(titled title: String) {
        guard let index = rows.firstIndex(where: { $0.title == title }) else { return }
        views.destination.selectItem(withTag: index)
        destinationChanged()
    }
    func pickDestination(_ destination: TaskDestination) { choose(destination) }
    func pickAgent(_ tab: TerminalTab) {
        fillAgents()
        guard let index = agents.firstIndex(where: { $0.tab === tab }) else { return }
        views.agent.selectItem(withTag: index)
        agentChanged()
    }
    func pressUseTodoFolder() { useTodoFolder() }
    func pressChooseOffer() { chooseOffer() }
    func pressDismissOffer() { dismissOffer() }
    func reread() { refresh() }
    func pressCancel() { cancel() }
    /// What the question over the sheet says ("Added a minute ago. Add again?"), while one is up.
    var askingAgain: String? {
        guard let alert = window.attachedSheet?.contentView else { return nil }
        func labels(_ view: NSView) -> [String] { ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(labels) }
        return labels(alert).joined(separator: "\n")
    }
    func answerAgain(_ add: Bool) {
        guard let alert = window.attachedSheet else { return }
        window.endSheet(alert, returnCode: add ? .alertFirstButtonReturn : .alertSecondButtonReturn)
    }
    /// The bytes Add writes for the prompt now, at `now`.
    func texts(at now: Date) -> [String] {
        drafts(now: now).compactMap { draft -> String? in
            guard case .success(let plan) = TaskWriter.plan(draft, project: project, created: now, duplicates: false) else { return nil }
            return plan.text
        }
    }
}

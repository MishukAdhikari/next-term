import AppKit
import NextTermCore

/// Tasks › Add Task…: a prompt becomes a task by TaskDraft's rules (the first line is the task, list lines its steps,
/// the rest notes), and Add (⌘↩) saves it as a todo file in the project's todo folder; Esc cancels. The prompt starts
/// as the terminal's selection, else the editor's, else the question an agent waits on. The line under it says what
/// the task will be and where it goes, before anything is written; after, a notice offers Undo.
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
    /// Where you are, read once as the sheet opens: the branch, the tab and its agent.
    private let context: TaskContext
    private let project: String?

    static func present(over controller: TerminalWindowController) {
        guard let parent = controller.window, shown == nil else { return }
        let sheet = AddTaskSheet(controller: controller, text: prefill(controller))
        shown = sheet
        sheet.parent = parent
        parent.beginSheet(sheet.window) { _ in shown = nil }
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

        let stack = NSStackView(views: [title, scroll, whenRow, whereYouAre, summary, place, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: summary)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        for view in [scroll, summary, place, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = stack
        window.setContentSize(NSSize(width: 520, height: stack.fittingSize.height))
        updateState()
    }

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
        switch TaskWriter.plan(first, project: project, duplicates: false) {
        case .success(let plan):
            let folder = plan.resolution.createsFolder ? ", and makes the \(plan.shownFolder.dropLast()) folder" : ""
            let files = drafts.count == 1 ? plan.shown : "\(drafts.count) files in \(plan.shownFolder)"
            place.stringValue = "Saves to " + files + folder
            addButton.isEnabled = true
        case .failure(let refusal):
            place.stringValue = Self.sentence(refusal)
            place.textColor = Theme.failed
            addButton.isEnabled = false
        }
    }

    /// Why a task can't be added from this window, for the sheet.
    static func sentence(_ refusal: TaskWriter.Refusal) -> String {
        switch refusal {
        case .noProject: return "This window has no project: choose a folder for tasks outside projects in Settings › Tasks."
        case .missing(let folder): return "The todo folder \(folder) is not there (an unmounted disk?)."
        case .unusable(let why): return why
        }
    }

    // MARK: adding

    @objc private func add() {
        let now = Date()
        var plans: [TaskWriter.Plan] = []
        for draft in drafts(now: now) {
            switch TaskWriter.plan(draft, project: project, created: now, looking: true) {
            case .success(let plan): plans.append(plan)
            case .failure(let refusal):
                place.stringValue = Self.sentence(refusal)
                place.textColor = Theme.failed
                return
            }
        }
        guard !plans.isEmpty else { return }
        guard let again = plans.first(where: \.duplicate) else { return write(plans) }
        // The same title in this folder within the last minute: asked, not added twice by a double press.
        let alert = NSAlert()
        alert.messageText = "Added a minute ago. Add again?"
        alert.informativeText = "“\(again.draft.title)” went to \(again.shownFolder) less than a minute ago."
        alert.addButton(withTitle: "Add Again")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { self?.write(plans) }
            }
        }
    }

    private func write(_ plans: [TaskWriter.Plan]) {
        var files: [(url: URL, text: String)] = []
        var madeFolder: URL?
        var failure: Error?
        for plan in plans {
            do {
                let written = try TaskWriter.write(plan)
                files.append((written.file, plan.text))
                madeFolder = madeFolder ?? written.madeFolder
            } catch {
                failure = error
                break
            }
        }
        let window = controller?.window
        let folder = plans.first?.shownFolder ?? ""
        close()
        TaskWriter.offerUndo(files, madeFolder: madeFolder, shownFolder: folder, in: window)
        if let failure {
            let alert = NSAlert()
            alert.messageText = files.isEmpty ? "The task wasn’t added" : "Not every task was added"
            alert.informativeText = failure.localizedDescription + " Nothing else was written."
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }

    @objc private func cancel() { close() }

    private func close() {
        parent?.endSheet(window)
        Self.shown = nil
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

import AppKit
import NextTermCore

/// The one planner and the one sender of tasks for every destination: the Add Task sheet uses them, and add_task and
/// Wrap Up after it, so the same draft gives the same line, the same What's sent and the same bytes everywhere. The
/// todo folder keeps its own writer unchanged; every other destination renders with TaskPayload. Nothing here logs,
/// and nothing reaches the network: a page opens in the browser through TaskOpen, and the user presses Create there.
@MainActor
enum TaskDestinations {
    /// What Add would do now: the plan, and the todo folder's files when that is where the tasks go.
    struct Planned {
        let plan: DestinationPlan
        let drafts: [TaskDraft]
        let files: [TaskWriter.Plan]
        /// The window's project, as its path.
        let project: String?
    }

    enum Outcome: Equatable {
        /// Handed over; the sheet closes.
        case done
        /// Nothing more was sent: the line says why, and the sheet stays open.
        case failed(String)
        /// The user said Not Now: nothing changed, and the sheet stays open.
        case cancelled
    }

    /// The plan for `drafts` at `destination`. The todo folder's folder is looked in only when `looking` (at Add, or
    /// outside a protected place), as its writer does.
    static func plan(_ drafts: [TaskDraft], to destination: TaskDestination, project: String?, facts: DestinationFacts,
                     now: Date = Date(), looking: Bool = false) -> Planned {
        guard destination != .todoFolder else { return todoFolder(drafts, project: project, now: now, looking: looking) }
        let today = TaskDay(now, calendar: .current)
        let name: String? = project.map { (TaskSettings.projectKey($0) as NSString).lastPathComponent }
        let rendered: [TaskPayload?] = drafts.map { TaskPayload.render($0, to: destination, project: name, today: today) }
        let plan = DestinationPlan.make(rendered: rendered, destination: destination, facts: facts)
        return Planned(plan: plan, drafts: drafts, files: [], project: project)
    }

    /// The todo folder, as slice one says it: "Saves to todo/…md in next-term", and its file's text byte for byte.
    private static func todoFolder(_ drafts: [TaskDraft], project: String?, now: Date, looking: Bool) -> Planned {
        var files: [TaskWriter.Plan] = []
        for draft in drafts {
            switch TaskWriter.plan(draft, project: project, created: now, looking: looking, duplicates: looking) {
            case .success(let file): files.append(file)
            case .failure(let refusal):
                let plan = DestinationPlan.todoFolder(line: AddTaskSheet.sentence(refusal), texts: [], refusal: true)
                return Planned(plan: plan, drafts: drafts, files: [], project: project)
            }
        }
        guard let first = files.first else {
            let plan = DestinationPlan.todoFolder(line: "", texts: [], refusal: true)
            return Planned(plan: plan, drafts: drafts, files: [], project: project)
        }
        let folder = first.resolution.createsFolder ? ", and makes the \(first.shownFolder.dropLast()) folder" : ""
        let shown = files.count == 1 ? first.shown : "\(files.count) files in \(first.shownFolder)"
        let plan = DestinationPlan.todoFolder(line: "Saves to " + shown + folder, texts: files.map(\.text),
                                              refusal: false)
        return Planned(plan: plan, drafts: drafts, files: files, project: project)
    }

    /// The destination within its kind, as the posted record keys it.
    static func key(_ destination: TaskDestination) -> String {
        switch destination {
        case .todoFolder, .todoist, .omnifocus, .trello: return ""
        case .reminders(let listID, let listName): return listID ?? listName
        case .things(let list): return list ?? ""
        case .shortcut(let id, _): return id
        case .github(let owner, let repo): return owner + "/" + repo
        case .gitlab(let path): return path
        case .linear(let team): return team ?? ""
        case .azureBoards(let org, let project, _): return org + "/" + project
        case .throughAgent(let tracker): return tracker
        }
    }

    /// The task sent the same way less than a minute ago, if any: its title and where it went, for the sheet's
    /// "Added a minute ago. Add again?". The todo folder answers from its own folder; the rest from the posted record,
    /// read off the main thread.
    static func duplicate(_ planned: Planned, done: @escaping (_ title: String?) -> Void) {
        let destination = planned.plan.destination
        if destination == .todoFolder { return done(planned.files.first(where: \.duplicate)?.draft.title) }
        let kind = destination.kind
        let key = key(destination)
        let titles: [String] = planned.drafts.map(\.title)
        DispatchQueue.global(qos: .userInitiated).async {
            let again: String? = titles.first { title in
                TaskRecordStore.shared.recentDuplicate(kind: kind, key: key, title: title) != nil
            }
            DispatchQueue.main.async { done(again) }
        }
    }

    /// One line in the posted record, written off the main thread.
    static func record(_ title: String, to destination: TaskDestination, key given: String? = nil, project: String?,
                       waited: Bool) {
        let entry = TaskRecord.Entry(at: Date(), kind: destination.kind, key: given ?? key(destination), title: title,
                                     slug: TodoFile.slug(title), project: project.map(TaskSettings.projectKey),
                                     waited: waited)
        DispatchQueue.global(qos: .utility).async { TaskRecordStore.shared.record(entry) }
    }
}

extension TaskDestinations {
    /// Where a send happens: the sheet's window (Reminders' explanation opens over it), the project window the notice
    /// with Undo shows in once the sheet is gone, and the agent tab picked for Through your agent.
    @MainActor struct Place {
        let sheet: NSWindow?
        let controller: TerminalWindowController?
        let tab: TerminalTab?

        var notice: NSWindow? { controller?.window }
    }

    /// The only code that hands a task over. Each success writes one line in the posted record; a refusal or a cancel
    /// writes none. `done` comes on the main thread once every task went, or at the first that didn't.
    static func send(_ planned: Planned, at place: Place, done: @escaping (Outcome) -> Void) {
        let plan = planned.plan
        guard plan.canAdd else { return done(.failed(plan.line)) }
        switch plan.destination {
        case .todoFolder:
            writeFiles(planned, at: place, done: done)
        case .reminders:
            let tasks = plan.payloads.compactMap { TaskReminders.Task($0, to: plan.destination, project: planned.project) }
            addReminders(tasks[...], at: place, done: done)
        case .shortcut:
            let tasks = plan.payloads.compactMap { TaskShortcut.Task($0, to: plan.destination, project: planned.project) }
            runShortcut(tasks[...], at: place, done: done)
        case .things, .todoist, .omnifocus, .github, .gitlab, .linear, .trello, .azureBoards:
            let links: [(URL, String)] = zip(plan.payloads, planned.drafts).compactMap { payload, draft in
                if case .link(let url) = payload.form { return (url, draft.title) }
                return nil
            }
            open(links[...], planned, at: place, done: done)
        case .throughAgent(let tracker):
            typeRequest(planned, tracker: tracker, at: place, done: done)
        }
    }

    /// The todo folder: each file written create-only, then the notice with Undo, as slice one does.
    private static func writeFiles(_ planned: Planned, at place: Place, done: @escaping (Outcome) -> Void) {
        var files: [(url: URL, text: String)] = []
        var madeFolder: URL?
        var failure: Error?
        for file in planned.files {
            do {
                let written = try TaskWriter.write(file)
                files.append((written.file, file.text))
                madeFolder = madeFolder ?? written.madeFolder
                let folder = written.file.deletingLastPathComponent().path
                record(file.draft.title, to: .todoFolder, key: folder, project: planned.project, waited: false)
            } catch {
                failure = error
                break
            }
        }
        let window = place.notice
        done(.done)
        TaskWriter.offerUndo(files, madeFolder: madeFolder, shownFolder: planned.files.first?.shownFolder ?? "",
                             in: window)
        guard let failure else { return }
        let alert = NSAlert()
        alert.messageText = files.isEmpty ? "The task wasn’t added" : "Not every task was added"
        alert.informativeText = failure.localizedDescription + " Nothing else was written."
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Reminders, one after another; the first that doesn't go stops the rest.
    private static func addReminders(_ tasks: ArraySlice<TaskReminders.Task>, at place: Place,
                                     done: @escaping (Outcome) -> Void) {
        guard let task = tasks.first else { return done(.done) }
        TaskReminders.add(task, from: place.sheet, undoIn: place.notice) { outcome in
            switch outcome {
            case .added: addReminders(tasks.dropFirst(), at: place, done: done)
            case .notNow: done(.cancelled)
            case .failed(let line): done(.failed(line))
            }
        }
    }

    /// The shortcut, once per task, after a look that it is still there.
    private static func runShortcut(_ tasks: ArraySlice<TaskShortcut.Task>, at place: Place,
                                    done: @escaping (Outcome) -> Void) {
        guard let first = tasks.first else { return done(.done) }
        TaskShortcut.isListed(first.id) { listed in
            if listed == false { return done(.failed(ShortcutList.goneLine)) }
            runEach(tasks, last: nil, at: place, done: done)
        }
    }

    private static func runEach(_ tasks: ArraySlice<TaskShortcut.Task>, last: String?, at place: Place,
                                done: @escaping (Outcome) -> Void) {
        guard let task = tasks.first else {
            if let last { GitToast.show(last, in: place.notice) }
            return done(.done)
        }
        TaskShortcut.send(task) { outcome in
            switch outcome {
            case .sent(let line): runEach(tasks.dropFirst(), last: line, at: place, done: done)
            case .failed(let line), .stopped(let line): done(.failed(line))
            }
        }
    }
}

extension TaskDestinations {
    /// Things' add, a Quick Add or a tracker's page, one per task, through the one gate for task links. Things saves
    /// by itself; a Quick Add or a page waits for the user's own Add or Create, so its line says it waited.
    private static func open(_ links: ArraySlice<(URL, String)>, _ planned: Planned, at place: Place,
                             done: @escaping (Outcome) -> Void) {
        let destination = planned.plan.destination
        guard let (url, title) = links.first else {
            GitToast.show(openedLine(destination, count: planned.drafts.count), in: place.notice)
            return done(.done)
        }
        TaskOpen.open(url, from: place.notice) { outcome in
            switch outcome {
            case .opened:
                let waited = destination.kind != .things
                record(title, to: destination, project: planned.project, waited: waited)
                open(links.dropFirst(), planned, at: place, done: done)
            case .failed(let line):
                done(.failed(line))
            }
        }
    }

    /// The notice once every link opened.
    static func openedLine(_ destination: TaskDestination, count: Int) -> String {
        switch destination.kind {
        case .things: return count == 1 ? "Added to Things" : "Added \(count) tasks to Things"
        case .todoist, .omnifocus:
            let name = destination.kind == .todoist ? "Todoist" : "OmniFocus"
            return "Opened \(name) Quick Add: press Add there."
        default:
            let pages = count == 1 ? "the page" : "\(count) pages"
            return "Opened \(pages): nothing is created until you press Create there."
        }
    }

    /// Through your agent: the request typed into the picked tab, checked again now, with no Return.
    private static func typeRequest(_ planned: Planned, tracker: String, at place: Place,
                                    done: @escaping (Outcome) -> Void) {
        guard let tab = place.tab, let controller = place.controller, let typed = planned.plan.typed else {
            return done(.failed(DestinationPlan.noReadyTab))
        }
        // The sheet goes first, so the tab can take the keyboard.
        if let why = TaskAgentRequest.refusal(tab) { return done(.failed(why)) }
        done(.done)
        if let why = TaskAgentRequest.type(typed, into: tab, in: controller) {
            return GitToast.show(why, in: place.notice)
        }
        for draft in planned.drafts {
            record(draft.title, to: planned.plan.destination, project: planned.project, waited: true)
        }
        let name = SecretMask.current.mask(tab.title)
        let where_ = SecretMask.current.mask(tracker)
        GitToast.show("Typed into “\(name)”. Read it there and press Return to send it to \(where_).",
                      in: place.notice)
    }
}

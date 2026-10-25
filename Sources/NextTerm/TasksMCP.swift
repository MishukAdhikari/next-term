import AppKit
import NextTermCore

/// add_task on the app's side (MCPServer.taskTools). The arguments are checked, the project found and where its tasks go
/// read fresh from the settings first, and a refusal (a destination that can't take the task now, Through your agent)
/// is answered at once with no window. Then the user is asked on the Mac (MCPWriteControl.approve: one request at a
/// time, the 50-second wait, Decline and Stop Asking), seeing where it goes and exactly what leaves, stored keys masked.
/// A task leaving Next Term is always shown first, even to a remote connection that skips asking for local changes.
/// On Approve the todo folder is written by TaskWriter as Tasks › Add Task… does, and every other destination is sent
/// by TaskDestinations, the sheet's own sender, so both give the same text for the same task. Nothing here logs.
@MainActor
enum TasksMCP {
    static func addTask(_ arguments: [String: Any], caller: TerminalTab?, approval: MCPApproval, requester: String?, connection: String?,
                        reply: @escaping MCPControl.Reply) {
        let context = MCPWriteControl.context(arguments, caller: caller, approval: approval, requester: requester, connection: connection)
        let checked = MCPServer.taskDraft(arguments) { SecretMask.current.mask($0) }
        guard case .success(let made) = checked else {
            if case .failure(let error) = checked { reply(MCPControl.fail(error.text)) }
            return
        }
        let callerWindow = caller.flatMap(MCPControl.controller(of:))
        let project: String?
        switch self.project(made.project, callerWindow: callerWindow, projects: context.projects) {
        case .success(let found): project = found
        case .failure(let error): return reply(MCPControl.fail(error.text))
        }
        let window = callerWindow?.project == project ? callerWindow : AppDelegate.shared.controllers.first { $0.project == project }
        var draft = made.draft
        let addedBy = requester ?? caller.map { "\(TerminalWindowController.agentName(of: $0)) in tab “\($0.title)”" }
            ?? "an agent outside Next Term’s tabs"
        let whereYouAre = TaskSettings(defaults: .standard).includeContext
        draft.context = TaskWriter.context(of: caller, in: callerWindow ?? window, addedBy: addedBy, whereYouAre: whereYouAre)

        guard made.target == .project else {
            return toTodoFolder(draft, project: project, window: window, context: context, reply: reply)
        }
        let key = project.map(TaskSettings.projectKey)
        let read = MCPServer.taskDestination(TaskSettings(defaults: .standard), projectKey: key)
        if read.problem == nil, read.destination == .todoFolder {
            return toTodoFolder(draft, project: project, window: window, context: context, following: key, reply: reply)
        }
        var facts = Self.facts(for: draft)
        if let refusal = MCPServer.taskRefusal(read.destination, savedProblem: read.problem, facts: facts) {
            return reply(MCPControl.fail(refusal))
        }
        let shown = MCPServer.taskAlwaysAsks(read.destination) ? onTheMac(context) : context
        let sending = Sending(draft: draft, destination: read.destination, project: project, key: key, window: window)
        switch read.destination {
        case .shortcut(let id, _):
            // A shortcut no longer listed is refused before anyone is asked; the list is read, nothing is run.
            TaskShortcut.isListed(id) { listed in
                facts.shortcutListed = listed
                if let refusal = MCPServer.taskRefusal(read.destination, savedProblem: nil, facts: facts) {
                    return reply(MCPControl.fail(refusal))
                }
                ask(sending, facts: facts, context: shown, reply: reply)
            }
        case .reminders:
            // Whether Add makes the list, for "new list"; read only because access is given already.
            TaskReminders.makesList(read.destination) { makes in
                facts.makesList = makes
                ask(sending, facts: facts, context: shown, reply: reply)
            }
        default:
            ask(sending, facts: facts, context: shown, reply: reply)
        }
    }

    /// The same call, asked on the Mac: a grant that skips the window covers local changes only.
    static func onTheMac(_ context: MCPWriteControl.Context) -> MCPWriteControl.Context {
        MCPWriteControl.Context(caller: context.caller, approval: .askOnMac, reason: context.reason, asker: context.asker,
                                who: context.who, projects: context.projects, isRemote: context.isRemote)
    }

    /// The todo folder, as it always was: the exact file shown, planned again on Approve, written create-only, and the
    /// notice with Undo. `following` is the project's key when the todo folder is the project's destination, so a
    /// change made while the window waits sends nothing.
    private static func toTodoFolder(_ draft: TaskDraft, project: String?, window: TerminalWindowController?,
                                     context: MCPWriteControl.Context, following: String?? = nil,
                                     reply: @escaping MCPControl.Reply) {
        let plan: TaskWriter.Plan
        switch TaskWriter.plan(draft, project: project) {
        case .success(let planned): plan = planned
        case .failure(let refusal): return reply(MCPControl.fail(sentence(refusal)))
        }
        let ask = MCPWriteControl.Ask(title: "An agent asks to add a task", details: details(plan))
        MCPWriteControl.approve(ask, context, reply: reply) { approved, asked in
            asked?.finish()
            if let following {
                let now = MCPServer.taskDestination(TaskSettings(defaults: .standard), projectKey: following)
                guard now.problem == nil, now.destination == .todoFolder else {
                    return reply(MCPControl.fail(MCPServer.taskDestinationChanged))
                }
            }
            // Planned again now the user said yes, at the same time, so the bytes are the ones shown: a name taken
            // meanwhile moves to the next, and a folder in a protected place is looked in only now.
            let fresh: TaskWriter.Plan
            switch TaskWriter.plan(draft, project: project, created: plan.created, looking: true, duplicates: false) {
            case .success(let planned): fresh = planned
            case .failure(let refusal): return reply(MCPControl.fail(sentence(refusal)))
            }
            do {
                let written = try TaskWriter.write(fresh)
                // One line in the posted record, as the sheet writes, so Post Update sees this task too.
                let folder = written.file.deletingLastPathComponent().path
                TaskDestinations.record(draft.title, to: .todoFolder, key: folder, project: project, waited: false)
                var relative: String?
                if case .inProject(_, let root, _) = fresh.resolution { relative = String(written.file.path.dropFirst(root.count + 1)) }
                let file = MCPServer.TaskFileAnswer(path: written.file.path, relativePath: relative,
                                                    createdFolder: written.madeFolder != nil)
                reply(MCPControl.ok(MCPServer.taskAnswer(approved: approved, sentTo: .todoFolder, draft: draft, file: file)))
                TaskWriter.offerUndo([(written.file, fresh.text)], madeFolder: written.madeFolder, shownFolder: fresh.shownFolder,
                                     in: window?.window)
            } catch {
                reply(MCPControl.fail(error.localizedDescription + " Nothing was written."))
            }
        }
    }

    /// The project the task is for: the one named (its top folder for a folder inside it), else the caller's window's
    /// (nil for a window with no project), else the only one open. nil when none is open: the folder for windows with
    /// no project, if the user chose one. Several open and none named is refused.
    static func project(_ raw: Any?, callerWindow: TerminalWindowController?, projects: MCPProjects) -> Result<String?, MCPToolError> {
        if raw != nil {
            switch projects.project(raw) {
            case .success(let folder): return .success(projects.root(holding: folder) ?? folder)
            case .failure(let error): return .failure(MCPToolError(error.text + " Nothing was written."))
            }
        }
        if let callerWindow { return .success(callerWindow.project) }
        switch projects.project(nil) {
        case .success(let folder): return .success(folder)
        // None open: a task outside projects. Several: the agent names one, as every project tool asks.
        case .failure(let error):
            return projects.open.isEmpty ? .success(nil) : .failure(MCPToolError(error.text + " Nothing was written."))
        }
    }

    /// Why nothing was written, for the agent.
    static func sentence(_ refusal: TaskWriter.Refusal) -> String {
        switch refusal {
        case .noProject: return MCPServer.taskNeedsProject
        case .missing(let folder): return "The todo folder \(folder) is not there (an unmounted disk?). Nothing was written."
        case .unusable(let why): return why + " Nothing was written."
        }
    }

    /// What the approval window says for the todo folder: where the file goes (and the folder, when that is new), the
    /// note when the same task was added a minute ago, then the whole file's text as it will be written.
    static func details(_ plan: TaskWriter.Plan) -> String {
        let folder = plan.resolution.createsFolder ? ", and makes the \(plan.shownFolder.dropLast()) folder" : ""
        let shown = DestinationPlan.todoFolder(line: "Saves to " + plan.shown + folder, texts: [plan.text], refusal: false)
        return MCPServer.taskDetails(shown, duplicate: plan.duplicate ? plan.shownFolder : nil)
    }
}

extension TasksMCP {
    /// One task on its way to the project's destination, other than the todo folder.
    struct Sending {
        let draft: TaskDraft
        let destination: TaskDestination
        let project: String?
        let key: String?
        let window: TerminalWindowController?
    }

    /// What only the app knows, read now: the apps installed, where Reminders stands (never asked from here) and the
    /// day's words. Nothing is launched.
    static func facts(for draft: TaskDraft, now: Date = Date()) -> DestinationFacts {
        var facts = DestinationFacts()
        let apps: [TaskLink.Kind] = [.things, .todoist, .omnifocus]
        facts.installed = Set(apps.filter { TaskOpen.installed($0) })
        facts.reminders = TaskReminders.step
        facts.day = dayWords(draft.scheduled, now: now)
        return facts
    }

    /// "Tomorrow, Sat 19 Oct", as the sheet says the day; nil for no date.
    static func dayWords(_ scheduled: TaskDraft.Scheduled, now: Date) -> String? {
        guard case .day(let day) = scheduled, let start = day.start(in: .current) else { return nil }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        let shown = formatter.string(from: start)
        let today = TaskDay(now, calendar: .current)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now).map { TaskDay($0, calendar: .current) }
        if day == today { return "Today, " + shown }
        if day == tomorrow { return "Tomorrow, " + shown }
        return shown
    }

    /// The window: where it goes and exactly what leaves, as the sheet would show it. On Approve the destination is read
    /// again; one changed meanwhile sends nothing. Otherwise the sheet's sender hands it over.
    static func ask(_ sending: Sending, facts: DestinationFacts, context: MCPWriteControl.Context,
                    reply: @escaping MCPControl.Reply) {
        let planned = TaskDestinations.plan([sending.draft], to: sending.destination, project: sending.project, facts: facts)
        if planned.plan.refused { return reply(MCPControl.fail(MCPServer.taskCantUse(planned.plan.line))) }
        TaskDestinations.duplicate(planned) { again in
            let place: String? = again.map { _ in DestinationChoices.name(sending.destination) }
            let details = MCPServer.taskDetails(planned.plan, duplicate: place)
            let ask = MCPWriteControl.Ask(title: "An agent asks to add a task", details: details)
            MCPWriteControl.approve(ask, context, reply: reply) { approved, asked in
                asked?.finish()
                send(sending, facts: facts, approved: approved, reply: reply)
            }
        }
    }

    private static func send(_ sending: Sending, facts: DestinationFacts, approved: String, reply: @escaping MCPControl.Reply) {
        let now = MCPServer.taskDestination(TaskSettings(defaults: .standard), projectKey: sending.key)
        guard now.problem == nil, MCPServer.taskSameDestination(sending.destination, now: now.destination) else {
            return reply(MCPControl.fail(MCPServer.taskDestinationChanged))
        }
        // The destination as saved now: a Reminders list's id saved meanwhile is used.
        let destination = now.destination
        // Reminders may have been turned off while the window waited; it is never asked for from here.
        var fresh = facts
        fresh.reminders = TaskReminders.step
        if let refusal = MCPServer.taskRefusal(destination, savedProblem: nil, facts: fresh) {
            return reply(MCPControl.fail(refusal))
        }
        let planned = TaskDestinations.plan([sending.draft], to: destination, project: sending.project, facts: fresh)
        var place = TaskDestinations.Place(sheet: nil, controller: sending.window, tab: nil)
        let used = UsedList()
        place.placed = { used.id = $0 }
        TaskDestinations.send(planned, at: place) { outcome in
            switch outcome {
            case .done:
                answer(approved, sentTo: destination, draft: sending.draft, list: used.id, reply: reply)
            case .failed(let line):
                reply(MCPControl.fail(line.contains("Nothing") ? line : line + " Nothing was added."))
            case .cancelled:
                reply(MCPControl.fail("The user chose Not Now. Nothing was added."))
            }
        }
    }

    /// The Reminders list a reminder went to, by id, once it is saved.
    private final class UsedList {
        var id: String?
    }

    /// The answer once handed over; for Reminders it names the list the reminder went to, which is the default list
    /// when the user took it after the saved one couldn't be made.
    private static func answer(_ approved: String, sentTo destination: TaskDestination, draft: TaskDraft, list: String?,
                               reply: @escaping MCPControl.Reply) {
        guard case .reminders = destination, let list else {
            return reply(MCPControl.ok(MCPServer.taskAnswer(approved: approved, sentTo: destination, draft: draft)))
        }
        TaskReminders.listTitle(list) { title in
            let answer = MCPServer.taskAnswer(approved: approved, sentTo: destination, draft: draft, list: title)
            reply(MCPControl.ok(answer))
        }
    }
}

import AppKit
import NextTermCore

/// add_task on the app's side (MCPServer.taskTools). The arguments are checked and the todo folder found first, and a
/// refusal is answered at once with no window. Then the user is asked on the Mac (MCPWriteControl.approve: one request
/// at a time, the 50-second wait, Decline and Stop Asking), seeing the exact file with stored keys masked; on Approve,
/// TaskWriter writes it as Tasks › Add Task… does, so both give the same bytes for the same task.
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

        let plan: TaskWriter.Plan
        switch TaskWriter.plan(draft, project: project) {
        case .success(let planned): plan = planned
        case .failure(let refusal): return reply(MCPControl.fail(sentence(refusal)))
        }
        let ask = MCPWriteControl.Ask(title: "An agent asks to add a task", details: details(plan))
        MCPWriteControl.approve(ask, context, reply: reply) { approved, asked in
            asked?.finish()
            // Planned again now the user said yes, at the same time, so the bytes are the ones shown: a name taken
            // meanwhile moves to the next, and a folder in a protected place is looked in only now.
            let fresh: TaskWriter.Plan
            switch TaskWriter.plan(draft, project: project, created: plan.created, looking: true, duplicates: false) {
            case .success(let planned): fresh = planned
            case .failure(let refusal): return reply(MCPControl.fail(sentence(refusal)))
            }
            do {
                let written = try TaskWriter.write(fresh)
                var relative: String?
                if case .inProject(_, let root, _) = fresh.resolution { relative = String(written.file.path.dropFirst(root.count + 1)) }
                let answer = MCPServer.taskAnswer(approved: approved, path: written.file.path, relativePath: relative, draft: draft,
                                                  createdFolder: written.madeFolder != nil)
                reply(MCPControl.ok(answer))
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

    /// What the approval window says: the file it creates (and the folder, when that is new), the note when the same
    /// task was added a minute ago, then the whole file's text as it will be written (the window scrolls a long one).
    static func details(_ plan: TaskWriter.Plan) -> String {
        var said: [String] = []
        if plan.duplicate { said.append("Added a minute ago. Add again? The same task went to \(plan.shownFolder) less than a minute ago.") }
        let folder = plan.resolution.createsFolder ? ", and the \(plan.shownFolder.dropLast()) folder" : ""
        said.append("Creates \(plan.shown)\(folder):")
        let text = plan.text.hasSuffix("\n") ? String(plan.text.dropLast()) : plan.text
        return said.joined(separator: "\n") + "\n\n" + text
    }
}

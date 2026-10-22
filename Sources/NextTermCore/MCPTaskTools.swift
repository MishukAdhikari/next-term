import Foundation

/// add_task, Tasks' one tool: an agent adds a task for the user where the user sends the project's tasks, or as a todo
/// file in the project's todo folder when it asks for that, once the user approves on the Mac (the app's TasksMCP,
/// through MCPWriteControl.approve). Its own list, not controlTools; not always loaded (it is used once in a while), and
/// named in the instructions among the tools that ask, so agents know it is there. Its schema only grows: every later
/// field is optional, and the answer already says where the task went (`destination`).
extension MCPServer {
    /// The arguments add_task takes; any other is refused.
    static let taskArguments: Set<String> = ["title", "notes", "when", "project", "reason", "destination"]
    /// The longest title and notes.
    public static let taskTitleLength = 300
    public static let taskNotesLength = 20_000

    public static let taskTools: [Tool] = [
        Tool(name: "add_task", title: "Add a task",
             description: "Adds a task for the user: one Markdown file in the project's todo folder (todo/ unless the user chose another), with front matter (created, scheduled, branch, tab, agent) and a `- [ ]` line holding the title, its steps and notes, or the same task in the place the user chose for this project's tasks. With destination project (the default) the task goes where the user sends this project's tasks; todo_folder always writes the Markdown file. The user is asked on the Mac first and sees exactly what is sent; stored keys are masked. Next Term fills branch, tab and agent from your tab. Each todo/*.md is one task: read open ones there with your own tools. Answers where it went (the file's path for the todo folder), its title, steps and scheduled day, or why nothing was added.",
             inputSchema: #"{"type": "object", "properties": {"title": {"type": "string", "minLength": 1, "maxLength": 300, "description": "The task in one line: what to do."}, "notes": {"type": "string", "maxLength": 20000, "description": "Markdown under the task: list lines become its steps (- [ ] …), the rest stays as written."}, "when": {"type": "string", "pattern": "\#(When.pattern)", "description": "The day it is planned for: today, tomorrow or a date (YYYY-MM-DD). Never a deadline. Default: tomorrow."}, "project": {"type": "string", "description": "An open project's folder (as list_projects gives it), its name, or a folder inside one. Default: your window's project, or the only one open."}, "reason": {"type": "string", "description": "Why, in a sentence; shown to the user as your words when they are asked."}, "destination": {"type": "string", "enum": ["project", "todo_folder"], "description": "project: where the user sends this project's tasks; todo_folder: the Markdown file. Default: project."}}, "required": ["title"], "additionalProperties": false}"#,
             readOnly: false, destructive: false, idempotent: false, timeout: 60, alwaysLoad: false),
    ]

    public static func isTaskTool(_ name: String) -> Bool { taskTools.contains { $0.name == name } }

    /// The tools listed for tool search to find rather than kept loaded: the import tools and add_task. The tools' own
    /// `alwaysLoad` must agree (a unit test checks both).
    public static func isDeferred(_ name: String) -> Bool { isImportTool(name) || isTaskTool(name) }

    /// add_task's refusal for a call with no project to put the task in.
    public static let taskNeedsProject = "This task needs a project: pass project, or the user can choose a folder for tasks outside "
        + "projects in Settings › Tasks. Nothing was written."

    /// Where add_task's task goes: the project's destination, which only the user chooses, or always the todo folder.
    /// An agent can never name an app, a page or Through your agent.
    public enum TaskTarget: String, Sendable {
        case project
        case todoFolder = "todo_folder"
    }

    /// add_task's refusal for a destination that is neither of the two.
    public static let taskTargetRefusal = "destination takes project or todo_folder; where the project’s tasks go is the "
        + "user’s choice. Nothing was added."

    /// add_task's arguments, checked: the draft (stored keys masked by `mask`) planned for its day, the project as given
    /// (nil: the caller's window's) and where it goes. Anything wrong is refused before the user is asked, with no window.
    public static func taskDraft(_ arguments: [String: Any], now: Date = Date(), calendar: Calendar = .current,
                                 mask: (String) -> String = { $0 })
        -> Result<(draft: TaskDraft, project: Any?, target: TaskTarget), MCPToolError> {
        if let unknown = arguments.keys.sorted().first(where: { !taskArguments.contains($0) }) {
            return .failure(MCPToolError("add_task takes no argument \(unknown): only title, notes, when, project, reason and "
                + "destination. Nothing was written."))
        }
        // A destination it doesn't take is refused before anything else is looked at.
        var target = TaskTarget.project
        if arguments.keys.contains("destination") {
            guard let raw = arguments["destination"] as? String, let given = TaskTarget(rawValue: raw) else {
                return .failure(MCPToolError(taskTargetRefusal))
            }
            target = given
        }
        guard let title = arguments["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(MCPToolError("Give title: the task in one line. Nothing was written."))
        }
        guard title.count <= taskTitleLength else {
            return .failure(MCPToolError("title is \(title.count) characters; keep it to \(taskTitleLength) and put the rest in notes. Nothing was written."))
        }
        if arguments["notes"] != nil, !(arguments["notes"] is String) {
            return .failure(MCPToolError("notes is Markdown text. Nothing was written."))
        }
        let notes = arguments["notes"] as? String ?? ""
        guard notes.count <= taskNotesLength else {
            return .failure(MCPToolError("notes is \(notes.count) characters, over \(taskNotesLength). Nothing was written."))
        }
        if arguments["reason"] != nil, !(arguments["reason"] is String) {
            return .failure(MCPToolError("reason is a sentence. Nothing was written."))
        }
        let when = arguments["when"] == nil ? "tomorrow" : arguments["when"] as? String ?? ""
        guard let day = When.parse(when, now: now, calendar: calendar) else {
            return .failure(MCPToolError("when is today, tomorrow or a day on the calendar as YYYY-MM-DD (the pattern \(When.pattern)); "
                + "“\(when)” is none of them. Nothing was written."))
        }
        guard var draft = TaskDraft(title: title, notes: notes, mask: mask) else {
            return .failure(MCPToolError("Give title: the task in one line, with words. Nothing was written."))
        }
        draft.scheduled = .day(day)
        return .success((draft, arguments["project"], target))
    }

    /// add_task's answer for a file written: where (`relativePath` when it is in the project), what it holds, how it was
    /// approved, and that the todo folder was made for it when it was.
    public static func taskAnswer(approved: String, path: String, relativePath: String?, draft: TaskDraft, createdFolder: Bool) -> [String: Any] {
        let file = TaskFileAnswer(path: path, relativePath: relativePath, createdFolder: createdFolder)
        return taskAnswer(approved: approved, sentTo: .todoFolder, draft: draft, file: file)
    }

    /// The todo file add_task wrote, for its answer.
    public struct TaskFileAnswer: Equatable, Sendable {
        public var path: String
        public var relativePath: String?
        public var createdFolder: Bool

        public init(path: String, relativePath: String?, createdFolder: Bool) {
            self.path = path
            self.relativePath = relativePath
            self.createdFolder = createdFolder
        }
    }

    /// The one sentence a page or Quick Add answers with: Next Term can't know the user submitted it.
    public static let taskWaitsForUser = "The page is open for the user to submit; nothing is added until they do."

    /// add_task's answer once the task was handed over: how it was approved, the destination's kind, the title, steps
    /// and day. Only the todo folder answers a path; a page or Quick Add says it waits for the user; Reminders names its
    /// list, masked. Never a link or an item's id.
    public static func taskAnswer(approved: String, sentTo destination: TaskDestination, draft: TaskDraft,
                                  file: TaskFileAnswer? = nil,
                                  mask: (String) -> String = { SecretMask.current.mask($0) }) -> [String: Any] {
        var answer: [String: Any] = [
            "approved": approved,
            "destination": destination.kind.rawValue,
            "title": draft.title,
            "steps": draft.steps.count,
        ]
        if case .day(let day) = draft.scheduled { answer["scheduled"] = day.description }
        switch destination {
        case .todoFolder:
            guard let file else { break }
            answer["path"] = file.path
            answer["created_folder"] = file.createdFolder
            if let relative = file.relativePath { answer["relative_path"] = relative }
        case .reminders(_, let listName):
            answer["list"] = mask(listName)
        case .todoist, .omnifocus, .github, .gitlab, .linear, .trello, .azureBoards:
            answer["waiting_for_user"] = true
            answer["note"] = taskWaitsForUser
        case .things, .shortcut, .throughAgent:
            break
        }
        return answer
    }
}

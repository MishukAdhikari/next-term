import Foundation

/// add_task, Tasks' one tool: an agent adds a task for the user as a todo file in the project's todo folder, once the
/// user approves on the Mac (the app's TasksMCP, through MCPWriteControl.approve). Its own list, not controlTools; not
/// always loaded (it is used once in a while), and named in the instructions among the tools that ask, so agents know it
/// is there. Its schema only grows: every later field is optional, and the answer already says where the task went
/// (`destination`).
extension MCPServer {
    /// The arguments add_task takes; any other is refused.
    static let taskArguments: Set<String> = ["title", "notes", "when", "project", "reason"]
    /// The longest title and notes.
    public static let taskTitleLength = 300
    public static let taskNotesLength = 20_000

    public static let taskTools: [Tool] = [
        Tool(name: "add_task", title: "Add a task",
             description: "Adds a task for the user: one Markdown file in the project's todo folder (todo/ unless the user chose another), with front matter (created, scheduled, branch, tab, agent) and a `- [ ]` line holding the title, its steps and notes. The user is asked on the Mac first and sees the exact file; stored keys are masked. Next Term fills branch, tab and agent from your tab. Each todo/*.md is one task: read open ones there with your own tools. Answers the file's path, title, steps and scheduled day, or why nothing was written.",
             inputSchema: #"{"type": "object", "properties": {"title": {"type": "string", "minLength": 1, "maxLength": 300, "description": "The task in one line: what to do."}, "notes": {"type": "string", "maxLength": 20000, "description": "Markdown under the task: list lines become its steps (- [ ] …), the rest stays as written."}, "when": {"type": "string", "pattern": "\#(When.pattern)", "description": "The day it is planned for: today, tomorrow or a date (YYYY-MM-DD). Never a deadline. Default: tomorrow."}, "project": {"type": "string", "description": "An open project's folder (as list_projects gives it), its name, or a folder inside one. Default: your window's project, or the only one open."}, "reason": {"type": "string", "description": "Why, in a sentence; shown to the user as your words when they are asked."}}, "required": ["title"], "additionalProperties": false}"#,
             readOnly: false, destructive: false, idempotent: false, timeout: 60, alwaysLoad: false),
    ]

    public static func isTaskTool(_ name: String) -> Bool { taskTools.contains { $0.name == name } }

    /// The tools listed for tool search to find rather than kept loaded: the import tools and add_task. The tools' own
    /// `alwaysLoad` must agree (a unit test checks both).
    public static func isDeferred(_ name: String) -> Bool { isImportTool(name) || isTaskTool(name) }

    /// add_task's refusal for a call with no project to put the task in.
    public static let taskNeedsProject = "This task needs a project: pass project, or the user can choose a folder for tasks outside "
        + "projects in Settings › Tasks. Nothing was written."

    /// add_task's arguments, checked: the draft (stored keys masked by `mask`) planned for its day, and the project as
    /// given (nil: the caller's window's). Anything wrong is refused before the user is asked, with no window.
    public static func taskDraft(_ arguments: [String: Any], now: Date = Date(), calendar: Calendar = .current,
                                 mask: (String) -> String = { $0 }) -> Result<(draft: TaskDraft, project: Any?), MCPToolError> {
        if let unknown = arguments.keys.sorted().first(where: { !taskArguments.contains($0) }) {
            return .failure(MCPToolError("add_task takes no argument \(unknown): only title, notes, when, project and reason. Nothing was written."))
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
        return .success((draft, arguments["project"]))
    }

    /// add_task's answer for a file written: where (`relativePath` when it is in the project), what it holds, how it was
    /// approved, and that the todo folder was made for it when it was.
    public static func taskAnswer(approved: String, path: String, relativePath: String?, draft: TaskDraft, createdFolder: Bool) -> [String: Any] {
        var answer: [String: Any] = [
            "approved": approved,
            "destination": "todo_folder",
            "path": path,
            "title": draft.title,
            "steps": draft.steps.count,
            "created_folder": createdFolder,
        ]
        if let relativePath { answer["relative_path"] = relativePath }
        if case .day(let day) = draft.scheduled { answer["scheduled"] = day.description }
        return answer
    }
}

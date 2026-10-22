import Foundation

/// Where add_task's task goes, said to the agent and to the user. The project's destination is the user's choice: one
/// that can't be used right now is refused with no window and nothing asked, and the approval window shows the same line
/// and the same text the Add Task sheet would, masked. Nothing here says a title, notes or a name anywhere but in the
/// window and the answer.
extension MCPServer {
    /// The end of every refusal for a destination that can't take the task now.
    static let taskOtherWay = "pass destination todo_folder, or the user changes it in Tasks › Send Tasks To. Nothing was added."

    /// Reminders not allowed yet: an agent's call never makes macOS ask; only the user's own Add does.
    public static let taskRemindersNotAllowed = "Next Term isn’t allowed to use Reminders yet; the user turns it on from "
        + "Tasks › Add Task…"

    /// The project's destination changed while the window waited: nothing is sent.
    public static let taskDestinationChanged = "The project’s destination changed while the user was asked. Nothing was added."

    /// A project whose tasks go through the user's agent: the caller posts it with its own tools, or to the todo folder.
    public static func taskThroughAgent(_ tracker: String) -> String {
        "This project’s tasks go to \(tracker) through your agent: post it with your own \(tracker) tools, or pass "
            + "destination todo_folder. Nothing was added."
    }

    /// A destination that can't take the task now, named by `problem`.
    public static func taskCantUse(_ problem: String) -> String {
        var said = problem.trimmingCharacters(in: .whitespaces)
        while let last = said.last, ".:;".contains(last) { said.removeLast() }
        return said + "; " + taskOtherWay
    }

    /// The project's destination as add_task reads it, fresh from the settings, and why the saved one can't be used,
    /// if it can't. A value that failed its check is refused, never read as another place.
    public static func taskDestination(_ settings: TaskSettings, projectKey: String?) -> (destination: TaskDestination, problem: String?) {
        let own: TaskDestination? = projectKey.flatMap { settings.projects[$0]?.destination }
        let problem = DestinationChoices.savedProblem(key: projectKey, own: own, settings: settings)
        return (settings.destination(for: projectKey), problem)
    }

    /// Why add_task can't send to `destination` now, before anything is planned; nil when it can. The tracker's name is
    /// masked.
    public static func taskRefusal(_ destination: TaskDestination, savedProblem: String?, facts: DestinationFacts,
                                   mask: (String) -> String = { SecretMask.current.mask($0) }) -> String? {
        if let savedProblem { return taskCantUse(mask(savedProblem)) }
        if let problem = destination.problem { return taskCantUse(mask(problem)) }
        switch destination {
        case .throughAgent(let tracker):
            return taskThroughAgent(mask(tracker))
        case .reminders:
            guard facts.reminders == .ready else { return taskCantUse(taskRemindersNotAllowed) }
        case .things, .todoist, .omnifocus:
            guard let kind = TaskLink.Kind(rawValue: destination.kind.rawValue) else { return nil }
            if !facts.installed.contains(kind) { return taskCantUse("\(kind.name) isn’t installed") }
        case .shortcut:
            if facts.shortcutListed == false { return taskCantUse("The shortcut is gone") }
        case .todoFolder, .github, .gitlab, .linear, .trello, .azureBoards:
            break
        }
        return nil
    }

    /// What the approval window says: the note when the same task went to the same place a minute ago (`duplicate`
    /// names that place), "To: " and where it goes, then exactly what leaves (the window scrolls a long one).
    public static func taskDetails(_ plan: DestinationPlan, duplicate: String?,
                                   mask: (String) -> String = { SecretMask.current.mask($0) }) -> String {
        var said: [String] = []
        if let duplicate {
            said.append("Added a minute ago. Add again? The same task went to \(duplicate) less than a minute ago.")
        }
        let name = plan.destination == .todoFolder ? "the todo folder" : DestinationChoices.name(plan.destination, mask: mask)
        said.append("To: \(name): " + lowered(plan.line))
        let sent = plan.sent.hasSuffix("\n") ? String(plan.sent.dropLast()) : plan.sent
        return said.joined(separator: "\n") + "\n\n" + sent
    }

    /// The line after "To: …:", its first letter small.
    static func lowered(_ line: String) -> String {
        guard let first = line.first else { return line }
        return first.lowercased() + line.dropFirst()
    }
}

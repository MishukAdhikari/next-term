import Foundation

/// The rows the Add Task sheet's Destination popup and Tasks › Send Tasks To ▸ share. The current destination comes
/// first, titled "(this project’s)" in a project's window and "(default)" in one without; then one row per kind in a
/// fixed order. A kind shows the details the current or default destination has for it ("GitHub o/r", "Linear ENG");
/// a kind that can't go anywhere without details it doesn't have opens Settings › Tasks at them instead. An app that
/// isn't installed, and Reminders when it isn't allowed, show why and can't be chosen.
public enum DestinationChoices {
    public enum Action: Equatable, Sendable {
        case use(TaskDestination)
        /// Opens Settings › Tasks at this kind's details.
        case setUp(TaskDestination.Kind)
    }

    public struct Row: Equatable, Sendable {
        public let title: String
        public let action: Action
        public let enabled: Bool
    }

    /// The order every list of destinations takes.
    public static let order: [TaskDestination.Kind] = [.todoFolder, .reminders, .things, .shortcut, .todoist, .omnifocus,
                                                        .github, .gitlab, .linear, .trello, .azureBoards, .throughAgent]
    /// The Reminders list a task goes to when none was chosen.
    public static let remindersList = "Next Term"

    public static func rows(current: TaskDestination, default fallback: TaskDestination?, inProject: Bool,
                            facts: DestinationFacts,
                            mask: (String) -> String = { SecretMask.current.mask($0) }) -> [Row] {
        let whose = inProject ? " (this project’s)" : " (default)"
        var rows: [Row] = [Row(title: name(current, mask: mask) + whose, action: .use(current), enabled: true)]
        for kind in order {
            let detailed: TaskDestination? = [current, fallback].compactMap { $0 }.first { $0.kind == kind }
            guard let destination = detailed ?? plain(kind) else {
                rows.append(Row(title: setUpTitle(kind), action: .setUp(kind), enabled: true))
                continue
            }
            if destination == current { continue }
            let why = unavailable(kind, facts: facts)
            let title = name(destination, mask: mask) + (why.map { " · " + $0 } ?? "")
            rows.append(Row(title: title, action: .use(destination), enabled: why == nil))
        }
        return rows
    }

    /// The destination a kind that needs no details goes to; nil for one that does.
    static func plain(_ kind: TaskDestination.Kind) -> TaskDestination? {
        switch kind {
        case .todoFolder: return .todoFolder
        case .reminders: return .reminders(listID: nil, listName: remindersList)
        case .things: return .things(list: nil)
        case .todoist: return .todoist
        case .omnifocus: return .omnifocus
        case .linear: return .linear(team: nil)
        case .trello: return .trello
        case .shortcut, .github, .gitlab, .azureBoards, .throughAgent: return nil
        }
    }

    static func setUpTitle(_ kind: TaskDestination.Kind) -> String {
        switch kind {
        case .shortcut: return "Run a Shortcut…"
        case .github: return "GitHub Issues…"
        case .gitlab: return "GitLab Issues…"
        case .azureBoards: return "Azure Boards…"
        case .throughAgent: return "Through Your Agent…"
        default: return kindName(kind) + "…"
        }
    }

    /// Why a kind can't be chosen now; nil when it can.
    static func unavailable(_ kind: TaskDestination.Kind, facts: DestinationFacts) -> String? {
        switch kind {
        case .things, .todoist, .omnifocus:
            let app = TaskLink.Kind(rawValue: kind.rawValue)
            return app.map(facts.installed.contains) == true ? nil : "not installed"
        case .reminders:
            if case .blocked = facts.reminders { return "not allowed in Privacy & Security" }
            return nil
        default:
            return nil
        }
    }

    /// A kind's name alone.
    public static func kindName(_ kind: TaskDestination.Kind) -> String {
        switch kind {
        case .todoFolder: return "Todo Folder"
        case .reminders: return "Reminders"
        case .things: return "Things"
        case .shortcut: return "Run a Shortcut"
        case .todoist: return "Todoist"
        case .omnifocus: return "OmniFocus"
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        case .linear: return "Linear"
        case .trello: return "Trello"
        case .azureBoards: return "Azure Boards"
        case .throughAgent: return "Through Your Agent"
        }
    }

    /// A destination with its details, as a row shows it: "GitHub o/r", "Run “Add to Inbox”", "Reminders “Work”".
    public static func name(_ destination: TaskDestination,
                            mask: (String) -> String = { SecretMask.current.mask($0) }) -> String {
        switch destination {
        case .reminders(_, let listName):
            return listName == remindersList ? "Reminders" : "Reminders “\(mask(listName))”"
        case .things(let list?): return "Things “\(mask(list))”"
        case .shortcut(_, let name): return "Run “\(mask(name))”"
        case .github(let owner, let repo): return "GitHub \(mask(owner))/\(mask(repo))"
        case .gitlab(let path): return "GitLab \(mask(path))"
        case .linear(let team?): return "Linear \(mask(team))"
        case .azureBoards(let org, let project, _): return "Azure Boards \(mask(org))/\(mask(project))"
        case .throughAgent(let tracker): return "Through Your Agent (\(mask(tracker)))"
        default: return kindName(destination.kind)
        }
    }
}

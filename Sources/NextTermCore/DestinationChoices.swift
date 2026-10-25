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

    // MARK: Send Tasks To ▸

    /// Whose destination the submenu shows: a project's (every worktree of it shares one), or the default's.
    public enum MenuScope: Equatable, Sendable {
        /// `key` is the project's key (`TaskSettings.projectKey`); `worktree` when the window is a linked worktree.
        case project(key: String, name: String, worktree: Bool)
        case noProject
    }

    public enum MenuAction: Equatable, Sendable {
        /// A line that says something and does nothing.
        case label
        case separator
        /// Saves this destination for the scope.
        case use(TaskDestination)
        /// The default's row, ticked in a project that has none of its own: choosing it changes nothing, so the
        /// project keeps following the default.
        case keep
        /// Opens Settings › Tasks at this kind's details; nothing changes until Save there.
        case setUp(TaskDestination.Kind)
        /// Clears the project's own destination, so its tasks go where the default says.
        case useDefault
        /// Opens Settings › Tasks.
        case setUpAll
    }

    public struct MenuRow: Equatable, Sendable {
        public let title: String
        public let action: MenuAction
        public let enabled: Bool
        /// The destination tasks go to now.
        public let ticked: Bool
        /// The longer reason a row can't be chosen.
        public let tip: String?

        public init(title: String, action: MenuAction, enabled: Bool? = nil, ticked: Bool = false, tip: String? = nil) {
            self.title = title
            self.action = action
            self.enabled = enabled ?? (action != .label && action != .separator)
            self.ticked = ticked
            self.tip = tip
        }
    }

    /// A destination that can't be offered yet, shown greyed where it would go, with why.
    struct Held {
        let title: String
        let after: TaskDestination.Kind
        let tip: String
    }

    static let held: [Held] = [
        Held(title: "TickTick · held: not checked yet", after: .omnifocus,
             tip: "TickTick’s link hasn’t been checked with its Mac app yet, so it isn’t offered."),
        Held(title: "Jira Page · held: Jira 9 and later turn off the prefilled page; use Through Your Agent",
             after: .azureBoards,
             tip: "Atlassian turns off Jira’s prefilled create page in Jira 9 and later. Through Your Agent posts it "
                + "with Atlassian’s own tools instead."),
    ]


    /// Tasks › Send Tasks To ▸, for the window in front: whose it is, why a saved value can't be used, one row per kind
    /// in the fixed order with the destination tasks go to now ticked and its details said, the held rows greyed with
    /// why, then Use the Default (when the project has its own) and Set Up Destinations….
    public static func menuRows(scope: MenuScope, settings: TaskSettings, facts: DestinationFacts,
                                mask: (String) -> String = { SecretMask.current.mask($0) }) -> [MenuRow] {
        var key: String?
        var rows: [MenuRow]
        switch scope {
        case .project(let projectKey, let name, let worktree):
            key = projectKey
            let whose = "For “\(mask(name))”" + (worktree ? " and its worktrees" : "")
            rows = [MenuRow(title: whose, action: .label)]
        case .noProject:
            rows = [MenuRow(title: "For windows with no project (the default)", action: .label)]
        }
        let own: TaskDestination? = key.flatMap { settings.projects[$0]?.destination }
        let fallback = settings.defaultDestination
        let current = settings.destination(for: key)
        if let problem = savedProblem(key: key, own: own, settings: settings) {
            // The saved value is the user's own, but it is shown masked and on one line like every other name.
            let shown: String = TerminalText.oneLine(mask(problem))
            rows.append(MenuRow(title: "Saved destination can’t be used: " + shown, action: .label))
        }
        let fromDefault = key != nil && own == nil
        for kind in order {
            rows.append(menuRow(kind, current: current, fromDefault: fromDefault, details: [own, fallback],
                                facts: facts, mask: mask))
            for hold in held where hold.after == kind {
                rows.append(MenuRow(title: hold.title, action: .label, tip: hold.tip))
            }
        }
        rows.append(MenuRow(title: "", action: .separator))
        if own != nil {
            let back = "Use the Default (" + name(fallback ?? .todoFolder, mask: mask) + ")"
            rows.append(MenuRow(title: back, action: .useDefault))
        }
        rows.append(MenuRow(title: "Set Up Destinations…", action: .setUpAll))
        return rows
    }

    /// Why the value saved for this scope can't be used, while nothing usable is saved in its place.
    static func savedProblem(key: String?, own: TaskDestination?, settings: TaskSettings) -> String? {
        if let key, own == nil {
            if let problem = settings.projects[key]?.problem { return problem }
            if let problem = settings.projectsProblem { return problem }
        }
        guard own == nil, settings.defaultDestination == nil else { return nil }
        return settings.defaultDestinationProblem
    }

    static func menuRow(_ kind: TaskDestination.Kind, current: TaskDestination, fromDefault: Bool,
                        details: [TaskDestination?], facts: DestinationFacts,
                        mask: (String) -> String) -> MenuRow {
        let why = unavailable(kind, facts: facts)
        let suffix = why.map { " · " + $0 } ?? ""
        let tip = why == nil ? nil : unavailableTip(kind)
        if kind == current.kind {
            let title = tickedName(current, mask: mask) + (fromDefault ? " (the default)" : "") + suffix
            let action: MenuAction = fromDefault ? .keep : .use(current)
            return MenuRow(title: title, action: action, enabled: why == nil, ticked: true, tip: tip)
        }
        let detailed: TaskDestination? = details.compactMap { $0 }.first { $0.kind == kind }
        guard let destination = detailed ?? plain(kind) else {
            return MenuRow(title: setUpTitle(kind), action: .setUp(kind))
        }
        let title = name(destination, mask: mask) + suffix
        return MenuRow(title: title, action: .use(destination), enabled: why == nil, tip: tip)
    }

    /// The destination tasks go to now, with the details a plain row leaves out: "Reminders, list “Next Term”".
    static func tickedName(_ destination: TaskDestination, mask: (String) -> String) -> String {
        if case .reminders(_, let listName) = destination { return "Reminders, list “\(mask(listName))”" }
        return name(destination, mask: mask)
    }

    /// The longer reason, as a row's tooltip.
    static func unavailableTip(_ kind: TaskDestination.Kind) -> String {
        if kind == .reminders {
            return "Next Term isn’t allowed to add reminders. Turn it on in System Settings › Privacy & Security › "
                + "Reminders."
        }
        return kindName(kind) + " isn’t installed on this Mac. Install it, or choose another destination."
    }
}

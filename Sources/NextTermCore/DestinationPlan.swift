import Foundation

/// What only the app knows about a destination, read when the Add Task sheet opens, when its Destination popup changes
/// and when its window becomes key again: which apps are installed, where Reminders stands, whether the shortcut is
/// still listed, the agent tab picked, and the day's words. Plain values, so the line and What's sent are tested here.
public struct DestinationFacts: Equatable, Sendable {
    /// The agent tab picked for Through your agent.
    public struct AgentTab: Equatable, Sendable {
        public var title: String
        public var agent: AgentKind
        /// The program takes a paste with its line breaks; without it every line break would be a Return.
        public var bracketedPaste: Bool
        /// Why it can't be typed into now; nil when it is ready.
        public var notReady: AgentReadiness.Reason?

        public init(title: String, agent: AgentKind, bracketedPaste: Bool, notReady: AgentReadiness.Reason? = nil) {
            self.title = title
            self.agent = agent
            self.bracketedPaste = bracketedPaste
            self.notReady = notReady
        }
    }

    /// The apps found installed as their vendor's own; a kind not here is not installed. Pages need no app.
    public var installed: Set<TaskLink.Kind> = []
    /// Where Reminders stands; ready unless known otherwise.
    public var reminders: RemindersAccess.Step = .ready
    /// Add would make the Reminders list; nil when that can't be known yet (access not given).
    public var makesList: Bool?
    /// The chosen shortcut is still listed; nil when the list was not read.
    public var shortcutListed: Bool?
    /// The agent tab picked; nil when no agent tab in the window is ready.
    public var agentTab: AgentTab?
    /// The planned day as the sheet says it ("Tomorrow, Sat 19 Oct"); nil for No Date.
    public var day: String?

    public init() {}
}

/// Where the task goes, said in one line before Add, and exactly what leaves: the sheet, the approval window and Wrap
/// Up's review all show this, built from the same payloads Add sends, so the same draft gives the same text everywhere.
/// A refusal (an app not installed, Reminders not allowed, no ready agent tab, too many pages) replaces the line and
/// turns Add off; nothing ever falls back to another place by itself.
public struct DestinationPlan: Equatable, Sendable {
    public let destination: TaskDestination
    /// One per task, in order; none for the todo folder, whose files are written by its own writer.
    public let payloads: [TaskPayload]
    /// The one line under Destination, or the refusal.
    public let line: String
    /// What's sent: the todo file's text, a reminder's fields, a link's place and each parameter, a shortcut's input
    /// or the request typed, each task under "1 of 3" when there are several.
    public let sent: String
    /// The line is a refusal: Add is off.
    public let refused: Bool
    /// The refusal offers Use Todo Folder, for this Add only.
    public let offersTodoFolder: Bool
    /// Some text was cut to fit the destination.
    public let cut: Bool
    /// Through your agent: the one request typed, every task in it, with no Return.
    public let typed: String?

    public var canAdd: Bool { !refused }

    /// The button says what Add does.
    public var addTitle: String {
        switch destination.kind {
        case .todoFolder, .reminders, .things, .shortcut: return "Add Task"
        case .github, .gitlab, .linear, .trello, .azureBoards: return "Open Page"
        case .todoist, .omnifocus: return "Open Quick Add"
        case .throughAgent: return "Type into Tab"
        }
    }

    /// The most pages or Quick Add windows one Add opens.
    public static let pagesAtOnce = 5
    /// A tab with no bracketed paste takes one task at a time; `title` is masked already.
    public static func oneAtATime(_ title: String) -> String {
        "“\(title)” takes one line at a time: add these one by one."
    }

    public static let noReadyTab = "No agent tab in this window is ready. Start one, or wait for it to finish."
    static let cutNote = " · cut to fit"

    /// The todo folder's plan: its line (slice one's, from the writer), and each file's text as written.
    public static func todoFolder(line: String, texts: [String], refusal: Bool) -> DestinationPlan {
        DestinationPlan(destination: .todoFolder, payloads: [], line: line, sent: numbered(texts), refused: refusal,
                        offersTodoFolder: false, cut: false, typed: nil)
    }

    /// Each text alone, or each under "1 of 3".
    static func numbered(_ texts: [String]) -> String {
        guard texts.count > 1 else { return texts.first ?? "" }
        let blocks: [String] = texts.enumerated().map { index, text in "\(index + 1) of \(texts.count)\n\n" + text }
        return blocks.joined(separator: "\n\n")
    }
}

extension DestinationPlan {
    /// The plan for the payloads `TaskPayload.render` gave for each task (nil where it gave none) at `destination`,
    /// with what the app knows. Every name the line shows (a list, a shortcut, a tracker, a tab) goes through `mask`.
    public static func make(rendered: [TaskPayload?], destination: TaskDestination, facts: DestinationFacts,
                            mask: (String) -> String = { SecretMask.current.mask($0) }) -> DestinationPlan {
        let payloads: [TaskPayload] = rendered.compactMap { $0 }
        let cut = payloads.contains { $0.cut }
        let count = rendered.count
        func refuse(_ line: String, todo: Bool) -> DestinationPlan {
            DestinationPlan(destination: destination, payloads: payloads, line: line,
                            sent: numbered(payloads.map(\.sent)), refused: true, offersTodoFolder: todo, cut: cut,
                            typed: nil)
        }
        if let problem = destination.problem { return refuse(mask(problem), todo: true) }
        guard count > 0, payloads.count == count else {
            return refuse("This destination can’t take the task.", todo: true)
        }
        if let refusal = refusal(destination, count: count, facts: facts, mask: mask) {
            return refuse(refusal.line, todo: refusal.todo)
        }
        var sent = numbered(payloads.map(\.sent))
        var typed: String?
        if case .throughAgent(let tracker) = destination, let tab = facts.agentTab {
            let request = agentRequest(payloads, tracker: mask(tracker))
            let text = tab.bracketedPaste ? request : oneLine(request)
            typed = text
            sent = text
        }
        let said = describe(destination, count: count, facts: facts, mask: mask)
        return DestinationPlan(destination: destination, payloads: payloads, line: said + (cut ? cutNote : ""),
                               sent: sent, refused: false, offersTodoFolder: false, cut: cut, typed: typed)
    }

    /// Why Add can't go there now, and whether Use Todo Folder is offered; nil when it can.
    static func refusal(_ destination: TaskDestination, count: Int, facts: DestinationFacts,
                        mask: (String) -> String) -> (line: String, todo: Bool)? {
        switch destination {
        case .reminders:
            if case .blocked(let line, _) = facts.reminders { return (line, true) }
        case .things, .todoist, .omnifocus:
            guard let kind = TaskLink.Kind(rawValue: destination.kind.rawValue) else { return nil }
            if !facts.installed.contains(kind) {
                return ("\(kind.name) isn’t installed: choose another destination or Use Todo Folder", true)
            }
            if kind != .things && count > pagesAtOnce {
                return ("\(kind.name) opens one Quick Add per task: add at most \(pagesAtOnce) at once.", false)
            }
        case .shortcut:
            if facts.shortcutListed == false { return (ShortcutList.goneLine, true) }
        case .github, .gitlab, .linear, .trello, .azureBoards:
            if count > pagesAtOnce, let name = pageName(destination) {
                return ("\(name) opens one page per task: add at most \(pagesAtOnce) at once.", false)
            }
        case .throughAgent:
            guard let tab = facts.agentTab else { return (noReadyTab, false) }
            let title = mask(tab.title)
            if let reason = tab.notReady {
                return ("“\(title)” (\(tab.agent.name)) isn’t ready: \(reason.text).", false)
            }
            if count > 1 && !tab.bracketedPaste { return (oneAtATime(title), false) }
        case .todoFolder:
            break
        }
        return nil
    }

    static func pageName(_ destination: TaskDestination) -> String? {
        switch destination {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        case .linear: return "Linear"
        case .trello: return "Trello"
        case .azureBoards: return "Azure Boards"
        default: return nil
        }
    }
}

extension DestinationPlan {
    /// The line for a destination Add can reach now.
    static func describe(_ destination: TaskDestination, count: Int, facts: DestinationFacts,
                         mask: (String) -> String) -> String {
        let one = count == 1
        let issues = one ? "a new issue" : "\(count) new issues"
        let create = "nothing is created until you press Create"
        switch destination {
        case .todoFolder:
            return ""
        case .reminders(_, let listName):
            let head = one ? "Adds to Reminders" : "Adds \(count) tasks to Reminders"
            let list = (facts.makesList == true ? "new list" : "list") + " “\(mask(listName))”"
            let day = facts.day.map { "due " + $0 } ?? "no due date"
            var line = [head, list, day].joined(separator: ", ")
            if case .explain = facts.reminders { line += " · Reminders asks for permission first" }
            return line
        case .things(let list):
            let into = one ? "Adds to Things" : "Adds \(count) tasks to Things"
            guard facts.day != nil || list != nil else { return into + "’ Inbox" }
            let day: String? = facts.day.map { "scheduled " + $0 }
            let place: String? = list.map { "in “\(mask($0))”" }
            return ([into] + [day, place].compactMap { $0 }).joined(separator: ", ")
        case .shortcut(_, let name):
            let each = one ? "" : " for each of \(count) tasks,"
            return "Runs the shortcut “\(mask(name))”\(each) with the task as its input"
        case .todoist, .omnifocus:
            let name = destination.kind == .todoist ? "Todoist" : "OmniFocus"
            let each = one ? "" : " for each of \(count) tasks"
            return "Opens \(name) Quick Add\(each), filled in: press Add there, and set the day there"
        case .github(let owner, let repo):
            return "Opens \(issues) in \(mask(owner))/\(mask(repo)) on github.com, filled in: \(create)"
        case .gitlab(let path):
            return "Opens \(issues) in \(mask(path)) on gitlab.com, filled in: \(create)"
        case .linear(let team?):
            return "Opens \(issues) in team \(mask(team)) on linear.app, filled in: \(create)"
        case .linear(nil):
            return "Opens \(issues) on linear.new, filled in: choose the team there; \(create)"
        case .trello:
            let each = one ? "" : " for each of \(count) tasks"
            return "Opens Trello’s Add Card\(each) with the title only: choose the board there"
        case .azureBoards(let org, let project, let type):
            let shownType = mask(type)
            let items = one ? "a new \(shownType)" : "\(count) new work items of type \(shownType)"
            return "Opens \(items) in \(mask(org))/\(mask(project)) on dev.azure.com, filled in: nothing is created "
                + "until you press Save"
        case .throughAgent(let tracker):
            guard let tab = facts.agentTab else { return noReadyTab }
            let what = one ? "it" : "\(count) tasks"
            return "Types a request to post \(what) to \(mask(tracker)) into “\(mask(tab.title))” (\(tab.agent.name)), "
                + "with no Return"
        }
    }

    /// One request for every task: a task's own request as rendered, or, for several, one ask and each task under
    /// "1.", "2."…, its lines after the first indented under its number.
    static func agentRequest(_ payloads: [TaskPayload], tracker: String) -> String {
        let texts: [String] = payloads.compactMap { payload in
            if case .agentRequest(let text) = payload.form { return text }
            return nil
        }
        guard texts.count > 1 else { return texts.first ?? "" }
        let ask = "Add these \(texts.count) tasks to \(tracker) with your \(tracker) tools, exactly as written, then "
            + "tell me their links."
        let tasks: [String] = texts.enumerated().map { index, text in
            // The task is what follows its own ask, which is one line and then a blank one.
            let task = text.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
            let lines: [String] = task.components(separatedBy: "\n")
            let indented: [String] = lines.enumerated().map { number, line in
                number == 0 || line.isEmpty ? line : "   " + line
            }
            return "\(index + 1). " + indented.joined(separator: "\n")
        }
        return ([ask] + tasks).joined(separator: "\n\n")
    }

    /// The request on one line, for a program without bracketed paste: every line break would be a Return there.
    public static func oneLineRequest(_ text: String) -> String { oneLine(text) }

    static func oneLine(_ text: String) -> String {
        let lines: [String] = text.components(separatedBy: .newlines)
        let kept: [String] = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return kept.joined(separator: " / ")
    }
}

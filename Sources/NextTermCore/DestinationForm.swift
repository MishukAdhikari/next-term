import Foundation

/// The details box of Settings › Tasks: one destination's fields as typed, the destination they build, why it can't be
/// saved yet, and Revert. Half-typed details are never saved: Save stays off until the fields build a destination that
/// passes its check and differs from the one saved, so a task added meanwhile still goes where it went. Pure: nothing
/// here is checked against a service.
public struct DestinationForm: Equatable, Sendable {
    /// What is saved for the scope being edited; nil when nothing is.
    public private(set) var saved: TaskDestination?
    public var kind: TaskDestination.Kind

    /// Reminders: the list's name, and its identifier while it is the saved list's.
    public var listName = DestinationChoices.remindersList
    public var listID: String?
    /// Things: a list or area; empty is the Inbox.
    public var thingsList = ""
    public var shortcutID = ""
    public var shortcutName = ""
    public var owner = ""
    public var repo = ""
    public var gitlabPath = ""
    /// Linear: a team key; empty lets Linear ask.
    public var team = ""
    public var org = ""
    public var project = ""
    public var azureType = TaskDestination.azureTypes[0]
    public var tracker = ""

    /// The saved destination's fields, on its kind (the todo folder when nothing is saved).
    public init(saved: TaskDestination?) {
        self.saved = saved
        kind = saved?.kind ?? .todoFolder
        if let saved { fill(saved) }
    }

    /// `kind`'s fields: the saved ones when the saved destination is of that kind, else empty.
    public init(kind: TaskDestination.Kind, saved: TaskDestination?) {
        self.init(saved: saved)
        if saved?.kind != kind { choose(kind) }
    }

    /// Another kind, its fields empty (the saved ones when it is the saved kind).
    public mutating func choose(_ kind: TaskDestination.Kind) {
        let keep = saved
        self = DestinationForm(saved: nil)
        saved = keep
        self.kind = kind
        if let keep, keep.kind == kind { fill(keep) }
    }

    /// Back to what is saved, fields and kind.
    public mutating func revert() { self = DestinationForm(saved: saved) }

    /// The form now describes what was just saved.
    public mutating func didSave() { self = DestinationForm(saved: destination) }

    private mutating func fill(_ destination: TaskDestination) {
        switch destination {
        case .todoFolder, .todoist, .omnifocus, .trello: break
        case .reminders(let id, let name): (listID, listName) = (id, name)
        case .things(let list): thingsList = list ?? ""
        case .shortcut(let id, let name): (shortcutID, shortcutName) = (id, name)
        case .github(let o, let r): (owner, repo) = (o, r)
        case .gitlab(let path): gitlabPath = path
        case .linear(let key): team = key ?? ""
        case .azureBoards(let o, let p, let type): (org, project, azureType) = (o, p, type)
        case .throughAgent(let name): tracker = name
        }
    }

    /// The destination the fields build, trimmed; it may fail its check (`problem`).
    public var destination: TaskDestination {
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }
        func optional(_ text: String) -> String? { trimmed(text).isEmpty ? nil : trimmed(text) }
        switch kind {
        case .todoFolder: return .todoFolder
        case .reminders:
            let name = optional(listName) ?? DestinationChoices.remindersList
            return .reminders(listID: name == trimmed(listName) ? listID : nil, listName: name)
        case .things: return .things(list: optional(thingsList))
        case .shortcut: return .shortcut(id: shortcutID, name: shortcutName)
        case .todoist: return .todoist
        case .omnifocus: return .omnifocus
        case .github: return .github(owner: trimmed(owner), repo: trimmed(repo))
        case .gitlab: return .gitlab(path: trimmed(gitlabPath))
        case .linear: return .linear(team: optional(team))
        case .trello: return .trello
        case .azureBoards:
            let type = TaskDestination.azureTypes.contains(azureType) ? azureType : TaskDestination.azureTypes[0]
            return .azureBoards(org: trimmed(org), project: trimmed(project), type: type)
        case .throughAgent: return .throughAgent(tracker: trimmed(tracker))
        }
    }

    /// Why the fields can't be saved, as the box shows it; nil when they can.
    public var problem: String? {
        if kind == .shortcut, shortcutID.isEmpty { return "Choose a shortcut." }
        return destination.problem
    }

    /// Save is on: the fields build a usable destination that isn't the one saved.
    public var canSave: Bool { problem == nil && destination != saved }

    /// The kinds that need nothing typed: choosing one saves it at once. Linear is one of them, since a team is
    /// optional, yet it still has a field (`hasFields`).
    public static func savesAtOnce(_ kind: TaskDestination.Kind) -> Bool {
        [.todoFolder, .todoist, .omnifocus, .trello, .linear].contains(kind)
    }

    /// The kinds with something to type or pick in the box, so with Save and Revert: every kind but the ones with
    /// nothing at all to fill. Linear's team key is saved on Save even though Linear without one saves at once.
    public static func hasFields(_ kind: TaskDestination.Kind) -> Bool {
        ![.todoFolder, .todoist, .omnifocus, .trello].contains(kind)
    }

    /// What choosing `kind` saves at once: the saved destination when it is that kind already, else the kind with no
    /// details; nil for a kind that waits for Save.
    public static func atOnce(_ kind: TaskDestination.Kind, saved: TaskDestination?) -> TaskDestination? {
        guard savesAtOnce(kind) else { return nil }
        if let saved, saved.kind == kind { return saved }
        return DestinationChoices.plain(kind)
    }
}

// MARK: the project's remote, and what each kind says

extension DestinationForm {
    /// Fills the repository from the project's `origin` URL; nil once filled, else the sentence the box shows and
    /// nothing filled. A user name or token in an https URL is dropped before the URL is read, so it never reaches a
    /// field, and the URL itself is never shown.
    public mutating func useRemote(_ remoteURL: String?) -> String? {
        guard let remoteURL else { return "This project has no remote named origin." }
        let host: RepositoryAddress.Host = kind == .gitlab ? .gitlab : .github
        let wrong = "This project’s remote isn’t on \(host.rawValue)."
        guard kind == .github || kind == .gitlab else { return wrong }
        guard let address = RepositoryAddress.parse(Self.withoutUser(remoteURL)), address.host == host else {
            return wrong
        }
        if host == .github {
            owner = address.owner
            repo = address.repo
        } else {
            gitlabPath = address.path
        }
        return nil
    }

    /// An https URL without the `user:token@` before its host; any other URL as it is.
    static func withoutUser(_ url: String) -> String {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = "https://"
        guard text.hasPrefix(scheme) else { return text }
        let rest = text.dropFirst(scheme.count)
        let authority = rest.prefix { $0 != "/" }
        guard let at = authority.lastIndex(of: "@") else { return text }
        return scheme + String(rest[rest.index(after: at)...])
    }

    /// The `origin` URL of the project's main checkout, read from its git config (`git remote get-url` makes no
    /// network request), or nil. The caller never shows it: it can carry a token.
    public static func originURL(project: String, git: String) -> String? {
        let root = TodoFolder.projectRoot(project)
        let arguments: [String] = ["-C", root, "remote", "get-url", "origin"]
        guard let data = GitRunner.run(git, arguments, timeout: 5) else { return nil }
        let url = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return url.isEmpty ? nil : url
    }

    /// The one line a kind with nothing to fill shows in the box (Things' too, beside its optional list); nil for a
    /// kind whose fields say it.
    public static func note(_ kind: TaskDestination.Kind) -> String? {
        switch kind {
        case .todoFolder: return "Each task is a Markdown file in the project’s todo folder, for your agents to read."
        case .todoist: return "Todoist’s Quick Add opens with the title and notes; add it and set the day there."
        case .omnifocus: return "OmniFocus’s Quick Add opens with the title and notes; save it and set the day there."
        case .things: return "Things gets the title, notes and the day."
        case .trello: return "Trello asks for the board on its own page; Next Term sends the card’s name."
        default: return nil
        }
    }

    /// Said once, when Things is first chosen.
    public static let thingsEnableNote = "Things asks once whether to enable Things URLs. Choose Enable."
}

// MARK: the popups' rows

extension DestinationForm {
    /// One row of Settings › Tasks' Default and This project popups: a kind, or a held one greyed with why.
    public struct ChoiceRow: Equatable, Sendable {
        public let kind: TaskDestination.Kind?
        public let title: String
        public let enabled: Bool
        public let tip: String?
    }

    /// Every kind in the order every list of destinations takes, by its name alone; one that can't be chosen now
    /// (an app not installed, Reminders not allowed) says why, and the held destinations sit greyed where they would go.
    public static func rows(facts: DestinationFacts) -> [ChoiceRow] {
        var rows: [ChoiceRow] = []
        for kind in DestinationChoices.order {
            let why = DestinationChoices.unavailable(kind, facts: facts)
            let title = DestinationChoices.kindName(kind) + (why.map { " · " + $0 } ?? "")
            let tip = why == nil ? nil : DestinationChoices.unavailableTip(kind)
            rows.append(ChoiceRow(kind: kind, title: title, enabled: why == nil, tip: tip))
            for hold in DestinationChoices.held where hold.after == kind {
                rows.append(ChoiceRow(kind: nil, title: hold.title, enabled: false, tip: hold.tip))
            }
        }
        return rows
    }
}

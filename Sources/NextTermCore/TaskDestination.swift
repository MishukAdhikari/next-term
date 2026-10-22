import Foundation

/// Where a task goes: the todo folder (the default), an app on this Mac, a page the user finishes in the browser, or
/// the user's agent. Saved as JSON in Next Term's settings, never in a repository, so nothing in a project can send
/// the user's tasks elsewhere. A value read back is used only when every field passes its check; a bad one is never
/// repaired into another place.
public enum TaskDestination: Equatable, Hashable, Sendable {
    case todoFolder
    /// A Reminders list: its identifier when known, and its name, which is what is looked for when the identifier is gone.
    case reminders(listID: String?, listName: String)
    /// Things, in a named list or area, or its Inbox.
    case things(list: String?)
    /// A shortcut, by the identifier `shortcuts list --show-identifiers` prints, and its name as shown.
    case shortcut(id: String, name: String)
    case todoist
    case omnifocus
    case github(owner: String, repo: String)
    /// A gitlab.com project path, groups and subgroups included.
    case gitlab(path: String)
    /// A Linear team by its key, or none: Linear asks.
    case linear(team: String?)
    case trello
    case azureBoards(org: String, project: String, type: String)
    /// Posted by the user's agent with its own tools for this tracker; the name is only what is shown.
    case throughAgent(tracker: String)

    /// The one spelling of each kind, shared by the settings, the posted record and add_task's answer.
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case todoFolder = "todo_folder", reminders, things, shortcut, todoist, omnifocus, github, gitlab, linear, trello
        case azureBoards = "azure_boards", throughAgent = "through_agent"
    }

    public var kind: Kind {
        switch self {
        case .todoFolder: return .todoFolder
        case .reminders: return .reminders
        case .things: return .things
        case .shortcut: return .shortcut
        case .todoist: return .todoist
        case .omnifocus: return .omnifocus
        case .github: return .github
        case .gitlab: return .gitlab
        case .linear: return .linear
        case .trello: return .trello
        case .azureBoards: return .azureBoards
        case .throughAgent: return .throughAgent
        }
    }

    /// Azure Boards work item types offered. Which exist depends on the project's process.
    public static let azureTypes = ["Task", "Bug", "User Story", "Issue", "Product Backlog Item"]
    /// The most segments a gitlab.com path may have.
    public static let gitlabSegments = 20
    /// The longest tracker name.
    public static let trackerLength = 40

    /// Why this value can't be used, as Settings › Tasks shows it; nil when it can.
    public var problem: String? {
        switch self {
        case .todoFolder, .todoist, .omnifocus, .trello, .things(list: nil), .linear(team: nil): return nil
        case .reminders(let listID, let listName):
            if let listID, !Self.isOneLine(listID) { return "The Reminders list’s identifier is not one line." }
            return Self.isOneLine(listName) ? nil : "The Reminders list needs a name of one line."
        case .things(let list?):
            return Self.isOneLine(list) ? nil : "The Things list needs a name of one line."
        case .shortcut(let id, let name):
            return Self.isOneLine(id) && Self.isOneLine(name) ? nil : "The shortcut needs its identifier and name."
        case .github(let owner, let repo):
            return Self.nameProblem(owner, "GitHub owner") ?? Self.nameProblem(repo, "GitHub repository")
        case .gitlab(let path):
            let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard segments.count >= 2, segments.count <= Self.gitlabSegments else {
                return "A GitLab path is a group and a project, with at most \(Self.gitlabSegments) parts."
            }
            return segments.lazy.compactMap { Self.nameProblem($0, "GitLab path part") }.first
        case .linear(let team?):
            let letters = team.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
            return letters && (1...10).contains(team.count) ? nil : "A Linear team key is 1 to 10 letters and digits."
        case .azureBoards(let org, let project, let type):
            guard Self.isOneLine(org), Self.isOneLine(project) else {
                return "Azure Boards needs an organization and a project."
            }
            return Self.azureTypes.contains(type) ? nil : "Azure Boards can’t make a work item of type “\(type)”."
        case .throughAgent(let tracker):
            guard Self.isOneLine(tracker), tracker.count <= Self.trackerLength else {
                return "A tracker’s name is one line of 1 to \(Self.trackerLength) characters."
            }
            return nil
        }
    }

    /// Text with something in it and no line break.
    static func isOneLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && text.rangeOfCharacter(from: .newlines) == nil
    }

    /// A GitHub owner or repository, or one part of a GitLab path: letters, digits, `.`, `_` and `-`, up to 100,
    /// and never `.` or `..` alone, so the name stays one part of a page's path.
    static func nameProblem(_ name: String, _ what: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let fits = name.unicodeScalars.allSatisfy { allowed.contains($0) }
        let length = name.unicodeScalars.count
        guard fits, length >= 1, length <= 100, name != ".", name != ".." else {
            return "A \(what) uses only letters, digits, “.”, “_” and “-”, up to 100."
        }
        return nil
    }
}

/// Saved as `{"kind": …, …}`, with only the fields of that kind. Reading back refuses a kind this version doesn't know,
/// a missing field and a field that fails its check, each with the reason Settings shows.
extension TaskDestination: Codable {
    enum Field: String, CodingKey {
        case kind, listID, listName, list, id, name, owner, repo, path, team, org, project, type, tracker
    }

    /// Why a saved destination was not read, as Settings › Tasks shows it.
    struct Unusable: Error {
        let problem: String
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        guard let raw = try? c.decode(String.self, forKey: .kind) else {
            throw Unusable(problem: "The saved destination has no kind.")
        }
        guard let kind = Kind(rawValue: raw) else {
            throw Unusable(problem: "The saved destination is one this version of Next Term doesn’t know.")
        }
        let value: TaskDestination
        do {
            value = try Self.decode(kind, c)
        } catch is DecodingError {
            throw Unusable(problem: "The saved destination is missing some of its details.")
        }
        if let problem = value.problem { throw Unusable(problem: problem) }
        self = value
    }

    static func decode(_ kind: Kind, _ c: KeyedDecodingContainer<Field>) throws -> TaskDestination {
        switch kind {
        case .todoFolder: return .todoFolder
        case .reminders:
            let listID = try c.decodeIfPresent(String.self, forKey: .listID)
            return .reminders(listID: listID, listName: try c.decode(String.self, forKey: .listName))
        case .things: return .things(list: try c.decodeIfPresent(String.self, forKey: .list))
        case .shortcut:
            let id = try c.decode(String.self, forKey: .id)
            return .shortcut(id: id, name: try c.decode(String.self, forKey: .name))
        case .todoist: return .todoist
        case .omnifocus: return .omnifocus
        case .github:
            let owner = try c.decode(String.self, forKey: .owner)
            return .github(owner: owner, repo: try c.decode(String.self, forKey: .repo))
        case .gitlab: return .gitlab(path: try c.decode(String.self, forKey: .path))
        case .linear: return .linear(team: try c.decodeIfPresent(String.self, forKey: .team))
        case .trello: return .trello
        case .azureBoards:
            let org = try c.decode(String.self, forKey: .org)
            let project = try c.decode(String.self, forKey: .project)
            return .azureBoards(org: org, project: project, type: try c.decode(String.self, forKey: .type))
        case .throughAgent: return .throughAgent(tracker: try c.decode(String.self, forKey: .tracker))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(kind.rawValue, forKey: .kind)
        switch self {
        case .todoFolder, .todoist, .omnifocus, .trello: break
        case .reminders(let listID, let listName):
            try c.encodeIfPresent(listID, forKey: .listID)
            try c.encode(listName, forKey: .listName)
        case .things(let list): try c.encodeIfPresent(list, forKey: .list)
        case .shortcut(let id, let name):
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
        case .github(let owner, let repo):
            try c.encode(owner, forKey: .owner)
            try c.encode(repo, forKey: .repo)
        case .gitlab(let path): try c.encode(path, forKey: .path)
        case .linear(let team): try c.encodeIfPresent(team, forKey: .team)
        case .azureBoards(let org, let project, let type):
            try c.encode(org, forKey: .org)
            try c.encode(project, forKey: .project)
            try c.encode(type, forKey: .type)
        case .throughAgent(let tracker): try c.encode(tracker, forKey: .tracker)
        }
    }

    /// The JSON saved in the settings; nil for a value that fails its check, so a bad value is never saved.
    public static func json(_ destination: TaskDestination) -> String? {
        guard destination.problem == nil else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(destination) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A saved value read back: the destination, or nil and why it can't be used.
    public static func read(_ json: String) -> (destination: TaskDestination?, problem: String?) {
        do {
            return (try JSONDecoder().decode(TaskDestination.self, from: Data(json.utf8)), nil)
        } catch let unusable as Unusable {
            return (nil, unusable.problem)
        } catch {
            return (nil, "The saved destination can’t be read.")
        }
    }
}

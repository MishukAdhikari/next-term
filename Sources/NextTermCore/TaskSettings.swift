import Foundation

/// Settings › Tasks: where the todo folder is, and whether a new task says where it was added. Read from the defaults
/// each time a task is added, so a change applies at once.
public struct TaskSettings: Equatable, Sendable {
    /// The folder in each project when nothing else is chosen.
    public static let defaultFolder = "todo"

    /// The todo folder: a path inside each project (`todo`, `docs/todo`), or one absolute folder for every project.
    public var folder = defaultFolder
    /// The folder for a window with no project, absolute; nil: a task there needs a project.
    public var outsideFolder: String?
    /// "Add where you are to new tasks": the branch, the tab and its agent go in the file's front matter.
    public var includeContext = true
    /// Where a project's tasks go when the project names no place of its own; nil: the todo folder.
    public var defaultDestination: TaskDestination?
    /// Why the saved default can't be used, as Settings shows it; the todo folder is used meanwhile.
    public var defaultDestinationProblem: String?
    /// Each project's own choices, by its key (`projectKey`): kept here, never in the repository, so nothing in a
    /// project can send the user's tasks somewhere else.
    public var projects: [String: ProjectTasks] = [:]
    /// Why the saved projects can't be read at all; each project then uses the default.
    public var projectsProblem: String?
    /// A reminder gets an alert at 9:00 on its day. Off unless the user turns it on.
    public var remindersAlarm = false
    /// The one-time offer of another destination in the Add Task sheet: still to show, or shown and answered.
    public var destinationOffer = DestinationOffer.pending

    public enum DestinationOffer: String, Sendable {
        case pending, done
    }

    /// Where each is kept in the defaults.
    public enum Key {
        public static let folder = "tasks.folder"
        public static let outsideFolder = "tasks.outsideFolder"
        public static let includeContext = "tasks.includeContext"
        public static let defaultDestination = "tasks.defaultDestination"
        public static let projects = "tasks.projects"
        public static let remindersAlarm = "tasks.remindersAlarm"
        public static let destinationOffer = "tasks.destinationOffer"
        public static let all = [folder, outsideFolder, includeContext, defaultDestination, projects, remindersAlarm,
                                 destinationOffer]
    }

    public init(folder: String = defaultFolder, outsideFolder: String? = nil, includeContext: Bool = true) {
        self.folder = folder
        self.outsideFolder = outsideFolder
        self.includeContext = includeContext
    }

    /// What is saved, with the default for anything missing or empty. An outside folder that is not absolute is none.
    public init(defaults: UserDefaults) {
        let folder = defaults.string(forKey: Key.folder)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.folder = folder.isEmpty ? Self.defaultFolder : folder
        let outside = defaults.string(forKey: Key.outsideFolder)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        outsideFolder = Self.isAbsolute(outside) ? outside : nil
        includeContext = defaults.object(forKey: Key.includeContext) as? Bool ?? true
        if let json = defaults.string(forKey: Key.defaultDestination) {
            (defaultDestination, defaultDestinationProblem) = TaskDestination.read(json)
        }
        if let json = defaults.string(forKey: Key.projects) {
            if let read = try? JSONDecoder().decode([String: ProjectTasks].self, from: Data(json.utf8)) {
                projects = read
            } else {
                projectsProblem = "The saved choices for each project can’t be read."
            }
        }
        remindersAlarm = defaults.object(forKey: Key.remindersAlarm) as? Bool ?? false
        let offer = defaults.string(forKey: Key.destinationOffer).flatMap(DestinationOffer.init(rawValue:))
        destinationOffer = offer ?? .pending
    }

    /// Where a task in the project with this key goes: the project's own destination, else the default, else the
    /// todo folder. A value that failed its check counts as unset, never as another place.
    public func destination(for projectKey: String?) -> TaskDestination {
        if let projectKey, let own = projects[projectKey]?.destination { return own }
        return defaultDestination ?? .todoFolder
    }

    /// A project's key: its main checkout, canonical, so every worktree of one repository shares one set of choices.
    /// A bare repository's worktree has no main checkout and keys by its own path, as the todo folder does.
    public static func projectKey(_ project: String) -> String {
        TodoFolder.projectRoot(project)
    }

    /// The JSON saved for every project's choices.
    public static func json(projects: [String: ProjectTasks]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(projects) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// One folder for every project (`/…` or `~/…`), not a path in each.
    public var isShared: Bool { Self.isAbsolute(folder) }

    static func isAbsolute(_ path: String) -> Bool { path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") }
}

/// One project's own Tasks choices. A destination that fails its check is read as none, with the reason kept for
/// Settings, so the project falls back to the default instead of going anywhere else.
public struct ProjectTasks: Equatable, Sendable, Codable {
    public var destination: TaskDestination?
    /// Where Wrap Up's handoffs go in this project, relative to it; nil: the default.
    public var handoffFolder: String?
    /// Why the saved destination can't be used; never saved.
    public var problem: String?

    enum CodingKeys: String, CodingKey {
        case destination, handoffFolder
    }

    public init(destination: TaskDestination? = nil, handoffFolder: String? = nil) {
        self.destination = destination
        self.handoffFolder = handoffFolder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handoffFolder = try? c.decodeIfPresent(String.self, forKey: .handoffFolder)
        do {
            destination = try c.decodeIfPresent(TaskDestination.self, forKey: .destination)
        } catch let unusable as TaskDestination.Unusable {
            problem = unusable.problem
        } catch {
            problem = "The saved destination can’t be read."
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(destination, forKey: .destination)
        try c.encodeIfPresent(handoffFolder, forKey: .handoffFolder)
    }
}

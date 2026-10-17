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

    /// Where each is kept in the defaults.
    public enum Key {
        public static let folder = "tasks.folder"
        public static let outsideFolder = "tasks.outsideFolder"
        public static let includeContext = "tasks.includeContext"
        public static let all = [folder, outsideFolder, includeContext]
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
    }

    /// One folder for every project (`/…` or `~/…`), not a path in each.
    public var isShared: Bool { Self.isAbsolute(folder) }

    static func isAbsolute(_ path: String) -> Bool { path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") }
}

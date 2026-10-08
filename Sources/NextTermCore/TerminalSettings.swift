import Foundation

// Settings › Terminal: the cursor, how much scrollback a tab keeps and where a new tab starts. The app
// stores and applies them (TerminalBehaviour.swift); an import can fill them (Import*.swift).

/// The terminal cursor's shape. Programs can still change it (vim's bar in insert mode); when one puts it
/// back to the default, it returns to this.
public enum CursorShape: String, CaseIterable, Sendable {
    case block, bar, underline

    public var title: String {
        switch self {
        case .block: return "Block"
        case .bar: return "Bar"
        case .underline: return "Underline"
        }
    }
}

/// How many lines a terminal keeps above the screen (10,000 unless chosen: NextTermView.scrollbackLines).
public enum Scrollback {
    public static let range = 1_000...100_000

    public static func clamped(_ lines: Int) -> Int { min(range.upperBound, max(range.lowerBound, lines)) }
}

/// Where ⌘T opens a tab.
public enum StartFolder: Equatable, Sendable {
    /// The window's project; in a window without one, the folder of the tab in front.
    case project
    /// The folder of the tab in front, in a project window too.
    case current
    case home
    /// A folder of the user's choosing (absolute).
    case folder(String)

    public static let standard = StartFolder.project

    /// As saved: "project", "current", "home" or the folder's path.
    public init(stored: String?) {
        switch stored {
        case "current": self = .current
        case "home": self = .home
        case let path? where path.hasPrefix("/"): self = .folder(path)
        default: self = .project
        }
    }

    public var stored: String {
        switch self {
        case .project: return "project"
        case .current: return "current"
        case .home: return "home"
        case .folder(let path): return path
        }
    }

    /// The folder a new tab starts in. `project`: the window's (nil for none); `current`: the folder of the tab
    /// in front (nil for none, or one on a server). A chosen folder that is gone falls back to the project's
    /// rule, so a tab still opens; nil leaves it to the shell (the home folder).
    public func directory(project: String?, current: String?, home: String, exists: (String) -> Bool) -> String? {
        switch self {
        case .project: return project ?? current
        case .current: return current ?? project
        case .home: return home
        case .folder(let path): return exists(path) ? path : project ?? current
        }
    }
}

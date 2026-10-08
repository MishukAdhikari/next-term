import Foundation

// Settings › General: what a launch that names no folder or file shows, and whether a quit with project
// windows open asks about reopening them. A launch that names one always opens it directly.

/// "When Next Term opens:".
public enum LaunchOpens: String, CaseIterable, Sendable {
    case welcome, lastProjects

    /// For new users, and for existing users after the update that brought the choice.
    public static let standard = LaunchOpens.welcome

    public var title: String {
        switch self {
        case .welcome: return "Show the Welcome window"
        case .lastProjects: return "Reopen the projects that were open"
        }
    }
}

/// The choices in Settings › General, read from the defaults at each launch, reopen and quit, so a change
/// applies from the next one. The answer to the reopen question at a quit sets them too.
public struct LaunchSettings: Equatable, Sendable {
    /// "When Next Term opens:".
    public var opens = LaunchOpens.standard
    /// "Ask whether to reopen projects when quitting": the reopen prompt, or the checkbox on the
    /// save-changes or "Quitting stops…" alert. Unsaved files and running work are asked about anyway.
    public var askToReopenOnQuit = true

    /// Where each is kept in the defaults.
    public enum Key {
        public static let opens = "launchOpens"
        public static let askToReopenOnQuit = "askToReopenOnQuit"
        public static let all = [opens, askToReopenOnQuit]
    }

    public init() {}

    /// What is saved, with the default for anything missing or not one of the choices. There is no
    /// migration: an existing user, who never saved either, gets the Welcome window too.
    public init(defaults: UserDefaults) {
        opens = LaunchOpens(rawValue: defaults.string(forKey: Key.opens) ?? "") ?? .standard
        askToReopenOnQuit = defaults.object(forKey: Key.askToReopenOnQuit) as? Bool ?? true
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(opens.rawValue, forKey: Key.opens)
        defaults.set(askToReopenOnQuit, forKey: Key.askToReopenOnQuit)
    }
}

import Foundation

// Settings › General: what a launch that names no folder or file shows, whether a quit with a terminal window open asks
// about resuming, and whether a restore brings scrollback back. A launch that names one always opens it too.

/// "At launch:".
public enum LaunchOpens: String, CaseIterable, Sendable {
    /// In the order of the radio buttons. "Open a new terminal" is kept as `newTerminal`: a build from before it reads that
    /// as any value it does not know, the Welcome window.
    case welcome, lastProjects, newTerminal

    /// For new users, and for existing users who never chose: the windows open at the last quit come back, as a Mac app
    /// restores its state. A first launch has nothing to bring back, and shows the Welcome window (LaunchDecision). A
    /// choice stored, even the Welcome window, stays.
    public static let standard = LaunchOpens.lastProjects

    /// "Resume where I left off" keeps 0.10's stored value, `lastProjects`, so a choice of "Reopen the projects that were
    /// open" carries over. "Open a new terminal" is for the user who wants a shell at once and never the Welcome window.
    public var title: String {
        switch self {
        case .welcome: return "Show the Welcome window"
        case .lastProjects: return "Resume where I left off"
        case .newTerminal: return "Open a new terminal"
        }
    }
}

/// The choices in Settings › General, read from the defaults at each launch, reopen and quit, so a change
/// applies from the next one. The answer to a quit's resume question sets "At launch" and "At quit" too.
public struct LaunchSettings: Equatable, Sendable {
    /// "At launch:". Setting it counts as choosing it.
    public var opens = LaunchOpens.standard {
        didSet { opensChosen = true }
    }
    /// "At launch" was chosen: it is stored, or was set since. Never chosen reads as Resume, and a quit's resume checkbox
    /// then starts checked.
    public private(set) var opensChosen = false
    /// "Ask whether to resume when quitting": the plain quit dialog, or the checkbox on the save-changes or "Quitting
    /// stops…" alert. Unsaved files and running work are asked about anyway.
    public var askToReopenOnQuit = true
    /// "Keep scrollback": an update or quit restore brings shell output back (R4).
    public var keepScrollback = true

    /// Where each is kept in the defaults.
    public enum Key {
        public static let opens = "launchOpens"
        public static let askToReopenOnQuit = "askToReopenOnQuit"
        public static let keepScrollback = "keepScrollback"
        public static let all = [opens, askToReopenOnQuit, keepScrollback]
    }

    /// One of the settings, saved on its own: each control in Settings › General saves only its own key.
    public enum Setting: CaseIterable, Sendable {
        case opens, askToReopenOnQuit, keepScrollback
    }

    public init() {}

    /// What is saved, with the default for anything missing or not one of the choices. There is no
    /// migration: an existing user, who never saved one, gets Resume too.
    public init(defaults: UserDefaults) {
        if let stored = LaunchOpens(rawValue: defaults.string(forKey: Key.opens) ?? "") {
            opens = stored
            opensChosen = true
        }
        askToReopenOnQuit = defaults.object(forKey: Key.askToReopenOnQuit) as? Bool ?? true
        keepScrollback = defaults.object(forKey: Key.keepScrollback) as? Bool ?? true
    }

    /// Saves every setting: "At launch" only once it was chosen.
    public func save(to defaults: UserDefaults) {
        for setting in Setting.allCases { save(setting, to: defaults) }
    }

    /// Saves one setting and touches no other key. "At launch" is saved only once it was chosen.
    public func save(_ setting: Setting, to defaults: UserDefaults) {
        switch setting {
        case .opens:
            if opensChosen { defaults.set(opens.rawValue, forKey: Key.opens) }
        case .askToReopenOnQuit:
            defaults.set(askToReopenOnQuit, forKey: Key.askToReopenOnQuit)
        case .keepScrollback:
            defaults.set(keepScrollback, forKey: Key.keepScrollback)
        }
    }
}

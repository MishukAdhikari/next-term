import Foundation

/// An agent started in the home folder of a window with no project reads that folder as its project: Desktop,
/// Documents and the rest of it, each of which macOS asks about, in Next Term's name. So the window offers once, in a
/// notice, to choose a project folder for it, with Don't Ask Again. The offer never stops, holds or delays the agent.
public enum HomeAgentOffer {
    /// The setting, in the app's defaults: false once the user chose Don't Ask Again. Absent, it is on.
    public static let key = "offerProjectForAgentsInHome"

    /// Whether the offer is on in `defaults`.
    public static func isOn(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    /// Don't Ask Again.
    public static func turnOff(_ defaults: UserDefaults) {
        defaults.set(false, forKey: key)
    }

    /// Whether a window offers it now: it has no project, has not offered it yet, and a tab here on this Mac runs an
    /// agent Next Term recognises whose folder is the home folder. `on`: the setting.
    public static func offers(on: Bool, windowProject: String?, offered: Bool, tabs: [Tab], home: String) -> Bool {
        guard on, windowProject == nil, !offered else { return false }
        let home: String = ProtectedPlaces.trimmed(home)
        return tabs.contains { (tab: Tab) -> Bool in
            tab.runsAgent && !tab.remote && ProtectedPlaces.trimmed(tab.directory) == home
        }
    }

    /// What the rule needs of a tab.
    public struct Tab: Sendable, Equatable {
        public var directory: String
        public var runsAgent: Bool
        public var remote: Bool

        public init(directory: String, runsAgent: Bool, remote: Bool = false) {
            self.directory = directory
            self.runsAgent = runsAgent
            self.remote = remote
        }
    }

    /// The notice's line: "Claude Code is working in your home folder. Open a project for it?"
    public static func text(agent: String) -> String {
        "\(agent) is working in your home folder. Open a project for it?"
    }
}

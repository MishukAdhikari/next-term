import Foundation

// Settings › Notifications: which of a tab's notices become a macOS notification. Only the notification:
// the tab marks, the Dock badge and VoiceOver's announcements come whatever is chosen here.

/// When a command that is not an agent (a build, a test run) finishes or fails.
public enum CommandNotifications: String, CaseIterable, Sendable {
    case inAnotherApp, always, never

    /// While you are in Next Term the tab mark says it already.
    public static let standard = CommandNotifications.inAnotherApp

    public var title: String {
        switch self {
        case .inAnotherApp: return "Only when I’m in another app"
        case .always: return "Always, for tabs I’m not looking at"
        case .never: return "Never"
        }
    }
}

/// Finished work notifies only when it took at least this long.
public enum WorkThreshold: Int, CaseIterable, Sendable {
    case fiveSeconds = 5, thirtySeconds = 30, oneMinute = 60, fiveMinutes = 300

    public static let standard = WorkThreshold.fiveSeconds

    public var seconds: TimeInterval { TimeInterval(rawValue) }

    public var title: String {
        switch self {
        case .fiveSeconds: return "5 seconds"
        case .thirtySeconds: return "30 seconds"
        case .oneMinute: return "1 minute"
        case .fiveMinutes: return "5 minutes"
        }
    }
}

extension TabNotice {
    /// Which of the settings speaks for a notice.
    public enum Topic: Sendable {
        /// An agent is blocked on your decision (it asked a question).
        case decision
        /// An agent stopped and waits for your next prompt, or exited.
        case agentFinished
        /// Any other command finished or failed.
        case commandFinished
        /// The program rang the bell, or sent its own notification (OSC 9 / OSC 777).
        case programAlert
        /// Next Term's own call to the tab: ssh asking for a password in a remote tab.
        case otherAlert
    }

    public var topic: Topic {
        if question != nil { return .decision }
        if state == .attention { return fromProgram ? .programAlert : .otherAlert }
        return kind == .agent ? .agentFinished : .commandFinished
    }
}

/// The choices in Settings › Notifications, read from the defaults each time a notice comes, so a change
/// applies at once. Pure: told whether Next Term is the active app and whether the tab is on screen, it
/// says whether a notice becomes a notification.
public struct NotificationSettings: Equatable, Sendable {
    /// "When an agent needs your decision".
    public var decisions = true
    /// "When an agent finishes": also while Next Term is in front, for a tab you are not looking at.
    public var agentFinished = true
    /// "When a command finishes or fails".
    public var commands = CommandNotifications.standard
    /// "Only for work that took at least": finished work only. A decision or a bell always counts.
    public var threshold = WorkThreshold.standard
    /// "Play a sound".
    public var sound = true
    /// "A program’s own bell or notification (OSC 9/777)".
    public var programAlerts = true

    /// Where each is kept in the defaults.
    public enum Key {
        public static let decisions = "notifyDecisions"
        public static let agentFinished = "notifyAgentFinished"
        public static let commands = "notifyCommands"
        public static let threshold = "notifyThresholdSeconds"
        public static let sound = "notificationSound"
        public static let programAlerts = "notifyProgramAlerts"
        public static let all = [decisions, agentFinished, commands, threshold, sound, programAlerts]
    }

    public init() {}

    /// What is saved, with the default for anything missing or not one of the choices.
    public init(defaults: UserDefaults) {
        decisions = defaults.object(forKey: Key.decisions) as? Bool ?? true
        agentFinished = defaults.object(forKey: Key.agentFinished) as? Bool ?? true
        commands = CommandNotifications(rawValue: defaults.string(forKey: Key.commands) ?? "") ?? .standard
        threshold = WorkThreshold(rawValue: defaults.integer(forKey: Key.threshold)) ?? .standard
        sound = defaults.object(forKey: Key.sound) as? Bool ?? true
        programAlerts = defaults.object(forKey: Key.programAlerts) as? Bool ?? true
    }

    /// Whether `notice` becomes a notification. Never for the tab you are looking at (`tabVisible`: the
    /// active tab of the key window, its terminal on screen); `appActive` is whether Next Term is in front.
    public func shouldNotify(_ notice: TabNotice, appActive: Bool, tabVisible: Bool) -> Bool {
        if tabVisible { return false }
        let longEnough = notice.duration >= threshold.seconds
        switch notice.topic {
        case .decision:
            return decisions
        case .agentFinished:
            return agentFinished && longEnough
        case .commandFinished:
            guard longEnough else { return false }
            switch commands {
            case .inAnotherApp: return !appActive
            case .always: return true
            case .never: return false
            }
        case .programAlert:
            // In Next Term, the amber mark says it.
            return programAlerts && !appActive
        case .otherAlert:
            return !appActive
        }
    }
}

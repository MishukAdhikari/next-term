import Foundation

/// What the last check for skill updates found for one installed skill.
public enum SkillUpdateState: Equatable, Sendable, Codable {
    case current
    case available(commit: String)
    /// The repository or the skill's folder is gone, or GitHub refused.
    case unknown(String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Agents › Skills… says how many installed skills have an update: as the menu item's badge on macOS 14 and later,
/// in its title on macOS 13. A quiet check keeps the count, once a day at most.
public enum SkillUpdates {
    /// The skills the last check found an update for.
    public static func count(_ answers: [String: SkillUpdateState]) -> Int {
        answers.values.filter(\.isAvailable).count
    }

    /// "1 update", "2 updates"; nil with none.
    public static func phrase(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 update" : "\(count) updates"
    }

    /// The menu item's title where there is no badge (macOS 13): "Skills… (2 updates)", or the title alone with none.
    public static func title(_ title: String, count: Int) -> String {
        guard let phrase = phrase(count) else { return title }
        return "\(title) (\(phrase))"
    }

    /// The quiet check runs once a day at most.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// Whether the quiet check is due: never checked, or the last check a day ago or more. A last check more than a day
    /// ahead of the clock (it was set back) counts as none, so the check never waits longer than two days.
    public static func isDue(now: Date, lastCheck: Date?) -> Bool {
        guard let lastCheck else { return true }
        let age = now.timeIntervalSince(lastCheck)
        return age >= interval || age < -interval
    }

    /// The last check's answers, kept across launches (as JSON) so a relaunch within the day still shows the count.
    public static func encode(_ answers: [String: SkillUpdateState]) -> Data? {
        try? JSONEncoder().encode(answers)
    }

    /// Kept answers, or none when there are none or they can't be read.
    public static func decode(_ data: Data?) -> [String: SkillUpdateState] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: SkillUpdateState].self, from: data)) ?? [:]
    }
}

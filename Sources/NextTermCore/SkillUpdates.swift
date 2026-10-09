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

    /// After a quiet check no source answered (offline, GitHub's hourly limit), how long before it tries again.
    public static let retry: TimeInterval = 60 * 60

    /// Whether the quiet check is due: never checked, or the last check a day ago or more. A last check more than a day
    /// ahead of the clock (it was set back) counts as none, so the check never waits longer than two days. A quiet check
    /// that got no answer doesn't count as the day's: it holds the next try back an hour (`lastFailure`), no more.
    public static func isDue(now: Date, lastCheck: Date?, lastFailure: Date? = nil) -> Bool {
        if let lastFailure, (0..<retry).contains(now.timeIntervalSince(lastFailure)) { return false }
        guard let lastCheck else { return true }
        let age = now.timeIntervalSince(lastCheck)
        return age >= interval || age < -interval
    }

    /// What a quiet check keeps, from its `answers` and the skills whose source couldn't be asked (`unreached`: offline,
    /// GitHub's hourly limit). Such a skill keeps its `last` answer while there is one, so a failure never hides a count
    /// already known; with no source answered at all it is nil: nothing changes, and the check didn't happen. A check
    /// the user starts shows every failure instead.
    public static func quietAnswers(_ answers: [String: SkillUpdateState], unreached: Set<String>,
                                    last: [String: SkillUpdateState]) -> [String: SkillUpdateState]? {
        guard answers.keys.contains(where: { !unreached.contains($0) }) else { return nil }
        var kept = answers
        for name in unreached {
            if let previous = last[name] { kept[name] = previous }
        }
        return kept
    }

    /// The answers for skills still installed from GitHub (`tracked`): one removed outside Next Term (`npx skills remove`
    /// in a tab) leaves the count, after a relaunch too.
    public static func pruned(_ answers: [String: SkillUpdateState], tracked: Set<String>) -> [String: SkillUpdateState] {
        answers.filter { tracked.contains($0.key) }
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

import Foundation
import Testing
@testable import NextTermCore

/// Agents › Skills…' count of skill updates, its title where there is no badge, and the quiet check's once-a-day rule.
@Suite struct SkillUpdatesTests {
    let start = Date(timeIntervalSince1970: 1_760_000_000)

    func hours(_ hours: Double) -> Date { start.addingTimeInterval(hours * 3600) }

    @Test func countsOnlyAvailableUpdates() {
        #expect(SkillUpdates.count([:]) == 0) // no check has run
        let answers: [String: SkillUpdateState] = [
            "release-notes": .available(commit: "abc"), "tidy-prose": .current, "gone": .unknown("Its folder is no longer in a/b."),
            "pdf": .available(commit: "def"),
        ]
        #expect(SkillUpdates.count(answers) == 2)
        #expect(SkillUpdates.count(["tidy-prose": .current, "gone": .unknown("GitHub refused.")]) == 0)
        #expect(SkillUpdateState.available(commit: "abc").isAvailable && !SkillUpdateState.current.isAvailable)
    }

    @Test func titleWithoutABadge() {
        #expect(SkillUpdates.title("Skills…", count: 0) == "Skills…")
        #expect(SkillUpdates.title("Skills…", count: 1) == "Skills… (1 update)")
        #expect(SkillUpdates.title("Skills…", count: 2) == "Skills… (2 updates)")
        #expect(SkillUpdates.title("Skills…", count: -1) == "Skills…")
        #expect(SkillUpdates.phrase(0) == nil && SkillUpdates.phrase(1) == "1 update" && SkillUpdates.phrase(12) == "12 updates")
    }

    @Test func dueOnceADay() {
        #expect(SkillUpdates.isDue(now: start, lastCheck: nil)) // never checked
        #expect(!SkillUpdates.isDue(now: hours(1), lastCheck: start))
        #expect(!SkillUpdates.isDue(now: hours(23.9), lastCheck: start))
        #expect(SkillUpdates.isDue(now: hours(24), lastCheck: start))
        #expect(SkillUpdates.isDue(now: hours(24 * 9), lastCheck: start))
        // The clock set back: a last check a little ahead waits; more than a day ahead counts as none.
        #expect(!SkillUpdates.isDue(now: hours(-2), lastCheck: start))
        #expect(SkillUpdates.isDue(now: hours(-25), lastCheck: start))
    }

    @Test func answersAreKeptAcrossLaunches() {
        let answers: [String: SkillUpdateState] = ["release-notes": .available(commit: "abc"), "tidy-prose": .current, "gone": .unknown("GitHub refused.")]
        #expect(SkillUpdates.decode(SkillUpdates.encode(answers)) == answers)
        #expect(SkillUpdates.decode(SkillUpdates.encode([:])) == [:])
        #expect(SkillUpdates.decode(nil) == [:])
        #expect(SkillUpdates.decode(Data("not json".utf8)) == [:])
    }
}

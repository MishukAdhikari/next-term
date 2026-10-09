import Foundation
import Testing
@testable import NextTermCore

/// Agents › Skills…' count of skill updates, its title where there is no badge, and the quiet check's once-a-day rule:
/// a check that can't ask GitHub keeps the last answers, and skills removed since leave the count.
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

    @Test func aCheckWithNoAnswerTriesAgainAnHourLater() {
        // A quiet check that got no answer didn't count: due again an hour later, whatever the last check was.
        #expect(!SkillUpdates.isDue(now: hours(0.5), lastCheck: nil, lastFailure: start))
        #expect(SkillUpdates.isDue(now: hours(1), lastCheck: nil, lastFailure: start))
        #expect(!SkillUpdates.isDue(now: hours(25.5), lastCheck: start, lastFailure: hours(25)))
        #expect(SkillUpdates.isDue(now: hours(26), lastCheck: start, lastFailure: hours(25)))
        // Never earlier than the day's check: a failure doesn't make a check due.
        #expect(!SkillUpdates.isDue(now: hours(5), lastCheck: start, lastFailure: hours(2)))
        // The clock set back past the failure: it holds nothing back.
        #expect(SkillUpdates.isDue(now: hours(-1), lastCheck: nil, lastFailure: start))
    }

    @Test func aQuietCheckThatCantAskKeepsTheLastAnswers() {
        let last: [String: SkillUpdateState] = ["release-notes": .available(commit: "abc"), "pdf": .available(commit: "def"), "tidy-prose": .current]
        let offline: [String: SkillUpdateState] = ["release-notes": .unknown("offline"), "pdf": .unknown("offline"), "tidy-prose": .unknown("offline")]
        // Nothing answered (offline, GitHub's hourly limit): nothing changes, and the count stays 2.
        #expect(SkillUpdates.quietAnswers(offline, unreached: Set(offline.keys), last: last) == nil)
        #expect(SkillUpdates.quietAnswers([:], unreached: [], last: last) == nil)
        // One source answered, another didn't: its skills keep their last answers; one never answered shows the failure.
        let mixed: [String: SkillUpdateState] = ["release-notes": .unknown("GitHub refused."), "pdf": .current, "tidy-prose": .current,
                                                 "new-one": .unknown("GitHub refused.")]
        let kept = SkillUpdates.quietAnswers(mixed, unreached: ["release-notes", "new-one"], last: last)
        #expect(kept == ["release-notes": .available(commit: "abc"), "pdf": .current, "tidy-prose": .current, "new-one": .unknown("GitHub refused.")])
        #expect(kept.map(SkillUpdates.count) == 1)
        // A folder gone from its repository is an answer, not a failure.
        let gone: [String: SkillUpdateState] = ["pdf": .unknown("Its folder is no longer in a/b.")]
        #expect(SkillUpdates.quietAnswers(gone, unreached: [], last: last) == gone)
        // A skill no longer installed isn't brought back by its last answer.
        #expect(SkillUpdates.quietAnswers(["pdf": .current], unreached: [], last: last) == ["pdf": .current])
    }

    @Test func answersForRemovedSkillsLeaveTheCount() {
        let answers: [String: SkillUpdateState] = ["release-notes": .available(commit: "abc"), "pdf": .available(commit: "def"), "tidy-prose": .current]
        let left = SkillUpdates.pruned(answers, tracked: ["release-notes", "tidy-prose", "not-checked-yet"])
        #expect(left == ["release-notes": .available(commit: "abc"), "tidy-prose": .current])
        #expect(SkillUpdates.count(left) == 1)
        #expect(SkillUpdates.pruned(answers, tracked: []) == [:])
    }

    @Test func answersAreKeptAcrossLaunches() {
        let answers: [String: SkillUpdateState] = ["release-notes": .available(commit: "abc"), "tidy-prose": .current, "gone": .unknown("GitHub refused.")]
        #expect(SkillUpdates.decode(SkillUpdates.encode(answers)) == answers)
        #expect(SkillUpdates.decode(SkillUpdates.encode([:])) == [:])
        #expect(SkillUpdates.decode(nil) == [:])
        #expect(SkillUpdates.decode(Data("not json".utf8)) == [:])
    }
}

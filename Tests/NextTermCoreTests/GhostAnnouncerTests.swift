import Foundation
import Testing
@testable import NextTermCore

@Suite struct GhostAnnouncerTests {
    /// Suggestions at 0, 0.2 and 0.3 s: one announcement, at 0.8 s, of the last.
    @Test func oneAnnouncementHalfASecondAfterTheLast() {
        var announcer = GhostAnnouncer()
        announcer.suggested("git checkout", at: 0)
        announcer.suggested("git checkout dev", at: 0.2)
        announcer.suggested("git checkout main", at: 0.3)
        #expect(announcer.dueAt == 0.8)
        #expect(announcer.due(at: 0.7, words: .whole) == nil)
        #expect(announcer.due(at: 0.8, words: .whole) == "git checkout main, → accepts")
        #expect(announcer.due(at: 1.5, words: .whole) == nil && announcer.dueAt == nil)
    }

    /// Typing through it is not a new suggestion: still one announcement, once typing stops.
    @Test func aTrimIsNotNew() {
        var announcer = GhostAnnouncer()
        announcer.suggested("git cherry-pick abc", at: 0)
        announcer.typed(at: 0.3)
        #expect(announcer.due(at: 0.6, words: .whole) == nil)
        #expect(announcer.due(at: 0.8, words: .whole) == "git cherry-pick abc, → accepts")
        announcer.typed(at: 1)
        #expect(announcer.due(at: 2, words: .whole) == nil)
    }

    @Test func goneBeforeItsTimeSaysNothing() {
        var announcer = GhostAnnouncer()
        announcer.suggested("make test", at: 0)
        announcer.hidden()
        #expect(announcer.dueAt == nil && announcer.due(at: 1, words: .whole) == nil)
    }

    @Test func theWordsAreTheSettings() {
        var announcer = GhostAnnouncer()
        announcer.suggested("make test", at: 0)
        #expect(announcer.due(at: 1, words: .short) == "Suggestion, → accepts")
        announcer.suggested("make test", at: 2)
        #expect(announcer.due(at: 3, words: .none) == nil && announcer.dueAt == nil)
        #expect(GhostAnnouncer.text("git checkout main", words: .whole) == "git checkout main, → accepts")
    }
}

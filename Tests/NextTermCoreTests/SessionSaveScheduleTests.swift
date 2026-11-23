import Foundation
import Testing
@testable import NextTermCore

/// The periodic save reads every tab's agent again only when the cheap signature moved, or the refresh is due.
@Suite struct SessionSaveScheduleTests {
    private let pane = UUID()
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func signature(directory: String = "/repo", running: Bool = true, command: String = "claude",
                           title: String? = "Fixing the tests", agentSession: String? = nil) -> SessionSignature {
        var signature = SessionSignature()
        signature.add("window", "0")
        signature.addPane(id: pane, directory: directory, running: running, command: command, title: title,
                          agentSession: agentSession)
        return signature
    }

    @Test func theFirstTickCaptures() {
        let schedule = SessionSaveSchedule()
        #expect(schedule.needsCapture(signature(), at: start))
    }

    @Test func anUnchangedSessionWaitsForTheRefresh() {
        var schedule = SessionSaveSchedule()
        schedule.captured(signature(), at: start)
        #expect(!schedule.needsCapture(signature(), at: start.addingTimeInterval(2)))
        #expect(!schedule.needsCapture(signature(), at: start.addingTimeInterval(SessionSaveSchedule.refresh - 1)))
        #expect(schedule.needsCapture(signature(), at: start.addingTimeInterval(SessionSaveSchedule.refresh)))
    }

    @Test func aSpinnerFrameIsNoChange() {
        var schedule = SessionSaveSchedule()
        schedule.captured(signature(title: "⠋ Fixing the tests"), at: start)
        #expect(!schedule.needsCapture(signature(title: "⠙ Fixing the tests"), at: start.addingTimeInterval(2)))
        #expect(!schedule.needsCapture(signature(title: "Fixing the tests"), at: start.addingTimeInterval(2)))
    }

    @Test func eachSavedFieldIsAChange() {
        var schedule = SessionSaveSchedule()
        schedule.captured(signature(), at: start)
        let later = start.addingTimeInterval(2)
        #expect(schedule.needsCapture(signature(directory: "/other"), at: later))
        #expect(schedule.needsCapture(signature(running: false), at: later))
        #expect(schedule.needsCapture(signature(command: "codex"), at: later))
        #expect(schedule.needsCapture(signature(title: "Reading files"), at: later))
        #expect(schedule.needsCapture(signature(title: nil), at: later))
        #expect(schedule.needsCapture(signature(agentSession: "abc"), at: later))
        var moved = signature()
        moved.add("window", "1")
        #expect(schedule.needsCapture(moved, at: later))
    }

    @Test func partsDoNotRunTogether() {
        var a = SessionSignature(), b = SessionSignature()
        a.add("ab", "c")
        b.add("a", "bc")
        #expect(a != b)
    }

    @Test func aSaveNotWrittenCapturesAgainNextTick() {
        var schedule = SessionSaveSchedule()
        schedule.captured(signature(), at: start)
        schedule.forget()
        #expect(schedule.needsCapture(signature(), at: start.addingTimeInterval(2)))
    }
}

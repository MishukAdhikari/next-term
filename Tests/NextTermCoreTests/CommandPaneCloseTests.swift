import Foundation
import Testing
@testable import NextTermCore

/// The rule for closing an agent's one-command pane once its command has finished.
@Suite struct CommandPaneCloseTests {
    @Test func aCommandThatSucceededClosesItsPane() {
        #expect(CommandPaneClose.closes(exitCode: 0, kept: false, userTyped: false))
    }

    @Test func aFailureOrAMissingExitCodeKeepsItOpen() {
        #expect(!CommandPaneClose.closes(exitCode: 1, kept: false, userTyped: false))
        #expect(!CommandPaneClose.closes(exitCode: 130, kept: false, userTyped: false))
        #expect(!CommandPaneClose.closes(exitCode: nil, kept: false, userTyped: false))
    }

    @Test func keepOpenTypingOrTheWindowsLastPaneKeepIt() {
        #expect(!CommandPaneClose.closes(exitCode: 0, kept: true, userTyped: false))
        #expect(!CommandPaneClose.closes(exitCode: 0, kept: false, userTyped: true))
        #expect(!CommandPaneClose.closes(exitCode: 0, kept: false, userTyped: false, lastInWindow: true))
    }

    @Test func theCountdownSaysWholeSeconds() {
        #expect(CommandPaneClose.countdown(3) == "Closes in 3 s")
        #expect(CommandPaneClose.countdown(2.2) == "Closes in 3 s")
        #expect(CommandPaneClose.countdown(0.1) == "Closes in 1 s")
        #expect(CommandPaneClose.countdown(0) == "Closes in 1 s")
    }
}

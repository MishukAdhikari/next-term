import Testing
@testable import NextTermCore

@Suite struct GitNoticeTests {
    /// A Fetch still reading the branches when a delete queued behind it shows its Undo: "Fetched: up to date" comes
    /// after, and leaves that Undo up.
    @Test func workBegunBeforeAnUndoLeavesIt() {
        let undo = GitNotice.Shown(number: 6, hasButton: true)
        #expect(!GitNotice.replaces(undo, hasButton: false, isError: false, begun: 5))
        // Begun once the Undo was up (Fetch pressed after the delete), or with no start noted (Copied): it takes its place.
        #expect(GitNotice.replaces(undo, hasButton: false, isError: false, begun: 6))
        #expect(GitNotice.replaces(undo, hasButton: false, isError: false, begun: nil))
    }

    @Test func anErrorOrAnotherButtonStillReplaces() {
        let undo = GitNotice.Shown(number: 6, hasButton: true)
        #expect(GitNotice.replaces(undo, hasButton: false, isError: true, begun: 5))
        #expect(GitNotice.replaces(undo, hasButton: true, isError: false, begun: 5))
    }

    @Test func aPlainNoticeOrNoneUpIsReplaced() {
        #expect(GitNotice.replaces(nil, hasButton: false, isError: false, begun: 5))
        #expect(GitNotice.replaces(GitNotice.Shown(number: 6, hasButton: false), hasButton: false, isError: false, begun: 5))
    }
}

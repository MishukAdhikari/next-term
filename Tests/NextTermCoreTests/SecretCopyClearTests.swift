import Testing
@testable import NextTermCore

/// A key Copy put on the clipboard is cleared once, and only while the clipboard still holds it: by its own timer, or
/// earlier when Next Term quits or the Mac locks or sleeps within its window (review finding #11).
@Suite struct SecretCopyClearTests {
    @Test func itsTimerClearsTheCopyOnceWhileTheClipboardStillHoldsIt() {
        var clear = SecretCopyClear()
        clear.copied(7)
        #expect(clear.copiedCount == 7)
        let first: Bool = clear.due(7, current: 7)
        #expect(first && clear.copiedCount == nil)
        let again: Bool = clear.due(7, current: 7)
        #expect(!again)
    }

    @Test func somethingCopiedSinceIsKept() {
        var clear = SecretCopyClear()
        clear.copied(7)
        let timer: Bool = clear.due(7, current: 8)
        #expect(!timer && clear.copiedCount == nil)
        clear.copied(9)
        let quit: Bool = clear.now(current: 10)
        #expect(!quit && clear.copiedCount == nil)
    }

    @Test func anEarlierCopysTimerLeavesANewerCopy() {
        var clear = SecretCopyClear()
        clear.copied(7)
        clear.copied(9)
        let earlier: Bool = clear.due(7, current: 9)
        #expect(!earlier && clear.copiedCount == 9)
        let newer: Bool = clear.due(9, current: 9)
        #expect(newer)
    }

    /// The quit, a lock or a sleep clears a copy still due, and its timer then finds nothing left to do.
    @Test func quittingWithinTheWindowClearsTheCopyAndItsTimerThenDoesNothing() {
        var clear = SecretCopyClear()
        let nothing: Bool = clear.now(current: 3)
        #expect(!nothing)
        clear.copied(4)
        let quit: Bool = clear.now(current: 4)
        #expect(quit && clear.copiedCount == nil)
        let quitAgain: Bool = clear.now(current: 4)
        let timer: Bool = clear.due(4, current: 4)
        #expect(!quitAgain && !timer)
    }
}

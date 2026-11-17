import Foundation
import Testing
@testable import NextTermCore

/// Pinned tabs' order rules and the session's pin.
@Suite struct PinnedTabsTests {
    @Test func aPinnedTabGoesAfterThePinnedOnes() {
        #expect(PinnedTabs.indexWhenPinned(3, pinned: [true, false, false, false]) == 1)
        #expect(PinnedTabs.indexWhenPinned(0, pinned: [false, false]) == 0)
        #expect(PinnedTabs.indexWhenPinned(2, pinned: [true, true, false]) == 2)
    }

    @Test func anUnpinnedTabGoesFirstAmongTheOthers() {
        #expect(PinnedTabs.indexWhenUnpinned(0, pinned: [true, true, false]) == 1)
        #expect(PinnedTabs.indexWhenUnpinned(1, pinned: [true, true, false]) == 1)
    }

    @Test func aDragKeepsATabOnItsSideOfTheDivider() {
        let pinned = [true, true, false, false]
        #expect(PinnedTabs.clampedMove(from: 0, to: 3, pinned: pinned) == 1)
        #expect(PinnedTabs.clampedMove(from: 3, to: 0, pinned: pinned) == 2)
        #expect(PinnedTabs.clampedMove(from: 2, to: 3, pinned: pinned) == 3)
    }

    @Test func bulkClosesLeavePinnedTabs() {
        #expect(PinnedTabs.closable([0, 1, 2, 3], pinned: [true, false, true, false]) == [1, 3])
    }

    @Test func theQuestionNamesTheTab() {
        #expect(PinnedTabs.closeQuestion(title: "api") == "Close the pinned tab \u{201C}api\u{201D}?")
    }

    @Test func thePinIsKeptInTheSessionAndOlderSnapshotsReadUnpinned() throws {
        let pane = SessionSnapshot.Pane(id: UUID(), folder: "/tmp")
        let group = SessionSnapshot.Group(root: .pane(pane), focused: pane.id, pinned: true)
        let data = try JSONEncoder().encode(group)
        #expect(try JSONDecoder().decode(SessionSnapshot.Group.self, from: data).pinned)
        let plain = try JSONEncoder().encode(SessionSnapshot.Group(root: .pane(pane), focused: pane.id))
        #expect(!String(decoding: plain, as: UTF8.self).contains("pinned"))
        #expect(try !JSONDecoder().decode(SessionSnapshot.Group.self, from: plain).pinned)
    }
}

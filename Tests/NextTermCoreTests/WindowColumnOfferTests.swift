import Foundation
import Testing
@testable import NextTermCore

struct WindowColumnOfferTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    @Test func hiddenItIsOfferedFromFiveWindowsOnce() {
        let fresh = WindowColumnOffer.Record()
        #expect(WindowColumnOffer.offer(shown: false, windows: 4, record: fresh, now: now) == nil)
        #expect(WindowColumnOffer.offer(shown: false, windows: 5, record: fresh, now: now) == .show)
        let offered = WindowColumnOffer.Record(showOffered: true)
        #expect(WindowColumnOffer.offer(shown: false, windows: 20, record: offered, now: now) == nil)
    }

    @Test func hiddenWithManyOpenItWaitsForMore() {
        // Hidden with 7 open: offered at 9, not before.
        let record = WindowColumnOffer.Record(hiddenWith: 7, hiddenAt: now.addingTimeInterval(-30 * day))
        #expect(WindowColumnOffer.offer(shown: false, windows: 8, record: record, now: now) == nil)
        #expect(WindowColumnOffer.offer(shown: false, windows: 9, record: record, now: now) == .show)
        // Hidden with 2 (or before the count was kept): five at least.
        #expect(WindowColumnOffer.showsFrom(hiddenWith: 2) == 5 && WindowColumnOffer.showsFrom(hiddenWith: nil) == 5)
    }

    @Test func notWithinTwoWeeksOfHidingIt() {
        let lately = WindowColumnOffer.Record(hiddenWith: 2, hiddenAt: now.addingTimeInterval(-13 * day))
        #expect(WindowColumnOffer.offer(shown: false, windows: 9, record: lately, now: now) == nil)
        let then = WindowColumnOffer.Record(hiddenWith: 2, hiddenAt: now.addingTimeInterval(-14 * day))
        #expect(WindowColumnOffer.offer(shown: false, windows: 9, record: then, now: now) == .show)
    }

    @Test func shownItSaysOnceHowToHideIt() {
        #expect(WindowColumnOffer.offer(shown: true, windows: 4, record: .init(), now: now) == nil)
        #expect(WindowColumnOffer.offer(shown: true, windows: 5, record: .init(), now: now) == .hide)
        #expect(WindowColumnOffer.offer(shown: true, windows: 9, record: .init(hideTipShown: true), now: now) == nil)
    }

    @Test func eachNoticeIsShownOnceAndSwitchingItEndsTheTip() throws {
        let (defaults, name) = try TestDefaults.make("column-offer")
        defer { TestDefaults.remove(defaults, name) }
        WindowColumnOffer.noteShown(.hide, defaults)
        #expect(WindowColumnOffer.Record(defaults) == .init(hideTipShown: true))
        WindowColumnOffer.noteShown(.show, defaults)
        #expect(WindowColumnOffer.Record(defaults).showOffered)

        let (other, otherName) = try TestDefaults.make("column-offer-set")
        defer { TestDefaults.remove(other, otherName) }
        // Hidden with 6 open: the count and the time kept, the tip never needed.
        WindowColumnOffer.columnSet(shown: false, windows: 6, now: now, other)
        #expect(WindowColumnOffer.Record(other) == .init(hiddenWith: 6, hiddenAt: now, hideTipShown: true))
        // Shown again: nothing offered any more.
        WindowColumnOffer.columnSet(shown: true, windows: 6, now: now, other)
        #expect(WindowColumnOffer.Record(other).showOffered)
        #expect(WindowColumnOffer.offer(shown: false, windows: 50, record: .init(other), now: now.addingTimeInterval(100 * day)) == nil)
    }

    @Test func finishEndsBoth() throws {
        let (defaults, name) = try TestDefaults.make("column-offer-finish")
        defer { TestDefaults.remove(defaults, name) }
        WindowColumnOffer.finish(defaults)
        let record = WindowColumnOffer.Record(defaults)
        #expect(WindowColumnOffer.offer(shown: false, windows: 50, record: record, now: now) == nil)
        #expect(WindowColumnOffer.offer(shown: true, windows: 50, record: record, now: now) == nil)
    }

    @Test func theNoticeIsOneShortLineThatNamesTheKey() {
        #expect(WindowColumnOffer.text(.show, windows: 6, key: "⌃⇧⌘S") == "6 windows open. Show the window column (⌃⇧⌘S)?")
        #expect(WindowColumnOffer.text(.hide, windows: 6, key: "⌃⇧⌘S") == "6 windows open. Hide the window column (⌃⇧⌘S)?")
        #expect(WindowColumnOffer.text(.show, windows: 6, key: nil) == "6 windows open. Show the window column?")
        for kind in [WindowColumnOffer.Kind.show, .hide] {
            #expect(WindowColumnOffer.text(kind, windows: 99, key: "⌃⇧⌘S").count <= 56)
        }
        #expect(WindowColumnOffer.buttons(.show) == ("Show", "Don’t Ask Again"))
        #expect(WindowColumnOffer.buttons(.hide) == ("Hide", "Keep It"))
    }

    @Test func itsKeysAreKept() {
        #expect(WindowColumnOffer.keys == ["windowColumnShowOffered", "windowColumnHiddenWith", "windowColumnHiddenAt", "windowColumnHideTipShown"])
    }

    @Test func theLinesSayWhatChangesInEveryWindow() {
        #expect(WindowColumnSettings.approvalLine(shown: false, key: "⌃⇧⌘S")
            == "The window column is hidden in every window; View › Show Window Column (⌃⇧⌘S) or Settings › General brings it back.")
        #expect(WindowColumnSettings.approvalLine(shown: false, key: nil)
            == "The window column is hidden in every window; View › Show Window Column or Settings › General brings it back.")
        #expect(WindowColumnSettings.approvalLine(shown: true, key: "⌃⇧⌘S").hasPrefix("The window column shows at the outer edge of every window"))
        #expect(WindowColumnSettings.approvalLine(folded: true) == "The window column folds to a badge for each window, in every window.")
        #expect(WindowColumnSettings.approvalLine(folded: false).hasPrefix("The window column unfolds in every window"))
        #expect(WindowColumnSettings.unseenLine(shown: true) == "Window column on: it shows from two windows on.")
        #expect(WindowColumnSettings.unseenLine(shown: false) == "Window column off: no window will show it.")
        #expect(WindowColumnSettings.grantedLine(shown: false, key: "⌃⇧⌘S") == "An agent hid the window column; ⌃⇧⌘S brings it back.")
        #expect(WindowColumnSettings.grantedLine(shown: true, key: nil) == "An agent showed the window column.")
    }
}

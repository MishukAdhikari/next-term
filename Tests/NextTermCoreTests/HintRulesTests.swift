import Foundation
import Testing
@testable import NextTermCore

struct HintRulesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    /// A moment in which everything lets the hint show: tips on, nothing up, no key for a minute, a settled window.
    private func clear(_ record: HintRules.Record = .init()) -> HintRules.Situation {
        HintRules.Situation(record: record, now: now, sinceKey: 60, windowAge: 120)
    }

    @Test func theThreeHintsArePassiveWithThreeShowings() {
        #expect(Hint.allCases == [.columnSide, .nextAgent, .columnBasics])
        for hint in Hint.allCases { #expect(hint.kind == .passive && hint.limit == 3) }
    }

    @Test func itShowsWhenEveryRuleHolds() {
        for hint in Hint.allCases { #expect(HintRules.eligible(hint, clear())) }
    }

    @Test func eachRuleHoldsItBack() {
        var off = clear()
        off.tipsOn = false
        #expect(HintRules.heldBack(.columnSide, off) == .tipsOff)
        #expect(HintRules.heldBack(.columnSide, clear(.init(retired: .closed))) == .retired)
        #expect(HintRules.heldBack(.columnSide, clear(.init(shown: 3))) == .limitReached)
        #expect(HintRules.heldBack(.columnSide, clear(.init(shown: 2))) == nil)

        var soon = clear()
        soon.lastAnyShownAt = now.addingTimeInterval(-day + 1)
        #expect(HintRules.heldBack(.columnSide, soon) == .tooSoon)
        soon.lastAnyShownAt = now.addingTimeInterval(-day)
        #expect(HintRules.heldBack(.columnSide, soon) == nil)

        var notice = clear()
        notice.noticeVisible = true
        #expect(HintRules.heldBack(.columnSide, notice) == .noticeVisible)

        var typing = clear()
        typing.sinceKey = 1.9
        #expect(HintRules.heldBack(.columnSide, typing) == .typing)
        typing.sinceKey = 2
        #expect(HintRules.heldBack(.columnSide, typing) == nil)

        var busy = clear()
        busy.agentBusy = true
        #expect(HintRules.heldBack(.columnSide, busy) == .agentBusy)

        var new = clear()
        new.windowAge = 59
        #expect(HintRules.heldBack(.columnSide, new) == .windowNew)
        new.windowAge = 60
        #expect(HintRules.heldBack(.columnSide, new) == nil)
    }

    @Test func itsOwnStateComesBeforeTheMoment() {
        // Retired and typing: retired is the reason, so the caller never waits for a key that changes nothing.
        var both = clear(.init(retired: .countReached))
        both.sinceKey = 0
        both.noticeVisible = true
        #expect(HintRules.heldBack(.nextAgent, both) == .retired)
    }

    @Test func sixtyDaysAfterItFirstCouldShowItExpires() {
        let first = HintRules.noteTriggered(.init(), now: now)
        #expect(first.firstEligibleAt == now)
        // The 60 days start once: a later trigger keeps the first time.
        #expect(HintRules.noteTriggered(first, now: now.addingTimeInterval(day)).firstEligibleAt == now)
        // A retired hint starts nothing.
        #expect(HintRules.noteTriggered(.init(retired: .closed), now: now).firstEligibleAt == nil)

        var late = clear(first)
        late.now = now.addingTimeInterval(60 * day - 1)
        #expect(HintRules.heldBack(.columnBasics, late) == nil)
        late.now = now.addingTimeInterval(60 * day)
        #expect(HintRules.heldBack(.columnBasics, late) == .expired)
        #expect(!HintRules.isExpired(.init(), now: now.addingTimeInterval(1000 * day)))
    }

    @Test func onlyAShowingOfASecondOrMoreCounts() {
        #expect(!HintRules.counts(0.99) && HintRules.counts(1))
        let swipe = HintRules.noteExposure(.columnSide, .init(), seconds: 0.4, now: now)
        #expect(!swipe.counted && swipe.record == .init())
        let seen = HintRules.noteExposure(.columnSide, .init(), seconds: 1, now: now)
        #expect(seen.counted && seen.record == .init(shown: 1, lastShownAt: now))
    }

    @Test func theThirdShowingRetiresIt() {
        var record = HintRules.Record()
        for _ in 0..<3 { record = HintRules.noteExposure(.nextAgent, record, seconds: 2, now: now).record }
        #expect(record.shown == 3 && record.retired == .countReached)
        // Retired, nothing more counts.
        let after = HintRules.noteExposure(.nextAgent, record, seconds: 5, now: now.addingTimeInterval(day))
        #expect(!after.counted && after.record == record)
    }

    @Test func aRetiredHintKeepsItsFirstReason() {
        let closed = HintRules.retire(.init(shown: 1), .closed)
        #expect(closed.retired == .closed && closed.shown == 1)
        #expect(HintRules.retire(closed, .actionPerformed).retired == .closed)
        #expect(HintRules.Retirement.allCases.map(\.rawValue) == ["actionPerformed", "closed", "countReached", "expired"])
    }

    @Test func itsKeysAreKept() {
        #expect(HintRules.key(.columnSide, .shown) == "hint.columnSide.shown")
        #expect(HintRules.key(.nextAgent, .retired) == "hint.nextAgent.retired")
        #expect(HintRules.resetKeys.count == 13 && HintRules.resetKeys.last == "hint.lastAnyShownAt")
        #expect(HintRules.resetKeys.contains("hint.columnBasics.firstEligibleAt") && HintRules.resetKeys.contains("hint.columnSide.lastShownAt"))
        #expect(HintRules.keys == HintRules.resetKeys + ["hint.seeded", "showTips"])
    }

    @Test func aRecordIsSavedAndLoadedAndAFreshOneLeavesNoKey() throws {
        let (defaults, name) = try TestDefaults.make("hints")
        defer { TestDefaults.remove(defaults, name) }
        #expect(HintRules.load(.columnSide, defaults) == .init())
        #expect(HintRules.tipsOn(defaults) && HintRules.lastAnyShownAt(defaults) == nil)
        let record = HintRules.Record(shown: 2, lastShownAt: now, firstEligibleAt: now.addingTimeInterval(-day), retired: .closed)
        HintRules.save(record, .columnSide, defaults)
        #expect(HintRules.load(.columnSide, defaults) == record)
        #expect(HintRules.load(.nextAgent, defaults) == .init())
        #expect(defaults.string(forKey: "hint.columnSide.retired") == "closed" && defaults.integer(forKey: "hint.columnSide.shown") == 2)
        HintRules.save(.init(), .columnSide, defaults)
        #expect(HintRules.resetKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        // An unknown reason, as a later version might write, reads as not retired rather than failing.
        defaults.set("someday", forKey: "hint.nextAgent.retired")
        #expect(HintRules.load(.nextAgent, defaults).retired == nil)
    }

    @Test func resetShowsTipsAgainButKeepsTheSwitchAndTheSeeding() throws {
        let (defaults, name) = try TestDefaults.make("hints-reset")
        defer { TestDefaults.remove(defaults, name) }
        for hint in Hint.allCases { HintRules.save(.init(shown: 3, lastShownAt: now, firstEligibleAt: now, retired: .countReached), hint, defaults) }
        HintRules.setLastAnyShownAt(now, defaults)
        defaults.set(false, forKey: HintRules.tipsKey)
        defaults.set(true, forKey: HintRules.seededKey)
        #expect(HintRules.lastAnyShownAt(defaults) == now && !HintRules.tipsOn(defaults))
        HintRules.reset(defaults)
        for hint in Hint.allCases { #expect(HintRules.load(hint, defaults) == .init()) }
        #expect(HintRules.lastAnyShownAt(defaults) == nil)
        #expect(!HintRules.tipsOn(defaults) && defaults.bool(forKey: HintRules.seededKey))
    }

    @Test func anUpdateRetiresOnlyWhatIsInUse() {
        #expect(HintRules.seeded(.init()).isEmpty)
        #expect(HintRules.seeded(.init(columnSideChosen: true)) == [.columnSide])
        #expect(HintRules.seeded(.init(columnExpandedEver: true)) == [.columnBasics])
        // Nothing kept says whether the jump was used: never seeded.
        #expect(!HintRules.seeded(.init(columnSideChosen: true, columnExpandedEver: true)).contains(.nextAgent))
    }
}

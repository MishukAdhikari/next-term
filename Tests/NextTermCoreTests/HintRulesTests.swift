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

    @Test func everyHintIsPassiveWithThreeShowings() {
        #expect(Hint.allCases == [.columnSide, .nextAgent, .columnBasics, .terminalBeside, .sendSelection, .foldWorktrees])
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

        for each: HintNotices in [.hint, .toast, .sheet, .importWindow, .ghostNotice, .updateButton] {
            var notice = clear()
            notice.notices = each
            #expect(HintRules.heldBack(.columnSide, notice) == .noticeVisible)
        }

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
        both.notices = [.hint, .sheet]
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
        #expect(HintRules.resetKeys.count == Hint.allCases.count * 5 + 1 && HintRules.resetKeys.last == "hint.lastAnyShownAt")
        #expect(HintRules.resetKeys.contains("hint.nextAgent.watchFrom"))
        #expect(HintRules.resetKeys.contains("hint.columnBasics.firstEligibleAt") && HintRules.resetKeys.contains("hint.columnSide.lastShownAt"))
        #expect(HintRules.keys == HintRules.resetKeys + ["hint.seeded", "hint.seededHints", "showTips"])
    }

    @Test func aRecordIsSavedAndLoadedAndAFreshOneLeavesNoKey() throws {
        let (defaults, name) = try TestDefaults.make("hints")
        defer { TestDefaults.remove(defaults, name) }
        #expect(HintRules.load(.columnSide, defaults) == .init())
        #expect(HintRules.tipsOn(defaults) && HintRules.lastAnyShownAt(defaults) == nil)
        let record = HintRules.Record(shown: 2, lastShownAt: now, firstEligibleAt: now.addingTimeInterval(-day), retired: .closed,
                                      watchFrom: now.addingTimeInterval(-2 * day))
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
        #expect(HintRules.seed(.columnSide, .init()) == .due)
        #expect(HintRules.seed(.columnSide, .init(columnSideChosen: true)) == .retire)
        #expect(HintRules.seed(.columnBasics, .init(columnExpandedEver: true)) == .retire)
        #expect(HintRules.seed(.columnBasics, .init(columnSideChosen: true)) == .due)
        // Nothing kept says whether the jump was used: a new install has it due, one used before watches it.
        #expect(HintRules.seed(.nextAgent, .init(columnSideChosen: true, columnExpandedEver: true)) == .due)
        #expect(HintRules.seed(.nextAgent, .init(existingInstall: true)) == .watch)
    }

    @Test func aTerminalPositionEverChosenRetiresTheTerminalBesideHint() {
        #expect(HintRules.seed(.terminalBeside, .init()) == .due)
        #expect(HintRules.seed(.terminalBeside, .init(existingInstall: true)) == .due)
        #expect(HintRules.seed(.terminalBeside, .init(terminalPositionChosen: true)) == .retire)
        #expect(Hint.terminalBeside.inTabBar && !Hint.columnSide.inTabBar)
    }

    @Test func sendToAgentLeavesNoTraceSoAnInstallUsedBeforeWatchesIt() {
        #expect(Hint.sendSelection.command == "sendToAgent:" && Hint.sendSelection.traceless && Hint.sendSelection.inTabBar)
        #expect(HintRules.seed(.sendSelection, .init()) == .due)
        #expect(HintRules.seed(.sendSelection, .init(existingInstall: true)) == .watch)
        #expect(HintRules.seed(.sendSelection, .init(existingInstall: true, overrides: ["sendToAgent:"])) == .retire)
    }

    @Test func worktreesEverFoldedRetireTheFoldHint() {
        #expect(HintRules.seed(.foldWorktrees, .init(existingInstall: true)) == .due)
        #expect(HintRules.seed(.foldWorktrees, .init(worktreesFoldedEver: true)) == .retire)
        #expect(!Hint.foldWorktrees.inTabBar && !Hint.foldWorktrees.traceless)
    }

    @Test func aKeyTheUserReboundCountsAsUsed() {
        #expect(Hint.nextAgent.command == "goToNextAgentNeedingYou:")
        #expect(HintRules.seed(.nextAgent, .init(existingInstall: true, overrides: ["goToNextAgentNeedingYou:"])) == .retire)
        #expect(HintRules.seed(.nextAgent, .init(overrides: ["goToNextAgentNeedingYou:"])) == .retire)
        // Another command's key says nothing about this one.
        #expect(HintRules.seed(.nextAgent, .init(existingInstall: true, overrides: ["newTab:"])) == .watch)
    }

    @Test func aWatchedHintHoldsBackForTwoWeeksAndStartsNoExpiry() {
        let watched = HintRules.Record(watchFrom: now)
        #expect(HintRules.heldBack(.nextAgent, clear(watched)) == .watching)
        var later = clear(watched)
        later.now = now.addingTimeInterval(14 * day - 1)
        #expect(HintRules.heldBack(.nextAgent, later) == .watching)
        later.now = now.addingTimeInterval(14 * day)
        #expect(HintRules.heldBack(.nextAgent, later) == nil)
        // Its trigger in the watch starts no 60 days; after it, it does.
        #expect(HintRules.noteTriggered(watched, now: now.addingTimeInterval(day)).firstEligibleAt == nil)
        #expect(HintRules.noteTriggered(watched, now: now.addingTimeInterval(14 * day)).firstEligibleAt == now.addingTimeInterval(14 * day))
        // Retired in the watch (the feature was used), retired is the reason.
        #expect(HintRules.heldBack(.nextAgent, clear(.init(retired: .actionPerformed, watchFrom: now))) == .retired)
    }

    @Test func aFreshInstallSeedsEveryHintAtOnceWithNoWatch() throws {
        let (defaults, name) = try TestDefaults.make("hints-seed-fresh")
        defer { TestDefaults.remove(defaults, name) }
        #expect(HintRules.unseeded(defaults) == Hint.allCases)
        let done = HintRules.seed(.init(), defaults, now: now)
        #expect(Set(done.keys) == Set(Hint.allCases) && done.values.allSatisfy { $0 == .due })
        #expect(HintRules.unseeded(defaults).isEmpty)
        #expect(Hint.allCases.allSatisfy { HintRules.load($0, defaults) == .init() })
        #expect(defaults.stringArray(forKey: HintRules.seededHintsKey) == Hint.allCases.map(\.rawValue).sorted())
        #expect(defaults.bool(forKey: HintRules.seededKey))
    }

    @Test func eachHintIsSeededOnceAndAFactLaterChangesNothing() throws {
        let (defaults, name) = try TestDefaults.make("hints-seed-once")
        defer { TestDefaults.remove(defaults, name) }
        HintRules.seed(.init(), defaults, now: now)
        // The column moved after: its hint retires by its use (HintCenter.retire), never by a second seeding.
        let again = HintRules.seed(.init(columnSideChosen: true, existingInstall: true), defaults, now: now.addingTimeInterval(day))
        #expect(again.isEmpty && HintRules.load(.columnSide, defaults) == .init() && HintRules.load(.nextAgent, defaults) == .init())
    }

    @Test func anInstallFromTheFirstSeedingCountsItsThreeHintsAsSeeded() throws {
        let (defaults, name) = try TestDefaults.make("hints-seed-migrate")
        defer { TestDefaults.remove(defaults, name) }
        defaults.set(true, forKey: HintRules.seededKey)
        let first: [Hint] = [.columnSide, .nextAgent, .columnBasics]
        #expect(HintRules.unseeded(defaults) == Hint.allCases.filter { !first.contains($0) })
        // Its facts no longer reach the three: a user who closed nothing and moved the column after keeps the hint as it was.
        let done = HintRules.seed(.init(columnSideChosen: true, existingInstall: true, overrides: ["goToNextAgentNeedingYou:"]), defaults, now: now)
        #expect(first.allSatisfy { done[$0] == nil && HintRules.load($0, defaults) == .init() })
        #expect(Set(defaults.stringArray(forKey: HintRules.seededHintsKey) ?? []) == Set(Hint.allCases.map(\.rawValue)))
    }

    @Test func seedingRetiresWatchesAndKeepsALaterVersionsNames() throws {
        let (defaults, name) = try TestDefaults.make("hints-seed-apply")
        defer { TestDefaults.remove(defaults, name) }
        defaults.set(["someLaterHint"], forKey: HintRules.seededHintsKey)
        let done = HintRules.seed(.init(columnSideChosen: true, existingInstall: true), defaults, now: now)
        #expect(done[.columnSide] == .retire && HintRules.load(.columnSide, defaults).retired == .actionPerformed)
        #expect(done[.nextAgent] == .watch && HintRules.load(.nextAgent, defaults) == .init(watchFrom: now))
        #expect(done[.columnBasics] == .due && HintRules.load(.columnBasics, defaults) == .init())
        #expect(Set(defaults.stringArray(forKey: HintRules.seededHintsKey) ?? []) == Set(Hint.allCases.map(\.rawValue) + ["someLaterHint"]))
        // Reset Tips ends the watch and leaves the seeding: the tips show again at once, and nothing is seeded twice.
        HintRules.reset(defaults)
        #expect(HintRules.load(.nextAgent, defaults) == .init() && HintRules.unseeded(defaults).isEmpty)
    }
}

import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// Wrap Up's rules with no window: which agent tabs are asked, how each handoff is waited for, and how the review
/// turns Next items into tomorrow's tasks that post only on Add.
@Suite struct WrapUpModelTests {
    static let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func tab(_ id: UUID, _ title: String, _ verdict: AgentReadiness.Verdict, inside: Bool = true,
                    namesLeft: Bool = true) -> WrapUpModel.TabFacts {
        WrapUpModel.TabFacts(id: id, title: title, agent: .claude, verdict: verdict, insideProject: inside,
                             namesLeft: namesLeft)
    }

    static func readiness(_ tab: AgentReadiness.Tab) -> AgentReadiness.Verdict { AgentReadiness.check(tab) }

    // MARK: step 1, the tab list

    @Test func onlyTheReadyTabIsTickedAndTheOthersSayWhy() {
        let done = Self.readiness(AgentReadiness.Tab(state: .done, agent: .claude, lineHasText: false))
        let working = Self.readiness(AgentReadiness.Tab(state: .working, agent: .codex, lineHasText: false))
        let typed = Self.readiness(AgentReadiness.Tab(state: .idle, agent: .claude, lineHasText: true))
        var model = WrapUpModel([Self.tab(Self.a, "api", done), Self.tab(Self.b, "web", working),
                                 Self.tab(Self.c, "docs", typed)])
        #expect(model.rows.map(\.ticked) == [true, false, false])
        #expect(model.rows.map(\.reason) == [nil, "working", "has your text in its prompt"])
        model.setTicked(Self.b, true)
        model.setTicked(Self.c, true)
        #expect(model.rows.map(\.ticked) == [true, false, false])
        #expect(model.askCount == 1)
        #expect(model.askTitle == "Ask 1 Agent")
    }

    @Test func aTabOutsideTheProjectOrOnAServerOrOutOfNamesIsNotAsked() {
        let remote = Self.readiness({
            var tab = AgentReadiness.Tab(state: .idle, agent: .claude, lineHasText: false)
            tab.remote = true
            return tab
        }())
        let model = WrapUpModel([Self.tab(Self.a, "api", .ready, inside: false), Self.tab(Self.b, "srv", remote),
                                 Self.tab(Self.c, "full", .ready, namesLeft: false)])
        #expect(model.rows.map(\.reason) == ["not in this project’s top folder", "on a server",
                                             "today’s handoff names are used up"])
        #expect(model.rows.allSatisfy { !$0.ticked })
        #expect(!model.canAsk)
        #expect(model.askTitle == "Ask 0 Agents")
    }

    @Test func aTabTurningReadyStaysUntickedAndATickedOneThatStartsWorkingIsUnticked() {
        var model = WrapUpModel([Self.tab(Self.a, "api", .ready), Self.tab(Self.b, "web", .notReady(.working))])
        model.refresh([Self.tab(Self.a, "api", .notReady(.working)), Self.tab(Self.b, "web", .ready)])
        #expect(model.rows.map(\.ticked) == [false, false])
        #expect(model.rows.map(\.reason) == ["working", nil])
        #expect(model.askCount == 0)
        model.setTicked(Self.b, true)
        #expect(model.askCount == 1)
        #expect(model.askTitle == "Ask 1 Agent")
    }

    @Test func aTabOpenedMeanwhileJoinsUntickedAndAClosedOneLeaves() {
        var model = WrapUpModel([Self.tab(Self.a, "api", .ready)])
        model.refresh([Self.tab(Self.b, "web", .ready)])
        #expect(model.rows.map(\.id) == [Self.b])
        #expect(model.rows.map(\.ticked) == [false])
    }

    @Test func theFooterNamesTheFolderAndAnEmptyWindowSaysSo() {
        #expect(WrapUpModel.footer(folder: "docs/handoffs") == "Each ticked agent is asked to write a handoff to "
            + "docs/handoffs/. Nothing is posted until you review it.")
        #expect(WrapUpModel([]).rows.isEmpty)
        #expect(WrapUpModel.noAgents == "No agent tabs in this window.")
    }

    // MARK: waiting

    static func look(exists: Bool = false, size: Int? = nil, working: Bool = false, after seconds: TimeInterval,
                     gone: Bool = false, exited: Bool = false, asking: Bool = false) -> WrapUpModel.Look {
        WrapUpModel.Look(exists: exists, size: size, working: working, gone: gone, exited: exited, asking: asking,
                         now: start.addingTimeInterval(seconds))
    }

    static func asked() -> WrapUpModel {
        var model = WrapUpModel([tab(a, "api", .ready)])
        model.asked(a, file: "docs/handoffs/2026-10-18-api.md", at: start)
        return model
    }

    @Test func eachPhaseFollowsTheFileTheTabAndTheClock() {
        var model = Self.asked()
        #expect(model.rows[0].phase == .asked)
        #expect(model.rows[0].phaseText == "Asked")
        model.look(Self.a, Self.look(after: 1))
        #expect(model.rows[0].phase == .asked)
        model.look(Self.a, Self.look(exists: true, size: 10, after: 2))
        #expect(model.rows[0].phase == .writing)
        model.look(Self.a, Self.look(exists: true, size: 40, after: 3))
        #expect(model.rows[0].phase == .writing)
        #expect(model.rows[0].phaseText == "Writing…")
        model.look(Self.a, Self.look(exists: true, size: 40, working: true, after: 4))
        #expect(model.rows[0].phase == .writing)
        model.look(Self.a, Self.look(exists: true, size: 40, after: 5))
        #expect(model.rows[0].phase == .ready)
        #expect(model.rows[0].phaseText == "Ready to review")
        #expect(model.canReview)
        #expect(!model.isWaiting)
    }

    @Test func fiveMinutesWithNoFileIsStillWritingAndKeepWaitingGivesFiveMore() {
        var model = Self.asked()
        model.look(Self.a, Self.look(after: 299))
        #expect(model.rows[0].phase == .asked)
        model.look(Self.a, Self.look(after: 300))
        #expect(model.rows[0].phase == .stillWriting)
        #expect(model.rows[0].canKeepWaiting)
        #expect(model.rows[0].canSkip)
        model.keepWaiting(Self.a, now: Self.start.addingTimeInterval(300))
        model.look(Self.a, Self.look(after: 599))
        #expect(model.rows[0].phase == .asked)
        model.look(Self.a, Self.look(after: 600))
        #expect(model.rows[0].phase == .stillWriting)
    }

    @Test func aClosedOrAskingTabSaysSoAndAnAnswerThatWritesTheFileStillCounts() {
        var model = Self.asked()
        model.look(Self.a, Self.look(after: 1, asking: true))
        #expect(model.rows[0].phaseText == "asking")
        #expect(model.rows[0].canSkip)
        model.look(Self.a, Self.look(exists: true, size: 9, after: 2))
        model.look(Self.a, Self.look(exists: true, size: 9, after: 3))
        #expect(model.rows[0].phase == .ready)

        var closed = Self.asked()
        closed.look(Self.a, Self.look(after: 1, gone: true))
        #expect(closed.rows[0].phaseText == "closed")
        closed.skip(Self.a)
        #expect(closed.rows[0].phase == .skipped("skipped"))
        #expect(!closed.isWaiting)
        #expect(closed.canReview)
        #expect(!Self.asked().canReview)
    }

    @Test func reviewingSkipsTheTabsStillWaitedFor() {
        var model = WrapUpModel([Self.tab(Self.a, "api", .ready), Self.tab(Self.b, "web", .ready)])
        model.asked(Self.a, file: "docs/handoffs/a.md", at: Self.start)
        model.asked(Self.b, file: "docs/handoffs/b.md", at: Self.start)
        model.look(Self.b, Self.look(after: 1, gone: true))
        model.stopWaiting()
        #expect(model.rows.map(\.phaseText) == ["Skipped: no handoff yet", "Skipped: closed"])
    }

    @Test func aRowSkippedAtAskIsNotTypedIntoAndSaysWhy() {
        var model = WrapUpModel([Self.tab(Self.a, "api", .ready)])
        model.skip(Self.a, because: "has your text in its prompt")
        #expect(model.rows[0].phaseText == "Skipped: has your text in its prompt")
        #expect(model.rows[0].file == nil)
    }

    // MARK: the review

    static let file = "docs/handoffs/2026-10-18-api.md"
    static let today = TaskDay("2026-10-18")!

    static func row(_ phase: WrapUpModel.Phase, file: String? = file) -> WrapUpModel.Row {
        var model = WrapUpModel([tab(a, "api", .ready)])
        if let file { model.asked(a, file: file, at: start) }
        if case .skipped(let why) = phase { model.skip(a, because: why) }
        if phase == .ready {
            model.look(a, look(exists: true, size: 40, after: 1))
            model.look(a, look(exists: true, size: 40, after: 2))
        }
        return model.rows[0]
    }

    static func review(_ text: String) -> WrapUpReview {
        WrapUpReview(rows: [row(.ready)], reads: [a: .text(Handoff.parse(text))])
    }

    @Test func threeNextItemsAreThreeTickedTasksForTomorrow() {
        let review = Self.review("## Done\n- x\n## Next\n- one\n- two\n- three\n")
        let section = review.sections[0]
        #expect(section.title == "api")
        #expect(section.file == Self.file)
        #expect(section.note == nil)
        #expect(section.tasks.map(\.title) == ["one", "two", "three"])
        #expect(section.tasks.allSatisfy { $0.ticked && $0.when == .tomorrow })
        #expect(review.addCount == 3)
        #expect(review.addTitle == "Add 3 Tasks")
        let calendar = Calendar(identifier: .gregorian)
        let now = Self.today.start(in: calendar)!.addingTimeInterval(3600)
        let drafts = review.drafts(now: now, calendar: calendar, contexts: [:], to: .todoFolder)
        #expect(drafts.map(\.title) == ["one", "two", "three"])
        #expect(drafts.allSatisfy { $0.scheduled == .day(TaskDay("2026-10-19")!) })
        #expect(drafts[0].notes == "From docs/handoffs/2026-10-18-api.md")
    }

    @Test func aHandoffWithNoNextSectionShowsItsTextAndOneEmptyRow() {
        var review = Self.review("Did some things, nothing else to say.")
        let section = review.sections[0]
        #expect(section.note == "This handoff has no Next section.")
        #expect(section.raw == "Did some things, nothing else to say.")
        #expect(section.showsText)
        #expect(section.tasks.count == 1)
        #expect(section.tasks[0].title.isEmpty && !section.tasks[0].ticked)
        #expect(review.addCount == 0)
        #expect(!review.canAdd)
        review.addRow(Self.a)
        #expect(review.sections[0].tasks.count == 2)
        let id = review.sections[0].tasks[1].id
        review.setTitle(Self.a, id, "by hand")
        review.setTicked(Self.a, id, true)
        #expect(review.addTitle == "Add 1 Task")
    }

    @Test func aTickedItemIsUntickedAndAnEmptiedTitleIsNotCounted() {
        var review = Self.review("## Next\n- [x] done thing\n- open thing\n")
        #expect(review.sections[0].tasks.map(\.ticked) == [false, true])
        #expect(review.addCount == 1)
        review.setTitle(Self.a, review.sections[0].tasks[1].id, "   ")
        #expect(review.addCount == 0)
    }

    @Test func aSkippedTabOrALinkShowsItsReasonAndNoTasks() {
        let skipped = WrapUpReview(rows: [Self.row(.skipped("working"), file: nil)], reads: [:])
        #expect(skipped.sections[0].note == "Skipped: working")
        #expect(skipped.sections[0].tasks.isEmpty)
        let link = WrapUpReview(rows: [Self.row(.ready)], reads: [Self.a: .notPlainFile])
        #expect(link.sections[0].note == "The handoff is not a plain file, so it wasn’t read.")
        #expect(link.sections[0].raw == nil)
        #expect(link.sections[0].tasks.isEmpty)
    }

    @Test func aStoredKeyIsMaskedInTheTextTheTitleAndTheNotes() throws {
        let value = "sk-ant-abc123def456"
        let key = SymmetricKey(size: .bits256)
        let mask = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        let text = "## Next\n- rotate token=\(value)\n"
        let review = WrapUpReview(rows: [Self.row(.ready)], reads: [Self.a: .text(Handoff.parse(mask.mask(text)))])
        var edited = review
        let id = review.sections[0].tasks[0].id
        edited.setTitle(Self.a, id, "rotate \(value) now", mask: { mask.mask($0) })
        let drafts = edited.drafts(now: Self.start, calendar: .current, contexts: [:], to: .todoFolder)
        let seen = [review.sections[0].raw ?? "", review.sections[0].tasks[0].title,
                    edited.sections[0].tasks[0].title, drafts[0].title, drafts[0].notes]
        #expect(seen.allSatisfy { !$0.contains(value) && !$0.contains("abc123") })
        #expect(review.sections[0].raw?.contains("•••") == true)
        #expect(edited.sections[0].tasks[0].title.contains("•••"))
        #expect(drafts[0].masked)
    }

    @Test func eachDraftCarriesItsTabsContext() {
        let review = Self.review("## Next\n- one\n")
        let context = TaskContext(branch: "main", tab: "api", agent: .claude, addedBy: "Wrap Up")
        let drafts = review.drafts(now: Self.start, calendar: .current, contexts: [Self.a: context],
                                   to: .todoFolder)
        #expect(drafts[0].context == context)
    }
}

/// What review and Add owe the user before anything leaves: the tab asked works where the path it is given lands,
/// a team page never learns the tab's title, and a destination that opens pages says its refusal before Add.
@Suite struct WrapUpSendingTests {
    @Test func onlyATabInTheProjectsTopFolderCanBeAsked() {
        #expect(WrapUpModel.atProjectRoot(tabFolder: "/p", project: "/p"))
        #expect(WrapUpModel.atProjectRoot(tabFolder: "/p/", project: "/p"))
        // A tab in a subfolder would resolve the project's relative path from its own folder.
        #expect(!WrapUpModel.atProjectRoot(tabFolder: "/p/api", project: "/p"))
        #expect(!WrapUpModel.atProjectRoot(tabFolder: "/p2", project: "/p"))
        #expect(!WrapUpModel.atProjectRoot(tabFolder: "/other", project: "/p"))
        #expect(!WrapUpModel.atProjectRoot(tabFolder: "/p/../other", project: "/p"))
    }

    @Test func anEmptyFileIsNeverReady() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var model = WrapUpModel([WrapUpModel.TabFacts(id: WrapUpModelTests.a, title: "api", agent: .claude,
                                                      verdict: .ready, insideProject: true, namesLeft: true)])
        model.asked(WrapUpModelTests.a, file: WrapUpModelTests.file, at: now)
        func look(_ size: Int, _ after: TimeInterval) -> WrapUpModel.Look {
            WrapUpModel.Look(exists: true, size: size, working: false, gone: false, exited: false, asking: false,
                             now: now.addingTimeInterval(after))
        }
        model.look(WrapUpModelTests.a, look(0, 1))
        model.look(WrapUpModelTests.a, look(0, 2))
        #expect(model.rows[0].phase == .writing)
        model.look(WrapUpModelTests.a, look(30, 3))
        model.look(WrapUpModelTests.a, look(30, 4))
        #expect(model.rows[0].phase == .ready)
    }

    static func review() -> WrapUpReview {
        let row = WrapUpModelTests.row(.ready)
        let handoff = Handoff.parse("## Next\n- one\n")
        return WrapUpReview(rows: [row], reads: [WrapUpModelTests.a: .text(handoff)])
    }

    @Test func teamPagesAndTheAgentRequestNeverGetTheHandoffsName() {
        let review = Self.review()
        let team: [TaskDestination.Kind] = [.github, .gitlab, .linear, .trello, .azureBoards, .throughAgent]
        let personal: [TaskDestination.Kind] = [.todoFolder, .reminders, .things, .shortcut, .todoist, .omnifocus]
        for kind in team {
            let drafts = review.drafts(now: WrapUpModelTests.start, calendar: .current, contexts: [:], to: kind)
            #expect(drafts[0].notes == "", "\(kind)")
        }
        for kind in personal {
            let drafts = review.drafts(now: WrapUpModelTests.start, calendar: .current, contexts: [:], to: kind)
            #expect(drafts[0].notes == "From " + WrapUpModelTests.file, "\(kind)")
        }
    }

    @Test func pagesOpenInTurnsAndTheFooterSaysWhatToPressThere() {
        #expect(WrapUpReview.opensInTurns(.github, count: 7))
        #expect(WrapUpReview.opensInTurns(.todoist, count: 6))
        #expect(!WrapUpReview.opensInTurns(.github, count: 5))
        #expect(!WrapUpReview.opensInTurns(.things, count: 9))
        #expect(!WrapUpReview.opensInTurns(.throughAgent, count: 9))
        #expect(WrapUpReview.turnsLine(.github, count: 7)
            == "Opens 7 pages, 5 at a time: nothing is created until you press Create there.")
        #expect(WrapUpReview.turnsLine(.todoist, count: 7)
            == "Opens 7 Quick Add windows, 5 at a time: nothing is added until you press Add there.")
        #expect(WrapUpReview.turnsLine(.omnifocus, count: 6)
            == "Opens 6 Quick Add windows, 5 at a time: nothing is added until you press Add there.")
    }
}

extension WrapUpSendingTests {
    static func plan(_ count: Int, _ destination: TaskDestination) -> DestinationPlan {
        let today = TaskDay("2026-10-18")!
        let rendered: [TaskPayload?] = (0..<count).map { index in
            let draft = TaskDraft(title: "task \(index)", steps: [])
            return TaskPayload.render(draft, to: destination, project: "p", today: today, mask: { $0 })
        }
        return DestinationPlan.make(rendered: rendered, destination: destination, facts: DestinationFacts(),
                                    mask: { $0 })
    }

    @Test func aRefusedPageDestinationSaysWhyBeforeAddEvenPastFiveTasks() {
        let broken = TaskDestination.github(owner: "o", repo: "")
        let refused = WrapUpReview.addGate(.github, count: 7, whole: Self.plan(7, broken),
                                           firstTurn: Self.plan(5, broken))
        #expect(refused.line == broken.problem)
        #expect(!refused.canAdd && refused.refused)
        let fine = TaskDestination.github(owner: "o", repo: "r")
        let turns = WrapUpReview.addGate(.github, count: 7, whole: Self.plan(7, fine), firstTurn: Self.plan(5, fine))
        #expect(turns.line == WrapUpReview.turnsLine(.github, count: 7))
        #expect(turns.canAdd && !turns.refused)
        let few = WrapUpReview.addGate(.github, count: 3, whole: Self.plan(3, fine), firstTurn: Self.plan(3, fine))
        #expect(few.line == Self.plan(3, fine).line && few.canAdd)
        // Not installed is said before Add, whatever the count.
        let todoist = WrapUpReview.addGate(.todoist, count: 7, whole: Self.plan(7, .todoist),
                                           firstTurn: Self.plan(5, .todoist))
        #expect(!todoist.canAdd && todoist.line.contains("isn’t installed"))
    }
}

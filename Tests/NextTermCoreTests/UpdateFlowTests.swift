import Foundation
import Testing
@testable import NextTermCore

/// A made-up session for the update sheet: one window, "app", with Claude Code idle in a tab (it resumes), `npm run dev`
/// in another (back on the line), a split pane under it (opens in its folder), a tab kept by tmux on a server (reattaches)
/// and a plain ssh tab (connection closes). What is busy, and each outcome, is set per test.
struct UpdateFixture {
    let version = "0.12.0"
    let agent = UUID()
    let command = UUID()
    let split = UUID()
    let kept = UUID()
    let ssh = UUID()

    /// Nothing busy.
    var plan: UpdatePlan { planned() }

    func planned(busy: Set<UUID> = [], outcomes: [UUID: RestoreOutcome] = [:], leftOut: Set<UUID> = [],
                 serving: Set<UUID> = [], jobs: Set<UUID> = []) -> UpdatePlan {
        func pane(_ id: UUID, _ name: String, _ outcome: RestoreOutcome, _ listLine: String, split: Bool = false,
                  agent: Bool = false, remote: Bool = false) -> UpdatePane {
            let planned = outcomes[id] ?? outcome
            var pane = UpdatePane(id: id, name: name, split: split, outcome: planned,
                                  listLine: planned == outcome ? listLine : "\(planned)", busy: busy.contains(id), agent: agent,
                                  remote: remote, serving: serving.contains(id), leftOut: leftOut.contains(id))
            pane.jobs = jobs.contains(id)
            return pane
        }
        let panes: [UpdatePane] = [
            pane(agent, "app", .resume, "Claude Code resumes", agent: true),
            pane(command, "dev server", .commandOnTheLine, "npm run dev goes back on the line"),
            pane(split, "app/src", .idle, "opens in its folder", split: true),
            pane(kept, "web-1: app", .reattach, "reattaches", remote: true),
            pane(ssh, "web-2: logs", .freshConnection, "connection closes", remote: true),
        ]
        return UpdatePlan(windows: [UpdateWindow(name: "app", panes: panes)])
    }

    func consent(keep: Bool = true, busy: Set<UUID> = []) -> UpdateConsent {
        UpdateConsent(version: version, keep: keep, covered: planned(busy: busy))
    }

    func flow(busy: Set<UUID> = [], remembered: Bool? = nil, entry: UpdateFlow.Entry = .updateButton) -> UpdateFlow {
        UpdateFlow(version: version, plan: planned(busy: busy), remembered: remembered, from: entry)
    }
}

@Suite struct UpdateFlowTests {
    let saw = UpdateFixture()

    /// The buttons' titles in a state, compared outside `#expect`, where arrays are slow to type-check.
    func titles(_ flow: UpdateFlow) -> [String] {
        let buttons: [UpdateButton] = flow.buttons
        return buttons.map(\.title)
    }

    func line(_ flow: UpdateFlow, _ id: UUID) -> String {
        let pane: UpdatePane? = flow.plan.panes.first { (pane: UpdatePane) -> Bool in pane.id == id }
        return pane.map(flow.line) ?? "no pane"
    }

    @Test func everyEntryPointReachesTheSameSheet() {
        // A manual check with the update staged, the Update button and the end of a download.
        let flows: [UpdateFlow] = UpdateFlow.Entry.allCases.map { (entry: UpdateFlow.Entry) -> UpdateFlow in saw.flow(entry: entry) }
        #expect(flows.allSatisfy { $0 == flows[0] })
        #expect(flows[0].state == .idle && flows[0].title == "Update Next Term to 0.12.0?")
        #expect(UpdateFlow.subtitle == "Next Term quits, installs the update and opens again.")
    }

    @Test func theButtonsFollowTheStateTable() {
        let idle = saw.flow()
        let idleButtons: [String] = titles(idle)
        #expect(idleButtons == ["Update Now", "When I Quit", "Cancel"], "\(idleButtons)")
        var busy = saw.flow(busy: [saw.agent])
        #expect(busy.state == .busy)
        let busyButtons: [String] = titles(busy)
        #expect(busyButtons == ["Wait for Them", "Update Now", "Cancel"], "\(busyButtons)")
        #expect(busy.press(.waitForThem) == .startWait)
        let waitingButtons: [String] = titles(busy)
        #expect(busy.state == .waiting && waitingButtons == ["Update Now", "Stop Waiting"], "\(waitingButtons)")
        #expect(busy.refresh(saw.plan) == .startCountdown)
        let countdownButtons: [String] = titles(busy)
        #expect(busy.state == .countdown && countdownButtons == ["Cancel"], "\(countdownButtons)")
        // No button is the default: Return presses nothing in any state.
        #expect(UpdateButton.allCases.allSatisfy { !$0.isDefault })
    }

    @Test func onlyUpdateNowAndWaitForThemGiveAConsentWithTheBoxsState() {
        var now = saw.flow()
        #expect(now.press(.updateNow) == .quit(UpdateConsent(version: saw.version, keep: true, covered: saw.plan)))
        var unchecked = saw.flow()
        unchecked.setKeep(false)
        #expect(unchecked.press(.updateNow) == .quit(UpdateConsent(version: saw.version, keep: false, covered: saw.plan)))
        // "When I Quit", "Cancel" and "Stop Waiting" create none.
        var later = saw.flow()
        #expect(later.press(.whenIQuit) == .close)
        var cancel = saw.flow()
        #expect(cancel.press(.cancel) == .close)
        var stop = saw.flow(busy: [saw.agent])
        #expect(stop.press(.waitForThem) == .startWait)
        #expect(stop.press(.stopWaiting) == .endWait)
        // "Update Now" while waiting: the box's state, the plan the user saw.
        var waiting = saw.flow(busy: [saw.agent])
        _ = waiting.press(.waitForThem)
        let busyPlan = saw.planned(busy: [saw.agent])
        #expect(waiting.press(.updateNow) == .quit(UpdateConsent(version: saw.version, keep: true, covered: busyPlan)))
    }

    @Test func waitForThemGivesItsConsentOnlyAtTheCountdownsEnd() {
        var flow = saw.flow(busy: [saw.agent, saw.command])
        flow.setWaited(saw.command, false)
        #expect(flow.press(.waitForThem) == .startWait)
        #expect(flow.consent == nil)
        // The agent still works: the wait goes on.
        let working = saw.planned(busy: [saw.agent, saw.command])
        #expect(flow.refresh(working) == .none && flow.state == .waiting && flow.consent == nil)
        // It is done; the command taken out still runs: the countdown starts.
        let done = saw.planned(busy: [saw.command])
        #expect(flow.refresh(done) == .startCountdown && flow.consent == nil)
        // The plan the user saw, minus the waited tab that finished, plus the tab taken out, which still counts as busy.
        let ended = flow.countdownEnded(done)
        var covered = saw.planned(busy: [saw.agent, saw.command])
        covered.windows[0].panes.removeAll { (pane: UpdatePane) -> Bool in pane.id == saw.agent }
        #expect(ended == .quit(UpdateConsent(version: saw.version, keep: true, covered: covered)))
        // Its Cancel ends the wait, with no consent.
        var cancelled = saw.flow(busy: [saw.agent])
        _ = cancelled.press(.waitForThem)
        _ = cancelled.refresh(saw.plan)
        #expect(cancelled.press(.cancel) == .endWait && cancelled.consent == nil)
    }

    @Test func theBoxStartsCheckedThenAtItsLastState() {
        // AE20: unset, checked; then where the user left it.
        #expect(saw.flow(remembered: nil).keep)
        #expect(!saw.flow(remembered: false).keep)
        #expect(saw.flow(remembered: true).keep)
        #expect(UpdateFlow.rememberKey == "resumeAfterUpdate")
        // Unchecked: every tab closes, kept remote tabs reattach, and Update Now keeps no sessions.
        var flow = saw.flow()
        flow.setKeep(false)
        #expect(flow.summary == "Every tab closes. Kept remote tabs reattach.")
        #expect(line(flow, saw.agent) == "closes" && line(flow, saw.kept) == "reattaches")
        #expect(line(flow, saw.ssh) == "connection closes")
        guard case .quit(let consent) = flow.press(.updateNow) else {
            Issue.record("Update Now gives a consent")
            return
        }
        #expect(!QuitIntent.forUpdate(consent, from: "0.11.0").savesSession)
        var local = UpdatePlan(windows: [UpdateWindow(name: "app", panes: [saw.plan.panes[0]])])
        local.refusal = nil
        var noRemote = UpdateFlow(version: saw.version, plan: local, remembered: false)
        #expect(noRemote.summary == "Every tab closes.")
        noRemote.setKeep(true)
        #expect(noRemote.summary == "1 agent resumes")
    }

    @Test func theSummaryCountsEachOutcome() {
        let flow = saw.flow()
        #expect(flow.summary == "1 agent resumes · 1 command goes back on the line · 1 tab opens in its folder · 1 remote tab reattaches · 1 connection closes")
        let more = UpdateFlow(version: saw.version, plan: saw.planned(outcomes: [saw.split: .resume, saw.command: .notKept]),
                              remembered: nil)
        #expect(more.summary.hasPrefix("2 agents resume · 1 not kept"), "\(more.summary)")
        let leftOut = UpdateFlow(version: saw.version, plan: saw.planned(leftOut: [saw.split]), remembered: nil)
        #expect(leftOut.summary.hasSuffix("1 tab closes"), "\(leftOut.summary)")
        #expect(line(leftOut, saw.split) == "closes")
    }

    @Test func aRunningCommandMakesTheSheetBusyAndIsWaitedFor() {
        // AE16: listed first, in the wait set, its line says it is waited for. Return presses nothing.
        var flow = saw.flow(busy: [saw.command])
        #expect(flow.state == .busy && flow.waitSet == [saw.command])
        #expect(flow.busyPanes.map(\.id) == [saw.command])
        #expect(line(flow, saw.command) == "waited for")
        let serving = UpdateFlow(version: saw.version, plan: saw.planned(busy: [saw.command], serving: [saw.command]), remembered: nil)
        #expect(line(serving, saw.command) == "waited for, though it never ends by itself")
        // Taken out: not waited for, and it stops; with the box checked it goes back on the line, or else gets a note.
        flow.setWaited(saw.command, false)
        #expect(flow.waitSet.isEmpty)
        #expect(line(flow, saw.command) == "stops at the update, then goes back on the line")
        let otherShell = UpdateFlow(version: saw.version, plan: saw.planned(busy: [saw.command], outcomes: [saw.command: .commandNote]),
                                    remembered: nil)
        var noted = otherShell
        noted.setWaited(saw.command, false)
        #expect(line(noted, saw.command) == "stops at the update, then gets a note")
        flow.setKeep(false)
        #expect(line(flow, saw.command) == "stops at the update, and closes")
        // An agent taken out: its current turn stops.
        var agent = saw.flow(busy: [saw.agent])
        agent.setWaited(saw.agent, false)
        #expect(line(agent, saw.agent) == "its current turn stops at the update, then Claude Code resumes")
    }

    @Test func aPlainSshTabNeverMakesTheSheetBusy() {
        // AE8: listed as "connection closes", never busy, never in the wait set, even when told it is busy.
        var flow = saw.flow(busy: [saw.ssh, saw.kept])
        #expect(flow.state == .idle && flow.waitSet.isEmpty)
        flow.setWaited(saw.ssh, true)
        #expect(flow.waitSet.isEmpty)
        #expect(line(flow, saw.ssh) == "connection closes")
    }

    @Test func theCountdownStartsWhenEveryWaitedTabIsDoneWhileATabTakenOutStillRuns() {
        var flow = saw.flow(busy: [saw.agent, saw.command])
        flow.setWaited(saw.command, false)
        _ = flow.press(.waitForThem)
        #expect(flow.refresh(saw.planned(busy: [saw.command])) == .startCountdown)
        // Nothing waited for: the countdown starts at once.
        var none = saw.flow(busy: [saw.command])
        none.setWaited(saw.command, false)
        #expect(none.press(.waitForThem) == .startCountdown && none.state == .countdown)
        // The wait set only shrinks: a tab that finished and works again is not waited for again.
        var shrinking = saw.flow(busy: [saw.agent, saw.command])
        _ = shrinking.press(.waitForThem)
        _ = shrinking.refresh(saw.planned(busy: [saw.command]))
        #expect(shrinking.waitSet == [saw.command])
        _ = shrinking.refresh(saw.planned(busy: [saw.command, saw.agent]))
        #expect(shrinking.waitSet == [saw.command])
        #expect(shrinking.refresh(saw.plan) == .startCountdown)
    }

    @Test func theCountdownsEndQuitsUnlessThePlanGotWorse() {
        // The waited tabs that finished and the tab taken out never show the sheet again.
        var flow = saw.flow(busy: [saw.agent, saw.command])
        flow.setWaited(saw.command, false)
        _ = flow.press(.waitForThem)
        _ = flow.refresh(saw.planned(busy: [saw.command]))
        guard case .quit = flow.countdownEnded(saw.planned(busy: [saw.command])) else {
            Issue.record("it quits")
            return
        }
        // A new busy tab, a session that can no longer be kept, or a remote tab that would now be lost shows it again,
        // in the busy or idle state, with the changed lines marked.
        let worse: [UpdatePlan] = [
            saw.planned(busy: [saw.command, saw.agent]),
            { () -> UpdatePlan in var plan = saw.planned(busy: [saw.command]); plan.refusal = .notSaved; return plan }(),
            saw.planned(busy: [saw.command], outcomes: [saw.kept: .freshConnection]),
        ]
        for current in worse {
            var again = saw.flow(busy: [saw.agent, saw.command])
            again.setWaited(saw.command, false)
            _ = again.press(.waitForThem)
            _ = again.refresh(saw.planned(busy: [saw.command]))
            #expect(again.countdownEnded(current) == .showAgain)
            #expect(again.state == .busy || again.state == .idle)
            #expect(again.plan == current && again.consent == nil)
        }
        var marked = saw.flow(busy: [saw.agent])
        _ = marked.press(.waitForThem)
        _ = marked.refresh(saw.plan)
        _ = marked.countdownEnded(saw.planned(busy: [saw.agent]))
        let changed: [UUID] = marked.details.filter(\.changed).compactMap(\.pane)
        #expect(changed == [saw.agent])
    }

    @Test func aQuitWhileWaitingUsesNoConsent() {
        // ⌘Q while waiting is a normal quit: the consent from "Wait for Them" does not exist yet, so the quit is the user's,
        // asks the 0.11 quit questions ("Quitting stops…" with the box), and installs without relaunching.
        var flow = saw.flow(busy: [saw.agent])
        _ = flow.press(.waitForThem)
        #expect(flow.consent == nil)
        let reason = QuitReason.of(plainSelfTest: false, harness: nil, updateConsent: flow.consent != nil, appleEventReason: nil)
        #expect(reason == .user)
        let update: UpdateQuit? = flow.consent.map { (consent: UpdateConsent) -> UpdateQuit in
            UpdateQuit(consent: consent, current: flow.plan)
        }
        let input = QuitInput(unsavedFiles: 0, busyTabs: 1, terminalWindows: 1, sheetAttached: false, reason: reason,
                              settings: LaunchSettings(), update: update)
        let asked: [QuitQuestion] = QuitPolicy.questions(input)
        let expected: [QuitQuestion] = [.busy(resumeCheckbox: true)]
        #expect(asked == expected, "\(asked)")
        #expect(QuitIntent.ordinary(reason: reason, settings: LaunchSettings(), consent: false)?.relaunches == false)
    }

    @Test func aTabBusyOnlyWithItsJobsIsWaitedForAndSaysItsJobsStop() {
        // `npm run dev &`, or vim stopped with ctrl-Z, at an idle prompt: busy, listed first, and waited for, as ⌘Q names it.
        var flow = UpdateFlow(version: saw.version, plan: saw.planned(busy: [saw.split], jobs: [saw.split]), remembered: nil)
        #expect(flow.state == .busy && flow.waitSet == [saw.split])
        #expect(flow.busyPanes.map(\.id) == [saw.split])
        #expect(line(flow, saw.split) == "waited for")
        // Taken out: its jobs stop, and the tab comes back as planned, or closes with the box unchecked.
        flow.setWaited(saw.split, false)
        #expect(line(flow, saw.split) == "its jobs stop at the update; opens in its folder")
        flow.setKeep(false)
        #expect(line(flow, saw.split) == "its jobs stop at the update, and it closes")
        // An agent idle in front of a background job: the job stops, and the agent still resumes.
        var agent = UpdateFlow(version: saw.version, plan: saw.planned(busy: [saw.agent], jobs: [saw.agent]), remembered: nil)
        agent.setWaited(saw.agent, false)
        #expect(line(agent, saw.agent) == "its jobs stop at the update; Claude Code resumes")
        // The wait counts it done once its jobs are gone.
        var waiting = UpdateFlow(version: saw.version, plan: saw.planned(busy: [saw.split], jobs: [saw.split]), remembered: nil)
        #expect(waiting.press(.waitForThem) == .startWait)
        #expect(waiting.refresh(saw.plan) == .startCountdown)
    }

    @Test func showingTheSheetAgainKeepsTheUsersChoices() {
        // The Update button or a check while the sheet is up: the plan now, with the box, the "Wait for this" choices and
        // the marked lines as the user left them. A tab newly busy joins the wait; the one taken out stays out.
        var flow = saw.flow(busy: [saw.agent, saw.command])
        flow.setWaited(saw.command, false)
        flow.setKeep(false)
        flow.replan(saw.planned(busy: [saw.agent, saw.command, saw.split]))
        #expect(flow.state == .busy && !flow.keep)
        #expect(flow.waitSet == [saw.agent, saw.split])
        // Every busy tab finished: the idle sheet.
        flow.replan(saw.plan)
        #expect(flow.state == .idle && flow.waitSet.isEmpty)
        // The lines marked when the sheet showed again stay marked.
        var again = saw.flow(busy: [saw.agent])
        again.showAgain(saw.planned(busy: [saw.agent]), marking: [saw.agent])
        again.replan(saw.planned(busy: [saw.agent]))
        let changed: [UUID] = again.details.filter(\.changed).compactMap(\.pane)
        #expect(changed == [saw.agent])
        // Sessions that can no longer be kept: the box unchecked and dimmed.
        var lost = saw.flow()
        var unsaved = saw.plan
        unsaved.refusal = .notSaved
        lost.replan(unsaved)
        #expect(!lost.keep && !lost.keepEnabled)
        // While waiting nothing is planned again: the wait panel comes forward as it is.
        var waiting = saw.flow(busy: [saw.agent])
        _ = waiting.press(.waitForThem)
        waiting.replan(saw.planned(busy: [saw.agent, saw.command]))
        let unplanned = waiting.plan == saw.planned(busy: [saw.agent])
        #expect(waiting.state == .waiting && waiting.waitSet == [saw.agent] && unplanned)
    }

    @Test func theBoxIsTheSameInEveryStateAndTheCountdownsConsentReadsIt() {
        var flow = saw.flow(busy: [saw.agent])
        _ = flow.press(.waitForThem)
        flow.setKeep(false)
        #expect(!flow.keep)
        #expect(flow.refresh(saw.plan) == .startCountdown)
        flow.setKeep(true)
        #expect(flow.keep)
        guard case .quit(let consent) = flow.countdownEnded(saw.plan) else {
            Issue.record("the countdown's end gives the consent")
            return
        }
        #expect(consent.keep)
    }

    @Test func anUpdateQuitOverADialogOrForAnotherVersionIsRefusedAndSaysWhy() {
        let consent = saw.consent()
        func refusal(staged: String?, sheet: Bool = false, modal: Bool = false, asking: Bool = false) -> UpdateQuitRefusal? {
            UpdateFlow.quitRefusal(for: consent, staged: staged, sheetAttached: sheet, modalWindow: modal, askingToQuit: asking)
        }
        #expect(refusal(staged: saw.version) == nil)
        // A commit sheet on another window, a modal window, or a quit's question: the press is kept, and the line says why.
        #expect(refusal(staged: saw.version, sheet: true) == .dialogOpen)
        #expect(refusal(staged: saw.version, modal: true) == .dialogOpen)
        #expect(refusal(staged: saw.version, asking: true) == .dialogOpen)
        #expect(refusal(staged: "0.13.0", sheet: true) == .dialogOpen)
        // Another version staged since: the consent covered the one before.
        #expect(refusal(staged: "0.13.0") == .otherVersion)
        #expect(refusal(staged: nil) == .otherVersion)
        // What the sheet or the wait panel says: click again, or, in the countdown, that it waits for the dialog to close.
        let sheet = saw.flow()
        #expect(sheet.heldLine == "The update can’t start while a dialog or sheet is open. Close it, then click Update Now again.")
        var counting = saw.flow(busy: [saw.agent])
        _ = counting.press(.waitForThem)
        _ = counting.refresh(saw.plan)
        #expect(counting.state == .countdown)
        #expect(counting.heldLine == "The update starts once the open dialog or sheet is closed.")
    }

    @Test func aFailedInstallPromisesTheUpdateButtonOnlyAfterTheCheckItRuns() {
        // R18, AE7: after the relaunch nothing is staged, so the Update button offers the update only once a check found
        // it; the one alert says the check runs now, and never that the button offers it already.
        for outcome in [InstallResult.Outcome.failedKeptOld, .failedRestoredBackup] {
            let text = UpdateFlow.installFailedText(outcome)
            #expect(text.contains("Next Term checks for it again now, and the Update button offers it once that check finds it."))
            #expect(!text.contains("still offers"), "\(text)")
            #expect(text.hasSuffix("You can download it from the release page instead."))
        }
        let backup = UpdateFlow.installFailedText(.failedRestoredBackup)
        #expect(backup.hasPrefix("The new version could not be put in place, so this version was opened from its backup."))
        let note = "This version opened again. Next Term checks for the update again now, and the Update button offers it once "
            + "that check finds it."
        #expect(UpdateFlow.didNotInstallText == note)
    }

    @Test func sessionsThatCannotBeKeptShowTheSheetWithTheBoxUncheckedAndDimmed() {
        for refusal in [KeepRefusal.translocated, .notSaved] {
            var plan = saw.planned(busy: [saw.agent])
            plan.refusal = refusal
            var flow = UpdateFlow(version: saw.version, plan: plan, remembered: true)
            #expect(!flow.keep && !flow.keepEnabled)
            flow.setKeep(true)
            #expect(!flow.keep)
            #expect(flow.summary == "Every tab closes. Kept remote tabs reattach.")
            let buttons: [String] = titles(flow)
            #expect(buttons == ["Wait for Them", "Update Now", "Cancel"], "\(buttons)")
            guard case .quit(let consent) = flow.press(.updateNow) else {
                Issue.record("Update Now quits")
                return
            }
            // Its quit never shows "Quitting stops…": the update path skips it.
            let input = QuitInput(unsavedFiles: 0, busyTabs: 1, terminalWindows: 1, sheetAttached: false, reason: .updateRelaunch,
                                  settings: LaunchSettings(), update: UpdateQuit(consent: consent, current: plan))
            let asked: [QuitQuestion] = QuitPolicy.questions(input)
            #expect(asked.isEmpty, "\(asked)")
        }
        #expect(KeepRefusal.translocated.text.hasPrefix("Next Term is running from a temporary location"))
        #expect(KeepRefusal.notSaved.text == "Next Term could not save your sessions, so they won’t come back after this update.")
    }

    @Test func theDetailsAreGroupedByWindowWithSplitPanesIndented() {
        let flow = saw.flow()
        let lines: [String] = flow.details.map(\.text)
        let indents: [Int] = flow.details.map(\.indent)
        #expect(lines.first == "app" && indents.first == 0)
        #expect(lines.contains("app: Claude Code resumes") && lines.contains("web-2: logs: connection closes"))
        let split: UpdateDetail? = flow.details.first { $0.pane == saw.split }
        #expect(split?.indent == 2 && split?.label == "app/src, opens in its folder")
        let tab: UpdateDetail? = flow.details.first { $0.pane == saw.agent }
        #expect(tab?.indent == 1)
    }

    @Test func anApprovalPanelIsHeldFromItsOpeningToItsCloseOnceAndInOrder() {
        final class Panel {}
        var panels = OpenPanels<Panel>()
        let first = Panel()
        let second = Panel()
        let opened = panels.register(first) && panels.register(second)
        let again = panels.register(first)
        #expect(opened && !again, "a panel presented again is held once")
        #expect(panels.all.count == 2 && panels.all.first === first && panels.all.last === second)
        panels.unregister(first)
        #expect(panels.all.count == 1 && panels.all.first === second)
        let reopened = panels.register(first)
        #expect(reopened && panels.all.last === first, "a panel closed, then presented again, is held again")
        panels.unregister(first)
        panels.unregister(first)
        do {
            let gone = Panel()
            panels.register(gone)
        }
        #expect(panels.all.count == 1 && panels.all.first === second, "a panel let go of is not held")
    }

    @Test func itNeverStartsOverASheetAModalWindowOrAQuitsQuestion() {
        #expect(UpdateFlow.mayStart(sheetAttached: false, modalWindow: false, askingToQuit: false))
        #expect(!UpdateFlow.mayStart(sheetAttached: true, modalWindow: false, askingToQuit: false))
        #expect(!UpdateFlow.mayStart(sheetAttached: false, modalWindow: true, askingToQuit: false))
        #expect(!UpdateFlow.mayStart(sheetAttached: false, modalWindow: false, askingToQuit: true))
    }
}

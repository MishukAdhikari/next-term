import CoreServices
import Foundation
import Testing
@testable import NextTermCore

@Suite struct QuitReasonTests {
    @Test func aLogoutRestartOrShutdownIsTheSystemSession() {
        // The six codes loginwindow puts in a quit event's kAEQuitReason, as the SDK spells them.
        let logout: [UInt32] = [kAELogOut, kAEReallyLogOut]
        let restart: [UInt32] = [kAEShowRestartDialog, kAERestart]
        let shutdown: [UInt32] = [kAEShowShutdownDialog, kAEShutDown]
        for code in logout + restart + shutdown {
            let reason: QuitReason = QuitReason(appleEventReason: code)
            #expect(reason == .systemSession, "\(code)")
        }
    }

    @Test func anyOtherQuitIsTheUsers() {
        // ⌘Q and the Dock's Quit send no reason; a scripted quit may send its own.
        #expect(QuitReason(appleEventReason: nil) == .user)
        #expect(QuitReason(appleEventReason: 0) == .user)
        #expect(QuitReason(appleEventReason: kAEQuitApplication) == .user)
        #expect(QuitReason(appleEventReason: 0x6162_6364) == .user) // 'abcd'
    }
}

@Suite struct QuitPolicyTests {
    /// A user quit with two terminal windows open, nothing unsaved or busy, and "At launch" as given: nil, never chosen.
    func input(unsaved: Int = 0, busy: Int = 0, windows: Int = 2, sheet: Bool = false, reason: QuitReason = .user,
               opens: LaunchOpens? = .welcome, ask: Bool = true, update: UpdateQuit? = nil) -> QuitInput {
        var settings = LaunchSettings()
        if let opens { settings.opens = opens }
        settings.askToReopenOnQuit = ask
        return QuitInput(unsavedFiles: unsaved, busyTabs: busy, terminalWindows: windows, sheetAttached: sheet, reason: reason,
                         settings: settings, update: update)
    }

    /// The questions `input` gives, checked in one place: comparing arrays of enums inside `#expect` is
    /// slow to type-check.
    func expectQuestions(_ input: QuitInput, _ expected: QuitQuestion..., sourceLocation: SourceLocation = #_sourceLocation) {
        let asked: [QuitQuestion] = QuitPolicy.questions(input)
        let same: Bool = asked == expected
        #expect(same, "asked \(asked) for \(input)", sourceLocation: sourceLocation)
    }

    // The questions by name, typed.
    func plain(_ resumeCheckbox: Bool) -> QuitQuestion { .quit(resumeCheckbox: resumeCheckbox) }
    func saveChanges(_ resumeCheckbox: Bool?) -> QuitQuestion { .saveChanges(resumeCheckbox: resumeCheckbox) }
    func busy(_ resumeCheckbox: Bool?) -> QuitQuestion { .busy(resumeCheckbox: resumeCheckbox) }

    /// Whether a question carries the resume checkbox: the plain dialog, or an alert with it.
    func carriesTheBox(_ question: QuitQuestion) -> Bool {
        switch question {
        case .saveChanges(let checkbox), .busy(let checkbox): return checkbox != nil
        case .quit: return true
        case .updateSheet: return false
        }
    }

    @Test func aQuitWithNothingElseToAskShowsThePlainDialogAlone() {
        // AE17, AE19: the box starts at the stored "At launch" choice, and checked when none is stored.
        expectQuestions(input(opens: nil), plain(true))
        expectQuestions(input(opens: .welcome), plain(false))
        expectQuestions(input(opens: .lastProjects), plain(true))
        expectQuestions(input(windows: 1, opens: nil), plain(true))
    }

    @Test func aTerminalWindowWithoutAProjectAsksAndTheWelcomeWindowAloneDoesNot() {
        expectQuestions(input(windows: 1, opens: .lastProjects), plain(true))
        expectQuestions(input(windows: 0))
        expectQuestions(input(unsaved: 1, windows: 0), saveChanges(nil))
        expectQuestions(input(busy: 1, windows: 0), busy(nil))
    }

    @Test func theQuittingStopsAlertCarriesTheCheckboxWhenItShows() {
        // AE22: the save-changes alert first, without it; then "Quitting stops…", checked under Resume.
        expectQuestions(input(unsaved: 1, busy: 1, opens: .lastProjects), saveChanges(nil), busy(true))
        expectQuestions(input(unsaved: 3, busy: 2), saveChanges(nil), busy(false))
        expectQuestions(input(unsaved: 1, busy: 1, opens: nil), saveChanges(nil), busy(true))
        expectQuestions(input(busy: 1), busy(false))
        expectQuestions(input(busy: 1, opens: .lastProjects), busy(true))
    }

    @Test func elseTheSaveChangesAlertCarriesIt() {
        // No plain dialog follows it.
        expectQuestions(input(unsaved: 1), saveChanges(false))
        expectQuestions(input(unsaved: 2, opens: .lastProjects), saveChanges(true))
        expectQuestions(input(unsaved: 1, opens: nil), saveChanges(true))
    }

    @Test func askOffAsksNothingAboutResuming() {
        // AE18: the safety questions stay.
        expectQuestions(input(ask: false))
        expectQuestions(input(unsaved: 1, ask: false), saveChanges(nil))
        expectQuestions(input(unsaved: 1, busy: 1, opens: .lastProjects, ask: false), saveChanges(nil), busy(nil))
    }

    @Test func aLogoutOrAnUpdateRelaunchAsksNothingAboutResuming() {
        // Unsaved files are still asked about; a logout's running work too. An update relaunch never asks about busy tabs:
        // its sheet showed what stops.
        expectQuestions(input(reason: .systemSession, opens: .lastProjects))
        expectQuestions(input(unsaved: 1, reason: .systemSession), saveChanges(nil))
        expectQuestions(input(busy: 1, reason: .systemSession), busy(nil))
        expectQuestions(input(reason: .updateRelaunch, opens: .lastProjects))
        expectQuestions(input(unsaved: 1, reason: .updateRelaunch), saveChanges(nil))
        expectQuestions(input(busy: 1, reason: .updateRelaunch))
    }

    @Test func aSheetUpAsksNothingAboutResuming() {
        // The `nxtrm` install offer, an Open panel.
        expectQuestions(input(sheet: true))
        expectQuestions(input(unsaved: 1, sheet: true), saveChanges(nil))
        expectQuestions(input(busy: 1, sheet: true), busy(nil))
    }

    @Test func theSelfTestIsAskedNothing() {
        expectQuestions(input(unsaved: 2, busy: 1, reason: .selfTest))
        expectQuestions(input(reason: .selfTest))
    }

    /// Over every mix: the box on one question at most, and on one exactly when asking applies; the plain dialog alone;
    /// the save-changes alert first; and the save-changes and "Quitting stops…" alerts whenever there are unsaved files
    /// or busy tabs, outside the self-test and the update relaunch, which never asks about busy tabs.
    @Test func everyMixAsksAboutResumingOnceAtMost() {
        let counts = [0, 1, 3]
        let choices: [LaunchOpens?] = [nil] + LaunchOpens.allCases.map { (opens: LaunchOpens) -> LaunchOpens? in opens }
        for unsaved in counts {
            for busy in counts {
                for windows in counts {
                    for sheet in [false, true] {
                        for reason in QuitReason.allCases {
                            for opens in choices {
                                for ask in [false, true] {
                                    let quit = input(unsaved: unsaved, busy: busy, windows: windows, sheet: sheet,
                                                     reason: reason, opens: opens, ask: ask)
                                    check(quit)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func check(_ quit: QuitInput) {
        let asked: [QuitQuestion] = QuitPolicy.questions(quit)
        let label = "\(quit)"
        if quit.reason == .selfTest {
            #expect(asked.isEmpty, "\(label)")
            return
        }
        let userAsks: Bool = quit.reason == .user && quit.settings.askToReopenOnQuit
        let applies: Bool = userAsks && quit.terminalWindows > 0 && !quit.sheetAttached
        #expect(QuitPolicy.asksAboutResuming(quit) == applies, "\(label)")
        let carriers: [QuitQuestion] = asked.filter(carriesTheBox)
        let once: Int = applies ? 1 : 0
        #expect(carriers.count == once, "\(label)")
        let starts: Bool = !quit.settings.opensChosen || quit.settings.opens == .lastProjects
        for question in carriers {
            switch question {
            case .saveChanges(let checkbox), .busy(let checkbox): #expect(checkbox == starts, "\(label)")
            case .quit(let checkbox): #expect(checkbox == starts, "\(label)")
            case .updateSheet: #expect(Bool(false), "\(label)")
            }
        }
        if asked.contains(where: isPlain) { #expect(asked.count == 1, "\(label)") }
        let saves: Int? = asked.firstIndex(where: isSaveChanges)
        let stops: Int? = asked.firstIndex(where: isBusy)
        #expect((saves != nil) == (quit.unsavedFiles > 0), "\(label)")
        let busyAsked: Bool = quit.busyTabs > 0 && quit.reason != .updateRelaunch
        #expect((stops != nil) == busyAsked, "\(label)")
        if let saves { #expect(saves == 0, "\(label)") }
        #expect(!asked.contains(.updateSheet), "\(label)")
    }

    func isPlain(_ question: QuitQuestion) -> Bool {
        if case .quit = question { return true } else { return false }
    }

    func isSaveChanges(_ question: QuitQuestion) -> Bool {
        if case .saveChanges = question { return true } else { return false }
    }

    func isBusy(_ question: QuitQuestion) -> Bool {
        if case .busy = question { return true } else { return false }
    }

    @Test func theAnswerSetsAtLaunch() {
        let welcome = chosen(.welcome)
        let resume = chosen(.lastProjects)
        // The plain dialog's Quit: the box's state.
        #expect(QuitPolicy.settings(after: .quit(resume: true, dontAskAgain: false), from: welcome) == resume)
        #expect(QuitPolicy.settings(after: .quit(resume: false, dontAskAgain: false), from: resume) == welcome)
        #expect(QuitPolicy.settings(after: .quit(resume: true, dontAskAgain: false), from: LaunchSettings()) == resume)
        #expect(QuitPolicy.settings(after: .quit(resume: false, dontAskAgain: false), from: LaunchSettings()) == welcome)
        // "Don’t ask again" turns Ask off too.
        var resumeQuietly = resume
        resumeQuietly.askToReopenOnQuit = false
        var welcomeQuietly = welcome
        welcomeQuietly.askToReopenOnQuit = false
        #expect(QuitPolicy.settings(after: .quit(resume: true, dontAskAgain: true), from: welcome) == resumeQuietly)
        #expect(QuitPolicy.settings(after: .quit(resume: false, dontAskAgain: true), from: resume) == welcomeQuietly)
        // The alerts' checkbox sets only "At launch".
        #expect(QuitPolicy.settings(after: .checkbox(checked: true), from: welcome) == resume)
        #expect(QuitPolicy.settings(after: .checkbox(checked: false), from: resume) == welcome)
        #expect(QuitPolicy.settings(after: .checkbox(checked: false), from: welcome) == welcome)
        // Keep scrollback is never touched.
        var noScrollback = welcome
        noScrollback.keepScrollback = false
        #expect(!QuitPolicy.settings(after: .quit(resume: true, dontAskAgain: true), from: noScrollback).keepScrollback)
    }

    @Test func theAnswerNeverUndoesOpenANewTerminal() {
        let terminal = chosen(.newTerminal)
        let resume = chosen(.lastProjects)
        // The box starts unchecked: nothing resumes under it.
        #expect(!QuitPolicy.resumeCheckbox(terminal))
        // Unchecked, on the plain dialog or an alert: "At launch" stays as it is.
        #expect(QuitPolicy.settings(after: .quit(resume: false, dontAskAgain: false), from: terminal) == terminal)
        #expect(QuitPolicy.settings(after: .checkbox(checked: false), from: terminal) == terminal)
        var terminalQuietly = terminal
        terminalQuietly.askToReopenOnQuit = false
        #expect(QuitPolicy.settings(after: .quit(resume: false, dontAskAgain: true), from: terminal) == terminalQuietly)
        // Checked: Resume where I left off, as from any other choice.
        #expect(QuitPolicy.settings(after: .quit(resume: true, dontAskAgain: false), from: terminal) == resume)
        #expect(QuitPolicy.settings(after: .checkbox(checked: true), from: terminal) == resume)
        // Through the quit's replies too.
        var unchecked = QuitAsking()
        unchecked.reply(.goOn(resume: false, dontAskAgain: false), to: plain(false))
        #expect(!unchecked.quitConsent && unchecked.settings(from: terminal) == terminal)
    }

    func chosen(_ opens: LaunchOpens) -> LaunchSettings {
        var settings = LaunchSettings()
        settings.opens = opens
        return settings
    }

    @Test func onlyAGoAheadWithTheBoxCheckedGivesTheQuitConsent() {
        // R30, AE18: the plain dialog's Quit and the alerts' go-ahead buttons, with the box checked.
        #expect(QuitPolicy.quitConsent(after: .quit(resume: true, dontAskAgain: false)))
        #expect(QuitPolicy.quitConsent(after: .quit(resume: true, dontAskAgain: true)))
        #expect(QuitPolicy.quitConsent(after: .checkbox(checked: true)))
        #expect(!QuitPolicy.quitConsent(after: .quit(resume: false, dontAskAgain: false)))
        #expect(!QuitPolicy.quitConsent(after: .checkbox(checked: false)))
        // A quit that asked nothing: no answer, no consent, whatever "At launch" says.
        #expect(!QuitPolicy.quitConsent(after: nil))
    }

    @Test func aQuitsRepliesGiveTheConsentOnlyWhenItGoesAhead() {
        // The plain dialog, Quit with the box checked.
        var plainQuit = QuitAsking()
        plainQuit.reply(.goOn(resume: true, dontAskAgain: false), to: plain(true))
        #expect(!plainQuit.cancelled && plainQuit.quitConsent)
        #expect(plainQuit.settings(from: chosen(.welcome)) == chosen(.lastProjects))
        // AE19: unchecked, Welcome and no consent; Cancel writes nothing and gives none.
        var unchecked = QuitAsking()
        unchecked.reply(.goOn(resume: false, dontAskAgain: false), to: plain(true))
        #expect(!unchecked.quitConsent && unchecked.settings(from: chosen(.lastProjects)) == chosen(.welcome))
        var cancelled = QuitAsking()
        cancelled.reply(.cancel, to: plain(true))
        #expect(cancelled.cancelled && !cancelled.quitConsent && cancelled.settings(from: chosen(.lastProjects)) == nil)
        // AE22: Don’t Save on the save-changes alert without the box, then Quit on "Quitting stops…" with it checked.
        var both = QuitAsking()
        both.reply(.goOn(resume: nil, dontAskAgain: false), to: saveChanges(nil))
        #expect(!both.quitConsent)
        both.reply(.goOn(resume: true, dontAskAgain: false), to: busy(true))
        #expect(both.quitConsent)
        // A failed Save All, after the box was checked on the save-changes alert, cancels: the consent goes with it.
        var failedSave = QuitAsking()
        failedSave.reply(.goOn(resume: true, dontAskAgain: false), to: saveChanges(true))
        #expect(failedSave.quitConsent)
        failedSave.reply(.cancel, to: saveChanges(true))
        #expect(failedSave.cancelled && !failedSave.quitConsent && failedSave.settings(from: LaunchSettings()) == nil)
        // A quit that asked nothing gives none, and saves nothing.
        let silent = QuitAsking()
        #expect(!silent.quitConsent && silent.settings(from: chosen(.lastProjects)) == nil)
    }

    /// The user changes the resume box while a quit dialog shows, then presses a button: the answer is the box as the user
    /// left it, on every dialog that carries it, never how it started (R29, R30).
    @Test func eachDialogReadsItsBoxOnlyAfterThePress() {
        let questions: [QuitQuestion] = [saveChanges(true), saveChanges(false), busy(true), busy(false), plain(true), plain(false)]
        for question in questions {
            let start = question.resumeCheckbox ?? false
            var presses: [QuitPress] = [.goOn]
            if case .saveChanges = question { presses.append(.save) }
            for press in presses {
                let dialog = AnsweredDialog(box: start, toggles: true, press: press)
                var asking = QuitAsking()
                #expect(asking.ask(question, on: dialog) == press)
                #expect(!dialog.readBeforePress, "\(question)")
                // Unchecked by the user: Welcome and no consent. Checked by the user: Resume and the consent.
                #expect(asking.answer?.resume == !start, "\(question) \(press)")
                #expect(asking.quitConsent == !start, "\(question) \(press)")
                let opens: LaunchOpens = start ? .welcome : .lastProjects
                #expect(asking.settings(from: chosen(start ? .lastProjects : .welcome))?.opens == opens, "\(question) \(press)")
            }
        }
    }

    /// The review's case: "At launch" reads Resume, one file is unsaved and nothing is busy, so the save-changes alert
    /// carries the box, checked. The user unchecks it and presses Don’t Save, or Save: Welcome, and no consent.
    @Test func uncheckingTheBoxOnTheSaveChangesAlertGivesNoConsent() {
        expectQuestions(input(unsaved: 1, opens: .lastProjects), saveChanges(true))
        for press in [QuitPress.goOn, .save] {
            var asking = QuitAsking()
            asking.ask(saveChanges(true), on: AnsweredDialog(box: true, toggles: true, press: press))
            #expect(!asking.quitConsent && asking.settings(from: chosen(.lastProjects)) == chosen(.welcome))
        }
        // Left as it was, the box answers as it started.
        var kept = QuitAsking()
        kept.ask(saveChanges(true), on: AnsweredDialog(box: true, toggles: false, press: .goOn))
        #expect(kept.quitConsent && kept.settings(from: chosen(.lastProjects)) == chosen(.lastProjects))
    }

    @Test func aDialogCancelledAfterTheBoxChangedAnswersNothing() {
        for question in [saveChanges(true), busy(false), plain(true)] {
            let dialog = AnsweredDialog(box: question.resumeCheckbox ?? false, toggles: true, press: .cancel)
            var asking = QuitAsking()
            #expect(asking.ask(question, on: dialog) == .cancel)
            #expect(asking.cancelled && !asking.quitConsent && asking.settings(from: chosen(.welcome)) == nil, "\(question)")
        }
        // A dialog that carries no box answers nothing about resuming, whatever it holds; Don’t ask again counts only on
        // the plain dialog.
        var noBox = QuitAsking()
        noBox.ask(saveChanges(nil), on: AnsweredDialog(box: true, toggles: false, press: .goOn))
        #expect(noBox.answer == nil && !noBox.quitConsent)
        var plainQuit = QuitAsking()
        plainQuit.ask(plain(false), on: AnsweredDialog(box: false, toggles: true, dontAskAgain: true, press: .goOn))
        #expect(plainQuit.answer == .quit(resume: true, dontAskAgain: true))
    }

    @Test func whenNoTabIsBusyAnyMoreThePlainDialogAsksInstead() {
        // AE22, raced: the save-changes alert showed without the box, which "Quitting stops…" was to carry; Claude finished
        // its turn under it. The question is still asked once, on the plain dialog.
        let gone: QuitQuestion? = QuitPolicy.lastQuestion(planned: busy(true), busyTabs: 0)
        #expect(gone == plain(true))
        let goneUnchecked: QuitQuestion? = QuitPolicy.lastQuestion(planned: busy(false), busyTabs: 0)
        #expect(goneUnchecked == plain(false))
        // Still busy: "Quitting stops…", with the box the policy gave it.
        let still: QuitQuestion? = QuitPolicy.lastQuestion(planned: busy(true), busyTabs: 2)
        #expect(still == busy(true))
        // A tab that turned busy under a question before: "Quitting stops…", without the box another alert carried.
        let turned: QuitQuestion? = QuitPolicy.lastQuestion(planned: nil, busyTabs: 1)
        #expect(turned == busy(nil))
        // Asking off, a logout, a sheet: no box was planned, so nothing more is asked.
        #expect(QuitPolicy.lastQuestion(planned: busy(nil), busyTabs: 0) == nil)
        #expect(QuitPolicy.lastQuestion(planned: nil, busyTabs: 0) == nil)
        // Its Quit with the box checked gives the consent and sets Resume, as the busy alert's would have.
        var asking = QuitAsking()
        asking.reply(.goOn(resume: nil, dontAskAgain: false), to: saveChanges(nil))
        asking.reply(.goOn(resume: true, dontAskAgain: false), to: plain(true))
        #expect(asking.quitConsent && asking.settings(from: chosen(.welcome)) == chosen(.lastProjects))
    }

    // MARK: the update path

    let saw = UpdateFixture()

    @Test func aQuitGoesAheadForTheReasonReadBeforeItsQuestions() {
        // Nothing changed under the questions: the update quit stays the update's relaunch, a user quit the user's.
        let consent = saw.consent()
        let update: QuitEnding = QuitPolicy.ending(reason: .updateRelaunch, consentBefore: consent, consentNow: consent)
        #expect(update == .goAhead(.updateRelaunch))
        let user: QuitEnding = QuitPolicy.ending(reason: .user, consentBefore: nil, consentNow: nil)
        #expect(user == .goAhead(.user))
        // Another version was staged under the unsaved-files question, so the consent no longer holds: the quit is
        // cancelled and the sheet shows for the staged version, never a user quit that installs it without relaunching.
        let other: QuitEnding = QuitPolicy.ending(reason: .updateRelaunch, consentBefore: consent, consentNow: nil)
        #expect(other == .updateSheet)
    }

    @Test func anUpdateQuitAsksOnlyAboutUnsavedFilesWithNoBox() {
        // AE9: none with nothing unsaved; one with an unsaved file, with no resume checkbox.
        let consent = saw.consent()
        let quit = UpdateQuit(consent: consent, current: saw.plan)
        expectQuestions(input(reason: .updateRelaunch, opens: nil, update: quit))
        expectQuestions(input(unsaved: 1, reason: .updateRelaunch, opens: nil, update: quit), saveChanges(nil))
        // A busy tab the plan covered is never asked about: the sheet showed it stops.
        let busy = saw.consent(busy: [saw.agent])
        let stillBusy = UpdateQuit(consent: busy, current: saw.planned(busy: [saw.agent]))
        expectQuestions(input(busy: 1, reason: .updateRelaunch, update: stillBusy))
    }

    @Test func aCancelledUpdateQuitLeavesTheNextQuitToTheQuitQuestions() {
        // AE5: the unsaved-files question cancelled; the consent is cleared, so the next ⌘Q has none.
        var asking = QuitAsking()
        asking.reply(.cancel, to: saveChanges(nil))
        #expect(asking.cancelled && asking.settings(from: LaunchSettings()) == nil)
        expectQuestions(input(opens: nil), plain(true))
        expectQuestions(input(unsaved: 1, busy: 1, opens: nil), saveChanges(nil), busy(true))
    }

    @Test func eachKindOfWorsePlanShowsTheUpdateSheetAgainNeverTheBusyQuestion() {
        let consent = saw.consent()
        // A new busy tab.
        let newBusy = UpdateQuit(consent: consent, current: saw.planned(busy: [saw.command]))
        expectQuestions(input(unsaved: 1, busy: 1, reason: .updateRelaunch, update: newBusy), .updateSheet)
        // A session that can no longer be kept: the last save failed.
        var unsaved = saw.plan
        unsaved.refusal = .notSaved
        expectQuestions(input(reason: .updateRelaunch, update: UpdateQuit(consent: consent, current: unsaved)), .updateSheet)
        // A remote tab that would now be lost: its tmux fell back to a plain connection.
        let lost = saw.planned(outcomes: [saw.kept: .freshConnection])
        expectQuestions(input(reason: .updateRelaunch, update: UpdateQuit(consent: consent, current: lost)), .updateSheet)
    }

    @Test func aPlanThatOnlyGotBetterQuitsWithTheConsent() {
        // The busy agent finished its turn; the command that ran finished too.
        let consent = saw.consent(busy: [saw.agent, saw.command])
        let better = saw.planned(outcomes: [saw.command: .idle])
        expectQuestions(input(reason: .updateRelaunch, update: UpdateQuit(consent: consent, current: better)))
        // A tab closed.
        var fewer = saw.plan
        fewer.windows[0].panes.removeAll { (pane: UpdatePane) -> Bool in pane.id == saw.command }
        expectQuestions(input(reason: .updateRelaunch, update: UpdateQuit(consent: consent, current: fewer)))
    }

    @Test func aWaitForThemConsentCoversTheTabsTakenOut() {
        // The waited agent finished; the command the user took out of the wait still runs: no busy question, no sheet.
        var flow = saw.flow(busy: [saw.agent, saw.command])
        flow.setWaited(saw.command, false)
        #expect(flow.press(.waitForThem) == .startWait)
        let finished = saw.planned(busy: [saw.command])
        #expect(flow.refresh(finished) == .startCountdown)
        guard case .quit(let consent) = flow.countdownEnded(finished) else {
            Issue.record("the countdown's end gives the consent")
            return
        }
        expectQuestions(input(busy: 1, reason: .updateRelaunch, update: UpdateQuit(consent: consent, current: finished)))
        // A busy tab outside the plan it covers: the waited agent working again.
        let again = saw.planned(busy: [saw.command, saw.agent])
        expectQuestions(input(busy: 2, reason: .updateRelaunch, update: UpdateQuit(consent: consent, current: again)), .updateSheet)
    }

    @Test func onlyAValidUpdateConsentGivesTheUpdateRelaunch() {
        // The `updateInstallWithoutAsking` switch quits without the sheet: a user quit. So does any other test switch.
        #expect(QuitReason.of(plainSelfTest: false, harness: nil, updateConsent: false, appleEventReason: nil) == .user)
        #expect(QuitReason.of(plainSelfTest: false, harness: nil, updateConsent: true, appleEventReason: nil) == .updateRelaunch)
        let shutdown = QuitReason.of(plainSelfTest: false, harness: nil, updateConsent: false, appleEventReason: kAEShutDown)
        #expect(shutdown == .systemSession)
        #expect(QuitReason.of(plainSelfTest: true, harness: nil, updateConsent: true, appleEventReason: nil) == .selfTest)
        #expect(QuitReason.of(plainSelfTest: false, harness: .user, updateConsent: true, appleEventReason: nil) == .user)
        // A valid update consent asks no resume question: no box, no plain dialog.
        let quit = UpdateQuit(consent: saw.consent(), current: saw.plan)
        let asked: [QuitQuestion] = QuitPolicy.questions(input(unsaved: 1, reason: .updateRelaunch, opens: nil, update: quit))
        #expect(!asked.contains(where: carriesTheBox))
    }

    @Test func anUpdateConsentWithTheBoxUncheckedStillSkipsTheBusyQuestionAndKeepsNoSessions() {
        let consent = saw.consent(keep: false, busy: [saw.agent])
        let quit = UpdateQuit(consent: consent, current: saw.planned(busy: [saw.agent]))
        expectQuestions(input(busy: 1, reason: .updateRelaunch, update: quit))
        let intent = QuitIntent.forUpdate(consent, from: "0.11.0")
        #expect(intent == .update(keep: false, from: "0.11.0", to: saw.version))
        #expect(!intent.savesSession && intent.relaunches)
        #expect(QuitIntent.forUpdate(saw.consent(), from: "0.11.0").savesSession)
        #expect(!QuitIntent.quit(resume: true, consent: true).relaunches)
    }

    @Test func aSystemSessionQuitGivesNoConsentEvenWithTheBoxChecked() {
        // A logout asks nothing, so nothing checked counts: its intent carries no consent.
        var resume = LaunchSettings()
        resume.opens = .lastProjects
        var asking = QuitAsking()
        asking.reply(.goOn(resume: true, dontAskAgain: false), to: plain(true))
        let intent = QuitIntent.ordinary(reason: .systemSession, settings: resume, consent: asking.quitConsent)
        #expect(intent == .quit(resume: true, consent: false))
        #expect(QuitIntent.ordinary(reason: .user, settings: resume, consent: asking.quitConsent) == .quit(resume: true, consent: true))
    }
}

/// The plain quit dialog's buttons and checkbox, and the names its tooltip lists, with made-up folders.
@Suite struct QuitPromptTests {
    let app = "/Users/x/Code/app"
    let api = "/Users/x/Code/api"

    @Test func quitThenCancelAndNeitherIsChosenByItsPlace() {
        // R29: "Quit" then "Cancel". Quit carries no key (the dialog clears its Return); NSAlert gives Cancel ⎋.
        let buttons: [QuitPromptButton] = QuitPolicy.promptButtons
        let titles: [String] = buttons.map(\.title)
        let same: Bool = titles == ["Quit", "Cancel"]
        #expect(same, "\(titles)")
        #expect(QuitPolicy.promptTitle == "Quit Next Term?")
        #expect(QuitPolicy.checkboxTitle == "Reopen windows and resume sessions when Next Term opens")
    }

    @Test func eachButtonAnswersForItself() {
        // Quit gives the box's state and "Don’t ask again"; Cancel gives nothing, whatever is checked.
        #expect(QuitPromptButton.quit.answer(resume: true, dontAskAgain: false) == .quit(resume: true, dontAskAgain: false))
        #expect(QuitPromptButton.quit.answer(resume: false, dontAskAgain: true) == .quit(resume: false, dontAskAgain: true))
        #expect(QuitPromptButton.cancel.answer(resume: true, dontAskAgain: true) == nil)
        // As the quit asks: Quit lets it go on, Cancel cancels it.
        #expect(QuitPromptButton.quit.press == .goOn && QuitPromptButton.cancel.press == .cancel)
        #expect(QuitPromptButton.cancel.answer(resume: false, dontAskAgain: false) == nil)
    }

    @Test func theCheckboxTooltipNamesTheOpenProjects() {
        let two = QuitPolicy.checkboxToolTip([app, api, app])
        #expect(two.contains("“app” and “api”") && two.contains("Settings › General"))
        let none = QuitPolicy.checkboxToolTip([])
        #expect(none.contains("its windows") && !none.contains("“"))
    }

    /// The names `paths` lists, compared outside `#expect`.
    func expectNames(_ paths: [String], _ expected: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let names: [String] = QuitPolicy.projectNames(paths)
        let same: Bool = names == expected
        #expect(same, "\(names)", sourceLocation: sourceLocation)
    }

    @Test func eachProjectIsNamedOnceByItsFolder() {
        expectNames([app, api], ["app", "api"])
        // Two windows on one project.
        expectNames([app, api, app], ["app", "api"])
        expectNames([], [])
    }

    @Test func twoFoldersWithOneNameGetTheirParentsToo() {
        expectNames(["/Users/x/work/app", "/Users/x/home/app", api], ["work/app", "home/app", "api"])
        // As far up as it takes, and only for the ones that read the same.
        expectNames(["/Volumes/a/work/app", "/Users/x/work/app", "/Users/x/Code/web"],
                    ["a/work/app", "x/work/app", "web"])
        expectNames(["/app", "/Users/x/app"], ["app", "x/app"])
    }

    @Test func theListNamesFourAtMost() {
        // Each name in curly quotes, as the save-changes alert names a file, so a short one reads apart from
        // the sentence around it.
        #expect(QuitPolicy.projectList([app]) == "“app”")
        #expect(QuitPolicy.projectList([app, api]) == "“app” and “api”")
        #expect(QuitPolicy.projectList([app, api, "/Users/x/Code/web"]) == "“app”, “api” and “web”")
        let four: [String] = ["a", "b", "c", "d"].map { "/Users/x/Code/" + $0 }
        #expect(QuitPolicy.projectList(four) == "“a”, “b”, “c” and “d”")
        let six: [String] = ["a", "b", "c", "d", "e", "f"].map { "/Users/x/Code/" + $0 }
        #expect(QuitPolicy.projectList(six) == "“a”, “b”, “c”, “d” and 2 more")
        let five: [String] = ["a", "b", "c", "d", "e"].map { "/Users/x/Code/" + $0 }
        #expect(QuitPolicy.projectList(five) == "“a”, “b”, “c”, “d” and 1 more")
        let alike: [String] = ["/Users/x/work/app", "/Users/x/home/app"]
        #expect(QuitPolicy.projectList(alike) == "“work/app” and “home/app”")
    }
}

/// A quit dialog a made-up user answers: while it shows, they flip its resume box (`toggles`), then press `press`. It
/// notes a box read before the press, which would record how the box started rather than the answer.
final class AnsweredDialog: QuitDialog {
    private var box: Bool
    private let toggles: Bool
    private let suppression: Bool
    private let press: QuitPress
    private var shown = false
    private(set) var readBeforePress = false

    init(box: Bool, toggles: Bool, dontAskAgain: Bool = false, press: QuitPress) {
        self.box = box
        self.toggles = toggles
        self.suppression = dontAskAgain
        self.press = press
    }

    func run() -> QuitPress {
        shown = true
        if toggles { box.toggle() }
        return press
    }

    var resumeBox: Bool? {
        if !shown { readBeforePress = true }
        return box
    }

    var dontAskAgain: Bool {
        if !shown { readBeforePress = true }
        return suppression
    }
}

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
    /// A user quit with two project windows open, nothing unsaved or busy and the default settings.
    func input(unsaved: Int = 0, busy: Int = 0, projects: Int = 2, sheet: Bool = false, reason: QuitReason = .user,
               opens: LaunchOpens = .welcome, ask: Bool = true) -> QuitInput {
        var settings = LaunchSettings()
        settings.opens = opens
        settings.askToReopenOnQuit = ask
        return QuitInput(unsavedFiles: unsaved, busyTabs: busy, projectWindows: projects, sheetAttached: sheet,
                         reason: reason, settings: settings)
    }

    /// The questions `input` gives, checked in one place: comparing arrays of enums inside `#expect` is
    /// slow to type-check.
    func expectQuestions(_ input: QuitInput, _ expected: QuitQuestion..., sourceLocation: SourceLocation = #_sourceLocation) {
        let asked: [QuitQuestion] = QuitPolicy.questions(input)
        let same: Bool = asked == expected
        #expect(same, "asked \(asked) for \(input)", sourceLocation: sourceLocation)
    }

    // The questions by name, typed.
    func prompt(returnKeyReopens: Bool) -> QuitQuestion { .reopen(returnKeyReopens: returnKeyReopens) }
    func saveChanges(_ reopenCheckbox: Bool?) -> QuitQuestion { .saveChanges(reopenCheckbox: reopenCheckbox) }
    func busy(_ reopenCheckbox: Bool?) -> QuitQuestion { .busy(reopenCheckbox: reopenCheckbox) }

    /// Whether a question asks about reopening: the prompt, or an alert with the checkbox.
    func asksAboutReopening(_ question: QuitQuestion) -> Bool {
        switch question {
        case .saveChanges(let checkbox), .busy(let checkbox): return checkbox != nil
        case .reopen: return true
        }
    }

    @Test func aQuitWithNothingElseToAskShowsThePromptAlone() {
        // AE6: Return takes the choice that matches the setting.
        expectQuestions(input(), prompt(returnKeyReopens: false))
        expectQuestions(input(opens: .lastProjects), prompt(returnKeyReopens: true))
        expectQuestions(input(projects: 1), prompt(returnKeyReopens: false))
    }

    @Test func theQuittingStopsAlertCarriesTheCheckboxWhenItShows() {
        // AE7: the save-changes alert first, without it; then "Quitting stops…", checked under Reopen.
        expectQuestions(input(unsaved: 1, busy: 1, opens: .lastProjects), saveChanges(nil), busy(true))
        expectQuestions(input(unsaved: 3, busy: 2), saveChanges(nil), busy(false))
        expectQuestions(input(busy: 1), busy(false))
        expectQuestions(input(busy: 1, opens: .lastProjects), busy(true))
    }

    @Test func elseTheSaveChangesAlertCarriesIt() {
        // AE14: no prompt follows it.
        expectQuestions(input(unsaved: 1), saveChanges(false))
        expectQuestions(input(unsaved: 2, opens: .lastProjects), saveChanges(true))
    }

    @Test func askOffAsksNothingAboutReopening() {
        // AE8: the safety questions stay.
        expectQuestions(input(ask: false))
        expectQuestions(input(unsaved: 1, ask: false), saveChanges(nil))
        expectQuestions(input(unsaved: 1, busy: 1, opens: .lastProjects, ask: false), saveChanges(nil), busy(nil))
    }

    @Test func aLogoutOrAnUpdateRelaunchAsksNothingAboutReopening() {
        // AE9, AE10: unsaved files and running work are still asked about.
        let reasons: [QuitReason] = [.systemSession, .updateRelaunch]
        for reason in reasons {
            expectQuestions(input(reason: reason, opens: .lastProjects))
            expectQuestions(input(unsaved: 1, reason: reason), saveChanges(nil))
            expectQuestions(input(busy: 1, reason: reason), busy(nil))
        }
    }

    @Test func noProjectWindowAsksNothingAboutReopening() {
        // AE11: the Welcome window alone, or terminal windows without a project.
        expectQuestions(input(projects: 0))
        expectQuestions(input(unsaved: 1, projects: 0), saveChanges(nil))
        expectQuestions(input(busy: 1, projects: 0), busy(nil))
    }

    @Test func aSheetUpAsksNothingAboutReopening() {
        // R15: the `nxtrm` install offer, an Open panel.
        expectQuestions(input(sheet: true))
        expectQuestions(input(unsaved: 1, sheet: true), saveChanges(nil))
        expectQuestions(input(busy: 1, sheet: true), busy(nil))
    }

    @Test func theSelfTestIsAskedNothing() {
        expectQuestions(input(unsaved: 2, busy: 1, reason: .selfTest))
        expectQuestions(input(reason: .selfTest))
    }

    /// Over every mix: the reopen choice in one question at most, and in one exactly when asking applies;
    /// the prompt alone; the save-changes alert first; and the save-changes and "Quitting stops…" alerts
    /// whenever there are unsaved files or busy tabs, outside the self-test.
    @Test func everyMixAsksAboutReopeningOnceAtMost() {
        let counts = [0, 1, 3]
        for unsaved in counts {
            for busy in counts {
                for projects in counts {
                    for sheet in [false, true] {
                        for reason in QuitReason.allCases {
                            for opens in LaunchOpens.allCases {
                                for ask in [false, true] {
                                    let quit = input(unsaved: unsaved, busy: busy, projects: projects, sheet: sheet,
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
        let applies: Bool = userAsks && quit.projectWindows > 0 && !quit.sheetAttached
        #expect(QuitPolicy.asksAboutReopening(quit) == applies, "\(label)")
        let carriers: [QuitQuestion] = asked.filter(asksAboutReopening)
        let once: Int = applies ? 1 : 0
        #expect(carriers.count == once, "\(label)")
        let reopens: Bool = quit.settings.opens == .lastProjects
        for question in carriers {
            switch question {
            case .saveChanges(let checkbox), .busy(let checkbox): #expect(checkbox == reopens, "\(label)")
            case .reopen(let returnKeyReopens): #expect(returnKeyReopens == reopens, "\(label)")
            }
        }
        if asked.contains(where: isPrompt) { #expect(asked.count == 1, "\(label)") }
        let saves: Int? = asked.firstIndex(where: isSaveChanges)
        let stops: Int? = asked.firstIndex(where: isBusy)
        #expect((saves != nil) == (quit.unsavedFiles > 0), "\(label)")
        #expect((stops != nil) == (quit.busyTabs > 0), "\(label)")
        if let saves { #expect(saves == 0, "\(label)") }
    }

    func isPrompt(_ question: QuitQuestion) -> Bool {
        if case .reopen = question { return true } else { return false }
    }

    func isSaveChanges(_ question: QuitQuestion) -> Bool {
        if case .saveChanges = question { return true } else { return false }
    }

    func isBusy(_ question: QuitQuestion) -> Bool {
        if case .busy = question { return true } else { return false }
    }

    @Test func theAnswerSetsWhenNextTermOpens() {
        let welcome = LaunchSettings()
        var reopen = LaunchSettings()
        reopen.opens = .lastProjects
        // The prompt's buttons.
        #expect(QuitPolicy.settings(after: .reopen(dontAskAgain: false), from: welcome) == reopen)
        #expect(QuitPolicy.settings(after: .dontReopen(dontAskAgain: false), from: reopen) == welcome)
        #expect(QuitPolicy.settings(after: .reopen(dontAskAgain: false), from: reopen) == reopen)
        // "Don’t ask again" turns Ask off too.
        var reopenQuietly = reopen
        reopenQuietly.askToReopenOnQuit = false
        var welcomeQuietly = welcome
        welcomeQuietly.askToReopenOnQuit = false
        #expect(QuitPolicy.settings(after: .reopen(dontAskAgain: true), from: welcome) == reopenQuietly)
        #expect(QuitPolicy.settings(after: .dontReopen(dontAskAgain: true), from: reopen) == welcomeQuietly)
        // The alerts' checkbox sets only "When Next Term opens".
        #expect(QuitPolicy.settings(after: .checkbox(checked: true), from: welcome) == reopen)
        #expect(QuitPolicy.settings(after: .checkbox(checked: false), from: reopen) == welcome)
        #expect(QuitPolicy.settings(after: .checkbox(checked: false), from: welcome) == welcome)
    }
}

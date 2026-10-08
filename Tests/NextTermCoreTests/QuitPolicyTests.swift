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

/// The reopen prompt's buttons and the names it lists, with made-up folders.
@Suite struct QuitPromptTests {
    let app = "/Users/x/Code/app"
    let api = "/Users/x/Code/api"

    /// The buttons' titles, as added: compared outside `#expect`, where arrays are slow to type-check.
    func titles(returnKeyReopens: Bool) -> [String] {
        let buttons: [QuitPromptButton] = QuitPolicy.promptButtons(returnKeyReopens: returnKeyReopens)
        return buttons.map(\.title)
    }

    @Test func theChoiceThatMatchesTheSettingIsTheDefault() {
        // AE6: added first, it is the default, on top of the stacked buttons, and takes Return. "Cancel" is
        // added next, as in the save-changes alert, and sits at the bottom; the other choice last, between them.
        let welcome: [String] = titles(returnKeyReopens: false)
        let reopen: [String] = titles(returnKeyReopens: true)
        let welcomeOrder: Bool = welcome == ["Don’t Reopen", "Cancel", "Reopen"]
        let reopenOrder: Bool = reopen == ["Reopen", "Cancel", "Don’t Reopen"]
        #expect(welcomeOrder, "\(welcome)")
        #expect(reopenOrder, "\(reopen)")
    }

    @Test func eachButtonAnswersForItselfWhereverItSits() {
        // The answer comes from the button pressed, never its place, since the place follows the setting.
        #expect(QuitPromptButton.reopen.answer(dontAskAgain: false) == .reopen(dontAskAgain: false))
        #expect(QuitPromptButton.reopen.answer(dontAskAgain: true) == .reopen(dontAskAgain: true))
        #expect(QuitPromptButton.dontReopen.answer(dontAskAgain: false) == .dontReopen(dontAskAgain: false))
        #expect(QuitPromptButton.dontReopen.answer(dontAskAgain: true) == .dontReopen(dontAskAgain: true))
        // AE13: Cancel has no answer, even with "Don’t ask again" checked: nothing is written.
        #expect(QuitPromptButton.cancel.answer(dontAskAgain: true) == nil)
        #expect(QuitPromptButton.cancel.answer(dontAskAgain: false) == nil)
        for reopens in [false, true] {
            let buttons: [QuitPromptButton] = QuitPolicy.promptButtons(returnKeyReopens: reopens)
            #expect(Set(buttons) == Set(QuitPromptButton.allCases), "\(buttons)")
            #expect(buttons.count == 3 && buttons[1] == .cancel, "\(buttons)")
        }
    }

    @Test func theQuestionSaysThisProjectOrTheseProjectsByTheCount() {
        // The prompt's title, and the checkbox on the save-changes and "Quitting stops…" alerts.
        #expect(QuitPolicy.promptTitle([app]) == "Reopen this project next time?")
        #expect(QuitPolicy.promptTitle([app, api]) == "Reopen these projects next time?")
        #expect(QuitPolicy.checkboxTitle([app]) == "Reopen this project next time")
        #expect(QuitPolicy.checkboxTitle([app, api, "/Users/x/Code/web"]) == "Reopen these projects next time")
        // Two windows on one project are one project.
        #expect(QuitPolicy.promptTitle([app, app]) == "Reopen this project next time?")
        #expect(QuitPolicy.checkboxTitle([app, app]) == "Reopen this project next time")
        // Two folders of one name are two projects.
        let alike: [String] = ["/Users/x/work/app", "/Users/x/home/app"]
        #expect(QuitPolicy.promptTitle(alike) == "Reopen these projects next time?")
    }

    @Test func theOtherChoiceTakesACommandKey() {
        // NSAlert gives the default Return and "Cancel" ⎋. The other choice, added last, is not left to a click:
        // "Don’t Reopen" takes ⌘D, as "Don’t Save" does in the save-changes alert, and "Reopen" ⌘R.
        #expect(QuitPromptButton.dontReopen.commandKey == "d")
        #expect(QuitPromptButton.reopen.commandKey == "r")
        #expect(QuitPromptButton.cancel.commandKey == nil)
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

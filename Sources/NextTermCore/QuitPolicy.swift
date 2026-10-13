import Foundation

/// Why Next Term is quitting. Only a user's quit asks about resuming.
public enum QuitReason: CaseIterable, Sendable {
    /// ⌘Q, the Dock's Quit, a scripted quit: anything the others are not.
    case user
    /// The update quit the user agreed to on the update sheet: a valid update consent ("Update Now", or "Wait for Them" at
    /// its countdown's end). Nothing else gives it, a test switch neither.
    case updateRelaunch
    /// A logout, restart or shutdown, read from the quit Apple event. The one signal for it.
    case systemSession
    /// The plain `--self-test`.
    case selfTest

    /// The `kAEQuitReason` codes (AERegistry.h) loginwindow puts in its quit event: `kAELogOut`,
    /// `kAEReallyLogOut`, `kAEShowRestartDialog`, `kAERestart`, `kAEShowShutdownDialog`, `kAEShutDown`.
    static let systemSessionCodes: Set<UInt32> = Set(["logo", "rlgo", "rrst", "rest", "rsdn", "shut"].map(fourCharCode))

    /// From the quit Apple event's `kAEQuitReason` (`'why?'`), none when it has none: a logout, restart or
    /// shutdown gives `systemSession`, anything else `user`.
    public init(appleEventReason code: UInt32?) {
        if let code, Self.systemSessionCodes.contains(code) { self = .systemSession } else { self = .user }
    }

    /// Why a quit happens: the plain self-test first, then the reason the relaunch harness sets, then a valid update
    /// consent, then the quit Apple event's reason. A quit with no update consent is never the update's relaunch, so a
    /// test switch that quits without the sheet quits as the user's.
    public static func of(plainSelfTest: Bool, harness: QuitReason?, updateConsent: Bool, appleEventReason: UInt32?) -> QuitReason {
        if plainSelfTest { return .selfTest }
        if let harness { return harness }
        if updateConsent { return .updateRelaunch }
        return QuitReason(appleEventReason: appleEventReason)
    }

    private static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { (code: UInt32, byte: UInt8) -> UInt32 in code << 8 | UInt32(byte) }
    }
}

/// An update quit's consent and the plan now, which the quit compares with the plan the consent covers (KTD2).
public struct UpdateQuit: Sendable {
    public var consent: UpdateConsent
    public var current: UpdatePlan

    public init(consent: UpdateConsent, current: UpdatePlan) {
        self.consent = consent
        self.current = current
    }
}

/// What a quit knows when it decides what to ask.
public struct QuitInput: Sendable {
    /// Editor files with unsaved changes.
    public var unsavedFiles: Int
    /// Tabs running something that quitting stops.
    public var busyTabs: Int
    /// Terminal windows, with a project or not.
    public var terminalWindows: Int
    /// A sheet is attached to some window (the `nxtrm` install offer, an Open panel).
    public var sheetAttached: Bool
    public var reason: QuitReason
    public var settings: LaunchSettings
    /// The valid update consent this quit goes ahead under, and the plan now; nil with none.
    public var update: UpdateQuit?

    public init(unsavedFiles: Int, busyTabs: Int, terminalWindows: Int, sheetAttached: Bool, reason: QuitReason,
                settings: LaunchSettings, update: UpdateQuit? = nil) {
        self.unsavedFiles = unsavedFiles
        self.busyTabs = busyTabs
        self.terminalWindows = terminalWindows
        self.sheetAttached = sheetAttached
        self.reason = reason
        self.settings = settings
        self.update = update
    }
}

/// One question a quit asks, in turn. `resumeCheckbox` is the starting state of "Reopen windows and resume sessions when
/// Next Term opens" (`QuitPolicy.checkboxTitle`) on that alert, nil for no checkbox.
public enum QuitQuestion: Equatable, Sendable {
    /// "Save changes to … before quitting?"
    case saveChanges(resumeCheckbox: Bool?)
    /// "Quit Next Term?", "Quitting stops …".
    case busy(resumeCheckbox: Bool?)
    /// "Quit Next Term?" alone, the plain quit dialog: the checkbox, "Don’t ask again", Quit and Cancel.
    case quit(resumeCheckbox: Bool)
    /// The plan the update consent covers got worse: this quit is cancelled, the consent cleared, and the update sheet
    /// shows again.
    case updateSheet

    /// Where its resume checkbox starts; nil when it carries none.
    public var resumeCheckbox: Bool? {
        switch self {
        case .saveChanges(let checkbox), .busy(let checkbox): return checkbox
        case .quit(let checkbox): return checkbox
        case .updateSheet: return nil
        }
    }
}

/// How a quit whose questions were answered ends (QuitPolicy.ending).
public enum QuitEnding: Equatable, Sendable {
    /// It goes ahead, for this reason.
    case goAhead(QuitReason)
    /// It is cancelled, and the update sheet shows for the version staged now.
    case updateSheet
}

/// What was answered about resuming, at a quit that goes ahead. Cancel has no answer: nothing is written.
public enum QuitAnswer: Equatable, Sendable {
    /// The plain dialog's "Quit": its box, and "Don’t ask again".
    case quit(resume: Bool, dontAskAgain: Bool)
    /// The box on the save-changes or "Quitting stops…" alert, as it was when the quit went ahead.
    case checkbox(checked: Bool)

    /// The box was checked.
    public var resume: Bool {
        switch self {
        case .quit(let resume, _): return resume
        case .checkbox(let checked): return checked
        }
    }
}

/// The one table that says what a quit asks (R29). The save-changes and "Quitting stops…" alerts show whenever they
/// apply, as they always have. A quit asks about resuming in one of them at most: "Quitting stops…" when it shows, else
/// the save-changes alert, else the plain quit dialog alone. An update quit with a valid consent asks only about unsaved
/// files, with no checkbox, or shows the update sheet again when its plan got worse (R16).
public enum QuitPolicy {
    /// Whether this quit asks about resuming: a user's quit, with Ask on, a terminal window open and no sheet up.
    public static func asksAboutResuming(_ input: QuitInput) -> Bool {
        guard input.reason == .user, input.update == nil, input.settings.askToReopenOnQuit else { return false }
        return input.terminalWindows > 0 && !input.sheetAttached
    }

    /// Where the resume checkbox starts: at the stored "At launch" choice, and checked when none is stored.
    public static func resumeCheckbox(_ settings: LaunchSettings) -> Bool {
        settings.opensChosen ? settings.opens == .lastProjects : true
    }

    /// The questions, in order. None in the self-test.
    public static func questions(_ input: QuitInput) -> [QuitQuestion] {
        if input.reason == .selfTest { return [] }
        // The update path: the sheet showed what stops, and its box answered about resuming.
        if input.update != nil || input.reason == .updateRelaunch {
            if let update = input.update, UpdateFlow.worse(update.current, than: update.consent) != nil { return [.updateSheet] }
            return input.unsavedFiles > 0 ? [.saveChanges(resumeCheckbox: nil)] : []
        }
        let asks = asksAboutResuming(input)
        let checkbox: Bool? = asks ? resumeCheckbox(input.settings) : nil
        let busy = input.busyTabs > 0
        var questions: [QuitQuestion] = []
        // When "Quitting stops…" follows, it carries the checkbox, so the question is asked once.
        if input.unsavedFiles > 0 { questions.append(.saveChanges(resumeCheckbox: busy ? nil : checkbox)) }
        if busy { questions.append(.busy(resumeCheckbox: checkbox)) }
        if questions.isEmpty, let checkbox { questions.append(.quit(resumeCheckbox: checkbox)) }
        return questions
    }

    /// The last question, once the questions before it are answered and the busy tabs read again (`busyTabs`): "Quitting
    /// stops…" whenever a tab is busy, with the box only when the policy put it there (`planned`, its `busy` question).
    /// When no tab is busy any more but that alert was to carry the box, the plain dialog asks instead, so the question
    /// is still asked once (AE22, when the agent finishes under the save-changes alert).
    public static func lastQuestion(planned: QuitQuestion?, busyTabs: Int) -> QuitQuestion? {
        var checkbox: Bool?
        if case .busy(let box) = planned { checkbox = box }
        if busyTabs > 0 { return .busy(resumeCheckbox: checkbox) }
        return checkbox.map { (box: Bool) -> QuitQuestion in .quit(resumeCheckbox: box) }
    }

    /// How a quit ends once its questions are answered: for the reason read before them, which the questions never
    /// change. An update quit whose consent no longer holds (another version was staged while it asked) is cancelled, and
    /// the sheet shows for the staged version: that consent covered the one before.
    public static func ending(reason: QuitReason, consentBefore: UpdateConsent?, consentNow: UpdateConsent?) -> QuitEnding {
        if let consentBefore, consentNow != consentBefore { return .updateSheet }
        return .goAhead(reason)
    }

    /// The settings to save once the quit goes ahead: checked gives "Resume where I left off", unchecked the Welcome
    /// window, and "Don’t ask again" turns Ask off. Unchecked keeps "Open a new terminal", which resumes nothing either,
    /// so a quit never undoes that choice.
    public static func settings(after answer: QuitAnswer, from settings: LaunchSettings) -> LaunchSettings {
        var updated = settings
        if answer.resume {
            updated.opens = .lastProjects
        } else if settings.opens != .newTerminal {
            updated.opens = .welcome
        }
        if case .quit(_, true) = answer { updated.askToReopenOnQuit = false }
        return updated
    }

    /// The quit consent (R30): only a press that lets the quit go ahead with the box checked. A quit that asked nothing
    /// has no answer, and gives none, whatever "At launch" says.
    public static func quitConsent(after answer: QuitAnswer?) -> Bool {
        answer?.resume == true
    }
}

/// One quit's questions as they are answered (KTD2, R29, R30): whether the quit goes ahead, the settings its answer saves,
/// and the quit consent, which only a go-ahead press with the box checked gives, and any cancel after it takes back.
public struct QuitAsking: Equatable, Sendable {
    /// A press on a question's dialog.
    public enum Reply: Equatable, Sendable {
        /// A button that lets the quit go on ("Quit", "Save", "Don’t Save"), with the box as it was (nil when the dialog
        /// had none) and "Don’t ask again".
        case goOn(resume: Bool?, dontAskAgain: Bool)
        /// "Cancel", ⎋ or ⌘., or a Save All that failed.
        case cancel
    }

    public private(set) var cancelled = false
    /// The answer about resuming, from the one question that carried the box.
    public private(set) var answer: QuitAnswer?

    public init() {}

    public mutating func reply(_ reply: Reply, to question: QuitQuestion) {
        switch reply {
        case .cancel:
            cancelled = true
            answer = nil
        case .goOn(let resume, let dontAskAgain):
            guard !cancelled, let resume else { return }
            switch question {
            case .quit: answer = .quit(resume: resume, dontAskAgain: dontAskAgain)
            case .saveChanges, .busy: answer = .checkbox(checked: resume)
            case .updateSheet: break
            }
        }
    }

    /// The quit consent, while the quit goes ahead.
    public var quitConsent: Bool { !cancelled && QuitPolicy.quitConsent(after: answer) }

    /// What to save once the quit goes ahead; nil when it was cancelled or nothing was answered about resuming.
    public func settings(from settings: LaunchSettings) -> LaunchSettings? {
        guard !cancelled, let answer else { return nil }
        return QuitPolicy.settings(after: answer, from: settings)
    }
}

/// A button pressed on a quit question's dialog.
public enum QuitPress: Equatable, Sendable {
    /// A button that lets the quit go on: "Quit" on the plain dialog or the busy alert, "Don’t Save" on the save-changes
    /// alert.
    case goOn
    /// "Save" (or "Save All") on the save-changes alert: the quit goes on once every file is saved.
    case save
    /// "Cancel", ⎋ or ⌘.
    case cancel
}

/// A quit question's dialog as the quit asks it (`QuitAsking.ask`): shown until the user presses a button, and only then
/// read for its boxes, which the user may change while it shows.
public protocol QuitDialog: AnyObject {
    /// Shows the dialog and waits for a press.
    func run() -> QuitPress
    /// The resume box as it is now; nil when the dialog has none.
    var resumeBox: Bool? { get }
    /// "Don’t ask again" as it is now; false when the dialog has none.
    var dontAskAgain: Bool { get }
}

extension QuitAsking {
    /// Asks `question` on `dialog`, and records the press with the boxes as the user left them, read once the press has
    /// come: a box read as the dialog opens records how it started, not the user's answer (R29, R30). A dialog's box
    /// counts only on a question that carries one. Returns the press: a Save still saves every file, and one that fails
    /// cancels the quit (`reply(.cancel, to:)`).
    @discardableResult
    public mutating func ask(_ question: QuitQuestion, on dialog: some QuitDialog) -> QuitPress {
        let press = dialog.run()
        switch press {
        case .cancel:
            reply(.cancel, to: question)
        case .goOn, .save:
            let resume: Bool? = question.resumeCheckbox == nil ? nil : dialog.resumeBox
            let dontAskAgain: Bool
            if case .quit = question { dontAskAgain = dialog.dontAskAgain } else { dontAskAgain = false }
            reply(.goOn(resume: resume, dontAskAgain: dontAskAgain), to: question)
        }
        return press
    }
}

/// A button of the plain quit dialog, "Quit Next Term?" (`QuitPolicy.promptTitle`).
public enum QuitPromptButton: CaseIterable, Sendable {
    case quit, cancel

    public var title: String {
        switch self {
        case .quit: return "Quit"
        case .cancel: return "Cancel"
        }
    }

    /// The press it is, as the quit asks (`QuitAsking.ask`).
    public var press: QuitPress {
        switch self {
        case .quit: return .goOn
        case .cancel: return .cancel
        }
    }

    /// What pressing it answers, with the box and "Don’t ask again" as they were. Cancel has none: the quit is cancelled.
    public func answer(resume: Bool, dontAskAgain: Bool) -> QuitAnswer? {
        switch self {
        case .quit: return .quit(resume: resume, dontAskAgain: dontAskAgain)
        case .cancel: return nil
        }
    }
}

extension QuitPolicy {
    /// The plain dialog's buttons in the order they are added: "Quit", then "Cancel". Neither is the default: the dialog
    /// clears Quit's Return, and NSAlert gives Cancel ⎋, which ⌘. presses too.
    public static let promptButtons: [QuitPromptButton] = [.quit, .cancel]

    /// The plain dialog's title. It has no informative text.
    public static let promptTitle = "Quit Next Term?"

    /// The checkbox on the plain dialog and on the save-changes and "Quitting stops…" alerts.
    public static let checkboxTitle = "Reopen windows and resume sessions when Next Term opens"

    /// The checkbox's tooltip, naming the open projects.
    public static func checkboxToolTip(_ projects: [String]) -> String {
        let what = projects.isEmpty ? "its windows" : projectList(projects)
        return "Checked: Next Term brings back \(what) with their tabs, splits and sessions next time it opens. Unchecked: it "
            + "shows the Welcome window. You can change this in Settings › General."
    }

    /// The open projects by their folders' names, each once, in order. Folders with one name get their parent
    /// folders too, as far up as it takes for them to read apart ("work/app", "home/app").
    public static func projectNames(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }
        let parts: [[String]] = unique.map { path in path.split(separator: "/").map(String.init) }
        var depths = [Int](repeating: 1, count: parts.count)
        func name(_ index: Int) -> String {
            let name = parts[index].suffix(depths[index]).joined(separator: "/")
            return name.isEmpty ? unique[index] : name // "/"
        }
        while true {
            let names = parts.indices.map(name)
            var counts: [String: Int] = [:]
            for name in names { counts[name, default: 0] += 1 }
            // Each name two folders share goes one folder further up, where there is one.
            let deeper = parts.indices.filter { counts[names[$0], default: 0] > 1 && depths[$0] < parts[$0].count }
            if deeper.isEmpty { return names }
            for index in deeper { depths[index] += 1 }
        }
    }

    /// "“app”", "“app” and “api”", "“app”, “api” and “web”", or "“a”, “b”, “c”, “d” and 2 more": four names at most,
    /// each in curly quotes, as the save-changes alert names a file, so a short one reads apart from the sentence.
    public static func projectList(_ paths: [String]) -> String {
        let names = projectNames(paths)
        let shown: [String] = names.prefix(4).map { (name: String) -> String in "“" + name + "”" }
        let rest = names.count - shown.count
        if rest > 0 { return shown.joined(separator: ", ") + " and \(rest) more" }
        guard let last = shown.last, shown.count > 1 else { return shown.first ?? "" }
        return shown.dropLast().joined(separator: ", ") + " and " + last
    }
}

import Foundation

/// Why Next Term is quitting. Only a user's quit asks about reopening.
public enum QuitReason: CaseIterable, Sendable {
    /// ⌘Q, the Dock's Quit, a scripted quit: anything the others are not.
    case user
    /// "Relaunch Now" (`Updater.relaunching`).
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

    private static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { (code: UInt32, byte: UInt8) -> UInt32 in code << 8 | UInt32(byte) }
    }
}

/// What a quit knows when it decides what to ask.
public struct QuitInput: Sendable {
    /// Editor files with unsaved changes.
    public var unsavedFiles: Int
    /// Tabs running something that quitting stops.
    public var busyTabs: Int
    /// Windows with a project, one per path.
    public var projectWindows: Int
    /// A sheet is attached to some window (the `nxtrm` install offer, an Open panel).
    public var sheetAttached: Bool
    public var reason: QuitReason
    public var settings: LaunchSettings

    public init(unsavedFiles: Int, busyTabs: Int, projectWindows: Int, sheetAttached: Bool, reason: QuitReason,
                settings: LaunchSettings) {
        self.unsavedFiles = unsavedFiles
        self.busyTabs = busyTabs
        self.projectWindows = projectWindows
        self.sheetAttached = sheetAttached
        self.reason = reason
        self.settings = settings
    }
}

/// One question a quit asks, in turn. `reopenCheckbox` is the starting state of "Reopen the open projects
/// next time" on that alert, nil for no checkbox.
public enum QuitQuestion: Equatable, Sendable {
    /// "Save changes to … before quitting?"
    case saveChanges(reopenCheckbox: Bool?)
    /// "Quit Next Term?", "Quitting stops …".
    case busy(reopenCheckbox: Bool?)
    /// "Reopen these projects next time?", alone. `returnKeyReopens`: "Reopen" is the default button,
    /// else "Don’t Reopen" is.
    case reopen(returnKeyReopens: Bool)
}

/// What was answered about reopening, at a quit that goes ahead. Cancel has no answer: nothing is written.
public enum QuitAnswer: Equatable, Sendable {
    /// The prompt's "Reopen", with "Don’t ask again" checked or not.
    case reopen(dontAskAgain: Bool)
    /// The prompt's "Don’t Reopen".
    case dontReopen(dontAskAgain: Bool)
    /// The alert's "Reopen the open projects next time", as it was when the quit went ahead.
    case checkbox(checked: Bool)
}

/// The one table that says what a quit asks. The save-changes and "Quitting stops…" alerts show whenever
/// they apply, as they always have. A quit asks about reopening in one of them at most: "Quitting
/// stops…" when it shows, else the save-changes alert, else the reopen prompt alone.
public enum QuitPolicy {
    /// Whether this quit asks about reopening: a user's quit, with Ask on, a project window open and no
    /// sheet up.
    public static func asksAboutReopening(_ input: QuitInput) -> Bool {
        guard input.reason == .user, input.settings.askToReopenOnQuit else { return false }
        return input.projectWindows > 0 && !input.sheetAttached
    }

    /// The questions, in order. None in the self-test.
    public static func questions(_ input: QuitInput) -> [QuitQuestion] {
        if input.reason == .selfTest { return [] }
        let asks = asksAboutReopening(input)
        // The checkbox and the prompt's default both start at the current setting.
        let reopens = input.settings.opens == .lastProjects
        let checkbox: Bool? = asks ? reopens : nil
        let busy = input.busyTabs > 0
        var questions: [QuitQuestion] = []
        // When "Quitting stops…" follows, it carries the checkbox, so the question is asked once.
        if input.unsavedFiles > 0 { questions.append(.saveChanges(reopenCheckbox: busy ? nil : checkbox)) }
        if busy { questions.append(.busy(reopenCheckbox: checkbox)) }
        if questions.isEmpty && asks { questions.append(.reopen(returnKeyReopens: reopens)) }
        return questions
    }

    /// The settings to save once the quit goes ahead.
    public static func settings(after answer: QuitAnswer, from settings: LaunchSettings) -> LaunchSettings {
        var updated = settings
        switch answer {
        case .reopen(let dontAskAgain):
            updated.opens = .lastProjects
            if dontAskAgain { updated.askToReopenOnQuit = false }
        case .dontReopen(let dontAskAgain):
            updated.opens = .welcome
            if dontAskAgain { updated.askToReopenOnQuit = false }
        case .checkbox(let checked):
            // The alerts have no "Don’t ask again": Ask stays as it is.
            updated.opens = checked ? .lastProjects : .welcome
        }
        return updated
    }
}

/// A button of the reopen prompt, "Reopen these projects next time?".
public enum QuitPromptButton: CaseIterable, Sendable {
    case reopen, cancel, dontReopen

    public var title: String {
        switch self {
        case .reopen: return "Reopen"
        case .cancel: return "Cancel"
        case .dontReopen: return "Don’t Reopen"
        }
    }

    /// Its key with ⌘ when it is the other choice, added last: NSAlert gives the default Return and "Cancel" ⎋.
    /// "Don’t Reopen" takes ⌘D, as "Don’t Save" does in the save-changes alert.
    public var commandKey: String? {
        switch self {
        case .reopen: return "r"
        case .cancel: return nil
        case .dontReopen: return "d"
        }
    }

    /// What pressing it answers, with "Don’t ask again" as it was. Cancel has none: the quit is cancelled.
    public func answer(dontAskAgain: Bool) -> QuitAnswer? {
        switch self {
        case .reopen: return .reopen(dontAskAgain: dontAskAgain)
        case .cancel: return nil
        case .dontReopen: return .dontReopen(dontAskAgain: dontAskAgain)
        }
    }
}

extension QuitPolicy {
    /// The prompt's buttons in the order they are added. The choice that matches the setting comes first, so it is
    /// the default, on top of the stacked buttons, and takes Return: Return never changes "When Next Term opens".
    /// "Cancel" comes next, as it does in the save-changes alert, and sits at the bottom; the other choice last,
    /// between them.
    public static func promptButtons(returnKeyReopens: Bool) -> [QuitPromptButton] {
        returnKeyReopens ? [.reopen, .cancel, .dontReopen] : [.dontReopen, .cancel, .reopen]
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

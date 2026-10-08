import Foundation

/// How a launch, or a reopen with no window, came about.
public enum LaunchKind: CaseIterable, Sendable {
    /// From the Dock, Finder, Spotlight or a login item, naming nothing.
    case normal
    /// It named a folder or file: `nxtrm` (`--open-request`), a drop on the Dock icon, `open -a` with a
    /// path, Finder's Open With. One that opened its window meets "a terminal window is open"; one that
    /// skipped every item goes on as a normal launch.
    case request
    /// A reopen while Next Term runs with no window visible: a click on the Dock icon, or Finder,
    /// Spotlight or `open -a` with no path.
    case dockReopen
    /// The relaunch after "Relaunch Now", told by a flag `Updater` leaves (`isUpdateRelaunch`). Until
    /// the update that keeps sessions, whose restore takes its place.
    case updateRelaunch
}

/// What a restore did before the launch asks the table. Nothing restores yet: the update that keeps
/// sessions fills it in from its own step.
public enum LaunchRestoreResult: CaseIterable, Sendable {
    case notRun
    case openedWindows
    case openedNoWindow
}

/// What the launch knows when it asks what to show. The folders are checked by `LaunchDecision.opening`'s
/// `exists`, so nothing here touches the disk.
public struct LaunchInput: Sendable {
    public var kind: LaunchKind
    public var restore: LaunchRestoreResult
    /// A `TerminalWindowController` is open. The Welcome, Settings, Import and Update windows don't count.
    public var terminalWindowOpen: Bool
    public var settings: LaunchSettings
    /// The project windows open at the last quit, in order.
    public var sessionProjects: [String]
    /// The recent projects, most recent first.
    public var recentProjects: [String]
    /// "Coming from another app?" may be offered: it never was (`importOffered`), and there is no recent
    /// project. Whether an app to import from is installed is the app's to find, as it is slow.
    public var mayOfferImport: Bool

    public init(kind: LaunchKind, restore: LaunchRestoreResult, terminalWindowOpen: Bool, settings: LaunchSettings,
                sessionProjects: [String], recentProjects: [String], mayOfferImport: Bool) {
        self.kind = kind
        self.restore = restore
        self.terminalWindowOpen = terminalWindowOpen
        self.settings = settings
        self.sessionProjects = sessionProjects
        self.recentProjects = recentProjects
        self.mayOfferImport = mayOfferImport
    }
}

/// What the launch shows.
public enum LaunchOpening: Equatable, Sendable {
    /// A terminal window is open already.
    case nothing
    /// These projects, each in its window, in order.
    case reopen([String])
    case welcome
    /// "Coming from another app?", then the Welcome window; just the Welcome window when no app to import
    /// from is found.
    case importThenWelcome
}

/// The one table that says what a launch, or a reopen with no window, shows. The app gathers the inputs
/// and acts on the answer.
public enum LaunchDecision {
    /// How long the flag "Relaunch Now" leaves marks the next launch as its relaunch.
    public static let relaunchFlagLifetime: TimeInterval = 15 * 60

    /// The rows in order; the first that matches wins. `exists` says whether a project's folder is still
    /// there.
    public static func opening(_ input: LaunchInput, exists: (String) -> Bool) -> LaunchOpening {
        if input.terminalWindowOpen { return .nothing }
        let reopens = input.settings.opens == .lastProjects
        if input.kind == .dockReopen {
            // The session's windows were closed by hand: Reopen brings back the most recent project.
            guard reopens, let recent = input.recentProjects.first(where: exists) else { return .welcome }
            return .reopen([recent])
        }
        let saved = existing(input.sessionProjects, exists: exists)
        let relaunch = input.kind == .updateRelaunch && input.restore == .notRun
        if (relaunch || reopens) && !saved.isEmpty { return .reopen(saved) }
        // Nothing to reopen: no fallback to the most recent project.
        return input.kind == .normal && input.mayOfferImport ? .importThenWelcome : .welcome
    }

    /// Whether a launch flagged at `flaggedAt` is the relaunch after "Relaunch Now": a flag from 0 to 15
    /// minutes old. One from the future is not.
    public static func isUpdateRelaunch(flaggedAt: Date?, now: Date) -> Bool {
        guard let flaggedAt else { return false }
        let age = now.timeIntervalSince(flaggedAt)
        return age >= 0 && age <= relaunchFlagLifetime
    }

    /// `paths` in order, without the missing folders and repeats.
    static func existing(_ paths: [String], exists: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        return paths.filter { (path: String) -> Bool in seen.insert(path).inserted && exists(path) }
    }
}

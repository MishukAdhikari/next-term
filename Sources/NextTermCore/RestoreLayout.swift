import Foundation

// What the restore decides as it builds the windows and applies each pane's action (KTD6, KTD10). The app builds every
// window in one main-thread turn and then waits for each shell; these are its rules, kept here so they are tested.

public enum RestoreLayout {
    /// A screen as the app names it (`NSScreen.localizedName`), with its frame in screen coordinates.
    public struct Screen: Equatable, Sendable {
        public var name: String
        public var frame: SessionSnapshot.Frame

        public init(name: String, frame: SessionSnapshot.Frame) {
            self.name = name
            self.frame = frame
        }
    }

    /// How much of a window must lie on its screen for its frame to be kept, in points each way.
    static let minimumOnScreen = (width: 100.0, height: 50.0)
    /// No window is wider or taller than this.
    static let largestSide = 20_000.0

    /// The saved frame, kept only on the screen it was on, while that screen is there and the frame still lies on it
    /// enough to reach (screens arranged differently since can leave it off every screen). Nil otherwise: the window
    /// opens where a new one would.
    public static func frame(_ saved: SessionSnapshot.Frame?, on screen: String?, screens: [Screen]) -> SessionSnapshot.Frame? {
        guard let saved, let screen, let found = screens.first(where: { (shown: Screen) -> Bool in shown.name == screen }) else { return nil }
        let values: [Double] = [saved.x, saved.y, saved.width, saved.height]
        guard values.allSatisfy(\.isFinite), saved.width > 0, saved.height > 0 else { return nil }
        guard saved.width <= largestSide, saved.height <= largestSide else { return nil }
        let area = found.frame
        let across = min(saved.x + saved.width, area.x + area.width) - max(saved.x, area.x)
        let down = min(saved.y + saved.height, area.y + area.height) - max(saved.y, area.y)
        guard across >= minimumOnScreen.width, down >= minimumOnScreen.height else { return nil }
        return saved
    }

    /// A split's divider positions as the restore builds it: those saved, when every one of its `children` was built;
    /// when the ones at `dropped` could not be (a tab on a host removed since), each one's room goes to its neighbour, as
    /// when the app closes a pane. Equal shares when the saved ones do not fit.
    public static func dividers(_ saved: [Double], children: Int, dropped: [Int]) -> [Double] {
        let left = SessionSnapshot.Split.removingDividers(saved, for: dropped, children: children)
        return SessionSnapshot.Split.repairedDividers(left, count: children - dropped.count)
    }

    /// A restored tab's note as it is fed into its terminal, before the shell starts: one line of printable text, dim,
    /// with a CR LF after it. Whatever the note names (a folder, a command, a host) cannot put anything else on screen.
    public static func noteLine(_ note: String) -> String {
        "\u{1B}[2m" + TerminalText.oneLine(note) + "\u{1B}[0m\r\n"
    }

    // MARK: actions

    /// How long a pane's shell has to be ready before its action turns into a note.
    public static let readyLimit: TimeInterval = 15

    /// Where a pane's pending action stands.
    public enum Readiness: Equatable, Sendable {
        /// The shell is not reading a line yet.
        case waiting
        /// It is: the action may type now.
        case ready
        /// The user typed in the tab first: the action is dropped.
        case cancelled
        /// Not ready within `readyLimit`, or the shell ended: a note in place of the action.
        case timedOut
    }

    /// Whether a pane's action may type into its shell now (KTD6). Ready means the shell's first prompt was reported
    /// (`integrated`, its first integration end mark) and its line editor switched bracketed paste on, so what is typed
    /// is inserted as text and never run. The user typing first, a key, a paste or a drop, cancels it.
    public static func readiness(integrated: Bool, bracketedPaste: Bool, userTyped: Bool, exited: Bool,
                                 waited: TimeInterval) -> Readiness {
        if userTyped { return .cancelled }
        if exited { return .timedOut }
        if integrated && bracketedPaste { return .ready }
        return waited >= readyLimit ? .timedOut : .waiting
    }

    /// The time between two automatic resumes.
    public static let resumeGap: TimeInterval = 0.4

    /// Automatic resumes, started one at a time, `resumeGap` apart: of those ready, a tab in view first, then the rest in
    /// the order given.
    public struct ResumeQueue: Sendable {
        private var lastStart: TimeInterval?

        public init() {}

        /// The pane whose resume starts now, of `ready`, or nil to wait. Its start is counted.
        public mutating func next(ready: [UUID], visible: Set<UUID>, now: TimeInterval) -> UUID? {
            if let lastStart, now - lastStart < RestoreLayout.resumeGap - 0.000_001 { return nil }
            guard let pane = ready.first(where: visible.contains) ?? ready.first else { return nil }
            lastStart = now
            return pane
        }
    }
}

/// The words of the alerts the restore shows: safe mode's, once two restores did not finish (R21), and the one that says
/// a third set the snapshot aside, and where.
public enum RestoreAlertText {
    public static let safeModeTitle = "Next Term restored your windows but ran nothing, because the last two restores did not finish."
    public static let safeModeText = "Each tab says what it held. Keep As Is leaves them as they are. Try Again puts back what each "
        + "tab held, and resumes the agents that may resume by themselves, once."
    public static let keepAsIs = "Keep As Is"
    public static let tryAgain = "Try Again"

    public static let setAsideTitle = "The previous session could not be restored"

    /// Where the snapshot went: `name` in `folder`, or, when it could not be moved, the folder it stays in.
    public static func setAsideText(folder: String, name: String?) -> String {
        guard let name else {
            return "Three tries to restore it did not finish, so Next Term opened without it. It could not be set aside, and stays in "
                + folder + "."
        }
        return "Three tries to restore it did not finish, so Next Term opened without it. It was set aside as "
            + (folder as NSString).appendingPathComponent(name) + "."
    }
}

/// Kept remote tabs (tmux, herdr) waiting to reattach after a launch (R12). A record that names a project reattaches in
/// that project's window once it is open, never in another project's; one with no project in the first terminal window.
/// Until then each is saved again with the open tabs (`saved(with:)`), so its session on the host is never forgotten.
public struct KeptRemoteQueue: Equatable, Sendable {
    /// In the order they were saved. Plain connections are never kept, so never wait.
    public private(set) var waiting: [RemoteTabRecord]

    public init(_ records: [RemoteTabRecord] = []) {
        waiting = records.filter { (record: RemoteTabRecord) -> Bool in record.keep != .off }
    }

    /// Leaves out the records a restore brought back in its windows: the same host, session and keep mode.
    public mutating func remove(restored: [RemoteTabRecord]) {
        waiting.removeAll { (record: RemoteTabRecord) -> Bool in
            restored.contains { (other: RemoteTabRecord) -> Bool in Self.same(record, other) }
        }
    }

    /// The records that reattach now, in order, each with its window: its project's, or nil for the first window. They no
    /// longer wait. `openProjects`: each open terminal window's project, nil for a window with none.
    public mutating func take(openProjects: [String?]) -> [(record: RemoteTabRecord, project: String?)] {
        guard !openProjects.isEmpty else { return [] }
        var taken: [(record: RemoteTabRecord, project: String?)] = []
        var left: [RemoteTabRecord] = []
        for record in waiting {
            if let project = record.project {
                if openProjects.contains(project) { taken.append((record, project)) } else { left.append(record) }
            } else {
                taken.append((record, nil))
            }
        }
        waiting = left
        return taken
    }

    /// What a save writes: the open tabs' records, then those still waiting.
    public func saved(with open: [RemoteTabRecord]) -> [RemoteTabRecord] {
        open + waiting
    }

    static func same(_ a: RemoteTabRecord, _ b: RemoteTabRecord) -> Bool {
        a.hostID == b.hostID && a.session == b.session && a.keep == b.keep
    }
}

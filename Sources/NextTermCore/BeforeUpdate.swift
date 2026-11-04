import Foundation

/// The windows open as an update's quit began, kept beside the session in their own file until the relaunch has shown them
/// all back (the owner's request, 2026-11-04): a window that did not come back can be reopened from it, by the user or by
/// an agent once the user approves. It goes 5 minutes after a relaunch that brought every window back, and any copy a
/// day old goes at the next launch.
public enum BeforeUpdate {
    /// In the sessions folder, beside the session's own file.
    public static let fileName = "before-update.json"
    /// After a relaunch that brought every window back.
    public static let keptFor: TimeInterval = 5 * 60
    /// Whatever happened since, no copy outlives a day.
    public static let staleAfter: TimeInterval = 24 * 60 * 60

    /// An open window as the check sees it: its project, and the folders of its tabs on this Mac.
    public struct Open: Equatable, Sendable {
        public let project: String?
        public let folders: [String]

        public init(project: String?, folders: [String]) {
            self.project = project
            self.folders = folders
        }
    }

    /// The saved windows that are not open now, as indices into `saved`. A project's window is back when a window of that
    /// project is open; a window with no project, when a window with no project has a tab in one of its tabs' folders.
    /// Each open window stands for one saved window at most.
    public static func missing(saved: [SessionSnapshot.Window], open: [Open]) -> [Int] {
        var unused: [Open] = open
        var missing: [Int] = []
        for (index, window) in saved.enumerated() {
            let folders: Set<String> = Set(window.groups.flatMap(\.root.panes).compactMap { $0.remote == nil ? $0.folder : nil })
            let match: Int? = unused.firstIndex { (candidate: Open) -> Bool in
                if let project = window.project { return candidate.project == project }
                return candidate.project == nil && !folders.isDisjoint(with: candidate.folders)
            }
            if let match { unused.remove(at: match) } else { missing.append(index) }
        }
        return missing
    }

    /// Whether a copy saved at `savedAt` is past keeping, `now`.
    public static func isStale(savedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(savedAt) > staleAfter || savedAt > now.addingTimeInterval(60)
    }
}

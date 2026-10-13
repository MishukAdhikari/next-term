import Foundation

/// When each project was last used, newest first, for the Welcome window's list: up to `limit` folders, however they
/// were opened (File › Open Project, an agent over MCP, a worktree window, a restore). Recent Projects stays as it is
/// beside it, for File › Open Recent and the Dock menu: its own 10, without worktrees.
///
/// A project's last use is the later of when it was opened and when its window was last in front. The defaults keep
/// the history as `[path, seconds since 1970]` pairs, newest first.
public struct ProjectHistory: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let path: String
        public let lastUsed: Date

        public init(path: String, lastUsed: Date) {
            self.path = path
            self.lastUsed = lastUsed
        }
    }

    public static let limit = 50
    /// Where the pairs are kept in the defaults.
    public static let key = "projectHistory"

    /// Newest first, one per path, at most `limit`.
    public private(set) var entries: [Entry] = []

    public init() {}

    /// The pairs as the defaults hold them. Anything else in the list is skipped: an item that is not a pair, a path
    /// that is not absolute, a time that is not a number of seconds from 1970 on. A path given twice keeps its later
    /// time, and equal times keep the stored order.
    public init(stored: [Any]) {
        for item in stored {
            guard let entry = Self.entry(item) else { continue }
            if let kept = lastUsed(entry.path), kept >= entry.lastUsed { continue }
            entries.removeAll { $0.path == entry.path }
            place(entry, aheadOfEqualTimes: false)
        }
        trim()
    }

    /// Written back as the defaults keep it, newest first.
    public var stored: [[Any]] {
        entries.map { entry in
            let seconds: Double = entry.lastUsed.timeIntervalSince1970
            return [entry.path, seconds]
        }
    }

    /// The paths, newest first.
    public var paths: [String] { entries.map(\.path) }

    public func lastUsed(_ path: String) -> Date? {
        entries.first { $0.path == path }?.lastUsed
    }

    /// A window took the project: it moves up to that time, ahead of any other used at the same moment.
    public mutating func record(opened path: String, at date: Date) {
        entries.removeAll { $0.path == path }
        place(Entry(path: path, lastUsed: date), aheadOfEqualTimes: true)
        trim()
    }

    /// The project's last window closed, last in front at `lastUsed`. The time only moves forward: a stored later one
    /// (it was opened again since) stays. A project the history no longer holds comes back at that time.
    public mutating func record(closed path: String, lastUsed: Date) {
        if let kept = self.lastUsed(path), kept >= lastUsed { return }
        entries.removeAll { $0.path == path }
        place(Entry(path: path, lastUsed: lastUsed), aheadOfEqualTimes: true)
        trim()
    }

    public mutating func forget(_ path: String) {
        entries.removeAll { $0.path == path }
    }

    public mutating func clear() {
        entries.removeAll()
    }

    /// The ones whose folder still exists. The history keeps the others, so a folder on a drive that is not mounted
    /// now is listed again when it is back.
    public func existing(fileManager: FileManager = .default) -> [Entry] {
        entries.filter { entry in
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: entry.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// Keeps the list newest first.
    private mutating func place(_ entry: Entry, aheadOfEqualTimes: Bool) {
        let index: Int? = entries.firstIndex { other in
            aheadOfEqualTimes ? other.lastUsed <= entry.lastUsed : other.lastUsed < entry.lastUsed
        }
        entries.insert(entry, at: index ?? entries.endIndex)
    }

    private mutating func trim() {
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    private static func entry(_ item: Any) -> Entry? {
        guard let pair = item as? [Any], pair.count == 2 else { return nil }
        guard let path = pair[0] as? String, path.hasPrefix("/") else { return nil }
        guard let seconds = seconds(pair[1]) else { return nil }
        return Entry(path: path, lastUsed: Date(timeIntervalSince1970: seconds))
    }

    /// A number of seconds from 1970 on, written as a real or a whole number. A Bool bridges to a number too, and is
    /// no time.
    private static func seconds(_ value: Any) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds: Double = number.doubleValue
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }
}

/// Where the history is kept: its own key in a defaults domain, beside Recent Projects' and never in it.
public struct ProjectHistoryStore {
    /// The suite a self-test keeps the history in, so the fixture windows it opens never push the user's own projects
    /// out of the 50, and the user's history is never written during a run.
    public static let scratchSuite = CommandLineLink.bundleIdentifier + ".self-test.project-history"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The scratch suite, emptied: made once as a self-test starts, so a run never lists an earlier run's fixtures. Nil
    /// for a name that is the app's own domain or the global one, which are never emptied, or one the defaults refuse.
    public static func scratch(suiteName: String = scratchSuite) -> ProjectHistoryStore? {
        let refused: Set<String> = [
            "",
            CommandLineLink.bundleIdentifier,
            Bundle.main.bundleIdentifier ?? "",
            UserDefaults.globalDomain,
        ]
        guard !refused.contains(suiteName), let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        defaults.removePersistentDomain(forName: suiteName)
        return ProjectHistoryStore(defaults: defaults)
    }

    /// What is saved; nothing, or a value of another kind, reads as an empty history.
    public func load() -> ProjectHistory {
        ProjectHistory(stored: defaults.array(forKey: ProjectHistory.key) ?? [])
    }

    public func save(_ history: ProjectHistory) {
        defaults.set(history.stored, forKey: ProjectHistory.key)
    }
}

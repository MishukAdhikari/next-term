import Foundation

/// When each project was last used, newest first, for the Welcome window's list: up to `limit` folders, however they
/// were opened (File › Open Project, an agent over MCP, a worktree window, a restore). Recent Projects stays as it is
/// beside it, for File › Open Recent and the Dock menu: its own 10, without worktrees.
///
/// A project's last use is the later of when it was opened and when its window was last in front. The defaults keep
/// the history as `[path, seconds since 1970]` pairs, newest first, each time to the millisecond.
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
    /// that is not absolute, a time that is not a number of seconds from 1970 to `Date.distantFuture`. A path given
    /// twice keeps its later time, and equal times keep the stored order.
    public init(stored: [Any]) {
        // The newest time of each path and where that pair stood, in one pass, then one sort: a key holding far more
        // than 50 pairs reads as fast as one holding 50.
        var newest: [String: Ranked] = [:]
        for (index, item) in stored.enumerated() {
            guard let entry = Self.entry(item) else { continue }
            if let kept = newest[entry.path], kept.entry.lastUsed >= entry.lastUsed { continue }
            newest[entry.path] = Ranked(entry: entry, index: index)
        }
        let ranked: [Ranked] = newest.values.sorted(by: Ranked.isAhead)
        entries = ranked.prefix(Self.limit).map(\.entry)
    }

    /// Written back as the defaults keep it, newest first.
    public var stored: [[Any]] {
        entries.map { entry in
            let seconds: Double = Self.milliseconds(entry.lastUsed.timeIntervalSince1970)
            return [entry.path, seconds]
        }
    }

    /// The paths, newest first.
    public var paths: [String] { entries.map(\.path) }

    public func lastUsed(_ path: String) -> Date? {
        entries.first { $0.path == path }?.lastUsed
    }

    /// A window took the project: its time becomes `date`, ahead of any other used at the same moment, which with the
    /// clock as it should be is the front. The list stays newest first by time, so with the clock gone back the open
    /// sets the earlier time and places it there; a time a wrong clock once set far ahead is mended by the next open.
    public mutating func record(opened path: String, at date: Date) {
        guard let time = Self.time(date.timeIntervalSince1970) else { return }
        entries.removeAll { $0.path == path }
        place(Entry(path: path, lastUsed: time))
        trim()
    }

    /// The project's last window closed, last in front at `lastUsed`. The time only moves forward: a stored later one
    /// (it was opened again since) stays. A project the history no longer holds comes back at that time. A window
    /// never in front (its time is still `Date.distantPast`) has no time to record.
    public mutating func record(closed path: String, lastUsed: Date) {
        guard let time = Self.time(lastUsed.timeIntervalSince1970) else { return }
        if let kept = self.lastUsed(path), kept >= time { return }
        entries.removeAll { $0.path == path }
        place(Entry(path: path, lastUsed: time))
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

    /// Keeps the list newest first, the entry ahead of any other used at the same moment.
    private mutating func place(_ entry: Entry) {
        let index: Int? = entries.firstIndex { other in other.lastUsed <= entry.lastUsed }
        entries.insert(entry, at: index ?? entries.endIndex)
    }

    private mutating func trim() {
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// A stored pair read, with where it stood in the list.
    private struct Ranked {
        let entry: Entry
        let index: Int

        /// Newest first; equal times in the stored order.
        static func isAhead(_ a: Ranked, _ b: Ranked) -> Bool {
            if a.entry.lastUsed != b.entry.lastUsed { return a.entry.lastUsed > b.entry.lastUsed }
            return a.index < b.index
        }
    }

    private static func entry(_ item: Any) -> Entry? {
        guard let pair = item as? [Any], pair.count == 2 else { return nil }
        guard let path = pair[0] as? String, path.hasPrefix("/") else { return nil }
        // Written as a real or a whole number. A Bool bridges to a number too, and is no time.
        guard let number = pair[1] as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        guard let lastUsed = time(number.doubleValue) else { return nil }
        return Entry(path: path, lastUsed: lastUsed)
    }

    /// The latest time kept: `Date.distantFuture`, in the year 4001.
    private static let latest: Double = Date.distantFuture.timeIntervalSince1970

    /// The time as the history keeps it and the defaults write it: whole milliseconds, so a history read back is the
    /// same history and a close at a time already kept changes nothing. Nil for seconds the defaults could not keep:
    /// before 1970 (a window never in front has `Date.distantPast`), after `latest`, or not a number.
    private static func time(_ seconds: Double) -> Date? {
        guard seconds.isFinite, seconds >= 0, seconds <= latest else { return nil }
        return Date(timeIntervalSince1970: milliseconds(seconds))
    }

    /// Seconds rounded to the millisecond. A kept time is written through it too, so the seconds written are the ones
    /// it was made from, and read back as the same `Date`.
    private static func milliseconds(_ seconds: Double) -> Double {
        (seconds * 1_000).rounded() / 1_000
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

    /// Whether `scratch(suiteName:)` may empty the suite: only a self-test's own, `<bundle id>.self-test.<name>` with
    /// a name of letters, digits, `-` and `_`. Every other is refused, so no wrong name ever empties the app's
    /// settings (its domain, or `NextTerm` for a debug build run outside a bundle), the global domain or another app's.
    public static func isScratch(_ suiteName: String) -> Bool {
        let prefix: String = CommandLineLink.bundleIdentifier + ".self-test."
        guard suiteName.hasPrefix(prefix) else { return false }
        let name: Substring = suiteName.dropFirst(prefix.count)
        return !name.isEmpty && name.allSatisfy(isNameCharacter)
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || character == "-" || character == "_"
    }

    /// The scratch suite, emptied: made once as a self-test starts, so a run never lists an earlier run's fixtures. Nil
    /// for a name `isScratch` refuses, which is never emptied, or one the defaults refuse.
    public static func scratch(suiteName: String = scratchSuite) -> ProjectHistoryStore? {
        guard isScratch(suiteName), let defaults = UserDefaults(suiteName: suiteName) else { return nil }
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

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

    /// Clear Menu: every project no window holds leaves the history. The ones in `open` keep their place and time, as
    /// the Welcome list shows them open, so one whose window was never in front is still listed after it closes.
    public mutating func clear(keeping open: [String]) {
        let kept = Set(open)
        entries.removeAll { !kept.contains($0.path) }
    }

    /// ⌘⌫ on a closed project in the Welcome window: it leaves the history and Recent Projects both. A project in
    /// `open`, which a window holds, stays in both. True when the history held it, so there is something to save.
    @discardableResult
    public mutating func forget(_ path: String, recent: inout RecentProjects, open: [String]) -> Bool {
        guard !open.contains(path) else { return false }
        recent.remove(path)
        guard lastUsed(path) != nil else { return false }
        forget(path)
        return true
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

// MARK: - What the windows hold

extension ProjectHistory {
    /// What changed in the open projects between two looks at the windows, for the history to record.
    public struct Changes: Equatable, Sendable {
        /// Projects a window took since the last look, by path.
        public let opened: [String]
        /// Projects no window holds any more, by path, each at when one of its windows was last in front:
        /// `Date.distantPast` for one never in front, which records no time.
        public let closed: [Entry]

        public init(opened: [String], closed: [Entry]) {
            self.opened = opened
            self.closed = closed
        }

        public var isEmpty: Bool { opened.isEmpty && closed.isEmpty }
    }

    /// Records what changed: each project opened at `now`, the time of the look, then each closed one at its last time
    /// in front, which only moves its time forward.
    public mutating func record(_ changes: Changes, at now: Date) {
        for path in changes.opened { record(opened: path, at: now) }
        for entry in changes.closed { record(closed: entry.path, lastUsed: entry.lastUsed) }
    }
}

/// The projects the windows hold, as last looked at, each with the newest time one of its windows was in front: what
/// tells the history that a project was opened, or closed and when it was last used.
///
/// Every change to what the windows hold is a look (`update`), however the window got its project. Between looks a
/// window coming to the front or leaving it is told as it happens (`sawInFront`), so a close records when its window was
/// last in front, not a time from an older look. A quit closes no window, so it closes every project itself (`quit`).
public struct OpenProjects: Equatable, Sendable {
    /// One window with a project, at a look.
    public struct Window: Equatable, Sendable {
        /// Which window: the same at every look while it is open.
        public let id: Int
        public let path: String
        /// When it was last in front; `Date.distantPast` for a window never in front.
        public let lastInFront: Date
        /// It has the keyboard now, as the user put it there: its project is in front at the look.
        public let isFront: Bool

        public init(id: Int, path: String, lastInFront: Date, isFront: Bool) {
            self.id = id
            self.path = path
            self.lastInFront = lastInFront
            self.isFront = isFront
        }
    }

    /// Each open project at the newest time one of its windows was in front.
    private var lastInFront: [String: Date] = [:]
    /// Times a window came to the front or left it since the last look, by its project.
    private var seen: [String: Date] = [:]
    /// The project each window held at the last look.
    private var held: [Int: String] = [:]
    /// How many windows hold each open project, at the last look: what the Welcome list shows beside it. A look can
    /// change it while the history stays as it was (one of a project's two windows closing, or a window never in front).
    public private(set) var windowCounts: [String: Int] = [:]
    /// After a quit nothing opens or closes: the windows are still there as the app ends.
    private var hasQuit = false

    public init() {}

    /// The open projects, by path.
    public var paths: [String] { lastInFront.keys.sorted() }

    /// A window on `path` came to the front, or left it, at `date`. A time older than one already kept changes nothing.
    public mutating func sawInFront(_ path: String, at date: Date) {
        guard !hasQuit else { return }
        seen[path] = Self.later(seen[path], date)
    }

    /// A look at the windows as they are at `now`. A project a window took since the last look is opened. One no
    /// window holds any more is closed at the newest time any of its windows was in front, the one that just closed
    /// included. A window with the keyboard has its project in front now; one that took another project while it had
    /// the keyboard (Open Recent in this window) had the old one in front until now.
    public mutating func update(_ windows: [Window], at now: Date) -> ProjectHistory.Changes {
        guard !hasQuit else { return ProjectHistory.Changes(opened: [], closed: []) }
        var times: [String: Date] = lastInFront
        for (path, date) in seen { times[path] = Self.later(times[path], date) }
        seen.removeAll()
        var open: [String: Date] = [:]
        for window in windows {
            var time: Date = window.lastInFront
            if window.isFront {
                time = max(time, now)
                if let before = held[window.id], before != window.path { times[before] = Self.later(times[before], now) }
            }
            open[window.path] = Self.later(open[window.path], time)
        }
        for (path, time) in open {
            if let kept = times[path] { open[path] = max(time, kept) }
        }
        let opened: [String] = open.keys.filter { lastInFront[$0] == nil }.sorted()
        let gone: [String] = lastInFront.keys.filter { open[$0] == nil }.sorted()
        let closed: [ProjectHistory.Entry] = gone.map { path in
            ProjectHistory.Entry(path: path, lastUsed: times[path] ?? .distantPast)
        }
        lastInFront = open
        held.removeAll()
        windowCounts.removeAll()
        for window in windows {
            held[window.id] = window.path
            windowCounts[window.path, default: 0] += 1
        }
        return ProjectHistory.Changes(opened: opened, closed: closed)
    }

    /// Next Term quits with these windows open: a last look at them, then every project closes, the one with the
    /// keyboard in front until now. Nothing after it opens or closes anything.
    public mutating func quit(_ windows: [Window], at now: Date) -> ProjectHistory.Changes {
        guard !hasQuit else { return ProjectHistory.Changes(opened: [], closed: []) }
        let look: ProjectHistory.Changes = update(windows, at: now)
        let last: ProjectHistory.Changes = update([], at: now)
        hasQuit = true
        var closed: [ProjectHistory.Entry] = look.closed + last.closed
        closed.sort { $0.path < $1.path }
        return ProjectHistory.Changes(opened: look.opened, closed: closed)
    }

    private static func later(_ kept: Date?, _ date: Date) -> Date {
        guard let kept else { return date }
        return max(kept, date)
    }
}

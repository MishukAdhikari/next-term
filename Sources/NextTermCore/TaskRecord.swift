import Foundation

/// What was posted where, kept on this Mac only for 30 days: one JSON line per task. It catches the same task sent to
/// the same place twice within a minute, lists today's tasks for a daily update, and lets a Reminders Undo find what it
/// made. Nothing that leaves the Mac ever reads it. Titles are stored masked; a line that can't be read is skipped.
public enum TaskRecord {
    /// How long a line is kept.
    public static let keep: TimeInterval = 30 * 86_400
    /// How close two posts must be to count as the same one sent twice.
    public static let duplicateWindow: TimeInterval = 60

    public struct Entry: Codable, Equatable, Sendable {
        public var at: Date
        public var kind: TaskDestination.Kind
        /// The destination within its kind: a list or shortcut id, `owner/repo`, a GitLab path, a Linear team, an
        /// Azure `org/project`, a tracker's name, or the todo folder's path.
        public var key: String
        /// The title, masked before it is stored.
        public var title: String
        /// `TodoFile.slug` of the title: what two posts are compared by.
        public var slug: String
        /// The project's key, or none for a task added outside a project.
        public var project: String?
        /// The item's id when the destination gives one (a reminder's identifier).
        public var itemID: String?
        /// Next Term opened a page or a Quick Add window and can't know the user finished there.
        public var waited: Bool

        public init(at: Date, kind: TaskDestination.Kind, key: String, title: String, slug: String,
                    project: String?, itemID: String? = nil, waited: Bool) {
            self.at = at
            self.kind = kind
            self.key = key
            self.title = title
            self.slug = slug
            self.project = project
            self.itemID = itemID
            self.waited = waited
        }
    }

    /// One entry as its line, ending in a newline. JSON escapes every newline inside, so a line is always one line.
    public static func line(_ entry: Entry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Every line that reads as an entry, oldest first. A cut-off line, an unknown kind or any other bad line is
    /// skipped and the rest kept.
    public static func parse(_ data: Data) -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let newline = UInt8(ascii: "\n")
        var entries: [Entry] = []
        for line in data.split(separator: newline, omittingEmptySubsequences: true) {
            if let entry = try? decoder.decode(Entry.self, from: Data(line)) { entries.append(entry) }
        }
        return entries
    }

    /// The entries made within the last 30 days.
    public static func pruned(_ entries: [Entry], now: Date) -> [Entry] {
        entries.filter { now.timeIntervalSince($0.at) <= keep }
    }

    /// The newest entry for the same slug sent to the same kind and key within a minute of `now`, if any.
    public static func recentDuplicate(_ entries: [Entry], kind: TaskDestination.Kind, key: String, slug: String,
                                       now: Date, within seconds: TimeInterval = duplicateWindow) -> Entry? {
        entries.last { entry in
            guard entry.kind == kind, entry.key == key, entry.slug == slug else { return false }
            let age = now.timeIntervalSince(entry.at)
            return age <= seconds && -age < seconds
        }
    }

    /// The entries made since local midnight, for `project` (every project when nil), oldest first.
    public static func today(_ entries: [Entry], project: String?, now: Date,
                             calendar: Calendar = .current) -> [Entry] {
        let midnight = calendar.startOfDay(for: now)
        return entries.filter { entry in
            guard entry.at >= midnight, entry.at <= now else { return false }
            return project == nil || entry.project == project
        }
    }
}

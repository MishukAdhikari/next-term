import Foundation

/// The projects list_projects gives in `projects`: open and used before together, the one used last first, so a
/// launcher (the Raycast extension) can list the folders the user had last.
public enum ProjectList {
    public struct Item: Equatable, Sendable {
        public let path: String
        public let open: Bool
        /// When it was last used: its window last in front, or the history's time; nil for one only in Recent Projects.
        public let lastUsed: Date?

        public init(path: String, open: Bool, lastUsed: Date?) {
            self.path = path
            self.open = open
            self.lastUsed = lastUsed
        }
    }

    /// - `open`: each open window's project and when it was last in front, in any order; a project in several windows
    ///   counts its newest.
    /// - `history`: ProjectHistory's entries. `recents`: Recent Projects' paths, newest first.
    /// Those with a time come newest first (equal times: open first, then the order given); then Recent Projects' with
    /// no recorded use, in their order.
    public static func build(open: [(path: String, lastKey: Date)], history: [ProjectHistory.Entry],
                             recents: [String]) -> [Item] {
        var openTimes: [String: Date] = [:]
        var openOrder: [String] = []
        for window in open {
            if let kept = openTimes[window.path] {
                openTimes[window.path] = max(kept, window.lastKey)
            } else {
                openTimes[window.path] = window.lastKey
                openOrder.append(window.path)
            }
        }
        var timed: [(item: Item, rank: Int)] = []
        for (rank, path) in openOrder.enumerated() {
            let used = max(openTimes[path] ?? .distantPast, history.first { $0.path == path }?.lastUsed ?? .distantPast)
            timed.append((Item(path: path, open: true, lastUsed: used), rank))
        }
        for (index, entry) in history.enumerated() where openTimes[entry.path] == nil {
            timed.append((Item(path: entry.path, open: false, lastUsed: entry.lastUsed), openOrder.count + index))
        }
        timed.sort { a, b in
            let first = a.item.lastUsed ?? .distantPast, second = b.item.lastUsed ?? .distantPast
            return first != second ? first > second : a.rank < b.rank
        }
        var listed = Set(timed.map(\.item.path))
        var items = timed.map(\.item)
        for path in recents where listed.insert(path).inserted {
            items.append(Item(path: path, open: false, lastUsed: nil))
        }
        return items
    }
}

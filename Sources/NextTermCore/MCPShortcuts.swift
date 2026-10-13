import Foundation

/// list_shortcuts and show_settings, for the next-term-setup skill: the user's keyboard shortcuts as Next Term has them
/// now, so an agent gives the user the right key and never one from memory (they differ with the shortcut set and with
/// the user's own changes), and the Settings tab to open for what agents don't change. The app reads each command's
/// live key (KeyboardShortcuts.chord(for:)); this shapes the answer and narrows it to a query.
public enum MCPShortcuts {
    public struct Command: Equatable, Sendable {
        public let title: String
        /// "File › New Tab", or the part a key works in ("Project Sidebar").
        public let place: String
        /// "⌥⌘T"; nil when it has none.
        public let key: String?
        /// Before the user's own change: the shortcut set's key, else the menu's.
        public let defaultKey: String?
        public let changed: Bool
        /// Where the same key does something else ("⌘D is Duplicate Line while the editor has the keyboard…").
        public let note: String?

        public init(title: String, place: String, key: String?, defaultKey: String?, changed: Bool, note: String? = nil) {
            self.title = title
            self.place = place
            self.key = key
            self.defaultKey = defaultKey
            self.changed = changed
            self.note = note
        }
    }

    /// The Settings tabs show_settings opens, by SettingsWindowController's identifiers.
    public static let settingsTabs = ["general", "editor", "terminal", "notifications", "keys", "import", "skills", "secrets"]

    /// list_shortcuts' answer: the set, and the commands `query` matches (all without one).
    public static func answer(set: String, commands: [Command], query: String?) -> [String: Any] {
        let query = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = query.isEmpty ? commands : commands.filter { matches($0, query) }
        return [
            "shortcut_set": set,
            "commands": shown.map(row),
            "count": shown.count,
            "change_keys": "Settings › Keyboard Shortcuts (show_settings with tab keys); another editor's set through list_import_sources",
        ]
    }

    /// A key ("⌥⌘T", any case), or words that are all in the command's title or place.
    static func matches(_ command: Command, _ query: String) -> Bool {
        if let key = command.key, key.caseInsensitiveCompare(query) == .orderedSame { return true }
        let haystack = (command.title + " " + command.place).lowercased()
        return query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { haystack.contains($0) }
    }

    static func row(_ command: Command) -> [String: Any] {
        var row: [String: Any] = ["command": command.title, "where": command.place, "key": command.key ?? NSNull()]
        if command.changed {
            row["changed"] = true
            row["default_key"] = command.defaultKey ?? NSNull()
        }
        if let note = command.note { row["note"] = note }
        return row
    }
}

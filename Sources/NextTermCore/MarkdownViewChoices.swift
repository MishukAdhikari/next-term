import Foundation

/// Each Markdown file's own choice from View › Markdown Live Preview (Live Preview or Source), by its path, for the newest
/// 500 files chosen; any other file follows Settings › Editor. A renamed file is a new path and follows Settings again.
public struct MarkdownViewChoices: Equatable, Sendable {
    public static let limit = 500
    public static let defaultsKey = "markdownViewChoices"

    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var preview: Bool
    }

    /// Newest first.
    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = Array(entries.prefix(Self.limit))
    }

    /// The file's own choice, if it has one.
    public func choice(for path: String) -> Bool? {
        entries.first { $0.path == path }?.preview
    }

    /// The file's choice, as the newest; the oldest beyond the limit are forgotten.
    public mutating func set(_ preview: Bool, for path: String) {
        entries.removeAll { $0.path == path }
        entries.insert(Entry(path: path, preview: preview), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(entries)) ?? Data()
    }

    /// What was saved; anything unreadable reads as no choices.
    public static func decode(_ data: Data?) -> MarkdownViewChoices {
        guard let data, let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return MarkdownViewChoices() }
        return MarkdownViewChoices(entries: entries)
    }
}

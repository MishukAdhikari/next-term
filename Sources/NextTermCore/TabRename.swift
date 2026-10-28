import Foundation

/// rename_tab's title (plan 010a U5a): what Rename Tab… sets, a tab's own label in Next Term. One line, cut at 100
/// characters as new_tab cuts its title; empty gives the tab its own title back. Never a tmux session's name, nor one of
/// herdr's agents' (herdr's names are shown as given).
public enum TabRename {
    public static let longest = 100

    /// The title to set (nil: the tab's own again), or why not.
    public static func title(_ raw: String) -> Result<String?, TabRenameRefusal> {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.unicodeScalars.contains(where: hidden) else { return .failure(.init(hiddenRefusal)) }
        return .success(trimmed.isEmpty ? nil : String(trimmed.prefix(longest)))
    }

    /// An agent's title for the tab it opens (new_tab, new_remote_tab): none when not given, null or empty; otherwise
    /// as rename_tab takes it.
    public static func given(_ value: Any?) -> Result<String?, TabRenameRefusal> {
        guard let value, !(value is NSNull) else { return .success(nil) }
        guard let raw = value as? String else { return .failure(.init("title must be a string.")) }
        return title(raw)
    }

    /// A character that doesn't show as itself, as the approval panels leave it out: a control, a format character
    /// (the direction marks among them), or a line or paragraph separator. A title is what approval windows name a tab
    /// by, so it may hold none.
    public static func hidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    static let hiddenRefusal = "The title must be one line of characters that show as themselves: no control or format characters (such as direction marks or zero-width joiners) and no line or paragraph separators."

    /// What an agent's id is told.
    public static let agentRefusal = "That is one of herdr's agents: herdr's names are shown as given, and Next Term does not rename agents. rename_tab with its tab's id (before the slash) renames the herdr tab."
}

public struct TabRenameRefusal: Error, Equatable, Sendable {
    public let text: String
    public init(_ text: String) { self.text = text }
}

import Foundation

/// rename_tab's title (plan 010a U5a): what Rename Tab… sets, a tab's own label in Next Term. One line, cut at 100
/// characters as new_tab cuts its title; empty gives the tab its own title back. Never a tmux session's name, nor one of
/// herdr's agents' (herdr's names are shown as given).
public enum TabRename {
    public static let longest = 100

    /// The title to set (nil: the tab's own again), or why not.
    public static func title(_ raw: String) -> Result<String?, TabRenameRefusal> {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.unicodeScalars.contains(where: ShellQuote.isControl) else {
            return .failure(.init("The title must be one line, with no control characters."))
        }
        return .success(trimmed.isEmpty ? nil : String(trimmed.prefix(longest)))
    }

    /// What an agent's id is told.
    public static let agentRefusal = "That is one of herdr's agents: herdr's names are shown as given, and Next Term does not rename agents. rename_tab with its tab's id (before the slash) renames the herdr tab."
}

public struct TabRenameRefusal: Error, Equatable, Sendable {
    public let text: String
    public init(_ text: String) { self.text = text }
}

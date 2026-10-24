import Foundation

/// What Wrap Up types into a ready agent tab: one fixed line asking for a handoff file with four sections. It holds no
/// task text, no project name and no stored key, only the file's path relative to the project, so no home folder or
/// user name is ever typed. Changing the words is a reviewed change: a test pins them byte for byte.
public enum HandoffRequest {
    /// Raised whenever the words below change.
    public static let version = 1

    /// The request for a handoff at `path` (relative to the project). One line with no line break, so a single Return
    /// sends it.
    public static func text(path: String) -> String {
        let sections = "## Done, ## Next (one \"- \" line per next step, each a task someone can start tomorrow), "
            + "## Open questions, ## How to resume."
        let ask = "Write a short handoff for this session to \(path) (create the folder if needed) "
            + "with exactly these sections: "
        let limits = " Write only that file; change nothing else and don't commit it."
        return ask + sections + limits
    }
}

/// A handoff file's name: `<day>-<tab>.md`, the tab's title as a todo file's name makes it, then `-2` to `-99`.
public enum HandoffName {
    /// Every name the handoff may take, in order. The title is masked before it becomes part of a name, and what the
    /// mask leaves is dropped, so no part of a stored key is in a file name. `session` when nothing else is left.
    public static func names(day: TaskDay, tab: String,
                             mask: (String) -> String = { SecretMask.current.mask($0) }) -> [String] {
        let masked = mask(tab).replacingOccurrences(of: "•", with: " ")
        let words = masked.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = words.isEmpty ? "session" : TodoFile.slug(words)
        let stem = day.description + "-" + slug
        let numbered: [String] = (2...TodoFile.lastNumber).map { "\(stem)-\($0).md" }
        return [stem + ".md"] + numbered
    }

    /// The first name `taken` says is free: taken means a file is there, or another tab in the same Wrap Up holds it.
    /// nil when all are taken.
    public static func pick(day: TaskDay, tab: String, taken: (String) -> Bool,
                            mask: (String) -> String = { SecretMask.current.mask($0) }) -> String? {
        names(day: day, tab: tab, mask: mask).first { !taken($0) }
    }
}

import Foundation

/// What Wrap Up types into a ready agent tab: one fixed line asking for a handoff file with four sections. It holds no
/// task text, no project name and no stored key, only the file's path relative to the project, so no home folder or
/// user name is ever typed. Changing the words is a reviewed change: a test pins them byte for byte.
public enum HandoffRequest {
    /// Raised whenever the words below change.
    public static let version = 1

    /// The request for a handoff at `path` (relative to the project). One line with no line break, so a single Return
    /// sends it; nil when `path` holds a line break or a control character, which would send it early or reach the
    /// agent's screen as a command.
    public static func text(path: String) -> String? {
        guard !hasControl(path) else { return nil }
        let sections = "## Done, ## Next (one \"- \" line per next step, each a task someone can start tomorrow), "
            + "## Open questions, ## How to resume."
        let ask = "Write a short handoff for this session to \(path) (create the folder if needed) "
            + "with exactly these sections: "
        let limits = " Write only that file; change nothing else and don't commit it."
        return ask + sections + limits
    }

    /// Whether `text` holds a line break (any kind) or a control or format character, escape and tab included.
    public static func hasControl(_ text: String) -> Bool {
        let refused = CharacterSet.controlCharacters.union(.newlines)
        return text.unicodeScalars.contains { refused.contains($0) }
    }
}

/// A handoff file's name: `<day>-<tab>.md`, the tab's title as a todo file's name makes it, then `-2` to `-99`.
public enum HandoffName {
    /// Every name the handoff may take, in order. The title is masked before it becomes part of a name, and what the
    /// mask leaves is dropped, so no part of a stored key is in a file name. A program can set its tab's title, so the
    /// name keeps only ASCII letters, digits and `-` (accents dropped first: `café` is `cafe`), and nothing of the
    /// title reaches the typed request as anything but a plain word. `session` when nothing else is left.
    public static func names(day: TaskDay, tab: String,
                             mask: (String) -> String = { SecretMask.current.mask($0) }) -> [String] {
        let folded = mask(tab).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = folded.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = words.isEmpty ? "" : plainSlug(TodoFile.slug(words))
        let slug = plain.isEmpty ? "session" : plain
        let stem = day.description + "-" + slug
        let numbered: [String] = (2...TodoFile.lastNumber).map { "\(stem)-\($0).md" }
        return [stem + ".md"] + numbered
    }

    /// `slug` with every character but an ASCII letter or digit made `-`, each run of `-` one, none at either end.
    static func plainSlug(_ slug: String) -> String {
        var kept = ""
        for scalar in slug.unicodeScalars {
            let plain = scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar))
            if plain {
                kept.unicodeScalars.append(scalar)
            } else if !kept.isEmpty, kept.last != "-" {
                kept.append("-")
            }
        }
        while kept.last == "-" { kept.removeLast() }
        return kept
    }

    /// The first name `taken` says is free: taken means a file is there, or another tab in the same Wrap Up holds it.
    /// nil when all are taken.
    public static func pick(day: TaskDay, tab: String, taken: (String) -> Bool,
                            mask: (String) -> String = { SecretMask.current.mask($0) }) -> String? {
        names(day: day, tab: tab, mask: mask).first { !taken($0) }
    }
}

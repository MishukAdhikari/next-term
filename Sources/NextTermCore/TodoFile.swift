import Foundation

/// A todo file: one task as one Markdown file in the todo folder, in the format docs/todo-files.md sets out, so an agent
/// in the project can read tomorrow's tasks with its own file tools.
/// - **Name:** `<created yyyy-mm-dd>-<slug>.md`, `-2`, `-3`… when that is taken; it never changes after.
/// - **Text:** UTF-8, LF, a final newline. Flat front matter (`created`, `scheduled`, `project` and `path` outside the
///   project, `branch`, `tab`, `agent`, `resume`, `added_by`, in that order, empty ones left out), then the task's
///   `- [ ]` line, its steps' boxes nested under it, and the notes after a blank line.
/// - **Values:** dates bare, times ISO 8601 with their offset, an agent's kind bare; every other value double-quoted.
public enum TodoFile {
    /// What a name never holds, besides control characters: what a path, a shell or another file system reads as more.
    static let dropped: Set<Character> = ["/", ":", "\\", "*", "?", "\"", "<", ">", "|"]
    /// The longest slug, in characters: cut at a word.
    public static let slugLength = 50
    /// And in UTF-8 bytes, so a name in any script stays well inside the 255 bytes a file name can have.
    static let slugBytes = 200
    /// The highest number a taken name gets before adding is refused.
    public static let lastNumber = 99

    /// The title as a file name's part: lower case, letters of any script kept, `/ : \ * ? " < > |` and control
    /// characters dropped, each run of spaces one `-`, cut at a word to `slugLength` characters. `task` when nothing is
    /// left.
    public static func slug(_ title: String) -> String {
        var words: [String] = []
        var word = ""
        for character in title.lowercased().precomposedStringWithCanonicalMapping {
            if character.isWhitespace {
                if !word.isEmpty { words.append(word) }
                word = ""
                continue
            }
            let control = character.unicodeScalars.contains { $0.properties.generalCategory == .control }
            if dropped.contains(character) || control { continue }
            word.append(character)
        }
        if !word.isEmpty { words.append(word) }
        func fits(_ text: String) -> Bool { text.count <= slugLength && text.utf8.count <= slugBytes }
        var slug = ""
        for word in words {
            let longer = slug.isEmpty ? word : slug + "-" + word
            guard fits(longer) else { break }
            slug = longer
        }
        // One word longer than the whole: as much of it as fits.
        if slug.isEmpty, let first = words.first {
            for character in first {
                guard fits(slug + String(character)) else { break }
                slug.append(character)
            }
        }
        return slug.isEmpty ? "task" : slug
    }

    /// The file's name for a task added at `created` (its day in `timeZone`): `2026-10-15-finish-the-login-fix.md`, or
    /// with `-2` up to `-99` while `taken` says a name is in use. nil when all of them are.
    public static func fileName(created: Date, title: String, timeZone: TimeZone, taken: (String) -> Bool) -> String? {
        names(created: created, title: title, timeZone: timeZone).first { !taken($0) }
    }

    /// Every name the file may take, in order: `<day>-<slug>.md`, then `-2` to `-99`.
    public static func names(created: Date, title: String, timeZone: TimeZone) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let stem = TaskDay(created, calendar: calendar).description + "-" + slug(title)
        return [stem + ".md"] + (2...lastNumber).map { "\(stem)-\($0).md" }
    }

    /// A value in double quotes, as YAML reads it: `\\`, `\"`, and `\uXXXX` for control characters and line separators.
    public static func quote(_ value: String) -> String {
        var quoted = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": quoted += "\\\\"
            case "\"": quoted += "\\\""
            default:
                let category = scalar.properties.generalCategory
                if category == .control || category == .lineSeparator || category == .paragraphSeparator || scalar.value == 0xFEFF {
                    quoted += String(format: "\\u%04X", scalar.value)
                } else {
                    quoted.unicodeScalars.append(scalar)
                }
            }
        }
        return quoted + "\""
    }

    /// `2026-10-15T18:42:07+06:00`: the time in `timeZone`, with its offset (never `Z`).
    public static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let minutes = abs(offset) / 60
        let time = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                          parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return time + (offset < 0 ? "-" : "+") + String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// The file's text for `draft`, added at `created` in `timeZone`. `outsideProject`: the project's name and folder, for
    /// a todo folder outside it (one folder for every project), so the file says which project it is for.
    public static func render(_ draft: TaskDraft, created: Date, timeZone: TimeZone, outsideProject: (name: String, path: String)? = nil) -> String {
        var front: [(key: String, value: String)] = [("created", timestamp(created, timeZone: timeZone))]
        if case .day(let day) = draft.scheduled { front.append(("scheduled", day.description)) }
        if let outsideProject {
            front.append(("project", quote(outsideProject.name)))
            front.append(("path", quote(outsideProject.path)))
        }
        let context = draft.context ?? TaskContext()
        func add(_ key: String, _ value: String?, bare: Bool = false) {
            guard let value, !value.isEmpty else { return }
            front.append((key, bare ? value : quote(value)))
        }
        add("branch", context.branch)
        add("tab", context.tab)
        add("agent", context.agent?.rawValue, bare: true)
        add("resume", context.resume)
        add("added_by", context.addedBy, bare: context.addedBy == TaskContext.you)

        var text = "---\n" + front.map { $0.key + ": " + $0.value + "\n" }.joined() + "---\n"
        text += "- [ ] " + oneLine(draft.title) + "\n"
        for step in draft.steps {
            let indent = String(repeating: "  ", count: max(0, step.depth) + 1)
            text += indent + (step.done ? "- [x] " : "- [ ] ") + oneLine(step.text) + "\n"
        }
        var notes = draft.notes
        while notes.hasSuffix("\n") { notes.removeLast() }
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text += "\n" + notes + "\n" }
        return text
    }

    /// A title or a step on its one line.
    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

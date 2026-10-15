import Foundation

/// A task as Tasks › Add Task… and the MCP tool add_task make it, before it is written anywhere: a title, its steps,
/// notes, the day it is planned for and where it was added. It is the one input every destination turns into its own
/// form; the todo folder's is a Markdown file (TodoFile).
///
/// No model reads the prompt: fixed rules do (`drafts(prompt:mask:)`).
/// - The first plain line is the title, without a trailing `:`. A leading bullet or box is dropped from a title.
/// - Lines starting `-`, `*`, `+`, `1.`, `1)`, `[ ]` or `[x]` are steps, a `[x]` one done; an indented one is nested
///   under the step above it, and an indented plain line right after a step carries on its text.
/// - Every other line, and code fences whole, are the notes, word for word.
/// - A prompt that is only a list is one task per item, its nested items their steps.
/// Stored keys' values are masked before any rule sees the text, so nothing after holds them.
public struct TaskDraft: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public var text: String
        public var done: Bool
        /// 0 for a step right under the task, 1 for one under that step, and so on.
        public var depth: Int

        public init(text: String, done: Bool = false, depth: Int = 0) {
            self.text = text
            self.done = done
            self.depth = depth
        }
    }

    /// The day the task is planned for: never a deadline.
    public enum Scheduled: Equatable, Sendable {
        case day(TaskDay)
        case none
    }

    public var title: String
    public var steps: [Step]
    /// Markdown under the checklist, as written; no trailing line break.
    public var notes: String
    public var scheduled: Scheduled
    /// Where it was added (project, branch, tab, agent), when the user wants that said.
    public var context: TaskContext?
    /// A stored key's value was in the text and shows as •••.
    public var masked: Bool

    public init(title: String, steps: [Step], notes: String = "", scheduled: Scheduled = .none, context: TaskContext? = nil,
                masked: Bool = false) {
        self.title = title
        self.steps = steps
        self.notes = notes
        self.scheduled = scheduled
        self.context = context
        self.masked = masked
    }

    /// add_task's: `title`, whose lines after the first go to the start of the notes, and `notes`, read by the same rules
    /// as a prompt's lines after its title. nil when the title has no words.
    public init?(title: String, notes: String = "", mask: (String) -> String = { $0 }) {
        let maskedTitle = mask(title), maskedNotes = mask(notes)
        var lines = Self.lines(maskedTitle)
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let heading = Self.cleanTitle(lines[first])
        guard !heading.isEmpty else { return nil }
        lines.removeSubrange(...first)
        // The title's other lines, a blank line, then the notes.
        let rest = Self.lines(maskedNotes)
        if !lines.isEmpty, !rest.allSatisfy(\.isEmpty) { lines.append("") }
        let body = Self.body(lines + rest)
        self.init(title: heading, steps: body.steps, notes: body.notes, masked: maskedTitle != title || maskedNotes != notes)
    }

    /// The tasks a prompt makes: one, or one per item of a prompt that is only a list. None for a prompt with no words
    /// outside code fences.
    public static func drafts(prompt: String, mask: (String) -> String = { $0 }) -> [TaskDraft] {
        let text = mask(prompt)
        let masked = text != prompt
        let lines = Self.lines(text)
        let kinds = classify(lines)
        if let title = kinds.firstIndex(of: .plain) {
            var rest = lines
            rest.remove(at: title)
            let body = Self.body(rest)
            return [TaskDraft(title: cleanTitle(lines[title]), steps: body.steps, notes: body.notes, masked: masked)]
        }
        let items: [(index: Int, item: ListItem)] = kinds.enumerated().compactMap { index, kind in
            if case .item(let item) = kind { return (index, item) }
            return nil
        }
        guard let first = items.first else { return [] }
        // Code and a list: the first item is the title, the rest its steps and notes.
        if kinds.contains(where: { $0 == .fence }) {
            var rest = lines
            rest.remove(at: first.index)
            let body = Self.body(rest)
            return [TaskDraft(title: cleanTitle(first.item.text), steps: body.steps, notes: body.notes, masked: masked)]
        }
        // Only a list: each item at the top is a task, and what is nested under it its steps.
        var drafts: [TaskDraft] = []
        var stack: [Int] = []
        for (_, item) in items {
            while let last = stack.last, last >= item.indent { stack.removeLast() }
            let depth = stack.count
            stack.append(item.indent)
            if depth == 0 || drafts.isEmpty {
                let title = cleanTitle(item.text)
                if !title.isEmpty { drafts.append(TaskDraft(title: title, steps: [], masked: masked)) }
            } else if !item.text.isEmpty {
                drafts[drafts.count - 1].steps.append(Step(text: item.text, done: item.done, depth: depth - 1))
            }
        }
        return drafts
    }

    // MARK: the rules

    /// One line of a prompt: a list item, in a code fence (its fences included), blank, or plain.
    enum Kind: Equatable {
        case item(ListItem)
        case fence
        case blank
        case plain
    }

    struct ListItem: Equatable {
        /// Columns before the marker (a tab to the next multiple of 4).
        let indent: Int
        let text: String
        let done: Bool
    }

    /// The text's lines, with CRLF and a lone CR read as LF.
    static func lines(_ text: String) -> [String] {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return unified.components(separatedBy: "\n")
    }

    static func classify(_ lines: [String]) -> [Kind] {
        var fence: (marker: Character, count: Int)?
        return lines.map { line in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if let open = fence {
                let run = trimmed.prefix { $0 == open.marker }.count
                if run >= open.count, trimmed.dropFirst(run).allSatisfy(\.isWhitespace) { fence = nil }
                return .fence
            }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let run = trimmed.prefix { $0 == marker }.count
                if run >= 3 {
                    fence = (marker, run)
                    return .fence
                }
            }
            if trimmed.allSatisfy(\.isWhitespace) { return .blank }
            if let item = listItem(line) { return .item(item) }
            return .plain
        }
    }

    /// A list line: `-`, `*` or `+`, or up to 9 digits and `.` or `)`, then a space, with an optional box; or a box alone.
    static func listItem(_ line: String) -> ListItem? {
        var indent = 0
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" {
            indent = first == "\t" ? (indent / 4 + 1) * 4 : indent + 1
            rest = rest.dropFirst()
        }
        func afterSpace(_ text: Substring) -> Substring? {
            if text.isEmpty { return text }
            guard text.first == " " || text.first == "\t" else { return nil }
            return text.drop { $0 == " " || $0 == "\t" }
        }
        var marked = false
        if let first = rest.first, "-*+".contains(first), let after = afterSpace(rest.dropFirst()) {
            rest = after
            marked = true
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            let after = rest.dropFirst(digits.count)
            if (1...9).contains(digits.count), let mark = after.first, mark == "." || mark == ")", let text = afterSpace(after.dropFirst()) {
                rest = text
                marked = true
            }
        }
        var done = false
        if rest.count >= 3, rest.first == "[", let box = rest.dropFirst().first, " xX".contains(box), rest.dropFirst(2).first == "]",
           let text = afterSpace(rest.dropFirst(3)) {
            done = box != " "
            rest = text
            marked = true
        }
        guard marked else { return nil }
        return ListItem(indent: indent, text: rest.trimmingCharacters(in: .whitespaces), done: done)
    }

    /// A title as one line: no leading bullet or box, no trailing `:`.
    static func cleanTitle(_ line: String) -> String {
        var text = listItem(line)?.text ?? line.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(":") { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
        return text
    }

    /// The lines after a title: list lines are steps, nested by their indent; every other line, and code fences whole,
    /// the notes as written, without blank lines at either end.
    static func body(_ lines: [String]) -> (steps: [Step], notes: String) {
        var steps: [Step] = []
        var notes: [String] = []
        var stack: [Int] = []
        var blanks = 0
        var afterStep = false
        func note(_ line: String) {
            if !notes.isEmpty { notes += Array(repeating: "", count: blanks) }
            notes.append(line)
        }
        for (line, kind) in zip(lines, classify(lines)) {
            switch kind {
            case .blank:
                blanks += 1
                afterStep = false
                continue
            case .item(let item):
                while let last = stack.last, last >= item.indent { stack.removeLast() }
                let depth = stack.count
                stack.append(item.indent)
                if !item.text.isEmpty { steps.append(Step(text: item.text, done: item.done, depth: depth)) }
                afterStep = !item.text.isEmpty
            case .plain where afterStep && line.first.map { $0 == " " || $0 == "\t" } == true:
                // An indented line right under a step carries on its text.
                steps[steps.count - 1].text += " " + line.trimmingCharacters(in: .whitespaces)
            case .plain, .fence:
                note(line)
                afterStep = false
            }
            blanks = 0
        }
        return (steps, notes.joined(separator: "\n"))
    }
}

/// Where a task was added, as the user was when they added it: the branch, the tab and its agent, the command that
/// resumes that agent's session, and who added it. Read from the tab, never from an agent's arguments.
public struct TaskContext: Equatable, Sendable {
    /// `addedBy` for a task the user added themselves.
    public static let you = "you"

    public var branch: String?
    public var tab: String?
    public var agent: AgentKind?
    public var resume: String?
    /// `you`, or who asked: an agent in a tab (“Claude Code in tab “api””) or a connection.
    public var addedBy: String?

    public init(branch: String? = nil, tab: String? = nil, agent: AgentKind? = nil, resume: String? = nil, addedBy: String? = nil) {
        self.branch = branch
        self.tab = tab
        self.agent = agent
        self.resume = resume
        self.addedBy = addedBy
    }

    /// The same, with stored keys' values masked in each line of text.
    public func masked(by mask: (String) -> String) -> TaskContext {
        TaskContext(branch: branch.map(mask), tab: tab.map(mask), agent: agent, resume: resume.map(mask), addedBy: addedBy.map(mask))
    }
}

/// A day on the calendar, as the todo files write it: `2026-10-16`.
public struct TaskDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// `YYYY-MM-DD`, a day that is on the calendar (no 30 February).
    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let read = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard read.era == 1, read.year == year, read.month == month, read.day == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `calendar` (its time zone).
    public init(_ date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        year = parts.year ?? 1970
        month = parts.month ?? 1
        day = parts.day ?? 1
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// The day's start in `calendar`.
    public func start(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    public static func < (a: TaskDay, b: TaskDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
}

/// When a task is planned for, as add_task's `when` and the sheet's When take it.
public enum When {
    /// add_task's `when`: these words exactly, or a date.
    public static let pattern = "^(today|tomorrow|[0-9]{4}-[0-9]{2}-[0-9]{2})$"

    /// `today`, `tomorrow` or `YYYY-MM-DD` as a day, in `calendar`'s time zone at `now`; nil for anything else.
    public static func parse(_ text: String, now: Date, calendar: Calendar) -> TaskDay? {
        switch text {
        case "today": return TaskDay(now, calendar: calendar)
        case "tomorrow": return days(1, after: now, calendar: calendar)
        default: return text.utf8.count == 10 ? TaskDay(text) : nil
        }
    }

    /// The day `count` days after `now`'s, by the calendar (a day across a clock change is still one day).
    public static func days(_ count: Int, after now: Date, calendar: Calendar) -> TaskDay {
        let start = calendar.startOfDay(for: now)
        let later = calendar.date(byAdding: .day, value: count, to: start) ?? start.addingTimeInterval(Double(count) * 86_400)
        return TaskDay(later, calendar: calendar)
    }

    /// Next Week: the coming first day of the week (the calendar's, Sunday or Monday), never today.
    public static func nextWeek(after now: Date, calendar: Calendar) -> TaskDay {
        let start = calendar.startOfDay(for: now)
        let first = DateComponents(weekday: calendar.firstWeekday)
        let next = calendar.nextDate(after: start, matching: first, matchingPolicy: .nextTime) ?? start.addingTimeInterval(7 * 86_400)
        return TaskDay(next, calendar: calendar)
    }
}

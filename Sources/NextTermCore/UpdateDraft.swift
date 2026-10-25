import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Post Update's draft: what was done, what is next and what is blocked, from today's handoffs, today's posted tasks
/// and today's commits in the project. Building it is pure; every line is masked as it goes in, and the text is the
/// user's to change before anything leaves. Next Term sends it nowhere itself.
public struct UpdateDraft: Equatable, Sendable {
    /// A handoff read today: its file relative to the project, and what it held, masked already.
    public struct HandoffSource: Equatable, Sendable {
        public var file: String
        public var handoff: Handoff

        public init(file: String, handoff: Handoff) {
            self.file = file
            self.handoff = handoff
        }
    }

    public var project: String
    public var done: [String]
    public var next: [String]
    public var blocked: [String]
    /// Handoffs that held none of the known sections, by file, and added nothing.
    public var unshaped: [String]
    /// What was found, counted, as the line under the draft says it.
    public var handoffs: Int
    public var tasks: Int
    public var commits: Int
    /// Why some source added nothing: a handoff with no sections, or no commit lines.
    public var notes: [String]

    /// The longest text typed into an agent's prompt; a longer one is copied instead.
    public static let longestTyped = 4_000

    /// The draft from the three sources. Inside each section: handoff items first, then posted tasks, then commits. A
    /// handoff's Next item posted as a task today is listed once, as the task. Every line is passed through `mask`.
    public static func build(project: String, handoffs: [HandoffSource], tasks: [TaskRecord.Entry],
                             commits: TodayCommits.Outcome, mask: (String) -> String) -> UpdateDraft {
        var done = Lines(), next = Lines(), blocked = Lines()
        let posted: [(text: String, slug: String)] = tasks.map { entry in
            let title = mask(entry.title)
            return (title + " (" + mask(place(entry)) + ")", TodoFile.slug(title))
        }
        let postedSlugs: Set<String> = Set(posted.map(\.slug))
        var used = 0
        var unshaped: [String] = []
        for source in handoffs {
            let handoff = source.handoff
            guard handoff.shape != .none else {
                unshaped.append(source.file)
                continue
            }
            used += 1
            for item in handoff.items(in: .done) { done.add(mask(item.text)) }
            for item in handoff.next {
                let text = mask(item.text)
                if item.done { done.add(text); continue }
                guard !postedSlugs.contains(TodoFile.slug(text)) else { continue }
                next.add(text)
            }
            for item in handoff.items(in: .openQuestions) { blocked.add(mask(item.text)) }
        }
        for task in posted { next.add(task.text) }
        let subjects: [String] = commits.subjects.map(mask)
        for subject in subjects { done.add(subject) }
        var notes: [String] = []
        if !unshaped.isEmpty {
            let count = unshaped.count == 1 ? "1 handoff" : "\(unshaped.count) handoffs"
            notes.append(count + " had no sections: " + unshaped.map(mask).joined(separator: ", "))
        }
        if let reason = commits.reason { notes.append(reason) }
        let listed: Int = subjects.filter { moreCount($0) == nil }.count
        let counted: Int = listed + (subjects.last.flatMap(moreCount) ?? 0)
        return UpdateDraft(project: mask(project), done: done.items, next: next.items, blocked: blocked.items,
                           unshaped: unshaped, handoffs: used, tasks: tasks.count, commits: counted, notes: notes)
    }

    /// Lines in order, an exact repeat left out.
    struct Lines {
        var items: [String] = []
        var seen: Set<String> = []

        mutating func add(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            items.append(trimmed)
        }
    }

    /// The N of TodayCommits' "and N more" line, which stands for N commits not listed; nil for any other line.
    static func moreCount(_ text: String) -> Int? {
        guard text.hasPrefix("and "), text.hasSuffix(" more") else { return nil }
        return Int(text.dropFirst(4).dropLast(5))
    }

    /// Where a posted task went, short: the repository or project for a tracker, the app's name otherwise, and
    /// "page opened" or "opened" when Next Term opened a page or a window and can't know the task was made.
    static func place(_ entry: TaskRecord.Entry) -> String {
        let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        switch entry.kind {
        case .github, .gitlab, .azureBoards, .throughAgent:
            name = key.isEmpty ? DestinationChoices.kindName(entry.kind) : key
        case .linear:
            name = key.isEmpty ? "Linear" : "Linear " + key
        case .shortcut:
            name = "Shortcuts"
        default:
            name = DestinationChoices.kindName(entry.kind)
        }
        guard entry.waited else { return name }
        let page: Bool = [.github, .gitlab, .linear, .trello, .azureBoards].contains(entry.kind)
        return name + (page ? ", page opened" : ", opened")
    }
}

// MARK: the text

extension UpdateDraft {
    /// "From 2 handoffs, 3 tasks and 7 commits today.", naming only what was found.
    public var sourceLine: String {
        func count(_ number: Int, _ one: String) -> String? {
            number == 0 ? nil : number == 1 ? "1 " + one : "\(number) \(one)s"
        }
        let parts: [String] = [count(handoffs, "handoff"), count(tasks, "task"), count(commits, "commit")]
            .compactMap { $0 }
        guard let last = parts.last else { return "Nothing found for today." }
        let head = parts.dropLast().joined(separator: ", ")
        let listed = head.isEmpty ? last : head + " and " + last
        return "From " + listed + " today."
    }

    /// The draft as Markdown: a heading with the project and the day in the user's words, then Done, Next and Blocked,
    /// each item a "- " line and an empty section "- None".
    public func text(date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        let day = formatter.string(from: date)
        var lines: [String] = ["## Update: \(project), \(day)"]
        let sections: [(String, [String])] = [("Done", done), ("Next", next), ("Blocked", blocked)]
        for (title, items) in sections {
            lines.append("")
            lines.append("### " + title)
            let shown: [String] = items.isEmpty ? ["None"] : items
            lines += shown.map { "- " + $0 }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The text is too long to type into a prompt.
    public static func isTooLong(_ text: String) -> Bool { text.count > longestTyped }

    /// What is typed into the agent's tab: where to post, then the update as written. nil when either is empty, the
    /// place holds a line break, or the update is too long to type. The text is masked by the caller already.
    public static func request(text: String, to place: String) -> String? {
        let place = place.trimmingCharacters(in: .whitespaces)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !place.isEmpty, !HandoffRequest.hasControl(place), !body.isEmpty, !isTooLong(body) else { return nil }
        return "Post this update to \(place), exactly as written:\n\n" + body
    }
}

/// Save to Project: the update as a new file in `docs/updates` of the window's checkout, where the user would commit
/// it. A file is never written over, and the folder must be a plain folder of the project all the way down: a link
/// anywhere on the way is refused, even one that points back inside. Next Term never stages or commits it.
public enum UpdateFile {
    /// The folder, relative to the checkout. Fixed: nothing reads it back.
    public static let folder = "docs/updates"
    /// The last number a day's name takes.
    public static let lastNumber = 99

    public enum Failure: Error, Equatable, Sendable {
        case notPlainFolder
        case namesUsedUp
        case projectMissing
        case notWritten

        public var message: String {
            switch self {
            case .notPlainFolder: return "Choose Copy instead: docs/updates is not a plain folder in this project."
            case .namesUsedUp: return "Today’s update names are used up."
            case .projectMissing: return "The project folder is not there any more."
            case .notWritten: return "The update couldn’t be saved. Choose Copy instead."
            }
        }
    }

    /// `2026-10-18.md`, then `2026-10-18-2.md` to `-99`.
    public static func names(day: TaskDay) -> [String] {
        let first: [String] = [day.description + ".md"]
        let more: [String] = (2...lastNumber).map { "\(day.description)-\($0).md" }
        return first + more
    }

    /// Writes `text` (masked by the caller) under the first free name for `day` and returns its path relative to
    /// `checkout`. The folder is made when it is not there and checked again after, since a link could appear between.
    public static func save(_ text: String, in checkout: String, day: TaskDay) throws -> String {
        let root = canonicalPath(checkout)
        guard FileManager.default.fileExists(atPath: root) else { throw Failure.projectMissing }
        guard TaskSettings.handoffFolder(folder, in: root) == folder else { throw Failure.notPlainFolder }
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(folder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw Failure.notPlainFolder
        }
        guard TaskSettings.handoffFolder(folder, in: root) == folder else { throw Failure.notPlainFolder }
        let data = Data(text.utf8)
        for name in names(day: day) {
            let file = url.appendingPathComponent(name)
            var info = stat()
            if lstat(file.path, &info) == 0 { continue }
            do {
                try TextFile.write(data, to: file, expecting: .noFile)
                return folder + "/" + name
            } catch SafeWrite.Failure.changed {
                continue // One turned up there meanwhile.
            } catch {
                throw Failure.notWritten
            }
        }
        throw Failure.namesUsedUp
    }
}

import Foundation

/// What one destination receives for one task: a reminder's fields, a link that opens an app or a page filled in, the
/// text a shortcut reads, or the request typed to the user's agent. Pure: nothing here opens, posts or saves anything.
/// - Every link comes from a fixed template per destination. Each value is percent-encoded byte by byte (only letters,
///   digits, `-`, `.`, `_` and `~` stay), so a title can't add a parameter, change the host or end the link early.
/// - Personal destinations (Reminders, Things, a shortcut, Todoist, OmniFocus) get the steps, the notes and where the
///   task was added. Team pages and the agent request get the steps, the notes and the branch only: a tab's title or a
///   resume command means nothing to a teammate and says what is on this Mac.
/// - A destination that takes less is cut at a line end, and the text then ends with a line saying so, inside the limit.
///   When not even the first line fits, that line is cut inside, ending in "…", so the user's text is never all gone.
/// - Every piece of text loses its control characters (but line breaks and tabs) and direction marks, then goes
///   through `mask`, so a stored key's value never leaves, even from a draft made without masking, and what is shown
///   is what is typed or sent.
/// - A destination whose details can't be used (`TaskDestination.problem`) renders nothing.
/// The todo folder is not here: its file is `TodoFile.render`.
public struct TaskPayload: Equatable, Sendable {
    public enum Form: Equatable, Sendable {
        /// A reminder: `due` holds year, month and day only, which makes it all-day; nil for no day.
        case reminder(title: String, notes: String, due: DateComponents?)
        case link(URL)
        /// What a shortcut reads as its input.
        case stdin(String)
        /// What is typed into the user's agent tab, never followed by Return.
        case agentRequest(String)
    }

    public let form: Form
    /// The text was cut to fit the destination.
    public let cut: Bool
    /// What is sent, readable, for the sheet's "What's sent" and the approval window: a link's place and each
    /// parameter's name and value as the app or page receives it; a reminder's fields; the shortcut's input or the
    /// agent request word for word. The sheet's one line under Destination is built where the destination's details
    /// and the day's words are known, not here.
    public let sent: String

    /// The most bytes a page's link may have: GitHub opened one of about 6,500 and failed at 7,500.
    public static let linkBytes = 6_000
    /// Things takes up to 10,000 characters of notes, 4,000 in any other value (the title, the list, the whole
    /// checklist) and 100 checklist items.
    public static let thingsNotes = 10_000
    public static let thingsValue = 4_000
    public static let thingsChecklist = 100
    /// Azure Boards: some browsers take at most 2,000 characters in a field.
    public static let azureField = 2_000
    /// Trello's card name.
    public static let trelloName = 300

    /// The payload for `draft` at `destination`, with `project` (the project's name) in the context line; nil for the
    /// todo folder. `today` is the day the task is added, for Things' `today` and `tomorrow`. The context lines appear
    /// only when the draft's context has a branch, tab, agent or resume command, which it has only when the user wants
    /// where they are added.
    public static func render(_ draft: TaskDraft, to destination: TaskDestination, project: String?, today: TaskDay,
                              mask: (String) -> String = { SecretMask.current.mask($0) }) -> TaskPayload? {
        guard destination.problem == nil else { return nil }
        let task = Parts(draft, project: project, mask: mask)
        switch destination {
        case .todoFolder: return nil
        case .reminders(_, let listName): return reminder(task, list: mask(listName))
        case .things(let list): return things(task, list: list.map(mask), today: today)
        case .shortcut: return shortcut(task)
        case .todoist:
            let base = "todoist://openquickadd"
            return page(base, place: "Todoist Quick Add", name: "Todoist", title: "content", body: "description",
                        task.title, task.personal)
        case .omnifocus:
            let base = "omnifocus:///add"
            return page(base, place: "OmniFocus Quick Add", name: "OmniFocus", title: "name", body: "note",
                        task.title, task.personal)
        case .github(let owner, let repo):
            let base = "https://github.com/" + segments([owner, repo]) + "/issues/new"
            return page(base, name: "GitHub", title: "title", body: "body", task.title, task.team)
        case .gitlab(let path):
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let base = "https://gitlab.com/" + segments(parts) + "/-/work_items/new"
            return page(base, name: "GitLab", title: "issue[title]", body: "issue[description]", task.title,
                        noQuickActions(task.team))
        case .linear(let team):
            let base = team.map { "https://linear.app/team/" + segments([$0]) + "/new" } ?? "https://linear.new"
            return page(base, name: "Linear", title: "title", body: "description", task.title, task.team, plusSpaces: true)
        case .trello: return trello(task)
        case .azureBoards(let org, let project, let type):
            let base = "https://dev.azure.com/" + segments([org, project, "_workItems", "create", type])
            return page(base, name: "Azure Boards", title: "[System.Title]", body: "[System.Description]",
                        task.title, task.team, fieldLimit: azureField)
        case .throughAgent(let tracker):
            let name = mask(tracker)
            let ask = "Add this task to \(name) with your \(name) tools, exactly as written, then tell me its link."
            let text = join([ask, task.title, task.team])
            return TaskPayload(form: .agentRequest(text), cut: false, sent: text)
        }
    }
}

extension TaskPayload {
    /// The task's text, masked, in the pieces the destinations put together.
    struct Parts {
        let title: String
        /// Each step as a `- [ ]` line, nested ones indented two spaces a level.
        let stepLines: [String]
        /// Each step's text alone, in order, nesting flattened: Things' checklist.
        let stepTexts: [String]
        let notes: String
        /// "Project · Branch · Tab · Agent" and "Resume: …", when the context has them.
        let whereLines: [String]
        /// "Branch: …" when it is known.
        let branchLine: String?
        let day: TaskDay?

        init(_ draft: TaskDraft, project: String?, mask rawMask: (String) -> String) {
            // Cleaned before masking, so a control character inside a key can't split it past the mask.
            func mask(_ text: String) -> String { rawMask(TaskPayload.clean(text)) }
            title = TaskPayload.oneLine(mask(draft.title))
            stepTexts = draft.steps.map { TaskPayload.oneLine(mask($0.text)) }
            stepLines = zip(draft.steps, stepTexts).map { step, text in
                String(repeating: "  ", count: max(0, step.depth)) + (step.done ? "- [x] " : "- [ ] ") + text
            }
            var noteLines = mask(draft.notes).components(separatedBy: "\n")
            let blank = { (line: String) -> Bool in line.trimmingCharacters(in: .whitespaces).isEmpty }
            while let first = noteLines.first, blank(first) { noteLines.removeFirst() }
            while let last = noteLines.last, blank(last) { noteLines.removeLast() }
            notes = noteLines.joined(separator: "\n")
            let context = draft.context ?? TaskContext()
            func some(_ text: String?) -> String? {
                guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return TaskPayload.oneLine(mask(text))
            }
            let branch = some(context.branch), tab = some(context.tab), resume = some(context.resume)
            let agent = context.agent?.name
            var lines: [String] = []
            if branch != nil || tab != nil || agent != nil || resume != nil {
                let first: [String] = [some(project), branch, tab, agent].compactMap { $0 }
                lines.append(first.joined(separator: " · "))
                if let resume { lines.append("Resume: " + resume) }
            }
            whereLines = lines
            branchLine = branch.map { "Branch: " + $0 }
            if case .day(let day) = draft.scheduled { self.day = day } else { day = nil }
        }

        /// What Reminders, Things' notes, a shortcut, Todoist and OmniFocus get under the title.
        var personal: String {
            TaskPayload.join([stepLines.joined(separator: "\n"), notes, whereLines.joined(separator: "\n")])
        }

        /// What a team page and the agent request get under the title.
        var team: String {
            TaskPayload.join([stepLines.joined(separator: "\n"), notes, branchLine ?? ""])
        }
    }

    /// The parts that have text, a blank line between each.
    static func join(_ sections: [String]) -> String {
        sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// A title or a step on one line.
    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The line a text cut to a field's length ends with: `(Cut by Next Term: Things takes 10,000 characters.)`.
    static func cutNote(_ name: String, _ limit: Int) -> String {
        "(Cut by Next Term: \(name) takes \(grouped(limit)) characters.)"
    }

    /// The line a text cut to fit a link ends with. The limit is the whole link's bytes, not a count the user could
    /// check against the text, so no number is given.
    static func linkCutNote(_ name: String) -> String {
        "(Cut by Next Term to fit \(name)’s link length.)"
    }

    /// Control characters (but line breaks and tabs) and direction marks and overrides, removed: an agent tab drops
    /// control characters as it types, and a direction override would show the text in another order than it goes.
    static func clean(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var kept = String.UnicodeScalarView()
        for scalar in unified.unicodeScalars where scalar == "\n" || scalar == "\t" || !hidden(scalar) {
            kept.append(scalar)
        }
        return String(kept)
    }

    static let directionMarks: Set<UInt32> = {
        let marks: [UInt32] = [0x061C, 0x200E, 0x200F]
        let embeddings: [UInt32] = Array(0x202A...0x202E)
        let isolates: [UInt32] = Array(0x2066...0x2069)
        return Set(marks + embeddings + isolates)
    }()

    static func hidden(_ scalar: Unicode.Scalar) -> Bool {
        ShellQuote.isControl(scalar) || directionMarks.contains(scalar.value)
    }

    /// GitLab runs a description line that starts with `/` as a quick action (`/due` would even set a deadline), so
    /// such a line gets a backslash first, which GitLab's Markdown shows as the plain `/`.
    static func noQuickActions(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.hasPrefix("/") ? "\\" + $0 : $0 }.joined(separator: "\n")
    }

    /// 6000 as `6,000`, the same on every Mac.
    static func grouped(_ number: Int) -> String {
        var digits = String(number)
        var groups: [String] = []
        while digits.count > 3 {
            groups.insert(String(digits.suffix(3)), at: 0)
            digits.removeLast(3)
        }
        groups.insert(digits, at: 0)
        return groups.joined(separator: ",")
    }

    /// `text` whole when it fits; else as many of its first lines as fit with `note` after a blank line, or, when not
    /// one whole line fits, the longest start of the first line ending in "…"; nil when not even the note alone fits.
    static func fit(_ text: String, note: String, fits: (String) -> Bool) -> (text: String, cut: Bool)? {
        if fits(text) { return (text, false) }
        let lines = text.components(separatedBy: "\n")
        func kept(_ count: Int) -> String {
            var head = lines[..<count].joined(separator: "\n")
            while head.last?.isNewline == true { head.removeLast() }
            return head.isEmpty ? note : head + "\n\n" + note
        }
        guard fits(kept(0)) else { return nil }
        var low = 0, high = lines.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(kept(middle)) { low = middle } else { high = middle - 1 }
        }
        if low == 0, let first = lines.first, !first.isEmpty {
            let characters = Array(first)
            func part(_ count: Int) -> String { String(characters[..<count]) + "…\n\n" + note }
            var shortest = 0, longest = characters.count - 1
            while shortest < longest {
                let middle = (shortest + longest + 1) / 2
                if fits(part(middle)) { shortest = middle } else { longest = middle - 1 }
            }
            if shortest > 0 { return (part(shortest), true) }
        }
        return (kept(low), true)
    }

    /// The longest start of `title`, ending in "…", that `fits`; the title itself when it fits.
    static func fitTitle(_ title: String, fits: (String) -> Bool) -> (text: String, cut: Bool) {
        if fits(title) { return (title, false) }
        let characters = Array(title)
        var low = 0, high = characters.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(String(characters[..<middle]) + "…") { low = middle } else { high = middle - 1 }
        }
        return (String(characters[..<low]) + "…", true)
    }
}

extension TaskPayload {
    /// A reminder: the title, the personal text as its notes, and the day as an all-day due date.
    static func reminder(_ task: Parts, list: String) -> TaskPayload {
        let due = task.day.map { DateComponents(year: $0.year, month: $0.month, day: $0.day) }
        let when = task.day.map { "Due: \($0) (all-day)" } ?? "No due date"
        let fields = ["Title: " + task.title, "List: " + list, when].joined(separator: "\n")
        let notes = task.personal
        return TaskPayload(form: .reminder(title: task.title, notes: notes, due: due), cut: false,
                           sent: join([fields, notes]))
    }

    /// Things' add link: the first steps as its checklist, up to 100 and 4,000 characters, the rest at the top of the
    /// notes, never dropped; the day as `when`, left out for no day; never a deadline. Things' link can't mark a
    /// checklist item done, so a done step goes in unticked.
    static func things(_ task: Parts, list: String?, today: TaskDay) -> TaskPayload? {
        var checklist: [String] = []
        var length = 0
        for text in task.stepTexts.prefix(thingsChecklist) {
            let separator = checklist.isEmpty ? 0 : 1
            let longer = length + separator + text.utf16.count
            if longer > thingsValue { break }
            checklist.append(text)
            length = longer
        }
        let over = task.stepLines.dropFirst(checklist.count).joined(separator: "\n")
        let notes = join([over, task.notes, task.whereLines.joined(separator: "\n")])
        let note = cutNote("Things", thingsNotes)
        guard let fitted = fit(notes, note: note, fits: { $0.utf16.count <= thingsNotes }) else { return nil }
        let title = fitTitle(task.title) { $0.utf16.count <= thingsValue }
        let listName = list.map { fitTitle($0) { $0.utf16.count <= thingsValue } }
        var items: [Item] = [Item("title", title.text)]
        if !fitted.text.isEmpty { items.append(Item("notes", fitted.text)) }
        if let day = task.day { items.append(Item("when", thingsWhen(day, today: today))) }
        if let listName { items.append(Item("list", listName.text)) }
        if !checklist.isEmpty { items.append(Item("checklist-items", checklist.joined(separator: "\n"))) }
        let cut = title.cut || fitted.cut || listName?.cut == true
        return link("things:///add", place: "Things", items, cut: cut)
    }

    /// `today`, `tomorrow`, or the day as `yyyy-mm-dd`.
    static func thingsWhen(_ day: TaskDay, today: TaskDay) -> String {
        if day == today { return "today" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let tomorrow = today.start(in: calendar).flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
        if let tomorrow, TaskDay(tomorrow, calendar: calendar) == day { return "tomorrow" }
        return day.description
    }

    /// A shortcut's input: the title, the day it is planned for, then the personal text.
    static func shortcut(_ task: Parts) -> TaskPayload {
        let text = join([task.title, task.day.map { "Planned: \($0)" } ?? "", task.personal])
        return TaskPayload(form: .stdin(text), cut: false, sent: text)
    }

    /// Trello's Add Card: the name only, since it documents no parameter for a description.
    static func trello(_ task: Parts) -> TaskPayload? {
        let name = fitTitle(task.title) { $0.count <= trelloName }
        return link("https://trello.com/add-card", place: nil, [Item("name", name.text)], cut: name.cut)
    }

    /// A page or Quick Add filled with a title and a body: the body cut at a line end so the whole link stays under
    /// `linkBytes` (and the body under `fieldLimit`), the title cut too when even the cut note doesn't fit beside it.
    /// The cut note names the field's length only when that length alone made the cut; otherwise the link's.
    static func page(_ base: String, place: String? = nil, name: String, title titleName: String, body bodyName: String,
                     _ title: String, _ body: String, plusSpaces: Bool = false, fieldLimit: Int? = nil) -> TaskPayload? {
        func items(_ title: String, _ body: String) -> [Item] {
            let first = Item(titleName, title)
            return body.isEmpty ? [first] : [first, Item(bodyName, body, plusSpaces: plusSpaces)]
        }
        func fits(_ title: String, _ body: String) -> Bool {
            if let fieldLimit, body.count > fieldLimit { return false }
            return (base + "?" + query(items(title, body))).utf8.count <= linkBytes
        }
        if body.isEmpty {
            let shorter = fitTitle(title) { fits($0, "") }
            return link(base, place: place, items(shorter.text, ""), cut: shorter.cut)
        }
        var note = linkCutNote(name)
        if let fieldLimit, body.count > fieldLimit {
            let fieldNote = cutNote(name, fieldLimit)
            let byField = fit(body, note: fieldNote) { $0.count <= fieldLimit }
            let byBoth = fit(body, note: fieldNote) { fits(title, $0) }
            if let byField, byField.text == byBoth?.text { note = fieldNote }
        }
        if let fitted = fit(body, note: note, fits: { fits(title, $0) }) {
            return link(base, place: place, items(title, fitted.text), cut: fitted.cut)
        }
        let shorter = fitTitle(title) { fits($0, note) }
        return link(base, place: place, items(shorter.text, note), cut: true)
    }
}

extension TaskPayload {
    /// One parameter of a link, with its value as the app or page receives it.
    struct Item {
        let name: String
        let value: String
        /// Spaces as `+` (Linear's description reads them so); a literal `+` is still `%2B`.
        var plusSpaces = false

        init(_ name: String, _ value: String, plusSpaces: Bool = false) {
            self.name = name
            self.value = value
            self.plusSpaces = plusSpaces
        }
    }

    /// What stays as it is in a link: letters, digits, `-`, `.`, `_` and `~`. Everything else, `&`, `=`, `+`, `#`, `/`
    /// and `?` included, is percent-encoded.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    static func query(_ items: [Item]) -> String {
        items.map { item in
            let value = encode(item.value)
            let spaced = item.plusSpaces ? value.replacingOccurrences(of: "%20", with: "+") : value
            return encode(item.name) + "=" + spaced
        }.joined(separator: "&")
    }

    /// Path parts, each encoded whole, so a `/`, `?`, `#` or `@` in one stays inside it and the host stays the template's.
    static func segments(_ parts: [String]) -> String {
        parts.map(encode).joined(separator: "/")
    }

    /// The link `base?query`, and what it sends: its place (the page's address without `https://`, or the app's name)
    /// and each parameter's name and value.
    static func link(_ base: String, place: String?, _ items: [Item], cut: Bool) -> TaskPayload? {
        guard var components = URLComponents(string: base) else { return nil }
        components.percentEncodedQuery = query(items)
        guard let url = components.url else { return nil }
        let address = base.replacingOccurrences(of: "https://", with: "")
        let where_ = place ?? address.removingPercentEncoding ?? address
        let sent = ([where_] + items.map { $0.name + "\n" + $0.value }).joined(separator: "\n\n")
        return TaskPayload(form: .link(url), cut: cut, sent: sent)
    }
}

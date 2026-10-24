import Foundation

/// Wrap Up's first two steps with no window: which of the window's agent tabs may be asked for a handoff, and how each
/// asked tab's file is waited for. Only a ready tab can be ticked, and a tab never ticks itself: one that turns ready
/// while the sheet is open waits for the user. Every label and count the sheet shows is decided here, from plain
/// values, so the sheet holds no rule of its own. Nothing here reads a file, touches a tab or logs.
public struct WrapUpModel: Equatable, Sendable {
    /// How long a tab is waited for before the row offers Skip and Keep Waiting; Keep Waiting gives as long again.
    public static let wait: TimeInterval = 5 * 60

    public static let noAgents = "No agent tabs in this window."

    /// "Each ticked agent is asked to write a handoff to docs/handoffs/. Nothing is posted until you review it."
    public static func footer(folder: String) -> String {
        "Each ticked agent is asked to write a handoff to \(folder)/. Nothing is posted until you review it."
    }

    /// Why a tab can't be asked.
    public enum Block: Equatable, Sendable {
        case agent(AgentReadiness.Reason)
        /// The tab works outside the project, so a path relative to the project would be wrong there.
        case outsideProject
        /// Every name today's handoff could take for this tab is taken.
        case namesUsedUp

        public var text: String {
            switch self {
            case .agent(let reason): return reason.text
            case .outsideProject: return "outside this project"
            case .namesUsedUp: return "today’s handoff names are used up"
            }
        }
    }

    /// One agent tab as the app sees it now. The title is masked already.
    public struct TabFacts: Equatable, Sendable {
        public var id: UUID
        public var title: String
        public var agent: AgentKind
        public var verdict: AgentReadiness.Verdict
        public var insideProject: Bool
        public var namesLeft: Bool

        public init(id: UUID, title: String, agent: AgentKind, verdict: AgentReadiness.Verdict, insideProject: Bool,
                    namesLeft: Bool) {
            self.id = id
            self.title = title
            self.agent = agent
            self.verdict = verdict
            self.insideProject = insideProject
            self.namesLeft = namesLeft
        }

        /// The tab's verdict first, then Wrap Up's own two reasons.
        var block: Block? {
            if case .notReady(let reason) = verdict { return .agent(reason) }
            if !insideProject { return .outsideProject }
            return namesLeft ? nil : .namesUsedUp
        }
    }

    /// Where an asked tab's handoff stands.
    public enum Phase: Equatable, Sendable {
        /// Asked; no file yet.
        case asked
        /// The file is there and still growing, or the agent is still working.
        case writing
        /// The file stopped growing and the agent stopped: it can be read.
        case ready
        /// Waited the full time with no finished file.
        case stillWriting
        /// The agent asks a question; an answer that leads to the file still counts.
        case asking
        /// The tab closed or its agent exited.
        case closed(String)
        /// Not asked, or no longer waited for; the words say why.
        case skipped(String)
    }

    public struct Row: Equatable, Sendable {
        public let id: UUID
        public var title: String
        public var agent: AgentKind
        public var block: Block?
        public var ticked = false
        /// nil until the tab is asked or skipped at Ask.
        public var phase: Phase?
        /// The handoff's path relative to the project, once asked.
        public var file: String?
        var deadline: Date?
        var lastSize: Int?

        public var isReady: Bool { block == nil }
        public var reason: String? { block?.text }

        public var phaseText: String? {
            switch phase {
            case nil: return nil
            case .asked: return "Asked"
            case .writing: return "Writing…"
            case .ready: return "Ready to review"
            case .stillWriting: return "Still writing"
            case .asking: return "asking"
            case .closed(let why): return why
            case .skipped(let why): return "Skipped: " + why
            }
        }

        /// Still waited for: the timer looks at it.
        public var isWaiting: Bool {
            switch phase {
            case .asked, .writing, .stillWriting, .asking, .closed: return true
            case nil, .ready, .skipped: return false
            }
        }

        public var canSkip: Bool { isWaiting }
        public var canKeepWaiting: Bool { phase == .stillWriting }
    }

    public private(set) var rows: [Row]

    /// Ready tabs start ticked; the rest can't be ticked and say why.
    public init(_ tabs: [TabFacts]) {
        rows = tabs.map { tab in
            let block = tab.block
            return Row(id: tab.id, title: tab.title, agent: tab.agent, block: block, ticked: block == nil)
        }
    }
}

extension WrapUpModel {
    /// The tabs as they are now. A ticked row that stopped being ready is unticked; one that turned ready stays as it
    /// was. A tab opened meanwhile joins unticked, and one closed leaves. Rows already asked keep their place.
    public mutating func refresh(_ tabs: [TabFacts]) {
        var kept: [Row] = []
        for tab in tabs {
            guard var row = rows.first(where: { $0.id == tab.id }) else {
                kept.append(Row(id: tab.id, title: tab.title, agent: tab.agent, block: tab.block))
                continue
            }
            row.title = tab.title
            row.agent = tab.agent
            row.block = tab.block
            if row.block != nil { row.ticked = false }
            kept.append(row)
        }
        let asked: [Row] = rows.filter { row in row.phase != nil && !kept.contains { $0.id == row.id } }
        rows = kept + asked
    }

    /// Ticks or unticks a row; a row that isn't ready can't be ticked.
    public mutating func setTicked(_ id: UUID, _ on: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].ticked = on && rows[index].isReady
    }

    public var askCount: Int { rows.filter(\.ticked).count }
    public var canAsk: Bool { askCount > 0 }
    public var askTitle: String { askCount == 1 ? "Ask 1 Agent" : "Ask \(askCount) Agents" }

    // MARK: asking and waiting

    /// The request for `file` was typed into the tab at `now`.
    public mutating func asked(_ id: UUID, file: String, at now: Date) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].file = file
        rows[index].phase = .asked
        rows[index].deadline = now.addingTimeInterval(Self.wait)
        rows[index].lastSize = nil
    }

    /// The tab is not, or no longer, waited for.
    public mutating func skip(_ id: UUID, because why: String = "skipped") {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].phase = .skipped(why)
    }

    /// Waits as long again for a tab that is still writing.
    public mutating func keepWaiting(_ id: UUID, now: Date) {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].isWaiting else { return }
        rows[index].deadline = now.addingTimeInterval(Self.wait)
        rows[index].phase = rows[index].lastSize == nil ? .asked : .writing
    }

    /// One look at an asked tab and its named file, as plain values.
    public struct Look: Equatable, Sendable {
        public var exists: Bool
        public var size: Int?
        public var working: Bool
        public var gone: Bool
        public var exited: Bool
        public var asking: Bool
        public var now: Date

        public init(exists: Bool, size: Int?, working: Bool, gone: Bool, exited: Bool, asking: Bool, now: Date) {
            self.exists = exists
            self.size = size
            self.working = working
            self.gone = gone
            self.exited = exited
            self.asking = asking
            self.now = now
        }
    }

    /// The file is ready once it is the same size on two looks and the tab is not working; a closed tab works no more.
    public mutating func look(_ id: UUID, _ look: Look) {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].isWaiting else { return }
        var row = rows[index]
        let size: Int? = look.exists ? look.size : nil
        let working = look.working && !look.gone && !look.exited
        let steady = size != nil && size == row.lastSize
        row.lastSize = size
        if steady && !working {
            row.phase = .ready
        } else if look.gone {
            row.phase = .closed("closed")
        } else if look.exited {
            row.phase = .closed("exited")
        } else if look.asking {
            row.phase = .asking
        } else if let deadline = row.deadline, look.now >= deadline {
            row.phase = .stillWriting
        } else {
            row.phase = size == nil ? .asked : .writing
        }
        rows[index] = row
    }

    /// Rows asked or skipped at Ask: the waiting step's list.
    public var askedRows: [Row] { rows.filter { $0.phase != nil } }
    /// Some tab is still waited for.
    public var isWaiting: Bool { rows.contains(where: \.isWaiting) }
    /// The review never waits on the slowest agent: one ready handoff is enough. Once nothing is waited for, the
    /// review opens even with no handoff, so tasks can still be added by hand.
    public var canReview: Bool {
        rows.contains { $0.phase == .ready } || (!askedRows.isEmpty && !isWaiting)
    }

    /// At Review, every tab still waited for is skipped: a closed one says so, the rest have no handoff yet.
    public mutating func stopWaiting() {
        for index in rows.indices where rows[index].isWaiting {
            if case .closed(let why) = rows[index].phase {
                rows[index].phase = .skipped(why)
            } else {
                rows[index].phase = .skipped("no handoff yet")
            }
        }
    }
}

/// Wrap Up's review: one section per asked tab, each Next item a ticked task for tomorrow the user can edit, untick or
/// add to. Nothing is sent from here: the drafts go to the one sender only when the user presses Add. Every title is
/// masked again as it is edited, as the Add Task sheet's is.
public struct WrapUpReview: Equatable, Sendable {
    /// When a task is planned for, as the Add Task sheet's popup says it.
    public enum When: Int, CaseIterable, Sendable {
        case today, tomorrow, nextWeek, noDate

        public var title: String {
            switch self {
            case .today: return "Today"
            case .tomorrow: return "Tomorrow"
            case .nextWeek: return "Next Week"
            case .noDate: return "No Date"
            }
        }

        public func scheduled(now: Date, calendar: Calendar) -> TaskDraft.Scheduled {
            switch self {
            case .today: return .day(TaskDay(now, calendar: calendar))
            case .tomorrow: return .day(NextTermCore.When.days(1, after: now, calendar: calendar))
            case .nextWeek: return .day(NextTermCore.When.nextWeek(after: now, calendar: calendar))
            case .noDate: return .none
            }
        }
    }

    public struct Task: Equatable, Sendable {
        public let id: UUID
        public var title: String
        public var ticked: Bool
        public var when: When
        /// A stored key was in the title and shows as •••.
        public var masked: Bool

        public init(id: UUID = UUID(), title: String, ticked: Bool, when: When = .tomorrow, masked: Bool = false) {
            self.id = id
            self.title = title
            self.ticked = ticked
            self.when = when
            self.masked = masked
        }

        var counts: Bool { ticked && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public struct Section: Equatable, Sendable {
        /// The tab's id.
        public let id: UUID
        public var title: String
        /// The handoff's path relative to the project, when the tab was asked.
        public var file: String?
        /// Why there are no tasks from the file, when there are none.
        public var note: String?
        /// The masked text as read, for Show File.
        public var raw: String?
        public var truncated = false
        /// The text is shown opened, since there are no tasks from it.
        public var showsText = false
        public var tasks: [Task] = []
    }

    public private(set) var sections: [Section]

    /// The sections for the rows that were asked or skipped at Ask, with what was read from each ready one.
    public init(rows: [WrapUpModel.Row], reads: [UUID: HandoffFile.Read]) {
        sections = rows.filter { $0.phase != nil }.map { Self.section($0, read: reads[$0.id]) }
    }

    static func section(_ row: WrapUpModel.Row, read: HandoffFile.Read?) -> Section {
        var section = Section(id: row.id, title: row.title, file: row.file)
        guard row.phase == .ready, let read else {
            section.note = row.phaseText
            return section
        }
        switch read {
        case .text(let handoff):
            section.raw = handoff.raw
            section.truncated = handoff.truncated
            section.tasks = handoff.next.map { Task(title: $0.text, ticked: !$0.done) }
            guard section.tasks.isEmpty else { return section }
            let hasNext = handoff.sections[.next] != nil
            section.note = hasNext ? "This handoff’s Next section has no items." : "This handoff has no Next section."
            section.showsText = true
            section.tasks = [Task(title: "", ticked: false)]
        case .missing: section.note = "The handoff is gone, so there was nothing to read."
        case .notPlainFile: section.note = "The handoff is not a plain file, so it wasn’t read."
        case .notText: section.note = "The handoff is not text, so it wasn’t read."
        case .unreadable: section.note = "The handoff couldn’t be opened."
        }
        return section
    }
}

extension WrapUpReview {
    /// A new empty, unticked task under the section, for one written by hand.
    public mutating func addRow(_ section: UUID) {
        guard let index = sections.firstIndex(where: { $0.id == section }) else { return }
        sections[index].tasks.append(Task(title: "", ticked: false))
    }

    /// The title as edited, masked before it is held.
    public mutating func setTitle(_ section: UUID, _ task: UUID, _ text: String,
                                  mask: (String) -> String = { SecretMask.current.mask($0) }) {
        let masked = mask(text)
        update(section, task) {
            $0.title = masked
            $0.masked = masked != text
        }
    }

    public mutating func setTicked(_ section: UUID, _ task: UUID, _ on: Bool) {
        update(section, task) { $0.ticked = on }
    }

    public mutating func setWhen(_ section: UUID, _ task: UUID, _ when: When) {
        update(section, task) { $0.when = when }
    }

    private mutating func update(_ section: UUID, _ task: UUID, _ change: (inout Task) -> Void) {
        guard let s = sections.firstIndex(where: { $0.id == section }),
              let t = sections[s].tasks.firstIndex(where: { $0.id == task }) else { return }
        change(&sections[s].tasks[t])
    }

    /// Ticked tasks with a title.
    public var addCount: Int { sections.reduce(0) { $0 + $1.tasks.filter(\.counts).count } }
    public var canAdd: Bool { addCount > 0 }
    public var addTitle: String { addCount == 1 ? "Add 1 Task" : "Add \(addCount) Tasks" }

    /// The tasks Add hands to the sender, in order: each with its day, its tab's context, and the handoff it came
    /// from in its notes. Titles were masked as they were made or edited; they are masked once more here.
    public func drafts(now: Date, calendar: Calendar, contexts: [UUID: TaskContext],
                       mask: (String) -> String = { SecretMask.current.mask($0) }) -> [TaskDraft] {
        var drafts: [TaskDraft] = []
        for section in sections {
            let notes: String = section.file.map { "From " + mask($0) } ?? ""
            for task in section.tasks where task.counts {
                let title = mask(task.title.trimmingCharacters(in: .whitespacesAndNewlines))
                let masked = task.masked || title != task.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let scheduled = task.when.scheduled(now: now, calendar: calendar)
                drafts.append(TaskDraft(title: title, steps: [], notes: notes, scheduled: scheduled,
                                        context: contexts[section.id], masked: masked))
            }
        }
        return drafts
    }
}

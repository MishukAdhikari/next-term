import Foundation

/// One herdr tab's agents, followed one by one across the status checks: when each starts to need a decision, when it
/// finishes, whether it is on screen, what counts toward the Dock badge, the tab's own state, and the rows the tab list
/// shows. herdr's states are taken as given: its `done` already means "finished, and not seen yet", and Next Term never
/// reads an agent's state from herdr's painted screen. Pure: the tab feeds it each check's list and the clock.
///
/// herdr's seen is not always the user's: a turn that ends in herdr's focused pane counts as seen there unless the
/// terminal said its focus left, and Codex can read `unknown` at rest. So a turn that ends as idle while the agent was
/// off screen, or as unknown, is a finish too, and Next Term keeps it unread (its own flag; herdr's state is untouched)
/// until the user chooses the agent or herdr reports it at work again. Keep as Unread sets the same flag by hand.
public struct HerdrAgents: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// The agent waits on the user's decision: herdr read it blocked on two checks in a row, so a blocked that lasts
        /// one check (a flicker) is no news.
        case needsDecision(pane: String)
        /// Its pane is worth one read for its question (`HerdrCommand.read`, visible): it turned blocked, or herdr counted
        /// a change while it stayed blocked (`seq`, its state count then).
        case needsRead(pane: String, seq: Int?)
        /// It finished work. `duration`: how long Next Term saw it work, at least `TabStatus.notifyAfter`; nil when only
        /// herdr's counts say a turn ended (its finished turns rose, or its state changed twice between two checks).
        case finished(pane: String, duration: TimeInterval?)
        /// It no longer needs the user as it did: it left blocked, or it was finished (done, or kept unread) and is not
        /// now. A notice about it is out of date.
        case resolved(pane: String)
        /// herdr no longer lists it.
        case gone(pane: String)
    }

    /// The question read from a blocked agent's own pane.
    public struct Question: Equatable, Sendable {
        public var text: String
        public var choices: [String]
        public var style: AgentMenu.Style?
        /// New for each question, even in the same words (as TabStatus.questionSerial): an answer meant for one never
        /// lands on the next.
        public var serial: Int
        /// herdr's state count when it was read.
        public var seq: Int?

        public init(text: String, choices: [String] = [], style: AgentMenu.Style? = nil, serial: Int = 0, seq: Int? = nil) {
            self.text = text
            self.choices = choices
            self.style = style
            self.serial = serial
            self.seq = seq
        }
    }

    /// What is kept of one agent between checks.
    struct Followed: Equatable, Sendable {
        var status: HerdrAgent.Status
        /// When Next Term first saw it working this turn.
        var workSince: TimeInterval?
        /// When it began to need the user as it does now (blocked, or finished: done or kept unread).
        var needsSince: TimeInterval?
        var stateSeq: Int?
        var completionSeq: Int?
        var question: Question?
        /// Checks in a row that read it blocked, and whether its decision was told for them.
        var blockedChecks = 0
        var decisionTold = false
        /// Next Term keeps it as finished and not seen (R26, Keep as Unread).
        var unread = false
        /// It was on screen at this check: the next compares with what the user could see then.
        var onScreen = false

        /// Blocked, done, or kept unread.
        var needsYou: Bool { status == .blocked || status == .done || unread }
        /// Finished: done, or kept unread.
        var finished: Bool { status != .blocked && (status == .done || unread) }
    }

    /// herdr's agents as it last listed them, in its order.
    public private(set) var agents: [HerdrAgent] = []
    private var followed: [String: Followed] = [:]
    /// Agents whose notices the user turned off (Mute Notices), until Unmute, until their pane is gone, or until Next
    /// Term quits. Their rows, badge counts and MCP states are as before.
    private var muted: Set<String> = []
    /// The herdr tab its focus is in: the focused agent's, else what `herdr tab list` said; nil when unknown.
    public private(set) var focusedTab: String?
    /// The Next Term tab is on screen.
    public private(set) var tabVisible = false
    /// Blocked agents whose question is still to be read, with herdr's state count when they asked: the tab reads one at
    /// a time (`nextRead`), and a read's answer (`setQuestion`) or the agent moving on takes it off.
    private var reads: [String: Int?] = [:]
    private var serials = 0
    /// Agents the last update looked at: one step each, so a long list costs a step per agent (the self-test's budget).
    public private(set) var steps = 0

    public init() {}

    /// Takes one check's list. `focusedTab`: the herdr tab `herdr tab list` says has the focus (asked only when no agent
    /// has it); `tabVisible`: the Next Term tab is on screen. Returns what happened to each agent since the last check.
    public mutating func update(_ list: [HerdrAgent], focusedTab focused: String?, tabVisible: Bool, now: TimeInterval) -> [Event] {
        var events: [Event] = []
        var next: [String: Followed] = [:]
        next.reserveCapacity(list.count)
        var listed: [HerdrAgent] = []
        listed.reserveCapacity(list.count)
        steps = 0
        for agent in list {
            steps += 1
            let pane = agent.paneID
            guard next[pane] == nil else { continue } // a pane listed twice is the first
            listed.append(agent)
            let before = followed[pane]
            var kept = Followed(status: agent.status, stateSeq: agent.stateSeq, completionSeq: agent.completionSeq)
            if agent.status == .working {
                kept.workSince = before?.status == .working ? (before?.workSince ?? now) : now
            }
            // Work or a decision is herdr's news again: Next Term's unread flag gives way.
            kept.unread = agent.status == .working || agent.status == .blocked ? false : before?.unread ?? false
            switch agent.status {
            case .blocked:
                events += blocked(agent, before: before, kept: &kept)
            case .done, .idle, .unknown:
                reads[pane] = nil
                if let finish = Self.finish(before, agent, now: now) {
                    events.append(finish.event)
                    if finish.unread { kept.unread = true }
                }
            case .working:
                reads[pane] = nil
            }
            kept.needsSince = Self.needsSince(before, kept, now: now)
            if let before, (before.status == .blocked && kept.status != .blocked) || (before.finished && !kept.finished) {
                events.append(.resolved(pane: pane))
            }
            next[pane] = kept
        }
        for pane in followed.keys where next[pane] == nil {
            events.append(.gone(pane: pane))
            reads[pane] = nil
            muted.remove(pane)
        }
        followed = next
        agents = listed
        self.tabVisible = tabVisible
        focusedTab = listed.first(where: \.focused)?.tabID ?? focused
        for agent in listed {
            let shown = isOnScreen(agent.paneID)
            followed[agent.paneID]?.onScreen = shown
        }
        return events
    }

    /// A blocked agent's news this check: its pane is read on the first check that finds it blocked (and again when herdr
    /// counts a change), and its decision is told on the second check in a row, with the same state count or a later
    /// one, so a blocked of one check posts nothing.
    private mutating func blocked(_ agent: HerdrAgent, before: Followed?, kept: inout Followed) -> [Event] {
        let pane = agent.paneID
        var events: [Event] = []
        let lasts = before?.status == .blocked && (agent.stateSeq ?? 0) >= (before?.stateSeq ?? 0)
        if lasts, let before {
            kept.question = before.question
            kept.blockedChecks = before.blockedChecks + 1
            kept.decisionTold = before.decisionTold
            if agent.stateSeq != before.stateSeq {
                events.append(.needsRead(pane: pane, seq: agent.stateSeq))
                reads[pane] = .some(agent.stateSeq)
            }
        } else {
            kept.blockedChecks = 1
            events.append(.needsRead(pane: pane, seq: agent.stateSeq))
            reads[pane] = .some(agent.stateSeq)
        }
        if kept.blockedChecks >= 2 && !kept.decisionTold {
            kept.decisionTold = true
            events.insert(.needsDecision(pane: pane), at: 0)
        }
        return events
    }

    /// A turn that ended between the checks, if one did, and whether Next Term keeps it unread because herdr does not show
    /// it as done. From work Next Term saw for `TabStatus.notifyAfter` or longer: into done, into unknown (an agent that
    /// reads unknown at rest), or into idle while the agent was off screen at the check before (herdr took it as seen
    /// though the user could not see it); into idle while on screen, the user saw it end. With no work seen: herdr's count
    /// of finished turns rising, or its state count rising by 2 or more (work that came and went between two checks).
    /// Nothing for the list a tab first gets.
    private static func finish(_ before: Followed?, _ agent: HerdrAgent, now: TimeInterval) -> (event: Event, unread: Bool)? {
        guard let before else { return nil }
        let pane = agent.paneID
        if before.status == .working {
            let unseen = agent.status == .unknown || (agent.status == .idle && !before.onScreen)
            guard agent.status == .done || unseen else { return nil }
            let duration = now - (before.workSince ?? now)
            guard duration >= TabStatus.notifyAfter else { return nil }
            return (.finished(pane: pane, duration: duration), unseen)
        }
        let rose: Bool
        if let was = before.completionSeq, let count = agent.completionSeq, count > was {
            rose = true
        } else if let was = before.stateSeq, let count = agent.stateSeq, count >= was + 2 {
            rose = true
        } else {
            rose = false
        }
        guard rose else { return nil }
        return (.finished(pane: pane, duration: nil), agent.status != .done && !before.onScreen)
    }

    /// When the agent began to need the user as it does now: kept while it stays blocked, or stays finished (done, or
    /// kept unread); from now when it starts to; nil while it needs nothing.
    private static func needsSince(_ before: Followed?, _ kept: Followed, now: TimeInterval) -> TimeInterval? {
        guard kept.needsYou else { return nil }
        guard let before, let since = before.needsSince else { return now }
        let sameNeed = (before.status == .blocked && kept.status == .blocked) || (before.finished && kept.finished)
        return sameNeed ? since : now
    }

    // MARK: seen, unread and quiet

    /// The user chose the agent (its row, Go to Agent, its notice, ⌃⌘N, the Dock menu): Next Term's unread flag clears.
    /// herdr's own done clears when herdr shows it.
    public mutating func seen(_ pane: String) {
        guard var kept = followed[pane], kept.unread else { return }
        kept.unread = false
        if !kept.needsYou { kept.needsSince = nil }
        followed[pane] = kept
    }

    /// Keep as Unread: the agent stays finished and not seen, in the badge and in Needs You, until the user chooses it or
    /// herdr reports it working or blocked. Not for an agent that works or waits on a decision (herdr's news is newer).
    public mutating func markUnread(_ pane: String, now: TimeInterval) {
        guard var kept = followed[pane], kept.status != .working, kept.status != .blocked else { return }
        if !kept.finished { kept.needsSince = now }
        kept.unread = true
        followed[pane] = kept
    }

    public func isUnread(_ pane: String) -> Bool { followed[pane]?.unread ?? false }

    /// Mute Notices (true), or Unmute.
    public mutating func mute(_ pane: String, _ on: Bool) {
        guard followed[pane] != nil || !on else { return }
        if on { muted.insert(pane) } else { muted.remove(pane) }
    }

    public func isMuted(_ pane: String) -> Bool { muted.contains(pane) }

    /// When the agent began to need the user (blocked, done, or kept unread), for oldest-first order; nil while it needs
    /// nothing.
    public func needsSince(_ pane: String) -> TimeInterval? { followed[pane]?.needsSince }

    /// When Next Term first saw the agent working this turn; nil while it does not work.
    public func workSince(_ pane: String) -> TimeInterval? { followed[pane]?.workSince }

    // MARK: questions

    /// The blocked agent whose question is to be read next, and herdr's state count when it asked; nil when none waits.
    public var nextRead: (pane: String, seq: Int?)? {
        guard let pane = agents.lazy.map(\.paneID).first(where: { reads[$0] != nil }), let seq = reads[pane] else { return nil }
        return (pane, seq)
    }

    /// What a read of a blocked agent's pane found (`text` nil: no question on it, so herdr's words stay). For the read
    /// asked at `seq`: an answer for an agent that moved on since is dropped.
    public mutating func setQuestion(pane: String, seq: Int?, text: String?, choices: [String] = [], style: AgentMenu.Style? = nil) {
        guard var kept = followed[pane], kept.status == .blocked, kept.stateSeq == seq else { return }
        if reads[pane] == .some(seq) { reads[pane] = nil }
        guard let text else {
            kept.question = nil
            followed[pane] = kept
            return
        }
        if let asked = kept.question, asked.text == text, asked.seq == seq {
            kept.question?.choices = choices
            kept.question?.style = style
        } else {
            serials += 1
            kept.question = Question(text: text, choices: choices, style: style, serial: serials, seq: seq)
        }
        followed[pane] = kept
    }

    /// The question read from the agent's pane while it is blocked.
    public func question(_ pane: String) -> Question? { followed[pane]?.question }

    /// The agent's question is still to be read.
    public func awaitsRead(_ pane: String) -> Bool { reads[pane] != nil }

    /// What a blocked agent's pane shows (`herdr agent read --source visible`), read the way a local agent's screen is
    /// (AgentScreen): the question and the menu under it, stored keys masked in both (its choices from the rows masked
    /// whole, as MCPControl.fieldMenu has them). nil when the pane shows no question.
    public static func question(onScreen text: String, mask: SecretMask = .current) -> (text: String, menu: AgentMenu?)? {
        let lines = text.components(separatedBy: "\n")
        guard case .asking(let asked) = AgentScreen.activity(screenLines: lines, mask: mask) else { return nil }
        return (asked, AgentScreen.menu(asking: asked, screenLines: lines, shown: mask.mask(rows: lines), mask: mask))
    }

    // MARK: what the tab shows

    /// The agent is on screen: the Next Term tab is, and herdr shows the agent's own tab there (unknown counts as shown).
    public func isOnScreen(_ pane: String) -> Bool {
        guard tabVisible else { return false }
        guard let focusedTab, let tab = agents.first(where: { $0.paneID == pane })?.tabID else { return true }
        return tab == focusedTab
    }

    /// The agents that need the user and are not on screen (blocked, done and not seen, or kept unread), for the Dock
    /// badge. A muted agent still counts: muting stops its notices only.
    public var needsYou: [String] {
        var seen = Set<String>()
        return agents.compactMap { agent in
            guard followed[agent.paneID]?.needsYou == true, !isOnScreen(agent.paneID), seen.insert(agent.paneID).inserted else { return nil }
            return agent.paneID
        }
    }

    /// The tab's own state, as before: the first agent that needs a decision, named, with its question as read from its
    /// pane ("api (claude): Do you want…?"), else in herdr's words ("codex (w1:p2) needs a decision", and how many more);
    /// then work; else idle.
    public var activity: AgentActivity {
        let blocked = agents.filter { $0.status == .blocked }
        if let first = blocked.first {
            if let asked = followed[first.paneID]?.question { return .asking(Self.label(first) + ": " + asked.text) }
            let others = blocked.count - 1
            return .asking("\(first.name) (\(first.paneID)) needs a decision" + (others > 0 ? ", and \(others) more" : ""))
        }
        if agents.contains(where: { $0.status == .working }) { return .working }
        return .idle
    }

    /// "api (claude)" for an agent herdr shows by a name of its own, else "claude".
    public static func label(_ agent: HerdrAgent) -> String {
        let name = agent.name
        guard let kind = agent.kind, kind != name else { return name }
        return "\(name) (\(kind))"
    }

    /// The tab list's rows, one per agent in herdr's order (its states as marks: blocked asks, working works, done and kept
    /// unread are done, idle and unknown show nothing). Two rows with the same name and title say where each works.
    public var rows: [TabListRows.Agent] {
        var made = agents.map { agent -> TabListRows.Agent in
            let kept = followed[agent.paneID]
            return TabListRows.Agent(pane: agent.paneID, name: agent.name, kind: agent.kind, title: agent.title,
                                     directory: agent.directory, status: agent.status, question: kept?.question?.text,
                                     focused: agent.focused, unread: kept?.unread ?? false, muted: muted.contains(agent.paneID),
                                     needsSince: kept?.needsSince, workSince: kept?.workSince)
        }
        Self.disambiguate(&made)
        return made
    }

    /// Rows that read the same (name and title) each add the last folder of where they work, else their pane id when
    /// those are the same too ("claude · Fix login · api").
    static func disambiguate(_ rows: inout [TabListRows.Agent]) {
        let groups = Dictionary(grouping: rows.indices) { rows[$0].name + "\u{0}" + (rows[$0].title ?? "") }
        for indices in groups.values where indices.count > 1 {
            let folders = indices.map { index in rows[index].directory.map { ($0 as NSString).lastPathComponent } }
            let distinct = Set(folders.compactMap { $0 }).count == indices.count
            for (index, folder) in zip(indices, folders) {
                rows[index].disambiguation = distinct ? folder : rows[index].pane
            }
        }
    }

    /// More agents than this in one tab fold their idle ones into one row.
    public static let foldsPast = 6

    /// A tab's rows as shown, and those folded into one ("5 idle"): past `foldsPast` agents, the idle and unknown ones
    /// that are not kept unread fold, when there are two or more of them. Blocked, done, working and kept-unread agents
    /// never fold, and nothing moves: the shown keep herdr's order.
    public static func fold(_ rows: [TabListRows.Agent]) -> (shown: [TabListRows.Agent], folded: [TabListRows.Agent]) {
        guard rows.count > foldsPast else { return (rows, []) }
        let quiet = rows.filter(\.folds)
        guard quiet.count >= 2 else { return (rows, []) }
        return (rows.filter { !$0.folds }, quiet)
    }

    /// herdr's state in words, as a tab's is said.
    public static func words(_ status: HerdrAgent.Status) -> String {
        switch status {
        case .blocked: return "Needs your decision"
        case .working: return "Working"
        case .done: return "Done"
        case .idle: return "Idle"
        case .unknown: return "State unknown"
        }
    }

    /// The tab's tooltip lines for its agents: up to `shown` ("claude · w1:p1 · Working · Fix the login"), then "and 3
    /// more".
    public var tooltipLines: [String] { Self.tooltipLines(rows) }

    public static func tooltipLines(_ rows: [TabListRows.Agent], shown: Int = 8, now: TimeInterval? = nil) -> [String] {
        var lines = rows.prefix(shown).map { $0.summary(now: now) }
        if rows.count > shown { lines.append("and \(rows.count - shown) more") }
        return lines
    }

    /// herdr's state as a tab's mark.
    public static func state(_ status: HerdrAgent.Status) -> TabState {
        switch status {
        case .blocked: return .attention
        case .working: return .working
        case .done: return .done
        case .idle, .unknown: return .idle
        }
    }

    // MARK: time in state

    /// How long an agent has been in its state, in a row's words: "4 min", "1 h 5 min"; nil under a minute.
    public static func duration(_ seconds: TimeInterval) -> String? {
        let minutes = Int(seconds / 60)
        guard minutes >= 1 else { return nil }
        guard minutes >= 60 else { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// The same, said in full for VoiceOver: "4 minutes", "1 hour 5 minutes"; nil under a minute.
    public static func spokenDuration(_ seconds: TimeInterval) -> String? {
        let minutes = Int(seconds / 60)
        guard minutes >= 1 else { return nil }
        func unit(_ count: Int, _ name: String) -> String { "\(count) \(name)\(count == 1 ? "" : "s")" }
        guard minutes >= 60 else { return unit(minutes, "minute") }
        let rest = minutes % 60
        return rest == 0 ? unit(minutes / 60, "hour") : unit(minutes / 60, "hour") + " " + unit(rest, "minute")
    }
}

extension TabListRows {
    /// One of herdr's agents, under its herdr tab (HerdrAgents.rows): plain values the last check left.
    public struct Agent: Equatable, Sendable {
        public var pane: String
        /// herdr's name for it: its display name, else the name it was given, else what runs.
        public var name: String
        public var kind: String?
        public var title: String?
        public var directory: String?
        public var status: HerdrAgent.Status
        /// The question read from its pane while it waits on a decision.
        public var question: String?
        /// Its pane has herdr's focus.
        public var focused: Bool
        /// Next Term keeps it as finished and not seen.
        public var unread: Bool
        /// Its notices are off.
        public var muted: Bool
        /// Since when it needs the user (blocked, done or kept unread), and since when it works, as Next Term saw them.
        public var needsSince: TimeInterval?
        public var workSince: TimeInterval?
        /// What tells it from a row that reads the same: the last folder of where it works, or its pane id.
        public var disambiguation: String?

        public init(pane: String, name: String, kind: String? = nil, title: String? = nil, directory: String? = nil,
                    status: HerdrAgent.Status = .idle, question: String? = nil, focused: Bool = false, unread: Bool = false,
                    muted: Bool = false, needsSince: TimeInterval? = nil, workSince: TimeInterval? = nil,
                    disambiguation: String? = nil) {
            self.pane = pane
            self.name = name
            self.kind = kind
            self.title = title
            self.directory = directory
            self.status = status
            self.question = question
            self.focused = focused
            self.unread = unread
            self.muted = muted
            self.needsSince = needsSince
            self.workSince = workSince
            self.disambiguation = disambiguation
        }

        /// Its mark: herdr's state, and done while kept unread.
        public var state: TabState {
            unread && status != .blocked && status != .working ? .done : HerdrAgents.state(status)
        }

        /// Its state in words: herdr's, "Done" while kept unread.
        public var words: String {
            state == .done && status != .done ? "Done" : HerdrAgents.words(status)
        }

        /// It folds with the idle ones (HerdrAgents.fold).
        public var folds: Bool { (status == .idle || status == .unknown) && !unread }

        /// How long it has waited ("waiting 4 min": blocked, done or kept unread) or worked ("working 12 min") at `now`;
        /// nil under a minute, or in another state.
        public func time(now: TimeInterval) -> String? {
            if let since = needsSince, let said = HerdrAgents.duration(now - since) { return "waiting " + said }
            if status == .working, let since = workSince, let said = HerdrAgents.duration(now - since) { return "working " + said }
            return nil
        }

        /// The same for VoiceOver: "waiting 4 minutes".
        public func spokenTime(now: TimeInterval) -> String? {
            if let since = needsSince, let said = HerdrAgents.spokenDuration(now - since) { return "waiting " + said }
            if status == .working, let since = workSince, let said = HerdrAgents.spokenDuration(now - since) { return "working " + said }
            return nil
        }

        /// "claude · w1:p1 · Working · Fix the login": the tab's tooltip line for it, with the time in its state when
        /// `now` is given.
        public func summary(now: TimeInterval? = nil) -> String {
            let waited = now.flatMap { self.time(now: $0) }
            let name = disambiguation.map { "\(self.name) (\($0))" } ?? self.name
            let tail = [title, waited].compactMap { $0 }
            return ([name, pane, words] + tail).joined(separator: " · ")
        }

        /// Its row's tooltip: its summary, then its question or where it works, and what Next Term adds of its own.
        public func tooltip(now: TimeInterval? = nil) -> String {
            var lines = [summary(now: now), question ?? directory].compactMap { $0 }
            if now.flatMap({ time(now: $0) }) != nil { lines.append("Times are since Next Term saw it.") }
            if unread { lines.append("Kept unread in Next Term.") }
            if muted { lines.append("Its notices are muted.") }
            return lines.joined(separator: "\n")
        }
    }
}

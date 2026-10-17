import Foundation

// herdr's list of agents, read tolerantly. The status check runs `herdr agent list` (or, for herdr before 0.5.10, which
// has no `agent` command, `pane list`) and prints what it said on stdout and stderr together, its exit status, and an
// end marker (RemoteShell.herdrSection). herdr prints one compact JSON object on one of the two: the list on stdout, an
// error on stderr. What else can come with it (a version manager's warning, a BOM, colours, pretty-printed JSON, an
// error before 0.8.0 that was plain text) is read past, never taken for the answer, and an answer that was cut is never a
// partial list.

/// What herdr's list said.
public enum HerdrListing: Equatable, Sendable {
    /// herdr answered with its agents (none is an answer too).
    case agents([HerdrAgent])
    /// No herdr server runs on the socket the check asked: herdr's words, which name it.
    case notRunning(String)
    /// The server and the CLI speak different protocols (herdr was upgraded under a running server): herdr's words.
    case needsRestart(String)
    /// Anything else herdr said, masked and cut, or that it said nothing.
    case failed(String)
    /// The answer was cut (its 1 MB cap, the check's time limit, a dropped connection).
    case cut
    /// The status check found no herdr on the host.
    case missing
}

/// One status check's herdr section: where herdr was found, and what its list said.
public struct HerdrReport: Equatable, Sendable {
    public var path: String?
    /// How the check found it: running (the user's herdr server), login (the login shell's PATH), path (/bin/sh's
    /// PATH), known (an install folder), or cache (where a tab found it, without saying how).
    public var how: String?
    public var listing: HerdrListing
    /// The herdr session asked; nil for herdr's default.
    public var session: String?
    /// The herdr tab its focus is in, as `herdr tab list` said, when the check asked (no agent had the focus).
    public var focusedTab: String?

    public init(path: String? = nil, how: String? = nil, listing: HerdrListing, session: String? = nil, focusedTab: String? = nil) {
        self.path = path
        self.how = how
        self.listing = listing
        self.session = session
        self.focusedTab = focusedTab
    }

    /// The most the check keeps of herdr's answer (`head -c`): one that long was cut.
    static let outputCap = 1_000_000

    /// The section after `RemoteShell.herdrMarker`: `session<TAB>name` for a named session, `missing<TAB>…`, or
    /// `where<TAB>path<TAB>how`, `exit<TAB>status<TAB>command`, `out<TAB>what herdr said` and maybe `tabs<TAB>what herdr's
    /// tab list said`, then the end marker. Returns the report and how many lines it took, the end marker's included. No
    /// end marker: the answer was cut.
    public static func parse(section lines: ArraySlice<Substring>) -> (report: HerdrReport, consumed: Int) {
        var report = HerdrReport(listing: .cut)
        var missing = false, ended = false
        var exit: Int32?
        var command = "agent"
        var output: String?
        var consumed = 0
        for line in lines {
            consumed += 1
            if line == RemoteShell.herdrEndMarker {
                ended = true
                break
            }
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            switch fields[0] {
            case "missing":
                missing = true
            case "session" where fields.count >= 2:
                report.session = fields[1].isEmpty ? nil : fields[1]
            case "tabs":
                report.focusedTab = HerdrTabs.focusedTab(String(line.dropFirst(min(5, line.count))))
            case "where" where fields.count >= 2:
                report.path = fields[1].isEmpty ? nil : fields[1]
                report.how = fields.count > 2 && !fields[2].isEmpty ? fields[2] : nil
            case "exit" where fields.count >= 2:
                exit = Int32(fields[1])
                if fields.count > 2, !fields[2].isEmpty { command = fields[2] }
            case "out":
                output = String(line.dropFirst(min(4, line.count)))
            default:
                // A line outside the format (an older check's bare JSON): what herdr said.
                output = (output.map { $0 + " " } ?? "") + line
            }
        }
        guard ended else { return (report, consumed) }
        if missing {
            report.listing = .missing
        } else if let output, output.utf8.count >= outputCap {
            report.listing = .cut
        } else {
            report.listing = HerdrAgent.listing(output: output ?? "", exit: exit, command: command)
        }
        return (report, consumed)
    }

    /// For MCP's host_sessions and check_host: what the check found, in a sentence; nil while herdr lists its agents.
    public var problem: String? {
        switch listing {
        case .agents: return nil
        case .notRunning(let said): return "herdr is installed but no herdr server answered: \(said)"
        case .needsRestart(let said): return "herdr needs a restart before it can report its agents: \(said)"
        case .failed(let said): return "herdr did not list its agents: \(said)"
        case .cut: return "herdr's answer was cut off"
        case .missing: return "herdr was not found on the host"
        }
    }
}

/// An agent as herdr lists it (`herdr agent list`, or an agent's pane in `herdr pane list`).
public struct HerdrAgent: Equatable, Sendable {
    public enum Status: String, Sendable {
        case idle, working, blocked, done, unknown
    }
    public var paneID: String
    /// The name the user gave it in herdr (`name`), nil when it has none.
    public var customName: String?
    /// What runs in the pane, as herdr names it (`agent`; a pane's `label` before herdr had it): "claude", "codex". The
    /// rules for one kind of agent (its question's reader, Codex's `unknown` at rest) key on it.
    public var kind: String?
    /// The name herdr shows for it (`display_agent`), which naming plugins set through herdr's metadata ("Claude:
    /// auth"); nil when herdr gives none, or only the kind again.
    public var displayName: String?
    public var status: Status
    /// herdr's title for it: its presentation `title` (what naming plugins write), else its terminal's title without
    /// the spinner herdr strips (`terminal_title_stripped`). A `title` that is only the terminal's own is shown stripped.
    public var title: String?
    public var directory: String?
    /// herdr's workspace and tab ids for the pane (`w1`, `w1:t1`), when its list gives them.
    public var workspaceID: String?
    public var tabID: String?
    /// The pane has herdr's focus.
    public var focused: Bool
    /// herdr's count of the agent's state changes (`state_change_seq`), and of its finished turns (`completion_seq`,
    /// herdr 0.9.4 and later): nil when its list has none.
    public var stateSeq: Int?
    public var completionSeq: Int?
    /// herdr is still starting the agent.
    public var launchPending: Bool
    /// The agent's own session herdr keeps a reference to (`agent_session`, herdr 0.6.5 and later), the one place its
    /// transcript is looked for; nil when herdr names none.
    public var session: AgentSessionRef?

    public init(paneID: String, customName: String? = nil, kind: String? = nil, displayName: String? = nil, status: Status,
                title: String? = nil, directory: String? = nil, workspaceID: String? = nil, tabID: String? = nil,
                focused: Bool = false, stateSeq: Int? = nil, completionSeq: Int? = nil, launchPending: Bool = false,
                session: AgentSessionRef? = nil) {
        self.paneID = paneID
        self.customName = customName
        self.kind = kind
        self.displayName = displayName
        self.status = status
        self.title = title
        self.directory = directory
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.focused = focused
        self.stateSeq = stateSeq
        self.completionSeq = completionSeq
        self.launchPending = launchPending
        self.session = session
    }

    /// What the agent is called, as herdr shows it: its display name, else the name it was given, else what runs.
    public var name: String { displayName ?? customName ?? kind ?? "agent" }

    /// The most agents one list gives.
    static let maxAgents = 500

    /// herdr's JSON (`{"result": {"agents": [...]}}`, or the bare result); nil when it lists no agents (an error, or not
    /// herdr's JSON at all). Unknown fields are ignored.
    public static func parseList(_ json: String) -> [HerdrAgent]? {
        guard case .agents(let agents) = listing(output: json) else { return nil }
        return agents
    }

    /// What herdr printed for `herdr <command> list` (`agent`, or `pane` for herdr before 0.5.10), stdout and stderr
    /// together, and its exit status.
    public static func listing(output: String, exit: Int32? = nil, command: String = "agent") -> HerdrListing {
        let text = plain(output)
        if let listing = scan(text, { value, whole in read(value, panes: command == "pane", whole: whole) }) { return listing }
        let said = text.trimmingCharacters(in: .whitespaces)
        let status = exit.map { $0 == 0 ? "" : " (exit \($0))" } ?? ""
        if said.isEmpty { return .failed("herdr printed nothing" + status) }
        let lower = said.lowercased()
        if lower.contains("unknown command") || lower.contains("unrecognized subcommand") {
            return .failed("herdr is older than 0.5.10, which added `herdr agent list`: update herdr on the host to see its agents here")
        }
        // Before 0.8.0, no server was an I/O error on its socket, in Rust's words (`Os { code: 2, kind: NotFound, … }`, or
        // `… (os error 111)`). A shell's own "No such file or directory" (a broken shim's script) is not that.
        let gone = ["kind: notfound", "kind: connectionrefused", "(os error 2)", "(os error 61)", "(os error 111)",
                    "connection refused", "server_not_running"]
        if gone.contains(where: { lower.contains($0) }) { return .notRunning(shown(said)) }
        return .failed(shown(said))
    }

    /// The first of herdr's answers `read` takes in `text` (`plain` already): the whole of it, then from each `{` or `[`
    /// (8 at most) to its matching end, herdr's answer after or before noise. `read` is told whether the value is the
    /// whole text: a bare array counts only as the whole answer, since inside a cut one an array is never the list.
    static func scan<T>(_ text: String, _ read: (Any, Bool) -> T?) -> T? {
        let bytes = Array(text.utf8)
        if let value = json(bytes[...]), let found = read(value, true) { return found }
        var from = 0
        var tries = 0
        while tries < 8, let open = bytes[from...].firstIndex(where: { $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "[") }) {
            tries += 1
            guard let end = matchingEnd(bytes, from: open) else {
                from = open + 1
                continue
            }
            if let value = json(bytes[open...end]) {
                if let found = read(value, false) { return found }
                from = end + 1 // JSON, but not herdr's (a tool's own log line): past it
            } else {
                from = open + 1
            }
        }
        return nil
    }

    /// herdr's answer as one line of text: a byte order mark, colours and other escape sequences, and control
    /// characters out; line breaks and tabs become spaces (JSON reads the same).
    static func plain(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        var pending = scalars.next()
        while let scalar = pending {
            pending = scalars.next()
            switch scalar.value {
            case 0xFEFF:
                continue
            case 0x1B:
                if pending == "[" {
                    // CSI: parameters and intermediates, up to a final byte.
                    pending = scalars.next()
                    while let next = pending, !(0x40...0x7E).contains(next.value) { pending = scalars.next() }
                    pending = scalars.next()
                } else if pending == "]" {
                    // OSC: up to BEL or ESC \.
                    pending = scalars.next()
                    while let next = pending, next.value != 0x07, next.value != 0x1B { pending = scalars.next() }
                    if pending?.value == 0x1B { pending = scalars.next() }
                    pending = scalars.next()
                } else {
                    pending = scalars.next()
                }
            case 0x09, 0x0A, 0x0D:
                kept.append(" ")
            default:
                if !ShellQuote.isControl(scalar) { kept.append(scalar) }
            }
        }
        return String(kept)
    }

    /// A JSON object or array, or nil.
    static func json(_ bytes: ArraySlice<UInt8>) -> Any? {
        guard let first = bytes.first(where: { $0 != 0x20 }), first == UInt8(ascii: "{") || first == UInt8(ascii: "[") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(bytes))
    }

    /// Where the object or array that opens at `open` closes, strings read past; nil when it never does.
    static func matchingEnd(_ bytes: [UInt8], from open: Int) -> Int? {
        var depth = 0
        var inString = false
        var index = open
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if byte == UInt8(ascii: "\\") {
                    index += 1
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
            }
            index += 1
        }
        return nil
    }

    /// herdr's answer, when `value` is one: its agents, or its error. `whole`: `value` is all herdr printed.
    private static func read(_ value: Any, panes: Bool, whole: Bool) -> HerdrListing? {
        if let list = value as? [Any] { return whole ? .agents(agents(from: list, panes: panes)) : nil }
        guard let object = value as? [String: Any] else { return nil }
        if let error = object["error"] {
            let fields = error as? [String: Any]
            let code = fields.flatMap { string($0["code"], max: 80) } ?? ""
            let message = fields.flatMap { string($0["message"], max: 400) } ?? string(error, max: 400) ?? ""
            switch code {
            case "server_not_running": return .notRunning(shown(message.isEmpty ? "no herdr server is running" : message))
            case "protocol_mismatch": return .needsRestart(shown(message.isEmpty ? "the protocols differ" : message))
            default:
                let said = [code, message].filter { !$0.isEmpty }.joined(separator: ": ")
                return .failed(shown(said.isEmpty ? "herdr answered with an error" : said))
            }
        }
        if let result = object["result"] {
            if let list = result as? [Any] { return .agents(agents(from: list, panes: panes)) }
            return (result as? [String: Any]).flatMap(items)
        }
        return items(object)
    }

    /// `agents` (agent list), or `panes` (pane list): the panes with an agent in them.
    private static func items(_ object: [String: Any]) -> HerdrListing? {
        if let list = object["agents"] as? [Any] { return .agents(agents(from: list, panes: false)) }
        if let list = object["panes"] as? [Any] { return .agents(agents(from: list, panes: true)) }
        return nil
    }

    private static func agents(from list: [Any], panes: Bool) -> [HerdrAgent] {
        var found: [HerdrAgent] = []
        for case let item as [String: Any] in list {
            if found.count == maxAgents { break }
            // A pane list names every pane: only those an agent runs in.
            if panes, (string(item["agent"], max: 80) ?? "").isEmpty { continue }
            found.append(agent(item))
        }
        return found
    }

    /// One item, whatever herdr version wrote it: `agent_status` (0.4.5 and later), `agent_state` (0.4.0), or a plain
    /// `status` or `state`; a pane id as text or a number, else the terminal's. Booleans are read as booleans only (a
    /// `"focused": "yes"` is not focus), and the counters as whole numbers.
    private static func agent(_ item: [String: Any]) -> HerdrAgent {
        func first(_ keys: [String], max: Int) -> String? {
            keys.lazy.compactMap { string(item[$0], max: max) }.first { !$0.isEmpty }
        }
        let said = first(["agent_status", "agent_state", "status", "state"], max: 40) ?? ""
        let status = Status(rawValue: said.trimmingCharacters(in: .whitespaces).lowercased()) ?? .unknown
        let kind = first(["agent", "label"], max: 80)
        let shown = first(["display_agent"], max: 80)
        // herdr's presentation title, unless it is only the terminal's raw title, which herdr gives stripped too.
        let presented = first(["title"], max: 80)
        let terminal = first(["terminal_title"], max: 80)
        let title = presented.flatMap { $0 == terminal ? nil : $0 } ?? first(["terminal_title_stripped"], max: 80) ?? presented
        return HerdrAgent(
            paneID: first(["pane_id", "terminal_id"], max: 80) ?? "",
            customName: first(["name"], max: 80),
            kind: kind,
            displayName: shown.flatMap { $0 == kind ? nil : $0 },
            status: status,
            title: title,
            directory: first(["foreground_cwd", "cwd"], max: 1024),
            workspaceID: first(["workspace_id"], max: 80),
            tabID: first(["tab_id"], max: 80),
            focused: boolean(item["focused"]),
            stateSeq: count(item["state_change_seq"]),
            completionSeq: count(item["completion_seq"]),
            launchPending: boolean(item["launch_pending"]),
            session: AgentSessionRef(item["agent_session"])
        )
    }

    /// A JSON boolean; anything else is false.
    static func boolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    /// A JSON whole number of 0 or more (never a boolean), or nil.
    static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let whole = number.int64Value
        guard whole >= 0, Double(whole) == number.doubleValue else { return nil }
        return Int(clamping: whole)
    }

    /// A JSON value as text without control characters, cut at `max`: a string, or a number (never a boolean).
    static func string(_ value: Any?, max: Int) -> String? {
        let text: String
        if let value = value as? String {
            text = value
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            text = number.stringValue
        } else {
            return nil
        }
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter { !ShellQuote.isControl($0) }))
        return String(kept.prefix(max))
    }

    /// What herdr said, for a tooltip or MCP: stored keys masked, then cut at 200 characters.
    static func shown(_ said: String, mask: SecretMask = .current) -> String {
        let masked = mask.mask(String(said.prefix(1000)))
        let cut = masked.prefix(200)
        return cut.count < masked.count ? String(cut) + "…" : String(cut)
    }
}

/// What a herdr tab makes of each status check: herdr's agents while it answers, and a line for the tab's tooltip (and
/// MCP) when it doesn't, after three checks in a row, so one slow answer while herdr starts says nothing. Next Term never
/// restarts, updates or installs herdr: the note says what to do.
public struct HerdrWatch: Equatable, Sendable {
    public static let failuresBeforeNote = 3
    /// herdr's agents as last listed; nil while not known.
    public private(set) var agents: [HerdrAgent]?
    /// The tooltip's line; nil while all is well.
    public private(set) var note: String?
    public private(set) var failures = 0

    public init() {}

    /// Takes one check's report. `showsHerdr`: the tab shows herdr (it did not fall back to a plain shell). Returns the
    /// agents to show when herdr listed them.
    public mutating func observe(_ report: HerdrReport, showsHerdr: Bool) -> [HerdrAgent]? {
        guard showsHerdr else {
            // A tab that fell back is a plain shell. It says so once herdr answers on the host (the user installed it).
            agents = nil
            failures = 0
            switch report.listing {
            case .agents, .notRunning, .needsRestart: note = "herdr is now on the host: open a new herdr tab to use it"
            default: note = nil
            }
            return nil
        }
        switch report.listing {
        case .agents(let list):
            agents = list
            failures = 0
            note = nil
            return list
        case .needsRestart(let said):
            agents = nil
            failures = 0
            note = "herdr needs a restart before it can report its agents: \(said)"
            return nil
        case .notRunning, .failed, .cut, .missing:
            failures += 1
            guard failures >= Self.failuresBeforeNote else { return nil }
            agents = nil
            note = Self.notAnswering(report.listing)
            return nil
        }
    }

    static func notAnswering(_ listing: HerdrListing) -> String {
        switch listing {
        case .notRunning(let said): return "herdr’s list came from a session that isn’t running (\(said))"
        case .failed(let said): return "herdr not answering: \(said)"
        case .cut: return "herdr not answering: its answer was cut off"
        case .missing: return "herdr not answering: the status check didn’t find herdr on the host"
        case .agents, .needsRestart: return "herdr not answering"
        }
    }
}

/// The agent's own session, as herdr keeps a reference to it (`agent_session`): whose store it is in (`source`, `agent`)
/// and an id or a path in it (`kind` "id" or "path", `value`). herdr's words, kept as given.
public struct AgentSessionRef: Equatable, Sendable {
    public var source: String
    public var agent: String
    public var kind: String
    public var value: String

    public init(source: String, agent: String, kind: String, value: String) {
        self.source = source
        self.agent = agent
        self.kind = kind
        self.value = value
    }

    /// herdr's object, or nil without a value in it.
    init?(_ value: Any?) {
        guard let object = value as? [String: Any] else { return nil }
        let text = { (key: String, max: Int) in HerdrAgent.string(object[key], max: max) ?? "" }
        let found = text("value", 1024)
        guard !found.isEmpty else { return nil }
        self.init(source: text("source", 80), agent: text("agent", 80), kind: text("kind", 20), value: found)
    }
}

/// One herdr session a host's status check asks for its agents: nil for herdr's default. `wantsFocus`: one of its tabs is
/// on screen, so the check also asks which herdr tab has the focus when no agent has it. `overview`: asked for a
/// connection that has no herdr tab, on a host kept with herdr, only where herdr already runs or a tab once found it
/// (the finder's cache), so a check never runs a herdr no tab has used.
public struct HerdrPollSession: Equatable, Sendable {
    public var name: String?
    public var wantsFocus: Bool
    public var overview: Bool

    public init(name: String?, wantsFocus: Bool = false, overview: Bool = false) {
        self.name = name
        self.wantsFocus = wantsFocus
        self.overview = overview
    }

    /// The most sessions one check asks: more take turns, check by check.
    public static let perPoll = 4

    /// The sessions a check asks, from the host's herdr tabs (each one's session, and whether it is on screen): each
    /// once, in the tabs' order, wanting the focus when any of its tabs is on screen. Of more than `perPoll`, check
    /// `round` asks the next `perPoll` in turn.
    public static func plan(_ tabs: [(session: String?, onScreen: Bool)], round: Int) -> [HerdrPollSession] {
        var sessions: [HerdrPollSession] = []
        for tab in tabs {
            if let index = sessions.firstIndex(where: { $0.name == tab.session }) {
                if tab.onScreen { sessions[index].wantsFocus = true }
            } else {
                sessions.append(HerdrPollSession(name: tab.session, wantsFocus: tab.onScreen))
            }
        }
        guard sessions.count > perPoll else { return sessions }
        let start = (max(0, round) * perPoll) % sessions.count
        return (0..<perPoll).map { sessions[(start + $0) % sessions.count] }
    }
}

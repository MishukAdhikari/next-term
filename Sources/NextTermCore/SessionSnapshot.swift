import Foundation

// The session snapshot: every window, tab, split and pane, saved so that an update relaunch or a crash
// brings the layout back. The app's SessionRestore writes and reads it; this is the schema and its rules.
//
// The file is untrusted input at launch, so:
// - reading is capped: file size, nesting, window, tab and pane counts, string lengths;
// - an entry that does not read is dropped, not the file (only a bad header refuses it all);
// - a value this version does not know (an agent, a keep mode) reads as `unknown`;
// - the tree is repaired before anything is built from it (repaired()).
// Writing applies the same caps, except that a tree deeper than the cap is flattened, not cut, and
// panesLeftOut(limits:) names any pane a count cap leaves out, so the writer can say so.
//
// Never in it: environment values, the alias-expanded command line, a typed line that failed its checks,
// and program titles (only the title the user gave a tab).

public struct SessionSnapshot: Equatable, Sendable {
    /// The schema's major version, also in the file name, so no version reads a file it cannot. Within one
    /// major version, fields are only ever added.
    public static let schema = 1

    /// The state file's name for a major version: "state-v1.json".
    public static func fileName(schema: Int = SessionSnapshot.schema) -> String { "state-v\(schema).json" }

    public var header: Header
    /// Front to back.
    public var windows: [Window]

    public init(header: Header, windows: [Window] = []) {
        self.header = header
        self.windows = windows
    }

    /// Every pane: window by window, tab by tab, in reading order.
    public var panes: [Pane] { windows.flatMap { $0.groups.flatMap(\.panes) } }

    /// What a normal quit leaves: the header alone, marked clean. A normal launch reads no further.
    public var tombstone: SessionSnapshot {
        var header = self.header
        header.clean = true
        return SessionSnapshot(header: header)
    }
}

// MARK: - The records

extension SessionSnapshot {
    public struct Header: Equatable, Sendable {
        public var schema: Int
        /// The launch that wrote it.
        public var launchID: UUID
        /// Rises with every save, across launches.
        public var generation: Int
        /// Only a normal quit writes it clean; the first save of each launch does not, so a crash leaves it unclean.
        public var clean: Bool
        /// The boot it was written in (kern.bootsessionuuid).
        public var bootSession: String?
        /// The update marker this snapshot waits for: only a marker with this id restores it as an update.
        public var awaitingMarker: UUID?
        /// The version an update was installing when it was written.
        public var pendingToVersion: String?
        public var savedAt: Date

        public init(schema: Int = SessionSnapshot.schema, launchID: UUID, generation: Int, clean: Bool, bootSession: String? = nil,
                    awaitingMarker: UUID? = nil, pendingToVersion: String? = nil, savedAt: Date) {
            self.schema = schema
            self.launchID = launchID
            self.generation = generation
            self.clean = clean
            self.bootSession = bootSession
            self.awaitingMarker = awaitingMarker
            self.pendingToVersion = pendingToVersion
            self.savedAt = savedAt
        }
    }

    /// A window's frame in screen coordinates.
    public struct Frame: Equatable, Sendable, Codable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Window: Equatable, Sendable {
        public var frame: Frame?
        /// The screen it was on, as the app names screens. A frame is used only on a screen that still exists.
        public var screen: String?
        /// The project folder of a project window.
        public var project: String?
        /// Its tabs, in order.
        public var groups: [Group]
        /// The selected tab's index in `groups`.
        public var selected: Int
        public var minimized: Bool
        public var fullScreen: Bool

        public init(frame: Frame? = nil, screen: String? = nil, project: String? = nil, groups: [Group], selected: Int = 0,
                    minimized: Bool = false, fullScreen: Bool = false) {
            self.frame = frame
            self.screen = screen
            self.project = project
            self.groups = groups
            self.selected = selected
            self.minimized = minimized
            self.fullScreen = fullScreen
        }
    }

    /// One tab: its panes as a tree of splits.
    public struct Group: Equatable, Sendable {
        public var root: Node
        /// The pane with the keyboard.
        public var focused: UUID
        /// The pane filling the tab, the others kept behind it.
        public var zoomed: UUID?

        public init(root: Node, focused: UUID, zoomed: UUID? = nil) {
            self.root = root
            self.focused = focused
            self.zoomed = zoomed
        }

        public var panes: [Pane] { root.panes }
    }

    public indirect enum Node: Equatable, Sendable {
        case pane(Pane)
        case split(Split)

        public var panes: [Pane] {
            switch self {
            case .pane(let pane): return [pane]
            case .split(let split): return split.children.flatMap(\.panes)
            }
        }

        func mapPanes(_ transform: (Pane) -> Pane) -> Node {
            switch self {
            case .pane(let pane):
                return .pane(transform(pane))
            case .split(var split):
                split.children = split.children.map { $0.mapPanes(transform) }
                return .split(split)
            }
        }
    }

    public struct Split: Equatable, Sendable {
        /// Side by side (true) or one above the other, as the app's PaneGroup.Split has it.
        public var vertical: Bool
        public var children: [Node]
        /// Where each divider is, as a fraction of the split's length: one fewer than the children.
        public var dividers: [Double]

        /// Without dividers, equal shares.
        public init(vertical: Bool, children: [Node], dividers: [Double]? = nil) {
            self.vertical = vertical
            self.children = children
            self.dividers = dividers ?? Split.evenDividers(count: children.count)
        }

        static func evenDividers(count: Int) -> [Double] {
            guard count > 1 else { return [] }
            return (1..<count).map { Double($0) / Double(count) }
        }
    }

    public struct Pane: Equatable, Sendable {
        /// The tab's id, which MCP clients know it by: it stays the same across the restart.
        public var id: UUID
        /// Its folder (a local pane).
        public var folder: String?
        /// The title the user gave it. Never a program's title, which could hold anything.
        public var userTitle: String?
        /// A tab on a server: the record RemoteConnection keeps for it.
        public var remote: RemoteTabRecord?
        /// The saved record named a keep mode this version does not know. `remote.keep` then reads `.off`,
        /// so the tab can only come back as a fresh connection.
        public var keepIsUnknown = false
        /// The line typed last, and whether it may be put back.
        public var command: Command?
        /// Its state before the restart, as MCP reported it.
        public var stateBefore: PriorState
        /// The restart cut its work off (an agent mid-turn, a command still running).
        public var interrupted: Bool
        /// When the user last selected it: of two panes on one agent session, the later one resumes.
        public var lastSelected: Date
        /// The agent it ran, and how its session is known.
        public var agent: Evidence?
        /// The name of its saved scrollback file: a UUID, resolved only inside the sessions folder.
        public var scrollback: UUID?
        /// What the restore does to it. Until that is applied, every save writes this record unchanged.
        public var pending: PendingAction?
        /// What its note says, as fields: the note renderer turns them into text.
        public var note: Note?
        /// Its saved id was a duplicate, so it has a fresh one.
        public var reminted = false
        /// Its shell was the system /bin/zsh: only there does a typed line go back on the prompt (R9).
        /// Not known reads as false.
        public var systemZsh = false

        public init(id: UUID, folder: String? = nil, userTitle: String? = nil, remote: RemoteTabRecord? = nil, command: Command? = nil,
                    stateBefore: PriorState = .unknown, interrupted: Bool = false, lastSelected: Date = .distantPast,
                    agent: Evidence? = nil, scrollback: UUID? = nil, pending: PendingAction? = nil, note: Note? = nil) {
            self.id = id
            self.folder = folder
            self.userTitle = userTitle
            self.remote = remote
            self.command = command
            self.stateBefore = stateBefore
            self.interrupted = interrupted
            self.lastSelected = lastSelected
            self.agent = agent
            self.scrollback = scrollback
            self.pending = pending
            self.note = note
        }

        /// How a remote pane was kept on its host; nil for a local one.
        public var keep: Keep? {
            guard let remote else { return nil }
            if keepIsUnknown { return .unknown }
            return Keep(rawValue: remote.keep.rawValue) ?? .unknown
        }
    }

    /// The typed line and what its checks found. Only a line that passed every check is kept, so a line
    /// that held a secret, or could not be put back as it ran, never reaches the file.
    public struct Command: Equatable, Sendable {
        /// Lines this long or longer are not put back.
        public static let longest = 4096

        /// The line as typed (never its alias-expanded form); nil unless `check` is `.kept`.
        public private(set) var line: String?
        public private(set) var check: LineCheck
        /// Whether the shell integration reported it typed, with its quoting, or it was polled.
        public var source: LineSource
        /// Still running at save time; otherwise it is the last command, finished.
        public var running: Bool
        public var exitCode: Int32?

        /// `check` is the caller's verdict (the secret detector's among them). A line it calls kept that is
        /// not one short line of plain text is dropped all the same, with the reason.
        public init(line: String?, check: LineCheck, source: LineSource, running: Bool, exitCode: Int32? = nil) {
            self.check = check
            self.source = source
            self.running = running
            self.exitCode = exitCode
            guard check == .kept, let line else { return }
            if let problem = Command.problem(with: line) {
                self.check = problem
            } else {
                self.line = line
            }
        }

        /// From a tab's status: its typed line, never `expandedCommand`.
        public init(status: TabStatus, check: LineCheck) {
            let line: String? = status.command.isEmpty ? nil : status.command
            let source: LineSource = status.integrated ? .integration : .polled
            self.init(line: line, check: check, source: source, running: status.running, exitCode: status.exitCode)
        }

        /// Why a line could not be put back as it ran: more than one line, too long, or holding control,
        /// bidi, zero-width or other invisible characters. Nil for one short line of plain text.
        public static func problem(with line: String) -> LineCheck? {
            let scalars = line.unicodeScalars
            if scalars.contains(where: isLineBreak) { return .multiline }
            if scalars.prefix(longest).count >= longest { return .tooLong }
            if scalars.contains(where: isUnsafe) { return .unsafeCharacters }
            return nil
        }

        static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x0A...0x0D, 0x85, 0x2028, 0x2029: return true
            default: return false
            }
        }

        static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F: return true // C0, DEL, C1
            case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF: return true // zero-width and bidi
            default: break
            }
            // Any other character that shows nothing or changes how text around it shows: format characters,
            // tag letters, soft hyphens, variation selectors, fillers, and noncharacters.
            let properties = scalar.properties
            if properties.generalCategory == .format { return true }
            return properties.isDefaultIgnorableCodePoint || properties.isNoncharacterCodePoint
        }
    }

    /// The agent in a pane, and how its session id is known.
    public struct Evidence: Equatable, Sendable {
        public var agent: Agent
        /// The session id as the agent's resume takes it: ASCII letters, digits and `._:-` only.
        public var sessionID: String?
        public var source: IDSource
        /// The folder the session recorded.
        public var sessionFolder: String?
        /// The agent's executable as it ran, an absolute path. For a script agent, `interpreter` and `script`
        /// say what runs: a resume runs the interpreter on the script, never through the script's shebang.
        public var executable: String?
        /// A script agent's interpreter and the script's real path, both absolute.
        public var interpreter: String?
        public var script: String?
        /// When the agent's process started: a guessed id must be newer, and the agent's project config
        /// must not have changed since. Not known, no check that needs it passes.
        public var startedAt: Date?
        /// When the session was last written, so a note can name it by agent, id and date.
        public var sessionDate: Date?
        /// The agent's provider and config-location variables matched the login shell's when captured.
        /// Compared in memory: no value is saved.
        public var routingMatchesShell: Bool
        /// No auto-continue variable was set for the agent when captured.
        public var autoContinueOff: Bool
        /// The typed line ran as typed: its alias-expanded form was the same line. Compared in memory: the
        /// expanded line is not saved.
        public var ranAsTyped: Bool

        /// Each fact not known reads as the answer that resumes nothing: nil, or false.
        public init(agent: Agent, sessionID: String? = nil, source: IDSource = .guess, sessionFolder: String? = nil,
                    executable: String? = nil, interpreter: String? = nil, script: String? = nil, startedAt: Date? = nil,
                    sessionDate: Date? = nil, routingMatchesShell: Bool = false, autoContinueOff: Bool = false,
                    ranAsTyped: Bool = false) {
            self.agent = agent
            self.sessionID = sessionID
            self.source = source
            self.sessionFolder = sessionFolder
            self.executable = executable
            self.interpreter = interpreter
            self.script = script
            self.startedAt = startedAt
            self.sessionDate = sessionDate
            self.routingMatchesShell = routingMatchesShell
            self.autoContinueOff = autoContinueOff
            self.ranAsTyped = ranAsTyped
        }

        /// An id from agreeing evidence. Anything less is a guess.
        public var isExact: Bool { sessionID != nil && source.isExact }
    }

    /// What the restore does to a pane, and how far it got. Only a record: each launch plans again.
    public struct PendingAction: Equatable, Sendable {
        public var action: Action
        public var state: ActionState
        /// Why the pane was restored.
        public var reason: RestoreKind

        public init(action: Action, state: ActionState = .pending, reason: RestoreKind) {
            self.action = action
            self.state = state
            self.reason = reason
        }
    }

    /// A note's fields. Text is made from them when shown, through the sanitizer.
    public struct Note: Equatable, Sendable {
        public var reason: NoteReason
        /// The command it names: its pane's kept line, and nothing else. A pane writes no other (repaired()).
        public private(set) var command: String?
        public var exitCode: Int32?

        /// `command` is the pane's typed line, and only a line its checks kept is copied. A note on a line
        /// that was not kept names none of it.
        public init(reason: NoteReason, command: Command? = nil, exitCode: Int32? = nil) {
            self.init(reason: reason, line: command?.line, exitCode: exitCode)
        }

        /// As read from a file: the same rules.
        fileprivate init(reason: NoteReason, line: String?, exitCode: Int32?) {
            self.reason = reason
            self.exitCode = exitCode
            guard reason != .notKept, let line, Command.problem(with: line) == nil else { return }
            command = line
        }

        /// The note, its command kept only when it is `line`.
        func naming(only line: String?) -> Self {
            guard command != nil, command != line else { return self }
            var note = self
            note.command = nil
            return note
        }
    }
}

// MARK: - Values

// Each reads anything this version does not know as `unknown`.
extension SessionSnapshot {
    /// The agents the restore knows, by its own names (AgentKind's for the three it shares).
    public enum Agent: String, CaseIterable, Sendable {
        case claude, codex, qwen, copilot, gemini, cursor, opencode, amp, junie, commandCode, kiro, goose, agy, aider, unknown
    }

    /// Where a session id came from.
    public enum IDSource: String, CaseIterable, Sendable {
        /// Claude Code's sessions/<pid>.json for that very process.
        case sessionFile
        /// The rollout file the codex process holds open.
        case openRollout
        /// Qwen Code's chats/<id>.runtime.json with its pid.
        case runtimeFile
        /// COPILOT_AGENT_SESSION_ID in a child of the verified copilot process. A guess all the same: any
        /// command the tab runs can set it.
        case childEnvironment
        /// The typed line and the live process's argv agree on it.
        case typedAndArgv
        /// Anything less, such as the newest session in the folder.
        case guess
        case unknown

        public var isExact: Bool {
            switch self {
            case .sessionFile, .openRollout, .runtimeFile, .typedAndArgv: return true
            case .childEnvironment, .guess, .unknown: return false
            }
        }
    }

    /// KeepMode, plus a mode this version does not know.
    public enum Keep: String, CaseIterable, Sendable {
        case off, tmux, herdr, unknown
    }

    /// A tab's state as MCP reports it.
    public enum PriorState: String, CaseIterable, Sendable {
        case idle, running, working, done, failed, attention, exited, disconnected, connecting, unknown
    }

    public enum LineCheck: String, CaseIterable, Sendable {
        /// Passed every check: it may be put back.
        case kept
        /// The secret detector matched it (typed or expanded).
        case secret
        case multiline
        case tooLong
        /// Control, bidi, zero-width or other invisible characters.
        case unsafeCharacters
        case unknown
    }

    public enum LineSource: String, CaseIterable, Sendable {
        /// The shell integration reported the line as typed.
        case integration
        /// Polled argv: its quoting is lost.
        case polled
        case unknown
    }

    public enum Action: String, CaseIterable, Sendable {
        /// The agent's own resume, once the shell is ready.
        case resume
        /// An agent's original command on the prompt line, unrun.
        case onTheLine
        /// Any other command on the prompt line, unrun.
        case typeIn
        /// Nothing typed: a note only.
        case note
        /// A kept remote tab reattached.
        case reattach
        /// A plain remote tab as a fresh connection.
        case freshConnection
        case unknown
    }

    public enum ActionState: String, CaseIterable, Sendable {
        case pending, applied, cancelled, dismissed, unknown
    }

    public enum RestoreKind: String, CaseIterable, Sendable {
        case update, crash, safeMode, unknown
    }

    public enum NoteReason: String, CaseIterable, Sendable {
        /// An idle tab: its last command and exit code.
        case lastCommand
        /// The line held a secret and was not kept.
        case notKept
        /// The line could not be put back as it ran (not reported typed, more than one line, too long).
        case notTyped
        /// An agent on the line: its session by agent, id and date.
        case agentSession
        /// An agent with no resume of ours, and how to resume it by hand.
        case agentHint
        /// A remote tab reopened fresh: its last command.
        case remote
        /// The folder was gone: the tab opened in the nearest one left.
        case folderMoved
        /// The shell was not ready in time.
        case timedOut
        case unknown
    }
}

// MARK: - Reading and writing

extension SessionSnapshot {
    public struct Limits: Equatable, Sendable {
        /// The whole file.
        public var bytes = 8 << 20
        /// Splits within splits in one tab.
        public var depth = 12
        public var windows = 64
        /// Tabs in one window.
        public var groups = 256
        /// Panes in the whole snapshot.
        public var panes = 512
        /// Folders, projects and executables, in UTF-8 bytes.
        public var path = 4096
        /// Titles, screen names and host fields, in UTF-8 bytes.
        public var text = 1024

        public init() {}

        public static let standard = Limits()

        /// How deep the JSON may nest: a tree `depth` splits deep needs three levels a split, plus the
        /// levels around it, with room to spare so a tree just over the cap loses only what is below it.
        var jsonDepth: Int { depth * 4 + 16 }
        /// Array entries tried in all, divider positions among them: a file of many tiny entries, bad or
        /// unused, cannot make reading slow.
        var entries: Int { panes * 4 + windows + 64 }
    }

    public enum DecodeError: Error, Equatable, Sendable {
        /// Over the size cap: refused before it is read.
        case tooLarge
        /// Nested deeper than any snapshot this version writes.
        case tooDeep
        /// Not JSON, or not a snapshot.
        case unreadable
        /// No header that reads.
        case badHeader
        /// Another major version's file.
        case otherSchema(Int)
    }

    /// Reads a state file, repaired. Only a bad header, the wrong schema or a file over a cap refuses it;
    /// anything else that does not read is left out. `makeID` gives duplicate tab ids their fresh ones.
    public static func decode(_ data: Data, limits: Limits = .standard, makeID: () -> UUID = UUID.init) throws -> SessionSnapshot {
        try read(data, budget: SnapshotBudget(limits)).repaired(limits: limits, makeID: makeID)
    }

    /// The file as it reads, within the caps of `budget`, before any repair.
    static func read(_ data: Data, budget: SnapshotBudget) throws -> SessionSnapshot {
        guard data.count <= budget.limits.bytes else { throw DecodeError.tooLarge }
        guard nesting(of: data, within: budget.limits.jsonDepth) else { throw DecodeError.tooDeep }
        let decoder = JSONDecoder()
        decoder.userInfo[.sessionSnapshotBudget] = budget
        do {
            return try decoder.decode(SessionSnapshot.self, from: data)
        } catch let error as DecodeError {
            throw error
        } catch {
            throw DecodeError.unreadable
        }
    }

    /// The state file's bytes, repaired first, so what is written always reads back as itself. Any pane a
    /// count cap leaves out is in panesLeftOut(limits:).
    public func encoded(limits: Limits = .standard) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(repaired(limits: limits))
    }

    /// Whether no array or object in `data` nests deeper than `limit`. Read without parsing, strings skipped,
    /// so a hostile file is refused before the decoder recurses into it.
    static func nesting(of data: Data, within limit: Int) -> Bool {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var depth = 0
            var inString = false
            var escaped = false
            for byte in bytes {
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == UInt8(ascii: "\\") {
                        escaped = true
                    } else if byte == UInt8(ascii: "\"") {
                        inString = false
                    }
                    continue
                }
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "["), UInt8(ascii: "{"):
                    depth += 1
                    if depth > limit { return false }
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    depth -= 1
                default:
                    break
                }
            }
            return true
        }
    }
}

// MARK: - Repairs

extension SessionSnapshot {
    /// The snapshot with every rule applied: strings over their caps dropped, counts capped, a tree deeper
    /// than the cap flattened at the cap, splits of one collapsed, fractions mended, dangling focus and
    /// selection pointed at the first pane and tab, a dangling zoom (or one on a tab of one pane) cleared,
    /// and duplicate tab ids given fresh ones. Reading applies it, and so does writing.
    public func repaired(limits: Limits = .standard, makeID: () -> UUID = UUID.init) -> SessionSnapshot {
        var result = trimmed(limits: limits)
        result.remintDuplicates(makeID: makeID)
        return result
    }

    /// Every repair but fresh ids.
    func trimmed(limits: Limits) -> SessionSnapshot {
        var budget = limits.panes
        var kept: [Window] = []
        for window in windows.prefix(limits.windows) {
            if let fixed = window.repaired(limits: limits, panes: &budget) { kept.append(fixed) }
        }
        return SessionSnapshot(header: header.repaired(), windows: kept)
    }

    /// The panes that writing leaves out, by id: past the window, tab or pane counts, or a remote pane whose
    /// record cannot be trusted. The writer reports them; a tree too deep loses no pane (it is flattened).
    public func panesLeftOut(limits: Limits = .standard) -> [UUID] {
        var written: [UUID: Int] = [:]
        for pane in trimmed(limits: limits).panes { written[pane.id, default: 0] += 1 }
        var left: [UUID] = []
        for pane in panes {
            if let count = written[pane.id], count > 0 {
                written[pane.id] = count - 1
            } else {
                left.append(pane.id)
            }
        }
        return left
    }

    /// Where entry `index` sits once the entries marked false are gone; nil when it is gone itself.
    static func surviving(_ index: Int, in kept: [Bool]) -> Int? {
        guard kept.indices.contains(index), kept[index] else { return nil }
        return kept[..<index].filter { $0 }.count
    }

    /// The first pane with an id keeps it; a later one gets a fresh id, and focus and zoom follow it.
    mutating func remintDuplicates(makeID: () -> UUID) {
        var taken = Set(panes.map(\.id))
        var seen: Set<UUID> = []
        for window in windows.indices {
            for group in windows[window].groups.indices {
                windows[window].groups[group].remint(seen: &seen, taken: &taken, makeID: makeID)
            }
        }
    }

    static func freshID(taken: inout Set<UUID>, makeID: () -> UUID) -> UUID {
        var id = makeID()
        for _ in 0..<8 where taken.contains(id) { id = makeID() }
        if taken.contains(id) { id = UUID() }
        taken.insert(id)
        return id
    }
}

extension SessionSnapshot.Header {
    func repaired() -> Self {
        var fixed = self
        fixed.generation = max(0, generation)
        fixed.bootSession = SnapshotText.token(bootSession, max: 64, extra: "-")
        fixed.pendingToVersion = SnapshotText.token(pendingToVersion, max: 64, extra: ".+-")
        return fixed
    }
}

extension SessionSnapshot.Frame {
    /// Nil for a frame no screen could show.
    func repaired() -> Self? {
        let values: [Double] = [x, y, width, height]
        guard values.allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }), width > 0, height > 0 else { return nil }
        return self
    }
}

extension SessionSnapshot.Window {
    /// Nil for a window left with no tab and no project.
    func repaired(limits: SessionSnapshot.Limits, panes budget: inout Int) -> Self? {
        var kept: [SessionSnapshot.Group] = []
        var survived: [Bool] = []
        for group in groups.prefix(limits.groups) {
            let fixed = group.repaired(limits: limits, panes: &budget)
            survived.append(fixed != nil)
            if let fixed { kept.append(fixed) }
        }
        let project = SnapshotText.path(self.project, max: limits.path)
        guard !kept.isEmpty || project != nil else { return nil }
        var window = self
        window.frame = frame?.repaired()
        window.screen = SnapshotText.text(screen, max: limits.text)
        window.project = project
        window.groups = kept
        window.selected = SessionSnapshot.surviving(selected, in: survived) ?? 0
        return window
    }
}

extension SessionSnapshot.Group {
    /// Nil when no pane is left, or there is no room for its panes.
    func repaired(limits: SessionSnapshot.Limits, panes budget: inout Int) -> Self? {
        guard let root = root.repaired(limits: limits, depth: 0) else { return nil }
        let ids = root.panes.map(\.id)
        guard let first = ids.first, ids.count <= budget else { return nil }
        budget -= ids.count
        let focus = ids.contains(focused) ? focused : first
        let zoom = zoomed.flatMap { ids.count > 1 && ids.contains($0) ? $0 : nil }
        return Self(root: root, focused: focus, zoomed: zoom)
    }

    mutating func remint(seen: inout Set<UUID>, taken: inout Set<UUID>, makeID: () -> UUID) {
        let before = panes.map(\.id)
        let focusIndex = before.firstIndex(of: focused) ?? 0
        let zoomIndex = zoomed.flatMap { before.firstIndex(of: $0) }
        root = root.mapPanes { (pane: SessionSnapshot.Pane) -> SessionSnapshot.Pane in
            var pane = pane
            if seen.contains(pane.id) {
                pane.id = SessionSnapshot.freshID(taken: &taken, makeID: makeID)
                pane.reminted = true
            }
            seen.insert(pane.id)
            return pane
        }
        let after = panes.map(\.id)
        focused = after[focusIndex]
        zoomed = zoomIndex.map { after[$0] }
    }
}

extension SessionSnapshot.Node {
    /// Nil when nothing readable is left. `depth` counts the splits above this node.
    func repaired(limits: SessionSnapshot.Limits, depth: Int) -> Self? {
        switch self {
        case .pane(let pane):
            return pane.repaired(limits: limits).map(Self.pane)
        case .split(let whole):
            guard depth < limits.depth else { return nil }
            // At the deepest level a split may have, any split below gives its panes to this one. A file never
            // gets here (reading stops at the cap); a tab the app split deeper loses none of its panes.
            let split = depth + 1 < limits.depth ? whole : whole.flattened()
            var children: [Self] = []
            var dropped: [Int] = []
            for (index, child) in split.children.enumerated() {
                if let fixed = child.repaired(limits: limits, depth: depth + 1) {
                    children.append(fixed)
                } else {
                    dropped.append(index)
                }
            }
            // A split of one is just that one.
            guard children.count > 1 else { return children.first }
            let left = SessionSnapshot.Split.removingDividers(split.dividers, for: dropped, children: split.children.count)
            let dividers = SessionSnapshot.Split.repairedDividers(left, count: children.count)
            return .split(SessionSnapshot.Split(vertical: split.vertical, children: children, dividers: dividers))
        }
    }
}

extension SessionSnapshot.Split {
    /// This split with the panes of every split below it as its own children, in order, each pane taking an
    /// equal part of the room its child had.
    func flattened() -> Self {
        let nested = children.contains { (child: SessionSnapshot.Node) -> Bool in
            if case .split = child { return true }
            return false
        }
        guard nested else { return self }
        let room = Self.shares(of: Self.repairedDividers(dividers, count: children.count))
        var panes: [SessionSnapshot.Node] = []
        var edges: [Double] = []
        var position = 0.0
        for (child, share) in zip(children, room) {
            let inside = child.panes
            let each = share / Double(inside.count)
            for pane in inside {
                panes.append(.pane(pane))
                position += each
                edges.append(position)
            }
        }
        return Self(vertical: vertical, children: panes, dividers: Array(edges.dropLast()))
    }

    /// The dividers once the children at `dropped` are gone, each one's room going to its neighbour, as when
    /// the app closes a pane. Left as they are when they did not match the children to begin with.
    static func removingDividers(_ dividers: [Double], for dropped: [Int], children: Int) -> [Double] {
        guard !dropped.isEmpty, dividers.count == children - 1 else { return dividers }
        var result = dividers
        for index in dropped.reversed() where !result.isEmpty {
            result.remove(at: min(index, result.count - 1))
        }
        return result
    }

    /// Divider positions for `count` children. Kept exactly as they are when every child has some room;
    /// otherwise clamped into the split and scaled so each child keeps at least a sliver. Equal shares when
    /// they cannot be read at all (the wrong count, not a number).
    public static func repairedDividers(_ dividers: [Double], count: Int) -> [Double] {
        let even = evenDividers(count: count)
        guard count > 1, dividers.count == count - 1, dividers.allSatisfy({ $0.isFinite }) else { return even }
        let least = min(0.01, 0.5 / Double(count))
        if shares(of: dividers).allSatisfy({ $0 >= least / 2 }) { return dividers }
        let clamped: [Double] = dividers.map { min(max($0, 0), 1) }
        let room: [Double] = shares(of: clamped).map { max($0, 0) }
        let total = room.reduce(0, +)
        guard total > 0 else { return even }
        let spare = 1 - least * Double(count)
        var position = 0.0
        var result: [Double] = []
        for share in room.dropLast() {
            position += least + spare * share / total
            result.append(position)
        }
        return result
    }

    /// Each child's part of the length, from the divider positions.
    private static func shares(of dividers: [Double]) -> [Double] {
        let edges: [Double] = [0] + dividers + [1]
        return (1..<edges.count).map { (index: Int) -> Double in edges[index] - edges[index - 1] }
    }
}

extension SessionSnapshot.Pane {
    /// Nil for a remote pane whose record cannot be trusted: it must not come back as a local one.
    func repaired(limits: SessionSnapshot.Limits) -> Self? {
        var pane = self
        if let remote {
            guard let fixed = Self.repaired(remote, limits: limits) else { return nil }
            pane.remote = fixed
        } else {
            pane.keepIsUnknown = false
        }
        pane.folder = SnapshotText.path(folder, max: limits.path)
        pane.userTitle = SnapshotText.text(userTitle, max: limits.text)
        pane.agent = agent?.repaired(limits: limits)
        // A note names the pane's own kept line or nothing, so a line that failed its checks never gets in.
        pane.note = note?.naming(only: command?.line)
        return pane
    }

    /// The host fields are what tell a re-pointed host, so they must read whole.
    static func repaired(_ record: RemoteTabRecord, limits: SessionSnapshot.Limits) -> RemoteTabRecord? {
        guard SnapshotText.text(record.hostID, max: limits.text) != nil, record.directory.utf8.count <= limits.path,
              record.session.utf8.count <= limits.text else { return nil }
        if let destination = record.destination, SnapshotText.text(destination, max: limits.text) == nil { return nil }
        if let port = record.port, !(1...65535).contains(port) { return nil }
        var fixed = record
        fixed.project = SnapshotText.path(record.project, max: limits.path)
        fixed.title = SnapshotText.text(record.title, max: limits.text)
        return fixed
    }
}

extension SessionSnapshot.Evidence {
    func repaired(limits: SessionSnapshot.Limits) -> Self {
        var fixed = self
        fixed.sessionID = SnapshotText.token(sessionID, max: 128, extra: "._:-")
        fixed.sessionFolder = SnapshotText.plainPath(sessionFolder, max: limits.path)
        fixed.executable = SnapshotText.plainPath(executable, max: limits.path)
        fixed.interpreter = SnapshotText.plainPath(interpreter, max: limits.path)
        fixed.script = SnapshotText.plainPath(script, max: limits.path)
        return fixed
    }
}

/// The string rules: a value that breaks one is dropped, never cut.
enum SnapshotText {
    static func text(_ value: String?, max: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= max else { return nil }
        return value
    }

    static func path(_ value: String?, max: Int) -> String? {
        guard let value = text(value, max: max), value.hasPrefix("/") else { return nil }
        return value
    }

    /// A path the restore runs or resumes in: one line with no control, bidi or other invisible character,
    /// so the path that is checked is the one that runs. (A tab's own folder keeps the plain rule.)
    static func plainPath(_ value: String?, max: Int) -> String? {
        guard let value = path(value, max: max) else { return nil }
        let unsafe = value.unicodeScalars.contains { (scalar: Unicode.Scalar) -> Bool in
            SessionSnapshot.Command.isLineBreak(scalar) || SessionSnapshot.Command.isUnsafe(scalar)
        }
        return unsafe ? nil : value
    }

    /// ASCII letters and digits, plus the characters in `extra`.
    static func token(_ value: String?, max: Int, extra: String) -> String? {
        guard let value = text(value, max: max) else { return nil }
        let allowed = Set(extra.utf8)
        return value.utf8.allSatisfy({ isAlphanumeric($0) || allowed.contains($0) }) ? value : nil
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"):
            return true
        default:
            return false
        }
    }
}

// MARK: - Coding

/// What one read of a file may still take: array entries tried, and panes kept.
final class SnapshotBudget: @unchecked Sendable {
    let limits: SessionSnapshot.Limits
    private(set) var entries: Int
    private(set) var panes: Int

    init(_ limits: SessionSnapshot.Limits) {
        self.limits = limits
        entries = limits.entries
        panes = limits.panes
    }

    func takeEntry() -> Bool {
        guard entries > 0 else { return false }
        entries -= 1
        return true
    }

    func takePane() -> Bool {
        guard panes > 0 else { return false }
        panes -= 1
        return true
    }
}

extension CodingUserInfoKey {
    fileprivate static let sessionSnapshotBudget = CodingUserInfoKey(rawValue: "NextTerm.SessionSnapshot.budget")!
}

extension Decoder {
    fileprivate var snapshotBudget: SnapshotBudget? { userInfo[.sessionSnapshotBudget] as? SnapshotBudget }
}

/// An entry that may not read: its value is nil then, and the list reads on.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Times as whole milliseconds since 1970: they read back exactly, so an unchanged record saves unchanged.
private enum Millis {
    static func of(_ date: Date) -> Int64 {
        let millis = (date.timeIntervalSince1970 * 1000).rounded()
        guard millis.isFinite else { return 0 }
        return Int64(min(max(millis, -9e15), 9e15))
    }

    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}

extension UUID {
    /// As MCP shows tab ids.
    fileprivate var lowercased: String { uuidString.lowercased() }
}

extension KeyedDecodingContainer {
    /// Nil when missing or of another type.
    fileprivate func optional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    fileprivate func flag(_ key: Key) -> Bool { optional(Bool.self, key) ?? false }

    fileprivate func uuid(_ key: Key) -> UUID? { optional(String.self, key).flatMap(UUID.init(uuidString:)) }

    fileprivate func date(_ key: Key) -> Date? { optional(Int64.self, key).map(Millis.date) }

    /// `fallback` when missing, of another type, or a value this version does not know.
    fileprivate func value<T: RawRepresentable>(_ key: Key, or fallback: T) -> T where T.RawValue == String {
        optional(String.self, key).flatMap(T.init(rawValue:)) ?? fallback
    }

    /// A list read entry by entry: one that does not read is nil, so the caller knows where it was. Reading
    /// stops after `max` entries, or when the file's budget runs out.
    fileprivate func entries<T: Decodable>(_ type: T.Type, _ key: Key, max: Int, budget: SnapshotBudget?) -> [T?] {
        guard var list = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var read: [T?] = []
        while !list.isAtEnd && read.count < max {
            if let budget, !budget.takeEntry() { break }
            guard let entry = try? list.decode(Lossy<T>.self) else { break }
            read.append(entry.value)
        }
        return read
    }

    /// A list of numbers read one by one, at most `max` of them, within the file's budget. Nil when it is
    /// not a list, an entry is not a number, or the budget runs out.
    fileprivate func numbers(_ key: Key, max: Int, budget: SnapshotBudget?) -> [Double]? {
        guard var list = try? nestedUnkeyedContainer(forKey: key) else { return nil }
        var read: [Double] = []
        while !list.isAtEnd && read.count < max {
            if let budget, !budget.takeEntry() { return nil }
            guard let number = try? list.decode(Double.self) else { return nil }
            read.append(number)
        }
        return read
    }
}

extension SessionSnapshot: Codable {
    private enum Keys: String, CodingKey { case header, windows }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let header = try? c.decode(Header.self, forKey: .header) else { throw DecodeError.badHeader }
        guard header.schema == Self.schema else { throw DecodeError.otherSchema(header.schema) }
        let budget = decoder.snapshotBudget
        let windows = c.entries(Window.self, .windows, max: budget?.limits.windows ?? Limits.standard.windows, budget: budget)
        self.init(header: header, windows: windows.compactMap { $0 })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(header, forKey: .header)
        if !windows.isEmpty { try c.encode(windows, forKey: .windows) }
    }
}

extension SessionSnapshot.Header: Codable {
    private enum Keys: String, CodingKey {
        case schema, launchID, generation, clean, bootSession, awaitingMarker, pendingToVersion, savedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let launchID = c.uuid(.launchID) else { throw SessionSnapshot.DecodeError.badHeader }
        let generation = try c.decode(Int.self, forKey: .generation)
        guard generation >= 0 else { throw SessionSnapshot.DecodeError.badHeader }
        let schema = try c.decode(Int.self, forKey: .schema)
        let clean = try c.decode(Bool.self, forKey: .clean)
        let savedAt = Millis.date(try c.decode(Int64.self, forKey: .savedAt))
        self.init(schema: schema, launchID: launchID, generation: generation, clean: clean, savedAt: savedAt)
        bootSession = c.optional(String.self, .bootSession)
        awaitingMarker = c.uuid(.awaitingMarker)
        pendingToVersion = c.optional(String.self, .pendingToVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(launchID.lowercased, forKey: .launchID)
        try c.encode(generation, forKey: .generation)
        try c.encode(clean, forKey: .clean)
        try c.encodeIfPresent(bootSession, forKey: .bootSession)
        try c.encodeIfPresent(awaitingMarker?.lowercased, forKey: .awaitingMarker)
        try c.encodeIfPresent(pendingToVersion, forKey: .pendingToVersion)
        try c.encode(Millis.of(savedAt), forKey: .savedAt)
    }
}

extension SessionSnapshot.Window: Codable {
    private enum Keys: String, CodingKey { case frame, screen, project, groups, selected, minimized, fullScreen }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let budget = decoder.snapshotBudget
        let most = budget?.limits.groups ?? SessionSnapshot.Limits.standard.groups
        let read = c.entries(SessionSnapshot.Group.self, .groups, max: most, budget: budget)
        let survived: [Bool] = read.map { $0 != nil }
        self.init(groups: read.compactMap { $0 })
        selected = SessionSnapshot.surviving(c.optional(Int.self, .selected) ?? 0, in: survived) ?? 0
        frame = c.optional(SessionSnapshot.Frame.self, .frame)
        screen = c.optional(String.self, .screen)
        project = c.optional(String.self, .project)
        minimized = c.flag(.minimized)
        fullScreen = c.flag(.fullScreen)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(frame, forKey: .frame)
        try c.encodeIfPresent(screen, forKey: .screen)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encode(groups, forKey: .groups)
        try c.encode(selected, forKey: .selected)
        try c.encode(minimized, forKey: .minimized)
        try c.encode(fullScreen, forKey: .fullScreen)
    }
}

extension SessionSnapshot.Group: Codable {
    private enum Keys: String, CodingKey { case root, focused, zoomed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let root = try c.decode(SessionSnapshot.Node.self, forKey: .root)
        guard let first = root.panes.first else { throw SessionSnapshot.DecodeError.unreadable }
        self.init(root: root, focused: c.uuid(.focused) ?? first.id, zoomed: c.uuid(.zoomed))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(root, forKey: .root)
        try c.encode(focused.lowercased, forKey: .focused)
        try c.encodeIfPresent(zoomed?.lowercased, forKey: .zoomed)
    }
}

extension SessionSnapshot.Node: Codable {
    private enum Keys: String, CodingKey { case pane, split }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if c.contains(.pane) {
            self = .pane(try c.decode(SessionSnapshot.Pane.self, forKey: .pane))
            return
        }
        // The splits above this one, from where the decoder is in the file.
        let above = decoder.codingPath.filter { $0.stringValue == Keys.split.stringValue }.count
        guard above < decoder.snapshotBudget?.limits.depth ?? SessionSnapshot.Limits.standard.depth else {
            throw SessionSnapshot.DecodeError.tooDeep
        }
        self = .split(try c.decode(SessionSnapshot.Split.self, forKey: .split))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .pane(let pane): try c.encode(pane, forKey: .pane)
        case .split(let split): try c.encode(split, forKey: .split)
        }
    }
}

extension SessionSnapshot.Split: Codable {
    private enum Keys: String, CodingKey { case vertical, children, dividers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let budget = decoder.snapshotBudget
        let most = budget?.limits.panes ?? SessionSnapshot.Limits.standard.panes
        let read = c.entries(SessionSnapshot.Node.self, .children, max: most, budget: budget)
        let children = read.compactMap { $0 }
        guard !children.isEmpty else { throw SessionSnapshot.DecodeError.unreadable }
        let dropped = read.indices.filter { read[$0] == nil }
        // One more than they need at most: a list longer than that reads as the wrong count all the same.
        let saved = c.numbers(.dividers, max: read.count, budget: budget) ?? []
        let dividers = Self.removingDividers(saved, for: dropped, children: read.count)
        self.init(vertical: c.flag(.vertical), children: children, dividers: dividers)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(vertical, forKey: .vertical)
        try c.encode(children, forKey: .children)
        try c.encode(dividers, forKey: .dividers)
    }
}

extension SessionSnapshot.Pane: Codable {
    private enum Keys: String, CodingKey {
        case id, folder, userTitle, remote, command, stateBefore, interrupted, lastSelected, agent, scrollback, pending, note, reminted
        case systemZsh
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let id = c.uuid(.id) else { throw SessionSnapshot.DecodeError.unreadable }
        self.init(id: id, folder: c.optional(String.self, .folder), userTitle: c.optional(String.self, .userTitle))
        if c.contains(.remote) {
            // RemoteConnection's own record; only a keep mode this version does not know is read apart.
            if let record = try? c.decode(RemoteTabRecord.self, forKey: .remote) {
                remote = record
            } else {
                remote = try c.decode(UnknownKeepRemote.self, forKey: .remote).record
                keepIsUnknown = true
            }
        }
        command = c.optional(SessionSnapshot.Command.self, .command)
        stateBefore = c.value(.stateBefore, or: .unknown)
        interrupted = c.flag(.interrupted)
        lastSelected = c.date(.lastSelected) ?? .distantPast
        agent = c.optional(SessionSnapshot.Evidence.self, .agent)
        scrollback = c.uuid(.scrollback)
        pending = c.optional(SessionSnapshot.PendingAction.self, .pending)
        note = c.optional(SessionSnapshot.Note.self, .note)
        reminted = c.flag(.reminted)
        systemZsh = c.flag(.systemZsh)
        if let budget = decoder.snapshotBudget, !budget.takePane() { throw SessionSnapshot.DecodeError.tooLarge }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id.lowercased, forKey: .id)
        try c.encodeIfPresent(folder, forKey: .folder)
        try c.encodeIfPresent(userTitle, forKey: .userTitle)
        if let remote {
            if keepIsUnknown {
                try c.encode(UnknownKeepRemote(record: remote), forKey: .remote)
            } else {
                try c.encode(remote, forKey: .remote)
            }
        }
        try c.encodeIfPresent(command, forKey: .command)
        try c.encode(stateBefore.rawValue, forKey: .stateBefore)
        try c.encode(interrupted, forKey: .interrupted)
        try c.encode(Millis.of(lastSelected), forKey: .lastSelected)
        try c.encodeIfPresent(agent, forKey: .agent)
        try c.encodeIfPresent(scrollback?.lowercased, forKey: .scrollback)
        try c.encodeIfPresent(pending, forKey: .pending)
        try c.encodeIfPresent(note, forKey: .note)
        if reminted { try c.encode(true, forKey: .reminted) }
        try c.encode(systemZsh, forKey: .systemZsh)
    }
}

/// A RemoteTabRecord whose keep mode this version does not know: the record's own keys, the mode read as
/// text and written back as "unknown". The record itself holds `.off`.
private struct UnknownKeepRemote: Codable {
    var record: RemoteTabRecord

    private enum Keys: String, CodingKey { case hostID, destination, port, directory, session, keep, project, title }

    init(record: RemoteTabRecord) {
        self.record = record
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        // A known mode means the record failed to read for another reason.
        let keep = try c.decodeIfPresent(String.self, forKey: .keep)
        guard keep.flatMap(KeepMode.init(rawValue:)) == nil else { throw SessionSnapshot.DecodeError.unreadable }
        let hostID = try c.decode(String.self, forKey: .hostID)
        let directory = try c.decode(String.self, forKey: .directory)
        let session = try c.decode(String.self, forKey: .session)
        let destination = try c.decodeIfPresent(String.self, forKey: .destination)
        let port = try c.decodeIfPresent(Int.self, forKey: .port)
        record = RemoteTabRecord(hostID: hostID, destination: destination, port: port, directory: directory, session: session, keep: .off,
                                 project: c.optional(String.self, .project), title: c.optional(String.self, .title))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(record.hostID, forKey: .hostID)
        try c.encodeIfPresent(record.destination, forKey: .destination)
        try c.encodeIfPresent(record.port, forKey: .port)
        try c.encode(record.directory, forKey: .directory)
        try c.encode(record.session, forKey: .session)
        try c.encode(SessionSnapshot.Keep.unknown.rawValue, forKey: .keep)
        try c.encodeIfPresent(record.project, forKey: .project)
        try c.encodeIfPresent(record.title, forKey: .title)
    }
}

extension SessionSnapshot.Command: Codable {
    private enum Keys: String, CodingKey { case line, check, source, running, exitCode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let check: SessionSnapshot.LineCheck = c.value(.check, or: .unknown)
        let source: SessionSnapshot.LineSource = c.value(.source, or: .unknown)
        self.init(line: c.optional(String.self, .line), check: check, source: source, running: c.flag(.running),
                  exitCode: c.optional(Int32.self, .exitCode))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(line, forKey: .line)
        try c.encode(check.rawValue, forKey: .check)
        try c.encode(source.rawValue, forKey: .source)
        try c.encode(running, forKey: .running)
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
    }
}

extension SessionSnapshot.Evidence: Codable {
    private enum Keys: String, CodingKey {
        case agent, sessionID, source, sessionFolder, executable, interpreter, script, startedAt, sessionDate, routingMatchesShell
        case autoContinueOff, ranAsTyped
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(agent: c.value(.agent, or: .unknown), source: c.value(.source, or: .unknown))
        sessionID = c.optional(String.self, .sessionID)
        sessionFolder = c.optional(String.self, .sessionFolder)
        executable = c.optional(String.self, .executable)
        interpreter = c.optional(String.self, .interpreter)
        script = c.optional(String.self, .script)
        startedAt = c.date(.startedAt)
        sessionDate = c.date(.sessionDate)
        routingMatchesShell = c.flag(.routingMatchesShell)
        autoContinueOff = c.flag(.autoContinueOff)
        ranAsTyped = c.flag(.ranAsTyped)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(agent.rawValue, forKey: .agent)
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        try c.encode(source.rawValue, forKey: .source)
        try c.encodeIfPresent(sessionFolder, forKey: .sessionFolder)
        try c.encodeIfPresent(executable, forKey: .executable)
        try c.encodeIfPresent(interpreter, forKey: .interpreter)
        try c.encodeIfPresent(script, forKey: .script)
        try c.encodeIfPresent(startedAt.map(Millis.of), forKey: .startedAt)
        try c.encodeIfPresent(sessionDate.map(Millis.of), forKey: .sessionDate)
        try c.encode(routingMatchesShell, forKey: .routingMatchesShell)
        try c.encode(autoContinueOff, forKey: .autoContinueOff)
        try c.encode(ranAsTyped, forKey: .ranAsTyped)
    }
}

extension SessionSnapshot.PendingAction: Codable {
    private enum Keys: String, CodingKey { case action, state, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(action: c.value(.action, or: .unknown), state: c.value(.state, or: .unknown), reason: c.value(.reason, or: .unknown))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(action.rawValue, forKey: .action)
        try c.encode(state.rawValue, forKey: .state)
        try c.encode(reason.rawValue, forKey: .reason)
    }
}

extension SessionSnapshot.Note: Codable {
    private enum Keys: String, CodingKey { case reason, command, exitCode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(reason: c.value(.reason, or: .unknown), line: c.optional(String.self, .command),
                  exitCode: c.optional(Int32.self, .exitCode))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(reason.rawValue, forKey: .reason)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
    }
}

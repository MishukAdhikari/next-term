import CryptoKit
import Foundation
import SQLite3

/// One agent's session store: where the agent keeps its conversations, and how to read one folder's out
/// of it without reading a transcript whole. Each stands alone, so one that throws (its format changed)
/// only leaves its agent out of a listing.
public protocol AgentSessionProvider {
    var agent: AgentKind { get }
    /// The sessions started in `folder` (with `subfolders`, in the folders inside it too), in any order.
    /// `since`: only sessions written to since then are wanted, so older files can be skipped unread.
    func sessions(in folder: String, subfolders: Bool, since: Date?) throws -> [AgentSession]
}

extension AgentKind {
    /// The reader of this agent's store in `home`.
    public func provider(home: String) -> any AgentSessionProvider {
        switch self {
        case .claude: return ClaudeSessions(home: home)
        case .codex: return CodexSessions(home: home)
        case .commandCode: return CommandCodeSessions(home: home)
        case .gemini: return GeminiSessions(home: home)
        case .qwen: return QwenSessions(home: home)
        case .opencode: return OpencodeSessions(home: home)
        case .cursor: return CursorSessions(home: home)
        case .copilot: return CopilotSessions(home: home)
        }
    }

    /// A name short enough for a filter button: "Claude", "Gemini", "Copilot".
    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .qwen: return "Qwen"
        case .cursor: return "Cursor"
        case .copilot: return "Copilot"
        case .codex, .commandCode, .opencode: return name
        }
    }

    /// The agent can continue a copy of a session, leaving the original as it was. Gemini CLI, Cursor
    /// Agent and Copilot CLI cannot from the command line.
    public var canFork: Bool {
        switch self {
        case .claude, .codex, .commandCode, .qwen, .opencode: return true
        case .gemini, .cursor, .copilot: return false
        }
    }

    /// The command line that picks session `id` up again, typed into a shell in `cwd`. Gemini CLI, Cursor
    /// Agent and Command Code look sessions up in the folder they run in, so it must be that one.
    func resumeCommand(id: String, cwd: String, fork: Bool) -> String {
        let quoted = ShellQuote.quote(id)
        let fork = fork && canFork
        switch self {
        case .claude: return "claude --resume \(quoted)" + (fork ? " --fork-session" : "")
        case .codex: return (fork ? "codex fork " : "codex resume ") + quoted + " -C " + ShellQuote.quote(cwd)
        case .commandCode: return "command-code --resume \(quoted)" + (fork ? " --fork-session" : "")
        case .gemini: return "gemini --resume \(quoted)"
        case .qwen: return "qwen --resume \(quoted)" + (fork ? " --fork-session" : "")
        case .opencode: return "opencode --session \(quoted)" + (fork ? " --fork" : "")
        case .cursor: return "cursor-agent --resume=\(quoted)"
        case .copilot: return "copilot --resume=\(quoted)"
        }
    }

    /// The command line that picks up the agent's latest session in the folder it is typed in.
    public var continueCommand: String {
        switch self {
        case .claude: return "claude --continue"
        case .codex: return "codex resume --last"
        case .commandCode: return "command-code --continue"
        case .gemini: return "gemini --resume latest"
        case .qwen: return "qwen --continue"
        case .opencode: return "opencode --continue"
        case .cursor: return "cursor-agent resume"
        case .copilot: return "copilot --continue"
        }
    }

    /// The agent a tab runs, from the program name it worked out (`CommandClassifier.programName`).
    public init?(program: String) {
        switch program {
        case "claude", "claude-code", "claude.exe": self = .claude
        case "codex": self = .codex
        case "command-code", "commandcode", "cmd": self = .commandCode
        case "gemini", "gemini-cli": self = .gemini
        case "qwen", "qwen-code": self = .qwen
        case "opencode": self = .opencode
        case "cursor-agent": self = .cursor
        case "copilot": self = .copilot
        default: return nil
        }
    }

    /// The options that name the session to resume (`--resume <id>`, `--resume=<id>`).
    private var idOptions: [String] {
        switch self {
        case .claude, .gemini, .qwen, .copilot: return ["--resume", "-r", "--session-id"]
        case .commandCode: return ["--resume", "-r", "--session"]
        case .opencode: return ["--session", "-s"]
        case .cursor: return ["--resume"]
        case .codex: return []
        }
    }

    /// The session a command line resumes by id (`claude --resume <id>`, `codex resume <id>`,
    /// `opencode -s <id>`), or nil: a new session, the latest one, a picker, a fork (which gets an id of
    /// its own), or a name or search term (`claude --resume "my feature"`).
    public func resumedID(in commandLine: String) -> String? {
        for segment in CommandClassifier.segments(commandLine) {
            let words = Self.words(segment)
            // The program is the first word that is not an option, an assignment or a wrapper (`npx`).
            guard let at = words.firstIndex(where: { !CommandClassifier.parse($0).name.isEmpty }),
                  AgentKind(program: CommandClassifier.parse(words[at]).name) == self else { continue }
            let args = Array(words[(at + 1)...])
            guard var id = self == .codex ? Self.codexResumed(args) : resumedID(args) else { return nil }
            // Gemini CLI takes "latest" and a number (its list's order) too: neither names one session.
            if self == .gemini, id == "latest" || Int(id) != nil { return nil }
            // `command-code --session <path to the transcript>`.
            if id.hasSuffix(".jsonl") { id = String((id as NSString).lastPathComponent.dropLast(6)) }
            return isID(id) ? id : nil
        }
        return nil
    }

    /// Shaped like a session id: no spaces, and for Claude Code (whose ids are all UUIDs) a UUID.
    private func isID(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return false }
        return self != .claude || UUID(uuidString: value) != nil
    }

    private func resumedID(_ args: [String]) -> String? {
        if args.contains("--fork-session") || args.contains("--fork") { return nil }
        for (index, arg) in args.enumerated() {
            for option in idOptions {
                if arg.hasPrefix(option + "=") { return String(arg.dropFirst(option.count + 1)) }
                if arg == option, index + 1 < args.count, !args[index + 1].hasPrefix("-") { return args[index + 1] }
            }
        }
        return nil
    }

    /// `codex resume <id>`, its options anywhere around the id.
    private static func codexResumed(_ args: [String]) -> String? {
        guard args.first == "resume", !args.contains("--last") else { return nil }
        let valued: Set<String> = ["-C", "--cd", "-m", "--model", "-c", "--config", "-p", "--profile", "-s", "--sandbox",
                                   "-a", "--ask-for-approval", "-i", "--image", "--add-dir"]
        var index = 1
        while index < args.count {
            let arg = args[index]
            if valued.contains(arg) {
                index += 2
                continue
            }
            if !arg.hasPrefix("-") { return arg }
            index += 1
        }
        return nil
    }

    /// The words of a simple command as the shell splits them: a quoted part keeps its spaces and loses its
    /// quotes, and outside single quotes a backslash keeps the next character as it is.
    static func words(_ command: String) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for ch in command {
            if escaped {
                word.append(ch)
                escaped = false
            } else if ch == "\\" && quote != "'" {
                escaped = true
                inWord = true
            } else if let open = quote {
                if ch == open { quote = nil } else { word.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch
                inWord = true
            } else if ch == " " || ch == "\t" {
                if inWord { words.append(word) }
                word = ""
                inWord = false
            } else {
                word.append(ch)
                inWord = true
            }
        }
        if inWord { words.append(word) }
        return words
    }
}

/// An agent running in a tab, as the tab saw it start.
public struct RunningAgent: Sendable, Equatable {
    /// What the caller finds the tab by again.
    public let key: String
    public let agent: AgentKind
    /// The folder it runs in.
    public let directory: String
    /// The command line as typed (with its expansion after it, when an alias was expanded).
    public let commandLine: String
    public let startedAt: Date
    /// The agent's process, when it is known: Claude Code and Copilot CLI record which session a process
    /// has open.
    public let pid: Int32?

    public init(key: String, agent: AgentKind, directory: String, commandLine: String, startedAt: Date, pid: Int32? = nil) {
        self.key = key
        self.agent = agent
        self.directory = directory
        self.commandLine = commandLine
        self.startedAt = startedAt
        self.pid = pid
    }
}

extension AgentSessions {
    /// The newest session `agent` has started in `folder` (exactly that folder) at or after `time`, ids in
    /// `excluding` left out, or nil when there is none: what a tab that started that agent at `time`
    /// without naming a session is in now. Newest means started last; a session the agent went on to
    /// (`/clear` starts one) counts.
    ///
    /// Time alone cannot tell two tabs that run one agent in one folder apart: both get the same answer.
    /// Ask `sessionID(of:pid:)` first, and pass the ids other tabs already have as `excluding`, so no
    /// session is taken up twice.
    ///
    /// Cheap: it reads only stores written to since `time` (files older than that are skipped unread), and
    /// of those only what a listing reads (the first and last 64 KiB of a transcript, an index row), never
    /// a whole transcript. Sessions a listing hides (sub-agents', `claude -p` runs, ones with no prompt
    /// yet) are not returned. Never throws: a store it cannot read gives nil.
    public static func newest(agent: AgentKind, in folder: String, after time: Date, excluding ids: Set<String> = [],
                              home: String = NSHomeDirectory()) -> AgentSession? {
        let found = (try? agent.provider(home: home).sessions(in: canonicalPath(folder), subfolders: false, since: time)) ?? []
        return found.filter { startTime($0) >= time && !ids.contains($0.id) }.max { startTime($0) < startTime($1) }
    }

    /// The session a live agent process has open, from the agent's own record of it: Claude Code's
    /// ~/.claude/sessions/<pid>.json (which it keeps up to date through `/clear` and `/resume`), and the
    /// Copilot CLI session folder that holds `inuse.<pid>.lock`. nil for the other agents, and when there
    /// is no record.
    public static func sessionID(of agent: AgentKind, pid: Int32, home: String = NSHomeDirectory()) -> String? {
        switch agent {
        case .claude: return claudeSessionID(pid: pid, home: home)
        case .copilot: return CopilotSessions.sessionID(pid: pid, home: home)
        case .codex, .commandCode, .gemini, .qwen, .opencode, .cursor: return nil
        }
    }

    /// The session the `claude` with process `pid` has open: the `sessionId` of its
    /// ~/.claude/sessions/<pid>.json (the file `claudeRunning` reads).
    static func claudeSessionID(pid: Int32, home: String) -> String? {
        let path = (home as NSString).appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = readHead(path, bytes: 16384),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["sessionId"] as? String
    }

    private static func startTime(_ session: AgentSession) -> Date { session.createdAt ?? session.updatedAt }

    /// Which sessions are open in which tab: session identity (`AgentSession.identity`) → the tab's key.
    /// The agent's record of what its process has open decides (`sessionID(of:pid:)`); else a resume
    /// command names its session (`claude --resume <id>`); else the tab is guessed by time (`guess`).
    public static func openSessions(_ running: [RunningAgent], home: String = NSHomeDirectory()) -> [String: String] {
        var open: [String: String] = [:]
        var unnamed: [RunningAgent] = []
        for tab in running {
            let recorded = tab.pid.flatMap { sessionID(of: tab.agent, pid: $0, home: home) }
            if let id = recorded ?? tab.agent.resumedID(in: tab.commandLine) {
                open[tab.agent.rawValue + ":" + id] = tab.key
            } else {
                unnamed.append(tab)
            }
        }
        for tab in unnamed {
            if let session = guess(tab, among: running, taken: open, home: home) { open[session.identity] = tab.key }
        }
        return open
    }

    /// The session a tab whose agent named none is in: the newest its folder has had since the agent
    /// started, or else (`claude --continue`) the one written to most recently since then. Time cannot tell
    /// two tabs of one agent in one folder apart, so a session another of them could have started or
    /// written to is left out, as is one an agent process elsewhere has open: better no tab than the
    /// wrong one.
    private static func guess(_ tab: RunningAgent, among running: [RunningAgent], taken: [String: String], home: String) -> AgentSession? {
        let folder = canonicalPath(tab.directory)
        let rivals = running.filter { $0.key != tab.key && $0.agent == tab.agent && canonicalPath($0.directory) == folder }
        func onlyMine(_ date: Date) -> Bool { !rivals.contains { $0.startedAt <= date } }
        let found = (try? tab.agent.provider(home: home).sessions(in: folder, subfolders: false, since: tab.startedAt)) ?? []
        let free = found.filter { !$0.isRunning && AgentSessions.tab(of: $0, in: taken) == nil }
        let started = free.filter { startTime($0) >= tab.startedAt && onlyMine(startTime($0)) }
        if let session = started.max(by: { startTime($0) < startTime($1) }) { return session }
        let resumed = free.filter { startTime($0) < tab.startedAt && $0.updatedAt >= tab.startedAt && onlyMine($0.updatedAt) }
        return resumed.max { $0.updatedAt < $1.updatedAt }
    }

    /// The key of the tab `session` is open in, from `openSessions`: by its identity, or by an id prefix
    /// the resume command used (Copilot CLI and Codex resume by one).
    public static func tab(of session: AgentSession, in open: [String: String]) -> String? {
        if let key = open[session.identity] { return key }
        let prefix = session.agent.rawValue + ":"
        for (identity, key) in open where identity.hasPrefix(prefix) {
            let id = identity.dropFirst(prefix.count)
            if id.count >= 8, session.id.hasPrefix(id) { return key }
        }
        return nil
    }
}

// MARK: the stores the first agents had

/// Claude Code: ~/.claude/projects/<folder name>/<id>.jsonl (see AgentSessions.claude).
struct ClaudeSessions: AgentSessionProvider {
    let home: String
    var agent: AgentKind { .claude }

    func sessions(in folder: String, subfolders: Bool, since: Date?) throws -> [AgentSession] {
        guard let since, !subfolders else { return try AgentSessions.claude(folder, home: home, subfolders: subfolders) }
        // Only this folder's files written to since then.
        let directory = (home as NSString).appendingPathComponent(".claude/projects/" + AgentSessions.claudeFolderName(folder))
        let running = AgentSessions.claudeRunning(home: home)
        var found: [AgentSession] = []
        for (file, path) in AgentStoreFiles.written(in: directory, since: since) where file.hasSuffix(".jsonl") {
            let id = String(file.dropLast(6))
            guard let session = AgentSessions.claudeSession(path, id: id, running: running.contains(id)),
                  AgentSessions.matches(session.cwd, folder, subfolders: false) else { continue }
            found.append(session)
        }
        return found
    }
}

/// Codex: its state database's threads table (see AgentSessions.codex). One indexed query, so `since`
/// has nothing to skip.
struct CodexSessions: AgentSessionProvider {
    let home: String
    var agent: AgentKind { .codex }

    func sessions(in folder: String, subfolders: Bool, since: Date?) throws -> [AgentSession] {
        try AgentSessions.codex(folder, home: home, subfolders: subfolders)
    }
}

/// Command Code: ~/.commandcode/projects/<slug>/<id>.jsonl, a few KiB of each read (see AgentSessions.commandCode).
struct CommandCodeSessions: AgentSessionProvider {
    let home: String
    var agent: AgentKind { .commandCode }

    func sessions(in folder: String, subfolders: Bool, since: Date?) throws -> [AgentSession] {
        try AgentSessions.commandCode(folder, home: home, subfolders: subfolders, since: since)
    }
}

// MARK: shared by the readers

enum AgentStoreFiles {
    /// The entries of `directory` (name, path), only the ones modified at or after `since` when it is given.
    static func written(in directory: String, since: Date?) -> [(name: String, path: String)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.compactMap { name in
            let path = (directory as NSString).appendingPathComponent(name)
            if let since, (modified(path) ?? .distantPast) < since { return nil }
            return (name, path)
        }
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// The latest modification among `paths` that exist.
    static func latest(_ paths: [String]) -> Date? {
        paths.compactMap(modified).max()
    }

    static func json(_ path: String, bytes: Int = 65536) -> [String: Any]? {
        AgentSessions.readHead(path, bytes: bytes).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// A one-segment folder name from an agent's own file: never a way out of its folder.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".")
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Milliseconds since 1970 (a number or a numeric string) as a date.
    static func date(milliseconds value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue / 1000) }
        if let text = value as? String, let number = Double(text) { return Date(timeIntervalSince1970: number / 1000) }
        return nil
    }

    /// A message's text: a string, or the text parts of a list (`[{"text": …}]`).
    static func text(_ content: Any?) -> String? {
        if let string = content as? String { return string }
        guard let parts = content as? [[String: Any]] else { return nil }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }
}

/// An agent's SQLite store, read-only: opened with SQLITE_OPEN_READONLY and `query_only`, never
/// checkpointed, and not as immutable, which would miss the newest sessions still in its write-ahead log.
final class AgentStoreDatabase {
    private let db: OpaquePointer

    init(_ path: String) throws {
        guard isRegularFile(path) else { throw AgentSessions.ReadError("no \((path as NSString).lastPathComponent)") }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw AgentSessions.ReadError("cannot open \((path as NSString).lastPathComponent)")
        }
        db = handle
        sqlite3_busy_timeout(db, 200)
        sqlite3_exec(db, "PRAGMA query_only = 1", nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    /// The table's column names (empty when there is no such table).
    func columns(_ table: String) -> Set<String> {
        Set(rows("SELECT name FROM pragma_table_info(?1)", [table]).compactMap { $0.first ?? nil })
    }

    /// Every row as strings (nil for NULL). Parameters are strings, integers or doubles; a statement that
    /// does not prepare (a column or function this SQLite lacks) gives no rows.
    func rows(_ sql: String, _ parameters: [Any] = []) -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            if let text = value as? String {
                sqlite3_bind_text(statement, index, text, -1, transient)
            } else if let number = value as? Int {
                sqlite3_bind_int64(statement, index, Int64(number))
            } else if let number = value as? Double {
                sqlite3_bind_double(statement, index, number)
            } else {
                sqlite3_bind_null(statement, index)
            }
        }
        var result: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = sqlite3_column_count(statement)
            result.append((0..<count).map { column in
                guard sqlite3_column_type(statement, column) != SQLITE_NULL, let text = sqlite3_column_text(statement, column) else { return nil }
                return String(cString: text)
            })
        }
        return result
    }
}

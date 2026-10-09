import Darwin
import Foundation

// What a tab's agent showed while it ran, kept so a restore can name its session and decide whether it may resume
// by itself (KTD4). The app reads the kernel (ProcessInspector); this reads the agents' own files and turns both
// into a SessionSnapshot.Evidence.
//
// An id is exact only from agreeing evidence: the agent's own record of this very process (Claude Code's
// sessions/<pid>.json with the same start, the one rollout Codex holds open, Qwen Code's runtime file with its
// pid), or the typed line and the live argv naming the same session. A child process's environment, argv alone,
// the typed line alone, two candidates: a guess. Every file is read as untrusted input: never through a link at its
// name, only a regular file of this user's with one name, capped, and a key that is missing reads as no evidence.

// MARK: - The kernel's view

/// A process's KERN_PROCARGS2 record: the executable path it was started with, its whole argv, and the variables of
/// its environment that were asked for. Nothing else of the environment is kept, and a record that does not read is
/// nil, never its bytes.
public struct ProcessArguments: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]

    /// More arguments than this is not a record the kernel wrote.
    public static let mostArguments = 65_536

    /// The record: argc, the executable path and its padding, argv, then the environment up to an empty string.
    public static func parse(_ bytes: [UInt8], keeping keys: Set<String>) -> ProcessArguments? {
        guard bytes.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard (0...mostArguments).contains(argc) else { return nil }
        var reader = NulStrings(bytes: bytes, offset: MemoryLayout<Int32>.size)
        guard let executable = reader.next() else { return nil }
        reader.skipNuls()
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = reader.next() else { return nil }
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        while let entry = reader.next(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            if keys.contains(key) { environment[key] = String(entry[entry.index(after: equals)...]) }
        }
        return ProcessArguments(executable: executable, arguments: arguments, environment: environment)
    }
}

/// NUL-terminated strings one after another. One the buffer cuts off is not read.
private struct NulStrings {
    let bytes: [UInt8]
    var offset: Int

    mutating func next() -> String? {
        guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
        let text = String(decoding: bytes[offset..<end], as: UTF8.self)
        offset = end + 1
        return text
    }

    mutating func skipNuls() {
        while offset < bytes.count, bytes[offset] == 0 { offset += 1 }
    }
}

/// An agent's process as the kernel showed it at capture (ProcessInspector reads it).
public struct AgentProcess: Equatable, Sendable {
    public var pid: Int32
    /// When it started; nil when that could not be read.
    public var startedAt: Date?
    /// The file the kernel ran (proc_pidpath).
    public var executable: String
    /// Its whole argv.
    public var arguments: [String]
    /// The variables of AgentEvidence.environmentKeys it has, and no others.
    public var environment: [String: String]
    /// Its working folder.
    public var directory: String?
    /// The files it holds open: read only for an agent whose session shows there (Codex).
    public var openFiles: [String]

    public init(pid: Int32, startedAt: Date?, executable: String, arguments: [String], environment: [String: String] = [:],
                directory: String? = nil, openFiles: [String] = []) {
        self.pid = pid
        self.startedAt = startedAt
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.openFiles = openFiles
    }
}

/// A path as it is now, every link resolved: what a resume would run or run in, and who could change it.
public struct FileFacts: Equatable, Sendable {
    public var realPath: String
    public var owner: uid_t
    /// Its permission bits.
    public var mode: UInt16
    public var isRegular: Bool
    public var isDirectory: Bool
    public var links: Int
    /// On a local volume, not a network share.
    public var isLocal: Bool

    public init(realPath: String, owner: uid_t, mode: UInt16, isRegular: Bool = false, isDirectory: Bool = false, links: Int = 1,
                isLocal: Bool = true) {
        self.realPath = realPath
        self.owner = owner
        self.mode = mode
        self.isRegular = isRegular
        self.isDirectory = isDirectory
        self.links = links
        self.isLocal = isLocal
    }

    /// What `path` (absolute) leads to, with every link on the way resolved: the owner and mode are the real file's,
    /// never a link's. Nil when it leads nowhere.
    public static func read(_ path: String) -> FileFacts? {
        guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return nil }
        let real = String(cString: resolved)
        free(resolved)
        var info = stat()
        guard lstat(real, &info) == 0 else { return nil }
        var volume = statfs()
        let local = statfs(real, &volume) == 0 && volume.f_flags & UInt32(MNT_LOCAL) != 0
        let type = info.st_mode & S_IFMT
        return FileFacts(realPath: real, owner: info.st_uid, mode: UInt16(info.st_mode & 0o7777), isRegular: type == S_IFREG,
                         isDirectory: type == S_IFDIR, links: Int(info.st_nlink), isLocal: local)
    }

    /// Its group or everyone may write it.
    public var othersCanWrite: Bool { mode & 0o022 != 0 }
}

/// A file in an agent's own store, read only when it is the store's own: a regular file of this user's with one
/// name, opened without following a link at its name and without waiting on a pipe.
enum StoreFile {
    /// The file whole, refused past `maxSize`; or with `head`, its first `maxSize` bytes whatever its size.
    static func read(_ path: String, maxSize: Int, head: Bool = false, owner: uid_t = geteuid()) -> (data: Data, info: stat)? {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner, info.st_nlink == 1,
              head || info.st_size <= maxSize else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= maxSize {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        if data.count > maxSize {
            guard head else { return nil }
            data = data.prefix(maxSize)
        }
        return (data, info)
    }
}

// MARK: - The agents' own records

/// What Claude Code keeps of a running `claude` in ~/.claude/sessions/<pid>.json. Its keys are undocumented.
public struct ClaudeProcessRecord: Equatable, Sendable {
    /// The process it names, when the file says.
    public var pid: Int32?
    public var sessionID: String
    /// The folder the session runs in.
    public var cwd: String
    /// When the process started, as `ps -o lstart` writes it, in UTC.
    public var procStart: String
    /// "busy" or "idle".
    public var status: String?

    public init(pid: Int32?, sessionID: String, cwd: String, procStart: String, status: String?) {
        self.pid = pid
        self.sessionID = sessionID
        self.cwd = cwd
        self.procStart = procStart
        self.status = status
    }
}

/// Qwen Code's chats/<id>.runtime.json: the process that has session `id` open, and its folder.
public struct QwenRuntime: Equatable, Sendable {
    public var pid: Int32
    public var sessionID: String
    public var folder: String
}

public enum AgentEvidence {
    /// Why an agent's record gave no evidence. It names a key at most, never what the file held.
    public enum Problem: Error, Equatable, Sendable {
        /// No file, or not one its store may hold: a link, another user's, a hard link, too large.
        case unreadable
        case notJSON
        /// A key the evidence needs is missing or of another type: the format changed.
        case missing(String)
    }

    /// The only environment variables capture reads: the search path, and what can send an agent to another
    /// provider, account or store, or make it continue a turn by itself.
    public static let environmentKeys: Set<String> = {
        var keys: Set<String> = ["PATH", "CLAUDE_CONFIG_DIR", "CODEX_HOME", copilotSessionKey]
        for agent in RestoreAgent.allCases {
            keys.formUnion(agent.routingVariables)
            keys.formUnion(agent.autoContinueVariables)
        }
        return keys
    }()

    /// The variable Copilot CLI sets in the commands it runs, naming its session.
    public static let copilotSessionKey = "COPILOT_AGENT_SESSION_ID"

    public static func claudeRecord(_ data: Data) -> Result<ClaudeProcessRecord, Problem> {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.notJSON) }
        guard let id = json["sessionId"] as? String else { return .failure(.missing("sessionId")) }
        guard let cwd = json["cwd"] as? String else { return .failure(.missing("cwd")) }
        guard let start = json["procStart"] as? String else { return .failure(.missing("procStart")) }
        var pid: Int32?
        if let value = json["pid"] {
            guard let number = (value as? Int).flatMap(Int32.init(exactly:)) else { return .failure(.missing("pid")) }
            pid = number
        }
        return .success(ClaudeProcessRecord(pid: pid, sessionID: id, cwd: cwd, procStart: start, status: json["status"] as? String))
    }

    public static func qwenRuntime(_ data: Data) -> Result<QwenRuntime, Problem> {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.notJSON) }
        guard let pid = (json["pid"] as? Int).flatMap(Int32.init(exactly:)) else { return .failure(.missing("pid")) }
        guard let id = json["session_id"] as? String else { return .failure(.missing("session_id")) }
        guard let folder = json["work_dir"] as? String else { return .failure(.missing("work_dir")) }
        return .success(QwenRuntime(pid: pid, sessionID: id, folder: folder))
    }

    /// `rollout-2026-10-07T10-00-00-<uuid>.jsonl`, the file Codex writes a session to: its uuid.
    public static func rolloutID(fileName: String) -> String? {
        guard fileName.hasPrefix("rollout-"), fileName.hasSuffix(".jsonl") else { return nil }
        let stem = fileName.dropLast(6)
        guard stem.count > "rollout-".count + 37 else { return nil }
        let id = String(stem.suffix(36))
        guard stem.dropLast(36).hasSuffix("-"), UUID(uuidString: id) != nil else { return nil }
        return id
    }

    /// A rollout's first line: `{"type": "session_meta", "payload": {"id", "cwd", …}}`.
    static func codexMeta(_ data: Data) -> (id: String, cwd: String)? {
        let line = data.prefix { $0 != 0x0A }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              json["type"] as? String == "session_meta", let payload = json["payload"] as? [String: Any],
              let id = payload["id"] as? String, let cwd = payload["cwd"] as? String, cwd.hasPrefix("/") else { return nil }
        return (id, cwd)
    }

    // MARK: ps's start times

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }

    /// `Wed Oct  7 18:05:43 2026`, in UTC: how Claude Code records when its process started.
    public static func procStart(_ text: String) -> Date? {
        let words = text.split(separator: " ")
        guard words.count == 5, weekdays.contains(String(words[0])), let month = months.firstIndex(of: String(words[1])),
              let day = Int(words[2]), let year = Int(words[4]) else { return nil }
        let clock = words[3].split(separator: ":").compactMap { Int($0) }
        guard clock.count == 3 else { return nil }
        let parts = DateComponents(year: year, month: month + 1, day: day, hour: clock[0], minute: clock[1], second: clock[2])
        guard parts.isValidDate(in: utc) else { return nil }
        return utc.date(from: parts)
    }

    /// `date` as `procStart` reads it, to the second.
    public static func procStartText(_ date: Date) -> String {
        let parts = utc.dateComponents([.weekday, .month, .day, .hour, .minute, .second, .year], from: date)
        let weekday = weekdays[((parts.weekday ?? 1) - 1) % 7]
        let month = months[((parts.month ?? 1) - 1) % 12]
        let clock = String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let day = String(format: "%2d", parts.day ?? 1)
        return "\(weekday) \(month) \(day) \(clock) \(parts.year ?? 1970)"
    }

    /// A process started at `start` is the one `text` names: ps truncates to the second.
    static func startMatches(_ text: String, _ start: Date) -> Bool {
        guard let named = procStart(text) else { return false }
        let gap = start.timeIntervalSince(named)
        return gap > -0.5 && gap < 1.5
    }
}

// MARK: - Capture

extension AgentEvidence {
    /// What the app saw of a tab at capture.
    public struct Capture: Sendable {
        /// The process leading the tab's foreground group.
        public var leader: AgentProcess?
        /// Its descendants that are the same agent: a CLI that runs itself again in a child (Codex's npm build, Qwen Code).
        public var relaunched: [AgentProcess]
        /// The leader leads the tab's foreground group and descends from the tab's shell. Without that nothing it
        /// showed is used.
        public var verified: Bool
        /// COPILOT_AGENT_SESSION_ID in the leader's descendants.
        public var childSessionIDs: [String]
        /// The line the shell integration reported typed, while that command runs.
        public var typedLine: String?
        /// Its alias-expanded form, compared in memory and never kept.
        public var expandedLine: String?
        /// The routing variables of the tab's shell as it started, to compare the agent's with.
        public var shellEnvironment: [String: String]
        public var home: String

        public init(leader: AgentProcess? = nil, relaunched: [AgentProcess] = [], verified: Bool = false, childSessionIDs: [String] = [],
                    typedLine: String? = nil, expandedLine: String? = nil, shellEnvironment: [String: String] = [:],
                    home: String = NSHomeDirectory()) {
            self.leader = leader
            self.relaunched = relaunched
            self.verified = verified
            self.childSessionIDs = childSessionIDs
            self.typedLine = typedLine
            self.expandedLine = expandedLine
            self.shellEnvironment = shellEnvironment
            self.home = home
        }

        /// The typed and expanded lines of a tab's status, while the integration reports its command running.
        public init(status: TabStatus, home: String = NSHomeDirectory()) {
            let typed = status.integrated && status.running && !status.command.isEmpty
            self.init(typedLine: typed ? status.command : nil, expandedLine: typed && !status.expandedCommand.isEmpty ? status.expandedCommand : nil,
                      home: home)
        }
    }

    /// A session an agent's own file names.
    struct Found {
        var id: String
        var source: SessionSnapshot.IDSource
        var folder: String?
    }

    /// The evidence of the agent a tab runs, or nil when it runs none. The leader counts only when it is verified and
    /// is that agent itself (not `npx` starting it, say): otherwise the typed line alone names it, as a guess.
    public static func capture(_ input: Capture) -> SessionSnapshot.Evidence? {
        let typedAgent = input.typedLine.flatMap { RestoreAgent(program: CommandClassifier.programName($0)) }
        let leaderAgent = input.leader.flatMap(RestoreAgent.init(process:))
        guard let agent = leaderAgent ?? typedAgent else { return nil }
        let leader = input.verified && leaderAgent == agent ? input.leader : nil
        var evidence = SessionSnapshot.Evidence(agent: agent)
        let typed = input.typedLine.flatMap { agent.arguments(inLine: $0) }
        let argv = leader.map { RestoreAgent.arguments(argv: $0.arguments, executable: $0.executable) }
        let candidates = leader.map { [$0] + input.relaunched } ?? []
        if let found = session(of: agent, in: candidates, home: input.home) {
            evidence.sessionID = found.id
            evidence.source = found.source
            evidence.sessionFolder = found.folder
        } else {
            nameSession(&evidence, typed: typed?.arguments, argv: argv, children: input.childSessionIDs)
        }
        let expanded = input.expandedLine.flatMap { $0.isEmpty ? nil : $0 }
        evidence.ranAsTyped = typed?.plain == true && (expanded == nil || expanded == input.typedLine)
        let options = agent.options(in: argv ?? typed?.arguments ?? [])
        evidence.flags = options.carried
        evidence.leftOff = options.leftOff
        evidence.flagsAllowed = argv != nil && options.allowed
        if let leader {
            evidence.sessionFolder = evidence.sessionFolder ?? leader.directory
            evidence.startedAt = leader.startedAt
            record(code(of: leader), in: &evidence)
            evidence.routingMatchesShell = candidates.allSatisfy { process in
                agent.routingVariables.allSatisfy { process.environment[$0] == input.shellEnvironment[$0] }
            }
            evidence.autoContinueOff = candidates.allSatisfy { process in
                agent.autoContinueVariables.allSatisfy { process.environment[$0] == nil }
            }
        }
        return evidence.repaired(limits: .standard)
    }

    /// An id from the typed line and argv: exact when both name it, else a guess (argv's first). Copilot's children
    /// name a session too: one that differs makes an exact id a guess, and with no other id it is the guess.
    private static func nameSession(_ evidence: inout SessionSnapshot.Evidence, typed: [String]?, argv: [String]?, children: [String]) {
        let agent = evidence.agent
        let fromLine = typed.flatMap { agent.resumedID(in: $0) }
        let fromArgv = argv.flatMap { agent.resumedID(in: $0) }
        if let fromLine, fromLine == fromArgv {
            evidence.sessionID = fromLine
            evidence.source = .typedAndArgv
        } else {
            evidence.sessionID = fromArgv ?? fromLine
            evidence.source = .guess
        }
        let named = Set(children.filter(agent.isSessionID))
        guard !named.isEmpty else { return }
        if let id = evidence.sessionID {
            if named != [id] { evidence.source = .guess }
        } else if named.count == 1 {
            evidence.sessionID = named.first
            evidence.source = .childEnvironment
        }
    }

    /// The session the agent's own file names for one of `candidates`, when exactly one is named.
    static func session(of agent: RestoreAgent, in candidates: [AgentProcess], home: String) -> Found? {
        switch agent {
        case .claude: return only(candidates.compactMap { claudeSession($0, home: home) })
        case .codex: return codexSession(candidates, home: home)
        case .qwen: return only(candidates.flatMap { qwenSessions($0, home: home) })
        default: return nil
        }
    }

    private static func only(_ found: [Found]) -> Found? {
        Set(found.map(\.id)).count == 1 ? found.first : nil
    }

    /// The store an agent keeps, moved by its own variable when that is an absolute path.
    private static func store(_ process: AgentProcess, _ key: String, or fallback: String) -> String {
        guard let moved = process.environment[key], moved.hasPrefix("/") else { return fallback }
        return moved
    }

    /// sessions/<pid>.json for this very process: its pid, and the start time ps gives it.
    private static func claudeSession(_ process: AgentProcess, home: String) -> Found? {
        let folder = store(process, "CLAUDE_CONFIG_DIR", or: home + "/.claude")
        guard let start = process.startedAt, case .success(let record) = AgentSessions.claudeProcess(pid: process.pid, store: folder),
              record.pid == nil || record.pid == process.pid, startMatches(record.procStart, start),
              RestoreAgent.claude.isSessionID(record.sessionID), record.cwd.hasPrefix("/") else { return nil }
        return Found(id: record.sessionID, source: .sessionFile, folder: record.cwd)
    }

    /// The rollout files the candidates hold open in Codex's store: exactly one names the session. Its first line,
    /// when it reads, must name the same one, and gives its folder.
    private static func codexSession(_ candidates: [AgentProcess], home: String) -> Found? {
        var held: [String: String] = [:]
        for process in candidates {
            let sessions = canonicalPath(store(process, "CODEX_HOME", or: home + "/.codex") + "/sessions") + "/"
            for path in process.openFiles where path.hasPrefix(sessions) {
                if let id = rolloutID(fileName: (path as NSString).lastPathComponent) { held[path] = id }
            }
        }
        guard held.count == 1, let (path, id) = held.first, let head = StoreFile.read(path, maxSize: 262_144, head: true) else { return nil }
        guard let meta = codexMeta(head.data) else { return Found(id: id, source: .openRollout, folder: nil) }
        guard meta.id.lowercased() == id.lowercased() else { return nil }
        return Found(id: id, source: .openRollout, folder: meta.cwd)
    }

    /// chats/<id>.runtime.json in the folder of the process's working directory that names this pid, made since it
    /// started.
    private static func qwenSessions(_ process: AgentProcess, home: String) -> [Found] {
        guard let directory = process.directory, let start = process.startedAt else { return [] }
        let chats = home + "/.qwen/projects/" + QwenSessions.folderName(directory) + "/chats"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: chats)) ?? []).filter { $0.hasSuffix(".runtime.json") }
        return names.prefix(64).compactMap { name -> Found? in
            let id = String(name.dropLast(".runtime.json".count))
            guard RestoreAgent.qwen.isSessionID(id), let file = StoreFile.read(chats + "/" + name, maxSize: 65_536),
                  case .success(let runtime) = qwenRuntime(file.data), runtime.pid == process.pid, runtime.sessionID == id,
                  runtime.folder.hasPrefix("/") else { return nil }
            let born = file.info.st_birthtimespec
            let bornAt = Double(born.tv_sec) + Double(born.tv_nsec) / 1_000_000_000
            guard bornAt >= start.timeIntervalSince1970 - 2 else { return nil }
            return Found(id: id, source: .runtimeFile, folder: runtime.folder)
        }
    }

    // MARK: paths

    /// What ran: the path the agent was started by when it leads to the very file the kernel ran (so a resume runs
    /// `~/.local/bin/claude`, which an update moves on, rather than one version's file), else the kernel's own. For a
    /// script agent, the interpreter so found and the script's real path.
    static func code(of process: AgentProcess) -> (executable: String, interpreter: String?, script: String?) {
        let ran = FileFacts.read(process.executable)?.realPath
        let argv0 = process.arguments.first ?? ""
        let invoked = invokedPath(argv0, searchPath: process.environment["PATH"], directory: process.directory)
        let same = invoked.flatMap { path in ran != nil && FileFacts.read(path)?.realPath == ran ? path : nil }
        let program = same ?? process.executable
        guard let index = RestoreAgent.scriptIndex(argv: process.arguments, executable: process.executable) else { return (program, nil, nil) }
        let word = process.arguments[index]
        let path = word.hasPrefix("/") ? word : process.directory.map { $0 + "/" + word }
        return (program, program, path.flatMap { FileFacts.read($0)?.realPath })
    }

    private static func record(_ code: (executable: String, interpreter: String?, script: String?), in evidence: inout SessionSnapshot.Evidence) {
        evidence.executable = code.executable
        evidence.interpreter = code.interpreter
        evidence.script = code.script
    }

    /// The absolute path a shell would run for `word`: itself when it holds a slash (from `directory` when relative),
    /// else the first executable file of that name in `searchPath`'s absolute folders.
    static func invokedPath(_ word: String, searchPath: String?, directory: String?) -> String? {
        if word.contains("/") {
            if word.hasPrefix("/") { return normalized(word) }
            guard let directory, directory.hasPrefix("/") else { return nil }
            return normalized(directory + "/" + word)
        }
        guard !word.isEmpty, let searchPath else { return nil }
        for folder in searchPath.split(separator: ":") where folder.hasPrefix("/") {
            let candidate = String(folder) + "/" + word
            if access(candidate, X_OK) == 0, isRegularFile(candidate) { return candidate }
        }
        return nil
    }

    /// An absolute path with `.` and `..` worked out, and no link followed.
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." {
                _ = parts.popLast()
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}

// MARK: - Facts read at restore

extension AgentEvidence {
    /// Folders anything may write, a sandboxed agent among them: the temporary folders, and the per-user one that
    /// holds $TMPDIR and its cache beside it.
    public static func temporaryFolders() -> [String] {
        var folders = ["/private/tmp", "/private/var/tmp"]
        let temporary = canonicalPath(NSTemporaryDirectory())
        folders.append(temporary)
        if temporary.hasPrefix("/private/var/folders/") { folders.append((temporary as NSString).deletingLastPathComponent) }
        return folders
    }

    /// A project config `agent` reads, in `folder` or a folder above it (not the home folder's own, which is the
    /// user's), changed after `start`. Change time counts too, so a modification time set back does not hide it.
    /// Not knowing when the agent started counts as changed.
    public static func projectConfigChanged(agent: RestoreAgent, folder: String, since start: Date?,
                                            home: String = NSHomeDirectory()) -> Bool {
        guard let start else { return true }
        let files = agent.projectConfigFiles
        guard !files.isEmpty, folder.hasPrefix("/") else { return !files.isEmpty }
        let skip = normalized(home)
        var current = normalized(folder)
        while true {
            if current != skip {
                for file in files where changed(current == "/" ? "/" + file : current + "/" + file, after: start) { return true }
            }
            if current == "/" { return false }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private static func changed(_ path: String, after start: Date) -> Bool {
        var info = stat()
        var latest = -Double.infinity
        if lstat(path, &info) == 0 { latest = max(latest, changeTime(info)) }
        if stat(path, &info) == 0 { latest = max(latest, changeTime(info)) }
        return latest > start.timeIntervalSince1970
    }

    private static func changeTime(_ info: stat) -> Double {
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        let changed = Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000
        return max(modified, changed)
    }

    /// Claude Code's settings set an auto-continue variable in their `env`: the user's, the managed ones, or a
    /// project's in `folder` or above it. A settings file that does not read counts as setting one.
    public static func claudeSettingsAutoContinue(home: String = NSHomeDirectory(), folder: String?,
                                                  managed: String = "/Library/Application Support/ClaudeCode/managed-settings.json") -> Bool {
        var paths = [home + "/.claude/settings.json", home + "/.claude/settings.local.json", managed]
        if let folder, folder.hasPrefix("/") {
            var current = normalized(folder)
            while true {
                let base = current == "/" ? "" : current
                paths += [base + "/.claude/settings.json", base + "/.claude/settings.local.json"]
                if current == "/" { break }
                current = (current as NSString).deletingLastPathComponent
            }
        }
        let variables = Set(RestoreAgent.claude.autoContinueVariables)
        for path in Set(paths) {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            guard let data = AgentSessions.readHead(path, bytes: 1 << 20),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return true }
            if let env = json["env"] as? [String: Any], env.keys.contains(where: variables.contains) { return true }
        }
        return false
    }
}

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
// name, only a regular file of this user's with one name whose real path lies in the agent's own store, capped, and
// a key that is missing reads as no evidence.

// MARK: - The kernel's view

/// A process's KERN_PROCARGS2 record: the executable path it was started with, its whole argv, and the variables of
/// its environment that were asked for: by value, or as a digest only (AgentEvidence.routingDigest(of:_:)). Nothing else
/// of the environment is kept, and a record that does not read is nil, never its bytes.
public struct ProcessArguments: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    /// The variables of `keeping`, by value.
    public var environment: [String: String]
    /// The variables of `digesting` on the routing allowlist, each as AgentEvidence.routingDigest(of:_:) gives it:
    /// compared, never kept.
    public var routing: [String: String]

    /// More arguments than this is not a record the kernel wrote.
    public static let mostArguments = 65_536

    /// The record: argc, the executable path and its padding, argv, then the environment up to an empty string.
    public static func parse(_ bytes: [UInt8], keeping keys: Set<String>, digesting secret: Set<String> = []) -> ProcessArguments? {
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
        var routing: [String: String] = [:]
        while let entry = reader.next(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            let value = String(entry[entry.index(after: equals)...])
            if keys.contains(key) { environment[key] = value }
            if secret.contains(key) { routing[key] = AgentEvidence.routingDigest(of: key, value) }
        }
        return ProcessArguments(executable: executable, arguments: arguments, environment: environment, routing: routing)
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
    /// Its routing variables (AgentEvidence.routingKeys), as digests.
    public var routing: [String: String]

    public init(pid: Int32, startedAt: Date?, executable: String, arguments: [String], environment: [String: String] = [:],
                directory: String? = nil, openFiles: [String] = [], routing: [String: String] = [:]) {
        self.pid = pid
        self.startedAt = startedAt
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.openFiles = openFiles
        self.routing = routing
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
    /// The symbolic links followed on the way to it, each by its own path (in its folder's real path): a resume that
    /// runs the path it was given passes each of them again.
    public var linksFollowed: [String]

    public init(realPath: String, owner: uid_t, mode: UInt16, isRegular: Bool = false, isDirectory: Bool = false, links: Int = 1,
                isLocal: Bool = true, linksFollowed: [String] = []) {
        self.realPath = realPath
        self.owner = owner
        self.mode = mode
        self.isRegular = isRegular
        self.isDirectory = isDirectory
        self.links = links
        self.isLocal = isLocal
        self.linksFollowed = linksFollowed
    }

    /// What `path` (absolute) leads to, with every link on the way resolved: the owner and mode are the real file's,
    /// never a link's. Nil when it leads nowhere.
    public static func read(_ path: String) -> FileFacts? {
        guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return nil }
        let real = String(cString: resolved)
        free(resolved)
        guard let links = linksFollowed(path) else { return nil }
        var info = stat()
        guard lstat(real, &info) == 0 else { return nil }
        var volume = statfs()
        let local = statfs(real, &volume) == 0 && volume.f_flags & UInt32(MNT_LOCAL) != 0
        let type = info.st_mode & S_IFMT
        return FileFacts(realPath: real, owner: info.st_uid, mode: UInt16(info.st_mode & 0o7777), isRegular: type == S_IFREG,
                         isDirectory: type == S_IFDIR, links: Int(info.st_nlink), isLocal: local, linksFollowed: links)
    }

    /// The links resolving `path` follows, in order, as realpath(3) walks it: a folder on the way that is a link counts.
    /// Each is named in its folder's real path. Nil when the walk fails or goes round more than 32 links.
    static func linksFollowed(_ path: String) -> [String]? {
        var pending: [Substring] = path.split(separator: "/").reversed()
        var resolved: [Substring] = []
        var links: [String] = []
        while let part = pending.popLast() {
            if part == "." { continue }
            if part == ".." {
                _ = resolved.popLast()
                continue
            }
            let folder = "/" + resolved.joined(separator: "/")
            let candidate = (folder == "/" ? "" : folder) + "/" + part
            var info = stat()
            guard lstat(candidate, &info) == 0 else { return nil }
            guard info.st_mode & S_IFMT == S_IFLNK else {
                resolved.append(part)
                continue
            }
            guard links.count < 32, let target = linkTarget(candidate) else { return nil }
            let realFolder = canonicalPath(folder)
            links.append((realFolder == "/" ? "" : realFolder) + "/" + part)
            if target.hasPrefix("/") { resolved = [] }
            pending += target.split(separator: "/").reversed()
        }
        return links
    }

    private static func linkTarget(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Its group or everyone may write it.
    public var othersCanWrite: Bool { mode & 0o022 != 0 }
}

/// A file in an agent's own store, read only when it is the store's own: a regular file of this user's with one
/// name whose real path lies in the store, opened without following a link at its name and without waiting on a pipe.
enum StoreFile {
    /// The file whole, refused past `maxSize`; or with `head`, its first `maxSize` bytes whatever its size. `store` is
    /// the store's real path: a folder on the way that is a link out of it leads to no file of the store's (KTD4).
    static func read(_ path: String, maxSize: Int, head: Bool = false, owner: uid_t = geteuid(),
                     inside store: String) -> (data: Data, info: stat)? {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner, info.st_nlink == 1,
              head || info.st_size <= maxSize, isInside(descriptor, store) else { return nil }
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

    /// The open file's real path, as the kernel names it, lies in `folder` (a real path).
    private static func isInside(_ descriptor: Int32, _ folder: String) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
        guard folder.hasPrefix("/"), fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return false }
        let real = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return real.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
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
        /// No file, or not one its store may hold: a link, outside the store, another user's, a hard link, too large.
        case unreadable
        case notJSON
        /// A key the evidence needs is missing or of another type: the format changed.
        case missing(String)
    }

    /// The only environment variables capture reads by value: the search path, the folders that move a store, the
    /// session Copilot CLI tells its commands, and what makes an agent continue a turn by itself.
    public static let environmentKeys: Set<String> = {
        var keys: Set<String> = ["PATH", "CLAUDE_CONFIG_DIR", "CODEX_HOME", copilotSessionKey]
        for agent in RestoreAgent.allCases { keys.formUnion(agent.autoContinueVariables) }
        return keys
    }()

    /// What can send an agent to another provider, account or store, read only as digests (KTD5): the allowlist of base
    /// URLs, config folders, and model and provider selectors (RestoreAgent.routingVariables). A name that looks like a
    /// secret's never is on it, even listed there.
    public static let routingKeys: Set<String> = {
        let listed = RestoreAgent.allCases.flatMap(\.routingVariables)
        return Set(listed.filter(mayDigest(name:)))
    }()

    /// The key digests are made with: the sessions folder's once the app names it (`keepRoutingKey(in:)`).
    static let routingKey = RoutingKey.Current()

    /// Names the sessions folder this process holds as where the routing key is kept, read or made at the first digest.
    /// The app calls it at launch, as soon as it has taken the folder.
    public static func keepRoutingKey(in files: SessionFiles) {
        routingKey.keep(in: files)
    }

    /// What a routing variable reads as when its value may not be digested. It matches nothing, not even itself
    /// (`routingMatches`), so the agent's resume goes on the line.
    public static let refusedDigest = "refused"

    /// Whether a variable named `name` may be digested at all: never a key, token, secret, password or credential
    /// (`*_KEY`, `*_TOKEN`, `*_SECRET` among them), nor an auth, header or cookie variable, nor a name the secret
    /// detectors take for a secret's (CommandSecrets, MCPRedaction).
    public static func mayDigest(name: String) -> Bool {
        let upper = name.uppercased()
        let words = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASSPHRASE", "CREDENTIAL", "AUTH", "HEADER", "COOKIE",
                     "_PWD", "_PASS"]
        if words.contains(where: { (word: String) -> Bool in upper.contains(word) }) { return false }
        let lower = name.lowercased()
        let secret = CommandSecrets.found(CommandSecrets.secretName, in: lower)
        let password = CommandSecrets.found(CommandSecrets.passwordName, in: lower)
        return !secret && !password && !MCPRedaction.isSecretName(name)
    }

    /// A routing variable as it is compared (KTD5): nil off the allowlist (`routingKeys`), `refusedDigest` for a value
    /// the secret detector would mask (a password or token in a URL, a key-shaped or long random run), else its keyed
    /// digest, held in memory only.
    public static func routingDigest(of name: String, _ value: String) -> String? {
        guard routingKeys.contains(name) else { return nil }
        guard CommandSecrets.mayKeep(name + "=" + value) else { return refusedDigest }
        return routingDigest(value)
    }

    /// `value`'s digest under the routing key, whatever it is: `routingDigest(of:_:)` decides what is digested.
    static func routingDigest(_ value: String) -> String {
        routingKey.key.digest(value)
    }

    /// Whether two routing variables' digests match: both unset, or the same digest of a value that was not refused.
    public static func routingMatches(_ one: String?, _ other: String?) -> Bool {
        one == other && one != refusedDigest
    }

    /// The routing variables in `/usr/bin/env`'s listing of an environment (the login shell's), as digests. A value
    /// holding a newline is cut there, and a variable listed twice is refused: either way its resume goes on the line,
    /// never the wrong way.
    public static func routingDigests(environmentListing listing: String) -> [String: String] {
        var digests: [String: String] = [:]
        for line in listing.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "="), equals != line.startIndex else { continue }
            let key = String(line[..<equals])
            guard digests[key] == nil else {
                digests[key] = refusedDigest
                continue
            }
            digests[key] = routingDigest(of: key, String(line[line.index(after: equals)...]))
        }
        return digests
    }

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

    /// `Thu Oct  1 09:30:15 2026`, in UTC: how Claude Code records when its process started.
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
        /// Its descendants that are the same agent: a CLI that runs itself again in a child (Codex's npm build, Qwen
        /// Code). Counted only for an agent that does (RestoreAgent.relaunchesItself).
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
        /// The login shell's routing variables as digests (routingDigests): the environment a restored tab's shell
        /// starts with, to compare the agent's with. Nil while it is not known, and then nothing matches.
        public var shellRouting: [String: String]?
        public var home: String

        public init(leader: AgentProcess? = nil, relaunched: [AgentProcess] = [], verified: Bool = false, childSessionIDs: [String] = [],
                    typedLine: String? = nil, expandedLine: String? = nil, shellRouting: [String: String]? = nil,
                    home: String = NSHomeDirectory()) {
            self.leader = leader
            self.relaunched = relaunched
            self.verified = verified
            self.childSessionIDs = childSessionIDs
            self.typedLine = typedLine
            self.expandedLine = expandedLine
            self.shellRouting = shellRouting
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
    /// is that agent itself (not `npx` starting it, say): otherwise the typed line alone names it, as a guess. An agent
    /// the matrix does not know is `.unknown`: still an agent, whose line is never put back as a command's.
    public static func capture(_ input: Capture) -> SessionSnapshot.Evidence? {
        let typedAgent = input.typedLine.flatMap(RestoreAgent.init(line:))
        let leaderAgent = input.leader.flatMap(RestoreAgent.init(process:))
        guard let agent = leaderAgent ?? typedAgent else { return nil }
        let leader = input.verified && leaderAgent == agent ? input.leader : nil
        var evidence = SessionSnapshot.Evidence(agent: agent)
        let typed = input.typedLine.flatMap { agent.arguments(inLine: $0) }
        let argv = leader.map { RestoreAgent.arguments(argv: $0.arguments, executable: $0.executable) }
        let candidates = leader.map { [$0] + (agent.relaunchesItself ? input.relaunched : []) } ?? []
        evidence.store = leader.flatMap { store(of: agent, environment: $0.environment, home: input.home) }
        if let store = evidence.store, let found = session(of: agent, in: candidates, store: store) {
            evidence.sessionID = found.id
            evidence.source = found.source
            evidence.sessionFolder = found.folder
        } else {
            nameSession(&evidence, typed: typed?.arguments, argv: argv, children: input.childSessionIDs)
        }
        let expanded = input.expandedLine.flatMap { $0.isEmpty ? nil : $0 }
        // The launch as a put-back line replays it (U2, KTD7): argv's options, the typed word that passes them on, and
        // the permission options the typed line or its alias expansion showed. The expansion is read here only.
        evidence.options = argv.flatMap(agent.launchOptions(in:))
        evidence.confirmed = input.typedLine.map { agent.confirmedOptions(inLine: expanded ?? $0) } ?? []
        evidence.launcher = launcher(of: agent, typed: input.typedLine, expanded: expanded, argv: argv, options: evidence.options)
        evidence.ranAsTyped = ranAsTyped(agent, typed: input.typedLine, expanded: expanded, launcher: evidence.launcher)
        if let leader {
            evidence.sessionFolder = evidence.sessionFolder ?? leader.directory
            evidence.startedAt = leader.startedAt
            evidence.version = agent.cli.version(at: RestoreAgent.installPaths(of: leader, resolved: true))
            record(code(of: leader), in: &evidence)
            evidence.routingMatchesShell = input.shellRouting.map { shell in
                candidates.allSatisfy { process in
                    agent.routingVariables.allSatisfy { AgentEvidence.routingMatches(process.routing[$0], shell[$0]) }
                }
            } ?? false
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

    /// The word typed to start the agent, when it passes its arguments on (KTD7): the first word of the typed line's last
    /// command, with no prefix or wrapper before it, that is an alias whose expansion's last command runs the agent with
    /// argv's own arguments, or a word typed with arguments that argv ends with. A function typed alone shows neither.
    /// The words typed after it must read alone as they do at the end of argv: an alias ending in an option that takes a
    /// value (`claude --model`) leaves that value to the typed words, which a replay would split. Its own words hold no
    /// form or one-shot option (`alias cc='claude --continue'`), which a replay would bring back beside the resume form.
    /// Nil when argv's options are not known, as the launcher replays the last of them.
    static func launcher(of agent: RestoreAgent, typed: String?, expanded: String?, argv: [String]?,
                         options: [SessionSnapshot.LaunchOption]?) -> SessionSnapshot.Launcher? {
        guard let typed, let argv, options != nil, let last = CommandClassifier.segments(typed).last else { return nil }
        let words = AgentKind.words(last)
        guard let word = words.first, CommandClassifier.programIndex(words) == 0, SessionSnapshot.Launcher.isWord(word) else { return nil }
        let rest = Array(words.dropFirst())
        guard rest.count <= argv.count, Array(argv.suffix(rest.count)) == rest else { return nil }
        if let expanded {
            guard let tail = CommandClassifier.segments(expanded).last, agent.arguments(inLine: tail)?.arguments == argv else { return nil }
        } else if rest.isEmpty {
            return nil
        }
        let cli = agent.cli
        let own = cli.read(Array(argv.dropLast(rest.count))).pieces
        let replays = own.allSatisfy { (piece: AgentCLI.Piece) -> Bool in
            guard case .known(_, _, let option) = piece else { return true }
            return option.kind != .form && option.kind != .oneShot
        }
        guard replays, own + cli.read(rest).pieces == cli.read(argv).pieces, let typedOptions = agent.launchOptions(in: rest) else {
            return nil
        }
        return SessionSnapshot.Launcher(word: word, typed: typedOptions.count)
    }

    /// The typed line ran the agent as typed (KTD5): its command's first word is the agent's program, with no assignment
    /// or wrapper before it and no alias in between; or that word is an alias (`launcher`, which passes argv's own
    /// arguments on) whose expansion changed nothing else of the line and runs the agent's program, with its options,
    /// first. A function, which the shell expands as itself, shows neither; nor does an alias that sets a variable, wraps
    /// the agent, or runs anything before it.
    static func ranAsTyped(_ agent: RestoreAgent, typed: String?, expanded: String?, launcher: SessionSnapshot.Launcher?) -> Bool {
        guard let typed else { return false }
        guard let expanded, expanded != typed else { return agent.arguments(inLine: typed)?.plain == true }
        let before = CommandClassifier.segments(typed)
        let after = CommandClassifier.segments(expanded)
        guard launcher != nil, let last = after.last, before.count == after.count, before.dropLast() == after.dropLast() else {
            return false
        }
        return agent.arguments(inLine: last)?.plain == true
    }

    /// The store an agent that resumes by itself keeps, by its real path (a link to it, such as a dotfiles folder,
    /// resolved): Claude Code's config folder (CLAUDE_CONFIG_DIR when that is an absolute path), Codex's (CODEX_HOME
    /// likewise), Qwen Code's. Nil for any other agent.
    static func store(of agent: RestoreAgent, environment: [String: String], home: String) -> String? {
        let folder: String
        switch agent {
        case .claude: folder = absolute(environment["CLAUDE_CONFIG_DIR"]) ?? home + "/.claude"
        case .codex: folder = absolute(environment["CODEX_HOME"]) ?? home + "/.codex"
        case .qwen: folder = home + "/.qwen"
        default: return nil
        }
        return canonicalPath(normalized(folder))
    }

    private static func absolute(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        return path
    }

    /// The session the agent's own file in `store` names for one of `candidates`, when exactly one is named.
    static func session(of agent: RestoreAgent, in candidates: [AgentProcess], store: String) -> Found? {
        switch agent {
        case .claude: return only(candidates.compactMap { claudeSession($0, store: store) })
        case .codex: return codexSession(candidates, store: store)
        case .qwen: return only(candidates.flatMap { qwenSessions($0, store: store) })
        default: return nil
        }
    }

    private static func only(_ found: [Found]) -> Found? {
        Set(found.map(\.id)).count == 1 ? found.first : nil
    }

    /// sessions/<pid>.json for this very process: its pid, and the start time ps gives it.
    private static func claudeSession(_ process: AgentProcess, store: String) -> Found? {
        guard let start = process.startedAt, case .success(let record) = AgentSessions.claudeProcess(pid: process.pid, store: store),
              record.pid == nil || record.pid == process.pid, startMatches(record.procStart, start),
              RestoreAgent.claude.isSessionID(record.sessionID), record.cwd.hasPrefix("/") else { return nil }
        return Found(id: record.sessionID, source: .sessionFile, folder: record.cwd)
    }

    /// The rollout files the candidates hold open in the store's own sessions folder (the kernel names an open file
    /// by its real path, so one reached through a link out of the store is not there): exactly one names the
    /// session. Its first line, when it reads, must name the same one, and gives its folder.
    private static func codexSession(_ candidates: [AgentProcess], store: String) -> Found? {
        let sessions = store + "/sessions/"
        var held: [String: String] = [:]
        for process in candidates {
            for path in process.openFiles where path.hasPrefix(sessions) {
                if let id = rolloutID(fileName: (path as NSString).lastPathComponent) { held[path] = id }
            }
        }
        guard held.count == 1, let (path, id) = held.first,
              let head = StoreFile.read(path, maxSize: 262_144, head: true, inside: store) else { return nil }
        guard let meta = codexMeta(head.data) else { return Found(id: id, source: .openRollout, folder: nil) }
        guard meta.id.lowercased() == id.lowercased() else { return nil }
        return Found(id: id, source: .openRollout, folder: meta.cwd)
    }

    /// chats/<id>.runtime.json in the folder of the process's working directory that names this pid, made since it
    /// started.
    private static func qwenSessions(_ process: AgentProcess, store: String) -> [Found] {
        guard let directory = process.directory, let start = process.startedAt else { return [] }
        let chats = store + "/projects/" + QwenSessions.folderName(directory) + "/chats"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: chats)) ?? []).filter { $0.hasSuffix(".runtime.json") }
        return names.prefix(64).compactMap { name -> Found? in
            let id = String(name.dropLast(".runtime.json".count))
            guard RestoreAgent.qwen.isSessionID(id), let file = StoreFile.read(chats + "/" + name, maxSize: 65_536, inside: store),
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

    /// A project config `agent` reads, in `folder` or a folder above it, changed after `start`: written, or renamed or
    /// linked into place (a config folder moved in keeps its files' times, and shows only in its own). Change time
    /// counts too, so a modification time set back does not hide it, and a file or folder that cannot be read counts
    /// as changed. The home folder above a project holds the user's own config, which the agents write themselves;
    /// a session run in the home folder reads it as its project's. Not knowing when the agent started counts as changed.
    public static func projectConfigChanged(agent: RestoreAgent, folder: String, since start: Date?,
                                            home: String = NSHomeDirectory()) -> Bool {
        guard let start else { return true }
        let files = agent.projectConfigFiles
        guard !files.isEmpty, folder.hasPrefix("/") else { return !files.isEmpty }
        let skip = normalized(home)
        let first = normalized(folder)
        var current = first
        while true {
            if current != skip || current == first {
                for file in files where changed(file, in: current, after: start) { return true }
            }
            if current == "/" { return false }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// `file` (relative) in `folder`, or a folder on the way to it, changed after `start`, or cannot be read.
    static func changed(_ file: String, in folder: String, after start: Date) -> Bool {
        var path = folder == "/" ? "" : folder
        for part in file.split(separator: "/") {
            path += "/" + part
            guard let latest = latestChange(path) else { return true }
            if latest > start.timeIntervalSince1970 { return true }
            if latest == -.infinity { return false }
        }
        return false
    }

    /// The latest modification or change time of `path` and of what it leads to: -infinity when nothing is there, nil
    /// when that cannot be told.
    private static func latestChange(_ path: String) -> Double? {
        var info = stat()
        var latest = -Double.infinity
        if lstat(path, &info) == 0 {
            latest = max(latest, changeTime(info))
        } else if !isAbsent(errno) {
            return nil
        }
        if stat(path, &info) == 0 {
            latest = max(latest, changeTime(info))
        } else if !isAbsent(errno) {
            return nil
        }
        return latest
    }

    /// What a failed lstat or stat says: nothing is there. Any other failure (a folder that cannot be searched, a
    /// loop of links) tells nothing.
    static func isAbsent(_ error: Int32) -> Bool {
        error == ENOENT || error == ENOTDIR
    }

    private static func changeTime(_ info: stat) -> Double {
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        let changed = Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000
        return max(modified, changed)
    }

    /// Claude Code's settings set an auto-continue variable in their `env`: the user's (in `store`, the config
    /// folder CLAUDE_CONFIG_DIR moves, and in ~/.claude), the managed ones, or a project's in `folder` or above it. A
    /// settings file that does not read, or cannot be told to be absent, counts as setting one.
    public static func claudeSettingsAutoContinue(home: String = NSHomeDirectory(), store: String? = nil, folder: String?,
                                                  managed: String = "/Library/Application Support/ClaudeCode/managed-settings.json") -> Bool {
        var paths = [home + "/.claude/settings.json", home + "/.claude/settings.local.json", managed]
        if let store, store.hasPrefix("/") { paths += [store + "/settings.json", store + "/settings.local.json"] }
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
            guard lstat(path, &info) == 0 else {
                if isAbsent(errno) { continue }
                return true
            }
            guard let data = AgentSessions.readHead(path, bytes: 1 << 20),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return true }
            if let env = json["env"] as? [String: Any], env.keys.contains(where: variables.contains) { return true }
        }
        return false
    }
}

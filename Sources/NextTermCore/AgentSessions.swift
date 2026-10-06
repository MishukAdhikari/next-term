import Foundation
import SQLite3

/// The conversations AI agents have kept for a project, so one can be picked up again in a click. Each
/// agent stores its own (Claude Code, Codex, Command Code), in its own format: these readers take only
/// what the list needs (id, folder, title, times, branch, model) from the start and end of each file or
/// from the agent's index, never a whole transcript, and never write anything. Titles are scrubbed of
/// anything that looks like a secret before they are shown. One agent's store failing to read (its
/// format changed) only leaves that agent out. Formats: claudedocs/research_next-term-agent-sessions.
public enum AgentKind: String, CaseIterable, Sendable, Codable {
    case claude, codex, commandCode

    public var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .commandCode: return "Command Code"
        }
    }
}

public struct AgentSession: Sendable, Hashable, Identifiable {
    public let agent: AgentKind
    /// What the agent's resume command takes.
    public let id: String
    /// The folder the agent worked in (as it recorded it).
    public let cwd: String
    public let title: String
    /// The title is one the user gave it (not the agent's summary or the first prompt).
    public let named: Bool
    public let createdAt: Date?
    public let updatedAt: Date
    public let gitBranch: String?
    public let model: String?
    /// An agent process has it open right now (Claude Code).
    public let isRunning: Bool

    public var identity: String { agent.rawValue + ":" + id }

    public init(agent: AgentKind, id: String, cwd: String, title: String, named: Bool, createdAt: Date?, updatedAt: Date,
                gitBranch: String?, model: String?, isRunning: Bool) {
        self.agent = agent
        self.id = id
        self.cwd = cwd
        self.title = title
        self.named = named
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.gitBranch = gitBranch
        self.model = model
        self.isRunning = isRunning
    }

    /// The command line that picks it up again, typed into a shell in `cwd`. `fork`: a copy that leaves the
    /// original as it was (the safe choice while it is open elsewhere).
    public func resumeCommand(fork: Bool = false) -> String {
        let quoted = ShellQuote.quote(id)
        switch agent {
        case .claude: return "claude --resume \(quoted)" + (fork ? " --fork-session" : "")
        case .codex: return (fork ? "codex fork " : "codex resume ") + quoted + " -C " + ShellQuote.quote(cwd)
        case .commandCode: return "command-code --resume \(quoted)" + (fork ? " --fork-session" : "")
        }
    }
}

public enum AgentSessions {
    public struct Listing: Sendable {
        public var sessions: [AgentSession]
        /// Agents whose sessions could not be read, with why.
        public var problems: [AgentKind: String]
    }

    /// The sessions for a folder (and, with `subfolders`, the folders inside it), newest first.
    public static func list(project: String, home: String = NSHomeDirectory(), subfolders: Bool = true,
                            perAgent limit: Int = 50) -> Listing {
        let folder = canonicalPath(project)
        var listing = Listing(sessions: [], problems: [:])
        for agent in AgentKind.allCases {
            do {
                let found: [AgentSession]
                switch agent {
                case .claude: found = try claude(folder, home: home, subfolders: subfolders)
                case .codex: found = try codex(folder, home: home, subfolders: subfolders)
                case .commandCode: found = try commandCode(folder, home: home, subfolders: subfolders)
                }
                listing.sessions += found.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit)
            } catch {
                listing.problems[agent] = "\(error)"
            }
        }
        listing.sessions.sort { $0.updatedAt > $1.updatedAt }
        return listing
    }

    static func matches(_ cwd: String, _ folder: String, subfolders: Bool) -> Bool {
        cwd == folder || (subfolders && cwd.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/"))
    }

    struct ReadError: Error, CustomStringConvertible {
        let description: String
        init(_ text: String) { description = text }
    }

    // MARK: Claude Code

    /// Claude's folder name for a project: every UTF-16 unit that is not an ASCII letter or digit becomes
    /// "-"; past 200 characters, the first 200 and a base-36 hash of the whole path.
    public static func claudeFolderName(_ path: String) -> String {
        let units = path.utf16.map { unit -> UInt16 in
            (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) ? unit : 0x2D
        }
        let name = String(decoding: units, as: UTF16.self)
        guard units.count > 200 else { return name }
        var hash: Int32 = 0
        for unit in path.utf16 { hash = hash &* 31 &+ Int32(unit) }
        return String(decoding: units.prefix(200), as: UTF16.self) + "-" + String(abs(Int64(hash)), radix: 36)
    }

    static func claude(_ folder: String, home: String, subfolders: Bool) throws -> [AgentSession] {
        let base = (home as NSString).appendingPathComponent(".claude/projects")
        guard let all = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        let encoded = claudeFolderName(folder)
        // The name is only a hint (several paths share one): the recorded folder decides.
        let candidates = all.filter { $0 == encoded || (subfolders && $0.hasPrefix(encoded + "-")) }
        let running = claudeRunning(home: home)
        var sessions: [AgentSession] = []
        for directory in candidates {
            let path = (base as NSString).appendingPathComponent(directory)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let url = (path as NSString).appendingPathComponent(file)
                let id = String(file.dropLast(6))
                guard let session = claudeSession(url, id: id, running: running.contains(id)),
                      matches(session.cwd, folder, subfolders: subfolders) else { continue }
                sessions.append(session)
            }
        }
        return sessions
    }

    /// Sessions a live `claude` has open: ~/.claude/sessions/<pid>.json (never the .key files beside them).
    static func claudeRunning(home: String) -> Set<String> {
        let folder = (home as NSString).appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        var ids = Set<String>()
        for file in files where file.hasSuffix(".json") {
            guard let pid = Int32(file.dropLast(5)), kill(pid, 0) == 0 || errno == EPERM,
                  let data = readHead((folder as NSString).appendingPathComponent(file), bytes: 16384),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = json["sessionId"] as? String else { continue }
            ids.insert(id)
        }
        return ids
    }

    static func claudeSession(_ path: String, id: String, running: Bool) -> AgentSession? {
        guard let (head, tail, modified) = headAndTail(path) else { return nil }
        var cwd: String?, created: Date?, branch: String?, firstPrompt: String?, isLoop = false
        for line in head {
            if line["isSidechain"] as? Bool == true { return nil } // an older Claude's sub-agent transcript
            if let entry = line["entrypoint"] as? String, entry.hasPrefix("sdk") { return nil } // claude -p, the SDK
            if cwd == nil, let value = line["cwd"] as? String { cwd = value }
            if created == nil, let stamp = line["timestamp"] as? String { created = parseDate(stamp) }
            if branch == nil, let value = line["gitBranch"] as? String, !value.isEmpty { branch = value }
            if firstPrompt == nil, line["type"] as? String == "user", let prompt = claudePrompt(line) {
                if prompt.hasPrefix("<tick") { isLoop = true }
                firstPrompt = prompt
            }
        }
        var agentName: String?, customTitle: String?, aiTitle: String?, summary: String?
        var updated: Date?, model: String?, relocated: String?
        for line in tail {
            switch line["type"] as? String {
            case "agent-name": agentName = (line["agentName"] as? String) ?? agentName
            case "custom-title": customTitle = (line["customTitle"] as? String) ?? customTitle
            case "ai-title": aiTitle = (line["aiTitle"] as? String) ?? aiTitle
            case "summary": summary = (line["summary"] as? String) ?? summary
            case "relocated": relocated = (line["relocatedCwd"] as? String) ?? relocated
            case "assistant": model = ((line["message"] as? [String: Any])?["model"] as? String) ?? model
            default: break
            }
            if let stamp = line["timestamp"] as? String, let date = parseDate(stamp) { updated = date }
            if let value = line["gitBranch"] as? String, !value.isEmpty { branch = value }
        }
        guard let folder = relocated ?? cwd, !isLoop else { return nil }
        let named = [agentName, customTitle].compactMap { $0 }.first { !$0.isEmpty }
        let title = named ?? [aiTitle, summary, firstPrompt].compactMap { $0 }.first { !$0.isEmpty }
        guard let title else { return nil } // nothing was ever asked: an empty session
        return AgentSession(agent: .claude, id: id, cwd: folder, title: clean(title), named: named != nil, createdAt: created,
                            updatedAt: min(updated ?? modified, modified), gitBranch: branch, model: model.map(shortModel),
                            isRunning: running)
    }

    /// A user line as Claude's own picker shows it: plain prompts, `/command args`, `! shell`; system
    /// injections and interruptions skipped.
    static func claudePrompt(_ line: [String: Any]) -> String? {
        if line["isMeta"] as? Bool == true || line["isCompactSummary"] as? Bool == true { return nil }
        let content = (line["message"] as? [String: Any])?["content"]
        var text: String?
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard var prompt = text?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else { return nil }
        if prompt.hasPrefix("<command-name>") {
            let name = between(prompt, "<command-name>", "</command-name>") ?? ""
            let arguments = between(prompt, "<command-args>", "</command-args>")?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !arguments.isEmpty else { return nil }
            prompt = (name.hasPrefix("/") ? name : "/" + name) + " " + arguments
        } else if prompt.hasPrefix("<bash-input>") {
            prompt = "! " + (between(prompt, "<bash-input>", "</bash-input>") ?? "")
        } else if prompt.hasPrefix("<tick") {
            return prompt
        } else if prompt.range(of: #"^\s*<[a-z][\w-]*[\s>]"#, options: .regularExpression) != nil
                    || prompt.hasPrefix("[Request interrupted by user") {
            return nil
        }
        return prompt
    }

    private static func between(_ text: String, _ open: String, _ close: String) -> String? {
        guard let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// "claude-sonnet-5-20261001" → "claude-sonnet-5".
    static func shortModel(_ model: String) -> String {
        model.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }

    // MARK: Codex

    static func codex(_ folder: String, home: String, subfolders: Bool) throws -> [AgentSession] {
        let base = (home as NSString).appendingPathComponent(".codex")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        // state_5.sqlite today; a newer schema generation gets a higher number.
        let databases = files.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"), let n = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (n, (base as NSString).appendingPathComponent(name))
        }
        guard let path = databases.max(by: { $0.0 < $1.0 })?.1 else { return [] }
        var db: OpaquePointer?
        // Read-only, and not immutable: that would miss what is still in the write-ahead log (the newest).
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw ReadError("cannot open \((path as NSString).lastPathComponent)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        sqlite3_exec(db, "PRAGMA query_only = 1", nil, nil, nil)
        let columns = Set(rows(db, "PRAGMA table_info(threads)").compactMap { $0[1] })
        let needed: Set<String> = ["id", "cwd", "preview", "archived"]
        guard needed.isSubset(of: columns) else { throw ReadError("the threads table changed") }
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let recency = columns.contains("recency_at_ms") ? "recency_at_ms" : columns.contains("updated_at_ms") ? "updated_at_ms" : "NULL"
        var filters = ["archived = 0", "preview <> ''"]
        if columns.contains("thread_source") { filters.append("(thread_source IS NULL OR thread_source = 'user')") }
        if columns.contains("source") { filters.append("(source IS NULL OR source <> 'exec')") }
        let sql = """
            SELECT id, cwd, \(column("name")), \(column("title")), preview, \(column("created_at_ms")), \(recency),
                   \(column("git_branch")), \(column("model"))
            FROM threads WHERE \(filters.joined(separator: " AND ")) AND (cwd = ?1 OR (?2 AND substr(cwd, 1, length(?1) + 1) = ?1 || '/'))
            ORDER BY \(recency == "NULL" ? "rowid" : recency) DESC LIMIT 200
            """
        return rows(db, sql, bind: [folder, subfolders ? "1" : "0"]).compactMap { row -> AgentSession? in
            guard let id = row[0], let cwd = row[1] else { return nil }
            let name = row[2].flatMap { $0.isEmpty ? nil : $0 }
            let title = name ?? row[3].flatMap { $0.isEmpty ? nil : $0 } ?? row[4] ?? ""
            let created = row[5].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
            let updated = row[6].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? created ?? .distantPast
            return AgentSession(agent: .codex, id: id, cwd: cwd, title: clean(title), named: name != nil, createdAt: created,
                                updatedAt: updated, gitBranch: row[7], model: row[8], isRunning: false)
        }
    }

    /// Every row as strings (nil for NULL).
    private static func rows(_ db: OpaquePointer, _ sql: String, bind: [String] = []) -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bind.enumerated() {
            if index == 1, value == "0" || value == "1" {
                sqlite3_bind_int(statement, Int32(index + 1), value == "1" ? 1 : 0)
            } else {
                sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            }
        }
        var result: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = sqlite3_column_count(statement)
            result.append((0..<count).map { i in
                sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : sqlite3_column_text(statement, i).map { String(cString: $0) }
            })
        }
        return result
    }

    // MARK: Command Code

    static func commandCode(_ folder: String, home: String, subfolders: Bool) throws -> [AgentSession] {
        let base = (home as NSString).appendingPathComponent(".commandcode/projects")
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        var sessions: [AgentSession] = []
        for project in projects {
            let directory = (base as NSString).appendingPathComponent(project)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            // <id>.jsonl is the transcript; <id>.checkpoints.jsonl, .prompts.jsonl and backups sit beside it.
            for file in files where file.hasSuffix(".jsonl") && file.dropLast(6).contains(".") == false {
                let path = (directory as NSString).appendingPathComponent(file)
                guard let head = readHead(path, bytes: 8192),
                      let firstLine = head.split(separator: 0x0A, maxSplits: 1).first,
                      let header = (try? JSONSerialization.jsonObject(with: Data(firstLine))) as? [String: Any],
                      header["type"] as? String == "session", let cwd = header["cwd"] as? String,
                      matches(cwd, folder, subfolders: subfolders) else { continue }
                if header["entrypoint"] as? String == "print" { continue } // headless runs
                let id = (header["id"] as? String) ?? String(file.dropLast(6))
                let stem = (directory as NSString).appendingPathComponent(String(file.dropLast(6)))
                let meta = readHead(stem + ".meta.json", bytes: 65536)
                    .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
                var prompt: String?
                if let checkpoints = readHead(stem + ".checkpoints.jsonl", bytes: 16384),
                   let line = checkpoints.split(separator: 0x0A, maxSplits: 1).first,
                   let first = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                    prompt = first["prompt"] as? String
                }
                let title = [(meta["title"] as? String), prompt].compactMap { $0 }.first { !$0.isEmpty }
                guard let title else { continue } // nothing was asked
                let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                sessions.append(AgentSession(agent: .commandCode, id: id, cwd: cwd, title: clean(title),
                                             named: meta["userRenamed"] as? Bool == true,
                                             createdAt: (header["timestamp"] as? String).flatMap(parseDate),
                                             updatedAt: modified, gitBranch: meta["gitBranch"] as? String,
                                             model: meta["model"] as? String, isRunning: false))
            }
        }
        return sessions
    }

    // MARK: reading

    /// The first bytes of a regular file (never a pipe or a device).
    static func readHead(_ path: String, bytes: Int) -> Data? {
        guard isRegularFile(path), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: bytes)
    }

    static let chunk = 65536

    /// The JSON lines in the first and last 64 KiB of a file (the part line at each cut dropped), and its
    /// modification date: enough for every field the list shows, whatever the file's size.
    static func headAndTail(_ path: String) -> (head: [[String: Any]], tail: [[String: Any]], modified: Date)? {
        guard isRegularFile(path), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: chunk)) ?? Data()
        var tail = head
        if size > UInt64(chunk) {
            try? handle.seek(toOffset: size - UInt64(chunk))
            tail = (try? handle.read(upToCount: chunk)) ?? Data()
            if let newline = tail.firstIndex(of: 0x0A) { tail = tail[(newline + 1)...] }
        }
        func lines(_ data: Data, dropLastPart: Bool) -> [[String: Any]] {
            var parts = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            if dropLastPart, data.last != 0x0A, !parts.isEmpty { parts.removeLast() }
            return parts.compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        return (lines(head, dropLastPart: size > UInt64(chunk)), lines(tail, dropLastPart: false), modified)
    }

    static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    // MARK: titles

    /// One line, at most 200 characters, with anything that looks like a secret replaced by •••.
    public static func clean(_ text: String) -> String {
        var line = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        line = redact(line)
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }

    static let secretPatterns = [
        #"sk-ant-[A-Za-z0-9_\-]{8,}"#, #"sk-[A-Za-z0-9_\-]{16,}"#, #"(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#,
        #"github_pat_[A-Za-z0-9_]{20,}"#, #"xox[abpr]-[A-Za-z0-9\-]{10,}"#, #"AKIA[0-9A-Z]{16}"#, #"AIza[0-9A-Za-z_\-]{30,}"#,
        #"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        // Keys RAG and agent projects carry: LangSmith, Hugging Face, Groq, Tavily, Replicate, xAI, Pinecone.
        #"lsv2_(pt|sk)_[A-Za-z0-9_]{16,}"#, #"hf_[A-Za-z0-9]{30,}"#, #"gsk_[A-Za-z0-9]{20,}"#, #"tvly-[A-Za-z0-9_\-]{16,}"#,
        #"r8_[A-Za-z0-9]{20,}"#, #"xai-[A-Za-z0-9]{20,}"#, #"pcsk_[A-Za-z0-9_]{20,}"#,
        #"(?i)(password|passwd|token|secret|api[_-]?key)\s*[=:]\s*\S+"#, #"\b[A-Fa-f0-9]{32,}\b"#, #"\b[A-Za-z0-9+/]{40,}={0,2}"#,
    ]

    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in secretPatterns {
            result = result.replacingOccurrences(of: pattern, with: "•••", options: .regularExpression)
        }
        return result
    }
}

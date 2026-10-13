import Foundation

/// OpenCode: SQLite stores, wherever `OpencodePaths.databases` finds them (`~/.local/share/opencode/opencode.db` by
/// default, since v1.2; `XDG_DATA_HOME`, `OPENCODE_DB` and channel builds move or add one). Its session table is
/// `session`, and `session_v2` from OpenCode 2, which leaves the old one beside it (a 1.x build run again writes there);
/// both are read, the newer table's row winning a tie. It has the folder each session was started in (`directory`),
/// `title` (OpenCode 2 may leave it empty), `time_created` and `time_updated` (ms), `model` (JSON with its `id`),
/// `parent_id` for a sub-agent's and `time_archived` for an archived one, neither listed. Until the agent names a
/// session its title is empty or "New session - <time>", so the first prompt (the first text part of its first user
/// message) stands in; with no prompt either, the session is empty. The newer runner keeps a session's messages in
/// `session_message` instead (`type`, `seq`, and `data` with the `text`). Several stores holding one session give its
/// newest row. Resume with `opencode --session <id>` in the same folder.
struct OpencodeSessions: AgentSessionProvider {
    let home: String
    /// The variables that move OpenCode's store (`OpencodePaths.variables`).
    let environment: [String: String]
    var agent: AgentKind { .opencode }

    /// `environment` nil: the login shell's for the user's own home, none for another (`OpencodePaths.environment`).
    init(home: String, environment: [String: String]? = nil) {
        self.home = home
        self.environment = environment ?? OpencodePaths.environment(home: home)
    }

    /// Every store's sessions, one row per id (the newest written), newest first. A store that can't be read leaves
    /// the others' sessions listed; it throws only when none could be.
    func sessions(in folder: String, subfolders: Bool, since: Date?) throws -> [AgentSession] {
        var newest: [String: AgentSession] = [:]
        var failure: Error?
        var read = false
        for path in OpencodePaths.databases(home: home, environment: environment) {
            do {
                Self.merge(try Self.sessions(path, in: folder, subfolders: subfolders, since: since), into: &newest)
                read = true
            } catch {
                failure = failure ?? error
            }
        }
        if !read, let failure { throw failure }
        return Self.newestFirst(newest)
    }

    /// The most rows one store gives.
    static let rowLimit = 200

    /// One store's sessions, the newest `rowLimit` written: OpenCode 2's table and the old one beside it, or the old
    /// one alone. Throws when the table OpenCode writes (`session_v2` when it is there) lacks a column it needs; an old
    /// table beside it that lacks one is left out.
    static func sessions(_ path: String, in folder: String, subfolders: Bool, since: Date?) throws -> [AgentSession] {
        let db = try AgentStoreDatabase(path)
        let current = db.columns("session_v2").isEmpty ? "session" : "session_v2"
        guard let found = rows(db, table: current, in: folder, subfolders: subfolders, since: since) else {
            throw AgentSessions.ReadError("the session table changed")
        }
        var newest: [String: AgentSession] = [:]
        merge(found, into: &newest)
        if current == "session_v2", let old = rows(db, table: "session", in: folder, subfolders: subfolders, since: since) {
            merge(old, into: &newest)
        }
        return Array(newestFirst(newest).prefix(rowLimit))
    }

    /// `table`'s sessions in `folder`, the newest `rowLimit` written; nil when it lacks `id`, `directory` or
    /// `time_updated` (or is not there).
    static func rows(_ db: AgentStoreDatabase, table: String, in folder: String, subfolders: Bool, since: Date?) -> [AgentSession]? {
        let columns = db.columns(table)
        guard ["id", "directory", "time_updated"].allSatisfy(columns.contains) else { return nil }
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        var filters = ["(directory = ?1 OR (?2 = 1 AND substr(directory, 1, length(?1) + 1) = ?1 || '/'))", "time_updated >= ?3"]
        if columns.contains("parent_id") { filters.append("parent_id IS NULL") }
        if columns.contains("time_archived") { filters.append("time_archived IS NULL") }
        let picked = "SELECT id, directory, \(column("title")), \(column("time_created")), time_updated, \(column("model"))"
        let sql = picked + " FROM \(table) WHERE " + filters.joined(separator: " AND ") + " ORDER BY time_updated DESC LIMIT \(rowLimit)"
        let after = since.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0
        return db.rows(sql, [folder, subfolders ? 1 : 0, after]).compactMap { row -> AgentSession? in
            guard let id = row[0], let directory = row[1] else { return nil }
            var title = row[2] ?? ""
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDefaultTitle(title) {
                title = firstPrompt(db, session: id) ?? firstUserMessage(db, session: id) ?? ""
            }
            guard !title.isEmpty else { return nil } // nothing was asked
            let created = AgentStoreFiles.date(milliseconds: row[3])
            let updated = AgentStoreFiles.date(milliseconds: row[4]) ?? created ?? .distantPast
            return AgentSession(agent: .opencode, id: id, cwd: directory, title: AgentSessions.clean(title), named: false,
                                createdAt: created, updatedAt: updated, gitBranch: nil, model: row[5].flatMap(modelName),
                                isRunning: false)
        }
    }

    /// `sessions` into `kept` by id: a row replaces the kept one only when written later, so a tie keeps the first read.
    static func merge(_ sessions: [AgentSession], into kept: inout [String: AgentSession]) {
        for session in sessions {
            if let have = kept[session.id], have.updatedAt >= session.updatedAt { continue }
            kept[session.id] = session
        }
    }

    /// Newest written first; a tie by id.
    static func newestFirst(_ kept: [String: AgentSession]) -> [AgentSession] {
        kept.values.sorted { (a: AgentSession, b: AgentSession) -> Bool in
            a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.id < b.id
        }
    }

    /// "New session - 2026-10-01T10:00:00.000Z" (or "Child session - …"): the agent has not named it yet.
    static func isDefaultTitle(_ title: String) -> Bool {
        title.range(of: #"^(New|Child) session - \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression) != nil
    }

    static func firstPrompt(_ db: AgentStoreDatabase, session id: String) -> String? {
        let sql = """
            SELECT p.data FROM message m JOIN part p ON p.message_id = m.id
            WHERE m.session_id = ?1 AND json_extract(m.data, '$.role') = 'user' AND json_extract(p.data, '$.type') = 'text'
              AND coalesce(json_extract(p.data, '$.synthetic'), 0) = 0
            ORDER BY m.time_created, m.id, p.id LIMIT 1
            """
        guard let data = db.rows(sql, [id]).first?.first ?? nil,
              let part = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any],
              let text = part["text"] as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// The first prompt from the newer runner's `session_message` table, nil when there is no such table.
    static func firstUserMessage(_ db: AgentStoreDatabase, session id: String) -> String? {
        guard !db.columns("session_message").isEmpty else { return nil }
        let sql = "SELECT json_extract(data, '$.text') FROM session_message WHERE session_id = ?1 AND type = 'user' ORDER BY seq LIMIT 1"
        guard let text = db.rows(sql, [id]).first?.first ?? nil else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// `{"id": "claude-sonnet-5", "providerID": "anthropic"}` → "claude-sonnet-5"; a plain string as it is.
    static func modelName(_ value: String) -> String? {
        guard value.hasPrefix("{") else { return value.isEmpty ? nil : value }
        let object = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any]
        return object?["id"] as? String
    }
}

// MARK: - The session OpenCode shows

extension OpencodeSessions {
    /// What OpenCode puts before a session's title in the tab's title: "OC | Fix the login test". Its home screen and a
    /// session with no title yet show "OpenCode", which names none.
    static let titlePrefix = "OC | "

    /// The session OpenCode's title `title` names among `sessions`: the only one of OpenCode's, written at or after
    /// `since` (when the agent showing it started), whose title is the shown one. Past 40 characters OpenCode shows the
    /// first 37 and "…" (an older build "..."), so a cut title names the sessions whose titles start with it. Both sides
    /// compare as the session list shows them (`AgentSessions.clean`). Nil for none or several, and for an id out of
    /// OpenCode's shape.
    static func shown(title: String, in sessions: [AgentSession], since: Date) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(titlePrefix) else { return nil }
        let words = String(trimmed.dropFirst(titlePrefix.count))
        let mark = ["…", "..."].first { (mark: String) -> Bool in words.hasSuffix(mark) }
        let cut = mark != nil
        var start = mark.map { (mark: String) -> String in String(words.dropLast(mark.count)) } ?? words
        // JavaScript cuts by UTF-16 unit, so half a character may end the cut: what it leaves reads as U+FFFD.
        while cut, start.hasSuffix("\u{FFFD}") { start.removeLast() }
        let whole = AgentSessions.clean(words)
        let prefix = AgentSessions.clean(start)
        guard !prefix.isEmpty else { return nil }
        let matches = sessions.filter { (session: AgentSession) -> Bool in
            guard session.agent == .opencode, session.updatedAt >= since else { return false }
            return session.title == whole || (cut && session.title.hasPrefix(prefix))
        }
        let ids = Set(matches.map(\.id))
        guard ids.count == 1, let id = ids.first, RestoreAgent.opencode.isSessionID(id) else { return nil }
        return id
    }

    /// `shown` over the sessions written in `folder` (not its subfolders) since `since`, read from every store now:
    /// never on the main thread. Nil when no store can be read.
    func shown(title: String, in folder: String, since: Date) -> String? {
        guard title.trimmingCharacters(in: .whitespaces).hasPrefix(Self.titlePrefix) else { return nil }
        let found = (try? sessions(in: canonicalPath(folder), subfolders: false, since: since)) ?? []
        return Self.shown(title: title, in: found, since: since)
    }
}

/// What a tab keeps of the session OpenCode shows. Matching its title reads OpenCode's store, so the tab looks a title up
/// off the main thread, once, when the title changes, and keeps the id it found. The save, which captures every tab on
/// the main thread, reads the kept id only while the title and the agent's start are the ones it was found for, and so
/// never waits on a store. Only the id is kept: a program's title could hold anything.
public struct OpencodeShownSession: Sendable {
    /// One lookup: the title OpenCode showed, and when the agent showing it started.
    public struct Ask: Equatable, Sendable {
        public var title: String
        public var start: Date

        public init(title: String, start: Date) {
            self.title = title
            self.start = start
        }
    }

    /// How long a title nothing was found for waits before it is looked up again. After `opencode -c` OpenCode shows
    /// the session it continues before writing to it, and only a session written since the agent started can match.
    public static let retryAfter: TimeInterval = 20

    private var asked: Ask?
    /// When `asked` was looked up, on the caller's clock.
    private var askedAt: TimeInterval = 0
    private var kept: (ask: Ask, id: String)?

    public init() {}

    /// The lookup to run now for the tab's title `title` (shown by an OpenCode that started at `start`), or nil when
    /// there is none to run: a title that names no session, one already found, or one looked up less than
    /// `retryAfter` ago. `now` is any steady clock in seconds.
    public mutating func ask(title: String?, start: Date, at now: TimeInterval) -> Ask? {
        guard let title, title.trimmingCharacters(in: .whitespaces).hasPrefix(OpencodeSessions.titlePrefix) else { return nil }
        let ask = Ask(title: title, start: start)
        if ask == asked {
            guard kept?.ask != ask, now - askedAt >= Self.retryAfter else { return nil }
        }
        asked = ask
        askedAt = now
        return ask
    }

    /// The lookup `ask` found `id` (nil: none). An answer to a lookup the title has moved on from is dropped.
    public mutating func found(_ id: String?, for ask: Ask) {
        guard ask == asked else { return }
        if let id {
            kept = (ask, id)
        } else {
            kept = nil
        }
    }

    /// The id kept for `title` shown by the agent that started at `start`, or nil: none found, or found for another.
    public func id(title: String?, start: Date) -> String? {
        guard let title, let kept, kept.ask == Ask(title: title, start: start) else { return nil }
        return kept.id
    }

    /// Looks `ask` up in the folder the agent runs in, in the OpenCode stores of `home`: never on the main thread.
    public static func lookUp(_ ask: Ask, in folder: String, home: String) -> String? {
        OpencodeSessions(home: home).shown(title: ask.title, in: folder, since: ask.start)
    }
}

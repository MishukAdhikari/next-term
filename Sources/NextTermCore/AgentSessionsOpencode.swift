import Foundation

/// OpenCode: SQLite stores, wherever `OpencodePaths.databases` finds them (`~/.local/share/opencode/opencode.db` by
/// default, since v1.2; `XDG_DATA_HOME`, `OPENCODE_DB` and channel builds move or add one). Its session table is
/// `session`, renamed `session_v2` by OpenCode 2, which leaves the old one beside it; the newer is read when it is
/// there. It has the folder each session was started in (`directory`), `title` (OpenCode 2 may leave it empty),
/// `time_created` and `time_updated` (ms), `model` (JSON with its `id`), `parent_id` for a sub-agent's and
/// `time_archived` for an archived one, neither listed. Until the agent names a session its title is empty or
/// "New session - <time>", so the first prompt (the first text part of its first user message) stands in; with no
/// prompt either, the session is empty. The newer runner keeps a session's messages in `session_message` instead
/// (`type`, `seq`, and `data` with the `text`). Several stores holding one session give its newest row. Resume with
/// `opencode --session <id>` in the same folder.
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
            let found: [AgentSession]
            do {
                found = try Self.sessions(path, in: folder, subfolders: subfolders, since: since)
            } catch {
                failure = failure ?? error
                continue
            }
            read = true
            for session in found {
                if let kept = newest[session.id], kept.updatedAt >= session.updatedAt { continue }
                newest[session.id] = session
            }
        }
        if !read, let failure { throw failure }
        return newest.values.sorted { (a: AgentSession, b: AgentSession) -> Bool in
            a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.id < b.id
        }
    }

    /// One store's sessions, the newest 200 written.
    static func sessions(_ path: String, in folder: String, subfolders: Bool, since: Date?) throws -> [AgentSession] {
        let db = try AgentStoreDatabase(path)
        let table = db.columns("session_v2").isEmpty ? "session" : "session_v2"
        let columns = db.columns(table)
        guard ["id", "directory", "time_updated"].allSatisfy(columns.contains) else {
            throw AgentSessions.ReadError("the session table changed")
        }
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        var filters = ["(directory = ?1 OR (?2 = 1 AND substr(directory, 1, length(?1) + 1) = ?1 || '/'))", "time_updated >= ?3"]
        if columns.contains("parent_id") { filters.append("parent_id IS NULL") }
        if columns.contains("time_archived") { filters.append("time_archived IS NULL") }
        let picked = "SELECT id, directory, \(column("title")), \(column("time_created")), time_updated, \(column("model"))"
        let sql = picked + " FROM \(table) WHERE " + filters.joined(separator: " AND ") + " ORDER BY time_updated DESC LIMIT 200"
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

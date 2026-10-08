import Foundation

/// opencode: one SQLite file, `~/.local/share/opencode/opencode.db` (since v1.2). Its `session` table has
/// the folder each session was started in (`directory`), `title`, `time_created` and `time_updated` (ms),
/// `model` (JSON with its `id`), `parent_id` for a sub-agent's and `time_archived` for an archived one,
/// neither listed. Until the agent names a session its title is "New session - <time>", so the first
/// prompt (the first text part of its first user message) stands in; with no prompt either, the session
/// is empty. Resume with `opencode --session <id>` in the same folder.
struct OpencodeSessions: AgentSessionProvider {
    let home: String
    var agent: AgentKind { .opencode }

    func sessions(in folder: String, subfolders: Bool, since: Date?) throws -> [AgentSession] {
        let path = (home as NSString).appendingPathComponent(".local/share/opencode/opencode.db")
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let db = try AgentStoreDatabase(path)
        let columns = db.columns("session")
        guard ["id", "directory", "title", "time_updated"].allSatisfy(columns.contains) else {
            throw AgentSessions.ReadError("the session table changed")
        }
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        var filters = ["(directory = ?1 OR (?2 = 1 AND substr(directory, 1, length(?1) + 1) = ?1 || '/'))", "time_updated >= ?3"]
        if columns.contains("parent_id") { filters.append("parent_id IS NULL") }
        if columns.contains("time_archived") { filters.append("time_archived IS NULL") }
        let sql = "SELECT id, directory, title, \(column("time_created")), time_updated, \(column("model")) FROM session WHERE "
            + filters.joined(separator: " AND ") + " ORDER BY time_updated DESC LIMIT 200"
        let after = since.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0
        return db.rows(sql, [folder, subfolders ? 1 : 0, after]).compactMap { row -> AgentSession? in
            guard let id = row[0], let directory = row[1] else { return nil }
            var title = row[2] ?? ""
            if Self.isDefaultTitle(title) { title = Self.firstPrompt(db, session: id) ?? "" }
            guard !title.isEmpty else { return nil } // nothing was asked
            let created = AgentStoreFiles.date(milliseconds: row[3])
            let updated = AgentStoreFiles.date(milliseconds: row[4]) ?? created ?? .distantPast
            return AgentSession(agent: .opencode, id: id, cwd: directory, title: AgentSessions.clean(title), named: false,
                                createdAt: created, updatedAt: updated, gitBranch: nil, model: row[5].flatMap(Self.modelName),
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

    /// `{"id": "claude-sonnet-5", "providerID": "anthropic"}` → "claude-sonnet-5"; a plain string as it is.
    static func modelName(_ value: String) -> String? {
        guard value.hasPrefix("{") else { return value.isEmpty ? nil : value }
        let object = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any]
        return object?["id"] as? String
    }
}

import Foundation
import SQLite3
import Testing
@testable import NextTermCore

/// Gemini CLI, Qwen Code, opencode, Cursor Agent and Copilot CLI, each from a store made here by hand in
/// that agent's format (no real sessions), plus `newest` and which tab a session is open in.
@Suite struct AgentSessionsReadersTests {
    func home() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-readers-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(_ lines: [[String: Any]], to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func age(_ path: String, days: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86400)], ofItemAtPath: path)
    }

    func database(_ path: String, _ sql: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
    }

    // MARK: Gemini CLI

    @Test func geminiByItsProjectRegistry() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/Users/me/Code/app"
        let root = home + "/.gemini"
        try write(#"{"projects": {"/Users/me/Code/app": "app", "/Users/me/Code/app/web": "web", "/Users/me/Code/app2": "app-1", "/x": "../evil"}}"#,
                  to: root + "/projects.json")
        try write(project, to: root + "/tmp/app/.project_root")
        let chats = root + "/tmp/app/chats"
        func header(_ id: String, kind: String = "main") -> [String: Any] {
            ["sessionId": id, "projectHash": "h", "startTime": "2026-10-01T10:00:00.000Z", "lastUpdated": "2026-10-01T10:05:00.000Z", "kind": kind]
        }
        func user(_ text: Any) -> [String: Any] { ["id": UUID().uuidString, "timestamp": "2026-10-01T10:01:00.000Z", "type": "user", "content": text] }
        let reply: [String: Any] = ["id": "r", "timestamp": "2026-10-02T09:00:00.000Z", "type": "gemini", "content": "Done", "model": "gemini-3-pro"]
        try write([header("g1-0000-uuid"), user([["text": "/help"]]), user([["text": "Add a dark mode"]]), reply,
                   ["$set": ["summary": "Dark mode toggle", "lastUpdated": "2026-10-02T09:00:00.000Z"]]],
                  to: chats + "/session-2026-10-01T10-00-g1-0000.jsonl")
        try write([header("g2-0000-uuid"), user("Write the release notes")], to: chats + "/session-2026-10-03T08-00-g2-0000.jsonl")
        try write([header("g3-0000-uuid"), user("/model")], to: chats + "/session-2026-10-03T09-00-g3-0000.jsonl") // only a command
        try write([header("g4-0000-uuid", kind: "subagent"), user("look around")], to: chats + "/session-2026-10-03T10-00-g4-0000.jsonl")
        try write([header("sub-of-g1"), user("inner")], to: chats + "/g1-0000-uuid/sub-of-g1.jsonl") // a sub-agent's folder
        // A subfolder that has a short name of its own; a session from before JSONL (one whole JSON file) is not read.
        try write([header("g5-web"), user("Fix the build"), ["id": "2", "timestamp": "2026-10-01T10:02:00.000Z", "type": "gemini", "model": "gemini-2.5-pro"]],
                  to: root + "/tmp/web/chats/session-2026-10-01T10-00-g5-web.jsonl")
        try write(#"{"sessionId": "g7-legacy", "projectHash": "h", "startTime": "2026-09-20T10:00:00.000Z", "messages": [{"type": "user", "content": "old"}]}"#,
                  to: root + "/tmp/web/chats/session-2026-09-20T10-00-g7-lega.json")
        try write("/Users/me/Code/app/web", to: root + "/tmp/web/.project_root")
        // A folder Gemini has not run in since it named folders: the SHA-256 of its path.
        let old = "/Users/me/Code/old"
        try write([header("g6-hashed"), user("Old layout")], to: root + "/tmp/" + AgentStoreFiles.sha256(old) + "/chats/session-2026-09-01T10-00-g6-hashe.jsonl")

        let found = try GeminiSessions(home: home).sessions(in: project, subfolders: false, since: nil)
        #expect(Set(found.map(\.id)) == ["g1-0000-uuid", "g2-0000-uuid"])
        let first = try #require(found.first { $0.id == "g1-0000-uuid" })
        #expect(first.title == "Dark mode toggle" && !first.named && first.model == "gemini-3-pro" && first.cwd == project)
        #expect(first.createdAt == AgentSessions.parseDate("2026-10-01T10:00:00.000Z"))
        #expect(found.first { $0.id == "g2-0000-uuid" }?.title == "Write the release notes")
        let wide = try GeminiSessions(home: home).sessions(in: project, subfolders: true, since: nil)
        #expect(Set(wide.map(\.id)) == ["g1-0000-uuid", "g2-0000-uuid", "g5-web"])
        #expect(wide.first { $0.id == "g5-web" }.map { $0.title == "Fix the build" && $0.cwd == project + "/web" && $0.model == "gemini-2.5-pro" } == true)
        #expect(try GeminiSessions(home: home).sessions(in: old, subfolders: false, since: nil).map(\.title) == ["Old layout"])
        #expect(first.resumeCommand() == "gemini --resume g1-0000-uuid" && first.resumeCommand(fork: true) == "gemini --resume g1-0000-uuid")
        #expect(!AgentKind.gemini.canFork && AgentKind.gemini.continueCommand == "gemini --resume latest")
    }

    @Test func geminiNameTakenOverByAnotherFolder() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/.gemini"
        try write(#"{"projects": {"/a/app": "app"}}"#, to: root + "/projects.json")
        try write("/b/app", to: root + "/tmp/app/.project_root") // the marker says the name is someone else's now
        try write([["sessionId": "x", "startTime": "2026-10-01T10:00:00Z"], ["type": "user", "content": "hi"]], to: root + "/tmp/app/chats/session-1-x.jsonl")
        #expect(try GeminiSessions(home: home).sessions(in: "/a/app", subfolders: false, since: nil).isEmpty)
    }

    // MARK: Qwen Code

    @Test func qwenByRecordedFolder() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/Users/me/Code/my_app"
        let dir = home + "/.qwen/projects/" + QwenSessions.folderName(project) + "/chats"
        #expect(QwenSessions.folderName(project) == "-Users-me-Code-my-app")
        func record(_ type: String, _ fields: [String: Any] = [:], cwd: String = project) -> [String: Any] {
            var line: [String: Any] = ["uuid": UUID().uuidString, "parentUuid": NSNull(), "sessionId": "", "timestamp": "2026-10-01T10:00:00.000Z",
                                       "type": type, "cwd": cwd, "version": "0.25.0", "gitBranch": "main"]
            line.merge(fields) { $1 }
            return line
        }
        func user(_ text: String) -> [String: Any] { record("user", ["message": ["role": "user", "parts": [["text": text]]]]) }
        let id1 = "0a1b2c3d-0000-4000-8000-000000000001", id2 = "0a1b2c3d-0000-4000-8000-000000000002"
        let id3 = "0a1b2c3d-0000-4000-8000-000000000003", id4 = "0a1b2c3d-0000-4000-8000-000000000004"
        func session(_ id: String, _ lines: [[String: Any]]) -> [[String: Any]] {
            lines.map { var line = $0; line["sessionId"] = id; return line }
        }
        try write(session(id1, [user("Speed up the tests"),
                                record("assistant", ["model": "qwen3-coder-plus", "timestamp": "2026-10-02T10:00:00.000Z", "gitBranch": "perf"]),
                                record("system", ["subtype": "custom_title", "gitBranch": "perf",
                                                  "systemPayload": ["customTitle": "Faster tests", "titleSource": "manual"]])]),
                  to: dir + "/\(id1).jsonl")
        try write(session(id2, [user("Document the API"),
                                record("system", ["subtype": "custom_title", "systemPayload": ["customTitle": "API docs", "titleSource": "auto"]])]),
                  to: dir + "/\(id2).jsonl")
        try write(session(id3, [record("system", ["subtype": "parent_session", "systemPayload": ["parentSessionId": id1]]), user("child")]),
                  to: dir + "/\(id3).jsonl")
        // Same folder name, another folder (/Users/me/Code/my.app); an archived chat; a sidecar.
        try write(session(id4, [user("not this one")].map { var l = $0; l["cwd"] = "/Users/me/Code/my.app"; return l }), to: dir + "/\(id4).jsonl")
        try write(session(id1, [user("archived")]), to: dir + "/archive/\(id1).jsonl")
        try write("{}", to: dir + "/\(id1).worktree.json")

        let found = try QwenSessions(home: home).sessions(in: project, subfolders: false, since: nil)
        #expect(Set(found.map(\.id)) == [id1, id2])
        let named = try #require(found.first { $0.id == id1 })
        #expect(named.title == "Faster tests" && named.named && named.model == "qwen3-coder-plus" && named.gitBranch == "perf")
        let auto = try #require(found.first { $0.id == id2 })
        #expect(auto.title == "API docs" && !auto.named)
        #expect(named.resumeCommand() == "qwen --resume \(id1)" && named.resumeCommand(fork: true) == "qwen --resume \(id1) --fork-session")
    }

    // MARK: opencode

    @Test func opencodeFromItsDatabase() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/Users/me/Code/app"
        let sql = """
            CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT, directory TEXT, title TEXT, version TEXT,
              model TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
            INSERT INTO session VALUES ('ses_1', 'p', NULL, 's1', '\(project)', 'Refactor the router', '1.18.34',
              '{"id":"claude-sonnet-5","providerID":"anthropic"}', 1000, 9000, NULL);
            INSERT INTO session VALUES ('ses_2', 'p', NULL, 's2', '\(project)', 'New session - 2026-10-01T10:00:00.000Z', '1.18.34', NULL, 1000, 8000, NULL);
            INSERT INTO message VALUES ('msg_1', 'ses_2', 1, 1, '{"role":"user"}');
            INSERT INTO part VALUES ('prt_0', 'msg_1', 'ses_2', 1, 1, '{"type":"text","text":"context","synthetic":true}');
            INSERT INTO part VALUES ('prt_1', 'msg_1', 'ses_2', 1, 1, '{"type":"text","text":"Add pagination"}');
            INSERT INTO session VALUES ('ses_3', 'p', NULL, 's3', '\(project)', 'New session - 2026-10-01T11:00:00.000Z', '1.18.34', NULL, 1000, 7000, NULL);
            INSERT INTO session VALUES ('ses_4', 'p', 'ses_1', 's4', '\(project)', 'Child session - 2026-10-01T10:00:00.000Z', '1.18.34', NULL, 1000, 9500, NULL);
            INSERT INTO session VALUES ('ses_5', 'p', NULL, 's5', '\(project)', 'Old work', '1.18.34', NULL, 1000, 9500, 9600);
            INSERT INTO session VALUES ('ses_6', 'p', NULL, 's6', '\(project)2', 'Sibling', '1.18.34', NULL, 1000, 9500, NULL);
            INSERT INTO session VALUES ('ses_7', 'p', NULL, 's7', '\(project)/api', 'Inside', '1.18.34', NULL, 1000, 9500, NULL);
            """
        try database(home + "/.local/share/opencode/opencode.db", sql)
        let reader = OpencodeSessions(home: home)
        let found = try reader.sessions(in: project, subfolders: false, since: nil)
        #expect(found.map(\.id) == ["ses_1", "ses_2"]) // newest first; ses_3 never had a prompt
        #expect(found[0].title == "Refactor the router" && found[0].model == "claude-sonnet-5" && found[1].title == "Add pagination")
        #expect(found[0].updatedAt == Date(timeIntervalSince1970: 9))
        #expect(Set(try reader.sessions(in: project, subfolders: true, since: nil).map(\.id)) == ["ses_1", "ses_2", "ses_7"])
        #expect(try reader.sessions(in: project, subfolders: false, since: Date(timeIntervalSince1970: 8.5)).map(\.id) == ["ses_1"])
        #expect(found[0].resumeCommand() == "opencode --session ses_1" && found[0].resumeCommand(fork: true) == "opencode --session ses_1 --fork")
    }

    @Test func opencodeFirstPromptFromItsNewerMessageTable() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/Users/me/Code/app"
        // The newer runner keeps a session's messages in session_message only, `{"text": …}` with the type beside it.
        let sql = """
            CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT, model TEXT, time_created INTEGER,
              time_updated INTEGER, time_archived INTEGER);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
            CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER,
              time_updated INTEGER, data TEXT);
            INSERT INTO session VALUES ('ses_n', NULL, '\(project)', 'New session - 2026-10-01T10:00:00.000Z', NULL, 1000, 9000, NULL);
            INSERT INTO session_message VALUES ('m0', 'ses_n', 'synthetic', 1, 1, 1, '{"text":"context"}');
            INSERT INTO session_message VALUES ('m2', 'ses_n', 'user', 3, 3, 3, '{"text":"Then the tests"}');
            INSERT INTO session_message VALUES ('m1', 'ses_n', 'user', 2, 2, 2, '{"text":"Add pagination"}');
            INSERT INTO session VALUES ('ses_e', NULL, '\(project)', 'New session - 2026-10-01T11:00:00.000Z', NULL, 1000, 8000, NULL);
            """
        try database(home + "/.local/share/opencode/opencode.db", sql)
        let found = try OpencodeSessions(home: home).sessions(in: project, subfolders: false, since: nil)
        #expect(found.map(\.id) == ["ses_n"] && found.first?.title == "Add pagination") // ses_e never had a prompt
    }

    @Test func opencodeWithAnotherSchemaSaysSo() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try database(home + "/.local/share/opencode/opencode.db", "CREATE TABLE session (id TEXT, cwd TEXT);")
        #expect(throws: (any Error).self) { try OpencodeSessions(home: home).sessions(in: "/p", subfolders: false, since: nil) }
        // The listing leaves only that agent out.
        let listing = AgentSessions.list(project: "/p", home: home)
        #expect(listing.problems.keys.contains(.opencode) && listing.sessions.isEmpty)
    }

    // MARK: Cursor Agent

    @Test func cursorFromMetaAndStore() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/Users/me/Code/app"
        let base = home + "/.cursor/chats/" + AgentStoreFiles.md5(project)
        try write(#"{"schemaVersion": 1, "createdAtMs": 1759312800000, "updatedAtMs": 1759399200000, "hasConversation": true, "title": "Migrate to Vite", "cwd": "/Users/me/Code/app"}"#,
                  to: base + "/chat-1/meta.json")
        try write(#"{"schemaVersion": 1, "createdAtMs": 1759312800000, "hasConversation": false}"#, to: base + "/chat-2/meta.json")
        try write(#"{"schemaVersion": 1, "createdAtMs": 1759312800000, "hasConversation": true, "isSubagent": true, "title": "sub"}"#,
                  to: base + "/chat-3/meta.json")
        // An older build's chat: only the store, its metadata hex-encoded JSON.
        func hex(_ json: String) -> String { Data(json.utf8).map { String(format: "%02x", $0) }.joined() }
        let named = hex(#"{"agentId":"chat-4","latestRootBlobId":"ab12","name":"Fix flaky test","mode":"default","createdAt":1759226400000,"lastUsedModel":"gpt-5"}"#)
        try database(base + "/chat-4/store.db", "CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB); CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT); INSERT INTO meta VALUES ('0', '\(named)');")
        let empty = hex(#"{"agentId":"chat-5","latestRootBlobId":"","name":"New Agent","mode":"default","createdAt":1759226400000}"#)
        try database(base + "/chat-5/store.db", "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT); INSERT INTO meta VALUES ('0', '\(empty)');")
        // A subfolder's chat, found by the folder its meta.json records.
        try write(#"{"createdAtMs": 1759312800000, "hasConversation": true, "title": "Server work", "cwd": "/Users/me/Code/app/server"}"#,
                  to: home + "/.cursor/chats/" + AgentStoreFiles.md5(project + "/server") + "/chat-6/meta.json")

        let reader = CursorSessions(home: home)
        let found = try reader.sessions(in: project, subfolders: false, since: nil)
        #expect(Set(found.map(\.id)) == ["chat-1", "chat-4"])
        let meta = try #require(found.first { $0.id == "chat-1" })
        #expect(meta.title == "Migrate to Vite" && meta.updatedAt == Date(timeIntervalSince1970: 1759399200) && meta.cwd == project)
        let store = try #require(found.first { $0.id == "chat-4" })
        #expect(store.title == "Fix flaky test" && store.model == "gpt-5" && store.createdAt == Date(timeIntervalSince1970: 1759226400))
        #expect(Set(try reader.sessions(in: project, subfolders: true, since: nil).map(\.id)) == ["chat-1", "chat-4", "chat-6"])
        #expect(meta.resumeCommand() == "cursor-agent --resume=chat-1" && !AgentKind.cursor.canFork)
    }

    // MARK: Copilot CLI

    @Test func copilotFromWorkspaceFiles() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/Users/me/Code/app"
        let base = home + "/.copilot/session-state"
        try write("""
            id: 11111111-2222-4333-8444-555555555555
            cwd: /Users/me/Code/app
            git_root: /Users/me/Code/app
            repository: me/app
            host_type: github
            branch: feature/login
            name: "Login: the remember-me box"
            user_named: true
            summary_count: 0
            created_at: 2026-10-01T10:00:00.000Z
            updated_at: 2026-10-02T10:00:00.000Z
            """, to: base + "/11111111-2222-4333-8444-555555555555/workspace.yaml")
        try write([["type": "session.start", "data": ["context": ["cwd": project]], "timestamp": "2026-10-01T10:00:00.000Z"],
                   ["type": "user.message", "data": ["content": "Add a remember-me box"]],
                   ["type": "assistant.message", "data": ["content": "Done", "model": "claude-sonnet-5"]]],
                  to: base + "/11111111-2222-4333-8444-555555555555/events.jsonl")
        // No name yet: the first prompt stands in. It is open in a copilot (this test's pid stands in for it).
        try write("""
            id: 22222222-2222-4333-8444-555555555555
            cwd: /Users/me/Code/app
            user_named: false
            created_at: 2026-10-03T10:00:00.000Z
            """, to: base + "/22222222-2222-4333-8444-555555555555/workspace.yaml")
        try write([["type": "user.message", "data": ["content": "Why is CI red?"]]], to: base + "/22222222-2222-4333-8444-555555555555/events.jsonl")
        try write("", to: base + "/22222222-2222-4333-8444-555555555555/inuse.\(getpid()).lock")
        // Nothing asked yet, and another folder.
        try write("id: 3\ncwd: /Users/me/Code/app\n", to: base + "/33333333/workspace.yaml")
        try write("id: 4\ncwd: /Users/me/Code/other\nname: Other\n", to: base + "/44444444/workspace.yaml")

        let found = try CopilotSessions(home: home).sessions(in: project, subfolders: false, since: nil)
        #expect(Set(found.map(\.id)) == ["11111111-2222-4333-8444-555555555555", "22222222-2222-4333-8444-555555555555"])
        let named = try #require(found.first { $0.id.hasPrefix("1111") })
        #expect(named.title == "Login: the remember-me box" && named.named && named.gitBranch == "feature/login" && named.model == "claude-sonnet-5")
        #expect(named.createdAt == AgentSessions.parseDate("2026-10-01T10:00:00.000Z") && !named.isRunning)
        let open = try #require(found.first { $0.id.hasPrefix("2222") })
        #expect(open.title == "Why is CI red?" && !open.named && open.isRunning)
        #expect(named.resumeCommand() == "copilot --resume=11111111-2222-4333-8444-555555555555")
    }

    @Test func flatYAMLValues() {
        let yaml = """
            name: a very long session name that the yaml library folded onto
              a second line
            quoted: 'it''s'
            escaped: "tab\\there"
            empty:
            list:
              - one
            # a comment
            """
        let values = CopilotSessions.flatYAML(yaml)
        #expect(values["name"] == "a very long session name that the yaml library folded onto a second line")
        #expect(values["quoted"] == "it's" && values["escaped"] == "tab\there" && values["empty"] == "")
    }

    // MARK: newest, and the tab a session is open in

    @Test func newestSessionStartedAfterATime() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/Users/me/Code/app"
        let dir = home + "/.claude/projects/" + AgentSessions.claudeFolderName(project)
        let start = Date().addingTimeInterval(-600)
        func stamp(_ offset: TimeInterval) -> String { ISO8601DateFormatter().string(from: start.addingTimeInterval(offset)) }
        func session(_ prompt: String, at offset: TimeInterval, cwd: String = project) -> [[String: Any]] {
            [["type": "user", "cwd": cwd, "timestamp": stamp(offset), "message": ["content": prompt]]]
        }
        try write(session("before", at: -60), to: dir + "/old.jsonl")
        try write(session("first", at: 30), to: dir + "/a.jsonl")
        try write(session("then /clear", at: 90), to: dir + "/b.jsonl")
        try write(session("in a subfolder", at: 120, cwd: project + "/src"), to: home + "/.claude/projects/" + AgentSessions.claudeFolderName(project + "/src") + "/c.jsonl")
        // A file last written well before `start` is not read at all.
        try write(session("stale but says later", at: 200), to: dir + "/stale.jsonl")
        try age(dir + "/stale.jsonl", days: 2)

        #expect(AgentSessions.newest(agent: .claude, in: project, after: start, home: home)?.id == "b")
        #expect(AgentSessions.newest(agent: .claude, in: project, after: start.addingTimeInterval(100), home: home) == nil)
        #expect(AgentSessions.newest(agent: .codex, in: project, after: start, home: home) == nil)
        #expect(AgentSessions.newest(agent: .claude, in: project + "/src", after: start, home: home)?.id == "c")
    }

    @Test func newestForEachNewReader() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/Users/me/Code/app"
        let earlier = Date().addingTimeInterval(-3600)
        let iso = ISO8601DateFormatter()
        let chats = home + "/.qwen/projects/" + QwenSessions.folderName(project) + "/chats"
        let ids = ["0a1b2c3d-0000-4000-8000-00000000000a", "0a1b2c3d-0000-4000-8000-00000000000b"]
        for (offset, id) in ids.enumerated() {
            try write([["sessionId": id, "cwd": project, "type": "user", "timestamp": iso.string(from: earlier.addingTimeInterval(Double(offset) * 60 + 60)),
                        "message": ["parts": [["text": "task \(offset)"]]]]], to: chats + "/\(id).jsonl")
        }
        #expect(AgentSessions.newest(agent: .qwen, in: project, after: earlier, home: home)?.id == ids[1])
        let copilot = home + "/.copilot/session-state/c1"
        try write("id: c1\ncwd: \(project)\nname: Ship it\ncreated_at: \(iso.string(from: earlier.addingTimeInterval(30)))\n", to: copilot + "/workspace.yaml")
        #expect(AgentSessions.newest(agent: .copilot, in: project, after: earlier, home: home)?.id == "c1")
        #expect(AgentSessions.newest(agent: .copilot, in: project, after: Date(), home: home) == nil)
    }

    @Test func newestSkipsCommandCodeFilesWrittenBefore() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/Users/me/Code/app"
        let dir = home + "/.commandcode/projects/users-me-code-app"
        let after = Date().addingTimeInterval(-86400)
        let later = ISO8601DateFormatter().string(from: after.addingTimeInterval(60))
        try write([["type": "session", "version": 3, "id": "cc1", "timestamp": later, "cwd": project]], to: dir + "/cc1.jsonl")
        try write([["id": "k", "prompt": "Refactor the billing"]], to: dir + "/cc1.checkpoints.jsonl")
        #expect(AgentSessions.newest(agent: .commandCode, in: project, after: after, home: home)?.id == "cc1")
        // Last written two days ago, whatever its header says: not read at all.
        try age(dir + "/cc1.jsonl", days: 2)
        #expect(AgentSessions.newest(agent: .commandCode, in: project, after: after, home: home) == nil)
    }

    @Test func resumedIDsFromCommandLines() {
        #expect(AgentKind.claude.resumedID(in: "claude --resume 0a1b") == "0a1b")
        #expect(AgentKind.claude.resumedID(in: "cd ~/app && claude -r 'abc-def'") == "abc-def")
        #expect(AgentKind.claude.resumedID(in: "claude --resume abc --fork-session") == nil) // a fork has an id of its own
        #expect(AgentKind.claude.resumedID(in: "claude --continue") == nil)
        #expect(AgentKind.claude.resumedID(in: "claude") == nil)
        #expect(AgentKind.codex.resumedID(in: "codex resume t1 -C /Users/me/app") == "t1")
        #expect(AgentKind.codex.resumedID(in: "codex resume -C /Users/me/app t1") == "t1")
        #expect(AgentKind.codex.resumedID(in: "codex resume --last") == nil && AgentKind.codex.resumedID(in: "codex fork t1") == nil)
        #expect(AgentKind.commandCode.resumedID(in: "command-code --resume c1") == "c1")
        #expect(AgentKind.commandCode.resumedID(in: "cmd --session /h/.commandcode/projects/p/c2.jsonl") == "c2")
        #expect(AgentKind.gemini.resumedID(in: "gemini --resume g1") == "g1")
        #expect(AgentKind.gemini.resumedID(in: "gemini --resume latest") == nil && AgentKind.gemini.resumedID(in: "gemini -r 3") == nil)
        #expect(AgentKind.qwen.resumedID(in: "qwen --resume q1") == "q1")
        #expect(AgentKind.opencode.resumedID(in: "opencode -s ses_1") == "ses_1" && AgentKind.opencode.resumedID(in: "opencode -s ses_1 --fork") == nil)
        #expect(AgentKind.cursor.resumedID(in: "cursor-agent --resume=chat-1") == "chat-1")
        #expect(AgentKind.copilot.resumedID(in: "copilot --resume=1111") == "1111")
        #expect(AgentKind.claude.resumedID(in: "codex resume t1") == nil) // another agent's command
        #expect(AgentKind(program: "commandcode") == .commandCode && AgentKind(program: "cursor-agent") == .cursor && AgentKind(program: "vim") == nil)
    }

    @Test func openSessionsInTabs() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/Users/me/Code/app"
        let dir = home + "/.claude/projects/" + AgentSessions.claudeFolderName(project)
        let first = Date().addingTimeInterval(-600), second = Date().addingTimeInterval(-300)
        let iso = ISO8601DateFormatter()
        func session(_ prompt: String, at date: Date, then later: Date? = nil) -> [[String: Any]] {
            var lines: [[String: Any]] = [["type": "user", "cwd": project, "timestamp": iso.string(from: date), "message": ["content": prompt]]]
            if let later { lines.append(["type": "assistant", "cwd": project, "timestamp": iso.string(from: later), "message": ["model": "m"]]) }
            return lines
        }
        try write(session("tab one's", at: first.addingTimeInterval(5)), to: dir + "/one.jsonl")
        try write(session("tab two's", at: second.addingTimeInterval(5)), to: dir + "/two.jsonl")
        try write(session("continued", at: first.addingTimeInterval(-3600), then: second.addingTimeInterval(10)), to: dir + "/old.jsonl")
        let running = [
            RunningAgent(key: "A", agent: .claude, directory: project, commandLine: "claude", startedAt: first),
            RunningAgent(key: "B", agent: .claude, directory: project, commandLine: "claude", startedAt: second),
            RunningAgent(key: "C", agent: .codex, directory: project, commandLine: "codex resume t9 -C /x", startedAt: second),
            RunningAgent(key: "D", agent: .copilot, directory: project, commandLine: "copilot --resume=11111111", startedAt: second),
        ]
        let open = AgentSessions.openSessions(running, home: home)
        // Each plain `claude` gets the session it started; a resume command names its own.
        #expect(open["claude:two"] == "B" && open["claude:one"] == "A" && open["codex:t9"] == "C")
        let copilot = AgentSession(agent: .copilot, id: "11111111-2222", cwd: project, title: "t", named: false, createdAt: nil,
                                   updatedAt: Date(), gitBranch: nil, model: nil, isRunning: false)
        #expect(AgentSessions.tab(of: copilot, in: open) == "D")
        // `claude --continue` picks the one it went on writing to.
        let continued = AgentSessions.openSessions([RunningAgent(key: "E", agent: .claude, directory: project, commandLine: "claude --continue",
                                                                 startedAt: second.addingTimeInterval(8))], home: home)
        #expect(continued["claude:old"] == "E")
    }

    @Test func everyAgentHasItsCommands() {
        func session(_ agent: AgentKind, _ id: String) -> AgentSession {
            AgentSession(agent: agent, id: id, cwd: "/p", title: "t", named: false, createdAt: nil, updatedAt: Date(),
                         gitBranch: nil, model: nil, isRunning: false)
        }
        for agent in AgentKind.allCases {
            #expect(session(agent, "id 1").resumeCommand().contains("'id 1'"), "\(agent)") // quoted for the shell
            // A tab running the command is seen to have that session open.
            #expect(agent.resumedID(in: session(agent, "0a1b-2c3d").resumeCommand()) == "0a1b-2c3d", "\(agent)")
            #expect(agent.resumedID(in: agent.continueCommand) == nil && !agent.shortName.isEmpty, "\(agent)")
        }
    }
}

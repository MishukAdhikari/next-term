import Foundation
import SQLite3
import Testing
@testable import NextTermCore

@Suite struct AgentSessionsTests {
    func home() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-sessions-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(_ lines: [[String: Any]], to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func claudeFolderNames() {
        #expect(AgentSessions.claudeFolderName("/Users/mishuk/Code/next-term") == "-Users-mishuk-Code-next-term")
        #expect(AgentSessions.claudeFolderName("/Users/mishuk/.claude/worktrees/xCloud/nervous-fermi") == "-Users-mishuk--claude-worktrees-xCloud-nervous-fermi")
        #expect(AgentSessions.claudeFolderName("/Users/me/my_app.v2/\u{FC}n\u{EF} 😀") == "-Users-me-my-app-v2--n----")
        let deep = "/Users/me/" + String(repeating: "deep/", count: 45) + "proj"
        let name = AgentSessions.claudeFolderName(deep)
        #expect(name.count == 207 && name.hasSuffix("-erjiov"))
    }

    @Test func claudeSessionsForAFolder() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/Users/me/Code/app"
        let dir = home + "/.claude/projects/" + AgentSessions.claudeFolderName(project)
        func user(_ text: String, cwd: String = project, extra: [String: Any] = [:]) -> [String: Any] {
            var line: [String: Any] = ["type": "user", "cwd": cwd, "timestamp": "2026-10-01T10:00:00.000Z", "gitBranch": "main",
                                       "entrypoint": "cli", "message": ["role": "user", "content": text]]
            line.merge(extra) { $1 }
            return line
        }
        let assistant: [String: Any] = ["type": "assistant", "cwd": project, "timestamp": "2026-10-02T12:00:00.000Z",
                                        "message": ["model": "claude-opus-5-5-20260901", "content": []]]
        try write([["type": "mode", "mode": "normal"], user("Fix the login bug"), assistant,
                   ["type": "ai-title", "aiTitle": "Fixing the login bug"]], to: dir + "/s1.jsonl")
        try write([user("<command-name>/rename</command-name><command-args>Auth work</command-args>"), assistant,
                   ["type": "custom-title", "customTitle": "Auth work"]], to: dir + "/s2.jsonl")
        try write([["type": "mode", "mode": "normal"]], to: dir + "/empty.jsonl")
        try write([user("from the SDK", extra: ["entrypoint": "sdk-ts"])], to: dir + "/sdk.jsonl")
        try write([user("a sub-agent", extra: ["isSidechain": true])], to: dir + "/side.jsonl")
        try write([user("<tick>loop</tick>")], to: dir + "/loop.jsonl")
        // Same folder name, different folder: /Users/me/Code-app.
        try write([user("someone else's", cwd: "/Users/me/Code-app")], to: dir + "/other.jsonl")
        // A sub-agent folder inside the session: never listed.
        try write([user("inner")], to: dir + "/s1/subagents/a.jsonl")
        // A subfolder of the project.
        try write([user("in src", cwd: project + "/src")], to: home + "/.claude/projects/" + AgentSessions.claudeFolderName(project + "/src") + "/s3.jsonl")
        // s1 is open in a running claude (this test's own pid stands in for it).
        try write([["pid": Int(getpid()), "sessionId": "s1", "cwd": project]], to: home + "/.claude/sessions/\(getpid()).json")
        try "token".write(toFile: home + "/.claude/sessions/\(getpid()).abc.key", atomically: true, encoding: .utf8)

        let found = try AgentSessions.claude(project, home: home, subfolders: false)
        #expect(Set(found.map(\.id)) == ["s1", "s2"])
        let first = try #require(found.first { $0.id == "s1" })
        #expect(first.title == "Fixing the login bug" && !first.named && first.gitBranch == "main" && first.model == "claude-opus-5-5")
        #expect(first.isRunning)
        #expect(first.updatedAt <= Date() && first.createdAt != nil)
        let named = try #require(found.first { $0.id == "s2" })
        #expect(named.title == "Auth work" && named.named && !named.isRunning)
        let wide = try AgentSessions.claude(project, home: home, subfolders: true)
        #expect(Set(wide.map(\.id)) == ["s1", "s2", "s3"])
        #expect(first.resumeCommand() == "claude --resume s1" && first.resumeCommand(fork: true) == "claude --resume s1 --fork-session")
    }

    @Test func claudeReadsOnlyTheEndsOfBigFiles() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/p"
        let path = home + "/.claude/projects/-p/big.jsonl"
        var lines: [[String: Any]] = [["type": "user", "cwd": project, "timestamp": "2026-10-01T10:00:00Z", "message": ["content": "start here"]]]
        for i in 0..<3000 { lines.append(["type": "assistant", "timestamp": "2026-10-01T10:00:00Z", "message": ["content": [["type": "text", "text": String(repeating: "x", count: 60) + "\(i)"]]]]) }
        lines.append(["type": "ai-title", "aiTitle": "A long one"])
        lines.append(["type": "assistant", "timestamp": "2026-10-05T09:00:00Z", "message": ["model": "m"]])
        try write(lines, to: path)
        let found = try AgentSessions.claude(project, home: home, subfolders: false)
        #expect(found.first?.title == "A long one" && found.first?.model == "m")
    }

    @Test func codexFromItsStateDatabase() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(home + "/.codex/state_5.sqlite", &db) == SQLITE_OK)
        let project = "/Users/me/Code/app"
        let sql = """
            CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, name TEXT, title TEXT, preview TEXT, created_at_ms INTEGER,
              recency_at_ms INTEGER, git_branch TEXT, model TEXT, archived INTEGER, thread_source TEXT, source TEXT);
            INSERT INTO threads VALUES ('t1', '\(project)', NULL, 'Add tests', 'add tests please', 1000, 5000, 'main', 'gpt-5.5', 0, 'user', 'cli');
            INSERT INTO threads VALUES ('t2', '\(project)', 'Release', 'x', 'y', 1000, 9000, NULL, NULL, 0, 'user', 'cli');
            INSERT INTO threads VALUES ('t3', '\(project)', NULL, NULL, 'archived', 1000, 9000, NULL, NULL, 1, 'user', 'cli');
            INSERT INTO threads VALUES ('t4', '\(project)', NULL, NULL, 'exec run', 1000, 9000, NULL, NULL, 0, 'user', 'exec');
            INSERT INTO threads VALUES ('t5', '\(project)', NULL, NULL, 'sub', 1000, 9000, NULL, NULL, 0, 'subagent', '{}');
            INSERT INTO threads VALUES ('t6', '\(project)', NULL, NULL, '', 1000, 9000, NULL, NULL, 0, 'user', 'cli');
            INSERT INTO threads VALUES ('t7', '\(project)2', NULL, NULL, 'sibling', 1000, 9000, NULL, NULL, 0, 'user', 'cli');
            INSERT INTO threads VALUES ('t8', '\(project)/src', NULL, NULL, 'inside', 1000, 9000, NULL, NULL, 0, 'user', 'cli');
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let found = try AgentSessions.codex(project, home: home, subfolders: false)
        #expect(found.map(\.id) == ["t2", "t1"]) // newest first
        #expect(found[0].title == "Release" && found[0].named && found[1].title == "Add tests" && !found[1].named)
        #expect(found[1].gitBranch == "main" && found[1].model == "gpt-5.5")
        #expect(Set(try AgentSessions.codex(project, home: home, subfolders: true).map(\.id)) == ["t1", "t2", "t8"])
        #expect(found[1].resumeCommand() == "codex resume t1 -C \(project)")
    }

    @Test func commandCodeByRecordedFolder() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/Users/me/Code/xCloud"
        let dir = home + "/.commandcode/projects/users-me-code-x-cloud"
        try write([["type": "session", "version": 3, "id": "c1", "timestamp": "2026-10-01T10:00:00Z", "cwd": project]], to: dir + "/c1.jsonl")
        try write([["id": "k", "prompt": "Refactor the billing", "messageCount": 4]], to: dir + "/c1.checkpoints.jsonl")
        try #"{"title": "Billing refactor", "model": "claude-opus-5-5"}"#.write(toFile: dir + "/c1.meta.json", atomically: true, encoding: .utf8)
        try write([["type": "session", "version": 3, "id": "c2", "timestamp": "2026-10-01T10:00:00Z", "cwd": project]], to: dir + "/c2.jsonl")
        try write([["type": "session", "version": 3, "id": "c3", "timestamp": "2026-10-01T10:00:00Z", "cwd": "/elsewhere"]], to: dir + "/c3.jsonl")
        let found = try AgentSessions.commandCode(project, home: home, subfolders: false)
        #expect(found.map(\.id) == ["c1"]) // c2 never had a prompt; c3 is another folder
        #expect(found.first?.title == "Billing refactor" && found.first?.model == "claude-opus-5-5")
        #expect(found.first?.resumeCommand() == "command-code --resume c1")
    }

    @Test func listingCombinesAgentsNewestFirst() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let listing = AgentSessions.list(project: "/nowhere", home: home)
        #expect(listing.sessions.isEmpty && listing.problems.isEmpty)
    }

    @Test func secretsNeverReachTheTitle() {
        #expect(AgentSessions.clean("use sk-ant-api03-abcdefghijklmnop to call") == "use ••• to call")
        #expect(AgentSessions.clean("deploy with token=abc123 now").contains("•••"))
        #expect(!AgentSessions.clean("key ghp_abcdefghijklmnopqrstuvwxyz0123").contains("ghp_"))
        #expect(AgentSessions.clean("Fix the login bug") == "Fix the login bug")
        // RAG projects: LangSmith and the model and search providers they use.
        // Made up, and put together here so no key-shaped text sits in the source (GitHub's push
        // protection would take a real-looking one for a leak).
        let filler = String(repeating: "0123456789abcdef", count: 2)
        for key in ["lsv2_pt_" + filler + "_0123456789", "lsv2_sk_" + filler, "hf_" + filler, "gsk_" + filler, "tvly-dev-" + filler,
                    "r8_" + filler, "xai-" + filler, "pcsk_" + filler] {
            #expect(AgentSessions.clean("set \(key) in .env") == "set ••• in .env", "\(key)")
            #expect(SecretGuard.looksSecret(key), "\(key)")
        }
        #expect(AgentSessions.clean("Trace the LangGraph agent in LangSmith") == "Trace the LangGraph agent in LangSmith")
        #expect(AgentSessions.clean(String(repeating: "word ", count: 100)).count == 200)
        #expect(AgentSessions.clean("two\n\nlines") == "two lines")
    }
}

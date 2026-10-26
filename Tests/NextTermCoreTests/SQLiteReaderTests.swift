import Foundation
import SQLite3
import Testing
@testable import NextTermCore

@Suite struct SQLiteReaderTests {
    /// A Laravel-shaped database: users (2,500 rows), migrations, a view, and an awkward table name.
    static func makeDatabase(wal: Bool = false) -> (FixtureProject, String) {
        let project = FixtureProject()
        let path = project.root + "/database/database.sqlite"
        try? FileManager.default.createDirectory(atPath: project.root + "/database", withIntermediateDirectories: true)
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        var sql = """
        CREATE TABLE migrations (id INTEGER PRIMARY KEY, migration TEXT NOT NULL, batch INTEGER NOT NULL);
        INSERT INTO migrations (migration, batch) VALUES ('0001_01_01_000000_create_users_table', 1);
        CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT, score REAL, avatar BLOB, note TEXT);
        CREATE VIEW active_users AS SELECT id, name FROM users WHERE id % 2 = 0;
        CREATE TABLE [odd "name"] (x);
        BEGIN;
        """
        let firstNote = "'line one\nline, \"two\" | pipe'"
        for i in 1...2500 {
            let note = i == 1 ? firstNote : "NULL"
            sql += "INSERT INTO users (name, email, score, avatar, note) VALUES ('User \(i)', 'user\(i)@example.com', \(Double(i) / 4), x'00ff10', \(note));\n"
        }
        sql += "COMMIT;"
        if wal { sql = "PRAGMA journal_mode = WAL;" + sql }
        sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
        return (project, path)
    }

    @Test func tablesPagesAndCounts() throws {
        let (project, path) = Self.makeDatabase()
        _ = project
        let tables = try SQLiteReader.tables(at: path)
        #expect(tables.map(\.name) == ["migrations", "odd \"name\"", "users", "active_users"])
        #expect(tables.last?.isView == true)
        #expect(try SQLiteReader.count("users", at: path) == 2500)
        #expect(try SQLiteReader.count("odd \"name\"", at: path) == 0)
        let first = try SQLiteReader.page("users", at: path, offset: 0)
        #expect(first.columns == ["id", "name", "email", "score", "avatar", "note"])
        #expect(first.rows.count == 1000)
        #expect(first.rows[0] == [.integer(1), .text("User 1", truncated: false), .text("user1@example.com", truncated: false), .real(0.25),
                                  .blob(3, head: Data([0x00, 0xFF, 0x10])), .text("line one\nline, \"two\" | pipe", truncated: false)])
        let last = try SQLiteReader.page("users", at: path, offset: 2000)
        #expect(last.rows.count == 500 && last.offset == 2000 && last.rows.last?.first == .integer(2500))
        #expect(try SQLiteReader.page("active_users", at: path, offset: 0, limit: 2).rows == [[.integer(2), .text("User 2", truncated: false)], [.integer(4), .text("User 4", truncated: false)]])
    }

    @Test func readingLeavesTheFileAndFolderAlone() throws {
        for wal in [false, true] {
            let (project, path) = Self.makeDatabase(wal: wal)
            let folder = project.root + "/database"
            let before = try FileManager.default.contentsOfDirectory(atPath: folder).sorted()
            let bytes = FileManager.default.contents(atPath: path)
            let stamp = FileStamp(path: path)
            _ = try SQLiteReader.tables(at: path)
            _ = try SQLiteReader.page("users", at: path, offset: 0)
            _ = try SQLiteReader.value("users", column: "note", key: .rowid(name: "rowid", value: 1), at: path)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder).sorted() == before, "wal \(wal)")
            #expect(FileManager.default.contents(atPath: path) == bytes && FileStamp(path: path) == stamp)

            let store = AgentStore(wal: wal)
            let listed = try FileManager.default.contentsOfDirectory(atPath: store.folder).sorted()
            let storeBytes = FileManager.default.contents(atPath: store.path)
            let storeStamp = FileStamp(path: store.path)
            for table in try SQLiteReader.tables(at: store.path) { _ = try SQLiteReader.page(table.name, at: store.path, offset: 0) }
            _ = try SQLiteReader.value("messages", column: "content", key: .rowid(name: "rowid", value: 2), at: store.path)
            _ = try SQLiteReader.value("kv", column: "v", key: AgentStore.kvKey("notes"), at: store.path)
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.folder).sorted() == listed, "agent store, wal \(wal)")
            #expect(FileManager.default.contents(atPath: store.path) == storeBytes && FileStamp(path: store.path) == storeStamp)
        }
    }

    @Test func kindsComeFromTheTableList() throws {
        let store = AgentStore()
        let tables = try SQLiteReader.tables(at: store.path)
        let kinds = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0.kind) })
        #expect(kinds["messages"] == .table && kinds["hide"] == .table && kinds["pairs"] == .withoutRowid)
        #expect(kinds["kv"] == .withoutRowid && kinds["recent"] == .view && kinds["messages_fts"] == .virtual)
        let shadows = ["messages_fts_data", "messages_fts_idx", "messages_fts_content", "messages_fts_docsize", "messages_fts_config"]
        #expect(shadows.allSatisfy { kinds[$0] == .shadow }, "\(kinds)")
        #expect(kinds["messages_fts_notes"] == .shadow, "named after the virtual table, so taken for one of its own")
        #expect(tables.last?.name == "recent" && tables.last?.isView == true && !tables.contains { $0.name.hasPrefix("sqlite_") })
        #expect(SQLiteReader.isShadowName("Docs_extra", of: ["docs"]) && !SQLiteReader.isShadowName("docsextra", of: ["docs"]))
    }

    @Test func pagesCarryEachRowsKey() throws {
        let (project, path) = Self.makeDatabase()
        _ = project
        let users = try SQLiteReader.page("users", at: path, offset: 10, limit: 5)
        #expect(users.columns == ["id", "name", "email", "score", "avatar", "note"])
        #expect(users.keys == (11...15).map { SQLiteRowKey.rowid(name: "rowid", value: Int64($0)) })
        #expect(users.rows.map { $0[0] } == (11...15).map { SQLiteValue.integer(Int64($0)) })
        #expect(users.info?.kind == .table && users.info?.rowidAlias == "id" && users.info?.isKey("id") == true && users.info?.isKey("name") == false)
        #expect(users.row(for: .rowid(name: "rowid", value: 13)) == 2)
        let view = try SQLiteReader.page("active_users", at: path, offset: 0, limit: 3)
        #expect(view.keys == [nil, nil, nil] && view.info?.kind == .view && view.info?.rowidName == nil)

        let store = AgentStore()
        let kv = try SQLiteReader.page("kv", at: store.path, offset: 0)
        #expect(kv.keys == kv.rows.map { row in .primaryKey([SQLiteKeyPart(column: "k", value: row[0])]) })
        #expect(kv.keys.first == AgentStore.kvKey("accents") && kv.info?.isKey("k") == true && kv.info?.isKey("v") == false)
        let pairs = try SQLiteReader.page("pairs", at: store.path, offset: 0)
        #expect(pairs.keys.first == .primaryKey([SQLiteKeyPart(column: "a", value: .text("x", truncated: false)), SQLiteKeyPart(column: "b", value: .integer(1))]))
        let hide = try SQLiteReader.page("hide", at: store.path, offset: 0)
        #expect(hide.columns == ["rowid", "_rowid_", "oid"] && hide.rows == [[.integer(7), .integer(8), .integer(9)]])
        #expect(hide.info?.rowidName == nil && hide.keys == [nil])
        let fts = try SQLiteReader.page("messages_fts", at: store.path, offset: 0)
        #expect(fts.columns == ["content"] && fts.keys.allSatisfy { $0 == nil } && fts.info?.kind == .virtual)
        let messages = try SQLiteReader.page("messages", at: store.path, offset: 0)
        #expect(messages.info?.column(named: "created")?.notNull == true && messages.info?.column(named: "content")?.declaredType == "TEXT")
        let generated = try SQLiteReader.page("totals", at: store.path, offset: 0)
        #expect(generated.columns == ["a", "doubled"] && generated.info?.column(named: "doubled")?.isGenerated == true)
    }

    @Test func blobsKeepTheirFirstBytes() throws {
        let store = AgentStore()
        let page = try SQLiteReader.page("messages", at: store.path, offset: 0)
        guard page.rows.count > 2, case let .blob(size, head) = page.rows[2][4] else { return #expect(Bool(false), "row 3 has its attachment") }
        #expect(size == 3072 && head == AgentStore.png.prefix(256) && head.count == 256)
        #expect(page.rows[2][4].display == "BLOB, 3,072 bytes")
        let (project, path) = Self.makeDatabase()
        _ = project
        let small = try SQLiteReader.page("users", at: path, offset: 0, limit: 1)
        #expect(small.rows[0][4] == .blob(3, head: Data([0x00, 0xFF, 0x10])))
    }

    @Test func oneValueReadWholeByItsKey() throws {
        let store = AgentStore()
        let page = try SQLiteReader.page("messages", at: store.path, offset: 0)
        guard page.rows.count > 1, case let .text(cut, truncated) = page.rows[1][2] else { return #expect(Bool(false), "row 2's content") }
        #expect(truncated && cut.count == SQLiteReader.maxCellCharacters)
        let key = try #require(page.keys[1])
        #expect(try SQLiteReader.value("messages", column: "content", key: key, at: store.path) == .text(AgentStore.long, truncated: false))
        let notes = try SQLiteReader.value("kv", column: "v", key: AgentStore.kvKey("notes"), at: store.path)
        #expect(notes == .text(AgentStore.long, truncated: false))
        guard case let .text(head, headCut)? = try SQLiteReader.value("messages", column: "content", key: key, at: store.path, limit: 1000) else {
            return #expect(Bool(false), "a value cut at its limit")
        }
        #expect(headCut && head.utf8.count <= 1000 && AgentStore.long.hasPrefix(head))
        // Never inside a character: "é" is two bytes.
        guard case let .text(accents, accentsCut)? = try SQLiteReader.value("kv", column: "v", key: AgentStore.kvKey("accents"), at: store.path, limit: 1001) else {
            return #expect(Bool(false), "the accented value")
        }
        #expect(accentsCut && accents == String(repeating: "é", count: 500))
        #expect(try SQLiteReader.value("kv", column: "v", key: AgentStore.kvKey("missing"), at: store.path) == nil)
    }

    /// A view written with double-quoted strings, as many are, reads: the reader leaves SQLite's default.
    @Test func aViewWithDoubleQuotedStringsReads() throws {
        let project = FixtureProject()
        let path = project.root + "/views.db"
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        sqlite3_exec(db, """
            CREATE TABLE t (id INTEGER PRIMARY KEY, status TEXT, name TEXT);
            INSERT INTO t (status, name) VALUES ('active', 'a'), ('gone', 'b'), ('active', 'c');
            CREATE VIEW v AS SELECT name FROM t WHERE status = "active";
            """, nil, nil, nil)
        sqlite3_close(db)
        #expect(try SQLiteReader.tables(at: path).map(\.name) == ["t", "v"])
        #expect(try SQLiteReader.count("v", at: path) == 2)
        let page = try SQLiteReader.page("v", at: path, offset: 0)
        #expect(page.columns == ["name"] && page.rows == [[.text("a", truncated: false)], [.text("c", truncated: false)]] && page.info?.columns.count == 1)
        // Reading one value by its key, every name is the viewer's own: one that names nothing fails.
        #expect(throws: SQLiteReader.ReadError.self) { try SQLiteReader.value("t", column: "missing", key: .rowid(name: "rowid", value: 1), at: path) }
        let store = AgentStore()
        #expect(throws: SQLiteReader.ReadError.self) { try SQLiteReader.value("kv", column: "rowid", key: AgentStore.kvKey("theme"), at: store.path) }
    }

    /// A page of an ordinary table reads each blob's size and first bytes without loading it; a WITHOUT
    /// ROWID table's and a generated column's come with the row.
    @Test func blobsAreReadByTheirFirstBytes() throws {
        let project = FixtureProject()
        let path = project.root + "/blobs.db"
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        sqlite3_exec(db, """
            CREATE TABLE b (id INTEGER PRIMARY KEY, data BLOB, copy BLOB GENERATED ALWAYS AS (data) VIRTUAL, note TEXT);
            CREATE TABLE w (k TEXT PRIMARY KEY, data BLOB) WITHOUT ROWID;
            CREATE TABLE g (id INTEGER PRIMARY KEY, n INTEGER, twice INTEGER GENERATED ALWAYS AS (n * 2) VIRTUAL, data BLOB, tail BLOB);
            INSERT INTO b (data, note) VALUES (randomblob(1000000), 'big'), (x'', 'empty'), (NULL, 'none'), (x'0102', 'small');
            INSERT INTO w VALUES ('k', x'0a0b0c');
            INSERT INTO g (n, data, tail) VALUES (1, x'0a0b', x'0c0d0e');
            """, nil, nil, nil)
        sqlite3_close(db)
        let page = try SQLiteReader.page("b", at: path, offset: 0)
        #expect(page.columns == ["id", "data", "copy", "note"])
        guard case let .blob(size, head) = page.rows[0][1] else { return #expect(Bool(false), "a blob") }
        #expect(size == 1_000_000 && head.count == 256)
        #expect(page.rows[0][2] == .blob(1_000_000) || page.rows[0][2] == .blob(1_000_000, head: head), "a generated blob: its size, its bytes if they can be read")
        #expect(page.rows[1][1] == .blob(0) && page.rows[2][1] == .null && page.rows[3][1] == .blob(2, head: Data([1, 2])))
        #expect(page.rows.map { $0[3] } == ["big", "empty", "none", "small"].map { SQLiteValue.text($0, truncated: false) })
        #expect(page.keys == (1...4).map { .rowid(name: "rowid", value: Int64($0)) })
        let w = try SQLiteReader.page("w", at: path, offset: 0)
        #expect(w.rows == [[.text("k", truncated: false), .blob(3, head: Data([0x0A, 0x0B, 0x0C]))]])
        // A blob stored after a virtual column: the SQLite of macOS 13 to 15 opens a blob there at the wrong place.
        let g = try SQLiteReader.page("g", at: path, offset: 0)
        #expect(g.rows == [[.integer(1), .integer(1), .integer(2), .blob(2, head: Data([0x0A, 0x0B])), .blob(3, head: Data([0x0C, 0x0D, 0x0E]))]])
    }

    @Test func oneRowReadAgainByItsKey() throws {
        let store = AgentStore()
        let page = try SQLiteReader.page("messages", at: store.path, offset: 0)
        try SQLiteReader.withDatabase(store.path) { db in
            let info = try #require(page.info)
            let row = try #require(try SQLiteReader.row("messages", key: .rowid(name: "rowid", value: 3), info: info, db))
            #expect(row.map(\.column) == page.columns && row.map(\.value) == page.rows[2])
            #expect(try SQLiteReader.row("messages", key: .rowid(name: "rowid", value: 99), info: info, db) == nil)
            let kv = try #require(try SQLiteReader.page("kv", at: store.path, offset: 0).info)
            #expect(try SQLiteReader.row("kv", key: AgentStore.kvKey("theme"), info: kv, db)?.map(\.value) == [.text("theme", truncated: false), .text("dark", truncated: false)])
        }
    }

    @Test func notADatabase() {
        let project = FixtureProject()
        project.write("notes.db", "hello")
        #expect(throws: SQLiteReader.ReadError.self) { try SQLiteReader.tables(at: project.root + "/notes.db") }
        #expect(throws: SQLiteReader.ReadError.self) { try SQLiteReader.tables(at: project.root + "/missing.db") }
    }

    @Test func exports() throws {
        let columns = ["id", "name", "note"]
        let rows: [[SQLiteValue]] = [[.integer(1), .text("Ada", truncated: false), .text("a, \"b\"\nc | d", truncated: false)],
                                     [.integer(2), .null, .blob(3)]]
        #expect(TableExport.csv(columns: columns, rows: rows) == "id,name,note\n1,Ada,\"a, \"\"b\"\"\nc | d\"\n2,,\"BLOB, 3 bytes\"\n")
        #expect(TableExport.json(columns: columns, rows: rows)
                == "[\n  {\"id\": 1, \"name\": \"Ada\", \"note\": \"a, \\\"b\\\"\\nc | d\"},\n  {\"id\": 2, \"name\": null, \"note\": \"BLOB, 3 bytes\"}\n]\n")
        #expect(TableExport.markdown(columns: columns, rows: rows)
                == "| id | name | note |\n| --- | --- | --- |\n| 1 | Ada | a, \"b\"<br>c \\| d |\n| 2 | NULL | BLOB, 3 bytes |\n")
        let parsed = try JSONSerialization.jsonObject(with: Data(TableExport.json(columns: columns, rows: rows).utf8)) as? [[String: Any]]
        #expect(parsed?.count == 2 && parsed?.first?["name"] as? String == "Ada")
    }
}

/// An agent's store: messages with a full-text index its triggers keep, a view, settings in a WITHOUT
/// ROWID table, a table whose columns hide the rowid, and a generated column. In the test's temporary folder.
final class AgentStore {
    static let long = String(repeating: "A long message, one of many lines.\n", count: 1429).prefix(50_000).description
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data((0..<3064).map { UInt8($0 % 251) })
    static let toolCall = #"{"name":"read_file","arguments":{"path":"a.md","limit":1.0}}"#

    let project = FixtureProject()
    var folder: String { project.root + "/store" }
    var path: String { folder + "/agent.db" }

    init(wal: Bool = false) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        defer { sqlite3_close(db) }
        if wal { exec(db, "PRAGMA journal_mode = WAL") }
        exec(db, """
            CREATE TABLE messages (id INTEGER PRIMARY KEY, role TEXT, content TEXT COLLATE NOCASE, tool_call TEXT, attachment BLOB, created REAL NOT NULL);
            CREATE VIRTUAL TABLE messages_fts USING fts5(content);
            CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN INSERT INTO messages_fts (rowid, content) VALUES (new.id, new.content); END;
            CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN DELETE FROM messages_fts WHERE rowid = old.id; END;
            CREATE TRIGGER messages_au AFTER UPDATE OF content ON messages BEGIN UPDATE messages_fts SET content = new.content WHERE rowid = old.id; END;
            CREATE TABLE messages_fts_notes (note TEXT);
            CREATE VIEW recent AS SELECT id, role, content FROM messages ORDER BY created DESC;
            CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID;
            CREATE TABLE pairs (a TEXT, b INTEGER, note TEXT, PRIMARY KEY (a, b)) WITHOUT ROWID;
            CREATE TABLE hide (rowid, _rowid_, oid);
            CREATE TABLE totals (a INTEGER, doubled INTEGER GENERATED ALWAYS AS (a * 2));
            CREATE TABLE rules (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, n INTEGER CHECK (n >= 0));
            CREATE TABLE audit (v TEXT);
            CREATE TRIGGER kv_au AFTER UPDATE ON kv BEGIN INSERT INTO audit VALUES (new.v); END;
            INSERT INTO messages (role, content, created) VALUES ('user', 'Hello', 1.0);
            INSERT INTO kv VALUES ('theme', 'dark'), ('font', 'mono'), ('accents', '\(String(repeating: "é", count: 2000))');
            INSERT INTO pairs VALUES ('x', 1, 'first'), ('x', 2, 'second');
            INSERT INTO hide VALUES (7, 8, 9);
            INSERT INTO totals (a) VALUES (21);
            INSERT INTO rules (name, n) VALUES ('a', 1), ('b', 2);
            """)
        insert(db, "INSERT INTO messages (role, content, created) VALUES ('assistant', ?1, 2.0)", [.text(Self.long)])
        insert(db, "INSERT INTO messages (role, content, tool_call, attachment, created) VALUES ('assistant', 'Reading it', ?1, ?2, 3.0)", [.text(Self.toolCall), .blob(Self.png)])
        insert(db, "INSERT INTO kv VALUES ('notes', ?1)", [.text(Self.long)])
        if wal {
            // As an app leaves its store when it quits: in WAL mode, with no -wal or -shm beside it.
            var keep: Int32 = 0
            sqlite3_file_control(db, "main", SQLITE_FCNTL_PERSIST_WAL, &keep)
        }
    }

    static func kvKey(_ k: String) -> SQLiteRowKey { .primaryKey([SQLiteKeyPart(column: "k", value: .text(k, truncated: false))]) }

    enum Bound { case text(String), blob(Data) }

    func exec(_ db: OpaquePointer?, _ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK { Issue.record("fixture: \(error.map { String(cString: $0) } ?? "")") }
    }

    func insert(_ db: OpaquePointer?, _ sql: String, _ values: [Bound]) {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() {
            switch value {
            case let .text(text): sqlite3_bind_text(statement, Int32(i + 1), text, -1, transient)
            case let .blob(data): _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(i + 1), $0.baseAddress, Int32(data.count), transient) }
            }
        }
        if sqlite3_step(statement) != SQLITE_DONE { Issue.record("fixture: \(String(cString: sqlite3_errmsg(db)))") }
    }
}

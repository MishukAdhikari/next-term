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
                                  .blob(3), .text("line one\nline, \"two\" | pipe", truncated: false)])
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
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder).sorted() == before, "wal \(wal)")
            #expect(FileManager.default.contents(atPath: path) == bytes && FileStamp(path: path) == stamp)
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

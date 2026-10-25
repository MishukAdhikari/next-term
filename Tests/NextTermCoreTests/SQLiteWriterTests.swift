import Foundation
import SQLite3
import Testing
@testable import NextTermCore

/// Every test writes to a database it made in its temporary folder, never to a real one.
@Suite struct SQLiteWriterTests {
    static func text(_ s: String) -> SQLiteValue { .text(s, truncated: false) }
    static let row1 = SQLiteRowKey.rowid(name: "rowid", value: 1)

    /// Another app's connection to the same file.
    final class OtherApp {
        var db: OpaquePointer?
        init(_ path: String) { sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) }
        deinit { sqlite3_close(db) }

        @discardableResult
        func exec(_ sql: String) -> Int32 { sqlite3_exec(db, sql, nil, nil, nil) }

        func one(_ sql: String) -> String? {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }

        func close() {
            sqlite3_close(db)
            db = nil
        }
    }

    static func read(_ path: String, _ sql: String) -> String? {
        let other = OtherApp(path)
        defer { other.close() }
        return other.one(sql)
    }

    @Test func aSaveWritesOneValueAndKeepsItsType() {
        let store = AgentStore()
        let edit = SQLiteEdit(table: "messages", column: "role", key: Self.row1, expected: Self.text("user"), value: Self.text("assistant"))
        #expect(SQLiteWriter.save(edit, at: store.path) == .saved(stored: Self.text("assistant")))
        #expect(Self.read(store.path, "SELECT role || ' ' || typeof(role) FROM messages WHERE id = 1") == "assistant text")
        let real = SQLiteEdit(table: "messages", column: "created", key: Self.row1, expected: .real(1), value: .real(2.5))
        #expect(SQLiteWriter.save(real, at: store.path) == .saved(stored: .real(2.5)))
        #expect(Self.read(store.path, "SELECT typeof(created) || ' ' || created FROM messages WHERE id = 1") == "real 2.5")
        #expect(Self.read(store.path, "SELECT count(*) FROM messages WHERE role = 'assistant'") == "3", "and no other row")
        let null = SQLiteEdit(table: "messages", column: "tool_call", key: Self.row1, expected: .null, value: Self.text("{}"))
        #expect(SQLiteWriter.save(null, at: store.path) == .saved(stored: Self.text("{}")))
        let toNull = SQLiteEdit(table: "messages", column: "tool_call", key: Self.row1, expected: Self.text("{}"), value: .null)
        #expect(SQLiteWriter.save(toNull, at: store.path) == .saved(stored: .null))
        #expect(Self.read(store.path, "SELECT typeof(tool_call) FROM messages WHERE id = 1") == "null")
    }

    @Test func aChangedValueIsRefusedAndShown() {
        let store = AgentStore()
        let other = OtherApp(store.path)
        other.exec("UPDATE messages SET content = 'final' WHERE id = 1")
        let bytes = FileManager.default.contents(atPath: store.path)
        let mine = SQLiteEdit(table: "messages", column: "content", key: Self.row1, expected: Self.text("Hello"), value: Self.text("mine"))
        let outcome = SQLiteWriter.save(mine, at: store.path)
        #expect(outcome == .changed(current: Self.text("final")))
        #expect(outcome.message == "Changed since it was read. Nothing was saved. Now: final")
        #expect(FileManager.default.contents(atPath: store.path) == bytes, "nothing written")
        // Checked again against the value now shown, it saves.
        let again = SQLiteEdit(table: "messages", column: "content", key: Self.row1, expected: Self.text("final"), value: Self.text("mine"))
        #expect(SQLiteWriter.save(again, at: store.path) == .saved(stored: Self.text("mine")))
        #expect(other.one("SELECT content FROM messages WHERE id = 1") == "mine")
    }

    @Test func aChangeOfCaseInANocaseColumnCounts() {
        let store = AgentStore()
        OtherApp(store.path).exec("UPDATE messages SET content = 'HELLO' WHERE id = 1")
        let edit = SQLiteEdit(table: "messages", column: "content", key: Self.row1, expected: Self.text("Hello"), value: Self.text("mine"))
        #expect(SQLiteWriter.save(edit, at: store.path) == .changed(current: Self.text("HELLO")))
        // A change of storage class counts too: SQLite finds 1 IS 1.0, but an integer is not the real that was read.
        let n = SQLiteEdit(table: "rules", column: "n", key: Self.row1, expected: .real(1), value: .integer(7))
        #expect(SQLiteWriter.save(n, at: store.path) == .changed(current: .integer(1)))
    }

    @Test func aDeletedRowIsGone() {
        let store = AgentStore()
        OtherApp(store.path).exec("DELETE FROM messages WHERE id = 1")
        let edit = SQLiteEdit(table: "messages", column: "content", key: Self.row1, expected: Self.text("Hello"), value: Self.text("x"))
        #expect(SQLiteWriter.save(edit, at: store.path) == .rowGone)
    }

    @Test func aWriterHoldingTheFileMakesItBusy() {
        let store = AgentStore()
        let other = OtherApp(store.path)
        other.exec("BEGIN IMMEDIATE")
        let bytes = FileManager.default.contents(atPath: store.path)
        let edit = SQLiteEdit(table: "messages", column: "role", key: Self.row1, expected: Self.text("user"), value: Self.text("x"))
        let start = Date()
        let busy = SQLiteWriter.save(edit, at: store.path, busyTimeout: 50)
        #expect(busy == .busy && Date().timeIntervalSince(start) < 2)
        #expect(busy.message == "The file is busy: another app is writing to it. Nothing was saved.")
        #expect(FileManager.default.contents(atPath: store.path) == bytes)
        other.exec("ROLLBACK")
        #expect(SQLiteWriter.save(edit, at: store.path, busyTimeout: 50) == .saved(stored: Self.text("x")))
    }

    @Test func aReaderInRollbackModeMakesCommitBusy() {
        let store = AgentStore()
        let other = OtherApp(store.path)
        other.exec("BEGIN")
        #expect(other.one("SELECT count(*) FROM messages") == "3") // holds SHARED until it ends
        let edit = SQLiteEdit(table: "messages", column: "role", key: Self.row1, expected: Self.text("user"), value: Self.text("x"))
        #expect(SQLiteWriter.save(edit, at: store.path, busyTimeout: 50) == .busy)
        other.exec("COMMIT")
        #expect(other.one("SELECT role FROM messages WHERE id = 1") == "user", "rolled back")
        #expect(!FileManager.default.fileExists(atPath: store.path + "-journal"))
    }

    @Test func aWriteProtectedFileIsReadOnly() throws {
        let store = AgentStore()
        #expect(SQLiteWriter.writeProblem(at: store.path) == nil)
        chmod(store.path, 0o444)
        defer { chmod(store.path, 0o644) }
        #expect(SQLiteWriter.writeProblem(at: store.path) == "This file can’t be written (it is read-only on disk).")
        let edit = SQLiteEdit(table: "messages", column: "role", key: Self.row1, expected: Self.text("user"), value: Self.text("x"))
        #expect(SQLiteWriter.save(edit, at: store.path) == .readOnly)
        chmod(store.path, 0o644)
        chmod(store.folder, 0o555)
        defer { chmod(store.folder, 0o755) }
        #expect(SQLiteWriter.writeProblem(at: store.path)?.hasPrefix("Its folder can’t be written") == true)
        #expect(SQLiteWriter.writeProblem(at: store.folder) == "This isn’t a regular file, so it can’t be edited here.")
        #expect(SQLiteWriter.writeProblem(at: store.folder + "/missing.db") == "The file is not there any more.")
    }

    @Test func aMissingFileIsNeverMade() {
        let store = AgentStore()
        let missing = store.folder + "/gone.db"
        let edit = SQLiteEdit(table: "messages", column: "role", key: Self.row1, expected: Self.text("user"), value: Self.text("x"))
        #expect(SQLiteWriter.save(edit, at: missing) == .gone)
        #expect(!FileManager.default.fileExists(atPath: missing))
    }

    @Test func viewsVirtualAndShadowTablesAreRefused() {
        let store = AgentStore()
        let bytes = FileManager.default.contents(atPath: store.path)
        for table in ["recent", "messages_fts", "messages_fts_data", "messages_fts_content", "messages_fts_notes"] {
            let edit = SQLiteEdit(table: table, column: table == "messages_fts_data" ? "block" : "content", key: Self.row1,
                                  expected: Self.text("Hello"), value: Self.text("x"))
            let outcome = SQLiteWriter.save(edit, at: store.path)
            guard case .refused = outcome else { return #expect(Bool(false), "\(table): \(outcome)") }
        }
        let keyed = SQLiteEdit(table: "kv", column: "v", key: Self.row1, expected: Self.text("dark"), value: Self.text("x"))
        guard case .refused = SQLiteWriter.save(keyed, at: store.path) else { return #expect(Bool(false), "a rowid key on a WITHOUT ROWID table") }
        let key = SQLiteEdit(table: "messages", column: "id", key: Self.row1, expected: .integer(1), value: .integer(9))
        guard case .refused = SQLiteWriter.save(key, at: store.path) else { return #expect(Bool(false), "the rowid alias") }
        let generated = SQLiteEdit(table: "totals", column: "doubled", key: Self.row1, expected: .integer(42), value: .integer(1))
        guard case .refused = SQLiteWriter.save(generated, at: store.path) else { return #expect(Bool(false), "a generated column") }
        #expect(FileManager.default.contents(atPath: store.path) == bytes)

        // And on the writer's own connection, defensive mode refuses a shadow table even without the check.
        let (connection, refusal) = SQLiteWriter.connect(store.path, busyTimeout: 50)
        defer { sqlite3_close(connection) }
        #expect(refusal == nil)
        #expect(sqlite3_exec(connection, "UPDATE messages_fts_data SET block = block", nil, nil, nil) != SQLITE_OK)
        #expect(String(cString: sqlite3_errmsg(connection)).contains("may not be modified"))
        // And a double-quoted name that names nothing is an error, not the string "rowid".
        #expect(sqlite3_exec(connection, "SELECT \"rowid\" FROM kv", nil, nil, nil) != SQLITE_OK)
    }

    @Test func constraintsRefuseWithSQLitesMessage() {
        let store = AgentStore()
        let rule = SQLiteRowKey.rowid(name: "rowid", value: 1)
        let cases: [(SQLiteEdit, String)] = [
            (SQLiteEdit(table: "rules", column: "name", key: rule, expected: Self.text("a"), value: .null), "NOT NULL constraint failed: rules.name"),
            (SQLiteEdit(table: "rules", column: "name", key: rule, expected: Self.text("a"), value: Self.text("b")), "UNIQUE constraint failed: rules.name"),
            (SQLiteEdit(table: "rules", column: "n", key: rule, expected: .integer(1), value: .integer(-1)), "CHECK constraint failed"),
        ]
        for (edit, message) in cases {
            let outcome = SQLiteWriter.save(edit, at: store.path)
            guard case let .refused(reason) = outcome else { return #expect(Bool(false), "\(edit.column): \(outcome)") }
            #expect(reason.contains(message), "\(reason)")
            #expect(outcome.message.hasPrefix("SQLite refused the change: ") && outcome.message.hasSuffix("Nothing was saved."))
        }
        #expect(Self.read(store.path, "SELECT name || n FROM rules WHERE id = 1") == "a1")
    }

    @Test func triggersRunAndTheIndexStaysInStep() {
        let store = AgentStore()
        let edit = SQLiteEdit(table: "messages", column: "content", key: Self.row1, expected: Self.text("Hello"), value: Self.text("a zebra here"))
        #expect(SQLiteWriter.save(edit, at: store.path) == .saved(stored: Self.text("a zebra here")))
        #expect(Self.read(store.path, "SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'zebra'") == "1")
        #expect(Self.read(store.path, "SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'hello'") == "0")
        let kv = SQLiteEdit(table: "kv", column: "v", key: AgentStore.kvKey("theme"), expected: Self.text("dark"), value: Self.text("light"))
        #expect(SQLiteWriter.save(kv, at: store.path) == .saved(stored: Self.text("light")))
        #expect(Self.read(store.path, "SELECT group_concat(v) FROM audit") == "light", "the AFTER UPDATE trigger ran")
    }

    @Test func noNewFileBesideAWALDatabase() throws {
        let store = AgentStore(wal: true)
        #expect(SQLiteReader.isWAL(store.path))
        let before = try FileManager.default.contentsOfDirectory(atPath: store.folder).sorted()
        #expect(before == ["agent.db"])
        let edit = SQLiteEdit(table: "kv", column: "v", key: AgentStore.kvKey("theme"), expected: Self.text("dark"), value: Self.text("light"))
        #expect(SQLiteWriter.save(edit, at: store.path) == .saved(stored: Self.text("light")))
        #expect(SQLiteWriter.save(edit.reversed, at: store.path) == .saved(stored: Self.text("dark")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.folder).sorted() == before)
        #expect(try SQLiteReader.value("kv", column: "v", key: AgentStore.kvKey("theme"), at: store.path) == Self.text("dark"))

        // With the app holding it open, its -wal and -shm stay, and the app reads the change.
        let app = OtherApp(store.path)
        #expect(app.one("SELECT v FROM kv WHERE k = 'theme'") == "dark")
        #expect(FileManager.default.fileExists(atPath: store.path + "-wal"))
        #expect(SQLiteWriter.save(edit, at: store.path) == .saved(stored: Self.text("light")))
        #expect(FileManager.default.fileExists(atPath: store.path + "-wal") && FileManager.default.fileExists(atPath: store.path + "-shm"))
        #expect(app.one("SELECT v FROM kv WHERE k = 'theme'") == "light")
    }

    @Test func reversedUndoesUnlessTheCellChanged() {
        let store = AgentStore()
        let edit = SQLiteEdit(table: "messages", column: "content", key: Self.row1, expected: Self.text("Hello"), value: Self.text("mine"))
        guard case let .saved(stored) = SQLiteWriter.save(edit, at: store.path) else { return #expect(Bool(false), "saved") }
        let undo = SQLiteEdit(table: edit.table, column: edit.column, key: edit.key, expected: stored, value: edit.expected)
        #expect(undo == edit.reversed)
        #expect(SQLiteWriter.save(undo, at: store.path) == .saved(stored: Self.text("Hello")))
        #expect(SQLiteWriter.save(edit, at: store.path) == .saved(stored: Self.text("mine")))
        OtherApp(store.path).exec("UPDATE messages SET content = 'theirs' WHERE id = 1")
        #expect(SQLiteWriter.save(edit.reversed, at: store.path) == .changed(current: Self.text("theirs")))
        #expect(Self.read(store.path, "SELECT content FROM messages WHERE id = 1") == "theirs")
    }

    @Test func aTwoColumnKey() throws {
        let store = AgentStore()
        let page = try SQLiteReader.page("pairs", at: store.path, offset: 0)
        let key = try #require(page.keys[1])
        let edit = SQLiteEdit(table: "pairs", column: "note", key: key, expected: Self.text("second"), value: Self.text("changed"))
        #expect(SQLiteWriter.save(edit, at: store.path) == .saved(stored: Self.text("changed")))
        #expect(Self.read(store.path, "SELECT group_concat(note, ',') FROM (SELECT note FROM pairs ORDER BY b)") == "first,changed")
    }

    @Test func invalidTextCantBeChecked() throws {
        let store = AgentStore()
        let other = OtherApp(store.path)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(other.db, "INSERT INTO kv VALUES ('bad', ?1)", -1, &statement, nil)
        let bytes: [UInt8] = [0x41, 0xFF, 0xFE, 0x42]
        _ = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: 4) {
                sqlite3_bind_text(statement, 1, $0, 4, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }
        #expect(sqlite3_step(statement) == SQLITE_DONE)
        sqlite3_finalize(statement)
        let read = try #require(try SQLiteReader.value("kv", column: "v", key: AgentStore.kvKey("bad"), at: store.path))
        let edit = SQLiteEdit(table: "kv", column: "v", key: AgentStore.kvKey("bad"), expected: read, value: Self.text("fixed"))
        #expect(SQLiteWriter.save(edit, at: store.path) == .invalidText)
        #expect(other.one("SELECT hex(v) FROM kv WHERE k = 'bad'") == "41FFFE42")
    }
}

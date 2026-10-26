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
        let edit = SQLiteEdit(table: "messages", column: "role", key: Self.row1, expected: Self.text("user"), value: Self.text("assistant"), row: [])
        #expect(SQLiteWriter.save(edit, at: store.path).stored == Self.text("assistant"))
        #expect(Self.read(store.path, "SELECT role || ' ' || typeof(role) FROM messages WHERE id = 1") == "assistant text")
        let real = SQLiteEdit(table: "messages", column: "created", key: Self.row1, expected: .real(1), value: .real(2.5), row: [])
        #expect(SQLiteWriter.save(real, at: store.path).stored == .real(2.5))
        #expect(Self.read(store.path, "SELECT typeof(created) || ' ' || created FROM messages WHERE id = 1") == "real 2.5")
        #expect(Self.read(store.path, "SELECT count(*) FROM messages WHERE role = 'assistant'") == "3", "and no other row")
        let null = SQLiteEdit(table: "messages", column: "tool_call", key: Self.row1, expected: .null, value: Self.text("{}"), row: [])
        #expect(SQLiteWriter.save(null, at: store.path).stored == Self.text("{}"))
        let toNull = SQLiteEdit(table: "messages", column: "tool_call", key: Self.row1, expected: Self.text("{}"), value: .null, row: [])
        #expect(SQLiteWriter.save(toNull, at: store.path).stored == .null)
        #expect(Self.read(store.path, "SELECT typeof(tool_call) FROM messages WHERE id = 1") == "null")
    }

    @Test func aChangedValueIsRefusedAndShown() {
        let store = AgentStore()
        let other = OtherApp(store.path)
        other.exec("UPDATE messages SET content = 'final' WHERE id = 1")
        let bytes = FileManager.default.contents(atPath: store.path)
        let mine = SQLiteEdit(table: "messages", column: "content", key: Self.row1, expected: Self.text("Hello"), value: Self.text("mine"), row: [])
        let outcome = SQLiteWriter.save(mine, at: store.path)
        #expect(outcome == .changed(current: Self.text("final")))
        #expect(outcome.message == "Changed since it was read. Nothing was saved. Now: final")
        #expect(FileManager.default.contents(atPath: store.path) == bytes, "nothing written")
        // Checked again against the value now shown, it saves.
        let again = SQLiteEdit(table: "messages", column: "content", key: Self.row1, expected: Self.text("final"), value: Self.text("mine"), row: [])
        #expect(SQLiteWriter.save(again, at: store.path).stored == Self.text("mine"))
        #expect(other.one("SELECT content FROM messages WHERE id = 1") == "mine")
    }

    @Test func aChangeOfCaseInANocaseColumnCounts() {
        let store = AgentStore()
        OtherApp(store.path).exec("UPDATE messages SET content = 'HELLO' WHERE id = 1")
        let edit = SQLiteEdit(table: "messages", column: "content", key: Self.row1, expected: Self.text("Hello"), value: Self.text("mine"), row: [])
        #expect(SQLiteWriter.save(edit, at: store.path) == .changed(current: Self.text("HELLO")))
        // A change of storage class counts too: SQLite finds 1 IS 1.0, but an integer is not the real that was read.
        let n = SQLiteEdit(table: "rules", column: "n", key: Self.row1, expected: .real(1), value: .integer(7), row: [])
        #expect(SQLiteWriter.save(n, at: store.path) == .changed(current: .integer(1)))
    }

    @Test func aDeletedRowIsGone() {
        let store = AgentStore()
        OtherApp(store.path).exec("DELETE FROM messages WHERE id = 1")
        let edit = SQLiteEdit(table: "messages", column: "content", key: Self.row1, expected: Self.text("Hello"), value: Self.text("x"), row: [])
        #expect(SQLiteWriter.save(edit, at: store.path) == .rowGone)
    }

    @Test func aWriterHoldingTheFileMakesItBusy() {
        let store = AgentStore()
        let other = OtherApp(store.path)
        other.exec("BEGIN IMMEDIATE")
        let bytes = FileManager.default.contents(atPath: store.path)
        let edit = SQLiteEdit(table: "messages", column: "role", key: Self.row1, expected: Self.text("user"), value: Self.text("x"), row: [])
        let start = Date()
        let busy = SQLiteWriter.save(edit, at: store.path, busyTimeout: 50)
        #expect(busy == .busy && Date().timeIntervalSince(start) < 2)
        #expect(busy.message == "The file is busy: another app is writing to it. Nothing was saved.")
        #expect(FileManager.default.contents(atPath: store.path) == bytes)
        other.exec("ROLLBACK")
        #expect(SQLiteWriter.save(edit, at: store.path, busyTimeout: 50).stored == Self.text("x"))
    }

    @Test func aReaderInRollbackModeMakesCommitBusy() {
        let store = AgentStore()
        let other = OtherApp(store.path)
        other.exec("BEGIN")
        #expect(other.one("SELECT count(*) FROM messages") == "3") // holds SHARED until it ends
        let edit = SQLiteEdit(table: "messages", column: "role", key: Self.row1, expected: Self.text("user"), value: Self.text("x"), row: [])
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
        let edit = SQLiteEdit(table: "messages", column: "role", key: Self.row1, expected: Self.text("user"), value: Self.text("x"), row: [])
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
        let edit = SQLiteEdit(table: "messages", column: "role", key: Self.row1, expected: Self.text("user"), value: Self.text("x"), row: [])
        #expect(SQLiteWriter.save(edit, at: missing) == .gone)
        #expect(!FileManager.default.fileExists(atPath: missing))
    }

    @Test func viewsVirtualAndShadowTablesAreRefused() {
        let store = AgentStore()
        let bytes = FileManager.default.contents(atPath: store.path)
        for table in ["recent", "messages_fts", "messages_fts_data", "messages_fts_content", "messages_fts_notes"] {
            let edit = SQLiteEdit(table: table, column: table == "messages_fts_data" ? "block" : "content", key: Self.row1,
                                  expected: Self.text("Hello"), value: Self.text("x"), row: [])
            let outcome = SQLiteWriter.save(edit, at: store.path)
            guard case .refused = outcome else { return #expect(Bool(false), "\(table): \(outcome)") }
        }
        let keyed = SQLiteEdit(table: "kv", column: "v", key: Self.row1, expected: Self.text("dark"), value: Self.text("x"), row: [])
        guard case .refused = SQLiteWriter.save(keyed, at: store.path) else { return #expect(Bool(false), "a rowid key on a WITHOUT ROWID table") }
        let key = SQLiteEdit(table: "messages", column: "id", key: Self.row1, expected: .integer(1), value: .integer(9), row: [])
        guard case .refused = SQLiteWriter.save(key, at: store.path) else { return #expect(Bool(false), "the rowid alias") }
        let generated = SQLiteEdit(table: "totals", column: "doubled", key: Self.row1, expected: .integer(42), value: .integer(1), row: [])
        guard case .refused = SQLiteWriter.save(generated, at: store.path) else { return #expect(Bool(false), "a generated column") }
        #expect(FileManager.default.contents(atPath: store.path) == bytes)

        // And on the writer's own connection, defensive mode refuses a shadow table even without the check.
        let (connection, refusal) = SQLiteWriter.connect(store.path, busyTimeout: 50)
        defer { sqlite3_close(connection) }
        #expect(refusal == nil)
        #expect(sqlite3_exec(connection, "UPDATE messages_fts_data SET block = block", nil, nil, nil) != SQLITE_OK)
        #expect(String(cString: sqlite3_errmsg(connection)).contains("may not be modified"))
    }

    @Test func constraintsRefuseWithSQLitesMessage() {
        let store = AgentStore()
        let rule = SQLiteRowKey.rowid(name: "rowid", value: 1)
        let cases: [(SQLiteEdit, String)] = [
            (SQLiteEdit(table: "rules", column: "name", key: rule, expected: Self.text("a"), value: .null, row: []), "NOT NULL constraint failed: rules.name"),
            (SQLiteEdit(table: "rules", column: "name", key: rule, expected: Self.text("a"), value: Self.text("b"), row: []), "UNIQUE constraint failed: rules.name"),
            (SQLiteEdit(table: "rules", column: "n", key: rule, expected: .integer(1), value: .integer(-1), row: []), "CHECK constraint failed"),
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
        let edit = SQLiteEdit(table: "messages", column: "content", key: Self.row1, expected: Self.text("Hello"), value: Self.text("a zebra here"), row: [])
        #expect(SQLiteWriter.save(edit, at: store.path).stored == Self.text("a zebra here"))
        #expect(Self.read(store.path, "SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'zebra'") == "1")
        #expect(Self.read(store.path, "SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'hello'") == "0")
        let kv = SQLiteEdit(table: "kv", column: "v", key: AgentStore.kvKey("theme"), expected: Self.text("dark"), value: Self.text("light"), row: [])
        #expect(SQLiteWriter.save(kv, at: store.path).stored == Self.text("light"))
        #expect(Self.read(store.path, "SELECT group_concat(v) FROM audit") == "light", "the AFTER UPDATE trigger ran")
    }

    @Test func noNewFileBesideAWALDatabase() throws {
        let store = AgentStore(wal: true)
        #expect(SQLiteReader.isWAL(store.path))
        let before = try FileManager.default.contentsOfDirectory(atPath: store.folder).sorted()
        #expect(before == ["agent.db"])
        let edit = SQLiteEdit(table: "kv", column: "v", key: AgentStore.kvKey("theme"), expected: Self.text("dark"), value: Self.text("light"), row: [])
        #expect(SQLiteWriter.save(edit, at: store.path).stored == Self.text("light"))
        #expect(SQLiteWriter.save(edit.reversed(row: []), at: store.path).stored == Self.text("dark"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.folder).sorted() == before)
        #expect(try SQLiteReader.value("kv", column: "v", key: AgentStore.kvKey("theme"), at: store.path) == Self.text("dark"))

        // With the app holding it open, its -wal and -shm stay, and the app reads the change.
        let app = OtherApp(store.path)
        #expect(app.one("SELECT v FROM kv WHERE k = 'theme'") == "dark")
        #expect(FileManager.default.fileExists(atPath: store.path + "-wal"))
        #expect(SQLiteWriter.save(edit, at: store.path).stored == Self.text("light"))
        #expect(FileManager.default.fileExists(atPath: store.path + "-wal") && FileManager.default.fileExists(atPath: store.path + "-shm"))
        #expect(app.one("SELECT v FROM kv WHERE k = 'theme'") == "light")
    }

    @Test func reversedUndoesUnlessTheCellChanged() {
        let store = AgentStore()
        let edit = SQLiteEdit(table: "messages", column: "content", key: Self.row1, expected: Self.text("Hello"), value: Self.text("mine"), row: [])
        guard case let .saved(stored, row) = SQLiteWriter.save(edit, at: store.path) else { return #expect(Bool(false), "saved") }
        let undo = SQLiteEdit(table: edit.table, column: edit.column, key: edit.key, expected: stored, value: edit.expected, row: row)
        #expect(undo == edit.reversed(row: row))
        #expect(SQLiteWriter.save(undo, at: store.path).stored == Self.text("Hello"))
        #expect(SQLiteWriter.save(edit, at: store.path).stored == Self.text("mine"))
        OtherApp(store.path).exec("UPDATE messages SET content = 'theirs' WHERE id = 1")
        #expect(SQLiteWriter.save(edit.reversed(row: []), at: store.path) == .changed(current: Self.text("theirs")))
        #expect(Self.read(store.path, "SELECT content FROM messages WHERE id = 1") == "theirs")
    }

    // MARK: the row as read

    /// The row at `key` as a page reads it.
    static func row(_ path: String, _ table: String, _ key: SQLiteRowKey) throws -> [SQLiteColumnValue] {
        let page = try SQLiteReader.page(table, at: path, offset: 0)
        let index = try #require(page.row(for: key))
        return zip(page.columns, page.rows[index]).map { SQLiteColumnValue(column: $0, value: $1) }
    }

    /// A database of the test's own, made by `sql`.
    static func database(_ sql: String) -> (FixtureProject, String) {
        let project = FixtureProject()
        let path = project.root + "/own.db"
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK { Issue.record("fixture: \(error.map { String(cString: $0) } ?? "")") }
        sqlite3_close(db)
        return (project, path)
    }

    /// A VACUUM gives the rows of a table with no INTEGER PRIMARY KEY new rowids: rowid 3 names another row.
    @Test func aRowRenumberedByVacuumIsRefused() throws {
        let (project, path) = Self.database("""
            CREATE TABLE m (role TEXT, content TEXT);
            INSERT INTO m VALUES ('user', 'a'), ('user', 'b'), ('user', 'c'), ('user', 'd');
            """)
        _ = project
        let key = SQLiteRowKey.rowid(name: "rowid", value: 3)
        let read = try Self.row(path, "m", key)
        #expect(read.map(\.value) == [Self.text("user"), Self.text("c")])
        OtherApp(path).exec("DELETE FROM m WHERE content = 'a'; VACUUM;")
        #expect(Self.read(path, "SELECT content FROM m WHERE rowid = 3") == "d", "rowid 3 is another row now")
        let bytes = FileManager.default.contents(atPath: path)
        let edit = SQLiteEdit(table: "m", column: "role", key: key, expected: Self.text("user"), value: Self.text("assistant"), row: read)
        let outcome = SQLiteWriter.save(edit, at: path)
        #expect(outcome == .rowChanged(row: [SQLiteColumnValue(column: "role", value: Self.text("user")), SQLiteColumnValue(column: "content", value: Self.text("d"))]))
        #expect(outcome.message.hasPrefix("This row changed since it was read. Nothing was saved."))
        #expect(FileManager.default.contents(atPath: path) == bytes, "nothing written")
        // Checked against the row now there (the draft rebased on it), a second Save writes to it.
        guard case let .rowChanged(now) = outcome else { return }
        let again = SQLiteEdit(table: "m", column: "role", key: key, expected: Self.text("user"), value: Self.text("assistant"), row: now)
        #expect(SQLiteWriter.save(again, at: path).stored == Self.text("assistant"))
        #expect(Self.read(path, "SELECT group_concat(role || ':' || content, ',') FROM m") == "user:b,user:c,assistant:d")
    }

    /// The last message deleted and another written in its place takes its id: the usual regenerate.
    @Test func aRowidGivenOutAgainIsRefused() throws {
        let (project, path) = Self.database("""
            CREATE TABLE m (id INTEGER PRIMARY KEY, role TEXT, content TEXT);
            INSERT INTO m (role, content) VALUES ('user', 'question'), ('assistant', 'first answer');
            """)
        _ = project
        let key = SQLiteRowKey.rowid(name: "rowid", value: 2)
        let read = try Self.row(path, "m", key)
        OtherApp(path).exec("DELETE FROM m WHERE id = 2; INSERT INTO m (role, content) VALUES ('assistant', 'second answer');")
        #expect(Self.read(path, "SELECT id || content FROM m WHERE id = 2") == "2second answer")
        let edit = SQLiteEdit(table: "m", column: "role", key: key, expected: Self.text("assistant"), value: Self.text("tool"), row: read)
        guard case .rowChanged = SQLiteWriter.save(edit, at: path) else { return #expect(Bool(false), "refused as another row") }
        #expect(Self.read(path, "SELECT role FROM m WHERE id = 2") == "assistant")
        // The same row, unchanged, saves; and the step that undoes it checks the row as the save left it.
        let fresh = try Self.row(path, "m", key)
        guard case let .saved(stored, after) = SQLiteWriter.save(SQLiteEdit(table: "m", column: "role", key: key, expected: Self.text("assistant"),
                                                                              value: Self.text("tool"), row: fresh), at: path) else {
            return #expect(Bool(false), "saved")
        }
        #expect(after.map(\.value) == [.integer(2), Self.text("tool"), Self.text("second answer")])
        let undo = SQLiteEdit(table: "m", column: "role", key: key, expected: stored, value: Self.text("assistant"), row: after)
        OtherApp(path).exec("UPDATE m SET content = 'third answer' WHERE id = 2")
        guard case .rowChanged = SQLiteWriter.save(undo, at: path) else { return #expect(Bool(false), "an undo checks the row too") }
        #expect(Self.read(path, "SELECT role FROM m WHERE id = 2") == "tool")
    }

    /// A long text cut on the page is checked by what was read of it (its first bytes, and that it goes on
    /// past them); a blob by its size and its first bytes.
    @Test func cutTextAndBlobsInTheRowAreChecked() throws {
        let store = AgentStore()
        let long = SQLiteRowKey.rowid(name: "rowid", value: 2)
        let read = try Self.row(store.path, "messages", long)
        #expect(read[2].column == "content" && read[2].value.isTruncated, "content is cut on the page")
        let edit = SQLiteEdit(table: "messages", column: "role", key: long, expected: Self.text("assistant"), value: Self.text("tool"), row: read)
        #expect(SQLiteWriter.save(edit, at: store.path).stored == Self.text("tool"), "a cut text that goes on as read")
        let undo = SQLiteEdit(table: "messages", column: "role", key: long, expected: Self.text("tool"), value: Self.text("assistant"),
                              row: try Self.row(store.path, "messages", long))
        let other = OtherApp(store.path)
        other.exec("UPDATE messages SET content = 'X' || substr(content, 2) WHERE id = 2")
        guard case .rowChanged = SQLiteWriter.save(undo, at: store.path) else { return #expect(Bool(false), "a text that starts otherwise") }
        other.exec("UPDATE messages SET content = substr(content, 1, 10000) WHERE id = 2")
        guard case .rowChanged = SQLiteWriter.save(undo, at: store.path) else { return #expect(Bool(false), "a text that no longer goes on") }
        other.exec("UPDATE messages SET content = '\(AgentStore.long)' WHERE id = 2")
        #expect(SQLiteWriter.save(undo, at: store.path).stored == Self.text("assistant"), "back as read")

        let attached = SQLiteRowKey.rowid(name: "rowid", value: 3)
        let row3 = try Self.row(store.path, "messages", attached)
        #expect(row3[4].value == .blob(3072, head: AgentStore.png.prefix(256)), "the first bytes, read without loading the blob")
        let role = SQLiteEdit(table: "messages", column: "role", key: attached, expected: Self.text("assistant"), value: Self.text("tool"), row: row3)
        other.exec("UPDATE messages SET attachment = zeroblob(3072) WHERE id = 3")
        guard case .rowChanged = SQLiteWriter.save(role, at: store.path) else { return #expect(Bool(false), "a blob with other first bytes") }
        let sized = row3.map { $0.column == "attachment" ? SQLiteColumnValue(column: "attachment", value: .blob(3071)) : $0 }
        let bySize = SQLiteEdit(table: "messages", column: "role", key: attached, expected: Self.text("assistant"), value: Self.text("tool"), row: sized)
        guard case .rowChanged = SQLiteWriter.save(bySize, at: store.path) else { return #expect(Bool(false), "a blob of another size") }
        #expect(Self.read(store.path, "SELECT group_concat(role) FROM messages") == "user,assistant,assistant")
    }

    @Test func aColumnGoneFromTheRowIsRefused() throws {
        let (project, path) = Self.database("CREATE TABLE m (role TEXT, note TEXT); INSERT INTO m VALUES ('user', 'n');")
        _ = project
        let key = SQLiteRowKey.rowid(name: "rowid", value: 1)
        let read = try Self.row(path, "m", key)
        OtherApp(path).exec("ALTER TABLE m RENAME COLUMN note TO memo")
        let edit = SQLiteEdit(table: "m", column: "role", key: key, expected: Self.text("user"), value: Self.text("x"), row: read)
        #expect(SQLiteWriter.save(edit, at: path) == .refused("the table changed since it was read."))
    }

    // MARK: conflicts, triggers, normalization

    /// A table's own ON CONFLICT REPLACE would delete the other row, and IGNORE skip the change quietly:
    /// OR ABORT refuses both with SQLite's message, and every row stays.
    @Test func aTablesConflictRuleNeverDeletesOrSkips() throws {
        let (project, path) = Self.database("""
            CREATE TABLE s (id INTEGER PRIMARY KEY, name TEXT UNIQUE ON CONFLICT REPLACE, v TEXT);
            CREATE TABLE i (id INTEGER PRIMARY KEY, name TEXT UNIQUE ON CONFLICT IGNORE, v TEXT);
            CREATE TABLE p (code TEXT PRIMARY KEY ON CONFLICT REPLACE, v TEXT);
            INSERT INTO s VALUES (3, 'theme', 'dark'), (5, 'font', 'mono');
            INSERT INTO i VALUES (3, 'theme', 'dark'), (5, 'font', 'mono');
            INSERT INTO p VALUES ('theme', 'dark'), ('font', 'mono');
            """)
        _ = project
        let bytes = FileManager.default.contents(atPath: path)
        for (table, column, key) in [("s", "name", SQLiteRowKey.rowid(name: "rowid", value: 3)), ("i", "name", .rowid(name: "rowid", value: 3)),
                                     ("p", "code", .rowid(name: "rowid", value: 1))] {
            let read = try Self.row(path, table, key)
            let edit = SQLiteEdit(table: table, column: column, key: key, expected: Self.text("theme"), value: Self.text("font"), row: read)
            let outcome = SQLiteWriter.save(edit, at: path)
            guard case let .refused(reason) = outcome else { return #expect(Bool(false), "\(table): \(outcome)") }
            #expect(reason.contains("UNIQUE constraint failed: \(table).\(column)"), "\(reason)")
            #expect(Self.read(path, "SELECT count(*) FROM \(table)") == "2", "\(table) keeps both rows")
        }
        #expect(FileManager.default.contents(atPath: path) == bytes)
    }

    /// A trigger that skips the change (RAISE(IGNORE)) says so, even for a number.
    @Test func aTriggerThatSkipsTheChangeSaysSo() throws {
        let (project, path) = Self.database("""
            CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER, note TEXT);
            CREATE TRIGGER keep BEFORE UPDATE OF n ON t BEGIN SELECT RAISE(IGNORE); END;
            INSERT INTO t (n, note) VALUES (1, 'x');
            """)
        _ = project
        let key = SQLiteRowKey.rowid(name: "rowid", value: 1)
        let edit = SQLiteEdit(table: "t", column: "n", key: key, expected: .integer(1), value: .integer(2), row: try Self.row(path, "t", key))
        let outcome = SQLiteWriter.save(edit, at: path)
        #expect(outcome == .skipped && outcome.message == "A trigger in this database skipped the change. Nothing was saved.")
        #expect(Self.read(path, "SELECT n FROM t") == "1")
    }

    /// Double-quoted strings are SQLite's default for what the writer doesn't write itself: a trigger's body.
    @Test func aTriggerWrittenWithDoubleQuotedStringsRuns() throws {
        let (project, path) = Self.database("""
            CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);
            CREATE TABLE log (w TEXT);
            CREATE TRIGGER logged AFTER UPDATE ON t BEGIN INSERT INTO log VALUES ("changed"); END;
            INSERT INTO t (v) VALUES ('a');
            """)
        _ = project
        let key = SQLiteRowKey.rowid(name: "rowid", value: 1)
        let edit = SQLiteEdit(table: "t", column: "v", key: key, expected: Self.text("a"), value: Self.text("b"), row: try Self.row(path, "t", key))
        #expect(SQLiteWriter.save(edit, at: path).stored == Self.text("b"))
        #expect(Self.read(path, "SELECT w FROM log") == "changed")
    }

    /// Another app writes the same text in another normalization: Swift takes the two for one string, SQLite
    /// doesn't. It is a change, shown, not text that "isn't valid UTF-8".
    @Test func aChangeOfNormalizationIsAChange() throws {
        let nfc = "caf\u{E9}", nfd = "cafe\u{301}"
        #expect(nfc == nfd && !SQLiteValue.text(nfc, truncated: false).isIdentical(to: .text(nfd, truncated: false)))
        let (project, path) = Self.database("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT); INSERT INTO t (v) VALUES ('caf\u{E9}');")
        _ = project
        OtherApp(path).exec("UPDATE t SET v = 'cafe\u{301}'")
        let key = SQLiteRowKey.rowid(name: "rowid", value: 1)
        let edit = SQLiteEdit(table: "t", column: "v", key: key, expected: Self.text(nfc), value: Self.text("tea"), row: [])
        let outcome = SQLiteWriter.save(edit, at: path)
        guard case let .changed(current) = outcome else { return #expect(Bool(false), "\(outcome)") }
        #expect(current.isIdentical(to: Self.text(nfd)))
        let again = SQLiteEdit(table: "t", column: "v", key: key, expected: current, value: Self.text("tea"), row: [])
        #expect(SQLiteWriter.save(again, at: path).stored == Self.text("tea"), "and rebased on it, Save writes")
    }

    @Test func aTwoColumnKey() throws {
        let store = AgentStore()
        let page = try SQLiteReader.page("pairs", at: store.path, offset: 0)
        let key = try #require(page.keys[1])
        let edit = SQLiteEdit(table: "pairs", column: "note", key: key, expected: Self.text("second"), value: Self.text("changed"), row: [])
        #expect(SQLiteWriter.save(edit, at: store.path).stored == Self.text("changed"))
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
        let edit = SQLiteEdit(table: "kv", column: "v", key: AgentStore.kvKey("bad"), expected: read, value: Self.text("fixed"), row: [])
        #expect(SQLiteWriter.save(edit, at: store.path) == .invalidText)
        #expect(other.one("SELECT hex(v) FROM kv WHERE k = 'bad'") == "41FFFE42")
    }
}

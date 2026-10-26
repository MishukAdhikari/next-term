import Foundation
import SQLite3
import SQLiteConfig

/// What a Save did. Everything but `saved` wrote nothing: the transaction was rolled back.
public enum SQLiteSaveOutcome: Sendable, Equatable {
    /// Written. `stored` is what the cell holds now, as SQLite stored it; `row` is the row read back in the
    /// same transaction, which the step that undoes it checks.
    case saved(stored: SQLiteValue, row: [SQLiteColumnValue])
    /// The cell no longer holds what was read: it holds `current`.
    case changed(current: SQLiteValue)
    /// The cell holds what was read, but another value of its row doesn't: the key may name another row
    /// now (SQLite gives a rowid out again). `row` is the row it names now.
    case rowChanged(row: [SQLiteColumnValue])
    /// No row has the key any more.
    case rowGone
    /// Another connection is writing (or, in rollback-journal mode, reading).
    case busy
    /// The file or its folder can't be written.
    case readOnly
    /// The file isn't there.
    case gone
    /// The cell's stored text isn't valid UTF-8, so it can't be compared with what was read.
    case invalidText
    /// The cell and its row were as read, and the UPDATE ran, but changed nothing: a trigger skipped it
    /// (RAISE(IGNORE)). A table's own ON CONFLICT IGNORE can't, under OR ABORT.
    case skipped
    /// SQLite refused it (a constraint, a trigger), or the table can't be edited.
    case refused(String)

    /// What the cell holds after a save.
    public var stored: SQLiteValue? {
        if case let .saved(stored, _) = self { return stored }
        return nil
    }

    /// One sentence for the detail pane.
    public var message: String {
        switch self {
        case .saved: return "Saved."
        case let .changed(current): return "Changed since it was read. Nothing was saved. Now: " + CellText.line(current.display, limit: 80, cut: current.isTruncated)
        case .rowChanged: return "This row changed since it was read. Nothing was saved. Look over its values, then Save again to write to it as it is now."
        case .rowGone: return "This row was deleted since it was read. Nothing was saved."
        case .busy: return "The file is busy: another app is writing to it. Nothing was saved."
        case .readOnly: return "This file can’t be written (it is read-only on disk). Nothing was saved."
        case .gone: return "The file is not there any more. Nothing was saved."
        case .invalidText: return "Its stored text isn’t valid UTF-8, so it can’t be checked before saving. Nothing was saved."
        case .skipped: return "A trigger in this database skipped the change. Nothing was saved."
        case let .refused(reason): return "SQLite refused the change: \(reason) Nothing was saved."
        }
    }
}

/// Writes one checked value to a SQLite file. Only the SQLite viewer's Save, Undo and Redo call it, on
/// the user's action; nothing an agent or an MCP tool runs reaches it.
///
/// Each save opens its own read-write connection (never one that could create the file), with SQLite's
/// defensive mode on (an index's own tables and the schema are read-only) and foreign keys on. In one `BEGIN IMMEDIATE` transaction it checks the table is still an ordinary or WITHOUT ROWID
/// table and that every name it will use is one of its columns, then runs one `UPDATE OR ABORT` keyed by
/// the row's rowid or primary key. It changes the cell only if the cell still holds, byte for byte and of
/// the same type, the value that was read, and the row's other values are still the ones read: a key
/// alone can name another row after a VACUUM, or once a deleted row's rowid is given out again. OR ABORT
/// overrides a table's own ON CONFLICT REPLACE or IGNORE, so a save never deletes another row and is never
/// skipped quietly. Exactly one row changed: the row is read back, and COMMIT. Anything else: ROLLBACK,
/// once the row is read again to say why. A database that had no -wal file beside it is left without one.
///
/// Double-quoted strings stay as SQLite has them: a trigger's body is compiled into the UPDATE, and many
/// are written with them. No name the writer writes can name nothing, since each is checked first.
public enum SQLiteWriter {
    public static func save(_ edit: SQLiteEdit, at path: String, busyTimeout: Int32 = 1000) -> SQLiteSaveOutcome {
        let (connection, refusal) = connect(path, busyTimeout: busyTimeout)
        defer { sqlite3_close(connection) }
        if let refusal { return refusal }
        guard let db = connection else { return .gone }
        let begun = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        guard begun == SQLITE_OK else { return failure(begun, db) }
        let outcome = update(edit, db)
        guard case .saved = outcome else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return outcome
        }
        let committed = sqlite3_exec(db, "COMMIT", nil, nil, nil)
        guard committed == SQLITE_OK else {
            let failed = failure(committed, db)
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return failed
        }
        return outcome
    }

    /// A read-write connection set up for one save, or why there is none. The caller closes it, also when
    /// it comes with a refusal.
    static func connect(_ path: String, busyTimeout: Int32) -> (OpaquePointer?, SQLiteSaveOutcome?) {
        guard isRegularFile(path) else { return (nil, .gone) }
        let hadWAL = FileManager.default.fileExists(atPath: path + "-wal")
        var connection: OpaquePointer?
        // Never SQLITE_OPEN_CREATE: a file that went away is not made again.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let opened = sqlite3_open_v2(SQLiteReader.fileURI(path) + "?mode=rw", &connection, flags, nil)
        guard opened == SQLITE_OK, let db = connection else {
            guard isRegularFile(path) else { return (connection, .gone) }
            return (connection, opened & 0xFF == SQLITE_CANTOPEN ? .readOnly : .refused(errorMessage(connection)))
        }
        // mode=rw opens a write-protected file for reading only.
        if sqlite3_db_readonly(db, "main") == 1 { return (connection, .readOnly) }
        sqlite3_busy_timeout(db, busyTimeout)
        guard nt_sqlite3_db_config_flag(db, SQLITE_DBCONFIG_DEFENSIVE, 1) == 1 else {
            return (connection, .refused("its defensive mode could not be turned on."))
        }
        // The file's triggers run as SQLite runs them, so a full-text index stays in step: the SQLite of macOS 14 and
        // 15 refuses an FTS table in a trigger when the schema isn't trusted. Trusting it opens nothing here: this
        // connection adds no functions or modules of its own, extension loading stays off, and defensive mode keeps
        // the schema and an index's own tables read-only.
        sqlite3_exec(db, "PRAGMA trusted_schema = ON", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        if !hadWAL {
            // Apple's SQLite keeps -wal and -shm after the last connection closes; none was there before this.
            var keep: Int32 = 0
            sqlite3_file_control(db, "main", SQLITE_FCNTL_PERSIST_WAL, &keep)
        }
        return (db, nil)
    }

    /// Why the file can't be edited at all, or nil when it can: it isn't a regular file, it is
    /// write-protected, or its folder is (SQLite writes its journal beside the file).
    public static func writeProblem(at path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return "The file is not there any more." }
        guard info.st_mode & S_IFMT == S_IFREG else { return "This isn’t a regular file, so it can’t be edited here." }
        guard access(path, W_OK) == 0 else { return "This file can’t be written (it is read-only on disk)." }
        let folder = (path as NSString).deletingLastPathComponent
        guard access(folder.isEmpty ? "." : folder, W_OK) == 0 else {
            return "Its folder can’t be written, and SQLite keeps its journal there, so this file can’t be edited."
        }
        return nil
    }

    /// The checks and the UPDATE, inside the transaction.
    static func update(_ edit: SQLiteEdit, _ db: OpaquePointer) -> SQLiteSaveOutcome {
        guard let kind = (try? SQLiteReader.kind(of: edit.table, db)) ?? nil else { return .refused("the table isn’t there any more.") }
        switch (kind, edit.key) {
        case (.table, .rowid), (.withoutRowid, .primaryKey): break
        case (.view, _): return .refused("a view can’t be edited.")
        case (.virtual, _): return .refused("a virtual table can’t be edited.")
        case (.shadow, _): return .refused("an internal table of a virtual table can’t be edited.")
        default: return .refused("the table changed since it was read.")
        }
        guard let info = SQLiteReader.tableInfo(edit.table, kind: kind, db), let column = info.column(named: edit.column) else {
            return .refused("the column isn’t in the table any more.")
        }
        if column.isGenerated || info.isKey(edit.column) { return .refused("this column can’t be edited.") }
        switch edit.key {
        case let .rowid(name, _) where name != info.rowidName: return .refused("the table changed since it was read.")
        case let .primaryKey(parts) where parts.map(\.column) != info.primaryKey.map(\.name): return .refused("the table changed since it was read.")
        default: break
        }
        for value in [edit.value, edit.expected] + edit.key.parts.map(\.value) where !SQLiteReader.isUsableKey(value) {
            return .refused("a BLOB or a value cut short can’t be saved.")
        }
        // The rest of the row as read, by the names the table has now.
        var others: [SQLiteColumnValue] = []
        for part in edit.row where part.column.lowercased() != column.name.lowercased() {
            guard let named = info.column(named: part.column) else { return .refused("the table changed since it was read.") }
            others.append(SQLiteColumnValue(column: named.name, value: part.value))
        }
        let utf8 = (try? SQLiteReader.rows(db, "PRAGMA encoding"))?.first?.first == .text("UTF-8", truncated: false)

        var bound = Bindings()
        let value = bound.add(.value(edit.value))
        let check = RowCheck(key: edit.key, column: column.name, expected: edit.expected, others: others, utf8: utf8, &bound)
        let sql = "UPDATE OR ABORT \(SQLiteReader.quote(edit.table)) SET \(SQLiteReader.quote(column.name)) = \(value) WHERE "
            + ([check.key, check.cell] + check.row).joined(separator: " AND ")
        guard let stepped = try? bound.run(sql, db) else { return .refused("a value could not be bound.") }
        guard stepped == SQLITE_DONE else { return failure(stepped, db) }
        let changed = sqlite3_changes64(db)
        if changed > 1 { return .refused("more than one row has this key.") }
        guard changed == 1 else { return why(edit, info: info, column: column.name, others: others, utf8: utf8, db) }
        guard let row = (try? SQLiteReader.row(edit.table, key: edit.key, info: info, db)) ?? nil else { return failure(sqlite3_errcode(db), db) }
        let stored = (try? cell(edit, column: column.name, limit: .none, db)) ?? edit.value
        // The row as the step that undoes this checks it, with the cell as stored, whole.
        let after = row.map { $0.column.lowercased() == column.name.lowercased() ? SQLiteColumnValue(column: $0.column, value: stored) : $0 }
        return .saved(stored: stored, row: after)
    }

    /// The UPDATE changed no row: the row is gone, the cell changed, another of its values changed, its
    /// text isn't UTF-8, or (all as read) a trigger skipped the change. Each test is the UPDATE's own.
    static func why(_ edit: SQLiteEdit, info: SQLiteTableInfo, column: String, others: [SQLiteColumnValue], utf8: Bool, _ db: OpaquePointer) -> SQLiteSaveOutcome {
        var bound = Bindings()
        let check = RowCheck(key: edit.key, column: column, expected: edit.expected, others: others, utf8: utf8, &bound)
        let sql = "SELECT \(([check.cell] + check.row).joined(separator: ", ")) FROM \(SQLiteReader.quote(edit.table)) WHERE \(check.key)"
        guard let tests = try? bound.rows(sql, db) else { return failure(sqlite3_errcode(db), db) }
        guard let passed = tests.first.map({ $0.map { $0 == .integer(1) } }) else { return .rowGone }
        if passed.first == false {
            guard let current = (try? cell(edit, column: column, limit: .bytes(SQLiteReader.maxDetailBytes), db)) ?? nil else { return .rowGone }
            guard current.isIdentical(to: edit.expected) else { return .changed(current: current) }
            // Decoded alike, yet the byte-for-byte test missed it: its stored bytes aren't UTF-8.
            return utf8 && storedTextIsUTF8(edit, column: column, db) ? .changed(current: current) : .invalidText
        }
        if passed.contains(false) {
            return ((try? SQLiteReader.row(edit.table, key: edit.key, info: info, db)) ?? nil).map { .rowChanged(row: $0) } ?? .rowGone
        }
        return .skipped
    }

    /// The edited cell as it is now, nil when no row has the key.
    static func cell(_ edit: SQLiteEdit, column: String, limit: SQLiteReader.TextLimit, _ db: OpaquePointer) throws -> SQLiteValue? {
        var columns: [String] = []
        let (lookup, keys) = SQLiteReader.keyClause(edit.key, from: 1)
        let sql = "SELECT \(SQLiteReader.quote(column)) FROM \(SQLiteReader.quote(edit.table)) WHERE \(lookup)"
        return try SQLiteReader.rows(db, sql, bind: keys, columns: &columns, limit: limit).first?.first
    }

    /// Whether the cell's stored bytes are UTF-8, read as a blob (reading them as text would decode them).
    static func storedTextIsUTF8(_ edit: SQLiteEdit, column: String, _ db: OpaquePointer) -> Bool {
        let (lookup, keys) = SQLiteReader.keyClause(edit.key, from: 1)
        let sql = "SELECT CAST(\(SQLiteReader.quote(column)) AS BLOB) FROM \(SQLiteReader.quote(edit.table)) WHERE \(lookup)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return true }
        defer { sqlite3_finalize(statement) }
        for (i, key) in keys.enumerated() where SQLiteReader.bind(key, to: statement, at: Int32(i + 1)) != SQLITE_OK { return true }
        guard sqlite3_step(statement) == SQLITE_ROW else { return true }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { return true }
        var input = UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: count).makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&input) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    static func failure(_ code: Int32, _ db: OpaquePointer) -> SQLiteSaveOutcome {
        switch code & 0xFF {
        case SQLITE_BUSY, SQLITE_LOCKED: return .busy
        case SQLITE_READONLY, SQLITE_CANTOPEN, SQLITE_PERM: return .readOnly
        default: return .refused(errorMessage(db))
        }
    }

    static func errorMessage(_ db: OpaquePointer?) -> String {
        let text = db.map { String(cString: sqlite3_errmsg($0)) } ?? "it could not be opened"
        let redacted = DatabaseMask.redact(text)
        return redacted.hasSuffix(".") ? redacted : redacted + "."
    }
}

/// The tests a save's UPDATE makes, their values bound in `Bindings`: the key, the cell as read, and each
/// other value of the row as read.
struct RowCheck {
    let key: String
    let cell: String
    let row: [String]

    init(key: SQLiteRowKey, column: String, expected: SQLiteValue, others: [SQLiteColumnValue], utf8: Bool, _ bound: inout Bindings) {
        self.key = key.parts.map { "\(SQLiteReader.quote($0.column)) = \(bound.add(.value($0.value)))" }.joined(separator: " AND ")
        let name = SQLiteReader.quote(column)
        let p = bound.add(.value(expected))
        cell = "(\(name) IS \(p) COLLATE BINARY AND typeof(\(name)) = typeof(\(p)))"
        row = others.compactMap { Self.test($0.column, $0.value, utf8: utf8, &bound) }
    }

    /// That `column` still holds `value` as it was read, or nil when the read can't be compared again: text
    /// decoded with U+FFFD in it (its bytes may not have been UTF-8), or text cut short in a database that
    /// keeps its text as UTF-16.
    static func test(_ column: String, _ value: SQLiteValue, utf8: Bool, _ bound: inout Bindings) -> String? {
        let c = SQLiteReader.quote(column)
        switch value {
        case .null:
            return "\(c) IS NULL"
        case .integer, .real:
            let p = bound.add(.value(value))
            return "(\(c) IS \(p) AND typeof(\(c)) = typeof(\(p)))"
        case let .text(text, truncated):
            if text.unicodeScalars.contains("\u{FFFD}") { return nil }
            guard truncated else {
                let p = bound.add(.value(value))
                return "(\(c) IS \(p) COLLATE BINARY AND typeof(\(c)) = 'text')"
            }
            guard utf8 else { return nil }
            // Its first bytes, and more after them, compared as a blob: a NUL in the text counts too.
            let bytes = Data(text.utf8)
            let p = bound.add(.bytes(bytes))
            return "(typeof(\(c)) = 'text' AND length(CAST(\(c) AS BLOB)) > \(bytes.count) AND substr(CAST(\(c) AS BLOB), 1, \(bytes.count)) = \(p))"
        case let .blob(size, head):
            var test = "(typeof(\(c)) = 'blob' AND length(\(c)) = \(size)"
            if !head.isEmpty { test += " AND substr(\(c), 1, \(head.count)) = \(bound.add(.bytes(head)))" }
            return test + ")"
        }
    }
}

/// A statement's numbered parameters and what each is bound to: a value as stored, or bytes as a blob.
struct Bindings {
    enum Bound {
        case value(SQLiteValue)
        case bytes(Data)
    }

    struct BindError: Error {}

    private(set) var values: [Bound] = []

    /// The next parameter, `?n`, bound to `value`.
    mutating func add(_ value: Bound) -> String {
        values.append(value)
        return "?\(values.count)"
    }

    /// Steps `sql` once with these values bound: SQLITE_DONE, or an error code (a failed prepare's own).
    func run(_ sql: String, _ db: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { return prepared }
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        return sqlite3_step(statement)
    }

    /// The rows a reading `sql` gives with these values bound.
    func rows(_ sql: String, _ db: OpaquePointer) throws -> [[SQLiteValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement, sqlite3_stmt_readonly(statement) != 0 else { throw BindError() }
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        var result: [[SQLiteValue]] = []
        let count = sqlite3_column_count(statement)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw BindError() }
            result.append((0..<count).map { SQLiteReader.value(statement, $0, limit: .characters(SQLiteReader.maxCellCharacters)) })
        }
    }

    private func bind(_ statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            let result: Int32
            switch value {
            case let .value(value):
                result = SQLiteReader.bind(value, to: statement, at: index)
            case let .bytes(data) where data.isEmpty:
                result = sqlite3_bind_zeroblob(statement, index, 0)
            case let .bytes(data):
                result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            }
            guard result == SQLITE_OK else { throw BindError() }
        }
    }
}

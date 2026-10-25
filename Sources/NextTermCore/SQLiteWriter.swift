import Foundation
import SQLite3
import SQLiteConfig

/// What a Save did. Everything but `saved` wrote nothing: the transaction was rolled back.
public enum SQLiteSaveOutcome: Sendable, Equatable {
    /// Written. `stored` is what the cell holds now, as SQLite stored it.
    case saved(stored: SQLiteValue)
    /// The cell no longer holds what was read: it holds `current`.
    case changed(current: SQLiteValue)
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
    /// SQLite refused it (a constraint, a trigger), or the table can't be edited.
    case refused(String)

    /// One sentence for the detail pane.
    public var message: String {
        switch self {
        case .saved: return "Saved."
        case let .changed(current): return "Changed since it was read. Nothing was saved. Now: " + CellText.line(current.display, limit: 80, cut: current.isTruncated)
        case .rowGone: return "This row was deleted since it was read. Nothing was saved."
        case .busy: return "The file is busy: another app is writing to it. Nothing was saved."
        case .readOnly: return "This file can’t be written (it is read-only on disk). Nothing was saved."
        case .gone: return "The file is not there any more. Nothing was saved."
        case .invalidText: return "Its stored text isn’t valid UTF-8, so it can’t be checked before saving. Nothing was saved."
        case let .refused(reason): return "SQLite refused the change: \(reason) Nothing was saved."
        }
    }
}

/// Writes one checked value to a SQLite file. Only the SQLite viewer's Save, Undo and Redo call it, on
/// the user's action; nothing an agent or an MCP tool runs reaches it.
///
/// Each save opens its own read-write connection (never one that could create the file), with SQLite's
/// defensive mode on (an index's own tables and the schema are read-only), double-quoted strings off,
/// untrusted schema and foreign keys on. In one `BEGIN IMMEDIATE` transaction it checks the table is
/// still an ordinary or WITHOUT ROWID table, then runs one UPDATE keyed by the row's rowid or primary key
/// that changes the cell only if it still holds, byte for byte and of the same type, the value that was
/// read. Exactly one row changed: COMMIT. Anything else: ROLLBACK. A database that had no -wal file beside
/// it is left without one.
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
        SQLiteReader.noDoubleQuotedStrings(db)
        sqlite3_exec(db, "PRAGMA trusted_schema = OFF", nil, nil, nil)
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

        let table = SQLiteReader.quote(edit.table), name = SQLiteReader.quote(column.name)
        let (clause, keys) = SQLiteReader.keyClause(edit.key, from: 3)
        let sql = "UPDATE \(table) SET \(name) = ?1 WHERE \(clause) AND \(name) IS ?2 COLLATE BINARY AND typeof(\(name)) = typeof(?2)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return failure(sqlite3_errcode(db), db) }
        defer { sqlite3_finalize(statement) }
        for (i, value) in ([edit.value, edit.expected] + keys).enumerated() {
            guard SQLiteReader.bind(value, to: statement, at: Int32(i + 1)) == SQLITE_OK else { return .refused("a value could not be bound.") }
        }
        let stepped = sqlite3_step(statement)
        guard stepped == SQLITE_DONE else { return failure(stepped, db) }
        let changed = sqlite3_changes64(db)
        let (lookup, lookupKeys) = SQLiteReader.keyClause(edit.key, from: 1)
        let read = "SELECT \(name) FROM \(table) WHERE \(lookup)"
        guard changed == 1 else {
            if changed > 1 { return .refused("more than one row has this key.") }
            var columns: [String] = []
            guard let rows = try? SQLiteReader.rows(db, read, bind: lookupKeys, columns: &columns, limit: .bytes(SQLiteReader.maxDetailBytes)) else {
                return failure(sqlite3_errcode(db), db)
            }
            guard let current = rows.first?.first else { return .rowGone }
            // Equal as decoded, yet the byte-for-byte check missed it: its bytes aren't valid UTF-8.
            return current == edit.expected ? .invalidText : .changed(current: current)
        }
        var columns: [String] = []
        let stored = (try? SQLiteReader.rows(db, read, bind: lookupKeys, columns: &columns, limit: .none))?.first?.first
        return .saved(stored: stored ?? edit.value)
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

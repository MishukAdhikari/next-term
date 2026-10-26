import Foundation
import SQLite3
import SQLiteConfig

public enum SQLiteValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    /// Cut at `SQLiteReader.maxCellCharacters` in a page (at `SQLiteReader.maxDetailBytes` read alone), with
    /// `truncated` set.
    case text(String, truncated: Bool)
    /// Its size and its first `SQLiteReader.blobHeadBytes` bytes (none when they couldn't be read on their
    /// own): a page keeps no more of a blob, and the viewer never shows or copies one whole.
    case blob(Int, head: Data = Data())

    /// What a grid cell shows ("NULL" for null).
    public var display: String {
        switch self {
        case .null: return "NULL"
        case let .integer(n): return String(n)
        case let .real(d): return SQLiteValue.format(d)
        case let .text(s, truncated): return truncated ? s + "…" : s
        case let .blob(n, _): return "BLOB, \(n.formatted()) byte\(n == 1 ? "" : "s")"
        }
    }

    /// What SQLite's typeof() says of it.
    public var storageClass: String {
        switch self {
        case .null: return "null"
        case .integer: return "integer"
        case .real: return "real"
        case .text: return "text"
        case .blob: return "blob"
        }
    }

    public var isTruncated: Bool {
        if case let .text(_, truncated) = self { return truncated }
        return false
    }

    static func format(_ d: Double) -> String {
        d.isFinite && d == d.rounded() && abs(d) < 1e15 ? String(format: "%.1f", d) : String(d)
    }

    /// The same value byte for byte: the same storage class, text with the same UTF-8 bytes (Swift's ==
    /// takes "é" and "e\u{301}" for one string; SQLite doesn't), a real with the same bits.
    public func isIdentical(to other: SQLiteValue) -> Bool {
        switch (self, other) {
        case (.null, .null): return true
        case let (.integer(a), .integer(b)): return a == b
        case let (.real(a), .real(b)): return a.bitPattern == b.bitPattern
        case let (.text(a, cutA), .text(b, cutB)): return cutA == cutB && a.utf8.elementsEqual(b.utf8)
        case let (.blob(a, headA), .blob(b, headB)): return a == b && headA == headB
        default: return false
        }
    }

    /// Whether two reads could be of one stored value: identical, or one cut short where the other goes
    /// on the same way (a page's text against the value read whole, a blob's first bytes against more of
    /// them). Text decoded with U+FFFD in it (its bytes aren't UTF-8) can't be told apart, so it agrees.
    public func agrees(with other: SQLiteValue) -> Bool {
        switch (self, other) {
        case let (.text(a, cutA), .text(b, cutB)):
            if a.unicodeScalars.contains("\u{FFFD}") || b.unicodeScalars.contains("\u{FFFD}") { return true }
            let (short, shortCut, long, longCut) = a.utf8.count <= b.utf8.count ? (a, cutA, b, cutB) : (b, cutB, a, cutA)
            // A whole value is all there is: the other read is the same, whole.
            guard shortCut else { return !longCut && short.utf8.elementsEqual(long.utf8) }
            // A cut one goes on past what was read: the other starts the same way, and is longer if whole.
            return (longCut || long.utf8.count > short.utf8.count) && long.utf8.starts(with: short.utf8)
        case let (.blob(a, headA), .blob(b, headB)):
            return a == b && (headA.count <= headB.count ? headB.starts(with: headA) : headA.starts(with: headB))
        default:
            return isIdentical(to: other)
        }
    }
}

/// One column's value in a row, as read.
public struct SQLiteColumnValue: Sendable, Hashable {
    public let column: String
    public let value: SQLiteValue

    public init(column: String, value: SQLiteValue) {
        self.column = column
        self.value = value
    }
}

public struct SQLiteTable: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// An ordinary table, whose rows have a rowid.
        case table
        case withoutRowid
        case view
        /// Kept by a module (full-text search, an R-tree), not by SQLite's own storage.
        case virtual
        /// One of a virtual table's own tables (its index, its settings).
        case shadow
        /// Listed by sqlite_master when pragma_table_list could not say what it is.
        case unverified
    }

    public let name: String
    public let kind: Kind
    /// A shadow table's virtual table; a virtual table's own table, when its triggers or its content=
    /// option name one ("messages" for an index of messages).
    public let owner: String?
    /// A virtual table's module ("fts5", "rtree").
    public let module: String?
    public var isView: Bool { kind == .view }

    public init(name: String, kind: Kind, owner: String? = nil, module: String? = nil) {
        self.name = name
        self.kind = kind
        self.owner = owner
        self.module = module
    }
}

/// A column as pragma_table_xinfo describes it.
public struct SQLiteColumn: Sendable, Equatable {
    public let name: String
    /// As declared ("TEXT", "VARCHAR(20)", "" for none).
    public let declaredType: String
    public let notNull: Bool
    /// Its place in the primary key, from 1; 0 when it is not in it.
    public let primaryKeyIndex: Int
    /// Computed from other columns (GENERATED ALWAYS AS), virtual or stored.
    public let isGenerated: Bool

    public init(name: String, declaredType: String = "", notNull: Bool = false, primaryKeyIndex: Int = 0, isGenerated: Bool = false) {
        self.name = name
        self.declaredType = declaredType
        self.notNull = notNull
        self.primaryKeyIndex = primaryKeyIndex
        self.isGenerated = isGenerated
    }
}

/// A table's kind and its columns, as SELECT * lists them (a virtual table's hidden columns are left out).
public struct SQLiteTableInfo: Sendable, Equatable {
    public static let rowidNames = ["rowid", "_rowid_", "oid"]

    public let kind: SQLiteTable.Kind
    public let columns: [SQLiteColumn]
    /// The name the rowid is read by: the first of rowid, _rowid_ and oid that no column takes. Nil for
    /// anything but an ordinary table, and when columns take all three.
    public let rowidName: String?

    public init(kind: SQLiteTable.Kind, columns: [SQLiteColumn]) {
        self.kind = kind
        self.columns = columns
        let taken = Set(columns.map { $0.name.lowercased() })
        rowidName = kind == .table ? Self.rowidNames.first { !taken.contains($0) } : nil
    }

    /// The primary key's columns, in the key's order.
    public var primaryKey: [SQLiteColumn] {
        columns.filter { $0.primaryKeyIndex > 0 }.sorted { $0.primaryKeyIndex < $1.primaryKeyIndex }
    }

    /// In an ordinary table, the INTEGER PRIMARY KEY column: the rowid under another name.
    public var rowidAlias: String? {
        let key = primaryKey
        guard kind == .table, key.count == 1, key[0].declaredType.uppercased() == "INTEGER" else { return nil }
        return key[0].name
    }

    public func column(named name: String) -> SQLiteColumn? {
        columns.first { $0.name == name } ?? columns.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Whether `name` is part of what tells this table's rows apart: the rowid's alias, or a WITHOUT ROWID
    /// table's primary key.
    public func isKey(_ name: String) -> Bool {
        if let alias = rowidAlias, alias.lowercased() == name.lowercased() { return true }
        return kind == .withoutRowid && primaryKey.contains { $0.name.lowercased() == name.lowercased() }
    }
}

/// One column of a row's key and the value it holds.
public struct SQLiteKeyPart: Sendable, Hashable {
    public let column: String
    public let value: SQLiteValue

    public init(column: String, value: SQLiteValue) {
        self.column = column
        self.value = value
    }
}

/// What finds one row again: its rowid, or a WITHOUT ROWID table's primary key. Self-contained, so a row
/// can be read again (or written, checked) after the page it came from is gone.
public enum SQLiteRowKey: Sendable, Hashable {
    case rowid(name: String, value: Int64)
    case primaryKey([SQLiteKeyPart])

    public var parts: [SQLiteKeyPart] {
        switch self {
        case let .rowid(name, value): return [SQLiteKeyPart(column: name, value: .integer(value))]
        case let .primaryKey(parts): return parts
        }
    }

    /// "row 7", "k = theme".
    public var label: String {
        switch self {
        case let .rowid(_, value): return "row \(value)"
        case let .primaryKey(parts):
            return parts.map { "\($0.column) = \(CellText.line($0.value.display, limit: 40))" }.joined(separator: ", ")
        }
    }
}

public struct SQLitePage: Sendable, Equatable {
    public let table: String
    public let columns: [String]
    public let rows: [[SQLiteValue]]
    /// 0-based, of the first row.
    public let offset: Int
    /// Each row's key; nil for a view's or a virtual table's rows, and for a key with a cut text or a
    /// BLOB in it.
    public let keys: [SQLiteRowKey?]
    /// The table's kind and columns, when SQLite could say (not for a virtual table whose module isn't here).
    public let info: SQLiteTableInfo?

    public init(table: String, columns: [String], rows: [[SQLiteValue]], offset: Int, keys: [SQLiteRowKey?]? = nil, info: SQLiteTableInfo? = nil) {
        self.table = table
        self.columns = columns
        self.rows = rows
        self.offset = offset
        self.keys = keys ?? Array(repeating: nil, count: rows.count)
        self.info = info
    }

    /// The row whose key is `key`, on this page.
    public func row(for key: SQLiteRowKey) -> Int? { keys.firstIndex(of: key) }
}

/// Reads a SQLite file and never writes to it: opened with SQLITE_OPEN_READONLY and `query_only`, and
/// as immutable when nothing is in its write-ahead log, so no -wal or -shm file appears in the project.
/// One connection per call, made off the main thread by the caller.
public enum SQLiteReader {
    public static let pageSize = 1000
    public static let maxCellCharacters = 10_000
    /// The most of one value the detail pane reads, by its row's key.
    public static let maxDetailBytes = 4 << 20
    /// How much of a blob a page keeps, for the detail's hex preview.
    public static let blobHeadBytes = 256

    public struct ReadError: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// How much of a text value is kept.
    enum TextLimit {
        case characters(Int)
        case bytes(Int)
        case none
    }

    public static func tables(at path: String) throws -> [SQLiteTable] {
        try withDatabase(path) { try tables($0) }
    }

    /// Every table and view of the main schema, tables first, by name. pragma_table_list says what each one
    /// is; when it can't (an older SQLite, a schema it refuses), sqlite_master lists them unverified.
    static func tables(_ db: OpaquePointer) throws -> [SQLiteTable] {
        let listed: [(name: String, type: String, withoutRowid: Bool)]
        do {
            listed = try rows(db, "SELECT name, type, wr FROM pragma_table_list WHERE schema = 'main' AND type IN ('table', 'view', 'virtual', 'shadow') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY type = 'view', name COLLATE NOCASE")
                .compactMap { row in
                    guard case let .text(name, _) = row[0], case let .text(type, _) = row[1] else { return nil }
                    return (name, type, row[2] == .integer(1))
                }
        } catch {
            return try rows(db, "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY type = 'view', name COLLATE NOCASE")
                .compactMap { row -> SQLiteTable? in
                    guard case let .text(name, _) = row[0], case let .text(type, _) = row[1] else { return nil }
                    return SQLiteTable(name: name, kind: type == "view" ? .view : .unverified)
                }
        }
        let virtuals = listed.filter { $0.type == "virtual" }.map(\.name)
        let described = virtuals.isEmpty ? [:] : describeVirtual(virtuals, db)
        return listed.map { table in
            switch table.type {
            case "view": return SQLiteTable(name: table.name, kind: .view)
            case "virtual":
                return SQLiteTable(name: table.name, kind: .virtual, owner: described[table.name]?.owner, module: described[table.name]?.module)
            case "shadow": return SQLiteTable(name: table.name, kind: .shadow, owner: shadowOwner(table.name, of: virtuals))
            default:
                if let owner = shadowOwner(table.name, of: virtuals) { return SQLiteTable(name: table.name, kind: .shadow, owner: owner) }
                return SQLiteTable(name: table.name, kind: table.withoutRowid ? .withoutRowid : .table)
            }
        }
    }

    /// A table named after a virtual table and "_" is taken for one of its own, even when its module isn't
    /// here to say so: changing it could break the virtual table.
    static func isShadowName(_ name: String, of virtuals: [String]) -> Bool { shadowOwner(name, of: virtuals) != nil }

    /// The virtual table whose name and "_" begin `name` (the longest, when two do).
    static func shadowOwner(_ name: String, of virtuals: [String]) -> String? {
        let name = name.lowercased()
        return virtuals.filter { name.hasPrefix($0.lowercased() + "_") }.max { $0.count < $1.count }
    }

    /// Each virtual table's module, from its CREATE statement, and the table it indexes: the one its
    /// content= option names, or else the table whose triggers write to it.
    static func describeVirtual(_ virtuals: [String], _ db: OpaquePointer) -> [String: (module: String?, owner: String?)] {
        let created = (try? rows(db, "SELECT name, sql FROM sqlite_master WHERE type = 'table'")) ?? []
        let triggers = (try? rows(db, "SELECT tbl_name, sql FROM sqlite_master WHERE type = 'trigger'")) ?? []
        var result: [String: (module: String?, owner: String?)] = [:]
        for case let row in created where row.count == 2 {
            guard case let .text(name, _) = row[0], virtuals.contains(name), case let .text(sql, _) = row[1] else { continue }
            let module = sql.range(of: "USING", options: .caseInsensitive).map { range in
                String(sql[range.upperBound...].drop { $0 == " " }.prefix { $0.isLetter || $0.isNumber || $0 == "_" }).lowercased()
            }
            var owner = contentOption(sql)
            if owner == nil {
                owner = triggers.lazy.compactMap { trigger -> String? in
                    guard trigger.count == 2, case let .text(table, _) = trigger[0], case let .text(body, _) = trigger[1],
                          table.lowercased() != name.lowercased(), mentions(body, name) else { return nil }
                    return table
                }.first
            }
            result[name] = (module, owner)
        }
        return result
    }

    /// `content='messages'` in an FTS table's arguments.
    static func contentOption(_ sql: String) -> String? {
        guard let range = sql.range(of: #"\bcontent\s*=\s*['"`\[]?([A-Za-z0-9_]+)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let value = sql[range].split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"`[")) }
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether `sql` names `table` as a whole word.
    static func mentions(_ sql: String, _ table: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: table)
        return sql.range(of: "(^|[^A-Za-z0-9_])" + escaped + "($|[^A-Za-z0-9_])", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What `table` is now, or nil when it isn't there.
    static func kind(of table: String, _ db: OpaquePointer) throws -> SQLiteTable.Kind? {
        let all = try tables(db)
        return (all.first { $0.name == table } ?? all.first { $0.name.lowercased() == table.lowercased() })?.kind
    }

    /// The columns pragma_table_xinfo lists, a virtual table's hidden ones left out. Nil when SQLite can't
    /// say (a virtual table whose module isn't here).
    static func tableInfo(_ table: String, kind: SQLiteTable.Kind, _ db: OpaquePointer) -> SQLiteTableInfo? {
        guard let listed = try? rows(db, "SELECT * FROM pragma_table_xinfo(?1)", bind: [.text(table, truncated: false)]), !listed.isEmpty else { return nil }
        var columns: [SQLiteColumn] = []
        for row in listed where row.count >= 7 {
            guard case let .text(name, _) = row[1] else { return nil }
            let hidden = row[6] == .integer(1) ? 1 : row[6] == .integer(2) ? 2 : row[6] == .integer(3) ? 3 : 0
            if hidden == 1 { continue }
            var type = ""
            if case let .text(declared, _) = row[2] { type = declared }
            var key = 0
            if case let .integer(n) = row[5] { key = Int(n) }
            columns.append(SQLiteColumn(name: name, declaredType: type, notNull: row[3] == .integer(1), primaryKeyIndex: key, isGenerated: hidden >= 2))
        }
        return SQLiteTableInfo(kind: kind, columns: columns)
    }

    public static func count(_ table: String, at path: String) throws -> Int {
        try withDatabase(path) { db in
            guard case let .integer(n)? = try rows(db, "SELECT count(*) FROM \(quote(table))").first?.first else { return 0 }
            return Int(n)
        }
    }

    /// A page of rows, each with its key: an ordinary table's rowid is read with them, a WITHOUT ROWID
    /// table's primary key is in them. An ordinary table's blobs are never loaded (lightRows); elsewhere
    /// SQLite reads each blob as its row is stepped, and only its first bytes are kept.
    public static func page(_ table: String, at path: String, offset: Int, limit: Int = pageSize) throws -> SQLitePage {
        try withDatabase(path) { db in
            let start = max(0, offset)
            let range = "LIMIT \(max(1, limit)) OFFSET \(start)"
            let info = (try? kind(of: table, db)).flatMap { tableInfo(table, kind: $0, db) }
            var columns: [String] = []
            if let info, let rowid = info.rowidName, !info.columns.isEmpty {
                let read = try lightRows(db, table, info: info, rowid: rowid, tail: range)
                return SQLitePage(table: table, columns: info.columns.map(\.name), rows: read.rows, offset: start,
                                  keys: read.ids.map { $0.map { .rowid(name: rowid, value: $0) } }, info: info)
            }
            let rows = try rows(db, "SELECT * FROM \(quote(table)) \(range)", columns: &columns)
            var keys: [SQLiteRowKey?]?
            if let info, info.kind == .withoutRowid, info.columns.map(\.name) == columns {
                let key = info.primaryKey.compactMap { part in info.columns.firstIndex { $0.name == part.name }.map { (part.name, $0) } }
                keys = rows.map { row in
                    guard !key.isEmpty else { return nil }
                    let parts = key.map { SQLiteKeyPart(column: $0.0, value: row[$0.1]) }
                    return parts.allSatisfy({ isUsableKey($0.value) }) ? .primaryKey(parts) : nil
                }
            }
            return SQLitePage(table: table, columns: columns, rows: rows, offset: start, keys: keys, info: info)
        }
    }

    /// Rows of an ordinary table, each with its rowid, read the way a page keeps them but without loading
    /// a blob: SQLite tells a blob's type and size from the row's header, and its first bytes come through
    /// sqlite3_blob_read (substr() in a table with a generated column, where no blob is opened). A
    /// page of large attachments then costs what its text does. `tail` follows the FROM clause (a WHERE, a
    /// LIMIT), with `values` bound to it. One read transaction, so the first bytes are of the rows read.
    static func lightRows(_ db: OpaquePointer, _ table: String, info: SQLiteTableInfo, rowid: String, tail: String,
                          bind values: [SQLiteValue] = []) throws -> (ids: [Int64?], rows: [[SQLiteValue]]) {
        let list = info.columns.map { column -> String in
            let name = quote(column.name)
            return "CASE typeof(\(name)) WHEN 'blob' THEN NULL ELSE \(name) END, CASE typeof(\(name)) WHEN 'blob' THEN length(\(name)) END"
        }
        let own = sqlite3_get_autocommit(db) != 0
        if own { sqlite3_exec(db, "BEGIN", nil, nil, nil) }
        defer { if own { sqlite3_exec(db, "COMMIT", nil, nil, nil) } }
        var columns: [String] = []
        let read = try rows(db, "SELECT \(quote(rowid)), \(list.joined(separator: ", ")) FROM \(quote(table)) \(tail)", bind: values, columns: &columns)
        var ids: [Int64?] = []
        var result: [[SQLiteValue]] = []
        var blobs: [(row: Int, column: Int)] = []
        ids.reserveCapacity(read.count)
        result.reserveCapacity(read.count)
        for row in read where row.count == 1 + 2 * info.columns.count {
            if case let .integer(id) = row[0] { ids.append(id) } else { ids.append(nil) }
            var values: [SQLiteValue] = []
            values.reserveCapacity(info.columns.count)
            for i in info.columns.indices {
                if case let .integer(size) = row[2 * i + 2] {
                    values.append(.blob(Int(size)))
                    if size > 0 { blobs.append((result.count, i)) }
                } else {
                    values.append(row[2 * i + 1])
                }
            }
            result.append(values)
        }
        // One handle a column, moved from row to row. In a table with a generated column the first bytes come from
        // substr(), which loads that blob alone: newer SQLite opens no blob there, and the SQLite of macOS 13 to 15
        // opens one that can read another column's bytes, since a virtual column has no place in the stored row.
        let opensBlobs: Bool = !info.columns.contains { (column: SQLiteColumn) -> Bool in column.isGenerated }
        var handles: [Int: OpaquePointer] = [:]
        var statements: [Int: OpaquePointer] = [:]
        defer {
            handles.values.forEach { sqlite3_blob_close($0) }
            statements.values.forEach { sqlite3_finalize($0) }
        }
        for blob in blobs {
            guard let id = ids[blob.row], case let .blob(size, _) = result[blob.row][blob.column] else { continue }
            let name = info.columns[blob.column].name
            var head: Data?
            if statements[blob.column] == nil {
                if let open = handles[blob.column], sqlite3_blob_reopen(open, id) != SQLITE_OK {
                    // A handle that failed to move is aborted: a new one.
                    sqlite3_blob_close(open)
                    handles[blob.column] = nil
                }
                if handles[blob.column] == nil {
                    var made: OpaquePointer?
                    if opensBlobs, sqlite3_blob_open(db, "main", table, name, id, 0, &made) == SQLITE_OK, let made {
                        handles[blob.column] = made
                    } else {
                        sqlite3_blob_close(made)
                        var statement: OpaquePointer?
                        let sql = "SELECT substr(\(quote(name)), 1, \(blobHeadBytes)) FROM \(quote(table)) WHERE \(quote(rowid)) = ?1"
                        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { sqlite3_finalize(statement); continue }
                        statements[blob.column] = statement
                    }
                }
                if let handle = handles[blob.column] {
                    var bytes = [UInt8](repeating: 0, count: min(Int(sqlite3_blob_bytes(handle)), blobHeadBytes))
                    if sqlite3_blob_read(handle, &bytes, Int32(bytes.count), 0) == SQLITE_OK { head = Data(bytes) }
                }
            }
            if let statement = statements[blob.column] {
                sqlite3_reset(statement)
                sqlite3_bind_int64(statement, 1, id)
                if sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_BLOB, let start = sqlite3_column_blob(statement, 0) {
                    head = Data(bytes: start, count: Int(sqlite3_column_bytes(statement, 0)))
                }
            }
            if let head { result[blob.row][blob.column] = .blob(size, head: head) }
        }
        return (ids, result)
    }

    /// One row as a page reads it, by its key, each value with its column; nil when no row has the key.
    static func row(_ table: String, key: SQLiteRowKey, info: SQLiteTableInfo, _ db: OpaquePointer) throws -> [SQLiteColumnValue]? {
        let (clause, values) = keyClause(key, from: 1)
        if info.kind == .table, let rowid = info.rowidName, !info.columns.isEmpty {
            guard let first = try lightRows(db, table, info: info, rowid: rowid, tail: "WHERE \(clause)", bind: values).rows.first else { return nil }
            return zip(info.columns, first).map { SQLiteColumnValue(column: $0.name, value: $1) }
        }
        var columns: [String] = []
        guard let first = try rows(db, "SELECT * FROM \(quote(table)) WHERE \(clause)", bind: values, columns: &columns).first else { return nil }
        return zip(columns, first).map { SQLiteColumnValue(column: $0, value: $1) }
    }

    /// A key part that can be compared again: not cut, not a blob (only its first bytes were read).
    static func isUsableKey(_ value: SQLiteValue) -> Bool {
        switch value {
        case .blob: return false
        case let .text(_, truncated): return !truncated
        default: return true
        }
    }

    /// One value, read again by its row's key, up to `limit` bytes of text (cut there, with `truncated` set).
    /// Nil when no row has the key any more.
    public static func value(_ table: String, column: String, key: SQLiteRowKey, at path: String, limit: Int = maxDetailBytes) throws -> SQLiteValue? {
        try withDatabase(path) { db in
            // Every name here is the viewer's own: a column renamed since the page was read fails to read.
            noDoubleQuotedStrings(db)
            let (clause, values) = keyClause(key, from: 1)
            var columns: [String] = []
            return try rows(db, "SELECT \(quote(column)) FROM \(quote(table)) WHERE \(clause)", bind: values, columns: &columns, limit: .bytes(limit)).first?.first
        }
    }

    /// `"id" = ?1 AND "k" = ?2`, numbered from `index`, and the values to bind.
    static func keyClause(_ key: SQLiteRowKey, from index: Int) -> (String, [SQLiteValue]) {
        let parts = key.parts
        let clause = parts.enumerated().map { "\(quote($1.column)) = ?\(index + $0)" }.joined(separator: " AND ")
        return (clause, parts.map(\.value))
    }

    /// `"name"`, with quotes inside doubled.
    public static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: connection

    static func withDatabase<T>(_ path: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard isRegularFile(path) else { throw ReadError(message: "The file is not there any more.") }
        var uri = fileURI(path) + "?mode=ro"
        if isWAL(path), !FileManager.default.fileExists(atPath: path + "-wal") { uri += "&immutable=1" }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            throw ReadError(message: DatabaseMask.redact("SQLite could not open the file: \(message)."))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        sqlite3_exec(db, "PRAGMA query_only = 1", nil, nil, nil)
        return try body(db)
    }

    /// `file:` and the path, percent-encoded where a URI needs it.
    static func fileURI(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        return "file:" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)
    }

    /// An identifier in double quotes that names nothing is an error, never a string: `"rowid"` on a
    /// WITHOUT ROWID table would otherwise read the word rowid. Only for a statement whose every name is
    /// the viewer's own: a view's SELECT and a trigger's body are compiled under this setting too, and many
    /// are written with double-quoted strings.
    static func noDoubleQuotedStrings(_ db: OpaquePointer) {
        _ = nt_sqlite3_db_config_flag(db, SQLITE_DBCONFIG_DQS_DML, 0)
        _ = nt_sqlite3_db_config_flag(db, SQLITE_DBCONFIG_DQS_DDL, 0)
    }

    /// Bytes 18 and 19 of the header are 2 in WAL mode.
    static func isWAL(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 20)) ?? Data()
        return header.count == 20 && header[header.startIndex + 18] == 2
    }

    static func rows(_ db: OpaquePointer, _ sql: String, bind values: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        var columns: [String] = []
        return try rows(db, sql, bind: values, columns: &columns)
    }

    static func rows(_ db: OpaquePointer, _ sql: String, bind values: [SQLiteValue] = [], columns: inout [String],
                     limit: TextLimit = .characters(maxCellCharacters)) throws -> [[SQLiteValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ReadError(message: DatabaseMask.redact(String(cString: sqlite3_errmsg(db))))
        }
        defer { sqlite3_finalize(statement) }
        // Only reading statements run here, whatever the SQL says.
        guard sqlite3_stmt_readonly(statement) != 0 else { throw ReadError(message: "Only reading is allowed.") }
        for (i, value) in values.enumerated() {
            guard bind(value, to: statement, at: Int32(i + 1)) == SQLITE_OK else { throw ReadError(message: "A value could not be bound.") }
        }
        let count = sqlite3_column_count(statement)
        columns = (0..<count).map { sqlite3_column_name(statement, $0).map { String(cString: $0) } ?? "" }
        var result: [[SQLiteValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ReadError(message: DatabaseMask.redact(String(cString: sqlite3_errmsg(db)))) }
            result.append((0..<count).map { value(statement, $0, limit: limit) })
        }
        return result
    }

    /// Binds a value as it is stored: text with its own length (a NUL inside it stays). A blob can't be
    /// bound, since only its first bytes were read.
    static func bind(_ value: SQLiteValue, to statement: OpaquePointer, at index: Int32) -> Int32 {
        switch value {
        case .null: return sqlite3_bind_null(statement, index)
        case let .integer(n): return sqlite3_bind_int64(statement, index, n)
        case let .real(d): return sqlite3_bind_double(statement, index, d)
        case let .text(text, _):
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            var bytes = Array(text.utf8)
            bytes.append(0)
            return bytes.withUnsafeBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                    sqlite3_bind_text(statement, index, $0, Int32(buffer.count - 1), transient)
                }
            }
        case .blob: return SQLITE_MISUSE
        }
    }

    static func value(_ statement: OpaquePointer, _ i: Int32, limit: TextLimit) -> SQLiteValue {
        switch sqlite3_column_type(statement, i) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, i))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, i))
        case SQLITE_BLOB:
            let start = sqlite3_column_blob(statement, i)
            let size = Int(sqlite3_column_bytes(statement, i))
            return .blob(size, head: start.map { Data(bytes: $0, count: min(size, blobHeadBytes)) } ?? Data())
        case SQLITE_TEXT:
            guard let bytes = sqlite3_column_text(statement, i) else { return .text("", truncated: false) }
            let length = Int(sqlite3_column_bytes(statement, i))
            switch limit {
            case let .characters(most):
                let text = String(decoding: UnsafeBufferPointer(start: bytes, count: min(length, most * 4)), as: UTF8.self)
                let cut = text.count > most || length > most * 4
                return .text(cut ? String(text.prefix(most)) : text, truncated: cut)
            case let .bytes(most) where length > most:
                // Cut where a character starts, never inside one.
                var end = max(0, most)
                while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
                return .text(String(decoding: UnsafeBufferPointer(start: bytes, count: end), as: UTF8.self), truncated: true)
            case .bytes, .none:
                return .text(String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self), truncated: false)
            }
        default: return .null
        }
    }
}

/// Rows as CSV, JSON or Markdown, for the clipboard and for an agent.
public enum TableExport {
    public static func csv(columns: [String], rows: [[SQLiteValue]]) -> String {
        func field(_ text: String) -> String {
            text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        let lines = [columns.map(field).joined(separator: ",")] + rows.map { row in
            row.map { value -> String in
                if case .null = value { return "" }
                return field(value.display)
            }.joined(separator: ",")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func json(columns: [String], rows: [[SQLiteValue]]) -> String {
        func string(_ text: String) -> String {
            (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        }
        func json(_ value: SQLiteValue) -> String {
            switch value {
            case .null: return "null"
            case let .integer(n): return String(n)
            case let .real(d): return d.isFinite ? String(d) : "null"
            case .text, .blob: return string(value.display)
            }
        }
        let objects = rows.map { row in
            "  {" + zip(columns, row).map { "\(string($0)): \(json($1))" }.joined(separator: ", ") + "}"
        }
        return objects.isEmpty ? "[]\n" : "[\n" + objects.joined(separator: ",\n") + "\n]\n"
    }

    public static func markdown(columns: [String], rows: [[SQLiteValue]]) -> String {
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>")
        }
        var lines = ["| " + columns.map(cell).joined(separator: " | ") + " |", "|" + columns.map { _ in " --- |" }.joined()]
        lines += rows.map { "| " + $0.map { cell($0.display) }.joined(separator: " | ") + " |" }
        return lines.joined(separator: "\n") + "\n"
    }
}

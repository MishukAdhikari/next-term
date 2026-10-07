import Foundation
import SQLite3

public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    /// Cut at `SQLiteReader.maxCellCharacters`, with `truncated` set.
    case text(String, truncated: Bool)
    /// Only its size: blobs are not shown or copied.
    case blob(Int)

    /// What a grid cell shows ("NULL" for null).
    public var display: String {
        switch self {
        case .null: return "NULL"
        case let .integer(n): return String(n)
        case let .real(d): return SQLiteValue.format(d)
        case let .text(s, truncated): return truncated ? s + "…" : s
        case let .blob(n): return "BLOB, \(n.formatted()) byte\(n == 1 ? "" : "s")"
        }
    }

    static func format(_ d: Double) -> String {
        d.isFinite && d == d.rounded() && abs(d) < 1e15 ? String(format: "%.1f", d) : String(d)
    }
}

public struct SQLiteTable: Sendable, Equatable {
    public let name: String
    public let isView: Bool
}

public struct SQLitePage: Sendable, Equatable {
    public let table: String
    public let columns: [String]
    public let rows: [[SQLiteValue]]
    /// 0-based, of the first row.
    public let offset: Int
}

/// Reads a SQLite file and never writes to it: opened with SQLITE_OPEN_READONLY and `query_only`, and
/// as immutable when nothing is in its write-ahead log, so no -wal or -shm file appears in the project.
/// One connection per call, made off the main thread by the caller.
public enum SQLiteReader {
    public static let pageSize = 1000
    public static let maxCellCharacters = 10_000

    public struct ReadError: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func tables(at path: String) throws -> [SQLiteTable] {
        try withDatabase(path) { db in
            try rows(db, "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY type = 'view', name COLLATE NOCASE")
                .compactMap { row -> SQLiteTable? in
                    guard case let .text(name, _) = row[0], case let .text(type, _) = row[1] else { return nil }
                    return SQLiteTable(name: name, isView: type == "view")
                }
        }
    }

    public static func count(_ table: String, at path: String) throws -> Int {
        try withDatabase(path) { db in
            guard case let .integer(n)? = try rows(db, "SELECT count(*) FROM \(quote(table))").first?.first else { return 0 }
            return Int(n)
        }
    }

    public static func page(_ table: String, at path: String, offset: Int, limit: Int = pageSize) throws -> SQLitePage {
        try withDatabase(path) { db in
            var columns: [String] = []
            let rows = try rows(db, "SELECT * FROM \(quote(table)) LIMIT \(max(1, limit)) OFFSET \(max(0, offset))", columns: &columns)
            return SQLitePage(table: table, columns: columns, rows: rows, offset: max(0, offset))
        }
    }

    /// `"name"`, with quotes inside doubled.
    public static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: connection

    static func withDatabase<T>(_ path: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard isRegularFile(path) else { throw ReadError(message: "The file is not there any more.") }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        var uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path) + "?mode=ro"
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

    /// Bytes 18 and 19 of the header are 2 in WAL mode.
    static func isWAL(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 20)) ?? Data()
        return header.count == 20 && header[header.startIndex + 18] == 2
    }

    static func rows(_ db: OpaquePointer, _ sql: String) throws -> [[SQLiteValue]] {
        var columns: [String] = []
        return try rows(db, sql, columns: &columns)
    }

    static func rows(_ db: OpaquePointer, _ sql: String, columns: inout [String]) throws -> [[SQLiteValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ReadError(message: DatabaseMask.redact(String(cString: sqlite3_errmsg(db))))
        }
        defer { sqlite3_finalize(statement) }
        // Only reading statements run here, whatever the SQL says.
        guard sqlite3_stmt_readonly(statement) != 0 else { throw ReadError(message: "Only reading is allowed.") }
        let count = sqlite3_column_count(statement)
        columns = (0..<count).map { sqlite3_column_name(statement, $0).map { String(cString: $0) } ?? "" }
        var result: [[SQLiteValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ReadError(message: DatabaseMask.redact(String(cString: sqlite3_errmsg(db)))) }
            result.append((0..<count).map { value(statement, $0) })
        }
        return result
    }

    private static func value(_ statement: OpaquePointer, _ i: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, i) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, i))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, i))
        case SQLITE_BLOB: return .blob(Int(sqlite3_column_bytes(statement, i)))
        case SQLITE_TEXT:
            guard let bytes = sqlite3_column_text(statement, i) else { return .text("", truncated: false) }
            let length = Int(sqlite3_column_bytes(statement, i))
            let text = String(decoding: UnsafeBufferPointer(start: bytes, count: min(length, maxCellCharacters * 4)), as: UTF8.self)
            let cut = text.count > maxCellCharacters || length > maxCellCharacters * 4
            return .text(cut ? String(text.prefix(maxCellCharacters)) : text, truncated: cut)
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

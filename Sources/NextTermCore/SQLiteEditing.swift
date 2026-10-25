import Foundation

/// SQLite's type affinity for a declared column type, by its five rules in their order.
public enum SQLiteAffinity: Sendable, Equatable {
    case integer, text, blob, real, numeric

    public init(declaredType: String) {
        let type = declaredType.uppercased()
        if type.contains("INT") {
            self = .integer
        } else if type.contains("CHAR") || type.contains("CLOB") || type.contains("TEXT") {
            self = .text
        } else if type.contains("BLOB") || type.trimmingCharacters(in: .whitespaces).isEmpty {
            self = .blob
        } else if type.contains("REAL") || type.contains("FLOA") || type.contains("DOUB") {
            self = .real
        } else {
            self = .numeric
        }
    }
}

/// What can be edited, decided before any SQL runs. Each refusal is one line the detail pane shows.
public enum SQLiteEditRules {
    /// Text longer than this edits in the detail pane, not in its cell.
    public static let inCellCharacters = 1000

    /// Why this cell can't be edited, or nil when it can. The checks run in this order: a view, a virtual
    /// table, a shadow table, a table SQLite couldn't describe, a rowid that columns hide, a row without a
    /// usable key, a key column, a generated column, a blob, a value too large to have been read whole.
    public static func reason(table: SQLiteTable, info: SQLiteTableInfo?, column: String, value: SQLiteValue, key: SQLiteRowKey?) -> String? {
        switch table.kind {
        case .view: return "A view shows rows from other tables; it can’t be edited here."
        case .virtual:
            let module: String
            switch table.module ?? "" {
            case "fts3", "fts4", "fts5": module = "its full-text module"
            case "rtree", "rtree_i32", "geopoly": module = "its R-tree module"
            default: module = "its module"
            }
            return "A virtual table, kept by \(module)" + (table.owner.map { ": edit \($0) instead." } ?? ".")
        case .shadow:
            return "An internal table of \(table.owner ?? "a virtual table"): changing it would break the index."
        case .unverified: return "SQLite couldn’t say what kind of table this is, so it can’t be edited here."
        case .table, .withoutRowid: break
        }
        guard let info, info.kind == table.kind else { return "SQLite couldn’t describe this table’s columns, so it can’t be edited here." }
        if info.kind == .table, info.rowidName == nil {
            return "Its columns named rowid, _rowid_ and oid hide the rowid, so a row can’t be found again to save it."
        }
        guard let key, key.parts.allSatisfy({ SQLiteReader.isUsableKey($0.value) }) else {
            return "This row’s key is too long or is a BLOB, so the row can’t be found again to save it."
        }
        guard let described = info.column(named: column) else { return "This column isn’t in the table any more." }
        if info.isKey(column) { return "This column is the row’s key." }
        if described.isGenerated { return "A generated column: SQLite computes it from the others." }
        if case .blob = value { return "A BLOB can’t be edited here." }
        if value.isTruncated { return "Over \(SQLiteReader.maxDetailBytes >> 20) MB: too large to edit here." }
        return nil
    }

    /// A short value on one line, which edits in its cell: a number, or text of at most 1,000 characters
    /// with no line break or control character that isn't JSON. Everything else edits in the detail pane.
    public static func inCellEditable(_ value: SQLiteValue) -> Bool {
        switch value {
        case .integer, .real: return true
        case .null, .blob: return false
        case let .text(text, truncated):
            guard !truncated, text.count <= inCellCharacters else { return false }
            guard !text.unicodeScalars.contains(where: { CellText.mark(for: $0) != nil }) else { return false }
            return JSONIndent.pretty(text) == nil
        }
    }
}

/// An edit to one cell, before it is saved: the whole original value, the text as typed, and Set NULL.
/// Only a Save writes it, through SQLiteWriter.
public struct CellDraft: Sendable, Equatable {
    public enum DraftError: Error, Sendable, Equatable {
        case notWholeNumber, notNumber, outOfRange, notFinite, notNull, blob

        public var message: String {
            switch self {
            case .notWholeNumber: return "Type a whole number, such as 42."
            case .notNumber: return "Type a number, such as 4.5."
            case .outOfRange: return "Too large: a whole number here is at most 9,223,372,036,854,775,807."
            case .notFinite: return "Type a finite number: SQLite stores no infinity or NaN here."
            case .notNull: return "This column is NOT NULL, so it can’t be set to NULL."
            case .blob: return "A BLOB can’t be edited here."
            }
        }
    }

    /// The value as read, whole.
    public let original: SQLiteValue
    public let column: SQLiteColumn
    /// What is typed.
    public var text: String
    /// Set NULL was chosen (typing "NULL" stores the text NULL).
    public var isNull: Bool

    public init(original: SQLiteValue, column: SQLiteColumn) {
        self.original = original
        self.column = column
        isNull = original == .null
        switch original {
        case .null, .blob: text = ""
        case let .integer(n): text = String(n)
        case let .real(d): text = "\(d)"
        case let .text(value, _): text = value
        }
    }

    public var canSetNull: Bool { !column.notNull }

    /// Typing replaces the text and gives the cell a value again after Set NULL.
    public mutating func type(_ typed: String) {
        text = typed
        isNull = false
    }

    /// The value to store. It keeps the original's storage class: an integer stays a 64-bit whole number,
    /// a real a finite number, text exactly as typed. A NULL takes its column's affinity.
    public func value() -> Result<SQLiteValue, DraftError> {
        if isNull { return canSetNull ? .success(.null) : .failure(.notNull) }
        switch original {
        case .integer: return Self.integer(text)
        case .real: return Self.real(text)
        case .text: return .success(.text(text, truncated: false))
        case .blob: return .failure(.blob)
        case .null:
            switch SQLiteAffinity(declaredType: column.declaredType) {
            case .integer: return Self.integer(text)
            case .real: return Self.real(text)
            case .numeric:
                if case let .success(n) = Self.integer(text) { return .success(n) }
                return Self.real(text)
            case .text, .blob: return .success(.text(text, truncated: false))
            }
        }
    }

    /// Whether Save would change the cell: "5.0" against a stored 5.0 does not.
    public var isModified: Bool {
        guard case let .success(value) = value() else { return true }
        return value != original || value.storageClass != original.storageClass
    }

    public var error: DraftError? {
        if case let .failure(error) = value() { return error }
        return nil
    }

    static func integer(_ text: String) -> Result<SQLiteValue, DraftError> {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int64(typed) { return .success(.integer(n)) }
        let digits = typed.drop { $0 == "+" || $0 == "-" }
        return !digits.isEmpty && digits.allSatisfy(\.isASCIIDigit) && typed.count - digits.count <= 1 ? .failure(.outOfRange) : .failure(.notWholeNumber)
    }

    static func real(_ text: String) -> Result<SQLiteValue, DraftError> {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = typed.lowercased().drop { $0 == "+" || $0 == "-" }
        if ["inf", "infinity", "nan"].contains(String(lowered)) { return .failure(.notFinite) }
        // Decimal only: no hex floats, no digit grouping.
        guard !typed.isEmpty, typed.allSatisfy({ $0.isASCIIDigit || "+-.eE".contains($0) }), let d = Double(typed) else { return .failure(.notNumber) }
        return d.isFinite ? .success(.real(d)) : .failure(.notFinite)
    }
}

/// One saved change, or the one that undoes it: the cell (table, column, row key), what it must hold
/// now, and what it becomes.
public struct SQLiteEdit: Sendable, Equatable {
    public let table: String
    public let column: String
    public let key: SQLiteRowKey
    /// What the cell must hold for the save to go ahead.
    public let expected: SQLiteValue
    public let value: SQLiteValue

    public init(table: String, column: String, key: SQLiteRowKey, expected: SQLiteValue, value: SQLiteValue) {
        self.table = table
        self.column = column
        self.key = key
        self.expected = expected
        self.value = value
    }

    /// The edit that puts the cell back, checked against what this one stored.
    public var reversed: SQLiteEdit { SQLiteEdit(table: table, column: column, key: key, expected: value, value: expected) }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

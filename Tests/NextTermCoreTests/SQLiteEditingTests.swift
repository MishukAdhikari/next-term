import Foundation
import Testing
@testable import NextTermCore

@Suite struct SQLiteEditingTests {
    static let messagesInfo = SQLiteTableInfo(kind: .table, columns: [
        SQLiteColumn(name: "id", declaredType: "INTEGER", primaryKeyIndex: 1),
        SQLiteColumn(name: "role", declaredType: "TEXT"),
        SQLiteColumn(name: "content", declaredType: "TEXT"),
        SQLiteColumn(name: "attachment", declaredType: "BLOB"),
        SQLiteColumn(name: "created", declaredType: "REAL", notNull: true),
        SQLiteColumn(name: "words", declaredType: "INTEGER", isGenerated: true),
    ])
    static let messages = SQLiteTable(name: "messages", kind: .table)
    static let row7 = SQLiteRowKey.rowid(name: "rowid", value: 7)

    static func reason(_ column: String = "content", _ value: SQLiteValue = .text("draft", truncated: false), table: SQLiteTable = messages,
                       info: SQLiteTableInfo? = messagesInfo, key: SQLiteRowKey? = row7) -> String? {
        SQLiteEditRules.reason(table: table, info: info, column: column, value: value, key: key)
    }

    @Test func everyRefusalSaysWhy() {
        let viewInfo = SQLiteTableInfo(kind: .view, columns: [SQLiteColumn(name: "content")])
        #expect(Self.reason(table: SQLiteTable(name: "recent", kind: .view), info: viewInfo, key: nil) == "A view shows rows from other tables; it can’t be edited here.")
        let fts = SQLiteTable(name: "messages_fts", kind: .virtual, owner: "messages", module: "fts5")
        #expect(Self.reason(table: fts, info: nil, key: nil) == "A virtual table, kept by its full-text module: edit messages instead.")
        #expect(Self.reason(table: SQLiteTable(name: "geo", kind: .virtual, module: "rtree"), info: nil, key: nil) == "A virtual table, kept by its R-tree module.")
        for shadow in ["data", "idx", "content", "docsize", "config"] {
            let table = SQLiteTable(name: "messages_fts_" + shadow, kind: .shadow, owner: "messages_fts")
            #expect(Self.reason(table: table, key: nil) == "An internal table of messages_fts: changing it would break the index.")
        }
        #expect(Self.reason(table: SQLiteTable(name: "t", kind: .unverified))?.hasPrefix("SQLite couldn’t say what kind of table") == true)
        #expect(Self.reason(info: nil)?.hasPrefix("SQLite couldn’t describe") == true)
        let hide = SQLiteTableInfo(kind: .table, columns: ["rowid", "_rowid_", "oid"].map { SQLiteColumn(name: $0) })
        #expect(hide.rowidName == nil)
        #expect(Self.reason("oid", .integer(9), table: SQLiteTable(name: "hide", kind: .table), info: hide, key: nil)?.hasPrefix("Its columns named rowid, _rowid_ and oid hide the rowid") == true)
        #expect(Self.reason(key: nil)?.hasPrefix("This row’s key is too long or is a BLOB") == true)
        let cutKey = SQLiteRowKey.primaryKey([SQLiteKeyPart(column: "k", value: .text("long", truncated: true))])
        let kvInfo = SQLiteTableInfo(kind: .withoutRowid, columns: [SQLiteColumn(name: "k", declaredType: "TEXT", primaryKeyIndex: 1), SQLiteColumn(name: "v")])
        let kv = SQLiteTable(name: "kv", kind: .withoutRowid)
        #expect(Self.reason("v", table: kv, info: kvInfo, key: cutKey)?.hasPrefix("This row’s key is too long") == true)
        let blobKey = SQLiteRowKey.primaryKey([SQLiteKeyPart(column: "k", value: .blob(3))])
        #expect(Self.reason("v", table: kv, info: kvInfo, key: blobKey)?.hasPrefix("This row’s key is too long or is a BLOB") == true)
        let themeKey = SQLiteRowKey.primaryKey([SQLiteKeyPart(column: "k", value: .text("theme", truncated: false))])
        #expect(Self.reason("k", table: kv, info: kvInfo, key: themeKey) == "This column is the row’s key.")
        #expect(Self.reason("id", .integer(7)) == "This column is the row’s key.", "an INTEGER PRIMARY KEY is the rowid itself")
        #expect(Self.reason("words", .integer(3)) == "A generated column: SQLite computes it from the others.")
        #expect(Self.reason("attachment", .blob(3072)) == "A BLOB can’t be edited here.")
        #expect(Self.reason("content", .text("cut", truncated: true)) == "Over 4 MB: too large to edit here.")
        #expect(Self.reason("gone") == "This column isn’t in the table any more.")
        // In the order the checks run: a view's blob says it is a view.
        #expect(Self.reason("content", .blob(3), table: SQLiteTable(name: "recent", kind: .view), info: viewInfo, key: nil)?.hasPrefix("A view") == true)
    }

    @Test func ordinaryCellsCanBeEdited() {
        #expect(Self.reason("content", .text("draft", truncated: false)) == nil)
        #expect(Self.reason("role", .null) == nil)
        #expect(Self.reason("created", .real(2.5)) == nil)
        let kvInfo = SQLiteTableInfo(kind: .withoutRowid, columns: [SQLiteColumn(name: "k", primaryKeyIndex: 1), SQLiteColumn(name: "v", declaredType: "INTEGER")])
        let key = SQLiteRowKey.primaryKey([SQLiteKeyPart(column: "k", value: .text("theme", truncated: false))])
        #expect(Self.reason("v", .integer(3), table: SQLiteTable(name: "kv", kind: .withoutRowid), info: kvInfo, key: key) == nil)
        let textKey = SQLiteTableInfo(kind: .table, columns: [SQLiteColumn(name: "code", declaredType: "TEXT", primaryKeyIndex: 1), SQLiteColumn(name: "n")])
        #expect(textKey.rowidAlias == nil && Self.reason("code", .text("a", truncated: false), table: SQLiteTable(name: "codes", kind: .table), info: textKey) == nil,
                "a TEXT primary key in a rowid table isn't the rowid: the row is found by its rowid")
    }

    @Test func affinityFollowsSQLitesRules() {
        let cases: [(String, SQLiteAffinity)] = [("INTEGER", .integer), ("BIGINT", .integer), ("int8", .integer), ("CHARINT", .integer),
                                                 ("TEXT", .text), ("VARCHAR(20)", .text), ("CLOB", .text), ("BLOB", .blob), ("", .blob),
                                                 ("REAL", .real), ("DOUBLE PRECISION", .real), ("FLOAT", .real), ("NUMERIC", .numeric),
                                                 ("DECIMAL(10,5)", .numeric), ("BOOLEAN", .numeric), ("DATETIME", .numeric)]
        for (declared, affinity) in cases { #expect(SQLiteAffinity(declaredType: declared) == affinity, "\(declared)") }
    }

    static func draft(_ original: SQLiteValue, _ type: String = "", notNull: Bool = false, typed: String) -> CellDraft {
        var draft = CellDraft(original: original, column: SQLiteColumn(name: "c", declaredType: type, notNull: notNull))
        draft.type(typed)
        return draft
    }

    @Test func aNullTakesItsColumnsAffinity() {
        #expect(Self.draft(.null, "INTEGER", typed: "5").value() == .success(.integer(5)))
        #expect(Self.draft(.null, "INTEGER", typed: "5.5").value() == .failure(.notWholeNumber))
        #expect(Self.draft(.null, "REAL", typed: "5").value() == .success(.real(5)))
        #expect(Self.draft(.null, "NUMERIC", typed: "5").value() == .success(.integer(5)))
        #expect(Self.draft(.null, "NUMERIC", typed: "4.5").value() == .success(.real(4.5)))
        #expect(Self.draft(.null, "NUMERIC", typed: "abc").value() == .failure(.notNumber))
        #expect(Self.draft(.null, "TEXT", typed: "5").value() == .success(.text("5", truncated: false)))
        #expect(Self.draft(.null, "", typed: " 5 ").value() == .success(.text(" 5 ", truncated: false)))
        let null = CellDraft(original: .null, column: SQLiteColumn(name: "c"))
        #expect(null.isNull && null.text == "" && !null.isModified)
    }

    @Test func numbersAreParsedStrictly() {
        #expect(Self.draft(.integer(1), typed: "+5").value() == .success(.integer(5)))
        #expect(Self.draft(.integer(1), typed: " 7 ").value() == .success(.integer(7)), "trimmed, for numbers only")
        #expect(Self.draft(.integer(1), typed: "1,000").value() == .failure(.notWholeNumber))
        #expect(Self.draft(.integer(1), "INTEGER", typed: "4.5").value() == .failure(.notWholeNumber))
        #expect(Self.draft(.integer(1), typed: "99999999999999999999").value() == .failure(.outOfRange))
        #expect(Self.draft(.integer(1), typed: "-9223372036854775808").value() == .success(.integer(.min)))
        #expect(Self.draft(.real(1), typed: "nan").value() == .failure(.notFinite))
        #expect(Self.draft(.real(1), typed: "inf").value() == .failure(.notFinite))
        #expect(Self.draft(.real(1), typed: "-Infinity").value() == .failure(.notFinite))
        #expect(Self.draft(.real(1), typed: "1e400").value() == .failure(.notFinite))
        #expect(Self.draft(.real(1), typed: "1,000").value() == .failure(.notNumber))
        #expect(Self.draft(.real(1), typed: "0x1p3").value() == .failure(.notNumber))
        #expect(Self.draft(.real(1), typed: " 2.5 ").value() == .success(.real(2.5)))
        #expect(Self.draft(.real(1), typed: "").value() == .failure(.notNumber))
        #expect(CellDraft.DraftError.notWholeNumber.message == "Type a whole number, such as 42.")
    }

    @Test func textIsKeptAsTyped() {
        #expect(Self.draft(.text("a", truncated: false), typed: "  spaced \n").value() == .success(.text("  spaced \n", truncated: false)))
        #expect(Self.draft(.text("a", truncated: false), typed: "NULL").value() == .success(.text("NULL", truncated: false)), "typing NULL stores the text")
        #expect(Self.draft(.blob(3), typed: "x").value() == .failure(.blob))
        let original = CellDraft(original: .text("é\u{0}\r\n", truncated: false), column: SQLiteColumn(name: "c"))
        #expect(original.text == "é\u{0}\r\n" && !original.isModified)
    }

    @Test func setNullOnlyWhereAllowed() {
        var required = Self.draft(.real(1), "REAL", notNull: true, typed: "1.0")
        required.isNull = true
        #expect(!required.canSetNull && required.value() == .failure(.notNull) && required.error == .notNull)
        var nullable = Self.draft(.text("x", truncated: false), "TEXT", typed: "x")
        nullable.isNull = true
        #expect(nullable.canSetNull && nullable.value() == .success(.null) && nullable.isModified)
    }

    @Test func modifiedComparesValues() {
        #expect(!Self.draft(.real(5), typed: "5.0").isModified)
        #expect(!Self.draft(.real(5), typed: "5").isModified)
        #expect(Self.draft(.real(5), typed: "6").isModified)
        #expect(!Self.draft(.integer(7), typed: " 7").isModified)
        #expect(!Self.draft(.text("a", truncated: false), typed: "a").isModified)
        #expect(Self.draft(.text("a", truncated: false), typed: "a ").isModified)
        #expect(Self.draft(.integer(7), typed: "seven").isModified, "what doesn't parse is a change, which Save explains")
    }

    @Test func reversedPutsItBack() {
        let edit = SQLiteEdit(table: "kv", column: "v", key: .primaryKey([SQLiteKeyPart(column: "k", value: .text("theme", truncated: false))]),
                              expected: .text("dark", truncated: false), value: .text("light", truncated: false))
        #expect(edit.reversed.expected == .text("light", truncated: false) && edit.reversed.value == .text("dark", truncated: false))
        #expect(edit.reversed.reversed == edit && edit.reversed.key == edit.key)
    }

    @Test func shortValuesEditInTheirCell() {
        #expect(SQLiteEditRules.inCellEditable(.integer(5)) && SQLiteEditRules.inCellEditable(.real(2.5)))
        #expect(SQLiteEditRules.inCellEditable(.text("user", truncated: false)))
        #expect(SQLiteEditRules.inCellEditable(.text(String(repeating: "a", count: 1000), truncated: false)))
        #expect(!SQLiteEditRules.inCellEditable(.text(String(repeating: "a", count: 1001), truncated: false)))
        #expect(!SQLiteEditRules.inCellEditable(.text("two\nlines", truncated: false)))
        #expect(!SQLiteEditRules.inCellEditable(.text("a\tb", truncated: false)))
        #expect(!SQLiteEditRules.inCellEditable(.text("a\u{2028}b", truncated: false)))
        #expect(!SQLiteEditRules.inCellEditable(.text(AgentStore.toolCall, truncated: false)))
        #expect(!SQLiteEditRules.inCellEditable(.text("cut", truncated: true)))
        #expect(!SQLiteEditRules.inCellEditable(.null) && !SQLiteEditRules.inCellEditable(.blob(3)))
    }
}

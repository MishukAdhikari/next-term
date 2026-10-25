import Foundation

/// What the detail pane shows for one cell: its column, what kind of value it is, and the value whole.
/// Text is shown exactly as stored (the text view marks its control characters); a JSON object or array
/// is indented without being parsed and written again, so its key order and numbers stay as stored; a
/// blob is its size and the first bytes in hex. Copy copies the value as stored, never the indented view.
public struct CellDetail: Sendable, Equatable {
    /// The column's name.
    public var title: String
    /// "TEXT · 2,400 characters", "JSON", "INTEGER", "REAL", "NULL", "BLOB · 3,072 bytes".
    public var kind: String
    /// What the value pane shows.
    public var body: String
    public var isJSON = false
    public var isNull = false
    public var isBlob = false
    /// The column's declared type, for the header's tooltip ("" when it has none).
    public var declaredType = ""
    /// What Copy puts on the clipboard: the value as stored. Nil for NULL and a blob.
    public var copyText: String?
    /// What the pane says under the value: it was cut on read, it is being read whole, it is too large.
    public var note: String?

    /// Where a SQLite value came from, which says what a cut text means.
    public enum Source: Sendable, Equatable {
        /// With its page, where text stops at `SQLiteReader.maxCellCharacters`. `fetching`: the rest is
        /// being read by the row's key. `isView`: a view's row, which has no key to read it by.
        case page(fetching: Bool, isView: Bool)
        /// Read alone by its row's key, where text stops at `SQLiteReader.maxDetailBytes`.
        case whole
    }

    public init(title: String, kind: String, body: String) {
        self.title = title
        self.kind = kind
        self.body = body
    }

    /// A SQLite value.
    public static func make(column: String, declaredType: String = "", value: SQLiteValue,
                            source: Source = .page(fetching: false, isView: false)) -> CellDetail {
        var detail: CellDetail
        switch value {
        case .null:
            detail = CellDetail(title: column, kind: "NULL", body: "NULL")
            detail.isNull = true
        case let .integer(n):
            detail = CellDetail(title: column, kind: "INTEGER", body: String(n))
            detail.copyText = detail.body
        case let .real(d):
            detail = CellDetail(title: column, kind: "REAL", body: "\(d)")
            detail.copyText = detail.body
        case let .text(text, truncated):
            detail = textDetail(column: column, text: text, cut: truncated)
            if truncated { detail.note = cutNote(source) }
        case let .blob(size, head):
            detail = CellDetail(title: column, kind: "BLOB · " + bytes(size), body: hex(head, total: size))
            detail.isBlob = true
        }
        detail.declaredType = declaredType
        return detail
    }

    /// A JSON Lines value as the line writes it: an object or array indented, a string without its quotes.
    public static func make(column: String, json: String) -> CellDetail {
        let trimmed = json.trimmingCharacters(in: .whitespaces)
        if let pretty = JSONIndent.pretty(trimmed) {
            var detail = CellDetail(title: column, kind: "JSON", body: pretty)
            detail.isJSON = true
            detail.copyText = json
            return detail
        }
        switch trimmed {
        case "null":
            var detail = CellDetail(title: column, kind: "NULL", body: "null")
            detail.isNull = true
            return detail
        case "true", "false":
            var detail = CellDetail(title: column, kind: "BOOLEAN", body: trimmed)
            detail.copyText = trimmed
            return detail
        default:
            if trimmed.hasPrefix("\"") { return textDetail(column: column, text: DataHead.displayValue(trimmed), cut: false, json: false) }
            if Double(trimmed) != nil {
                var detail = CellDetail(title: column, kind: "NUMBER", body: trimmed)
                detail.copyText = trimmed
                return detail
            }
            return textDetail(column: column, text: json, cut: false, json: false)
        }
    }

    /// A CSV field, or a line of a text file. `cut`: the record was longer than `DataHead.maxRecordBytes`.
    public static func make(column: String, text: String, cut: Bool) -> CellDetail {
        var detail = textDetail(column: column, text: text, cut: cut)
        if cut { detail.note = "Only the first \(megabytes(DataHead.maxRecordBytes)) of this record were read: it is longer." }
        return detail
    }

    /// Text, or JSON when it is a whole object or array.
    static func textDetail(column: String, text: String, cut: Bool, json: Bool = true) -> CellDetail {
        if json, !cut, let pretty = JSONIndent.pretty(text) {
            var detail = CellDetail(title: column, kind: "JSON", body: pretty)
            detail.isJSON = true
            detail.copyText = text
            return detail
        }
        let count = text.count
        let length = cut ? "more than \(count.formatted()) characters" : count == 1 ? "1 character" : "\(count.formatted()) characters"
        var detail = CellDetail(title: column, kind: "TEXT · " + length, body: text)
        detail.copyText = text
        return detail
    }

    static func cutNote(_ source: Source) -> String {
        let shown = "\(SQLiteReader.maxCellCharacters.formatted()) characters"
        switch source {
        case .page(fetching: true, _): return "Reading the whole value…"
        case .page(_, isView: true): return "A view’s rows have no key to read them by again, so only its first \(shown) can be shown."
        case .page: return "This row has no key to read it by again, so only its first \(shown) can be shown."
        case .whole: return "Over \(megabytes(SQLiteReader.maxDetailBytes)): only its first \(megabytes(SQLiteReader.maxDetailBytes)) are shown."
        }
    }

    static func bytes(_ n: Int) -> String { n == 1 ? "1 byte" : "\(n.formatted()) bytes" }

    static func megabytes(_ n: Int) -> String { "\(n >> 20) MB" }

    /// `00000000  89 50 4e 47 0d 0a 1a 0a  00 01 02 …  |.PNG....|`, 16 bytes a line, as `hexdump -C`
    /// writes them, then how many bytes of `total` there are past `data`.
    public static func hex(_ data: Data, total: Int) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            var line = String(format: "%08x  ", offset)
            for i in 0..<16 {
                line += i < row.count ? String(format: "%02x ", row[row.startIndex + i]) : "   "
                if i == 7 { line += " " }
            }
            line += " |" + String(row.map { (0x20...0x7E).contains($0) ? Character(Unicode.Scalar($0)) : "." }) + "|"
            lines.append(line)
            offset += 16
        }
        let rest = total - bytes.count
        if rest > 0 { lines.append(rest == 1 ? "1 more byte" : "\(rest.formatted()) more bytes") }
        return lines.joined(separator: "\n")
    }
}

/// Indents a JSON object or array as stored: two spaces a level, one item a line and ": " after a key.
/// Only whitespace between tokens changes: strings, escapes and numbers stay byte for byte, keys keep
/// their order, and an empty {} or [] stays as it is.
public enum JSONIndent {
    public static func pretty(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        guard let first = bytes.firstIndex(where: { !isSpace($0) }), bytes[first] == 0x7B || bytes[first] == 0x5B,
              (try? JSONSerialization.jsonObject(with: Data(bytes))) != nil else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        var depth = 0
        var i = first
        let n = bytes.count
        // JSONSerialization lets a trailing comma by ("[1,]"); it isn't JSON, and indenting it would leave an empty line.
        var last: UInt8 = 0
        func newline() {
            out.append(0x0A)
            for _ in 0..<(depth * 2) { out.append(0x20) }
        }
        while i < n {
            let byte = bytes[i]
            switch byte {
            case 0x22: // a string, copied whole with its escapes
                last = byte
                out.append(byte)
                i += 1
                while i < n {
                    let c = bytes[i]
                    out.append(c)
                    i += 1
                    if c == 0x5C, i < n { out.append(bytes[i]); i += 1 } else if c == 0x22 { break }
                }
                continue
            case 0x7B, 0x5B: // { [
                out.append(byte)
                var next = i + 1
                while next < n, isSpace(bytes[next]) { next += 1 }
                if next < n, bytes[next] == (byte == 0x7B ? 0x7D : 0x5D) {
                    out.append(bytes[next])
                    last = bytes[next]
                    i = next + 1
                    continue
                }
                depth += 1
                newline()
            case 0x7D, 0x5D: // } ]
                if last == 0x2C { return nil }
                depth = max(0, depth - 1)
                newline()
                out.append(byte)
            case 0x2C: // ,
                out.append(byte)
                newline()
            case 0x3A: // :
                out.append(contentsOf: [0x3A, 0x20])
            default:
                if !isSpace(byte) { out.append(byte) }
            }
            if !isSpace(byte) { last = byte }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
}

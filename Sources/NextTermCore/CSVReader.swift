import Foundation

/// A reader for the CSV files password managers and browsers export, as RFC 4180 writes them: fields split by commas,
/// a quoted field may hold commas, line breaks and `""` for a quote, and a record ends at a line break (CRLF or LF).
/// Blank lines are skipped, a byte-order mark is dropped, and every record must have as many fields as the first, the
/// header. It reads the text's bytes once, splitting only at ASCII, so every field is whole UTF-8.
public enum CSVReader {
    /// The most records a file may hold past its header.
    public static let maxRows = 50_000

    /// One record and the line it starts on (1-based).
    public struct Record: Equatable, Sendable {
        public let fields: [String]
        public let line: Int
    }

    public enum Failure: Error, Equatable, Sendable {
        /// A record with more or fewer fields than the header.
        case ragged(line: Int)
        /// A quote opened on this line and never closed.
        case openQuote(line: Int)
        case tooManyRows

        public var sentence: String {
            switch self {
            case .ragged(let line): return "The row on line \(line) has a different number of columns than the header."
            case .openQuote(let line): return "A quote opened on line \(line) is never closed."
            case .tooManyRows: return "It has more than \(CSVReader.maxRows) rows, more than Next Term reads."
            }
        }
    }

    /// The records of `text`, the header first; none for an empty text.
    public static func records(_ text: String) -> Result<[Record], Failure> {
        var reader = Reader(bytes: Array(text.utf8))
        defer { reader.wipe() }
        return reader.read()
    }
}

/// One pass over a CSV text's bytes.
private struct Reader {
    var bytes: [UInt8]
    var index = 0
    var line = 1
    var field: [UInt8] = []
    var fields: [String] = []
    var records: [CSVReader.Record] = []

    static let comma = UInt8(ascii: ",")
    static let quote = UInt8(ascii: "\"")
    static let newline = UInt8(ascii: "\n")
    static let carriage = UInt8(ascii: "\r")

    init(bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
    }

    mutating func wipe() {
        SecretBytes.wipe(&bytes)
        SecretBytes.wipe(&field)
    }

    mutating func read() -> Result<[CSVReader.Record], CSVReader.Failure> {
        var start: Int = line
        var started = false
        while index < bytes.count {
            let byte: UInt8 = bytes[index]
            if !started {
                if byte == Self.newline || byte == Self.carriage {
                    advanceLine(from: byte)
                    continue
                }
                started = true
                start = line
            }
            if byte == Self.quote {
                index += 1
                guard quoted() else { return .failure(.openQuote(line: start)) }
            } else if byte == Self.comma {
                index += 1
                endField()
            } else if byte == Self.newline || byte == Self.carriage {
                advanceLine(from: byte)
                if let failure = endRecord(line: start) { return .failure(failure) }
                started = false
            } else {
                field.append(byte)
                index += 1
            }
        }
        if started, let failure = endRecord(line: start) { return .failure(failure) }
        return .success(records)
    }

    /// Past a line break: one for `\n`, `\r\n` or a lone `\r`.
    mutating func advanceLine(from byte: UInt8) {
        index += 1
        if byte == Self.carriage, index < bytes.count, bytes[index] == Self.newline { index += 1 }
        line += 1
    }

    /// A quoted run, from past its opening quote to past its closing one; false when it never closes. A `""` is a
    /// quote; line breaks are kept as written. Text between the closing quote and the next comma is kept too.
    mutating func quoted() -> Bool {
        while index < bytes.count {
            let byte: UInt8 = bytes[index]
            index += 1
            if byte == Self.quote {
                if index < bytes.count, bytes[index] == Self.quote {
                    field.append(Self.quote)
                    index += 1
                    continue
                }
                return true
            }
            let lone: Bool = byte == Self.carriage && (index >= bytes.count || bytes[index] != Self.newline)
            if byte == Self.newline || lone { line += 1 }
            field.append(byte)
        }
        return false
    }

    mutating func endField() {
        fields.append(String(decoding: field, as: UTF8.self))
        SecretBytes.wipe(&field)
        field.removeAll(keepingCapacity: true)
    }

    /// The record ends: refused when its fields don't match the header's, or when the rows pass the cap.
    mutating func endRecord(line start: Int) -> CSVReader.Failure? {
        endField()
        let record = CSVReader.Record(fields: fields, line: start)
        fields = []
        if let header = records.first, header.fields.count != record.fields.count { return .ragged(line: start) }
        records.append(record)
        return records.count > CSVReader.maxRows + 1 ? .tooManyRows : nil
    }
}

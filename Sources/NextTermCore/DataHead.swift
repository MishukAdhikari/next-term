import Foundation

/// How a large data file splits into records, for the read-only head view.
public enum DataFileKind: String, Sendable, Equatable {
    /// One JSON value per line: .jsonl, .ndjson.
    case jsonLines
    /// Comma, semicolon or tab separated values: .csv, .tsv. A quoted field can hold newlines.
    case delimited
    /// Plain lines: a log, or any text file too big for the editor.
    case lines

    public init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "jsonl", "ndjson": self = .jsonLines
        case "csv", "tsv": self = .delimited
        default: self = .lines
        }
    }
}

/// Where a page starts: a byte offset at a record boundary, and the 1-based line there.
public struct DataPosition: Sendable, Equatable {
    public var offset: UInt64
    public var line: Int

    public init(offset: UInt64 = 0, line: Int = 1) {
        self.offset = offset
        self.line = line
    }

    public static let start = DataPosition()
}

/// One record: a line, or a CSV row (which can span lines).
public struct DataRecord: Sendable, Equatable {
    /// The 1-based line it starts on.
    public var line: Int
    /// Its text as in the file, without the line ending. Cut at `DataHead.maxRecordBytes`.
    public var raw: String
    /// CSV and TSV: its fields, unquoted. JSON Lines: the values of `keys` as written (a string keeps its
    /// quotes), or the whole value when the line is not an object.
    public var fields: [String] = []
    /// JSON Lines: the object's top-level keys, in the order the line has them.
    public var keys: [String] = []
    /// Why it could not be read: not JSON, a quote that is never closed, too long.
    public var error: String?
    public var isTruncated = false
    /// CSV and TSV: it has more than `DataHead.maxFields` fields. Only the first ones are in `fields`;
    /// `raw` has them all. A JSON line keeps every key, since its cells are found by name.
    public var hasMoreFields = false

    public init(line: Int, raw: String, fields: [String] = [], keys: [String] = [], error: String? = nil, isTruncated: Bool = false) {
        self.line = line
        self.raw = raw
        self.fields = fields
        self.keys = keys
        self.error = error
        self.isTruncated = isTruncated
    }

    /// JSON Lines: the value of a top-level key, as written.
    public func value(for key: String) -> String? {
        keys.firstIndex(of: key).flatMap { $0 < fields.count ? fields[$0] : nil }
    }
}

/// Some records from the start of a file, or from where the last page ended.
public struct DataPage: Sendable, Equatable {
    public var records: [DataRecord]
    /// CSV and TSV: the separator found in the first lines (or the one passed in).
    public var delimiter: UInt8?
    /// Where the next page starts.
    public var end: DataPosition
    /// Nothing follows `end`, as of this read.
    public var isAtEnd: Bool
    /// The file's size when it was read.
    public var fileSize: UInt64
    /// Where the last record starts, when the end of the file ended it rather than a line break: a log
    /// may still be writing that line, so once the file grows it is read again from there.
    public var unterminated: DataPosition?
    /// What this read saw, to tell later whether the file only grew.
    public var fingerprint: DataFingerprint
}

/// Some bytes a read saw: the start of the file and those just before where it stopped. A file that
/// only grew (a log) still has them; one written again in place (`cp`, a script's `>`, which keep the
/// inode) almost never does.
public struct DataFingerprint: Sendable, Equatable {
    public var head: Data
    public var tail: Data
    public var end: UInt64

    static let tailLength = 4096

    init(handle: FileHandle, end: UInt64) throws {
        self.end = end
        try handle.seek(toOffset: 0)
        head = try handle.read(upToCount: Int(min(UInt64(DataHead.headLength), end))) ?? Data()
        let from = end - min(end, UInt64(Self.tailLength))
        try handle.seek(toOffset: from)
        tail = try handle.read(upToCount: Int(end - from)) ?? Data()
    }

    /// The same bytes, from the file as it is now.
    public init?(path: String, end: UInt64) {
        guard isRegularFile(path), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let print = try? DataFingerprint(handle: handle, end: end) else { return nil }
        self = print
    }

    /// Whether the file still has these bytes where they were: it only grew since.
    public func matches(_ path: String) -> Bool {
        DataFingerprint(path: path, end: end) == self
    }
}

public enum DataHeadError: Error, LocalizedError, Equatable {
    case notAFile, binary, utf16, unreadable

    public var errorDescription: String? {
        switch self {
        case .notAFile: return "This is not a regular file."
        case .binary: return "This file is not text."
        case .utf16: return "This file is UTF-16 text, which the head view does not read."
        case .unreadable: return "This file could not be read."
        }
    }
}

/// Lets a background count stop early (the tab closed, the file changed).
public final class DataCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Reads the first records of a file of any size without loading all of it: a page of 1,000 at a time,
/// through a FileHandle, 256 KB at a time. Never writes.
public enum DataHead {
    public static let pageSize = 1000
    /// A record longer than this is cut (an embedding row is about 16 KB; a whole minified file is not a row).
    public static let maxRecordBytes = 1 << 20
    /// A CSV or TSV record keeps its first this many fields: a sparse matrix with 100,000 columns would
    /// otherwise cost ten times its size, and the table shows only 200. A JSON line keeps all its keys:
    /// the columns are the first 200 keys seen in any line, which can come after its 1,000th.
    public static let maxFields = 1000
    /// A page stops early past this many bytes, so 1,000 huge records cannot fill memory.
    public static let maxPageBytes = 64 << 20
    /// A page reads at most about this much. A record still going at that point (a multi-GB file with no
    /// line breaks) ends there, and the next page goes on from the same place on the same line.
    public static let maxScanBytes = 128 << 20
    static let chunkSize = 256 << 10
    /// How much of the start is looked at for a BOM, binary content and the CSV separator.
    static let headLength = 64 << 10

    /// Up to `limit` records from `start` (the start of the file, or a page's `end`). For CSV and TSV,
    /// pass the first page's `delimiter` to later pages.
    public static func page(at path: String, kind: DataFileKind, from start: DataPosition = .start,
                            limit: Int = pageSize, delimiter: UInt8? = nil) throws -> DataPage {
        guard isRegularFile(path) else { throw DataHeadError.notAFile } // a named pipe would block forever
        guard let handle = FileHandle(forReadingAtPath: path) else { throw DataHeadError.unreadable }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            var position = start
            var separator = delimiter
            if start.offset == 0 {
                try handle.seek(toOffset: 0)
                let head = try handle.read(upToCount: headLength) ?? Data()
                if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { throw DataHeadError.utf16 }
                if head.prefix(TextFile.sniffLength).contains(0) { throw DataHeadError.binary }
                if head.starts(with: [0xEF, 0xBB, 0xBF]) { position.offset = 3 }
                if kind == .delimited, separator == nil {
                    separator = detectDelimiter(head.dropFirst(Int(position.offset)), fallback: defaultDelimiter(for: path))
                }
            }
            try handle.seek(toOffset: position.offset)
            var scanner = RecordScanner(kind: kind, delimiter: separator ?? defaultDelimiter(for: path), start: position, limit: limit)
            var scanned = 0
            while !scanner.isFull {
                // Each read is an autoreleased buffer: drain them as we go, or a file with no line
                // breaks keeps every chunk it read in memory until the page returns.
                let count = try autoreleasepool { () throws -> Int in
                    let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                    if chunk.isEmpty { scanner.finish() } else { scanner.feed(chunk) }
                    return chunk.count
                }
                if count == 0 { break }
                scanned += count
                if scanned >= maxScanBytes, !scanner.isFull { scanner.stop() }
            }
            let end = scanner.position
            let fingerprint = try DataFingerprint(handle: handle, end: end.offset)
            return DataPage(records: scanner.records, delimiter: kind == .delimited ? separator : nil,
                            end: end, isAtEnd: end.offset >= size, fileSize: size,
                            unterminated: scanner.unterminated, fingerprint: fingerprint)
        } catch let error as DataHeadError {
            throw error
        } catch {
            throw DataHeadError.unreadable
        }
    }

    /// The data files the head view opens in place of the editor once they are over `viewThreshold`.
    public static let viewExtensions: Set<String> = ["jsonl", "ndjson", "csv", "tsv"]
    /// Below this the editor is better: it colours the file and opens it whole.
    public static let viewThreshold = 2 * 1024 * 1024

    /// What opens in the head view rather than the editor: a data file over 2 MB that it can read.
    /// UTF-16 (some spreadsheet exports) goes to the editor, which reads it, or past its limit to its app.
    public static func opensInView(_ path: String) -> Bool {
        guard viewExtensions.contains((path as NSString).pathExtension.lowercased()), isRegularFile(path) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        return size > viewThreshold && isText(path)
    }

    /// Whether the head view can read the file: no NUL byte early on and not UTF-16.
    public static func isText(_ path: String) -> Bool {
        guard isRegularFile(path), let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: TextFile.sniffLength) else { return false }
        if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return false }
        return !head.contains(0)
    }

    /// Stricter, for a file whose name does not say it is data: also UTF-8 through its first 64 KB. Some
    /// PDFs have no NUL byte early on, but none is UTF-8 that far.
    public static func isUTF8Text(_ path: String) -> Bool {
        guard isText(path), let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headLength) else { return false }
        return isUTF8(head)
    }

    /// Whether the bytes are UTF-8, allowing a character cut off at the end (the read stopped inside it).
    static func isUTF8(_ bytes: Data) -> Bool {
        let all = Array(bytes)
        var end = all.count
        // Back up over the last character when it is short of the bytes its first byte says it has.
        var i = end - 1
        while i >= 0, end - i <= 4, all[i] & 0xC0 == 0x80 { i -= 1 }
        if i >= 0, end - i <= 4, end - i < sequenceLength(all[i]) { end = i }
        let failed = transcode(all[..<end].makeIterator(), from: UTF8.self, to: UTF32.self, stoppingOnError: true) { _ in }
        return !failed
    }

    /// How many bytes a UTF-8 character starting with this byte has.
    private static func sequenceLength(_ lead: UInt8) -> Int {
        if lead >= 0xF0 { return 4 }
        if lead >= 0xE0 { return 3 }
        return lead >= 0xC0 ? 2 : 1
    }

    // MARK: counting

    /// Counts a file's lines, 4 MB at a time, without keeping any of it. Calls `progress` with the bytes
    /// and lines so far after each read. Nil when cancelled or unreadable.
    public static func countLines(_ path: String, cancellation: DataCancellation? = nil,
                                  progress: ((UInt64, Int) -> Void)? = nil) -> Int? {
        guard isRegularFile(path), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = 4 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var lines = 0
        var total: UInt64 = 0
        var last: UInt8 = 0x0A
        while true {
            if cancellation?.isCancelled == true { return nil }
            let n = read(handle.fileDescriptor, buffer, size)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            var p = UnsafeRawPointer(buffer)
            var remaining = n
            while remaining > 0, let hit = memchr(p, 0x0A, remaining) {
                lines += 1
                let advance = p.distance(to: UnsafeRawPointer(hit)) + 1
                p += advance
                remaining -= advance
            }
            last = buffer.load(fromByteOffset: n - 1, as: UInt8.self)
            total += UInt64(n)
            progress?(total, lines)
        }
        return lines + (last == 0x0A ? 0 : 1)
    }

    /// About how many records the whole file holds, from how many lines (or bytes) the ones read so far took.
    public static func estimatedTotal(records: Int, through end: DataPosition, fileSize: UInt64, lineCount: Int?) -> Int {
        guard records > 0, end.offset > 0 else { return records }
        let linesRead = end.line - 1
        if let lineCount, linesRead > 0 {
            let perLine = Double(records) / Double(linesRead)
            return max(records, Int((perLine * Double(lineCount)).rounded()))
        }
        let perByte = Double(records) / Double(end.offset)
        return max(records, Int((perByte * Double(fileSize)).rounded()))
    }

    // MARK: CSV

    static func defaultDelimiter(for path: String) -> UInt8 {
        (path as NSString).pathExtension.lowercased() == "tsv" ? 0x09 : 0x2C
    }

    /// The separator a CSV's first lines use most consistently: comma, tab or semicolon (European
    /// spreadsheets write "1,5;2,3", which has both in every line). Quoted text does not count.
    public static func detectDelimiter<Bytes: Collection>(_ head: Bytes, fallback: UInt8) -> UInt8 where Bytes.Element == UInt8 {
        let candidates: [UInt8] = [0x2C, 0x09, 0x3B]
        var counts: [[Int]] = [[], [], []]
        var current = [0, 0, 0]
        var inQuotes = false
        var lines = 0
        // Every comma in the lines counted sits between two digits, as decimal commas do ("1,5"). Decided
        // line by line: the sample can end partway through a line, and that one is not counted. The first
        // line is left out too: a header's commas are text ("Preis, EUR"), whatever the separator.
        var decimalCommas = true
        var lineDecimal = true
        let bytes = Array(head)
        for i in bytes.indices {
            let byte = bytes[i]
            if byte == 0x22 {
                inQuotes.toggle()
                continue
            }
            if inQuotes { continue }
            if byte == 0x0A {
                for k in 0..<3 { counts[k].append(current[k]) }
                if lines > 0, !lineDecimal { decimalCommas = false }
                current = [0, 0, 0]
                lineDecimal = true
                lines += 1
                if lines == 20 { break }
            } else if let k = candidates.firstIndex(of: byte) {
                current[k] += 1
                if byte == 0x2C, !isDecimalComma(bytes, at: i) { lineDecimal = false }
            }
        }
        if lines == 0 { for k in 0..<3 { counts[k].append(current[k]) } } // one line, no newline yet
        // The lines with any separator: a blank line or a one-column row says nothing.
        var sampled = 0
        for i in counts[0].indices where counts[0][i] + counts[1][i] + counts[2][i] > 0 { sampled += 1 }
        var best: SeparatorCount?
        for k in 0..<3 {
            let used = counts[k].filter { $0 > 0 }
            guard !used.isEmpty else { continue }
            var frequency: [Int: Int] = [:]
            for count in used { frequency[count, default: 0] += 1 }
            let top = frequency.max { a, b in a.value == b.value ? a.key < b.key : a.value < b.value }!
            let candidate = SeparatorCount(delimiter: candidates[k], consistent: top.value, mode: top.key)
            if let current = best, !candidate.beats(current, sampled: sampled, fallback: fallback, decimalCommas: decimalCommas) { continue }
            best = candidate
        }
        return best?.delimiter ?? fallback
    }

    private static func isDecimalComma(_ bytes: [UInt8], at i: Int) -> Bool {
        guard i > 0, i + 1 < bytes.count else { return false }
        return isDigit(bytes[i - 1]) && isDigit(bytes[i + 1])
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    /// How a separator shows in a CSV's first lines: how many lines have its most common count, and that count.
    private struct SeparatorCount {
        var delimiter: UInt8
        var consistent: Int
        var mode: Int

        /// Tab over the others: commas in text are far more common than a fixed number of tabs. Semicolon
        /// over comma only when the commas are decimal commas ("1,5;2,3"); a comma file can have a
        /// semicolon in a text column of every row ("1,a;b").
        func rank(decimalCommas: Bool) -> Int {
            if delimiter == 0x09 { return 2 }
            return delimiter == 0x3B && decimalCommas ? 1 : 0
        }

        /// The more consistent one. When both are in every line the same number of times, the rank.
        /// Otherwise (one line says little, or the rank does not choose) the one used more.
        func beats(_ other: SeparatorCount, sampled: Int, fallback: UInt8, decimalCommas: Bool) -> Bool {
            if consistent != other.consistent { return consistent > other.consistent }
            let mine = rank(decimalCommas: decimalCommas)
            let theirs = other.rank(decimalCommas: decimalCommas)
            if sampled > 1, consistent == sampled, mine != theirs { return mine > theirs }
            if mode != other.mode { return mode > other.mode }
            return delimiter == fallback
        }
    }

    /// Whether the first row names the columns: no numbers in it, no repeats, and either a column of
    /// numbers under a name or names short enough to be names. A guess: the view lets you turn it off.
    public static func looksLikeHeader(_ rows: [[String]]) -> Bool {
        guard let first = rows.first, !first.isEmpty else { return false }
        let names = first.map { $0.trimmingCharacters(in: .whitespaces) }
        if names.contains(where: isNumber) { return false }
        let named = names.filter { !$0.isEmpty }
        // One empty name is allowed: pandas writes its index column without one.
        if named.isEmpty || named.count < names.count - 1 || Set(named).count != named.count { return false }
        let body = rows.dropFirst().prefix(50)
        for column in names.indices {
            let values = body.compactMap { column < $0.count ? $0[column].trimmingCharacters(in: .whitespaces) : nil }.filter { !$0.isEmpty }
            if !values.isEmpty, values.allSatisfy(isNumber) { return true }
        }
        return named.allSatisfy { $0.count <= 64 }
    }

    static func isNumber(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, "0123456789+-.".unicodeScalars.contains(first) else { return false }
        return Double(text) != nil
    }

    // MARK: JSON Lines

    /// A line of a JSON Lines file: checked with JSONSerialization, then split into its top-level keys
    /// and values in the order the line has them (JSONSerialization does not keep the order).
    static func jsonRecord(_ bytes: [UInt8], line: Int, truncated: Bool) -> DataRecord {
        var record = DataRecord(line: line, raw: decode(bytes, truncated: truncated), isTruncated: truncated)
        if truncated {
            record.error = "Longer than 1 MB, so it is cut here and not read as JSON."
            return record
        }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])
        } catch {
            record.error = jsonError(error)
            return record
        }
        if let object = topLevelFields(bytes) {
            record.keys = object.keys
            record.fields = object.values
        } else {
            record.fields = [record.raw.trimmingCharacters(in: .whitespaces)] // an array, or a single value
        }
        return record
    }

    static func jsonError(_ error: Error) -> String {
        guard var detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String, !detail.isEmpty else {
            return "Not valid JSON."
        }
        detail = detail.replacingOccurrences(of: "around line 1, column", with: "at column")
        return "Not valid JSON: " + detail
    }

    /// A JSON value as a cell shows it: a string without its quotes and escapes, anything else as written.
    public static func displayValue(_ json: String) -> String {
        guard json.hasPrefix("\""), json.count >= 2 else { return json }
        if !json.contains("\\") { return String(json.dropFirst().dropLast()) }
        let decoded = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        return decoded as? String ?? json
    }

    /// The keys and values of a valid JSON object, as written; nil for anything else.
    static func topLevelFields(_ bytes: [UInt8]) -> (keys: [String], values: [String])? {
        bytes.withUnsafeBufferPointer { b -> (keys: [String], values: [String])? in
            let n = b.count
            var i = skipSpace(b, from: 0)
            guard i < n, b[i] == 0x7B else { return nil } // {
            i += 1
            var keys: [String] = []
            var values: [String] = []
            while true {
                i = skipSpace(b, from: i)
                guard i < n else { return nil }
                if b[i] == 0x7D { break } // }
                if b[i] == 0x2C { // ,
                    i += 1
                    continue
                }
                guard b[i] == 0x22 else { return nil }
                let keyStart = i
                i = stringEnd(b, from: i)
                keys.append(displayValue(String(decoding: UnsafeBufferPointer(rebasing: b[keyStart..<i]), as: UTF8.self)))
                i = skipSpace(b, from: i)
                guard i < n, b[i] == 0x3A else { return nil } // :
                i = skipSpace(b, from: i + 1)
                let valueStart = i
                i = valueEnd(b, from: i)
                values.append(String(decoding: UnsafeBufferPointer(rebasing: b[valueStart..<i]), as: UTF8.self))
            }
            return (keys, values)
        }
    }

    private static func skipSpace(_ b: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var i = start
        while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0D || b[i] == 0x0A { i += 1 }
        return i
    }

    /// Just past the closing quote of the string starting at `start`.
    private static func stringEnd(_ b: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var i = start + 1
        while i < b.count {
            if b[i] == 0x5C { // backslash
                i += 2
                continue
            }
            if b[i] == 0x22 { return i + 1 }
            i += 1
        }
        return b.count
    }

    /// Just past the value starting at `start`.
    private static func valueEnd(_ b: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        guard start < b.count else { return start }
        let first = b[start]
        if first == 0x22 { return stringEnd(b, from: start) }
        if first == 0x7B || first == 0x5B { // { [
            var depth = 0
            var i = start
            while i < b.count {
                switch b[i] {
                case 0x22:
                    i = stringEnd(b, from: i)
                    continue
                case 0x7B, 0x5B:
                    depth += 1
                case 0x7D, 0x5D:
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default:
                    break
                }
                i += 1
            }
            return b.count
        }
        var i = start
        while i < b.count, b[i] != 0x2C, b[i] != 0x7D, b[i] != 0x20, b[i] != 0x09, b[i] != 0x0D, b[i] != 0x0A { i += 1 }
        return i
    }

    /// The columns for JSON Lines rows: every top-level key, in the order first seen.
    public static func columns(of records: [DataRecord], limit: Int = 200) -> [String] {
        var seen = Set<String>()
        var columns: [String] = []
        for record in records {
            for key in record.keys where seen.insert(key).inserted {
                columns.append(key)
                if columns.count == limit { return columns }
            }
        }
        return columns
    }

    /// JSON Lines: each record's values of `columns`, as `value(for:)` finds them (the first of a repeated
    /// key), from one pass over its keys. `value(for:)` goes through them for every column, which on lines
    /// of thousands of keys holds up a copy of a few hundred rows for seconds.
    public static func values(of records: [DataRecord], columns: [String]) -> [[String?]] {
        var index: [String: Int] = [:]
        for (i, column) in columns.enumerated() where index[column] == nil { index[column] = i }
        let first = columns.indices.map { index[columns[$0]] ?? $0 } // a repeated column reads the first
        return records.map { record in
            var row = [String?](repeating: nil, count: columns.count)
            var left = index.count
            for (k, key) in record.keys.enumerated() where k < record.fields.count {
                guard let i = index[key], row[i] == nil else { continue }
                row[i] = record.fields[k]
                left -= 1
                if left == 0 { break }
            }
            return first.map { row[$0] }
        }
    }

    /// A CSV or TSV record's fields, all of them: split again from `raw` when it has more than it keeps.
    public static func allFields(of record: DataRecord, delimiter: UInt8) -> [String] {
        guard record.hasMoreFields else { return record.fields }
        var scanner = RecordScanner(kind: .delimited, delimiter: delimiter, start: .start, limit: 1, maxFields: .max)
        scanner.feed(Data(record.raw.utf8))
        scanner.finish()
        return scanner.records.first?.fields ?? record.fields
    }

    /// Text from bytes. A cut record can end inside a character: that half character goes.
    static func decode(_ bytes: [UInt8], truncated: Bool) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        guard truncated, text.unicodeScalars.last == "\u{FFFD}" else { return text }
        return String(text.unicodeScalars.dropLast())
    }
}

/// Splits bytes into records as they arrive, a chunk at a time, and knows where the next record starts.
struct RecordScanner {
    let kind: DataFileKind
    let delimiter: UInt8
    let limit: Int
    let maxFields: Int
    private(set) var records: [DataRecord] = []
    /// Where the record after the last one returned starts.
    private(set) var position: DataPosition
    /// Where the last record starts, when the end of the file ended it.
    private(set) var unterminated: DataPosition?

    /// The absolute offset of the next chunk.
    private var offset: UInt64
    /// The line being read.
    private var line: Int
    private var recordLine: Int
    /// The record's bytes from earlier chunks (and, for CSV, up to its last field), at most maxRecordBytes.
    private var carry: [UInt8] = []
    private var truncated = false
    private var pageBytes = 0
    /// The page ended early: it read as much as one page may.
    private var stopped = false

    // CSV and TSV
    private var fields: [String] = []
    private var field: [UInt8] = []
    private var recordBytes = 0
    private var fieldStarted = false
    private var inQuotes = false
    /// In quotes, the last byte was a quote: it closes the field unless another follows.
    private var quotePending = false
    /// The record ended with "\r": a "\n" next belongs to it.
    private var crPending = false
    /// The record ran past maxRecordBytes: skip to the end of its line.
    private var skipping = false
    private var recordError: String?
    /// Fields past maxFields were dropped.
    private var moreFields = false

    init(kind: DataFileKind, delimiter: UInt8, start: DataPosition, limit: Int, maxFields: Int = DataHead.maxFields) {
        self.kind = kind
        self.delimiter = delimiter
        self.limit = limit
        self.maxFields = maxFields
        position = start
        offset = start.offset
        line = start.line
        recordLine = start.line
    }

    var isFull: Bool { stopped || records.count >= limit || pageBytes >= DataHead.maxPageBytes }

    mutating func feed(_ chunk: Data) {
        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            if kind == .delimited { feedDelimited(bytes) } else { feedLines(bytes) }
        }
        offset += UInt64(chunk.count)
    }

    /// The end of the file: what is left is the last record.
    mutating func finish() {
        let start = position, count = records.count
        defer { if records.count > count { unterminated = start } }
        if kind != .delimited {
            if !carry.isEmpty || truncated { endLine(next: offset) }
            return
        }
        if crPending {
            crPending = false
            line += 1
            return emit(next: offset)
        }
        if quotePending {
            quotePending = false
            inQuotes = false
        }
        guard !carry.isEmpty || fieldStarted || !fields.isEmpty || inQuotes || skipping else { return }
        if inQuotes { recordError = "A quote is not closed before the end of the file." }
        endField()
        emit(next: offset)
    }

    /// Ends the page where the reading is. A record already cut at maxRecordBytes ends here too (its
    /// line goes on in the next page, under the same line number); one still being read is left for the
    /// next page, which starts where it starts.
    mutating func stop() {
        stopped = true
        if kind != .delimited {
            if truncated { endLine(next: offset, lineEnds: false) }
        } else if skipping {
            endField()
            emit(next: offset)
        }
    }

    // MARK: lines

    private mutating func feedLines(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress else { return }
        let n = bytes.count
        var i = 0
        while i < n, !isFull {
            guard let hit = memchr(base + i, 0x0A, n - i) else {
                append(UnsafeBufferPointer(rebasing: bytes[i..<n]))
                return
            }
            let j = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
            append(UnsafeBufferPointer(rebasing: bytes[i..<j]))
            endLine(next: offset + UInt64(j + 1))
            i = j + 1
        }
    }

    private mutating func endLine(next: UInt64, lineEnds: Bool = true) {
        let start = line
        if lineEnds { line += 1 }
        if !truncated, carry.last == 0x0D { carry.removeLast() }
        let blank = kind == .jsonLines && carry.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
        if !blank {
            if kind == .jsonLines {
                records.append(DataHead.jsonRecord(carry, line: start, truncated: truncated))
            } else {
                records.append(DataRecord(line: start, raw: DataHead.decode(carry, truncated: truncated), isTruncated: truncated))
            }
            pageBytes += carry.count + Self.overhead(records[records.count - 1])
        }
        carry.removeAll(keepingCapacity: true)
        truncated = false
        position = DataPosition(offset: next, line: line)
    }

    private mutating func append(_ slice: UnsafeBufferPointer<UInt8>) {
        let room = DataHead.maxRecordBytes - carry.count
        if slice.count <= room {
            carry.append(contentsOf: slice)
        } else {
            if room > 0 { carry.append(contentsOf: slice.prefix(room)) }
            truncated = true
        }
    }

    // MARK: CSV and TSV

    private mutating func feedDelimited(_ bytes: UnsafeBufferPointer<UInt8>) {
        let n = bytes.count
        var segment = 0 // where this chunk's part of the record starts
        var i = 0
        while i < n {
            let byte = bytes[i]
            if crPending {
                crPending = false
                line += 1
                if byte == 0x0A {
                    emit(next: offset + UInt64(i + 1))
                    i += 1
                    segment = i
                    if isFull { return }
                    continue
                }
                emit(next: offset + UInt64(i)) // an old Mac line ending: "\r" alone
                segment = i
                if isFull { return }
            }
            if skipping {
                guard let base = bytes.baseAddress, let hit = memchr(base + i, 0x0A, n - i) else { return }
                let j = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                line += 1
                endField()
                emit(next: offset + UInt64(j + 1))
                i = j + 1
                segment = i
                if isFull { return }
                continue
            }
            if inQuotes {
                if quotePending {
                    quotePending = false
                    if byte == 0x22 {
                        addFieldByte(0x22) // "" inside quotes is one quote
                        i += 1
                        continue
                    }
                    inQuotes = false // the quote before closed the field
                } else {
                    if byte == 0x22 {
                        quotePending = true
                    } else {
                        if byte == 0x0A { line += 1 }
                        addFieldByte(byte)
                    }
                    i += 1
                    if recordBytes > DataHead.maxRecordBytes {
                        startSkipping(bytes, from: segment, to: i)
                        segment = i
                    }
                    continue
                }
            }
            switch byte {
            case delimiter:
                endField()
            case 0x0A:
                endField()
                appendRaw(bytes, from: segment, to: i)
                line += 1
                emit(next: offset + UInt64(i + 1))
                segment = i + 1
                if isFull { return }
            case 0x0D:
                endField()
                appendRaw(bytes, from: segment, to: i)
                segment = i + 1
                crPending = true
            case 0x22 where !fieldStarted:
                inQuotes = true
                fieldStarted = true
            default:
                addFieldByte(byte)
            }
            i += 1
            if recordBytes > DataHead.maxRecordBytes {
                startSkipping(bytes, from: segment, to: i)
                segment = i
            }
        }
        if !skipping { appendRaw(bytes, from: segment, to: n) }
    }

    /// The record is too long (an unclosed quote, or no line breaks at all): keep what was read, then
    /// skip to the end of the line, ignoring quotes.
    private mutating func startSkipping(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) {
        appendRaw(bytes, from: start, to: end)
        truncated = true
        if inQuotes { recordError = "Longer than 1 MB inside quotes: a quote may not be closed." }
        inQuotes = false
        quotePending = false
        skipping = true
    }

    private mutating func addFieldByte(_ byte: UInt8) {
        recordBytes += 1
        fieldStarted = true
        if recordBytes <= DataHead.maxRecordBytes { field.append(byte) }
    }

    private mutating func endField() {
        if fields.count < maxFields {
            fields.append(String(decoding: field, as: UTF8.self))
        } else {
            moreFields = true // `raw` still has it
        }
        field.removeAll(keepingCapacity: true)
        fieldStarted = false
        recordBytes += 1
    }

    private mutating func appendRaw(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) {
        guard end > start else { return }
        append(UnsafeBufferPointer(rebasing: bytes[start..<end]))
    }

    /// What a record's fields and keys cost beyond its text, which the page limit counts too.
    private static func overhead(_ record: DataRecord) -> Int {
        record.fields.reduce(0) { $0 + cost($1) } + record.keys.reduce(0) { $0 + cost($1) }
    }

    /// A String's place in an array, and its own allocation when it has one: one over 15 UTF-8 bytes keeps
    /// them on the heap, behind a 32-byte header.
    private static func cost(_ string: String) -> Int {
        let count = string.utf8.count
        return MemoryLayout<String>.stride + (count > 15 ? count + 32 : 0)
    }

    /// Adds the record (a blank line is not one) and starts the next at `next`.
    private mutating func emit(next: UInt64) {
        let blank = carry.isEmpty && fields.count <= 1 && (fields.first?.isEmpty ?? true) && recordError == nil
        if !blank {
            var record = DataRecord(line: recordLine, raw: DataHead.decode(carry, truncated: truncated), fields: fields,
                                    error: recordError, isTruncated: truncated)
            record.hasMoreFields = moreFields
            records.append(record)
            pageBytes += carry.count + Self.overhead(record)
        }
        carry.removeAll(keepingCapacity: true)
        fields = []
        field.removeAll(keepingCapacity: true)
        recordBytes = 0
        fieldStarted = false
        inQuotes = false
        quotePending = false
        skipping = false
        truncated = false
        recordError = nil
        moreFields = false
        recordLine = line
        position = DataPosition(offset: next, line: line)
    }
}

/// Copying rows of the head view.
public enum DataExport {
    /// JSON Lines rows as JSON: the line itself for one row, an array of them for several.
    public static func jsonLines(_ raws: [String]) -> String {
        if raws.count == 1 { return raws[0] + "\n" }
        if raws.isEmpty { return "[]\n" }
        return "[\n  " + raws.joined(separator: ",\n  ") + "\n]\n"
    }

    /// Rows as JSON objects keyed by the column names. Values are text: a CSV has no types.
    public static func objects(columns: [String], rows: [[String?]]) -> String {
        TableExport.json(columns: columns, rows: rows.map(values))
    }

    /// Rows as CSV with a header line, quoted where needed.
    public static func csv(columns: [String], rows: [[String?]]) -> String {
        TableExport.csv(columns: columns, rows: rows.map(values))
    }

    /// JSON Lines rows as CSV: a column for each key, the values shown as cells show them.
    public static func csv(jsonLines records: [DataRecord]) -> String {
        let columns = DataHead.columns(of: records)
        let rows = DataHead.values(of: records, columns: columns).map { row in row.map { $0.map(DataHead.displayValue) } }
        return csv(columns: columns, rows: rows)
    }

    private static func values(_ row: [String?]) -> [SQLiteValue] {
        row.map { cell in cell.map { SQLiteValue.text($0, truncated: false) } ?? .null }
    }
}

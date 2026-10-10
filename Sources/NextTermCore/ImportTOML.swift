import Foundation

// A TOML reader for the import (Alacritty now; Rio, Helix and WezTerm colour files later): the whole of TOML 1.0's
// syntax and the 1.1 inline tables Alacritty's docs allow (over several lines, a comma at the end), read into
// values. It only reads: nothing in a file is run or looked up, and a file it can't follow is refused whole, as
// the apps themselves refuse it. Limits keep a hostile file small: its size, how deep arrays and tables go, and
// how long a dotted key is.

/// A TOML value. Dates and times are kept as written (no importer uses one).
public indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case bool(Bool)
    case datetime(String)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var string: String? { if case .string(let value) = self { return value } else { return nil } }
    public var bool: Bool? { if case .bool(let value) = self { return value } else { return nil } }
    public var array: [TOMLValue]? { if case .array(let value) = self { return value } else { return nil } }
    public var table: [String: TOMLValue]? { if case .table(let value) = self { return value } else { return nil } }

    /// An integer or a float, as a number.
    public var number: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .float(let value): return value.isFinite ? value : nil
        default: return nil
        }
    }

    /// The value at a path of table keys ("font", "normal", "family"), or nil.
    public subscript(_ path: String...) -> TOMLValue? { value(at: path) }

    public func value(at path: [String]) -> TOMLValue? {
        var current: TOMLValue = self
        for key in path {
            guard let next = current.table?[key] else { return nil }
            current = next
        }
        return current
    }
}

public struct TOMLError: Error, Equatable, Sendable {
    /// 1-based.
    public let line: Int
    public let message: String
}

public enum TOMLReader {
    /// A settings file is never near this; a bigger one isn't read.
    public static let maxBytes = 2 << 20
    /// Arrays and inline tables in one another, and tables under tables, no deeper than this.
    public static let maxDepth = 64

    /// The document's top-level table, or why it couldn't be read.
    public static func parse(_ text: String) -> Result<[String: TOMLValue], TOMLError> {
        guard text.utf8.count <= maxBytes else { return .failure(TOMLError(line: 1, message: "the file is too large")) }
        var parser = Parser(text)
        do {
            try parser.document()
            return .success(parser.root.value)
        } catch let error as TOMLError {
            return .failure(error)
        } catch {
            return .failure(TOMLError(line: parser.line, message: "not valid TOML"))
        }
    }

    // MARK: building

    /// A table while it is read: tables are shared so a header can reach one deep in the tree.
    final class Table {
        var values: [String: Node] = [:]
        /// Opened by a `[header]` (another header for it is an error).
        var headed = false
        /// Made by an inline table or a value: closed to any key added later.
        var closed = false
        let depth: Int

        init(depth: Int) { self.depth = depth }

        var value: [String: TOMLValue] {
            values.mapValues { node in
                switch node {
                case .value(let value): return value
                case .table(let table): return .table(table.value)
                case .tables(let tables): return .array(tables.map { .table($0.value) })
                }
            }
        }
    }

    enum Node {
        case value(TOMLValue)
        case table(Table)
        /// `[[array]]`.
        case tables([Table])
    }

    // MARK: parsing

    struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0
        var line = 1
        let root = Table(depth: 0)
        /// The table `key = value` lines go into.
        var current: Table

        init(_ text: String) {
            var scalars = Array(text.unicodeScalars)
            if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
            self.scalars = scalars
            current = root
        }

        var atEnd: Bool { index >= scalars.count }
        var peek: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

        func peek(_ offset: Int) -> Unicode.Scalar? {
            index + offset < scalars.count ? scalars[index + offset] : nil
        }

        func fail(_ message: String) -> TOMLError { TOMLError(line: line, message: message) }

        mutating func advance() {
            if scalars[index] == "\n" { line += 1 }
            index += 1
        }

        mutating func skipSpaces() {
            while let scalar = peek, scalar == " " || scalar == "\t" { advance() }
        }

        mutating func skipComment() {
            guard peek == "#" else { return }
            while let scalar = peek, scalar != "\n" { advance() }
        }

        /// Spaces, line breaks and comments (inside arrays and inline tables).
        mutating func skipBlank() {
            while let scalar = peek {
                if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                    advance()
                } else if scalar == "#" {
                    skipComment()
                } else {
                    return
                }
            }
        }

        /// The rest of a line after a value or a header: spaces, then a comment, then the line break.
        mutating func endOfLine() throws {
            skipSpaces()
            skipComment()
            if peek == "\r" { advance() }
            guard atEnd || peek == "\n" else { throw fail("more on the line after a value") }
            if !atEnd { advance() }
        }

        mutating func document() throws {
            while !atEnd {
                skipSpaces()
                guard let scalar = peek else { break }
                switch scalar {
                case "\n", "\r":
                    advance()
                case "#":
                    skipComment()
                case "[":
                    try header()
                default:
                    try keyValue(into: current, depth: current.depth)
                    try endOfLine()
                }
            }
        }

        // MARK: keys

        static func isBare(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", "-": return true
            default: return false
            }
        }

        /// A key, dotted or not: `a`, `"a b".c`, `'x'.y`.
        mutating func key() throws -> [String] {
            var parts: [String] = []
            while true {
                skipSpaces()
                guard let scalar = peek else { throw fail("a key was expected") }
                if scalar == "\"" {
                    parts.append(try basicString())
                } else if scalar == "'" {
                    parts.append(try literalString())
                } else if Self.isBare(scalar) {
                    var bare = ""
                    while let next = peek, Self.isBare(next) {
                        bare.unicodeScalars.append(next)
                        advance()
                    }
                    parts.append(bare)
                } else {
                    throw fail("a key was expected")
                }
                guard parts.count <= TOMLReader.maxDepth else { throw fail("a key too deep") }
                skipSpaces()
                guard peek == "." else { return parts }
                advance()
            }
        }

        /// `[table]` or `[[array of tables]]`: where the next keys go.
        mutating func header() throws {
            advance()
            let array = peek == "["
            if array { advance() }
            let path = try key()
            guard peek == "]" else { throw fail("a table header isn't closed") }
            advance()
            if array {
                guard peek == "]" else { throw fail("a table header isn't closed") }
                advance()
            }
            var table = root
            for (offset, part) in path.enumerated() {
                let last = offset == path.count - 1
                if last && array {
                    let added = Table(depth: table.depth + 1)
                    added.headed = true
                    switch table.values[part] {
                    case nil: table.values[part] = .tables([added])
                    case .tables(let tables)?: table.values[part] = .tables(tables + [added])
                    default: throw fail("\(part) is already set")
                    }
                    table = added
                } else {
                    table = try child(part, of: table, viaHeader: true)
                    if last {
                        guard !table.headed else { throw fail("the table \(part) is there twice") }
                        table.headed = true
                    }
                }
            }
            current = table
            try endOfLine()
        }

        /// The table under `table` named `part`, made if it isn't there. Through a header, an array of tables
        /// leads to its last table.
        mutating func child(_ part: String, of table: Table, viaHeader: Bool) throws -> Table {
            guard table.depth < TOMLReader.maxDepth else { throw fail("tables too deep") }
            switch table.values[part] {
            case nil:
                guard !table.closed else { throw fail("an inline table can't take more keys") }
                let made = Table(depth: table.depth + 1)
                table.values[part] = .table(made)
                return made
            case .table(let existing)?:
                guard !existing.closed else { throw fail("an inline table can't take more keys") }
                return existing
            case .tables(let tables)?:
                guard viaHeader, let last = tables.last else { throw fail("\(part) is already set") }
                return last
            case .value?:
                throw fail("\(part) is already set")
            }
        }

        /// `key = value`, into `table` (dotted keys make the tables between).
        mutating func keyValue(into table: Table, depth: Int) throws {
            let path = try key()
            skipSpaces()
            guard peek == "=" else { throw fail("= was expected after a key") }
            advance()
            skipSpaces()
            var target = table
            for part in path.dropLast() { target = try child(part, of: target, viaHeader: false) }
            guard let name = path.last else { throw fail("a key was expected") }
            guard !target.closed else { throw fail("an inline table can't take more keys") }
            guard target.values[name] == nil else { throw fail("\(name) is there twice") }
            let parsed = try value(depth: depth + path.count)
            target.values[name] = parsed
        }

        // MARK: values

        mutating func value(depth: Int) throws -> Node {
            guard depth <= TOMLReader.maxDepth else { throw fail("arrays and tables too deep") }
            guard let scalar = peek else { throw fail("a value was expected") }
            switch scalar {
            case "\"":
                if peek(1) == "\"" && peek(2) == "\"" { return .value(.string(try multilineBasicString())) }
                return .value(.string(try basicString()))
            case "'":
                if peek(1) == "'" && peek(2) == "'" { return .value(.string(try multilineLiteralString())) }
                return .value(.string(try literalString()))
            case "[":
                return .value(.array(try array(depth: depth)))
            case "{":
                return .table(try inlineTable(depth: depth))
            default:
                return .value(try bare())
            }
        }

        mutating func array(depth: Int) throws -> [TOMLValue] {
            advance()
            var items: [TOMLValue] = []
            while true {
                skipBlank()
                guard let scalar = peek else { throw fail("an array isn't closed") }
                if scalar == "]" {
                    advance()
                    return items
                }
                switch try value(depth: depth + 1) {
                case .value(let value): items.append(value)
                case .table(let table): items.append(.table(table.value))
                case .tables: throw fail("not valid TOML")
                }
                skipBlank()
                if peek == "," {
                    advance()
                } else if peek != "]" {
                    throw fail(", or ] was expected in an array")
                }
            }
        }

        /// `{ a = 1, b.c = "x" }`: closed once read, so no later key can add to it. Line breaks and a comma at
        /// the end are allowed, as TOML 1.1 allows them.
        mutating func inlineTable(depth: Int) throws -> Table {
            advance()
            let table = Table(depth: depth)
            while true {
                skipBlank()
                guard let scalar = peek else { throw fail("an inline table isn't closed") }
                if scalar == "}" {
                    advance()
                    break
                }
                try keyValue(into: table, depth: depth)
                skipBlank()
                if peek == "," {
                    advance()
                } else if peek != "}" {
                    throw fail(", or } was expected in an inline table")
                }
            }
            close(table)
            return table
        }

        func close(_ table: Table) {
            table.closed = true
            for case .table(let inner) in table.values.values { close(inner) }
        }

        // MARK: strings

        mutating func basicString() throws -> String {
            advance()
            var result = String.UnicodeScalarView()
            while let scalar = peek {
                switch scalar {
                case "\"":
                    advance()
                    return String(result)
                case "\\":
                    advance()
                    result.append(try escape())
                case "\n", "\r":
                    throw fail("a string isn't closed on its line")
                default:
                    guard isAllowed(scalar) else { throw fail("a control character in a string") }
                    result.append(scalar)
                    advance()
                }
            }
            throw fail("a string isn't closed")
        }

        mutating func literalString() throws -> String {
            advance()
            var result = String.UnicodeScalarView()
            while let scalar = peek {
                if scalar == "'" {
                    advance()
                    return String(result)
                }
                guard scalar != "\n", scalar != "\r" else { throw fail("a string isn't closed on its line") }
                guard isAllowed(scalar) else { throw fail("a control character in a string") }
                result.append(scalar)
                advance()
            }
            throw fail("a string isn't closed")
        }

        /// `"""…"""`: a line break just after the opening quotes is dropped, and a backslash at the end of a
        /// line drops the line break and the spaces after it.
        mutating func multilineBasicString() throws -> String {
            index += 3
            skipFirstLineBreak()
            var result = String.UnicodeScalarView()
            while let scalar = peek {
                if scalar == "\"" && peek(1) == "\"" && peek(2) == "\"" {
                    index += 3
                    // Up to two more quotes belong to the string.
                    for _ in 0..<2 where peek == "\"" {
                        result.append("\"")
                        index += 1
                    }
                    return String(result)
                }
                if scalar == "\\" {
                    var ahead = index + 1
                    while ahead < scalars.count, scalars[ahead] == " " || scalars[ahead] == "\t" { ahead += 1 }
                    if ahead < scalars.count, scalars[ahead] == "\n" || scalars[ahead] == "\r" {
                        index = ahead
                        while let next = peek, next == " " || next == "\t" || next == "\n" || next == "\r" { advance() }
                        continue
                    }
                    advance()
                    result.append(try escape())
                    continue
                }
                guard isAllowed(scalar) || scalar == "\n" || scalar == "\r" else { throw fail("a control character in a string") }
                result.append(scalar)
                advance()
            }
            throw fail("a string isn't closed")
        }

        mutating func multilineLiteralString() throws -> String {
            index += 3
            skipFirstLineBreak()
            var result = String.UnicodeScalarView()
            while let scalar = peek {
                if scalar == "'" && peek(1) == "'" && peek(2) == "'" {
                    index += 3
                    for _ in 0..<2 where peek == "'" {
                        result.append("'")
                        index += 1
                    }
                    return String(result)
                }
                guard isAllowed(scalar) || scalar == "\n" || scalar == "\r" else { throw fail("a control character in a string") }
                result.append(scalar)
                advance()
            }
            throw fail("a string isn't closed")
        }

        mutating func skipFirstLineBreak() {
            if peek == "\r" && peek(1) == "\n" {
                index += 1
            }
            if peek == "\n" { advance() }
        }

        func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7F)
        }

        mutating func escape() throws -> Unicode.Scalar {
            guard let scalar = peek else { throw fail("a string isn't closed") }
            advance()
            switch scalar {
            case "b": return "\u{8}"
            case "t": return "\t"
            case "n": return "\n"
            case "f": return "\u{C}"
            case "r": return "\r"
            case "e": return "\u{1B}"
            case "\"": return "\""
            case "\\": return "\\"
            case "x": return try hexScalar(2)
            case "u": return try hexScalar(4)
            case "U": return try hexScalar(8)
            default: throw fail("an escape TOML doesn't have")
            }
        }

        mutating func hexScalar(_ count: Int) throws -> Unicode.Scalar {
            var digits = ""
            for _ in 0..<count {
                guard let scalar = peek, scalar.properties.isASCIIHexDigit else { throw fail("a \\u escape needs hex digits") }
                digits.unicodeScalars.append(scalar)
                advance()
            }
            guard let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) else {
                throw fail("a \\u escape that is no character")
            }
            return scalar
        }

        // MARK: numbers, booleans, dates

        /// A value that isn't quoted or bracketed: true, false, a number, inf/nan, or a date and time.
        mutating func bare() throws -> TOMLValue {
            var token = ""
            while let scalar = peek, !Self.endsBare(scalar) {
                token.unicodeScalars.append(scalar)
                advance()
                guard token.unicodeScalars.count <= 64 else { throw fail("a value too long") }
            }
            // A date and a time may be split by a space ("1979-05-27 07:32:00").
            if Self.isDate(token), peek == " ", let next = peek(1), next.properties.numericType != nil {
                token.unicodeScalars.append(" ")
                advance()
                while let scalar = peek, !Self.endsBare(scalar) {
                    token.unicodeScalars.append(scalar)
                    advance()
                    guard token.unicodeScalars.count <= 64 else { throw fail("a value too long") }
                }
            }
            switch token {
            case "": throw fail("a value was expected")
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "inf", "+inf": return .float(.infinity)
            case "-inf": return .float(-.infinity)
            case "nan", "+nan", "-nan": return .float(.nan)
            default: break
            }
            if Self.isDate(token) || (token.count >= 5 && token.dropFirst(2).hasPrefix(":")) { return .datetime(token) }
            if let integer = try integer(token) { return .integer(integer) }
            if let float = try float(token) { return .float(float) }
            throw fail("a value TOML doesn't have")
        }

        static func endsBare(_ scalar: Unicode.Scalar) -> Bool {
            scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "," || scalar == "]"
                || scalar == "}" || scalar == "#"
        }

        static func isDate(_ token: String) -> Bool {
            let scalars = Array(token.unicodeScalars.prefix(10))
            guard scalars.count == 10 else { return false }
            for (offset, scalar) in scalars.enumerated() {
                let dash = offset == 4 || offset == 7
                if dash ? scalar != "-" : scalar.properties.numericType == nil || !scalar.isASCII { return false }
            }
            return true
        }

        /// Digits with single underscores between them, and nothing else.
        func digits(_ text: Substring, allowed: (Character) -> Bool) throws -> String? {
            guard !text.isEmpty else { return nil }
            var result = ""
            var previousUnderscore = true // no underscore first
            for character in text {
                if character == "_" {
                    guard !previousUnderscore else { throw fail("an underscore in a number must sit between digits") }
                    previousUnderscore = true
                } else {
                    guard allowed(character) else { return nil }
                    result.append(character)
                    previousUnderscore = false
                }
            }
            guard !previousUnderscore else { throw fail("an underscore in a number must sit between digits") }
            return result
        }

        func integer(_ token: String) throws -> Int64? {
            for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where token.hasPrefix(prefix) {
                let body = token.dropFirst(2)
                guard let clean = try digits(body, allowed: { $0.isASCII && $0.isHexDigit }) else { return nil }
                guard let value = Int64(clean, radix: radix) else { throw fail("a number out of range") }
                return value
            }
            var body = Substring(token)
            var negative = false
            if let sign = body.first, sign == "+" || sign == "-" {
                negative = sign == "-"
                body = body.dropFirst()
            }
            guard let clean = try digits(body, allowed: { $0.isASCII && $0.isNumber }) else { return nil }
            guard clean == "0" || !clean.hasPrefix("0") else { throw fail("a number with a leading zero") }
            guard let value = Int64((negative ? "-" : "") + clean) else { throw fail("a number out of range") }
            return value
        }

        func float(_ token: String) throws -> Double? {
            let allowed = { (character: Character) in
                character.isASCII && (character.isNumber || character == "." || character == "e" || character == "E"
                    || character == "+" || character == "-")
            }
            guard let clean = try digits(Substring(token), allowed: allowed) else { return nil }
            guard clean.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) else { return nil }
            // TOML wants digits on both sides of a point.
            if let point = clean.firstIndex(of: ".") {
                let before = clean[..<point].last, after = clean[clean.index(after: point)...].first
                guard before?.isNumber == true, after?.isNumber == true else { throw fail("a number with a point needs digits on both sides") }
            }
            guard let value = Double(clean), value.isFinite else { throw fail("a number out of range") }
            return value
        }
    }
}

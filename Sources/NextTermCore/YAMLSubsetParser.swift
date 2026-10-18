import Foundation

// The import's YAML reader, its block structure: lines, documents, mappings and sequences by their indentation. Scalars
// and flow collections are in YAMLSubsetScalars.swift.

extension YAMLSubset {
    static let nulls: Set<String> = ["", "~", "null", "Null", "NULL"]
    /// YAML 1.1's booleans, which config files still write (https://yaml.org/type/bool.html).
    static let booleans: Set<String> = ["y", "Y", "yes", "Yes", "YES", "n", "N", "no", "No", "NO", "true", "True", "TRUE",
                                        "false", "False", "FALSE", "on", "On", "ON", "off", "Off", "OFF"]
    static let number = try! NSRegularExpression(pattern: [
        #"^[-+]?(?:[0-9][0-9_]*(?:\.[0-9_]*)?|\.[0-9][0-9_]*)(?:[eE][-+]?[0-9]+)?$"#,
        #"^0x[0-9a-fA-F_]+$"#, #"^0o[0-7_]+$"#, #"^0b[01_]+$"#, #"^[-+]?\.(?:inf|Inf|INF)$"#, #"^\.(?:nan|NaN|NAN)$"#,
    ].joined(separator: "|"))

    /// What a plain scalar is, by YAML 1.1's and 1.2's rules together.
    static func kind(ofPlain text: String) -> Kind {
        if nulls.contains(text) { return .null }
        if booleans.contains(text) { return .boolean }
        let range = NSRange(text.startIndex..., in: text)
        return number.firstMatch(in: text, range: range) != nil ? .number : .string
    }

    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    static let hash = UInt8(ascii: "#")
    static let colon = UInt8(ascii: ":")
    static let dash = UInt8(ascii: "-")

    static func isBlank(_ byte: UInt8) -> Bool { byte == space || byte == tab }

    /// One line of the file: where it begins, where its content starts past the indentation, and where it ends before
    /// its line break. A line read after a sequence's `- ` starts where the item does.
    /// Its places are kept in 32 bits: a file of blank lines makes one for each byte.
    struct Line {
        private let begin32: Int32
        private var start32: Int32
        private let end32: Int32
        private var indent32: Int32
        private let number32: Int32
        /// A tab comes before its content, which isn't a comment.
        let tabbed: Bool

        init(begin: Int, start: Int, end: Int, indent: Int, number: Int, tabbed: Bool) {
            begin32 = Int32(begin)
            start32 = Int32(start)
            end32 = Int32(end)
            indent32 = Int32(indent)
            number32 = Int32(number)
            self.tabbed = tabbed
        }

        var begin: Int { Int(begin32) }
        var start: Int {
            get { Int(start32) }
            set { start32 = Int32(newValue) }
        }
        var end: Int { Int(end32) }
        /// The spaces before its content: its column for an item after `- `.
        var indent: Int {
            get { Int(indent32) }
            set { indent32 = Int32(newValue) }
        }
        var number: Int { Int(number32) }
        var isBlank: Bool { start32 == end32 }
    }
}

// MARK: - Lines and documents

extension YAMLSubset {
    struct Parser {
        let bytes: [UInt8]
        var lines: [Line] = []
        /// The line being read, and the end of the document's lines.
        var index = 0
        var limit = 0
        var nodes = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            var begin = 0
            while true {
                var end: Int = begin
                while end < bytes.count, bytes[end] != UInt8(ascii: "\n") { end += 1 }
                let stop: Int = end > begin && bytes[end - 1] == UInt8(ascii: "\r") ? end - 1 : end
                lines.append(Self.line(bytes, begin: begin, end: stop, number: lines.count + 1))
                guard end < bytes.count else { break }
                begin = end + 1
            }
        }

        static func line(_ bytes: [UInt8], begin: Int, end: Int, number: Int) -> Line {
            var spaces: Int = begin
            while spaces < end, bytes[spaces] == YAMLSubset.space { spaces += 1 }
            var start: Int = spaces
            while start < end, YAMLSubset.isBlank(bytes[start]) { start += 1 }
            let tabbed: Bool = start > spaces && start < end && bytes[start] != YAMLSubset.hash
            return Line(begin: begin, start: start, end: end, indent: spaces - begin, number: number, tabbed: tabbed)
        }

        func fail(_ reason: Reason, _ line: Int) -> Failure { Failure(line: line, reason: reason) }

        mutating func count(_ line: Int) throws {
            nodes += 1
            if nodes > YAMLSubset.maxNodes { throw fail(.tooMany, line) }
        }

        /// A `---` or `...` at the start of a line, alone or before a blank.
        func isMarker(_ line: Line, _ byte: UInt8) -> Bool {
            guard line.indent == 0, line.start == line.begin, line.end - line.start >= 3 else { return false }
            let three: Bool = (0..<3).allSatisfy { (offset: Int) -> Bool in bytes[line.start + offset] == byte }
            return three && (line.end == line.start + 3 || YAMLSubset.isBlank(bytes[line.start + 3]))
        }

        mutating func documents() throws -> [Node] {
            var result: [Node] = []
            var from = 0
            for number in lines.indices {
                let line: Line = lines[number]
                if isMarker(line, UInt8(ascii: "-")) {
                    try document(from: from, to: number, into: &result)
                    var rest: Int = line.start + 3
                    while rest < line.end, YAMLSubset.isBlank(bytes[rest]) { rest += 1 }
                    // `--- value`: the document starts on the marker's line, where the value does.
                    if rest < line.end, bytes[rest] != YAMLSubset.hash {
                        lines[number].start = rest
                        lines[number].indent = rest - line.begin
                        from = number
                    } else {
                        from = number + 1
                    }
                } else if isMarker(line, UInt8(ascii: ".")) {
                    try document(from: from, to: number, into: &result)
                    from = number + 1
                }
            }
            try document(from: from, to: lines.count, into: &result)
            return result
        }

        /// The document on lines `from..<to`, when it has something on it. A line left over fits nowhere.
        mutating func document(from: Int, to: Int, into result: inout [Node]) throws {
            index = from
            limit = to
            guard let first = try nextSignificant() else { return }
            let node: Node = try block(at: lines[first].indent, parent: -1, depth: 0)
            if let stray = try nextSignificant() { throw fail(.indentation, lines[stray].number) }
            result.append(node)
        }

        /// The next line with something on it, from `index` on: past blank lines, comments and directives. `index` is
        /// set to it; nil at the document's end.
        mutating func nextSignificant() throws -> Int? {
            while index < limit {
                let line: Line = lines[index]
                let directive: Bool = !line.isBlank && line.start == line.begin && bytes[line.start] == UInt8(ascii: "%")
                if line.isBlank || bytes[line.start] == YAMLSubset.hash || directive {
                    index += 1
                    continue
                }
                if line.tabbed { throw fail(.tabIndent, line.number) }
                return index
            }
            return nil
        }
    }
}

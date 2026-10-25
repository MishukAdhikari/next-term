import Foundation

// The import's YAML reader: block mappings and sequences, each at its indentation.

extension YAMLSubset.Parser {
    typealias Node = YAMLSubset.Node
    typealias Line = YAMLSubset.Line

    /// The node that starts on the current line at `indent`: a sequence, a mapping, or a value whose continuation lines
    /// are more indented than `parent`.
    mutating func block(at indent: Int, parent: Int, depth: Int) throws -> Node {
        let line: Line = lines[index]
        guard depth <= YAMLSubset.maxDepth else { throw fail(.tooDeep, line.number) }
        if isDash(line) { return try sequence(at: indent, depth: depth) }
        if try mappingKey(line) != nil { return try mapping(at: indent, depth: depth) }
        return try value(from: line.start, parent: parent, depth: depth)
    }

    /// `-` alone or before a blank.
    func isDash(_ line: Line) -> Bool {
        guard !line.isBlank, bytes[line.start] == YAMLSubset.dash else { return false }
        return line.start + 1 == line.end || YAMLSubset.isBlank(bytes[line.start + 1])
    }

    func skipBlanks(_ from: Int, end: Int) -> Int {
        var at: Int = from
        while at < end, YAMLSubset.isBlank(bytes[at]) { at += 1 }
        return at
    }

    /// Nothing but a comment from `from` on.
    func isDone(_ from: Int, end: Int) -> Bool {
        let at: Int = skipBlanks(from, end: end)
        return at >= end || bytes[at] == YAMLSubset.hash
    }

    /// The key a line starts with, and where its value starts past the `:` and blanks; nil when the line isn't
    /// `key: …`. A `? ` key is refused.
    func mappingKey(_ line: Line) throws -> (key: String, value: Int)? {
        guard !line.isBlank else { return nil }
        let first: UInt8 = bytes[line.start]
        let next: UInt8? = line.start + 1 < line.end ? bytes[line.start + 1] : nil
        if first == UInt8(ascii: "?"), next.map(YAMLSubset.isBlank) ?? true { throw fail(.complexKey, line.number) }
        if first == UInt8(ascii: "\"") || first == UInt8(ascii: "'") {
            guard let quoted = try quotedOnLine(at: line.start, end: line.end, number: line.number) else { return nil }
            let at: Int = skipBlanks(quoted.after, end: line.end)
            guard at < line.end, bytes[at] == YAMLSubset.colon else { return nil }
            guard at + 1 == line.end || YAMLSubset.isBlank(bytes[at + 1]) else { return nil }
            return (quoted.text, skipBlanks(at + 1, end: line.end))
        }
        if "[{&*!|>#%@`".utf8.contains(first) { return nil }
        var at: Int = line.start
        while at < line.end {
            let byte: UInt8 = bytes[at]
            if byte == YAMLSubset.hash, at > line.start, YAMLSubset.isBlank(bytes[at - 1]) { return nil }
            if byte == YAMLSubset.colon, at + 1 == line.end || YAMLSubset.isBlank(bytes[at + 1]) {
                let key: String = text(line.start, trimmedEnd(line.start, at))
                return key.isEmpty ? nil : (key, skipBlanks(at + 1, end: line.end))
            }
            at += 1
        }
        return nil
    }

    func trimmedEnd(_ start: Int, _ end: Int) -> Int {
        var stop: Int = end
        while stop > start, YAMLSubset.isBlank(bytes[stop - 1]) { stop -= 1 }
        return stop
    }

    func text(_ start: Int, _ end: Int) -> String {
        String(decoding: bytes[start..<max(start, end)], as: UTF8.self)
    }

    /// The pairs at `indent`, from the current line on.
    mutating func mapping(at indent: Int, depth: Int) throws -> Node {
        var pairs: [YAMLSubset.Pair] = []
        try count(lines[index].number)
        while let at = try nextSignificant() {
            let line: Line = lines[at]
            guard line.indent == indent else {
                if line.indent > indent { throw fail(.indentation, line.number) }
                break
            }
            guard let (key, start) = try mappingKey(line) else { throw fail(.indentation, line.number) }
            let value: Node
            if isDone(start, end: line.end) {
                index = at + 1
                value = try nested(below: indent, line: line.number, depth: depth + 1, inMapping: true)
            } else {
                value = try self.value(from: start, parent: indent, depth: depth + 1)
            }
            pairs.append(YAMLSubset.Pair(key: key, line: line.number, value: value))
        }
        return .mapping(pairs)
    }

    /// The items at `indent`, from the current line on. An item that starts on its dash's line is read from where it
    /// starts, as a line of its own at that column.
    mutating func sequence(at indent: Int, depth: Int) throws -> Node {
        var items: [Node] = []
        try count(lines[index].number)
        while let at = try nextSignificant() {
            let line: Line = lines[at]
            guard line.indent == indent, isDash(line) else {
                if line.indent > indent { throw fail(.indentation, line.number) }
                break
            }
            guard depth < YAMLSubset.maxDepth else { throw fail(.tooDeep, line.number) }
            let rest: Int = skipBlanks(line.start + 1, end: line.end)
            if isDone(rest, end: line.end) {
                index = at + 1
                items.append(try nested(below: indent, line: line.number, depth: depth + 1, inMapping: false))
            } else {
                lines[at].start = rest
                lines[at].indent = rest - line.begin
                items.append(try block(at: rest - line.begin, parent: indent, depth: depth + 1))
            }
        }
        return .sequence(items)
    }

    /// The value on the lines after a key or a dash with nothing after it: a node more indented than `parent`, or, for
    /// a key, a sequence at the key's own indent. Null when there is none.
    mutating func nested(below parent: Int, line number: Int, depth: Int, inMapping: Bool) throws -> Node {
        guard let at = try nextSignificant() else { return try null(number) }
        let line: Line = lines[at]
        if line.indent > parent { return try block(at: line.indent, parent: parent, depth: depth) }
        if inMapping, line.indent == parent, isDash(line) { return try sequence(at: parent, depth: depth) }
        return try null(number)
    }

    mutating func null(_ number: Int) throws -> Node {
        try count(number)
        return .scalar(YAMLSubset.Scalar(text: "", style: .plain, line: number))
    }
}

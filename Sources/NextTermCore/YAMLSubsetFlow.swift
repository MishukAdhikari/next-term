import Foundation

// The import's YAML reader: flow collections (`[a, b]`, `{k: v}`) that close on their line. One that goes on past its
// line is a part to skip.

extension YAMLSubset.Parser {
    static let flowEnds: [UInt8] = Array(",]}".utf8)

    /// A flow collection from `start`; a part to skip when it doesn't close on its line.
    mutating func flow(from start: Int, parent: Int, depth: Int) throws -> Node {
        let line: Line = lines[index]
        var at: Int = start
        guard let node = try flowNode(&at, end: line.end, number: line.number, depth: depth) else {
            try count(line.number)
            return skip(.flow, parent: parent)
        }
        guard isDone(at, end: line.end) else { throw fail(.unexpected, line.number) }
        index += 1
        return node
    }

    /// The flow node at `at`, which ends past it; nil when the line ends (or a comment starts) first.
    mutating func flowNode(_ at: inout Int, end: Int, number: Int, depth: Int) throws -> Node? {
        guard depth <= YAMLSubset.maxDepth else { throw fail(.tooDeep, number) }
        at = skipBlanks(at, end: end)
        guard at < end else { return nil }
        let byte: UInt8 = bytes[at]
        switch byte {
        case UInt8(ascii: "["):
            return try flowSequence(&at, end: end, number: number, depth: depth)
        case UInt8(ascii: "{"):
            return try flowMapping(&at, end: end, number: number, depth: depth)
        case UInt8(ascii: "\""), UInt8(ascii: "'"):
            guard let quoted = try quotedOnLine(at: at, end: end, number: number) else { return nil }
            at = quoted.after
            try count(number)
            let style: YAMLSubset.Style = byte == UInt8(ascii: "'") ? .singleQuoted : .doubleQuoted
            return .scalar(YAMLSubset.Scalar(text: quoted.text, style: style, line: number))
        case UInt8(ascii: "*"):
            at = flowTokenEnd(at, end: end)
            try count(number)
            return .skipped(.alias, line: number)
        case UInt8(ascii: "!"), UInt8(ascii: "&"):
            return try flowProperties(&at, end: end, number: number, depth: depth)
        default:
            return try flowPlain(&at, end: end, number: number)
        }
    }

    /// Where an anchor's, a tag's or an alias's name ends: at a blank, a `,` or a closing bracket.
    func flowTokenEnd(_ from: Int, end: Int) -> Int {
        var at: Int = from
        while at < end, !YAMLSubset.isBlank(bytes[at]), !Self.flowEnds.contains(bytes[at]) { at += 1 }
        return at
    }

    /// Anchors and tags at `at`, as many as are written, then the node they are on: an anchor only names it, and a tag
    /// makes it a part to skip. Read in a loop, so a run of them costs no stack. Nil when the line ends first.
    mutating func flowProperties(_ at: inout Int, end: Int, number: Int, depth: Int) throws -> Node? {
        var tagged = false
        while at < end, bytes[at] == UInt8(ascii: "&") || bytes[at] == UInt8(ascii: "!") {
            if bytes[at] == UInt8(ascii: "!") { tagged = true }
            at = skipBlanks(flowTokenEnd(at, end: end), end: end)
        }
        guard let node = try flowNode(&at, end: end, number: number, depth: depth) else { return nil }
        guard tagged else { return node }
        try count(number)
        return .skipped(.tag, line: number)
    }

    /// A plain scalar in a flow collection: up to a `,`, a bracket, or a `:` before a blank; empty where none starts.
    /// Nil when a comment starts first.
    mutating func flowPlain(_ at: inout Int, end: Int, number: Int) throws -> Node? {
        let start: Int = at
        while at < end {
            let byte: UInt8 = bytes[at]
            if Self.flowEnds.contains(byte) || byte == UInt8(ascii: "[") || byte == UInt8(ascii: "{") { break }
            if byte == YAMLSubset.colon {
                let next: UInt8? = at + 1 < end ? bytes[at + 1] : nil
                if next.map({ (after: UInt8) -> Bool in YAMLSubset.isBlank(after) || Self.flowEnds.contains(after) })
                    ?? true { break }
            }
            if byte == YAMLSubset.hash, at > start, YAMLSubset.isBlank(bytes[at - 1]) { return nil }
            at += 1
        }
        try count(number)
        return .scalar(YAMLSubset.Scalar(text: text(start, trimmedEnd(start, at)), style: .plain, line: number))
    }

    /// `[…]` from `at`. An item `key: value` is a mapping of one pair.
    mutating func flowSequence(_ at: inout Int, end: Int, number: Int, depth: Int) throws -> Node? {
        try count(number)
        at += 1
        var items: [Node] = []
        while true {
            at = skipBlanks(at, end: end)
            guard at < end else { return nil }
            if bytes[at] == UInt8(ascii: "]") {
                at += 1
                return .sequence(items)
            }
            guard var item = try flowNode(&at, end: end, number: number, depth: depth + 1) else { return nil }
            at = skipBlanks(at, end: end)
            if at < end, bytes[at] == YAMLSubset.colon, let key = item.scalar?.text {
                at += 1
                guard let value = try flowNode(&at, end: end, number: number, depth: depth + 1) else { return nil }
                item = .mapping([YAMLSubset.Pair(key: key, line: number, value: value)])
                at = skipBlanks(at, end: end)
            }
            items.append(item)
            guard at < end else { return nil }
            guard bytes[at] != UInt8(ascii: ",") else {
                at += 1
                continue
            }
            guard bytes[at] == UInt8(ascii: "]") else { throw fail(.unexpected, number) }
        }
    }

    /// `{…}` from `at`. A key with no value is null.
    mutating func flowMapping(_ at: inout Int, end: Int, number: Int, depth: Int) throws -> Node? {
        try count(number)
        at += 1
        var pairs: [YAMLSubset.Pair] = []
        while true {
            at = skipBlanks(at, end: end)
            guard at < end else { return nil }
            if bytes[at] == UInt8(ascii: "}") {
                at += 1
                return .mapping(pairs)
            }
            guard let keyNode = try flowNode(&at, end: end, number: number, depth: depth + 1) else { return nil }
            guard let key = keyNode.scalar?.text else { throw fail(.complexKey, number) }
            // A key is a pair's, as in a block mapping: not a node of its own.
            nodes -= 1
            at = skipBlanks(at, end: end)
            var value: Node = .scalar(YAMLSubset.Scalar(text: "", style: .plain, line: number))
            if at < end, bytes[at] == YAMLSubset.colon {
                at += 1
                guard let read = try flowNode(&at, end: end, number: number, depth: depth + 1) else { return nil }
                value = read
                at = skipBlanks(at, end: end)
            }
            pairs.append(YAMLSubset.Pair(key: key, line: number, value: value))
            guard at < end else { return nil }
            guard bytes[at] != UInt8(ascii: ",") else {
                at += 1
                continue
            }
            guard bytes[at] == UInt8(ascii: "}") else { throw fail(.unexpected, number) }
        }
    }
}

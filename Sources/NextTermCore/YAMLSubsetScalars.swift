import Foundation

// The import's YAML reader: a value where it starts (after a key's `:` or a dash, or on a line of its own), as a plain,
// quoted or block scalar, a flow collection, or a part to skip.

extension YAMLSubset.Parser {
    /// The value that starts at `start` on the current line, and the lines after it that belong to it, which are more
    /// indented than `parent`. Leaves `index` past them.
    mutating func value(from start: Int, parent: Int, depth: Int) throws -> Node {
        let line: Line = lines[index]
        guard depth <= YAMLSubset.maxDepth else { throw fail(.tooDeep, line.number) }
        var at: Int = start
        // An anchor only names the node: read past it, to the node.
        if bytes[at] == UInt8(ascii: "&") {
            while at < line.end, !YAMLSubset.isBlank(bytes[at]) { at += 1 }
            if isDone(at, end: line.end) {
                index += 1
                return try nested(below: parent, line: line.number, depth: depth, inMapping: true)
            }
            at = skipBlanks(at, end: line.end)
        }
        let byte: UInt8 = bytes[at]
        if byte == UInt8(ascii: "[") || byte == UInt8(ascii: "{") {
            return try flow(from: at, parent: parent, depth: depth)
        }
        try count(line.number)
        switch byte {
        case UInt8(ascii: "*"): return skip(.alias, parent: parent)
        case UInt8(ascii: "!"): return skip(.tag, parent: parent)
        case UInt8(ascii: "|"), UInt8(ascii: ">"): return try blockScalar(from: at, parent: parent)
        case UInt8(ascii: "\""), UInt8(ascii: "'"): return try quoted(from: at)
        default: return plain(from: at, parent: parent)
        }
    }

    /// A part not followed: its line, and the lines after it more indented than `parent`, are passed over.
    mutating func skip(_ part: YAMLSubset.Part, parent: Int) -> Node {
        let number: Int = lines[index].number
        index += 1
        var probe: Int = index
        while probe < limit {
            let line: Line = lines[probe]
            probe += 1
            if line.isBlank || bytes[line.start] == YAMLSubset.hash { continue }
            guard line.indent > parent else { break }
            index = probe
        }
        return .skipped(part, line: number)
    }

    /// A plain scalar: the rest of the line before a comment, then the lines after it more indented than `parent`,
    /// folded as YAML folds them (a line break is a space, each blank line a break). A comment line ends it.
    mutating func plain(from start: Int, parent: Int) -> Node {
        let line: Line = lines[index]
        var text: String = self.text(start, plainEnd(start, end: line.end))
        index += 1
        var breaks = 0
        var probe: Int = index
        while probe < limit {
            let next: Line = lines[probe]
            if next.isBlank {
                breaks += 1
                probe += 1
                continue
            }
            guard next.indent > parent, bytes[next.start] != YAMLSubset.hash else { break }
            text += breaks > 0 ? String(repeating: "\n", count: breaks) : " "
            text += self.text(next.start, plainEnd(next.start, end: next.end))
            breaks = 0
            probe += 1
            index = probe
        }
        return .scalar(YAMLSubset.Scalar(text: text, style: .plain, line: line.number))
    }

    /// Where a plain scalar's text ends on its line: before a ` #` comment, without the blanks before it.
    func plainEnd(_ start: Int, end: Int) -> Int {
        var at: Int = start
        while at < end {
            if bytes[at] == YAMLSubset.hash, at > start, YAMLSubset.isBlank(bytes[at - 1]) { break }
            at += 1
        }
        return trimmedEnd(start, at)
    }

    /// A quoted scalar from `start`, over as many lines as it takes: each line break folded to a space, each blank line
    /// a break, as YAML folds them. Nothing but a comment may follow its closing quote.
    mutating func quoted(from start: Int) throws -> Node {
        let first: Line = lines[index]
        let style: YAMLSubset.Style = bytes[start] == UInt8(ascii: "'") ? .singleQuoted : .doubleQuoted
        var out: [UInt8] = []
        defer { SecretBytes.wipe(&out) }
        var at: Int = start + 1
        var line: Line = first
        while true {
            switch try readQuoted(bytes[start], from: &at, end: line.end, into: &out, number: line.number) {
            case .closed:
                guard isDone(at, end: line.end) else { throw fail(.unexpected, line.number) }
                index += 1
                return .scalar(YAMLSubset.Scalar(text: String(decoding: out, as: UTF8.self), style: style,
                                                 line: first.number))
            case .lineEnded(let escaped):
                if !escaped {
                    while let last = out.last, YAMLSubset.isBlank(last) { out.removeLast() }
                }
                index += 1
                var breaks = 0
                while index < limit, lines[index].isBlank {
                    breaks += 1
                    index += 1
                }
                guard index < limit else { throw fail(.unclosedQuote, first.number) }
                if !escaped {
                    let folds: [UInt8] = Array(repeating: UInt8(ascii: "\n"), count: breaks)
                    out += breaks > 0 ? folds : [YAMLSubset.space]
                }
                line = lines[index]
                at = line.start
            }
        }
    }

    enum QuotedEnd {
        case closed
        /// The line ended first; `escaped` when it ended in a `\`, which joins the next line with nothing between.
        case lineEnded(escaped: Bool)
    }

    /// The quoted text on one line from `at`, up to its closing `quote`, decoded into `out`; `at` ends past the quote.
    func readQuoted(_ quote: UInt8, from at: inout Int, end: Int, into out: inout [UInt8],
                    number: Int) throws -> QuotedEnd {
        let single: Bool = quote == UInt8(ascii: "'")
        while at < end {
            let byte: UInt8 = bytes[at]
            if byte == quote {
                if single, at + 1 < end, bytes[at + 1] == quote {
                    out.append(quote)
                    at += 2
                    continue
                }
                at += 1
                return .closed
            }
            if !single, byte == UInt8(ascii: "\\") {
                if at + 1 == end {
                    at = end
                    return .lineEnded(escaped: true)
                }
                try escape(&at, into: &out, number: number)
                continue
            }
            out.append(byte)
            at += 1
        }
        return .lineEnded(escaped: false)
    }

    /// A quoted scalar that closes on its line (a key, or in a flow collection): its text and where it ends; nil when
    /// it goes on past the line.
    func quotedOnLine(at start: Int, end: Int, number: Int) throws -> (text: String, after: Int)? {
        var out: [UInt8] = []
        defer { SecretBytes.wipe(&out) }
        var at: Int = start + 1
        guard case .closed = try readQuoted(bytes[start], from: &at, end: end, into: &out, number: number) else {
            return nil
        }
        return (String(decoding: out, as: UTF8.self), at)
    }
}

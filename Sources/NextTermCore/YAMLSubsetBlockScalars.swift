import Foundation

// The import's YAML reader: a double-quoted scalar's escapes, and literal and folded blocks.

extension YAMLSubset.Parser {
    /// The escapes that stand for one byte.
    static let simpleEscapes: [UInt8: UInt8] = {
        let pairs: [(Character, UInt8)] = [("0", 0), ("a", 7), ("b", 8), ("t", 9), ("\t", 9), ("n", 10), ("v", 11),
                                           ("f", 12), ("r", 13), ("e", 27), (" ", 32), ("\"", 34), ("/", 47), ("\\", 92)]
        var table: [UInt8: UInt8] = [:]
        for (character, byte) in pairs { table[character.asciiValue ?? 0] = byte }
        return table
    }()

    /// The escape at `at` (a `\`), decoded into `out`; `at` ends past it.
    func escape(_ at: inout Int, into out: inout [UInt8], number: Int) throws {
        let code: UInt8 = bytes[at + 1]
        at += 2
        if let byte = Self.simpleEscapes[code] {
            out.append(byte)
            return
        }
        let value: UInt32
        switch code {
        case UInt8(ascii: "N"): value = 0x85
        case UInt8(ascii: "_"): value = 0xA0
        case UInt8(ascii: "L"): value = 0x2028
        case UInt8(ascii: "P"): value = 0x2029
        case UInt8(ascii: "x"), UInt8(ascii: "u"), UInt8(ascii: "U"):
            let digits: Int = code == UInt8(ascii: "x") ? 2 : (code == UInt8(ascii: "u") ? 4 : 8)
            guard at + digits <= bytes.count else { throw fail(.badEscape, number) }
            let hex: String = String(decoding: bytes[at..<(at + digits)], as: UTF8.self)
            guard hex.allSatisfy(\.isHexDigit), let parsed = UInt32(hex, radix: 16) else { throw fail(.badEscape, number) }
            value = parsed
            at += digits
        default:
            throw fail(.badEscape, number)
        }
        guard let scalar = Unicode.Scalar(value) else { throw fail(.badEscape, number) }
        out += Array(String(Character(scalar)).utf8)
    }

    /// A literal (`|`) or folded (`>`) block: its header's chomping (`-` strips the last line break, `+` keeps every
    /// one) and indentation number, then the lines indented past `parent`.
    mutating func blockScalar(from start: Int, parent: Int) throws -> Node {
        let line: Line = lines[index]
        let folded: Bool = bytes[start] == UInt8(ascii: ">")
        var keep: Bool?
        var explicit: Int?
        var at: Int = start + 1
        while at < line.end, !YAMLSubset.isBlank(bytes[at]) {
            let byte: UInt8 = bytes[at]
            if byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") {
                keep = byte == UInt8(ascii: "+")
            } else if byte >= UInt8(ascii: "1"), byte <= UInt8(ascii: "9") {
                explicit = Int(byte - UInt8(ascii: "0"))
            } else {
                throw fail(.unexpected, line.number)
            }
            at += 1
        }
        guard isDone(at, end: line.end) else { throw fail(.unexpected, line.number) }
        index += 1
        var probe: Int = index
        while probe < limit, lines[probe].isBlank { probe += 1 }
        let found: Int = probe < limit ? lines[probe].indent : 0
        let indent: Int = explicit.map { (number: Int) -> Int in max(parent, 0) + number } ?? found
        var pieces: [Range<Int>?] = []
        while index < limit {
            let next: Line = lines[index]
            if next.isBlank {
                pieces.append(nil)
            } else {
                guard indent > parent, next.indent >= indent else { break }
                pieces.append((next.begin + indent)..<next.end)
            }
            index += 1
        }
        var out: [UInt8] = joined(pieces, folded: folded)
        defer { SecretBytes.wipe(&out) }
        let last: Int = (pieces.lastIndex { (piece: Range<Int>?) -> Bool in piece != nil } ?? -1) + 1
        let content: Int = last > 0 ? 1 : 0
        if keep == nil, content == 1 { out.append(UInt8(ascii: "\n")) }
        if keep == true { out += Array(repeating: UInt8(ascii: "\n"), count: content + pieces.count - last) }
        return .scalar(YAMLSubset.Scalar(text: String(decoding: out, as: UTF8.self), style: folded ? .folded : .literal,
                                         line: line.number))
    }

    /// A block's lines up to its last one with something on it: joined by line breaks, or folded, where two lines with
    /// nothing between them are one line, and a blank line or a more indented line keeps its break.
    func joined(_ pieces: [Range<Int>?], folded: Bool) -> [UInt8] {
        var out: [UInt8] = []
        var breaks = 0
        var started = false
        var lastIndented = false
        for piece in pieces {
            guard let piece else {
                breaks += 1
                continue
            }
            let indented: Bool = !piece.isEmpty && YAMLSubset.isBlank(bytes[piece.lowerBound])
            if !started {
                out += Array(repeating: UInt8(ascii: "\n"), count: breaks)
            } else if !folded || indented || lastIndented {
                out += Array(repeating: UInt8(ascii: "\n"), count: breaks + 1)
            } else {
                out += breaks > 0 ? Array(repeating: UInt8(ascii: "\n"), count: breaks) : [YAMLSubset.space]
            }
            out += bytes[piece]
            started = true
            breaks = 0
            lastIndented = indented
        }
        return out
    }
}

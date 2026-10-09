import Foundation

/// A JSON text read as written: where each value and member sits (UTF-8 byte offsets into the text),
/// each object's keys decoded, and why a text is not plain JSON. The skills review uses it to trust an
/// agent's JSON file only when every reader takes it the same way (Claude Code keeps the last of two
/// equal keys, Foundation may not), and to read Claude Code's settings as Claude Code reads them. It
/// never writes. Strict JSON (RFC 8259) only: no comments, no trailing commas.
public enum SkillJSONText {
    public enum Problem: String, Error, Equatable, Sendable {
        /// Nothing but spaces.
        case empty
        /// `//` or `/* */` outside a string.
        case comment
        /// A comma right before `}` or `]`.
        case trailingComma
        /// Anything else that is not JSON, nesting deeper than `maxDepth` included.
        case notJSON

        /// Why, in plain words, for the review.
        public var reason: String {
            switch self {
            case .empty: return "it is empty"
            case .comment: return "it has comments"
            case .trailingComma: return "it has a trailing comma"
            case .notJSON: return "it is not valid JSON"
            }
        }
    }

    public struct Node: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case object, array, string, number, bool, null }
        public let kind: Kind
        /// Where the value is in the text, as UTF-8 byte offsets.
        public let range: Range<Int>
        /// An object's members, in order.
        public var members: [Member] = []
        /// An array's items, in order.
        public var items: [Node] = []
        /// A string's value, decoded.
        public var string: String?

        /// The members with this key (two or more: the key is there twice).
        public func member(_ key: String) -> [Member] {
            members.filter { SkillJSONText.same($0.key, key) }
        }
    }

    public struct Member: Equatable, Sendable {
        /// The key, decoded.
        public let key: String
        /// The key as written, quotes included.
        public let keyRange: Range<Int>
        public let value: Node
    }

    /// Deeper nesting is refused: no settings or manifest file needs it.
    public static let maxDepth = 128

    public static func parse(_ data: Data) -> Result<Node, Problem> {
        var scanner = Scanner(bytes: [UInt8](data))
        do {
            return .success(try scanner.document())
        } catch let problem as Problem {
            return .failure(problem)
        } catch {
            return .failure(.notJSON)
        }
    }

    /// A key that appears twice in one object, anywhere in the value.
    public static func duplicateKey(in node: Node) -> String? {
        var pending = [node]
        while let next = pending.popLast() {
            var seen = Set<[UInt32]>()
            for member in next.members where !seen.insert(member.key.unicodeScalars.map(\.value)).inserted { return member.key }
            pending += next.members.map(\.value)
            pending += next.items
        }
        return nil
    }

    /// Keys compare as JSON compares them: scalar by scalar (Swift's `==` would join look-alike forms).
    static func same(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    struct Scanner {
        let bytes: [UInt8]
        var at = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            // A UTF-8 byte order mark is skipped, and offsets still count it.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { at = 3 }
        }

        /// An object or array being read.
        struct Open {
            let isObject: Bool
            let start: Int
            var members: [Member] = []
            var items: [Node] = []
            /// An object's key waiting for its value.
            var key: (String, Range<Int>)?

            var closer: UInt8 { isObject ? 0x7D : 0x5D }

            mutating func add(_ node: Node) {
                if isObject, let key {
                    members.append(Member(key: key.0, keyRange: key.1, value: node))
                    self.key = nil
                } else {
                    items.append(node)
                }
            }

            func node(end: Int) -> Node {
                Node(kind: isObject ? .object : .array, range: start..<end, members: members, items: items)
            }
        }

        /// The whole text as one value. Objects and arrays are kept on a stack, not in nested calls, so
        /// no nesting can run out of stack.
        mutating func document() throws -> Node {
            try skipSpace()
            guard at < bytes.count else { throw Problem.empty }
            var stack: [Open] = []
            while true {
                guard at < bytes.count else { throw Problem.notJSON }
                var node: Node
                let byte = bytes[at]
                if byte == 0x7B || byte == 0x5B {
                    var open = Open(isObject: byte == 0x7B, start: at)
                    guard stack.count < SkillJSONText.maxDepth else { throw Problem.notJSON }
                    at += 1
                    try skipSpace()
                    guard at < bytes.count else { throw Problem.notJSON }
                    if bytes[at] == open.closer {
                        at += 1
                        node = open.node(end: at)
                    } else {
                        if open.isObject { try readKey(into: &open) }
                        stack.append(open)
                        continue
                    }
                } else {
                    node = try scalar()
                }
                // Hand the value to its container, closing every container it completes.
                while true {
                    guard var top = stack.popLast() else {
                        try skipSpace()
                        guard at == bytes.count else { throw Problem.notJSON }
                        return node
                    }
                    top.add(node)
                    try skipSpace()
                    guard at < bytes.count else { throw Problem.notJSON }
                    if bytes[at] == 0x2C {
                        at += 1
                        try skipSpace()
                        guard at < bytes.count else { throw Problem.notJSON }
                        if bytes[at] == top.closer { throw Problem.trailingComma }
                        if top.isObject { try readKey(into: &top) }
                        stack.append(top)
                        break
                    }
                    guard bytes[at] == top.closer else { throw Problem.notJSON }
                    at += 1
                    node = top.node(end: at)
                }
            }
        }

        mutating func skipSpace() throws {
            while at < bytes.count {
                switch bytes[at] {
                case 0x20, 0x09, 0x0A, 0x0D: at += 1
                case 0x2F: throw Problem.comment // `/`: only a comment starts with it outside a string
                default: return
                }
            }
        }

        /// A member's key and its colon, with `at` on its value.
        mutating func readKey(into open: inout Open) throws {
            guard at < bytes.count, bytes[at] == 0x22 else { throw Problem.notJSON }
            let start = at
            let key = try string()
            open.key = (key, start..<at)
            try skipSpace()
            guard at < bytes.count, bytes[at] == 0x3A else { throw Problem.notJSON }
            at += 1
            try skipSpace()
        }

        /// A string, number, true, false or null.
        mutating func scalar() throws -> Node {
            switch bytes[at] {
            case 0x22:
                let start = at
                let text = try string()
                return Node(kind: .string, range: start..<at, string: text)
            case 0x74: return try literal("true", .bool)
            case 0x66: return try literal("false", .bool)
            case 0x6E: return try literal("null", .null)
            default: return try number()
            }
        }

        /// A string from its opening quote: decoded, with `at` after its closing quote.
        mutating func string() throws -> String {
            at += 1
            var out: [UInt8] = []
            while at < bytes.count {
                let byte = bytes[at]
                at += 1
                if byte == 0x22 { return String(decoding: out, as: UTF8.self) }
                if byte < 0x20 { throw Problem.notJSON } // a raw control character (a line break, say)
                guard byte == 0x5C else {
                    out.append(byte)
                    continue
                }
                guard at < bytes.count else { throw Problem.notJSON }
                let escape = bytes[at]
                at += 1
                switch escape {
                case 0x22, 0x5C, 0x2F: out.append(escape)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x75: out += Array(String(try unicodeEscape()).utf8)
                default: throw Problem.notJSON
                }
            }
            throw Problem.notJSON
        }

        /// `\uXXXX` after the `u`, joining a surrogate pair; a lone half reads as U+FFFD, as it decodes.
        mutating func unicodeEscape() throws -> Character {
            let first = try hex4()
            if (0xD800...0xDBFF).contains(first), at + 1 < bytes.count, bytes[at] == 0x5C, bytes[at + 1] == 0x75 {
                let saved = at
                at += 2
                let second = try hex4()
                if (0xDC00...0xDFFF).contains(second) {
                    let scalar = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    return Character(Unicode.Scalar(scalar) ?? "\u{FFFD}")
                }
                at = saved
            }
            return Character(Unicode.Scalar(first) ?? "\u{FFFD}")
        }

        mutating func hex4() throws -> UInt32 {
            guard at + 4 <= bytes.count else { throw Problem.notJSON }
            var value: UInt32 = 0
            for byte in bytes[at..<at + 4] {
                guard let digit = Self.hexDigit(byte) else { throw Problem.notJSON }
                value = value << 4 | digit
            }
            at += 4
            return value
        }

        static func hexDigit(_ byte: UInt8) -> UInt32? {
            switch byte {
            case 0x30...0x39: return UInt32(byte - 0x30)
            case 0x41...0x46: return UInt32(byte - 0x41 + 10)
            case 0x61...0x66: return UInt32(byte - 0x61 + 10)
            default: return nil
            }
        }

        mutating func literal(_ word: String, _ kind: Node.Kind) throws -> Node {
            let start = at
            let expected = Array(word.utf8)
            guard at + expected.count <= bytes.count, Array(bytes[at..<at + expected.count]) == expected else { throw Problem.notJSON }
            at += expected.count
            return Node(kind: kind, range: start..<at)
        }

        /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`
        mutating func number() throws -> Node {
            let start = at
            if at < bytes.count, bytes[at] == 0x2D { at += 1 }
            guard at < bytes.count, Self.isDigit(bytes[at]) else { throw Problem.notJSON }
            if bytes[at] == 0x30 {
                at += 1
                if at < bytes.count, Self.isDigit(bytes[at]) { throw Problem.notJSON }
            } else {
                skipDigits()
            }
            if at < bytes.count, bytes[at] == 0x2E {
                at += 1
                guard at < bytes.count, Self.isDigit(bytes[at]) else { throw Problem.notJSON }
                skipDigits()
            }
            if at < bytes.count, bytes[at] == 0x65 || bytes[at] == 0x45 {
                at += 1
                if at < bytes.count, bytes[at] == 0x2B || bytes[at] == 0x2D { at += 1 }
                guard at < bytes.count, Self.isDigit(bytes[at]) else { throw Problem.notJSON }
                skipDigits()
            }
            return Node(kind: .number, range: start..<at)
        }

        mutating func skipDigits() {
            while at < bytes.count, Self.isDigit(bytes[at]) { at += 1 }
        }

        static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
    }
}

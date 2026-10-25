import Foundation

// The part of YAML that config files hold, read for the import: block mappings and sequences, plain, single-quoted and
// double-quoted scalars (over several lines too), literal and folded blocks, comments, `---` documents, and flow
// collections that close on their line. An anchor only names a node, so the node is read; an alias, a tag and a flow
// collection over several lines are kept as a part to skip, never followed. It runs nothing, includes nothing, and
// stops past `maxDepth` levels or `maxNodes` nodes. YAML 1.1's booleans (`yes`, `on`) read as booleans.

public enum YAMLSubset {
    /// Mappings and sequences in one another, no deeper than this.
    public static let maxDepth = 64
    /// The most nodes a file may hold.
    public static let maxNodes = 200_000

    public enum Style: Equatable, Sendable {
        case plain
        case singleQuoted
        case doubleQuoted
        /// `|`: its line breaks kept.
        case literal
        /// `>`: its lines folded into one, a blank line kept as a break.
        case folded
    }

    /// What a scalar is: only a plain one can be anything but a string.
    public enum Kind: Equatable, Sendable {
        case string
        case boolean
        case number
        case null
    }

    public struct Scalar: Equatable, Sendable {
        public let text: String
        public let style: Style
        /// Its first line, 1-based.
        public let line: Int

        public var kind: Kind { style == .plain ? YAMLSubset.kind(ofPlain: text) : .string }
    }

    /// A part the reader doesn't follow.
    public enum Part: Equatable, Sendable {
        case alias
        case tag
        /// A flow collection (`[…]`, `{…}`) that goes on past its line.
        case flow
    }

    public struct Pair: Equatable, Sendable {
        public let key: String
        public let line: Int
        public let value: Node
    }

    public indirect enum Node: Equatable, Sendable {
        case scalar(Scalar)
        case mapping([Pair])
        case sequence([Node])
        case skipped(Part, line: Int)

        /// The value of the last pair with this key, as loaders read a key set twice.
        public subscript(key: String) -> Node? {
            pairs?.last { (pair: Pair) -> Bool in pair.key == key }?.value
        }

        public var scalar: Scalar? {
            if case .scalar(let scalar) = self { return scalar }
            return nil
        }

        public var pairs: [Pair]? {
            if case .mapping(let pairs) = self { return pairs }
            return nil
        }

        public var items: [Node]? {
            if case .sequence(let items) = self { return items }
            return nil
        }

        /// The text of a string scalar, or nil.
        public var string: String? {
            guard let scalar, scalar.kind == .string else { return nil }
            return scalar.text
        }

        /// Its first line, or 0 for an empty collection.
        public var line: Int {
            switch self {
            case .scalar(let scalar): return scalar.line
            case .mapping(let pairs): return pairs.first?.line ?? 0
            case .sequence(let items): return items.first?.line ?? 0
            case .skipped(_, let line): return line
            }
        }
    }

    public enum Reason: Equatable, Sendable {
        case tabIndent
        case indentation
        case unclosedQuote
        case badEscape
        case tooDeep
        case complexKey
        case unexpected
        case tooMany
    }

    /// Why a file can't be read, at its line. Nothing of the file is in it.
    public struct Failure: Error, Equatable, Sendable {
        public let line: Int
        public let reason: Reason

        public var sentence: String {
            switch reason {
            case .tabIndent: return "Line \(line) is indented with a tab, which YAML doesn\u{2019}t allow."
            case .indentation: return "Line \(line) is indented in a way Next Term can\u{2019}t follow."
            case .unclosedQuote: return "The quote on line \(line) isn\u{2019}t closed."
            case .badEscape: return "Line \(line) has an escape YAML doesn\u{2019}t have."
            case .tooDeep: return "Line \(line) is nested deeper than Next Term reads."
            case .complexKey: return "Line \(line) has a key Next Term can\u{2019}t read."
            case .unexpected: return "Line \(line) holds something Next Term can\u{2019}t read there."
            case .tooMany: return "It holds more values than Next Term reads."
            }
        }
    }

    /// Each document in the text, in order: an empty one (only comments) is left out.
    public static func documents(_ text: String) -> Result<[Node], Failure> {
        var bytes: [UInt8] = Array(text.utf8)
        defer { SecretBytes.wipe(&bytes) }
        return parse(bytes)
    }

    /// The documents of `bytes`, read with a parser that is gone once this returns, so the caller's wipe reaches the
    /// only copy.
    static func parse(_ bytes: [UInt8]) -> Result<[Node], Failure> {
        guard bytes.count < Int(Int32.max) else { return .failure(Failure(line: 1, reason: .tooMany)) }
        var parser = Parser(bytes: bytes)
        do {
            return .success(try parser.documents())
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(Failure(line: 1, reason: .unexpected))
        }
    }
}

import Foundation

/// Tab completion's order: names that start with what was typed, in any case, first (shorter first, then
/// alphabetical); then names with the typed letters in order anywhere, best first (Go to File's FuzzyIndex,
/// unchanged). Names are compared NFC-normalised and case-folded, so NFC input finds an NFD name and é finds É.
/// With nothing typed, everything, alphabetical.
public final class CompletionRanking: @unchecked Sendable {
    public struct Ranked: Equatable, Sendable {
        /// Into the names given.
        public var index: Int
        public var prefix: Bool
        /// The name's characters (Unicode scalars) to pick out. Empty when folding changed the name's length
        /// (an NFD name, ß): the positions would not map.
        public var highlights: [Int]
    }

    public let names: [String]
    private let keys: [String]
    private let keyScalars: [[Unicode.Scalar]]
    private let sameLength: [Bool]
    private let fuzzy: FuzzyIndex

    public init(names: [String]) {
        self.names = names
        var keys: [String] = []
        var scalars: [[Unicode.Scalar]] = []
        var same: [Bool] = []
        keys.reserveCapacity(names.count)
        for name in names {
            let key = Self.key(name)
            let keyScalars = Array(key.unicodeScalars)
            keys.append(key)
            scalars.append(keyScalars)
            same.append(keyScalars.count == name.unicodeScalars.count)
        }
        self.keys = keys
        keyScalars = scalars
        sameLength = same
        fuzzy = FuzzyIndex(paths: keys)
    }

    /// What names are compared by: NFC, case-folded.
    public static func key(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
        return folded.precomposedStringWithCanonicalMapping
    }

    /// The names matching `typed`, best first.
    public func rank(_ typed: String) -> [Ranked] {
        let query = Self.key(typed)
        let queryScalars = Array(query.unicodeScalars)
        if queryScalars.isEmpty {
            let order = names.indices.sorted { a, b in keys[a] != keys[b] ? keys[a] < keys[b] : names[a] < names[b] }
            return order.map { Ranked(index: $0, prefix: true, highlights: []) }
        }
        var prefixed: [Int] = []
        var rest: [Int] = []
        for index in names.indices {
            if keyScalars[index].starts(with: queryScalars) { prefixed.append(index) } else { rest.append(index) }
        }
        prefixed.sort { a, b in
            let lengthA = keyScalars[a].count, lengthB = keyScalars[b].count
            if lengthA != lengthB { return lengthA < lengthB }
            return keys[a] != keys[b] ? keys[a] < keys[b] : names[a] < names[b]
        }
        let prefixHighlights = Array(0..<queryScalars.count)
        var ranked = prefixed.map { Ranked(index: $0, prefix: true, highlights: sameLength[$0] ? prefixHighlights : []) }

        let matches = fuzzy.search(query, among: rest) ?? []
        let ordered = matches.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let lengthA = keyScalars[a.index].count, lengthB = keyScalars[b.index].count
            if lengthA != lengthB { return lengthA < lengthB }
            return keys[a.index] < keys[b.index]
        }
        for match in ordered {
            let highlights = sameLength[match.index] ? scalarOffsets(fuzzy.positions(of: query, in: match.index), in: match.index) : []
            ranked.append(Ranked(index: match.index, prefix: false, highlights: highlights))
        }
        return ranked
    }

    /// UTF-8 offsets in a key, as offsets of its scalars.
    private func scalarOffsets(_ bytes: [Int], in index: Int) -> [Int] {
        guard !bytes.isEmpty else { return [] }
        let wanted = Set(bytes)
        var result: [Int] = []
        var offset = 0
        for (position, scalar) in keyScalars[index].enumerated() {
            let length = String(scalar).utf8.count
            if (offset..<(offset + length)).contains(where: wanted.contains) { result.append(position) }
            offset += length
        }
        return result
    }

    /// A name as the popup shows it: control characters and invisible or direction-changing ones as visible
    /// escapes (`\x0A`, `\u{202E}`), so a name can't hide part of itself or reorder the row.
    public static func visible(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            if ShellQuote.isControl(scalar) {
                out += String(format: "\\x%02X", scalar.value)
            } else if WordQuote.isHidden(scalar) {
                out += String(format: "\\u{%04X}", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

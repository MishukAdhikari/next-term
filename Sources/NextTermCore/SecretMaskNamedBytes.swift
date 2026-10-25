import Foundation

/// A line's UTF-8 bytes as `quotedValue`, `bareValue` and the indented values (`indentedValue`, `removedIndentedValue`)
/// read them in `MCPRedaction.redact`, for `MCPRedaction.NamedValues`: what ICU takes a space (`\s`), a line's end (`^`,
/// `$`) and a name's character to be.
struct NamedValueBytes {
    /// An opaque run's first byte, which counts as the three characters of •••, and its other bytes, which count as none:
    /// what `redact` made ••• before those patterns run (`opaqueCopy`). Neither is UTF-8, so neither is a space, a quote,
    /// an operator, a name's character or a line's end.
    static let opaqueStart: UInt8 = 0xFE
    static let opaqueRest: UInt8 = 0xFF

    let bytes: UnsafeBufferPointer<UInt8>
    var count: Int { bytes.count }

    /// The length of the White_Space character at `index` (ICU's `\s`), 0 for another or past the end.
    func space(_ index: Int) -> Int {
        guard index < count else { return 0 }
        let first = bytes[index]
        if first == 0x20 || (0x09...0x0D).contains(first) { return 1 }
        if first == 0xC2 { return index + 1 < count && (bytes[index + 1] == 0x85 || bytes[index + 1] == 0xA0) ? 2 : 0 }
        guard first == 0xE1 || first == 0xE2 || first == 0xE3, index + 2 < count else { return 0 }
        let second = bytes[index + 1], third = bytes[index + 2]
        switch first {
        case 0xE1: return second == 0x9A && third == 0x80 ? 3 : 0 // U+1680
        case 0xE3: return second == 0x80 && third == 0x80 ? 3 : 0 // U+3000
        default:
            if second == 0x81 { return third == 0x9F ? 3 : 0 } // U+205F
            guard second == 0x80 else { return 0 }
            // U+2000 to U+200A, U+2028, U+2029, U+202F
            return (0x80...0x8A).contains(third) || third == 0xA8 || third == 0xA9 || third == 0xAF ? 3 : 0
        }
    }

    /// The length of the line terminator at `index`, where ICU's `^` and `$` see a line's end (LF, VT, FF, CR, NEL, LS,
    /// PS), 0 for another character or past the end.
    func lineEnd(_ index: Int) -> Int {
        guard index < count else { return 0 }
        let first = bytes[index]
        if (0x0A...0x0D).contains(first) { return 1 }
        if first == 0xC2 { return index + 1 < count && bytes[index + 1] == 0x85 ? 2 : 0 }
        guard first == 0xE2, index + 2 < count, bytes[index + 1] == 0x80 else { return 0 }
        return bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9 ? 3 : 0
    }

    /// Past the spaces at `index` (`\s*+`).
    func skipSpaces(_ index: Int) -> Int {
        var at = index
        while case let length = space(at), length > 0 { at += length }
        return at
    }

    /// Whether `byte` is a name's character: `[A-Za-z0-9_.\-]`.
    static func isName(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x5F, 0x2E, 0x2D: return true
        default: return false
        }
    }

    /// The length of a name's character at `index` where the pattern ignores case (`bareValue`): ICU then takes ſ
    /// (U+017F) and the Kelvin sign (U+212A) for s and k. 0 for none.
    func foldedName(_ index: Int) -> Int {
        guard index < count else { return 0 }
        if Self.isName(bytes[index]) { return 1 }
        if bytes[index] == 0xC5 { return index + 1 < count && bytes[index + 1] == 0xBF ? 2 : 0 }
        guard bytes[index] == 0xE2, index + 2 < count else { return 0 }
        return bytes[index + 1] == 0x84 && bytes[index + 2] == 0xAA ? 3 : 0
    }

    /// The URL scheme's character (`urlPassword` ignores case: ſ and the Kelvin sign too) that ends at `end`, and whether
    /// it is a letter; nil for none.
    func schemeCharacter(endingAt end: Int) -> (length: Int, letter: Bool)? {
        guard end > 0 else { return nil }
        switch bytes[end - 1] {
        case 0x41...0x5A, 0x61...0x7A: return (1, true)
        case 0x30...0x39, 0x2B, 0x2E, 0x2D: return (1, false)
        case 0xBF where end >= 2 && bytes[end - 2] == 0xC5: return (2, true)
        case 0xAA where end >= 3 && bytes[end - 3] == 0xE2 && bytes[end - 2] == 0x84: return (3, true)
        default: return nil
        }
    }

    /// Whether `range` holds at least `least` characters as the pattern counts them, an opaque run being three.
    func holds(_ range: Range<Int>, atLeast least: Int) -> Bool {
        var found = 0
        for index in range {
            let byte = bytes[index]
            if byte == Self.opaqueStart {
                found += 3
            } else if byte != Self.opaqueRest, byte & 0xC0 != 0x80 {
                found += 1
            }
            if found >= least { return true }
        }
        return false
    }

    func starts(with prefix: [UInt8], at index: Int) -> Bool {
        index + prefix.count <= count && prefix.indices.allSatisfy { bytes[index + $0] == prefix[$0] }
    }

    func text(_ range: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
    }
}

import Foundation

extension NamedValueBytes {
    /// A value `quotedValue` or `bareValue` masks for its name, in UTF-8 offsets: where the match starts (the name; a bare
    /// value's line start), the value alone, and where the text the pattern needs to mask it ends: past a quoted value's
    /// closing quote, at a bare value's end (spaces or the text's end may follow).
    struct Found: Equatable {
        let start: Int
        let value: Range<Int>
        let end: Int
    }

    /// Every value the two patterns mask for its name, and maybe a few more, never fewer: each place a match could start
    /// is tried on its own (the patterns, taking matches left to right, skip one that starts inside another), a name of
    /// any length counts (they read 256 characters at most), and a placeholder counts as a value (`isValue`).
    func namedValues() -> [Found] {
        // Both patterns need an `=` or a `:` before the value: most lines have neither.
        guard bytes.contains(where: { $0 == 0x3D || $0 == 0x3A }) else { return [] }
        return quotedValues() + bareValues()
    }

    /// `quotedValue`: a name, maybe its closing quote, `=`, `:`, `=>` or `:=` with spaces around, and a value in quotes
    /// of one kind, 4 characters at least, on one line.
    func quotedValues() -> [Found] {
        var found: [Found] = []
        var next = NextByte()
        var index = 0
        while index < count {
            guard Self.isName(bytes[index]) else { index += 1; continue }
            let start = index
            while index < count, Self.isName(bytes[index]) { index += 1 }
            if let value = quotedValue(after: index, next: &next), MCPRedaction.isSecretName(text(start..<index)) {
                found.append(Found(start: start, value: value, end: value.upperBound + 1))
            }
        }
        return found
    }

    private func quotedValue(after name: Int, next: inout NextByte) -> Range<Int>? {
        var at = name
        if at < count, bytes[at] == 0x22 || bytes[at] == 0x27 { at += 1 }
        at = skipSpaces(at)
        guard at < count else { return nil }
        switch bytes[at] {
        case 0x3D: at += at + 1 < count && bytes[at + 1] == 0x3E ? 2 : 1 // = or =>
        case 0x3A: at += at + 1 < count && bytes[at + 1] == 0x3D ? 2 : 1 // : or :=
        default: return nil
        }
        at = skipSpaces(at)
        guard at < count, bytes[at] == 0x22 || bytes[at] == 0x27 || bytes[at] == 0x60 else { return nil }
        let first = at + 1
        guard let close = next.position(of: bytes[at], from: first, in: bytes) else { return nil }
        if let feed = next.position(of: 0x0A, from: first, in: bytes), feed < close { return nil }
        return holds(first..<close, atLeast: 4) ? first..<close : nil
    }

    /// `bareValue`: at a line's start, maybe a diff's + or -, spaces, `export`, then a name, `=` or `:` with spaces
    /// around, and a value of 6 characters at least with no space, quote or `#` in it, and only spaces after it.
    func bareValues() -> [Found] {
        var found: [Found] = []
        var lineStart = 0
        while lineStart < count {
            if let value = bareValue(lineStart: lineStart) {
                found.append(Found(start: lineStart, value: value, end: value.upperBound))
            }
            var at = lineStart
            while at < count, lineEnd(at) == 0 { at += 1 }
            guard at < count else { break }
            lineStart = at + lineEnd(at)
        }
        return found
    }

    private func bareValue(lineStart: Int) -> Range<Int>? {
        let sign = bytes[lineStart] == 0x2B || bytes[lineStart] == 0x2D
        if sign, let value = bareValue(name: afterIndent(lineStart + 1)) { return value }
        // `[+\-]?` takes nothing: the name may start with a -, which is one of its characters.
        return bareValue(name: afterIndent(lineStart))
    }

    /// Past `[ \t]*+(?:export\s++)?+` at `start`, where the name starts.
    private func afterIndent(_ start: Int) -> Int {
        var at = start
        while at < count, bytes[at] == 0x20 || bytes[at] == 0x09 { at += 1 }
        let export = Array("export".utf8)
        guard at + export.count < count, export.indices.allSatisfy({ bytes[at + $0] | 0x20 == export[$0] }) else { return at }
        let after = skipSpaces(at + export.count)
        return after > at + export.count ? after : at
    }

    private func bareValue(name start: Int) -> Range<Int>? {
        // The name's look-behind: no name's character before it (a - the sign took).
        if start > 0, Self.isName(bytes[start - 1]) { return nil }
        var at = start
        while case let length = foldedName(at), length > 0 { at += length }
        guard at > start else { return nil }
        let name = start..<at
        at = skipSpaces(at)
        guard at < count, bytes[at] == 0x3D || bytes[at] == 0x3A else { return nil }
        let first = skipSpaces(at + 1)
        var end = first
        while end < count, space(end) == 0, !Self.endsABareValue(bytes[end]) { end += 1 }
        guard holds(first..<end, atLeast: 6) else { return nil }
        var rest = end
        while lineEnd(rest) == 0, case let length = space(rest), length > 0 { rest += length }
        guard rest == count || lineEnd(rest) > 0, MCPRedaction.isSecretName(text(name)) else { return nil }
        return first..<end
    }

    /// A quote or a `#`, which a bare value cannot hold.
    private static func endsABareValue(_ byte: UInt8) -> Bool {
        byte == 0x22 || byte == 0x27 || byte == 0x60 || byte == 0x23
    }
}

/// The next place of a byte at or after a place, for a scan that asks in order: each is looked for once.
struct NextByte {
    private var known: [UInt8: (from: Int, at: Int)] = [:]

    mutating func position(of byte: UInt8, from start: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        if let found = known[byte], found.from <= start, start <= found.at {
            return found.at < bytes.count ? found.at : nil
        }
        var at = start
        while at < bytes.count, bytes[at] != byte { at += 1 }
        known[byte] = (start, at)
        return at < bytes.count ? at : nil
    }
}

import Foundation

extension NamedValueBytes {
    /// `original` with what `redact` has made ••• by the time `quotedValue` and `bareValue` run made an opaque run: each
    /// stored value (`stored`, its byte ranges), then each private key's BEGIN line (a token pattern, the only one with a
    /// space in it), then each password in a URL (`urlPassword`, which may hold a quote), each found as the patterns find
    /// it in the line as it is by then. The other tokens hold no space, quote or operator, so they change no match the
    /// patterns make. nil: nothing is.
    static func opaqueCopy(of original: UnsafeBufferPointer<UInt8>, stored: [Range<Int>]) -> [UInt8]? {
        var copy: [UInt8]?
        func mark(_ ranges: [Range<Int>]) {
            guard !ranges.isEmpty else { return }
            var marked = copy ?? Array(original)
            for range in ranges where !range.isEmpty {
                marked[range.lowerBound] = opaqueStart
                for index in range.dropFirst() { marked[index] = opaqueRest }
            }
            copy = marked
        }
        mark(stored)
        for find in [Self.privateKeyHeaders, Self.urlPasswords] {
            if let current = copy {
                mark(current.withUnsafeBufferPointer { find(NamedValueBytes(bytes: $0))() })
            } else {
                mark(find(NamedValueBytes(bytes: original))())
            }
        }
        return copy
    }

    /// The BEGIN lines of private keys, `-----BEGIN [A-Z ]*PRIVATE KEY-----`, as the token pattern finds them: `[A-Z ]*`
    /// takes the whole run of capitals and spaces, which then ends with PRIVATE KEY, and the dashes come next.
    func privateKeyHeaders() -> [Range<Int>] {
        let begin = Array("-----BEGIN ".utf8)
        let words = Array("PRIVATE KEY".utf8)
        let dashes = Array("-----".utf8)
        var found: [Range<Int>] = []
        var index = 0
        while index + begin.count + words.count + dashes.count <= count {
            guard bytes[index] == 0x2D, starts(with: begin, at: index) else { index += 1; continue }
            var end = index + begin.count
            while end < count, bytes[end] == 0x20 || (0x41...0x5A).contains(bytes[end]) { end += 1 }
            guard end - words.count >= index + begin.count, starts(with: words, at: end - words.count),
                  starts(with: dashes, at: end) else {
                index += 1
                continue
            }
            found.append(index..<end + dashes.count)
            index = end + dashes.count
        }
        return found
    }

    /// The passwords of `scheme://user:password@` in the line, as `urlPassword` finds them: the scheme is the whole run
    /// of its characters before `://` (the pattern's look-behind starts it nowhere else), and starts with a letter.
    func urlPasswords() -> [Range<Int>] {
        var found: [Range<Int>] = []
        var index = 1
        while index + 2 < count {
            guard bytes[index] == 0x3A, bytes[index + 1] == 0x2F, bytes[index + 2] == 0x2F else { index += 1; continue }
            var start = index
            var letter = false
            while let character = schemeCharacter(endingAt: start) {
                start -= character.length
                letter = character.letter
            }
            guard start < index, letter, let password = password(after: index + 3) else {
                index += 1
                continue
            }
            found.append(password)
            index = password.upperBound + 1
        }
        return found
    }

    /// The password in `user:password@` at `start`: `[^\s:/@]++:([^\s@/]++)@`.
    private func password(after start: Int) -> Range<Int>? {
        var at = start
        while at < count, space(at) == 0, bytes[at] != 0x3A, bytes[at] != 0x2F, bytes[at] != 0x40 { at += 1 }
        guard at > start, at < count, bytes[at] == 0x3A else { return nil }
        let first = at + 1
        at = first
        while at < count, space(at) == 0, bytes[at] != 0x40, bytes[at] != 0x2F { at += 1 }
        guard at > first, at < count, bytes[at] == 0x40 else { return nil }
        return first..<at
    }
}

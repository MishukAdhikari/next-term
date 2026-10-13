import Foundation

extension MCPRedaction {
    /// Where a cut in one whole line would show part of a value `redact` masks for its name (`quotedValue`, `bareValue`).
    /// Such a value can be any length, and only its name, maybe far before the cut, makes it a secret's: the text around
    /// a cut (`cutsAMask`) cannot tell. The values are read from the line's bytes in one pass (`NamedValueBytes`), with
    /// what `redact` has made ••• by then made opaque, so a stored value or a URL's password in the line counts as the
    /// ••• the patterns see.
    struct NamedValues {
        let line: String
        /// Inside a value: a cut there that keeps the text before it shows the value's start. UTF-8 offsets, sorted,
        /// apart.
        private let keepingBefore: [Range<Int>]
        /// From just past where a value's match starts (its name, or a bare value's line start) to the value's end: a cut
        /// there that keeps the text after it shows the value, or its end, with a part of its name that may be no
        /// secret's, or none. UTF-8 offsets, sorted, apart.
        private let keepingAfter: [Range<Int>]

        init(_ line: String, mask secrets: SecretMask) {
            self.line = line
            var copy = line
            let found = copy.withUTF8 { original -> [NamedValueBytes.Found] in
                guard original.contains(where: { $0 == 0x3D || $0 == 0x3A }) else { return [] }
                guard let opaque = NamedValueBytes.opaqueCopy(of: original, stored: secrets.ranges(in: original)) else {
                    return NamedValueBytes(bytes: original).namedValues()
                }
                return opaque.withUnsafeBufferPointer { NamedValueBytes(bytes: $0).namedValues() }
            }
            keepingBefore = Self.apart(found.map { $0.value.lowerBound + 1..<$0.value.upperBound })
            keepingAfter = Self.apart(found.map { $0.start + 1..<$0.value.upperBound })
        }

        /// Whether a cut at `index` shows part of a value: of the text after the cut with `keepingAfter`, before it without.
        func cuts(_ index: String.Index, keepingAfter after: Bool) -> Bool {
            span(at: index, keepingAfter: after) != nil
        }

        /// Where a cut at `index` goes so the text it keeps shows no part of a value: back to the value's start when it
        /// keeps the text before it, on past the value when it keeps the text after it; nil when it shows none as it is.
        /// The place is a character's start, rounded away from the value.
        func clean(_ index: String.Index, keepingAfter after: Bool) -> String.Index? {
            guard let span = span(at: index, keepingAfter: after) else { return nil }
            if after { return character(at: span.upperBound, roundingUp: true) }
            return character(at: span.lowerBound - 1, roundingUp: false)
        }

        private func span(at index: String.Index, keepingAfter after: Bool) -> Range<Int>? {
            let spans = after ? keepingAfter : keepingBefore
            guard !spans.isEmpty else { return nil }
            let offset = line.utf8.distance(from: line.startIndex, to: index)
            var low = 0
            var high = spans.count
            while low < high {
                let middle = (low + high) / 2
                if spans[middle].upperBound <= offset { low = middle + 1 } else { high = middle }
            }
            return low < spans.count && spans[low].contains(offset) ? spans[low] : nil
        }

        private func character(at offset: Int, roundingUp: Bool) -> String.Index {
            var index = line.utf8.index(line.startIndex, offsetBy: offset)
            while String.Index(index, within: line) == nil {
                index = roundingUp ? line.utf8.index(after: index) : line.utf8.index(before: index)
            }
            return index
        }

        /// `ranges` sorted, with those that overlap or touch made one.
        static func apart(_ ranges: [Range<Int>]) -> [Range<Int>] {
            var merged: [Range<Int>] = []
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where !range.isEmpty {
                if let last = merged.last, range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            return merged
        }
    }

    /// The last line's `NamedValues`, kept while find_in_files builds its snippets with one mask: a line's matches come
    /// together, and a long line is read once for all of them.
    final class NamedValuesCache {
        private var last: NamedValues?

        func values(_ line: String, mask secrets: SecretMask) -> NamedValues {
            if let last, last.line == line { return last }
            let values = NamedValues(line, mask: secrets)
            last = values
            return values
        }
    }
}

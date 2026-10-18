import Foundation

extension MCPRedaction {
    /// The values `redact` masks for a name on a line before their own: `const apiKey =` with the value on the next
    /// line, as a formatter writes a long assignment, a YAML key with its quoted value on the line under it or its plain
    /// value on a line indented more (`indentedValue`), or `export` on a line before a bare value's name. The patterns
    /// read across lines there (a bare value's `=` or `:` stays on its name's line), so `redact` masks such a value in
    /// the text whole. But read_file's cut and find_in_files' snippet look at the value's line alone, and read_file from
    /// an offset may start after the name: the line on its own showed the value. Such a value is made ••• in its line
    /// first, and the line goes on as any other.
    struct CarriedValues {
        /// Per line (an index into the lines given), its values named on a line before it, in UTF-8 offsets in the
        /// line, sorted, apart.
        private var values: [Int: [Range<Int>]] = [:]

        /// The values in `lines[range]` named on a line before their own. The lines are read from the third line before
        /// the range with text in it: no match reaches further back, a name, its operator and `export` each taking a
        /// line at most, with only spaces and blank lines between, and an indented value's key with two lines with text
        /// at most between it and its value (comments, a diff's other side: `indentedValue`). The values are found as
        /// `NamedValues` finds them, with what `redact` has made ••• by then opaque; a placeholder is left, as `redact`
        /// leaves it.
        init(_ lines: [String], in range: Range<Int>, mask secrets: SecretMask) {
            let range = range.clamped(to: 0..<lines.count)
            var first = range.lowerBound
            var withText = 0
            while first > 0, withText < 3 {
                first -= 1
                if !Self.isBlank(lines[first]) { withText += 1 }
            }
            guard !range.isEmpty, first + 1 < range.upperBound else { return } // one line: nothing before it names one
            var text = ""
            var starts: [Int] = []
            for index in first..<range.upperBound {
                starts.append(text.utf8.count)
                text += lines[index] + "\n"
            }
            let found = text.withUTF8 { original -> [(line: Int, value: Range<Int>)] in
                guard original.contains(where: { $0 == 0x3D || $0 == 0x3A }) else { return [] }
                guard let opaque = NamedValueBytes.opaqueCopy(of: original, stored: secrets.ranges(in: original)) else {
                    return Self.carried(original, scanning: original, starts: starts)
                }
                return opaque.withUnsafeBufferPointer { Self.carried(original, scanning: $0, starts: starts) }
            }
            var values: [Int: [Range<Int>]] = [:]
            for item in found where first + item.line >= range.lowerBound {
                values[first + item.line, default: []].append(item.value)
            }
            self.values = values.mapValues { NamedValues.apart($0) }
        }

        /// The values in `bytes` (`original`, maybe with runs made opaque) whose match starts on a line before theirs, by
        /// line (an index into `starts`, where each line starts) and in UTF-8 offsets in it.
        private static func carried(_ original: UnsafeBufferPointer<UInt8>, scanning bytes: UnsafeBufferPointer<UInt8>,
                                    starts: [Int]) -> [(line: Int, value: Range<Int>)] {
            NamedValueBytes(bytes: bytes).namedValues().compactMap { found in
                let line = Self.line(holding: found.value.lowerBound, starts: starts)
                guard line > Self.line(holding: found.start, starts: starts) else { return nil } // its own line masks it
                // A run made opaque in it is what `redact` has made ••• by then: the value is one to hide.
                let hidden = found.value.contains { bytes[$0] >= NamedValueBytes.opaqueStart }
                let value = String(decoding: UnsafeBufferPointer(rebasing: original[found.value]), as: UTF8.self)
                guard hidden || MCPRedaction.isValue(value) else { return nil }
                return (line, found.value.lowerBound - starts[line]..<found.value.upperBound - starts[line])
            }
        }

        /// The line (an index into `starts`, sorted) that holds UTF-8 offset `offset`.
        private static func line(holding offset: Int, starts: [Int]) -> Int {
            var low = 0
            var high = starts.count
            while high - low > 1 {
                let middle = (low + high) / 2
                if starts[middle] <= offset { low = middle } else { high = middle }
            }
            return low
        }

        /// Whether `line` holds only spaces (ICU's `\s`).
        static func isBlank(_ line: String) -> Bool {
            var copy = line
            return copy.withUTF8 { NamedValueBytes(bytes: $0).skipSpaces(0) == $0.count }
        }

        /// `line`, which is `lines[index]` of those given, with its values named on a line before it made •••, and how
        /// many.
        func masked(_ line: String, at index: Int) -> (text: String, count: Int) {
            guard let ranges = values[index], let last = ranges.last, last.upperBound <= line.utf8.count else { return (line, 0) }
            var bytes = Array(line.utf8)
            for range in ranges.reversed() {
                bytes.replaceSubrange(range, with: Array(MCPRedaction.mask.utf8))
            }
            return (String(decoding: bytes, as: UTF8.self), ranges.count)
        }

        /// As `masked(_:at:)`, with where `match` (UTF-16, as a search gives it) is in the text it gives: an end in a value
        /// moves to the end of its •••, a start in one to its start, and one past it by what the ••• took off.
        func masked(_ line: String, at index: Int, keeping match: NSRange) -> (text: String, count: Int, match: NSRange) {
            let masked = masked(line, at: index)
            guard masked.count > 0, let ranges = values[index] else { return (line, 0, match) }
            let utf8 = line.utf8
            let wide = ranges.map { range -> Range<Int> in
                let lower = utf8.index(utf8.startIndex, offsetBy: range.lowerBound).utf16Offset(in: line)
                return lower..<utf8.index(utf8.startIndex, offsetBy: range.upperBound).utf16Offset(in: line)
            }
            let length = (MCPRedaction.mask as NSString).length
            func moved(_ position: Int, isEnd: Bool) -> Int {
                var shift = 0
                for range in wide {
                    if position <= range.lowerBound { break }
                    if position >= range.upperBound {
                        shift += length - range.count
                        continue
                    }
                    return range.lowerBound + shift + (isEnd ? length : 0)
                }
                return position + shift
            }
            let start = moved(match.location, isEnd: false)
            let end = moved(NSMaxRange(match), isEnd: true)
            return (masked.text, masked.count, NSRange(location: start, length: end - start))
        }
    }
}

import Foundation

extension MCPRedaction {
    /// find_in_files' matches with their values named on a line before their own made ••• (`CarriedValues`). A match
    /// holds its line alone, so its file is read again as the search read it, once for all its matches, and the lines
    /// before the match's line are taken from it, back to the third with text in it. A line the file no longer holds as
    /// the search found it (the file changed since, or is gone) is ••• whole: what the lines before it name is not known.
    /// A blank line holds no value, and is given as it is without reading them.
    final class CarriedLines {
        private let root: String
        private let mask: SecretMask
        /// The file read last: its path, its UTF-8 bytes (nil when it could not be read) and where each line starts.
        private var path: String?
        private var bytes: [UInt8]?
        private var starts: [Int] = []
        /// The line read last, kept for the next match in it: a long line is read once for all its matches.
        private var last: (line: Int, text: String, values: CarriedValues, index: Int)?

        init(root: String, mask: SecretMask) {
            self.root = root
            self.mask = mask
        }

        /// `match` with its line's values named on a line before it made •••, its range moved with them, and how many.
        func masking(_ match: SearchMatch) -> (match: SearchMatch, count: Int) {
            guard match.line > 1 else { return (match, 0) } // nothing before it
            // A blank line holds no value: no walk back over the blank lines before it, for each such match.
            guard !CarriedValues.isBlank(match.lineText) else { return (match, 0) }
            if path != match.relativePath { read(match.relativePath) }
            guard let found = values(at: match.line - 1, text: match.lineText) else {
                let whole = NSRange(location: 0, length: (MCPRedaction.mask as NSString).length)
                let masked = SearchMatch(relativePath: match.relativePath, line: match.line, lineText: MCPRedaction.mask, range: whole)
                return (masked, 1)
            }
            let masked = found.values.masked(match.lineText, at: found.index, keeping: match.range)
            guard masked.count > 0 else { return (match, 0) }
            let moved = SearchMatch(relativePath: match.relativePath, line: match.line, lineText: masked.text, range: masked.match)
            return (moved, masked.count)
        }

        private func read(_ relativePath: String) {
            path = relativePath
            last = nil
            bytes = nil
            starts = []
            // As the search reads it: a regular file, not too big, not binary, UTF-8.
            guard let text = ProjectSearch.text(of: URL(fileURLWithPath: root).appendingPathComponent(relativePath)) else { return }
            let read = Array(text.utf8)
            var starts = [0]
            for index in read.indices where read[index] == 0x0A { starts.append(index + 1) }
            self.bytes = read
            self.starts = starts
        }

        /// The values for line `index` (from 0) of the file read, with the line's index among the lines they were read
        /// with; nil when the file does not hold `text` there.
        private func values(at index: Int, text: String) -> (values: CarriedValues, index: Int)? {
            if let last, last.line == index, last.text == text { return (last.values, last.index) }
            guard bytes != nil, index < starts.count else { return nil }
            var first = index
            var withText = 0
            while first > 0, withText < 3 {
                first -= 1
                if !CarriedValues.isBlank(line(first)) { withText += 1 }
            }
            let lines = (first...index).map { line($0) }
            guard lines.last == text else { return nil }
            let values = CarriedValues(lines, in: lines.count - 1..<lines.count, mask: mask)
            last = (index, text, values, lines.count - 1)
            return (values, lines.count - 1)
        }

        /// Line `index` of the file read, as `ProjectSearch.splitLines` gives it: without its line feed, or a carriage
        /// return just before it.
        private func line(_ index: Int) -> String {
            guard let bytes else { return "" }
            let start = starts[index]
            let feed = index + 1 < starts.count
            var end = feed ? starts[index + 1] - 1 : bytes.count
            if feed, end > start, bytes[end - 1] == 0x0D { end -= 1 }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }
    }
}

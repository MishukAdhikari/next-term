import Foundation

/// Scrollback read behind the alternate screen (KTD9). While an editor, a pager or an agent has the alternate screen in
/// front, the normal buffer can only be read as text (`getBufferAsData`): a line a row, with no wrap flags, and each row
/// trimmed of its empty cells. So:
/// - whether a row goes on to the next is guessed from whether it fills the width, as every row a line wrapped from does
///   (`Row.full`), a blank at its end included;
/// - each row is masked alone, then the rows are put together into the lines they probably were, and each two of those
///   next to each other masked joined (`maskAcrossRows`);
/// - a command's echo is found by its text without blanks, over as many rows as it takes (`BareRows`).
extension ScrollbackText {
    /// The rows of a terminal's normal buffer as text (`getBufferAsData`), as it is read while the alternate screen is
    /// on, in a pane `columns` wide: one a line, with no wrap flags. The other half of a wide character reads as U+0000
    /// there: it goes, after it has counted as the cell it takes.
    public static func rows(bufferData data: Data, columns: Int) -> [Row] {
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.map { (line: String) -> Row in
            Row(withoutWideHalves(line), wrapped: nil, full: columns > 0 && line.unicodeScalars.count >= columns)
        }
    }

    static func withoutWideHalves(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        var afterWide = false
        for scalar in text.unicodeScalars {
            if scalar == "\u{0}", afterWide {
                afterWide = false
                continue
            }
            kept.append(scalar)
            afterWide = isWide(scalar)
        }
        return String(kept)
    }

    /// Takes two cells: the East Asian wide and fullwidth blocks, and the emoji ones. Close enough to know the empty cell
    /// after it for its other half.
    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF: return true
        case 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6: return true
        case 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD: return true
        default: return false
        }
    }

    // MARK: masking across rows

    /// Rows without wrap flags: what masking each alone (`out`, for `lines[range]`) misses where a line wrapped from one
    /// row to the next. The rows are put together into the lines they probably were (`probableLines`), and each two of
    /// those next to each other are masked joined by a blank, as the wrap may have fallen where a row's empty cells were
    /// trimmed; after a row not known to fill the width, also without one. A line with none next to it is masked alone.
    /// What that masks more is masked in the rows it lies in, with what masking each alone found there, so neither hides
    /// the other: each is read from the rows as they were.
    static func maskAcrossRows(_ out: inout [String], _ lines: [Line], _ range: Range<Int>, blank: Set<Int>,
                               mask: (String) -> String) {
        let units = probableLines(lines, upTo: range.upperBound, blank: blank).filter { (unit: Range<Int>) -> Bool in
            unit.upperBound >= range.lowerBound
        }
        var joined: [Joined] = []
        for (number, unit) in units.enumerated() {
            let after = number + 1 < units.count && units[number + 1].lowerBound == unit.upperBound ? units[number + 1] : nil
            let before = number > 0 && units[number - 1].upperBound == unit.lowerBound
            if let after {
                for joint in joints(after: lines[unit.upperBound - 1]) {
                    joined.append(Joined(lines, rows: unit, joint: joint, then: after))
                }
            } else if !before, unit.count > 1, unit.upperBound > range.lowerBound {
                joined.append(Joined(lines, rows: unit, joint: "", then: nil))
            }
        }
        guard !joined.isEmpty else { return }
        let texts = joined.map { (line: Joined) -> String in String(String.UnicodeScalarView(line.text)) }
        var masks = mask(texts.joined(separator: "\n")).components(separatedBy: "\n")
        if masks.count != texts.count { masks = texts.map(mask) }
        var spans: [Int: [Range<Int>]] = [:]
        for (number, line) in joined.enumerated() where masks[number] != texts[number] {
            // Masked as its rows were alone: nothing more.
            if masks[number] == line.alone(out, from: range.lowerBound) { continue }
            let masked = Array(masks[number].unicodeScalars)
            // Where it cannot tell the parts apart (the rows held `•••` already), from the first change to the last.
            let coarse = changed(line.text, masked).map { (span: Range<Int>) -> [Range<Int>] in [span] } ?? []
            for span in maskedSpans(line.text, masked) ?? coarse {
                for (row, at) in line.starts where range.contains(row) {
                    let lower = max(span.lowerBound, at)
                    let upper = min(span.upperBound, at + lines[row].text.unicodeScalars.count)
                    if lower < upper { spans[row, default: []].append(lower - at..<upper - at) }
                }
            }
        }
        for (row, added) in spans {
            let index = row - range.lowerBound
            let text = Array(lines[row].text.unicodeScalars)
            guard let alone = maskedSpans(text, Array(out[index].unicodeScalars)) else {
                out[index] = MCPRedaction.mask
                continue
            }
            out[index] = masking(text, alone + added)
        }
    }

    /// Rows put together, masked as one line.
    struct Joined {
        var text: [Unicode.Scalar] = []
        /// Each row in it, and where it starts.
        var starts: [(row: Int, at: Int)] = []
        /// What joins each row to the next.
        var joints: [String] = []

        /// The rows of `rows`, each joined to the next as it probably went on, then `joint` and the rows of `then`.
        init(_ lines: [Line], rows: Range<Int>, joint: String, then: Range<Int>?) {
            add(lines, rows)
            if let then {
                joints.append(joint)
                text.append(contentsOf: joint.unicodeScalars)
                add(lines, then)
            }
        }

        private mutating func add(_ lines: [Line], _ rows: Range<Int>) {
            for row in rows {
                if row > rows.lowerBound {
                    let joint = lines[row - 1].trimmed ? " " : ""
                    joints.append(joint)
                    text.append(contentsOf: joint.unicodeScalars)
                }
                starts.append((row, text.count))
                text.append(contentsOf: lines[row].text.unicodeScalars)
            }
        }

        /// Its rows as each was masked alone (`out`, from row `first`), joined the same way. Nil when one is before them.
        func alone(_ out: [String], from first: Int) -> String? {
            var text = ""
            for (number, start) in starts.enumerated() {
                guard start.row >= first else { return nil }
                if number > 0 { text += joints[number - 1] }
                text += out[start.row - first]
            }
            return text
        }
    }

    /// The rows of `lines` before `end` put together into the lines they probably were: a row that fills the width with
    /// the row after it. A blank row (a dropped command's) or an empty one is in none.
    static func probableLines(_ lines: [Line], upTo end: Int, blank: Set<Int>) -> [Range<Int>] {
        var units: [Range<Int>] = []
        var start: Int?
        for index in 0..<end {
            if blank.contains(index) || lines[index].text.isEmpty {
                if let open = start { units.append(open..<index) }
                start = nil
                continue
            }
            let open = start ?? index
            if lines[index].full == true {
                start = open
            } else {
                units.append(open..<index + 1)
                start = nil
            }
        }
        if let open = start { units.append(open..<end) }
        return units
    }

    /// How a line probably went on after `line`, its last row: with the blank trimmed at its end, or with the one a
    /// wrap at its trimmed empty cells left out; past a row not known to fill the width, with no blank too.
    static func joints(after line: Line) -> [String] {
        line.trimmed || line.full == false ? [" "] : line.full == true ? [""] : ["", " "]
    }

    /// The parts of `text` that each `•••` in `masked` took the place of, when `masked` is `text` with parts of it so
    /// replaced, each found from the left as short as lets the text after it agree. Nil when it is not.
    static func maskedSpans(_ text: [Unicode.Scalar], _ masked: [Unicode.Scalar]) -> [Range<Int>]? {
        let mark = Array(MCPRedaction.mask.unicodeScalars)
        var literals: [ArraySlice<Unicode.Scalar>] = []
        var from = 0
        var at = 0
        while at + mark.count <= masked.count {
            if masked[at] == mark[0], masked[at..<at + mark.count].elementsEqual(mark) {
                literals.append(masked[from..<at])
                at += mark.count
                from = at
            } else {
                at += 1
            }
        }
        literals.append(masked[from...])
        guard text.starts(with: literals[0]) else { return nil }
        guard literals.count > 1 else { return literals[0].count == text.count ? [] : nil }
        var spans: [Range<Int>] = []
        var position = literals[0].count
        for (number, literal) in literals.enumerated().dropFirst() {
            let found: Int?
            if number == literals.count - 1 {
                let start = text.count - literal.count
                found = start >= position && text[start...].elementsEqual(literal) ? start : nil
            } else {
                found = firstIndex(of: literal, in: text, from: position)
            }
            guard let found else { return nil }
            if found > position { spans.append(position..<found) }
            position = found + literal.count
        }
        return spans
    }

    static func firstIndex(of part: ArraySlice<Unicode.Scalar>, in text: [Unicode.Scalar], from start: Int) -> Int? {
        guard start + part.count <= text.count else { return nil }
        guard let head = part.first else { return start }
        for index in start...(text.count - part.count) where text[index] == head {
            if text[index..<index + part.count].elementsEqual(part) { return index }
        }
        return nil
    }

    // MARK: finding a command's echo

    /// `text` without its blanks.
    static func bare(_ text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.filter { (scalar: Unicode.Scalar) -> Bool in scalar != " " && scalar != "\t" }
    }

    /// A fingerprint of `parts` one after the other, the same however the text is split into them.
    static func fingerprint<Parts: Sequence>(bare parts: Parts) -> Int where Parts.Element == [Unicode.Scalar] {
        var hasher = Hasher()
        for part in parts {
            for scalar in part { hasher.combine(scalar.value) }
        }
        return hasher.finalize()
    }

    /// Rows without wrap flags, to find a line among them by its text without blanks: whether it wrapped, and at which
    /// blank, is not known there.
    struct BareRows {
        /// Each row's text without blanks.
        let rows: [[Unicode.Scalar]]
        /// How many characters the rows before each hold, one more than there are rows; and the first row before which
        /// each such count is reached.
        let sums: [Int]
        let firstAt: [Int: Int]

        init(_ lines: [Line]) {
            rows = lines.map { (line: Line) -> [Unicode.Scalar] in ScrollbackText.bare(line.text) }
            var sums = [0]
            var firstAt = [0: 0]
            sums.reserveCapacity(rows.count + 1)
            for row in rows {
                let sum = sums[sums.count - 1] + row.count
                if firstAt[sum] == nil { firstAt[sum] = sums.count }
                sums.append(sum)
            }
            self.sums = sums
            self.firstAt = firstAt
        }

        /// The rows from `start` that hold `count` characters, starting with one that holds some: up to the row after
        /// the last of them. An empty line is an empty row.
        func end(from start: Int, count: Int) -> Int? {
            guard start < rows.count else { return nil }
            if count == 0 { return rows[start].isEmpty ? start + 1 : nil }
            guard !rows[start].isEmpty, let end = firstAt[sums[start] + count] else { return nil }
            return end
        }

        /// Every place `echo` shows: each of its lines over the rows that hold it, one after the other.
        func places(of echo: Echo) -> [Range<Int>] {
            guard let count = echo.bareCounts.first else { return [] }
            var places: [Range<Int>] = []
            for start in rows.indices {
                guard var end = end(from: start, count: count), matches(start..<end, echo.bare[0]) else { continue }
                var found = true
                for line in echo.bare.indices.dropFirst() {
                    let next = self.end(from: end, count: echo.bareCounts[line])
                    guard let next, matches(end..<next, echo.bare[line]) else {
                        found = false
                        break
                    }
                    end = next
                }
                if found { places.append(start..<end) }
            }
            return places
        }

        func matches(_ span: Range<Int>, _ print: Int) -> Bool {
            ScrollbackText.fingerprint(bare: rows[span]) == print
        }
    }
}

import Foundation

extension SecretMask {
    /// Rows of a screen, matched as one run with the line breaks taken out, and the masked parts mapped back to each
    /// row by UTF-8 offset: a key a wrap split is masked in both rows. The rows are matched twice: as they are, and
    /// with each row's edges left out (`edges(of:)`), what agent UIs draw around a key they wrap: Claude Code's "  ⎿  "
    /// and Codex's "  └ " before a tool's output and the indent of its next rows, a box's "│" at both ends. The first
    /// keeps a space the terminal wrapped at, the second skips an indent. NULs are left out of both: the terminal gives
    /// one for the cell after a wide character, and no stored value holds one. Each part keeps the row's edges.
    public func mask(rows: [String]) -> [String] {
        guard !isEmpty, !rows.isEmpty else { return rows }
        var joined: [UInt8] = []
        var starts: [Int] = []
        for row in rows {
            starts.append(joined.count)
            joined.append(contentsOf: row.utf8)
        }
        starts.append(joined.count)
        let plain = ScreenRun(rows, starts: starts, trimmed: false)
        var found = plain.matches(self, in: joined)
        let trimmed = ScreenRun(rows, starts: starts, trimmed: true)
        if trimmed.bytes.count != plain.bytes.count { found += trimmed.matches(self, in: joined) }
        guard !found.isEmpty else { return rows }
        found = Self.merged(found)
        return rows.indices.map { index -> String in
            let start = starts[index]
            let end = starts[index + 1]
            let inRow = found.compactMap { range -> Range<Int>? in
                let lower = max(range.lowerBound, start)
                let upper = min(range.upperBound, end)
                return lower < upper ? (lower - start)..<(upper - start) : nil
            }
            return inRow.isEmpty ? rows[index] : Self.replacing(inRow, in: joined[start..<end])
        }
    }

    /// Rows `window` of a screen whose rows `rows` exist, masked over whole lines. `mask(rows:)` sees only the rows it is
    /// given, so a window whose first row holds the tail of a key that starts above it would show that tail unmasked.
    /// Here the rows past each end of the window are masked with it, then left out, wrapped or not: a terminal marks a
    /// row it wrapped itself, but agent UIs (Ink, ratatui) wrap with a newline or cursor moves, and `mask(rows:)` joins
    /// every row to the next one anyway. The walk past each end stops once the rows it read hold `longest - 1` bytes of
    /// text (`textBytes(of:)`, a row's edges not counted), all a form that reaches into the window can have outside it,
    /// or at a row with no text: no stored value has a line break, so none spans a row with nothing but its edges. With
    /// no marks nothing outside the window is read.
    ///
    /// `text(row)` is a row's text as shown, asked only for rows in `rows`.
    public func mask(window: ClosedRange<Int>, rows: ClosedRange<Int>, text: (Int) -> String) -> [String] {
        let shown = window.map(text)
        guard !isEmpty else { return shown }
        let above = walk(from: window.lowerBound - 1, by: -1, within: rows, text: text)
        let below = walk(from: window.upperBound + 1, by: 1, within: rows, text: text)
        let masked = mask(rows: above.reversed() + shown + below)
        return Array(masked[above.count..<(above.count + shown.count)])
    }

    /// The rows from `start` on, `step` at a time, that a form reaching into the window from that side can be on.
    private func walk(from start: Int, by step: Int, within rows: ClosedRange<Int>, text: (Int) -> String) -> [String] {
        var read: [String] = []
        var row = start
        var bytes = 0
        while rows.contains(row), bytes < longest - 1 {
            let line = text(row)
            let held = Self.textBytes(of: line)
            guard held > 0 else { break }
            read.append(line)
            bytes += held
            row += step
        }
        return read
    }

    /// Whether a character at a row's end is white space or one agent UIs draw around text they wrap: a space, a tab, a
    /// NUL (the terminal's empty cell), box drawing and block elements (U+2500 to U+259F: "│", "└", "─", "▌") and "⎿".
    static func isRowEdge(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00, 0x09, 0x20, 0x23BF, 0x2500...0x259F: return true
        default: return false
        }
    }

    /// The UTF-8 lengths of the edge characters (`isRowEdge`) `row` starts and ends with; a row of nothing else is all
    /// start.
    static func edges(of row: String) -> (leading: Int, trailing: Int) {
        var leading = 0
        for scalar in row.unicodeScalars {
            guard isRowEdge(scalar) else { break }
            leading += UTF8.width(scalar)
        }
        let count = row.utf8.count
        guard leading < count else { return (count, 0) }
        var trailing = 0
        for scalar in row.unicodeScalars.reversed() {
            guard isRowEdge(scalar) else { break }
            trailing += UTF8.width(scalar)
        }
        return (leading, trailing)
    }

    /// The bytes of `row` a stored value can be part of: all but its edges and its NULs.
    static func textBytes(of row: String) -> Int {
        let edges = edges(of: row)
        let inner = row.utf8.dropFirst(edges.leading).dropLast(edges.trailing)
        return inner.reduce(0) { $1 == 0 ? $0 : $0 + 1 }
    }
}

/// A screen's rows joined for matching, with some bytes left out: `bytes` holds those kept, `origin` the offset of each
/// in the rows' whole join, and `firsts` where each row's kept bytes start in `bytes`, with one more at the end.
struct ScreenRun {
    var bytes: [UInt8] = []
    var origin: [Int] = []
    var firsts: [Int] = []
    /// Where each row starts in the whole join, with one more at the end.
    let starts: [Int]

    /// Every byte of `rows` but NULs, and with `trimmed` none of a row's edges (`SecretMask.edges(of:)`) either.
    init(_ rows: [String], starts: [Int], trimmed: Bool) {
        self.starts = starts
        bytes.reserveCapacity(starts.last ?? 0)
        origin.reserveCapacity(starts.last ?? 0)
        for (index, row) in rows.enumerated() {
            firsts.append(bytes.count)
            let edges = trimmed ? SecretMask.edges(of: row) : (leading: 0, trailing: 0)
            let kept = edges.leading..<(row.utf8.count - edges.trailing)
            var offset = 0
            for byte in row.utf8 {
                if byte != 0, kept.contains(offset) {
                    bytes.append(byte)
                    origin.append(starts[index] + offset)
                }
                offset += 1
            }
        }
        firsts.append(bytes.count)
    }

    /// `mask`'s matches in `bytes`, as ranges of the whole join `joined`: one in each row a match covers, from its first
    /// byte kept there to its last, with the NULs right after it in that row taken along (a wide character's second
    /// cell). An edge between two parts of a key stays out.
    func matches(_ mask: SecretMask, in joined: [UInt8]) -> [Range<Int>] {
        let found = bytes.withUnsafeBufferPointer { mask.ranges(in: $0) }
        var out: [Range<Int>] = []
        for match in found {
            var row = rowHolding(match.lowerBound)
            while row + 1 < firsts.count, firsts[row] < match.upperBound {
                let lower = max(match.lowerBound, firsts[row])
                let upper = min(match.upperBound, firsts[row + 1])
                if lower < upper {
                    var end = origin[upper - 1] + 1
                    while end < starts[row + 1], joined[end] == 0 { end += 1 }
                    out.append(origin[lower]..<end)
                }
                row += 1
            }
        }
        return out
    }

    /// The row whose kept bytes hold `index`, an index of `bytes`.
    func rowHolding(_ index: Int) -> Int {
        var low = 0
        var high = firsts.count - 2
        while low < high {
            let middle = (low + high + 1) / 2
            if firsts[middle] <= index { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

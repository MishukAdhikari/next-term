import Foundation

extension SecretMask {
    /// Rows `window` of a screen whose rows `rows` exist, masked over whole lines. `mask(rows:)` sees only the rows it is
    /// given, so a window whose first row holds the tail of a key that starts above it would show that tail unmasked.
    /// Here the rows past each end of the window are masked with it, then left out, wrapped or not: a terminal marks a
    /// row it wrapped itself, but agent UIs (Ink, ratatui) wrap with a newline or cursor moves, and `mask(rows:)` joins
    /// every row to the next one anyway. The walk past each end stops once the rows it read hold `longest - 1` bytes, all
    /// a form that reaches into the window can have outside it, with each row counted as one byte at least so blank rows
    /// end it too; with no marks nothing outside the window is read.
    ///
    /// `text(row)` is a row's text as shown, asked only for rows in `rows`.
    public func mask(window: ClosedRange<Int>, rows: ClosedRange<Int>, text: (Int) -> String) -> [String] {
        let shown = window.map(text)
        guard !isEmpty else { return shown }
        let reach = longest - 1
        var above: [String] = []
        var row = window.lowerBound - 1
        var bytes = 0
        while row >= rows.lowerBound, bytes < reach {
            let line = text(row)
            above.append(line)
            bytes += max(1, line.utf8.count)
            row -= 1
        }
        var below: [String] = []
        row = window.upperBound + 1
        bytes = 0
        while row <= rows.upperBound, bytes < reach {
            let line = text(row)
            below.append(line)
            bytes += max(1, line.utf8.count)
            row += 1
        }
        let masked = mask(rows: above.reversed() + shown + below)
        return Array(masked[above.count..<(above.count + shown.count)])
    }
}

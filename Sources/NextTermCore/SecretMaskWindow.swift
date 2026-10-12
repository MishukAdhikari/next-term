import Foundation

extension SecretMask {
    /// Rows `window` of a screen, masked over whole lines. `mask(rows:)` sees only the rows it is given, so a window
    /// whose first row continues a line wrapped above it would show the tail of a key whose start is above, unmasked.
    /// Here the rows a wrap joins to either end of the window are masked with it, then left out. The walk past each end
    /// stops after the rows the longest form can span at `columns` columns (a row of n columns holds at most n bytes'
    /// worth of a form), and with no marks nothing outside the window is read.
    ///
    /// `wrapped(row)` is true when that row exists and continues the one above it, which exists too; `text(row)` is a
    /// row's text as shown.
    public func mask(window: ClosedRange<Int>, columns: Int, wrapped: (Int) -> Bool, text: (Int) -> String) -> [String] {
        let reach = isEmpty ? 0 : longest / max(1, columns) + 2
        var start = window.lowerBound
        while window.lowerBound - start < reach, wrapped(start) { start -= 1 }
        var end = window.upperBound
        while end - window.upperBound < reach, wrapped(end + 1) { end += 1 }
        let masked = mask(rows: (start...end).map(text))
        let first = window.lowerBound - start
        return Array(masked[first..<(first + window.count)])
    }
}

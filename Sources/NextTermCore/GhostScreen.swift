import Foundation

/// A plugin's ghost on a zsh prompt (zsh-autosuggestions' POSTDISPLAY): zsh draws it in the terminal's cells right after
/// the whole line, so an agent reading the screen would take it for typed text. With the ghost hook's report of the line
/// (GhostProtocol.BufferReport), Next Term finds those cells, checks that they show that text, and leaves them out of what
/// MCP's read_tab and wait_for_tab send, which say what is typed instead (`input`). Where the cells don't show it (an
/// async suggestion newer than the report), nothing is cut, and no suggestion is said.
public enum GhostScreen {
    /// Some of a row's cells: the row as the caller counts rows, and the cells' columns.
    public struct Span: Equatable, Sendable {
        public var row: Int
        public var columns: Range<Int>

        public init(row: Int, columns: Range<Int>) {
            self.row = row
            self.columns = columns
        }
    }

    /// The cells a ghost `ghostCells` wide takes after a line's end: from the caret, past what is right of it (RBUFFER,
    /// `rightCells`), wrapping at `columns` as zsh draws it, since zsh puts POSTDISPLAY after the whole buffer.
    public static func span(caretRow: Int, caretColumn: Int, columns: Int, rightCells: Int, ghostCells: Int) -> [Span] {
        guard columns > 0, ghostCells > 0, caretColumn >= 0, caretColumn < columns, rightCells >= 0 else { return [] }
        var at = caretColumn + rightCells
        var row = caretRow + at / columns
        at %= columns
        var left = ghostCells
        var spans: [Span] = []
        while left > 0 {
            let take = min(left, columns - at)
            spans.append(Span(row: row, columns: at..<(at + take)))
            left -= take
            row += 1
            at = 0
        }
        return spans
    }

    /// The cells `text` takes as the terminal shows it: a combining mark none, an East Asian wide character or an emoji two,
    /// anything else one. nil for text zsh shows some other way (a control character as ^X, a line break), whose cells
    /// Next Term doesn't try to place.
    public static func cells(_ text: String) -> Int? { cells(scalars: text.unicodeScalars) }

    public static func cells<Scalars: Sequence>(scalars: Scalars) -> Int? where Scalars.Element == Unicode.Scalar {
        var total = 0
        for scalar in scalars {
            guard let width = width(scalar) else { return nil }
            total += width
        }
        return total
    }

    static func width(_ scalar: Unicode.Scalar) -> Int? {
        let value = scalar.value
        if value < 0x20 || (0x7F..<0xA0).contains(value) { return nil }
        if value < 0x7F { return 1 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark: return 0
        case .format: return value == 0xAD ? 1 : 0
        case .lineSeparator, .paragraphSeparator: return nil
        default: break
        }
        if (0x1160...0x11FF).contains(value) || (0xD7B0...0xD7FF).contains(value) { return 0 }
        return ScrollbackText.isWide(scalar) || scalar.properties.isEmojiPresentation ? 2 : 1
    }

    /// Whether the text read from a span `width` cells wide (an empty cell as a space, a wide character once) is the start of
    /// `postdisplay` that fits in it.
    public static func matches(cells: String, postdisplay: String, width: Int) -> Bool {
        guard width > 0, !cells.isEmpty else { return false }
        return cells == fitting(postdisplay, in: width)
    }

    /// The start of `text` that fits in `width` cells, a wide character that would be cut left out.
    static func fitting(_ text: String, in width: Int) -> String {
        var used = 0
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let cells = self.width(scalar) ?? 1
            if used + cells > width { break }
            used += cells
            kept.append(scalar)
        }
        return String(kept)
    }

    /// A report of the line says what is typed only while nothing was written to the shell after it was read: each write
    /// (a key, a paste, an agent's text) is a line it may have changed.
    public static func isCurrent(reportWrites: Int, currentWrites: Int) -> Bool {
        reportWrites == currentWrites
    }
}

/// MCP's `input` for a tab at its zsh prompt (read_tab, wait_for_tab): the line being typed, the cursor in characters as
/// zsh counts them, and a plugin's ghost (`suggestion`), which is not typed and not in `screen`. Next Term's own
/// suggestion is never here: it is for the person at the keyboard.
public enum InputReport {
    /// nil when the line can't be read (over the hook's cap, not UTF-8). `suggestion`: a plugin's ghost whose cells were
    /// found where zsh drew it. Both texts are masked as the rest of the reply is.
    public static func make(from report: GhostProtocol.BufferReport, suggestion: String?, mask: (String) -> String) -> [String: Any]? {
        guard let line = report.buffer else { return nil }
        var input: [String: Any] = ["line": mask(line), "cursor": report.cursor]
        if let suggestion, !suggestion.isEmpty { input["suggestion"] = mask(suggestion) }
        return input
    }
}

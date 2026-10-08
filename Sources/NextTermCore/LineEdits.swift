import Foundation

/// The editor's line commands (Edit › Line) and its whole-line copy: each one replacement of the text and the
/// selection after it, worked out on the text as the editor holds it. Lines end in "\n": a CRLF file is edited
/// with plain newlines, and one with mixed endings keeps each "\r" inside its line, so it moves with the line.
public enum LineEdits {
    /// The characters in `range` (of the text before the edit) become `text`, then `selection` is selected.
    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var text: String
        public var selection: NSRange

        public init(range: NSRange, text: String, selection: NSRange) {
            self.range = range
            self.text = text
            self.selection = selection
        }
    }

    /// The lines (0-based) a selection touches. A selection that ends at the start of a line leaves that line out.
    public static func lines(touching selection: NSRange, in index: LineIndex) -> ClosedRange<Int> {
        let first = index.line(at: selection.location)
        let last = selection.length > 0 ? index.line(at: NSMaxRange(selection) - 1) : first
        return first...max(first, last)
    }

    /// Where a line's text ends, before its "\n".
    static func end(of line: Int, in index: LineIndex) -> Int {
        line + 1 < index.count ? index.starts[line + 1] - 1 : index.length
    }

    static func text(of lines: ClosedRange<Int>, in text: NSString, _ index: LineIndex) -> String {
        let start = index.starts[lines.lowerBound]
        return text.substring(with: NSRange(location: start, length: end(of: lines.upperBound, in: index) - start))
    }

    /// The empty line after a final "\n": the end of the file, not a line to move.
    static func isEnd(_ line: Int, in index: LineIndex) -> Bool {
        line > 0 && line == index.count - 1 && index.starts[line] == index.length
    }

    /// Duplicate Line. A selection within a line duplicates after itself; with nothing selected the caret's
    /// line duplicates below it, and a selection over several lines duplicates the lines it touches below them.
    /// The caret or the selection moves onto the copy, so doing it again makes another.
    public static func duplicate(_ selection: NSRange, in text: NSString, _ index: LineIndex) -> Edit {
        if selection.length > 0, !text.substring(with: selection).contains("\n") {
            let end = NSMaxRange(selection)
            return Edit(range: NSRange(location: end, length: 0), text: text.substring(with: selection),
                        selection: NSRange(location: end, length: selection.length))
        }
        let lines = lines(touching: selection, in: index)
        let block = Self.text(of: lines, in: text, index)
        let end = end(of: lines.upperBound, in: index)
        let shift = (block as NSString).length + 1
        return Edit(range: NSRange(location: end, length: 0), text: "\n" + block,
                    selection: NSRange(location: selection.location + shift, length: selection.length))
    }

    /// Delete Line: the lines the selection touches, with their line break (the last line of the file takes
    /// the break before it instead, so no empty line is left). The caret goes to the line that takes their
    /// place, at the column it had there. Nil for an empty file.
    public static func delete(_ selection: NSRange, in text: NSString, _ index: LineIndex) -> Edit? {
        guard index.length > 0 else { return nil }
        let lines = lines(touching: selection, in: index)
        let first = lines.lowerBound, after = lines.upperBound + 1
        let column = selection.location - index.starts[first]
        if after < index.count {
            // The next line moves up into their place.
            let start = index.starts[first]
            let length = end(of: after, in: index) - index.starts[after]
            return Edit(range: NSRange(location: start, length: index.starts[after] - start), text: "",
                        selection: NSRange(location: start + min(column, length), length: 0))
        }
        guard first > 0 else {
            return Edit(range: NSRange(location: 0, length: index.length), text: "", selection: NSRange(location: 0, length: 0))
        }
        // The last lines: the caret goes up to the line before them.
        let from = index.starts[first] - 1
        let above = index.starts[first - 1]
        return Edit(range: NSRange(location: from, length: index.length - from), text: "",
                    selection: NSRange(location: above + min(column, from - above), length: 0))
    }

    /// Move Line Up or Down: the lines the selection touches change places with the line above or below, and
    /// the selection goes with them. Nil at the top or the bottom (the empty line after a final line break
    /// stays the end of the file).
    public static func move(_ selection: NSRange, up: Bool, in text: NSString, _ index: LineIndex) -> Edit? {
        let lines = lines(touching: selection, in: index)
        // Only a caret can be on that empty line (a selection's last character is always on a line before it).
        if isEnd(lines.upperBound, in: index) { return nil }
        let other = up ? lines.lowerBound - 1 : lines.upperBound + 1
        guard other >= 0, other < index.count, !isEnd(other, in: index) else { return nil }
        let block = Self.text(of: lines, in: text, index)
        let neighbour = Self.text(of: other...other, in: text, index)
        let first = min(other, lines.lowerBound)
        let start = index.starts[first]
        let end = end(of: max(other, lines.upperBound), in: index)
        let shift = (neighbour as NSString).length + 1
        let location = selection.location + (up ? -shift : shift)
        // A selection that held the line break after the lines ends with them when they become the last line
        // (the text keeps its length).
        let length = min(selection.length, text.length - location)
        return Edit(range: NSRange(location: start, length: end - start), text: up ? block + "\n" + neighbour : neighbour + "\n" + block,
                    selection: NSRange(location: location, length: length))
    }

    /// ⌘C or ⌘X with nothing selected: the caret's line with a line break after it (one is added after a last
    /// line that has none), so pasting it gives a whole line. ⌘X takes the line away as Delete Line does.
    public static func wholeLine(at caret: Int, in text: NSString, _ index: LineIndex) -> String {
        let line = index.line(at: caret)
        return Self.text(of: line...line, in: text, index) + "\n"
    }

    /// Pasting a whole-line copy with nothing selected: it goes in above the caret's line, and the caret stays
    /// where it was in its own line.
    public static func pasteLines(_ copied: String, at caret: Int, _ index: LineIndex) -> Edit {
        let start = index.starts[index.line(at: caret)]
        return Edit(range: NSRange(location: start, length: 0), text: copied,
                    selection: NSRange(location: caret + (copied as NSString).length, length: 0))
    }

    /// Copy Path with Line: "src/app.ts:42", or "src/app.ts:42-48" for lines 42 to 48 (`lines` is 0-based), the
    /// form a ⌘-click in the terminal and agents read. The path is from `root` when the file is inside it.
    public static func pathWithLine(_ path: String, root: String?, lines: ClosedRange<Int>) -> String {
        var shown = path
        if let root, !root.isEmpty {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) { shown = String(path.dropFirst(prefix.count)) }
        }
        let first = lines.lowerBound + 1, last = lines.upperBound + 1
        return shown + ":" + (first == last ? "\(first)" : "\(first)-\(last)")
    }
}

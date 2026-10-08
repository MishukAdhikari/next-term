import Foundation

/// Settings › Editor › On save: trailing spaces and tabs trimmed from every line, and a newline at the end of the
/// file. Both are off by default. Worked out on the text as the editor holds it (lines end in "\n"; a CR left at
/// the end of a line, in a file with mixed endings, stays), as the replacements the editor makes in one undoable
/// step before it writes the file.
public enum SaveCleanUp {
    public struct Replacement: Equatable, Sendable {
        public var range: NSRange
        public var text: String

        public init(range: NSRange, text: String) {
            self.range = range
            self.text = text
        }
    }

    /// Files whose trailing spaces mean something are never trimmed: two spaces end a line in Markdown, and a
    /// patch's context lines must match the file they apply to.
    public static let keepsTrailingWhitespace: Set<String> = ["md", "markdown", "mdx", "diff", "patch"]

    public static func trims(fileNamed name: String) -> Bool {
        !keepsTrailingWhitespace.contains((name as NSString).pathExtension.lowercased())
    }

    /// The replacements, in the order they appear and never overlapping (none: nothing to do). A final newline is
    /// added only when the last line has something on it besides spaces, as in VS Code, so an empty file stays empty.
    public static func replacements(in text: NSString, trimTrailingWhitespace trim: Bool, insertFinalNewline newline: Bool) -> [Replacement] {
        var result: [Replacement] = []
        let length = text.length
        var start = 0
        var lastLineHasText = false
        while start <= length {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: start, length: length - start))
            let end = found.location == NSNotFound ? length : found.location
            var stop = end
            if stop > start, text.character(at: stop - 1) == 0x0D { stop -= 1 }
            var first = stop
            while first > start, isBlank(text.character(at: first - 1)) { first -= 1 }
            if trim, first < stop { result.append(Replacement(range: NSRange(location: first, length: stop - first), text: "")) }
            if found.location == NSNotFound {
                lastLineHasText = first > start
                break
            }
            start = end + 1
        }
        guard newline, lastLineHasText else { return result }
        // Trimmed spaces at the very end make room for the newline in the same replacement.
        if let last = result.last, NSMaxRange(last.range) == length {
            result[result.count - 1].text = "\n"
        } else {
            result.append(Replacement(range: NSRange(location: length, length: 0), text: "\n"))
        }
        return result
    }

    static func isBlank(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 }

    /// The text with the replacements made (for tests, and for a document no editor shows).
    public static func applying(_ replacements: [Replacement], to text: NSString) -> String {
        let result = NSMutableString(string: text)
        for replacement in replacements.reversed() { result.replaceCharacters(in: replacement.range, with: replacement.text) }
        return result as String
    }

    /// Where a place in the text before is after the replacements: moved back by the spaces trimmed before it, to
    /// where trimmed spaces it was among began, and before the newline added at the end.
    public static func location(_ location: Int, after replacements: [Replacement]) -> Int {
        var shift = 0
        for replacement in replacements where replacement.range.location < location {
            if replacement.text.isEmpty && NSMaxRange(replacement.range) <= location {
                shift -= replacement.range.length
            } else {
                return replacement.range.location + shift
            }
        }
        return location + shift
    }
}

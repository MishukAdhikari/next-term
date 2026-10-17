import Foundation

/// A Markdown file's headings, for Go to Heading and a link's `#anchor`, and its counts: words, characters and reading
/// time, of the file or of a selection in it. Each reads the file's lines as MarkdownSyntax reads them: from the text,
/// or as the editor's styler already holds them.
public enum MarkdownOutline {
    public struct Heading: Equatable, Sendable {
        public let level: Int
        /// 0-based.
        public let line: Int
        /// As Live Preview shows it: without its syntax characters.
        public let title: String
        /// The `#anchor` a link names it by: lower case, spaces as `-`, punctuation dropped but `-` and `_`, and a second
        /// heading of the same text `-1`, a third `-2`.
        public let anchor: String
    }

    /// The headings, in order: ATX (`## …`) and setext (text over `===` or `---`), none in a fence, front matter or HTML.
    public static func headings(in text: String) -> [Heading] {
        headings(MarkdownSyntax.lines(of: text), in: text as NSString, LineIndex(text))
    }

    /// The headings of lines already read (`lines` as `index` counts them, in `text`).
    public static func headings(_ lines: [MarkdownSyntax.Line], in text: NSString, _ index: LineIndex) -> [Heading] {
        var headings: [Heading] = []
        var used: [String: Int] = [:]
        for (number, line) in zip(0..<index.count, lines) where line.kind == .heading && line.headingLevel > 0 {
            let title = shown(line.content, of: line, in: text, at: index.starts[number]).trimmingCharacters(in: .whitespaces)
            var anchor = slug(title)
            if let seen = used[anchor] {
                used[anchor] = seen + 1
                anchor += "-\(seen + 1)"
            } else {
                used[anchor] = 0
            }
            headings.append(Heading(level: line.headingLevel, line: number, title: title, anchor: anchor))
        }
        return headings
    }

    /// A heading's anchor, before a repeat's number.
    public static func slug(_ title: String) -> String {
        var slug = String.UnicodeScalarView()
        let kept = CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters)
        for scalar in title.lowercased().unicodeScalars {
            if scalar == " " {
                slug.append("-")
            } else if scalar == "-" || scalar == "_" || kept.contains(scalar) {
                slug.append(scalar)
            }
        }
        return String(slug)
    }

    /// The heading a link's `#anchor` names, if the text has it (written as the anchor is, or percent-encoded).
    public static func heading(named anchor: String, in text: String) -> Heading? {
        let wanted = (anchor.removingPercentEncoding ?? anchor).lowercased()
        return headings(in: text).first { $0.anchor == wanted }
    }

    public struct Stats: Equatable, Sendable {
        public let words: Int
        public let characters: Int

        /// At 230 words a minute, rounded up.
        public var minutes: Int { (words + 229) / 230 }
    }

    /// Words and characters as Live Preview shows the text (its syntax characters left out), outside front matter and
    /// code; in `selection` only, when given. Words are the system's (so a CJK sentence counts its words); characters
    /// count spaces but not line breaks.
    public static func stats(of text: String, in selection: NSRange? = nil) -> Stats {
        stats(MarkdownSyntax.lines(of: text), in: text as NSString, LineIndex(text), selection: selection)
    }

    /// The counts of lines already read.
    public static func stats(_ lines: [MarkdownSyntax.Line], in text: NSString, _ index: LineIndex, selection: NSRange? = nil) -> Stats {
        let skipped: Set<MarkdownSyntax.Kind> = [.frontMatter, .fence, .code, .blank]
        var prose: [String] = []
        for (number, line) in zip(0..<index.count, lines) where !skipped.contains(line.kind) {
            let start = index.starts[number]
            var part = NSRange(location: 0, length: line.length)
            if let selection {
                let overlap = NSIntersectionRange(NSRange(location: start, length: line.length), selection)
                guard overlap.length > 0 else { continue }
                part = NSRange(location: overlap.location - start, length: overlap.length)
            }
            prose.append(shown(part, of: line, in: text, at: start))
        }
        let joined = prose.joined(separator: "\n") as NSString
        var words = 0
        joined.enumerateSubstrings(in: NSRange(location: 0, length: joined.length), options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        let characters = prose.reduce(0) { $0 + $1.count }
        return Stats(words: words, characters: characters)
    }

    /// Part of a line (`part`, relative to it) without the characters Live Preview hides.
    static func shown(_ part: NSRange, of line: MarkdownSyntax.Line, in text: NSString, at start: Int) -> String {
        var units: [UInt16] = []
        var hidden = line.hidden.makeIterator()
        var next = hidden.next()
        for offset in part.location..<NSMaxRange(part) {
            while let run = next, NSMaxRange(run) <= offset { next = hidden.next() }
            if let run = next, run.location <= offset { continue }
            units.append(text.character(at: start + offset))
        }
        return String(decoding: units, as: UTF16.self)
    }
}

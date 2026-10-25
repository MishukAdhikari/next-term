import Foundation

/// Markdown's syntax, read one line at a time from the text alone: the characters that are syntax (Live Preview
/// hides them), the spans that are bold, italic, struck, code or a link, what is drawn over the text (bullets, boxes,
/// rules, the quote bar), and what kind of line it is. Nothing here changes the text: the editor draws from what this
/// says and saves the text as it is, so a mistake here can only change what is drawn, never a byte of the file.
///
/// A line is read with the state the line before ended in (inside a code fence, front matter, an HTML block), so an edit
/// reads again only from its line until a line ends in the same state as before. Two kinds of line also look at the
/// line after them: a table's header row (the delimiter row under it makes it one) and a setext heading's text (the
/// `===` or `---` under it). Within a line, inline syntax follows CommonMark's rules: code spans, escapes, autolinks
/// and inline HTML first, then links, then emphasis by its delimiter runs; GFM's strikethrough, tables and task boxes
/// are read too. Offsets are UTF-16, from the start of the line.
public enum MarkdownSyntax {
    /// Live Preview is offered up to this size; a larger file opens as source.
    public static let previewMaxLength = 2 * 1024 * 1024
    /// A longer line (a minified table, a pasted blob) shows as source: nothing in it is hidden.
    public static let maxLineLength = 5_000

    /// Whether a file opens in Live Preview by its name: `.md` and `.markdown`. MDX stays source, since its JSX
    /// lines would read as HTML.
    public static func isMarkdown(fileName: String) -> Bool {
        let ext = (fileName.lowercased() as NSString).pathExtension
        return ext == "md" || ext == "markdown"
    }

    /// Where the line before left off.
    public struct LineState: Hashable, Sendable {
        public enum Block: Hashable, Sendable {
            case normal
            /// Inside a code fence: its character (` or ~), how many, its indent, and how many quotes it is in.
            case fence(marker: UInt16, count: Int, indent: Int, quotes: Int)
            /// YAML (`---`) or TOML (`+++`) front matter at the top of the file, until its closing line.
            case frontMatter(marker: UInt16)
            case htmlComment
            /// An HTML block, until a blank line, or until its closing text (`</pre>`, `?>`) when it has one.
            case htmlBlock(until: String?)
            /// A table's header row was read: the lines until a blank one (or another block) are its rows.
            case table
        }

        public var block: Block = .normal
        /// No line read yet: front matter can open.
        public var first = true
        /// The line before was paragraph text: `===` or `---` under it is a setext underline, and an indented line
        /// continues it rather than starting a code block.
        public var afterParagraph = false
        public var afterBlank = true
        /// Inside a list: an indented line is an item's text, not a code block.
        public var inList = false
        /// How many quotes the line before was in.
        public var quotes = 0

        public init() {}
        public static let start = LineState()
    }

    public enum Kind: Hashable, Sendable {
        case blank, paragraph, heading, setextUnderline, item, rule
        /// A code fence's opening or closing line; `code` is a line inside one, or an indented code block's.
        case fence, code
        case frontMatter, html, table
        /// A link reference or footnote definition (`[id]: …`).
        case definition
    }

    public struct Style: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let strong = Style(rawValue: 1)
        public static let emphasis = Style(rawValue: 2)
        public static let strikethrough = Style(rawValue: 4)
        public static let code = Style(rawValue: 8)
        public static let link = Style(rawValue: 16)
        /// Drawn faint: a done task's text, a setext heading's underline.
        public static let dimmed = Style(rawValue: 32)
    }

    public struct Span: Hashable, Sendable {
        public var range: NSRange
        public var style: Style
    }

    /// What is drawn in the place of some characters, which keep their width.
    public enum Drawing: Hashable, Sendable {
        /// A list item's `-`, `*` or `+`.
        case bullet
        /// A task's `[ ]`, `[x]` or `[X]`.
        case checkbox(done: Bool)
        /// A thematic break, across the editor.
        case rule
        /// A quote's `>`.
        case quoteBar
        /// Nothing: a task's bullet, so its box stands for the item.
        case blank
    }

    public struct Drawn: Hashable, Sendable {
        public var range: NSRange
        public var drawing: Drawing
    }

    /// A link's text and where it goes (`<…>` and escapes taken off); an image is the whole `![…](…)`, shown as source.
    public struct Link: Hashable, Sendable {
        public var text: NSRange
        public var destination: String
        /// The whole link, `[text](destination)` or `<https://…>`.
        public var range: NSRange
        public var isImage = false
    }

    /// A list item's marker and box.
    public struct Item: Hashable, Sendable {
        /// The `-`, `*` or `+`, or the number with its `.` or `)`.
        public var marker: NSRange
        /// An ordered item's number.
        public var number: Int?
        /// `-`, `*`, `+`, `.` or `)`.
        public var delimiter: UInt16
        /// The task box, `[ ]` or `[x]`, when it is a task.
        public var box: NSRange?
        public var done = false
        /// Where the item's text starts: after the marker, its spaces and the box.
        public var content: Int
        public var isOrdered: Bool { number != nil }
    }

    /// One line, read.
    public struct Line: Hashable, Sendable {
        public var kind: Kind = .blank
        /// 1 to 6 for a heading (ATX, or the text of a setext one), else 0.
        public var headingLevel = 0
        /// How many quotes the line is in.
        public var quoteDepth = 0
        public var item: Item?
        /// The line's text after its block syntax: a heading's title, an item's text, a paragraph line.
        public var content = NSRange(location: 0, length: 0)
        /// Characters Live Preview takes out of the line, in order and apart.
        public var hidden: [NSRange] = []
        public var spans: [Span] = []
        public var drawn: [Drawn] = []
        public var links: [Link] = []
        /// The column wrapped rows start at: an item's text, a quote's, a paragraph's indent.
        public var hang = 0
        /// Under a setext heading's text: its level (1 for `===`, 2 for `---`).
        public var setextAbove: Int?
        /// The line's length without its line break.
        public var length = 0

        public var taskBox: NSRange? { item?.box }
        public var isTask: Bool { item?.box != nil }
        /// Shown as written, always: nothing is hidden or drawn in it.
        public var isSource: Bool { [.fence, .code, .frontMatter, .html, .table, .definition].contains(kind) }

        public init() {}
    }

    /// Reads one line: `range` is the line as LineIndex gives it (with its line break, if it has one) in `text`, and
    /// `state` is where the line before left off.
    public static func scan(_ text: NSString, range: NSRange, after state: LineState) -> (line: Line, state: LineState) {
        var length = range.length
        while length > 0, [0x0A, 0x0D].contains(text.character(at: range.location + length - 1)) { length -= 1 }
        var units = [UInt16](repeating: 0, count: length)
        if length > 0 { text.getCharacters(&units, range: NSRange(location: range.location, length: length)) }
        var after = NSMaxRange(range)
        if after < text.length, text.character(at: after) == 0x0A, after == range.location + length { after += 1 }
        var reader = BlockReader(u: units, s: state, next: NextLine(text: text, start: after))
        return reader.read()
    }

    /// Every line of `text`, read from the top (the lines LineIndex counts).
    public static func lines(of text: String) -> [Line] {
        let source = text as NSString
        let index = LineIndex(text)
        var state = LineState.start
        var lines: [Line] = []
        lines.reserveCapacity(index.count)
        for line in 0..<index.count {
            let read = scan(source, range: index.range(ofLine: line), after: state)
            lines.append(read.line)
            state = read.state
        }
        return lines
    }
}

// MARK: characters

private let space: UInt16 = 0x20, tab: UInt16 = 0x09, backslash: UInt16 = 0x5C, backtick: UInt16 = 0x60
private let tilde: UInt16 = 0x7E, star: UInt16 = 0x2A, underscore: UInt16 = 0x5F, hash: UInt16 = 0x23
private let gt: UInt16 = 0x3E, lt: UInt16 = 0x3C, dash: UInt16 = 0x2D, plus: UInt16 = 0x2B, equals: UInt16 = 0x3D
private let pipe: UInt16 = 0x7C, open: UInt16 = 0x5B, close: UInt16 = 0x5D, paren: UInt16 = 0x28, closeParen: UInt16 = 0x29
private let bang: UInt16 = 0x21, dot: UInt16 = 0x2E, colon: UInt16 = 0x3A, quote: UInt16 = 0x22, apostrophe: UInt16 = 0x27
private let slash: UInt16 = 0x2F, question: UInt16 = 0x3F, atSign: UInt16 = 0x40

private func isSpace(_ c: UInt16) -> Bool { c == space || c == tab }
private func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
private func isASCIILetter(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }

/// `!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~`: what a backslash escapes.
private func isASCIIPunctuation(_ c: UInt16) -> Bool {
    (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
}

private let unicodePunctuation = CharacterSet.punctuationCharacters.union(.symbols)

/// The character a surrogate pair stands for.
private func scalar(lead: UInt16, trail: UInt16) -> Unicode.Scalar? {
    let high: UInt32 = (UInt32(lead) - 0xD800) << 10
    let low: UInt32 = UInt32(trail) - 0xDC00
    return Unicode.Scalar(0x10000 + high + low)
}

/// The character ending at `i` (nil at the start of the line, which counts as whitespace).
private func scalar(_ u: [UInt16], before i: Int) -> Unicode.Scalar? {
    guard i > 0 else { return nil }
    let last = u[i - 1]
    if UTF16.isTrailSurrogate(last), i >= 2, UTF16.isLeadSurrogate(u[i - 2]) { return scalar(lead: u[i - 2], trail: last) }
    return Unicode.Scalar(last) ?? "\u{FFFD}"
}

/// The character starting at `i` (nil at the end of the line, which counts as whitespace).
private func scalar(_ u: [UInt16], at i: Int) -> Unicode.Scalar? {
    guard i < u.count else { return nil }
    let first = u[i]
    if UTF16.isLeadSurrogate(first), i + 1 < u.count, UTF16.isTrailSurrogate(u[i + 1]) { return scalar(lead: first, trail: u[i + 1]) }
    return Unicode.Scalar(first) ?? "\u{FFFD}"
}

private func isWhitespace(_ s: Unicode.Scalar?) -> Bool {
    guard let s else { return true }
    return s.value < 0x80 ? (s.value == 0x20 || (0x09...0x0D).contains(s.value)) : CharacterSet.whitespacesAndNewlines.contains(s)
}

private func isPunctuation(_ s: Unicode.Scalar?) -> Bool {
    guard let s else { return false }
    return s.value < 0x80 ? isASCIIPunctuation(UInt16(s.value)) : unicodePunctuation.contains(s)
}

/// The line after the one being read, a character at a time, for the two kinds of line that look at it.
private struct NextLine {
    let text: NSString
    let start: Int

    func unit(_ i: Int) -> UInt16? {
        let at = start + i
        guard at < text.length else { return nil }
        let c = text.character(at: at)
        return c == 0x0A || c == 0x0D ? nil : c
    }

    /// The whole line, for a table's delimiter row (only read under a line with a `|` in it).
    func units(limit: Int) -> [UInt16] {
        var units: [UInt16] = []
        var i = 0
        while i < limit, let c = unit(i) {
            units.append(c)
            i += 1
        }
        return units
    }
}

// MARK: blocks

private struct BlockReader {
    let u: [UInt16]
    var s: MarkdownSyntax.LineState
    let next: NextLine
    var line = MarkdownSyntax.Line()

    typealias Syntax = MarkdownSyntax

    var isBlank: Bool { u.allSatisfy(isSpace) }

    mutating func read() -> (line: Syntax.Line, state: Syntax.LineState) {
        line.length = u.count
        let first = s.first
        s.first = false
        switch s.block {
        case .frontMatter(let marker):
            line.kind = .frontMatter
            if isFrontMatterLine(marker, closing: true) { s.block = .normal }
            return finish()
        case .htmlComment:
            line.kind = .html
            if find([dash, dash, gt], from: 0) != nil { s.block = .normal }
            return finish()
        case .htmlBlock(let until):
            if let until {
                line.kind = .html
                if contains(until) { s.block = .normal }
                return finish()
            }
            guard isBlank else {
                line.kind = .html
                return finish()
            }
            s.block = .normal
        case .fence(let marker, let count, let indent, let quotes):
            let quoted = quoteMarkers(limit: quotes)
            guard quoted.depth < quotes else {
                drawQuotes(quoted.positions)
                line.kind = closesFence(at: quoted.start, marker: marker, count: count, indent: indent) ? .fence : .code
                if line.kind == .fence { s.block = .normal }
                return finish()
            }
            s.block = .normal // the quote it was in ended, and the fence with it
        case .table:
            if !isBlank, !startsAnotherBlock() {
                line.kind = .table
                return finish()
            }
            s.block = .normal
        case .normal:
            break
        }
        if first, isFrontMatterLine(dash, closing: false) || isFrontMatterLine(plus, closing: false) {
            line.kind = .frontMatter
            s.block = .frontMatter(marker: u.first ?? dash)
            return finish()
        }
        if isBlank {
            line.kind = .blank
            return finish()
        }
        // A line too long to read shows as source.
        guard u.count <= Syntax.maxLineLength else {
            line.kind = .paragraph
            line.content = NSRange(location: 0, length: u.count)
            return finish(paragraph: true)
        }
        return readNormal()
    }

    /// The state after the line, from what it was. A block at the margin other than an item or paragraph text ends a list.
    mutating func finish(paragraph: Bool = false, margin: Bool = false) -> (line: Syntax.Line, state: Syntax.LineState) {
        if margin, line.kind != .item, line.kind != .blank, !paragraph { s.inList = false }
        s.afterBlank = line.kind == .blank
        s.afterParagraph = paragraph
        s.quotes = line.quoteDepth
        line.hidden = merged(line.hidden)
        return (line, s)
    }

    private func merged(_ ranges: [NSRange]) -> [NSRange] {
        guard ranges.count > 1 else { return ranges.filter { $0.length > 0 } }
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let last = result.last, NSMaxRange(last) >= range.location {
                result[result.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else {
                result.append(range)
            }
        }
        return result
    }

    mutating func readNormal() -> (line: Syntax.Line, state: Syntax.LineState) {
        let quoted = quoteMarkers(limit: .max)
        line.quoteDepth = quoted.depth
        drawQuotes(quoted.positions)
        var start = quoted.start
        while start < u.count, isSpace(u[start]) { start += 1 }
        let indent = column(of: start) - column(of: quoted.start)
        let quotesEnded = quoted.depth < s.quotes
        // After a blank line, a line at the margin that is not an item ends the list.
        if s.inList, s.afterBlank || quotesEnded, indent == 0, !isItemStart(at: start) { s.inList = false }
        if start >= u.count { // only quote markers
            line.kind = .blank
            return finish()
        }
        // An indented code block: not inside a list, and not continuing a paragraph.
        if indent >= 4, !s.afterParagraph, !s.inList {
            line.kind = .code
            return finish(margin: indent == 0)
        }
        if indent < 4 || s.inList, let fence = fenceOpening(at: start) {
            line.kind = .fence
            s.block = .fence(marker: fence.marker, count: fence.count, indent: indent, quotes: quoted.depth)
            return finish(margin: indent == 0)
        }
        if indent < 4, let level = atxLevel(at: start) {
            readHeading(level: level, markerStart: start, lineStart: quoted.start)
            return finish(margin: indent == 0)
        }
        if indent < 4, u[start] == lt, readHTMLBlock(at: start) {
            return finish(margin: indent == 0)
        }
        if indent < 4, s.afterParagraph, !s.inList, s.quotes == 0, quoted.depth == 0, let level = setextLevel(at: start) {
            line.kind = .setextUnderline
            line.setextAbove = level
            line.spans.append(.init(range: NSRange(location: start, length: u.count - start), style: .dimmed))
            return finish(margin: indent == 0)
        }
        if indent < 4, let rule = thematicBreak(at: start) {
            line.kind = .rule
            line.drawn.append(.init(range: rule, drawing: .rule))
            return finish(margin: indent == 0)
        }
        if indent < 4, find([pipe], from: start) != nil, isTableHeader(from: start) {
            line.kind = .table
            s.block = .table
            return finish(margin: indent == 0)
        }
        if indent < 4, !s.afterParagraph, isDefinition(at: start) {
            line.kind = .definition
            return finish(margin: indent == 0)
        }
        if indent < 4 || s.inList, readItem(at: start) {
            s.inList = true
            return finish(margin: indent == 0)
        }
        // Paragraph text, a setext heading's when the line under it is its underline.
        line.kind = .paragraph
        line.content = NSRange(location: start, length: u.count - start)
        line.hang = column(of: start)
        if quoted.depth == 0, !s.inList, let level = nextLineSetextLevel() {
            line.kind = .heading
            line.headingLevel = level
        }
        readInline(from: start)
        return finish(paragraph: true, margin: indent == 0)
    }

    // MARK: the parts of a line

    /// The tab-expanded column of a position (tab stops every 4).
    func column(of position: Int) -> Int {
        var column = 0
        for i in 0..<min(position, u.count) { column = u[i] == tab ? column + 4 - column % 4 : column + 1 }
        return column
    }

    func find(_ needle: [UInt16], from start: Int) -> Int? {
        guard !needle.isEmpty, u.count >= needle.count else { return nil }
        var i = start
        while i + needle.count <= u.count {
            if u[i] == needle[0], Array(u[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    /// Case-insensitive, for an HTML block's closing tag.
    func contains(_ text: String) -> Bool {
        String(decoding: u, as: UTF16.self).range(of: text, options: [.caseInsensitive, .literal]) != nil
    }

    /// The `>`s starting the line, each after up to 3 spaces and taking one space after it, up to `limit`.
    func quoteMarkers(limit: Int) -> (start: Int, depth: Int, positions: [Int]) {
        var i = 0, depth = 0, positions: [Int] = []
        while depth < limit {
            var j = i, spaces = 0
            while j < u.count, u[j] == space, spaces < 3 {
                j += 1
                spaces += 1
            }
            guard j < u.count, u[j] == gt else { break }
            positions.append(j)
            depth += 1
            i = j + 1
            if i < u.count, isSpace(u[i]) { i += 1 }
        }
        return (i, depth, positions)
    }

    mutating func drawQuotes(_ positions: [Int]) {
        line.quoteDepth = positions.count
        for position in positions { line.drawn.append(.init(range: NSRange(location: position, length: 1), drawing: .quoteBar)) }
        if let last = positions.last {
            line.hang = column(of: min(u.count, last + 2))
        }
    }

    /// `---` or `+++` alone on the line (`...` also closes YAML).
    func isFrontMatterLine(_ marker: UInt16, closing: Bool) -> Bool {
        var end = u.count
        while end > 0, isSpace(u[end - 1]) { end -= 1 }
        guard end == 3 else { return false }
        if u[0..<3].allSatisfy({ $0 == marker }) { return true }
        return closing && marker == dash && u[0..<3].allSatisfy { $0 == dot }
    }

    /// A line that starts another block, which ends a table.
    func startsAnotherBlock() -> Bool {
        var i = 0
        while i < u.count, isSpace(u[i]) { i += 1 }
        guard i < u.count, i < 4 else { return false }
        return u[i] == gt || atxLevel(at: i) != nil || fenceOpening(at: i) != nil || thematicBreak(at: i) != nil
    }

    func fenceOpening(at start: Int) -> (marker: UInt16, count: Int)? {
        guard start < u.count, u[start] == backtick || u[start] == tilde else { return nil }
        let marker = u[start]
        var end = start
        while end < u.count, u[end] == marker { end += 1 }
        guard end - start >= 3 else { return nil }
        // A backtick fence's info string has no backtick (or it would be a code span).
        if marker == backtick, u[end...].contains(backtick) { return nil }
        return (marker, end - start)
    }

    func closesFence(at quoteEnd: Int, marker: UInt16, count: Int, indent: Int) -> Bool {
        var i = quoteEnd
        while i < u.count, isSpace(u[i]) { i += 1 }
        guard column(of: i) - column(of: quoteEnd) < indent + 4 else { return false }
        var end = i
        while end < u.count, u[end] == marker { end += 1 }
        guard end - i >= count else { return false }
        return u[end...].allSatisfy(isSpace)
    }

    func atxLevel(at start: Int) -> Int? {
        var end = start
        while end < u.count, u[end] == hash { end += 1 }
        let level = end - start
        guard (1...6).contains(level), end == u.count || isSpace(u[end]) else { return nil }
        return level
    }

    /// `## Title ##`: the `## ` and the ` ##` are hidden, and so is the indent before it.
    mutating func readHeading(level: Int, markerStart: Int, lineStart: Int) {
        line.kind = .heading
        line.headingLevel = level
        var start = markerStart + level
        while start < u.count, isSpace(u[start]) { start += 1 }
        var end = u.count
        while end > start, isSpace(u[end - 1]) { end -= 1 }
        // A closing run of #s after a space (or the whole title).
        var closing = end
        while closing > start, u[closing - 1] == hash { closing -= 1 }
        if closing < end, closing == start || isSpace(u[closing - 1]) {
            var textEnd = closing
            while textEnd > start, isSpace(u[textEnd - 1]) { textEnd -= 1 }
            line.hidden.append(NSRange(location: textEnd, length: u.count - textEnd))
            end = textEnd
        }
        line.hidden.append(NSRange(location: lineStart, length: start - lineStart))
        line.content = NSRange(location: start, length: end - start)
        readInline(from: start, to: end)
    }

    func setextLevel(at start: Int) -> Int? {
        guard start < u.count, u[start] == equals || u[start] == dash else { return nil }
        let marker = u[start]
        var end = start
        while end < u.count, u[end] == marker { end += 1 }
        guard u[end...].allSatisfy(isSpace) else { return nil }
        return marker == equals ? 1 : 2
    }

    /// The line under this one is a setext underline (up to 3 spaces, then only `=` or only `-`).
    func nextLineSetextLevel() -> Int? {
        var i = 0
        while i < 3, next.unit(i) == space { i += 1 }
        guard let marker = next.unit(i), marker == equals || marker == dash else { return nil }
        while next.unit(i) == marker { i += 1 }
        while let c = next.unit(i), isSpace(c) { i += 1 }
        return next.unit(i) == nil ? (marker == equals ? 1 : 2) : nil
    }

    /// `---`, `***` or `___`, three or more with spaces between: the range from the first to the last.
    func thematicBreak(at start: Int) -> NSRange? {
        guard start < u.count, [dash, star, underscore].contains(u[start]) else { return nil }
        let marker = u[start]
        var count = 0, last = start
        for i in start..<u.count {
            if u[i] == marker {
                count += 1
                last = i
            } else if !isSpace(u[i]) {
                return nil
            }
        }
        return count >= 3 ? NSRange(location: start, length: last + 1 - start) : nil
    }

    /// `[id]: destination` or `[^note]: text`: shown as source. It can't interrupt a paragraph.
    func isDefinition(at start: Int) -> Bool {
        guard start < u.count, u[start] == open else { return false }
        var i = start + 1
        while i < u.count, u[i] != close {
            if u[i] == backslash { i += 1 }
            i += 1
        }
        return i > start + 1 && i + 1 < u.count && u[i + 1] == colon
    }

    // MARK: HTML blocks

    static let blockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup",
        "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame",
        "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link",
        "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "search", "section",
        "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul",
    ]
    static let rawTags = ["script", "pre", "style", "textarea"]

    /// An HTML block or comment starting the line: it shows as source until it ends (this line or later).
    mutating func readHTMLBlock(at start: Int) -> Bool {
        let rest = String(decoding: u[start...], as: UTF16.self)
        let lower = rest.lowercased()
        func ends(_ marker: String, after offset: Int) -> Bool {
            lower.range(of: marker, options: .literal, range: lower.index(lower.startIndex, offsetBy: offset)..<lower.endIndex) != nil
        }
        if lower.hasPrefix("<!--") {
            line.kind = .html
            if !ends("-->", after: 4) { s.block = .htmlComment }
            return true
        }
        for tag in Self.rawTags where lower.hasPrefix("<" + tag) {
            let after = lower.dropFirst(tag.count + 1).first
            guard after == nil || after == " " || after == ">" || after == "\t" else { continue }
            line.kind = .html
            if !ends("</" + tag + ">", after: 1) { s.block = .htmlBlock(until: "</" + tag + ">") }
            return true
        }
        for (opening, closing) in [("<?", "?>"), ("<![cdata[", "]]>")] where lower.hasPrefix(opening) {
            line.kind = .html
            if !ends(closing, after: opening.count) { s.block = .htmlBlock(until: closing) }
            return true
        }
        if lower.hasPrefix("<!"), lower.dropFirst(2).first?.isLetter == true {
            line.kind = .html
            if !ends(">", after: 2) { s.block = .htmlBlock(until: ">") }
            return true
        }
        // A block-level tag (it can interrupt a paragraph), or any complete tag alone on its line (it can't).
        let name = lower.dropFirst(lower.hasPrefix("</") ? 2 : 1).prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        let after = lower.dropFirst((lower.hasPrefix("</") ? 2 : 1) + name.count).first
        let tagEnds = after == nil || after == " " || after == ">" || after == "/" || after == "\t"
        let isBlockTag = !name.isEmpty && tagEnds && Self.blockTags.contains(String(name))
        let trimmed = lower.trimmingCharacters(in: .whitespaces)
        let isLoneTag = !name.isEmpty && tagEnds && !s.afterParagraph && trimmed.hasSuffix(">")
            && trimmed.dropFirst().firstIndex(of: "<") == nil
        guard isBlockTag || isLoneTag else { return false }
        line.kind = .html
        s.block = .htmlBlock(until: nil)
        return true
    }

    // MARK: tables

    /// A row with a `|` and, on the next line, a delimiter row with as many cells (`| --- | :-: |`).
    func isTableHeader(from start: Int) -> Bool {
        let row = cells(Array(u[start...]))
        guard row > 0 else { return false }
        let delimiter = next.units(limit: Syntax.maxLineLength)
        guard delimiter.contains(pipe) else { return false }
        var i = 0
        while i < delimiter.count, delimiter[i] == space { i += 1 }
        guard i < 4 else { return false }
        let body = Array(delimiter[i...])
        let allowed: Set<UInt16> = [pipe, dash, colon, space, tab]
        guard body.contains(dash), body.allSatisfy({ allowed.contains($0) }) else { return false }
        // Every cell of it is dashes, with a colon at either end.
        let parts = split(body).map { $0.filter { !isSpace($0) } }
        guard parts.allSatisfy({ part in
            var core = part[...]
            if core.first == colon { core = core.dropFirst() }
            if core.last == colon { core = core.dropLast() }
            return !core.isEmpty && core.allSatisfy { $0 == dash }
        }) else { return false }
        return parts.count == row
    }

    /// A row's cells, split at the `|`s that are not escaped or in a code span, without the leading and trailing ones.
    func split(_ row: [UInt16]) -> [[UInt16]] {
        var cells: [[UInt16]] = [[]]
        var i = 0, ticks = 0
        while i < row.count {
            let c = row[i]
            if c == backslash, i + 1 < row.count {
                cells[cells.count - 1] += [c, row[i + 1]]
                i += 2
                continue
            }
            if c == backtick { ticks = ticks == 0 ? 1 : 0 }
            if c == pipe, ticks == 0 {
                cells.append([])
            } else {
                cells[cells.count - 1].append(c)
            }
            i += 1
        }
        if let first = cells.first, first.allSatisfy(isSpace), cells.count > 1 { cells.removeFirst() }
        if let last = cells.last, last.allSatisfy(isSpace), cells.count > 1 { cells.removeLast() }
        return cells
    }

    func cells(_ row: [UInt16]) -> Int {
        guard row.contains(pipe) else { return 0 }
        return split(row).count
    }

    // MARK: list items

    /// The marker of an item at `start`: `-`, `*` or `+`, or up to 9 digits and `.` or `)`, then a space or the end.
    func itemMarker(at start: Int) -> (end: Int, number: Int?, delimiter: UInt16)? {
        guard start < u.count else { return nil }
        if [dash, star, plus].contains(u[start]) {
            let end = start + 1
            guard end == u.count || isSpace(u[end]) else { return nil }
            return (end, nil, u[start])
        }
        var end = start
        while end < u.count, isDigit(u[end]), end - start < 9 { end += 1 }
        guard end > start, end < u.count, u[end] == dot || u[end] == closeParen else { return nil }
        let number = Int(String(decoding: u[start..<end], as: UTF16.self)) ?? 0
        let delimiter = u[end]
        end += 1
        guard end == u.count || isSpace(u[end]) else { return nil }
        return (end, number, delimiter)
    }

    func isItemStart(at start: Int) -> Bool { itemMarker(at: start) != nil && thematicBreak(at: start) == nil }

    mutating func readItem(at start: Int) -> Bool {
        guard let marker = itemMarker(at: start) else { return false }
        var content = marker.end
        while content < u.count, isSpace(u[content]) { content += 1 }
        let empty = content >= u.count
        // Only a non-empty item interrupts a paragraph, and an ordered one only when it starts at 1.
        if s.afterParagraph, !s.inList, empty || (marker.number.map { $0 != 1 } ?? false) { return false }
        // Five or more spaces after the marker: the text is one space in (the rest is an indented code block's).
        if !empty, column(of: content) - column(of: marker.end) > 4 { content = marker.end + 1 }
        var item = Syntax.Item(marker: NSRange(location: start, length: marker.end - start), number: marker.number,
                               delimiter: marker.delimiter, content: content)
        // A task: `[ ]`, `[x]` or `[X]` after the marker, then a space or the end.
        if content + 2 < u.count, u[content] == open, u[content + 2] == close, [space, 0x78, 0x58].contains(u[content + 1]),
           content + 3 == u.count || isSpace(u[content + 3]) {
            item.box = NSRange(location: content, length: 3)
            item.done = u[content + 1] != space
            var text = content + 3
            while text < u.count, isSpace(u[text]) { text += 1 }
            item.content = text
        }
        line.kind = .item
        line.item = item
        line.hang = item.content < u.count || item.box != nil ? column(of: item.content) : column(of: marker.end) + 1
        line.content = NSRange(location: item.content, length: u.count - item.content)
        if let box = item.box {
            line.drawn.append(.init(range: box, drawing: .checkbox(done: item.done)))
            if item.number == nil { line.drawn.append(.init(range: item.marker, drawing: .blank)) }
        } else if item.number == nil {
            line.drawn.append(.init(range: item.marker, drawing: .bullet))
        }
        line.drawn.sort { $0.range.location < $1.range.location }
        readInline(from: item.content)
        if item.done, line.content.length > 0 {
            var end = u.count
            while end > item.content, isSpace(u[end - 1]) { end -= 1 }
            line.spans.append(.init(range: NSRange(location: item.content, length: end - item.content), style: [.strikethrough, .dimmed]))
        }
        return true
    }

    // MARK: inline

    mutating func readInline(from start: Int, to end: Int? = nil) {
        var inline = InlineReader(u: u, start: start, end: end ?? u.count)
        inline.read()
        line.hidden += inline.hidden
        line.spans += inline.spans
        line.links += inline.links
    }
}

// MARK: inline syntax

/// One line's inline syntax, between `start` and `end`, in CommonMark's order.
private struct InlineReader {
    let u: [UInt16]
    let start: Int
    let end: Int
    var hidden: [NSRange] = []
    var spans: [MarkdownSyntax.Span] = []
    var links: [MarkdownSyntax.Link] = []

    /// What each character is to the later passes.
    enum Mark: UInt8 { case plain, literal, taken }
    var marks: [Mark]
    /// Link texts: emphasis inside one pairs only inside it.
    var linkTexts: [NSRange] = []

    init(u: [UInt16], start: Int, end: Int) {
        self.u = u
        self.start = start
        self.end = end
        marks = Array(repeating: .plain, count: u.count)
    }

    mutating func read() {
        guard start < end else { return }
        readCodeSpansAndEscapes()
        readLinks()
        readEmphasis()
    }

    mutating func take(_ range: Range<Int>) {
        for i in range where i < marks.count { marks[i] = .taken }
    }

    // MARK: code spans, escapes, autolinks, inline HTML

    mutating func readCodeSpansAndEscapes() {
        var i = start
        while i < end {
            let c = u[i]
            if c == backslash, i + 1 < end, isASCIIPunctuation(u[i + 1]) {
                hidden.append(NSRange(location: i, length: 1))
                marks[i] = .taken
                marks[i + 1] = .literal
                i += 2
                continue
            }
            if c == backtick {
                var runEnd = i
                while runEnd < end, u[runEnd] == backtick { runEnd += 1 }
                let count = runEnd - i
                if let closing = closingRun(of: count, from: runEnd) {
                    hidden.append(NSRange(location: i, length: count))
                    hidden.append(NSRange(location: closing, length: count))
                    if closing > runEnd { spans.append(.init(range: NSRange(location: runEnd, length: closing - runEnd), style: .code)) }
                    take(i..<(closing + count))
                    i = closing + count
                } else {
                    for j in i..<runEnd { marks[j] = .literal }
                    i = runEnd
                }
                continue
            }
            if c == lt, let after = readAngle(at: i) {
                i = after
                continue
            }
            i += 1
        }
    }

    /// Where a run of exactly `count` backticks starts after `from`, if one does on the line.
    func closingRun(of count: Int, from: Int) -> Int? {
        var i = from
        while i < end {
            guard u[i] == backtick else {
                i += 1
                continue
            }
            var runEnd = i
            while runEnd < end, u[runEnd] == backtick { runEnd += 1 }
            if runEnd - i == count { return i }
            i = runEnd
        }
        return nil
    }

    /// `<https://…>` or `<a@b.c>`: an autolink, its `<` and `>` hidden; `<tag …>` or `<!-- … -->`: inline HTML, shown as
    /// source. Returns where reading goes on, or nil for a plain `<`.
    mutating func readAngle(at i: Int) -> Int? {
        var j = i + 1
        guard j < end else { return nil }
        // A URI: a scheme of 2 to 32 characters, a colon, then no space, `<` or `>`.
        if isASCIILetter(u[j]) {
            var k = j + 1
            while k < end, isASCIILetter(u[k]) || isDigit(u[k]) || [plus, dot, dash].contains(u[k]) { k += 1 }
            if k < end, u[k] == colon, (2...32).contains(k - j) {
                var m = k + 1
                while m < end, u[m] != gt, u[m] != lt, u[m] > 0x20 { m += 1 }
                if m < end, u[m] == gt {
                    autolink(i, m, destination: String(decoding: u[(i + 1)..<m], as: UTF16.self))
                    return m + 1
                }
            }
        }
        // An email address.
        var sign = j
        let local: Set<UInt16> = Set(".!#$%&'*+/=?^_`{|}~-".utf16)
        while sign < end, isASCIILetter(u[sign]) || isDigit(u[sign]) || local.contains(u[sign]) { sign += 1 }
        if sign > j, sign < end, u[sign] == atSign {
            var m = sign + 1
            while m < end, isASCIILetter(u[m]) || isDigit(u[m]) || u[m] == dash || u[m] == dot { m += 1 }
            if m > sign + 1, m < end, u[m] == gt, u[sign + 1] != dot, u[m - 1] != dot {
                autolink(i, m, destination: "mailto:" + String(decoding: u[(i + 1)..<m], as: UTF16.self))
                return m + 1
            }
        }
        // Inline HTML: a tag, a closing tag, a comment, a processing instruction or a declaration.
        if u[j] == slash { j += 1 }
        guard j < end, isASCIILetter(u[j]) || u[j] == bang || u[j] == question else { return nil }
        let closing = u[i + 1] == bang && i + 3 < end && u[i + 2] == dash && u[i + 3] == dash ? [dash, dash, gt] : [gt]
        var m = j
        while m + closing.count <= end {
            if Array(u[m..<(m + closing.count)]) == closing {
                take(i..<(m + closing.count))
                return m + closing.count
            }
            m += 1
        }
        return nil
    }

    mutating func autolink(_ opening: Int, _ closing: Int, destination: String) {
        hidden.append(NSRange(location: opening, length: 1))
        hidden.append(NSRange(location: closing, length: 1))
        let text = NSRange(location: opening + 1, length: closing - opening - 1)
        spans.append(.init(range: text, style: .link))
        links.append(.init(text: text, destination: destination, range: NSRange(location: opening, length: closing + 1 - opening)))
        take(opening..<(closing + 1))
    }

    // MARK: links

    /// `[text](destination "title")`: the `[` and the `](…)` hidden, the text a link. `![alt](src)` is an image, shown as
    /// source. Reference links, footnotes and `[text]` alone stay as written.
    mutating func readLinks() {
        var openers: [(position: Int, image: Bool, active: Bool)] = []
        var i = start
        while i < end {
            guard marks[i] == .plain else {
                i += 1
                continue
            }
            if u[i] == open {
                let image = i > start && u[i - 1] == bang && marks[i - 1] == .plain
                openers.append((i, image, true))
            } else if u[i] == close, let opener = openers.popLast() {
                if opener.active, i + 1 < end, u[i + 1] == paren, let tail = linkTail(from: i + 2) {
                    let text = NSRange(location: opener.position + 1, length: i - opener.position - 1)
                    if opener.image {
                        let whole = NSRange(location: opener.position - 1, length: tail.end - opener.position + 1)
                        links.append(.init(text: whole, destination: tail.destination, range: whole, isImage: true))
                        take((opener.position - 1)..<tail.end)
                    } else {
                        hidden.append(NSRange(location: opener.position, length: 1))
                        hidden.append(NSRange(location: i, length: tail.end - i))
                        spans.append(.init(range: text, style: .link))
                        let whole = NSRange(location: opener.position, length: tail.end - opener.position)
                        links.append(.init(text: text, destination: tail.destination, range: whole))
                        linkTexts.append(text)
                        marks[opener.position] = .taken
                        take(i..<tail.end)
                        // A link holds no other link: the brackets before it can't open one now.
                        for k in openers.indices where !openers[k].image { openers[k].active = false }
                    }
                    i = tail.end
                    continue
                }
            }
            i += 1
        }
    }

    /// After `](`: spaces, a destination (`<…>`, or without spaces and with balanced parentheses), an optional title in
    /// quotes or parentheses, spaces and `)`. Returns where the link ends and its destination.
    func linkTail(from start: Int) -> (end: Int, destination: String)? {
        var i = start
        func skipSpaces() { while i < end, isSpace(u[i]) { i += 1 } }
        skipSpaces()
        var destination: [UInt16] = []
        if i < end, u[i] == lt {
            i += 1
            while i < end, u[i] != gt {
                if u[i] == lt { return nil }
                if u[i] == backslash, i + 1 < end, isASCIIPunctuation(u[i + 1]) { i += 1 }
                destination.append(u[i])
                i += 1
            }
            guard i < end else { return nil }
            i += 1
        } else {
            var depth = 0
            while i < end, u[i] > 0x20 {
                if u[i] == backslash, i + 1 < end, isASCIIPunctuation(u[i + 1]) {
                    destination.append(u[i + 1])
                    i += 2
                    continue
                }
                if u[i] == paren { depth += 1 }
                if u[i] == closeParen {
                    if depth == 0 { break }
                    depth -= 1
                }
                destination.append(u[i])
                i += 1
            }
            guard depth == 0 else { return nil }
        }
        let beforeTitle = i
        skipSpaces()
        if i < end, [quote, apostrophe, paren].contains(u[i]) {
            guard i > beforeTitle || destination.isEmpty else { return nil }
            let closer = u[i] == paren ? closeParen : u[i]
            i += 1
            while i < end, u[i] != closer {
                if u[i] == backslash { i += 1 }
                i += 1
            }
            guard i < end else { return nil }
            i += 1
            skipSpaces()
        }
        guard i < end, u[i] == closeParen else { return nil }
        return (i + 1, String(decoding: destination, as: UTF16.self))
    }

    // MARK: emphasis

    /// A run of `*`, `_` or `~~`, and how much of it is still to pair: openers give their inner end, closers their inner start.
    struct Delimiter {
        let char: UInt16
        let length: Int
        let canOpen: Bool
        let canClose: Bool
        var left: Int
        var right: Int
        var remaining: Int { right - left }
    }

    /// CommonMark's delimiter runs: a run is left-flanking when what follows is not whitespace, and is not punctuation
    /// unless whitespace or punctuation comes before it (right-flanking the other way round). `*` opens when
    /// left-flanking and closes when right-flanking; `_` also not inside a word. Each group pairs on its own: the line
    /// outside links, and each link's text.
    mutating func readEmphasis() {
        var groups: [Int: [Delimiter]] = [:]
        var i = start
        while i < end {
            let c = u[i]
            guard marks[i] == .plain, c == star || c == underscore || c == tilde else {
                i += 1
                continue
            }
            var runEnd = i
            while runEnd < end, u[runEnd] == c, marks[runEnd] == .plain { runEnd += 1 }
            let before = scalar(u, before: i), after = scalar(u, at: runEnd)
            let leftFlanking = !isWhitespace(after) && (!isPunctuation(after) || isWhitespace(before) || isPunctuation(before))
            let rightFlanking = !isWhitespace(before) && (!isPunctuation(before) || isWhitespace(after) || isPunctuation(after))
            var canOpen = leftFlanking, canClose = rightFlanking
            if c == underscore {
                canOpen = leftFlanking && (!rightFlanking || isPunctuation(before))
                canClose = rightFlanking && (!leftFlanking || isPunctuation(after))
            }
            // Strikethrough is two tildes, no more and no fewer.
            if c != tilde || runEnd - i == 2 {
                let group = linkTexts.firstIndex { NSLocationInRange(i, $0) } ?? -1
                groups[group, default: []].append(Delimiter(char: c, length: runEnd - i, canOpen: canOpen, canClose: canClose,
                                                            left: i, right: runEnd))
            }
            i = runEnd
        }
        for key in groups.keys.sorted() { pair(groups[key] ?? []) }
    }

    /// CommonMark's "process emphasis" over one group: each closer, left to right, pairs with the nearest opener of its
    /// kind before it; two characters from each make bold, one italic. Delimiters between the pair are left as text.
    mutating func pair(_ list: [Delimiter]) {
        var list = list
        // Below these, no opener for that kind of closer was found: later searches stop there.
        var bottoms: [Int: Int] = [:]
        for closer in list.indices where list[closer].canClose {
            while list[closer].remaining > 0 {
                let c = list[closer]
                let key = Int(c.char) << 3 | (c.canOpen ? 4 : 0) | c.length % 3
                let floor = bottoms[key] ?? -1
                var found: Int?
                var j = closer - 1
                while j > floor {
                    let o = list[j]
                    if o.char == c.char, o.canOpen, o.remaining > 0, isPair(o, c) {
                        found = j
                        break
                    }
                    j -= 1
                }
                guard let opener = found else {
                    bottoms[key] = closer - 1
                    break
                }
                let count = c.char == tilde ? 2 : (list[opener].remaining >= 2 && c.remaining >= 2 ? 2 : 1)
                list[opener].right -= count
                hidden.append(NSRange(location: list[opener].right, length: count))
                hidden.append(NSRange(location: list[closer].left, length: count))
                let content = NSRange(location: list[opener].right + count, length: list[closer].left - list[opener].right - count)
                let style: MarkdownSyntax.Style = c.char == tilde ? .strikethrough : count == 2 ? .strong : .emphasis
                if content.length > 0 { spans.append(.init(range: content, style: style)) }
                list[closer].left += count
                for k in (opener + 1)..<closer { list[k].right = list[k].left }
            }
        }
    }

    /// Whether an opener and a closer of one character pair: tildes only two with two, and the rule of three (when either
    /// could both open and close, their lengths may not add up to a multiple of 3 unless both are multiples of 3).
    func isPair(_ opener: Delimiter, _ closer: Delimiter) -> Bool {
        if closer.char == tilde { return opener.remaining == 2 && closer.remaining == 2 }
        guard opener.canClose || closer.canOpen else { return true }
        return (opener.length + closer.length) % 3 != 0 || (opener.length % 3 == 0 && closer.length % 3 == 0)
    }
}

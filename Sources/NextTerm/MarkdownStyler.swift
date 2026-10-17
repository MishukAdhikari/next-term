import AppKit
import NextTermCore

/// A Markdown file's look in its editor, from what MarkdownSyntax reads in each line: headings in the editor's own font
/// at 1.5, 1.3 and 1.15 times its size (bold, as are the levels after them), bold and italic by the font's own traits,
/// struck text, code spans on a tint, and each item's wrapped rows under its text. All of it is attributes of the text
/// storage (no undo step, never the dirty flag, never a byte on disk), set in one edit batch a slice, so the grammar's
/// colours (the layout manager's temporary attributes) stay as they are. A code span's tint is drawn behind it from the
/// lines as read (CodeLayoutManager), never an attribute: the layout manager's own attributes cannot change inside the
/// storage's batch (it would make their glyphs while the storage is being edited, and raise), and setting one makes
/// the glyphs of text that may never be shown, which would double each slice of a long file.
///
/// Lines are read and styled in 8 ms slices from the top (the lines on screen first, when the slices have not reached
/// them), so a long file never holds up typing; a line that reads as plain text and still has the attributes it opened
/// with is left alone, so most of a long file costs only its reading. An edit reads again from the line before it
/// (which looks at the line after it, for a setext heading or a table) until a line ends in the state it ended in
/// before, so a keystroke restyles its own line, and a fence opened by typing restyles onwards in slices. Only a line
/// whose reading changed is styled again. Typed text takes the attributes of the text before it, and its line's
/// restyle, right after, gives each character its own. A command reads the lines it needs at once, styled or not.
final class MarkdownStyler {
    static let sliceBudget: TimeInterval = 0.008
    /// A heading's size, by level, as a multiple of the editor's font size.
    static let headingScales: [CGFloat] = [1, 1.5, 1.3, 1.15, 1, 1, 1]
    /// Link text, when no grammar colours it (the highlighting bundle is missing).
    static let linkColor = NSColor(hex: 0x548AF7)

    private let storage: NSTextStorage
    private weak var layoutManager: NSLayoutManager?
    private let index: () -> LineIndex
    /// Where each line left off (nil until it is read), and each line as read.
    private var ends: [MarkdownSyntax.LineState?]
    private var lines: [MarkdownSyntax.Line?]
    /// The storage holds a line in the base attributes (as opened, or after a new font): a plain line needs nothing.
    private var baseOnStorage: [Bool]
    /// Lines before this are read and styled.
    private var validUpTo = 0
    /// Lines up to here are read again even if their state matches: an edit changed them.
    private var mustRedoThrough = -1
    /// Where a pass still spreading down the file had got to when an edit above it started another, the nearest last:
    /// from each, the lines were read against the state from before, so a pass that finds a line ending as it did goes
    /// on from the next of these, never past it.
    private var stops: [Int] = []
    /// The states lines start in, read ahead of the slices for a command or the lines on screen: the first is line
    /// `aheadFrom`'s. Right until an edit above them (the slices read the same), and dropped once the slices pass them.
    private var aheadFrom = 0
    private var aheadStates: [MarkdownSyntax.LineState] = []
    private var scheduled = false
    /// Without a grammar, links get their colour here.
    private let colorsLinks: Bool

    var fonts: MarkdownFonts
    /// The paragraph style for a line's wrap column and heading level: the editor's, with its tab stops and heights.
    let paragraphStyle: (_ hang: Int, _ heading: Int) -> NSParagraphStyle
    /// Lines whose reading changed, or that were read for the first time and hide or draw something: Live Preview
    /// makes their glyphs again (a line laid out before it was read showed its syntax).
    var onLinesChanged: ((ClosedRange<Int>) -> Void)?
    /// The file's own markers, for the formatting commands (read once, from the text it opened with).
    let style: MarkdownStyle

    init(storage: NSTextStorage, layoutManager: NSLayoutManager, font: NSFont, colorsLinks: Bool,
         index: @escaping () -> LineIndex, paragraphStyle: @escaping (_ hang: Int, _ heading: Int) -> NSParagraphStyle) {
        self.storage = storage
        self.layoutManager = layoutManager
        self.index = index
        self.paragraphStyle = paragraphStyle
        self.colorsLinks = colorsLinks
        fonts = MarkdownFonts(base: font)
        style = MarkdownStyle.detect(in: storage.string)
        let count = index().count
        ends = Array(repeating: nil, count: count)
        lines = Array(repeating: nil, count: count)
        baseOnStorage = Array(repeating: false, count: count)
        mustRedoThrough = count - 1
    }

    /// Lines still to read (0 when the whole file is styled), for the self-test.
    var pendingLines: Int { lines.count - validUpTo }

    /// The line as last read, if it was: for drawing, which never reads.
    func readLine(_ number: Int) -> MarkdownSyntax.Line? {
        lines.indices.contains(number) ? lines[number] : nil
    }

    /// The code spans in a range of the text, in order, from the lines as last read: drawn on a tint behind their text,
    /// in Live Preview and in Source, and only once they are on screen.
    func codeSpans(in range: NSRange) -> [NSRange] {
        let index = self.index()
        guard index.count == lines.count, index.count > 0, range.location <= index.length else { return [] }
        let first = index.line(at: range.location)
        let last = min(index.line(at: max(range.location, NSMaxRange(range) - 1)), index.count - 1)
        var spans: [NSRange] = []
        for number in first...last {
            guard let line = lines[number] else { continue }
            let start = index.starts[number]
            for span in line.spans where span.style.contains(.code) && NSMaxRange(span.range) <= line.length {
                let run = NSRange(location: start + span.range.location, length: span.range.length)
                // Spans that touch are one tint (bold code beside plain code).
                if let previous = spans.last, NSMaxRange(previous) == run.location {
                    spans[spans.count - 1].length += run.length
                } else {
                    spans.append(run)
                }
            }
        }
        return spans
    }

    /// A line as read now, for a command. Where the slices have not reached it yet, the lines before it are read for
    /// their state only (reading is quick, styling is the slow part, and the states are kept for the next line asked
    /// for), so a command never waits for the styling.
    func line(_ number: Int) -> MarkdownSyntax.Line {
        let index = self.index()
        guard number < index.count else { return MarkdownSyntax.Line() }
        let text = storage.string as NSString
        guard index.count == lines.count else {
            let before = ends.indices.contains(number - 1) ? ends[number - 1] ?? MarkdownSyntax.LineState() : MarkdownSyntax.LineState()
            return MarkdownSyntax.scan(text, range: index.range(ofLine: number), after: before).line
        }
        if number < validUpTo, let line = lines[number] { return line }
        return MarkdownSyntax.scan(text, range: index.range(ofLine: number), after: state(before: number, text, index)).line
    }

    /// The state a line starts in: the slices' where they have read, else read on from the last state known.
    private func state(before number: Int, _ text: NSString, _ index: LineIndex) -> MarkdownSyntax.LineState {
        if number <= validUpTo { return number > 0 ? ends[number - 1] ?? MarkdownSyntax.LineState() : MarkdownSyntax.LineState() }
        if aheadStates.isEmpty || number < aheadFrom {
            aheadFrom = validUpTo
            aheadStates = [state(before: validUpTo, text, index)]
        }
        while aheadFrom + aheadStates.count <= number {
            let line = aheadFrom + aheadStates.count - 1
            aheadStates.append(MarkdownSyntax.scan(text, range: index.range(ofLine: line), after: aheadStates[aheadStates.count - 1]).state)
        }
        return aheadStates[number - aheadFrom]
    }

    /// The lines on screen, styled now when the slices have not reached them (a new font, a file opened deep in): the
    /// lines above are read for their state only, and the slices then go on from where they were and find these as
    /// read. Only where every line is to be read again anyway, so no match further up can skip the lines below these.
    func styleFirst(_ visible: ClosedRange<Int>) {
        let index = self.index()
        guard index.count == lines.count, visible.lowerBound > validUpTo, visible.upperBound < lines.count,
              visible.upperBound <= mustRedoThrough, lines[visible.lowerBound] == nil || lines[visible.upperBound] == nil else { return }
        let text = storage.string as NSString
        var state = state(before: visible.lowerBound, text, index)
        var changed: ClosedRange<Int>?
        storage.beginEditing()
        for number in visible {
            let range = index.range(ofLine: number)
            let (line, end) = MarkdownSyntax.scan(text, range: range, after: state)
            if store(line, end, at: number, range) { changed = changed.map { $0.lowerBound...number } ?? number...number }
            state = end
        }
        storage.endEditing()
        if let changed { onLinesChanged?(changed) }
    }

    /// Every line, read: the slices still to come are done now (Go to Heading lists them all).
    func allLines() -> [MarkdownSyntax.Line] {
        while validUpTo < lines.count, index().count == lines.count { run() }
        let read = lines.compactMap { $0 }
        return read.count == index().count ? read : MarkdownSyntax.lines(of: storage.string)
    }

    /// Lines `old` (as they were) became lines `old.lowerBound...newLast`. Call from the document's edit callback, with
    /// the line index already updated.
    func textEdited(_ old: ClosedRange<Int>, newLast: Int) {
        let count = index().count
        let added = newLast - old.lowerBound + 1
        if ends.indices.contains(old.lowerBound), old.upperBound < ends.count, added > 0 {
            ends.replaceSubrange(old, with: Array(repeating: nil, count: added))
            lines.replaceSubrange(old, with: Array(repeating: nil, count: added))
            baseOnStorage.replaceSubrange(old, with: Array(repeating: false, count: added))
        }
        guard ends.count == count else { return restyleAll(storageIsBase: false) }
        let shift = added - old.count
        // A pass still spreading had got this far: from here on the lines were read against the state from before, so a
        // later pass that finds a line ending as it did above here goes on from here. (The lines between the edit and
        // here were read from the new state, and a match among them still skips them.)
        stops = stops.compactMap { $0 > old.upperBound ? $0 + shift : $0 < old.lowerBound ? $0 : nil }
        if validUpTo > old.upperBound, validUpTo + shift < count, stops.last != validUpTo + shift { stops.append(validUpTo + shift) }
        // The states read ahead hold up to the line before the edited one (whose reading looks at the edited line).
        if old.lowerBound <= aheadFrom {
            aheadStates = []
        } else if old.lowerBound - aheadFrom < aheadStates.count {
            aheadStates.removeSubrange((old.lowerBound - aheadFrom)...)
        }
        if validUpTo > mustRedoThrough {
            mustRedoThrough = -1 // the last edit's lines are done: only this one's must be redone
        } else if mustRedoThrough > old.upperBound {
            mustRedoThrough += shift
        }
        mustRedoThrough = max(mustRedoThrough, newLast)
        // From the line before: it looks at the edited one.
        validUpTo = min(validUpTo, max(0, old.lowerBound - 1))
    }

    /// Everything read and styled again: after a new font or line height reset the storage to the base attributes
    /// (`storageIsBase`), or when the lines lost count.
    func restyleAll(storageIsBase: Bool) {
        let count = index().count
        ends = Array(repeating: nil, count: count)
        lines = Array(repeating: nil, count: count)
        baseOnStorage = Array(repeating: storageIsBase, count: count)
        validUpTo = 0
        mustRedoThrough = count - 1
        stops = []
        aheadStates = []
        run()
    }

    /// Reads and styles what is pending, within one slice, then goes on in later turns of the run loop.
    func run() {
        let index = self.index()
        guard index.count == lines.count else { return restyleAll(storageIsBase: false) }
        let text = storage.string as NSString
        let deadline = Date().addingTimeInterval(Self.sliceBudget)
        var changed: ClosedRange<Int>?
        storage.beginEditing()
        while validUpTo < lines.count {
            let number = validUpTo
            let before = number > 0 ? ends[number - 1] ?? MarkdownSyntax.LineState() : MarkdownSyntax.LineState()
            let range = index.range(ofLine: number)
            let (line, end) = MarkdownSyntax.scan(text, range: range, after: before)
            let unchanged = number > mustRedoThrough && ends[number] == end
            if store(line, end, at: number, range) {
                changed = changed.map { min($0.lowerBound, number)...max($0.upperBound, number) } ?? number...number
            }
            while let stop = stops.last, stop <= number { stops.removeLast() }
            validUpTo = number + 1
            if unchanged {
                // Every line after ended as it did before: already right, down to where an unfinished pass stopped (a
                // line not read yet is never past mustRedoThrough).
                validUpTo = stops.last ?? lines.count
            }
            if Date() > deadline { break }
        }
        storage.endEditing()
        if !aheadStates.isEmpty, validUpTo >= aheadFrom + aheadStates.count - 1 { aheadStates = [] }
        if let changed { onLinesChanged?(changed) }
        if validUpTo < lines.count { schedule() }
    }

    /// A line as read now, styled again when its reading changed. True when Live Preview must make its glyphs again:
    /// its reading changed, or it was read for the first time and hides or draws something.
    private func store(_ line: MarkdownSyntax.Line, _ end: MarkdownSyntax.LineState, at number: Int, _ range: NSRange) -> Bool {
        var remake = false
        if lines[number] != line {
            let plain = line.headingLevel == 0 && line.hang == 0 && line.spans.isEmpty
            if !(plain && lines[number] == nil && baseOnStorage[number]) { apply(line, at: range) }
            baseOnStorage[number] = false
            remake = lines[number] != nil || !line.hidden.isEmpty || !line.drawn.isEmpty
        }
        ends[number] = end
        lines[number] = line
        return remake
    }

    private func schedule(after delay: TimeInterval = 0) {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            // A line an input method is composing in keeps its look until the text is committed (textDidChange goes on
            // then); the slices wait.
            if self.layoutManager?.firstTextView?.hasMarkedText() == true { return self.schedule(after: 0.1) }
            self.run()
        }
    }

    /// One line's attributes from scratch: the base font (a heading's for a heading line), its paragraph style and (with
    /// no grammar) colour, then its spans' fonts, strikethrough and link colour.
    private func apply(_ line: MarkdownSyntax.Line, at range: NSRange) {
        guard range.length > 0 else { return }
        let heading = line.headingLevel
        storage.addAttribute(.font, value: fonts.font(heading: heading), range: range)
        storage.addAttribute(.paragraphStyle, value: paragraphStyle(line.hang, heading), range: range)
        storage.removeAttribute(.strikethroughStyle, range: range)
        if colorsLinks, let color = EditorDocument.attributes[.foregroundColor] { storage.addAttribute(.foregroundColor, value: color, range: range) }
        guard !line.spans.isEmpty else { return }
        // Each character's style: spans can nest (`***x***` is bold inside italic).
        var styles = [MarkdownSyntax.Style](repeating: [], count: line.length)
        for span in line.spans where NSMaxRange(span.range) <= line.length {
            for i in span.range.location..<NSMaxRange(span.range) { styles[i].formUnion(span.style) }
        }
        var start = 0
        while start < styles.count {
            let style = styles[start]
            var end = start + 1
            while end < styles.count, styles[end] == style { end += 1 }
            apply(style, to: NSRange(location: range.location + start, length: end - start), heading: heading)
            start = end
        }
    }

    /// One run of characters in the same style.
    private func apply(_ style: MarkdownSyntax.Style, to run: NSRange, heading: Int) {
        let strong = style.contains(.strong), emphasis = style.contains(.emphasis)
        if strong || emphasis { storage.addAttribute(.font, value: fonts.font(heading: heading, strong: strong, emphasis: emphasis), range: run) }
        if style.contains(.strikethrough) { storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run) }
        if style.contains(.link), colorsLinks { storage.addAttribute(.foregroundColor, value: Self.linkColor, range: run) }
    }
}

/// The editor's font as Markdown needs it: headings larger, and bold and italic by the family's own faces (an upright
/// face slanted when the family has no italic).
final class MarkdownFonts {
    let base: NSFont
    private var cache: [Int: NSFont] = [:]

    init(base: NSFont) {
        self.base = base
    }

    func font(heading: Int, strong: Bool = false, emphasis: Bool = false) -> NSFont {
        let level = min(max(heading, 0), 6)
        let key = level << 2 | (strong ? 1 : 0) | (emphasis ? 2 : 0)
        if let font = cache[key] { return font }
        var font = base
        let scale = MarkdownStyler.headingScales[level]
        if scale != 1 { font = NSFont(descriptor: font.fontDescriptor, size: base.pointSize * scale) ?? font }
        if level > 0 || strong { font = Self.font(font, with: .bold) }
        if emphasis { font = Self.font(font, with: .italic) }
        cache[key] = font
        return font
    }

    /// The face of the font's family with a trait. The system's SF Mono is no installed family, so its faces come
    /// from its descriptor; without a bold face the font stays as it is, and without an italic one it is slanted.
    static func font(_ font: NSFont, with trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        if font.fontDescriptor.symbolicTraits.contains(trait) { return font }
        let converted = NSFontManager.shared.convert(font, toHaveTrait: trait == .bold ? .boldFontMask : .italicFontMask)
        if converted.fontDescriptor.symbolicTraits.contains(trait) { return converted }
        let traits = font.fontDescriptor.symbolicTraits.union(trait)
        if let made = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize),
           made.fontDescriptor.symbolicTraits.contains(trait) {
            return made
        }
        guard trait == .italic else { return font }
        let size = font.pointSize
        let slant = AffineTransform(m11: size, m12: 0, m21: size * 0.2, m22: size, tX: 0, tY: 0)
        return NSFont(descriptor: font.fontDescriptor, textTransform: slant) ?? font
    }
}

/// A Markdown file's line heights: a heading's line is as tall as its font (its paragraph style says how tall), the text
/// centred in it as on every other line. Live Preview's hidden characters are made null glyphs here too
/// (MarkdownPreview.swift). Every other file keeps LineSpacing's one height and its glyphs as they are.
final class MarkdownSpacing: LineSpacing {
    /// The characters to hide in a range of the text, in order (Live Preview's).
    var hiddenCharacters: ((NSRange) -> [NSRange])?

    override func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                                lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                                in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let (height, font) = ownHeight(layoutManager, glyphRange) else {
            return super.layoutManager(layoutManager, shouldSetLineFragmentRect: lineFragmentRect, lineFragmentUsedRect: lineFragmentUsedRect,
                                       baselineOffset: baselineOffset, in: textContainer, forGlyphRange: glyphRange)
        }
        let natural = ceil(font.ascender - font.descender + font.leading)
        lineFragmentRect.pointee.size.height = height
        lineFragmentUsedRect.pointee.size.height = height
        baselineOffset.pointee = ceil(font.ascender) + floor((height - natural) / 2)
        return true
    }

    /// A heading row's height and font: its paragraph style asks for more than the base line height.
    private func ownHeight(_ layoutManager: NSLayoutManager, _ glyphRange: NSRange) -> (CGFloat, NSFont)? {
        guard let storage = layoutManager.textStorage, glyphRange.length > 0 else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        guard character < storage.length,
              let style = storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle,
              style.minimumLineHeight > lineHeight + 0.5,
              let font = storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont else { return nil }
        return (style.minimumLineHeight, font)
    }
}

import AppKit
import NextTermCore

/// A Markdown file's look in its editor, from what MarkdownSyntax reads in each line: headings in the editor's own font
/// at 1.5, 1.3 and 1.15 times its size (bold, as are the levels after them), bold and italic by the font's own traits,
/// struck text, code spans on a tint, and each item's wrapped rows under its text. All of it is attributes of the text
/// storage (no undo step, never the dirty flag, never a byte on disk) or the layout manager's temporary ones, so the
/// grammar's colours stay as they are.
///
/// Lines are read and styled in 8 ms slices from the top, so a long file never holds up typing; a line that reads as
/// plain text and still has the attributes it opened with is left alone, so most of a long file costs only its reading.
/// An edit reads again from the line before it (which looks at the line after it, for a setext heading or a table)
/// until a line ends in the state it ended in before, so a keystroke restyles its own line, and a fence opened by typing
/// restyles onwards in slices. Only a line whose reading changed is styled again. Typed text takes the attributes of
/// the text before it, and its line's restyle, right after, gives each character its own.
final class MarkdownStyler {
    static let sliceBudget: TimeInterval = 0.008
    /// A heading's size, by level, as a multiple of the editor's font size.
    static let headingScales: [CGFloat] = [1, 1.5, 1.3, 1.15, 1, 1, 1]
    /// Code spans' tint, behind the grammar's colour.
    static let codeTint = NSColor(white: 1, alpha: 0.07)
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
    private var scheduled = false
    /// Without a grammar, links get their colour here.
    private let colorsLinks: Bool

    var fonts: MarkdownFonts
    /// The paragraph style for a line's wrap column and heading level: the editor's, with its tab stops and heights.
    let paragraphStyle: (_ hang: Int, _ heading: Int) -> NSParagraphStyle

    init(storage: NSTextStorage, layoutManager: NSLayoutManager, font: NSFont, colorsLinks: Bool,
         index: @escaping () -> LineIndex, paragraphStyle: @escaping (_ hang: Int, _ heading: Int) -> NSParagraphStyle) {
        self.storage = storage
        self.layoutManager = layoutManager
        self.index = index
        self.paragraphStyle = paragraphStyle
        self.colorsLinks = colorsLinks
        fonts = MarkdownFonts(base: font)
        let count = index().count
        ends = Array(repeating: nil, count: count)
        lines = Array(repeating: nil, count: count)
        baseOnStorage = Array(repeating: false, count: count)
        mustRedoThrough = count - 1
    }

    /// Lines still to read (0 when the whole file is styled), for the self-test.
    var pendingLines: Int { lines.count - validUpTo }

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
        run()
    }

    /// Reads and styles what is pending, within one slice, then goes on in later turns of the run loop.
    func run() {
        let index = self.index()
        guard index.count == lines.count else { return restyleAll(storageIsBase: false) }
        let text = storage.string as NSString
        let deadline = Date().addingTimeInterval(Self.sliceBudget)
        storage.beginEditing()
        while validUpTo < lines.count {
            let number = validUpTo
            let before = number > 0 ? ends[number - 1] ?? MarkdownSyntax.LineState() : MarkdownSyntax.LineState()
            let (line, end) = MarkdownSyntax.scan(text, range: index.range(ofLine: number), after: before)
            if lines[number] != line {
                let plain = line.headingLevel == 0 && line.hang == 0 && line.spans.isEmpty
                if !(plain && lines[number] == nil && baseOnStorage[number]) { apply(line, at: index.range(ofLine: number)) }
                baseOnStorage[number] = false
            }
            let unchanged = number > mustRedoThrough && ends[number] == end
            ends[number] = end
            lines[number] = line
            validUpTo = number + 1
            if unchanged {
                // Every line after ended as it did before: already right.
                validUpTo = lines.firstIndex(where: { $0 == nil }) ?? lines.count
            }
            if Date() > deadline { break }
        }
        storage.endEditing()
        if validUpTo < lines.count { schedule() }
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.run()
        }
    }

    /// One line's attributes from scratch: the base font (a heading's for a heading line), its paragraph style, then its
    /// spans' fonts, strikethrough and tints.
    private func apply(_ line: MarkdownSyntax.Line, at range: NSRange) {
        guard range.length > 0 else { return }
        let heading = line.headingLevel
        storage.addAttribute(.font, value: fonts.font(heading: heading), range: range)
        storage.addAttribute(.paragraphStyle, value: paragraphStyle(line.hang, heading), range: range)
        storage.removeAttribute(.strikethroughStyle, range: range)
        let content = NSRange(location: range.location, length: line.length)
        layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: content)
        if colorsLinks { layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: content) }
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
        if style.contains(.code) { layoutManager?.addTemporaryAttribute(.backgroundColor, value: Self.codeTint, forCharacterRange: run) }
        if style.contains(.link), colorsLinks { layoutManager?.addTemporaryAttribute(.foregroundColor, value: Self.linkColor, forCharacterRange: run) }
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
/// centred in it as on every other line. Every other file keeps LineSpacing's one height.
final class MarkdownSpacing: LineSpacing {
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

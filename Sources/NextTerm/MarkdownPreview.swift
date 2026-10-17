import AppKit
import NextTermCore

/// Live Preview of a Markdown file. Its syntax characters take no room (MarkdownSpacing makes them null glyphs) on every
/// line but those the caret or the selection is on, which show as written; list bullets, task boxes, rules and quote
/// bars are drawn over their characters, a done task's text is faint, and a fence's lines sit on a tint
/// (CodeLayoutManager). Only drawing changes: the text, the undo stack and the dirty flag never do, and find, copy, drag,
/// accessibility and agents read every character.
///
/// Whole lines show their syntax, never a span inside one, so moving along a line never moves its text, and moving to
/// another line lays out only the line left and the line entered. While a drag selects, the lines stay as they were at
/// mouse-down and follow at mouse-up, so text never moves under the pointer; while an input method composes, they wait
/// for the text to be committed. A selection over more than 500 lines shows only the line its moving end is on.
final class MarkdownPreview {
    static let revealLimit = 500

    private let styler: MarkdownStyler
    private weak var textView: CodeTextView?
    private weak var layoutManager: NSLayoutManager?
    private let index: () -> LineIndex
    /// Live Preview, or Source.
    private(set) var enabled: Bool
    /// The lines that show their syntax now.
    private(set) var revealed: ClosedRange<Int>?
    private var lastSelection = NSRange(location: 0, length: 0)
    private var updateQueued = false

    init(styler: MarkdownStyler, textView: CodeTextView, layoutManager: NSLayoutManager, enabled: Bool, index: @escaping () -> LineIndex) {
        self.styler = styler
        self.textView = textView
        self.layoutManager = layoutManager
        self.enabled = enabled
        self.index = index
    }

    /// Live Preview on or off: the glyphs of what is laid out are made again, and nothing else changes. In Source every
    /// character shows and the fonts stay (MarkdownStyler), so switching moves no text but the syntax: the text on the
    /// top row stays there, however many rows the hidden syntax above it takes in Source.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        revealed = on ? revealedLines() : nil
        guard let layoutManager, let storage = layoutManager.textStorage else { return }
        let top = topCharacter()
        let all = NSRange(location: 0, length: storage.length)
        layoutManager.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        if let top { keepAtTop(top) }
        textView?.needsDisplay = true
        textView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// The first character on the editor's top row, and how far that row is scrolled past the top: a switch keeps it so.
    private func topCharacter() -> (character: Int, past: CGFloat)? {
        guard let textView, let layoutManager, let container = textView.textContainer, (layoutManager.textStorage?.length ?? 0) > 0 else {
            return nil
        }
        let y = textView.visibleRect.minY - textView.textContainerOrigin.y
        guard y > 0 else { return nil } // at the top, the text stays at the top anyway
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
        var row = NSRange()
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &row)
        return (layoutManager.characterIndexForGlyph(at: row.location), max(0, y - rect.minY))
    }

    /// That character's row back on the top row, as far past it as it was.
    private func keepAtTop(_ top: (character: Int, past: CGFloat)) {
        guard let textView, let layoutManager else { return }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: top.character, length: 0))
        let glyph = layoutManager.glyphIndexForCharacter(at: top.character)
        let row = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let visible = textView.visibleRect
        // A rect as tall as the view from that row, so the scroll view puts the row on top (as go to line does, never a
        // raw scroll(to:), which ignores the gutter).
        let y = row.minY + min(top.past, row.height) + textView.textContainerOrigin.y
        let rect = NSRect(x: visible.minX, y: y, width: 1, height: visible.height)
        textView.scrollToVisible(rect.intersection(textView.bounds))
    }

    private func isRevealed(_ line: Int) -> Bool { revealed?.contains(line) ?? false }

    /// Each line a range of the text touches, with where it starts.
    private func forEachLine(in range: NSRange, _ body: (_ line: Int, _ start: Int) -> Void) {
        let index = self.index()
        guard index.count > 0, range.location <= index.length else { return }
        let first = index.line(at: range.location)
        let last = index.line(at: max(range.location, NSMaxRange(range) - 1))
        for line in first...min(last, index.count - 1) { body(line, index.starts[line]) }
    }

    // MARK: what is drawn

    /// The characters to hide in a range: the read syntax of every line there but the revealed ones.
    func hiddenCharacters(in range: NSRange) -> [NSRange] {
        guard enabled else { return [] }
        var hidden: [NSRange] = []
        forEachLine(in: range) { line, start in
            guard !isRevealed(line), let read = styler.readLine(line) else { return }
            for part in read.hidden { hidden.append(NSRange(location: start + part.location, length: part.length)) }
        }
        return hidden
    }

    /// The marks drawn over a range's characters, in order: bullets, boxes, rules, quote bars, and faint done tasks.
    func drawings(in range: NSRange) -> [CodeLayoutManager.DrawOver] {
        guard enabled else { return [] }
        var drawn: [CodeLayoutManager.DrawOver] = []
        forEachLine(in: range) { line, start in
            guard !isRevealed(line), let read = styler.readLine(line) else { return }
            var marks = read.drawn.map { item in
                CodeLayoutManager.DrawOver(range: NSRange(location: start + item.range.location, length: item.range.length),
                                           drawing: Self.drawing(item.drawing))
            }
            for span in read.spans where span.style.contains(.dimmed) {
                marks.append(.init(range: NSRange(location: start + span.range.location, length: span.range.length), drawing: .dim))
            }
            drawn += marks.sorted { $0.range.location < $1.range.location }
        }
        return drawn
    }

    private static func drawing(_ drawing: MarkdownSyntax.Drawing) -> CodeLayoutManager.Drawing {
        switch drawing {
        case .bullet: return .listBullet
        case .checkbox(let done): return .checkbox(done: done)
        case .rule: return .rule
        case .quoteBar: return .quoteBar
        case .blank: return .blank
        }
    }

    /// A code fence's lines in a range, with their line breaks: drawn on a tint across the editor.
    func tintedLines(in range: NSRange) -> [NSRange] {
        guard enabled else { return [] }
        var tinted: [NSRange] = []
        let index = self.index()
        forEachLine(in: range) { line, _ in
            guard let read = styler.readLine(line), read.kind == .fence || read.kind == .code else { return }
            tinted.append(index.range(ofLine: line))
        }
        return tinted
    }

    // MARK: revealing

    /// The lines that show their syntax: the selection's, or the caret's once you clicked or typed in the editor while
    /// it has the keyboard (as a .env file's caret line shows its value).
    private func revealedLines() -> ClosedRange<Int>? {
        guard enabled, let textView else { return nil }
        let selection = textView.selectedRange()
        let focused = textView.window?.firstResponder === textView && textView.caretPlacedByUser
        guard selection.length > 0 || focused else { return nil }
        let index = self.index()
        guard selection.location <= index.length else { return nil }
        let lines = LineEdits.lines(touching: selection, in: index)
        guard lines.count > Self.revealLimit else { return lines }
        let moving = selection.location != lastSelection.location ? selection.location : max(selection.location, NSMaxRange(selection) - 1)
        let line = index.line(at: moving)
        return line...line
    }

    /// The selection moved, or the editor took or lost the keyboard: the lines it leaves hide their syntax again and the
    /// lines it enters show theirs. Not while a drag is selecting (`stillSelecting`) or an input method composes; and
    /// never in the middle of an edit to the text, which it waits for.
    func selectionChanged(stillSelecting: Bool) {
        guard enabled, let textView, !stillSelecting, !textView.hasMarkedText() else { return }
        if let storage = textView.textStorage, !storage.editedMask.isEmpty {
            guard !updateQueued else { return }
            updateQueued = true
            DispatchQueue.main.async { [weak self] in
                self?.updateQueued = false
                self?.selectionChanged(stillSelecting: false)
            }
            return
        }
        let now = revealedLines()
        lastSelection = textView.selectedRange()
        guard now != revealed else { return }
        let before = revealed
        revealed = now
        for lines in Self.lines(in: before, notIn: now) + Self.lines(in: now, notIn: before) { invalidate(lines) }
    }

    /// The lines of `a` that are not in `b`, as up to two runs.
    static func lines(in a: ClosedRange<Int>?, notIn b: ClosedRange<Int>?) -> [ClosedRange<Int>] {
        guard let a else { return [] }
        guard let b, b.overlaps(a) else { return [a] }
        var runs: [ClosedRange<Int>] = []
        if a.lowerBound < b.lowerBound { runs.append(a.lowerBound...(b.lowerBound - 1)) }
        if a.upperBound > b.upperBound { runs.append((b.upperBound + 1)...a.upperBound) }
        return runs
    }

    /// Lines whose reading changed (MarkdownStyler): their glyphs are made again.
    func linesChanged(_ lines: ClosedRange<Int>) {
        guard enabled else { return }
        invalidate(lines)
    }

    private func invalidate(_ lines: ClosedRange<Int>) {
        let index = self.index()
        guard let layoutManager, lines.lowerBound < index.count else { return }
        let start = index.starts[lines.lowerBound]
        let end = NSMaxRange(index.range(ofLine: min(lines.upperBound, index.count - 1)))
        let range = NSRange(location: start, length: end - start)
        layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        textView?.needsDisplay = true
    }

    // MARK: the caret

    /// A caret put inside a hidden run on a line that shows none (a click left of a heading's title, an arrow onto it)
    /// goes to the run's end, before the text it marks; a run that ends in an escape's backslash, before the backslash.
    func snapped(_ ranges: [NSValue]) -> [NSValue] {
        guard enabled, ranges.count == 1, let range = ranges.first?.rangeValue, range.length == 0 else { return ranges }
        let index = self.index()
        guard range.location <= index.length else { return ranges }
        let line = index.line(at: range.location)
        guard !isRevealed(line), let read = styler.readLine(line) else { return ranges }
        let local = range.location - index.starts[line]
        guard let run = read.hidden.first(where: { $0.location <= local && local < NSMaxRange($0) }) else { return ranges }
        // An escape's backslash and its character are one token: the caret goes before the backslash, never between them,
        // so typing at the start of `\# not a heading` leaves its escape whole. No other hidden run ends in a backslash.
        var end = NSMaxRange(run)
        if end > run.location, let text = textView?.string as NSString?, index.starts[line] + end <= text.length,
           text.character(at: index.starts[line] + end - 1) == 0x5C {
            end -= 1
        }
        return [NSValue(range: NSRange(location: index.starts[line] + end, length: 0))]
    }

    /// The task box drawn at a character, if one is (on a line that shows no syntax: there the box is its text).
    func box(at character: Int) -> NSRange? {
        guard enabled else { return nil }
        let index = self.index()
        guard character < index.length else { return nil }
        let line = index.line(at: character)
        guard !isRevealed(line), let box = styler.readLine(line)?.taskBox else { return nil }
        let drawn = NSRange(location: index.starts[line] + box.location, length: box.length)
        return NSLocationInRange(character, drawn) ? drawn : nil
    }
}

/// Live Preview's hidden characters, as null glyphs: they take no room, and the text keeps every character.
extension MarkdownSpacing {
    @objc(layoutManager:shouldGenerateGlyphs:properties:characterIndexes:font:forGlyphRange:)
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        let count = glyphRange.length
        guard count > 0, let hiddenCharacters else { return 0 }
        let first = characterIndexes[0], last = characterIndexes[count - 1]
        let hidden = hiddenCharacters(NSRange(location: first, length: last - first + 1))
        guard !hidden.isEmpty else { return 0 }
        var changed = Array(UnsafeBufferPointer(start: properties, count: count))
        var any = false, next = 0
        for glyph in 0..<count {
            let character = characterIndexes[glyph]
            while next < hidden.count, NSMaxRange(hidden[next]) <= character { next += 1 }
            guard next < hidden.count, hidden[next].location <= character else { continue }
            changed[glyph] = .null
            any = true
        }
        guard any else { return 0 }
        changed.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                layoutManager.setGlyphs(glyphs, properties: base, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
            }
        }
        return count
    }
}

extension CodeEditorView {
    /// A `.md` or `.markdown` file, whatever its size.
    var isMarkdownFile: Bool { MarkdownSyntax.isMarkdown(fileName: document.name) }
    /// A Markdown file too large for Live Preview (MarkdownSyntax.previewMaxLength): it shows as source.
    var markdownTooLarge: Bool { isMarkdownFile && markdown == nil }
    var showsLivePreview: Bool { preview?.enabled == true }

    /// Whether this file shows in Live Preview: its own choice from the View menu, else Settings › Editor's.
    var showsMarkdownPreview: Bool {
        guard let app = AppDelegate.shared else { return true }
        return app.markdownViewChoices.choice(for: document.path) ?? app.markdownLivePreview
    }

    /// View › Markdown Live Preview: this file between Live Preview and Source, remembered for it. Only the drawing
    /// changes: not the text, the dirty flag or the undo stack.
    func toggleMarkdownPreview() {
        guard let preview, let app = AppDelegate.shared else { return }
        let on = !preview.enabled
        preview.setEnabled(on)
        app.markdownViewChoices.set(on, for: document.path)
    }

    /// Settings › Editor changed: a file without its own choice follows it.
    func applyMarkdownPreviewSetting() {
        preview?.setEnabled(showsMarkdownPreview)
    }
}

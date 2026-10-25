import AppKit
import NextTermCore

/// The editor's layout manager. It lays text out exactly as NSLayoutManager does, and only draws some characters
/// differently: a .env file's values as bullets while they are hidden, and in Live Preview a Markdown file's list
/// bullets, task boxes, rules and quote bars in the place of their characters, a done task's text faint, and a fence's
/// lines on a tint across the editor. The text, its glyphs and where they go stay the same, so soft wrap, line
/// numbers, the blame column, the change marks, the caret and selections are where they would be, and copy, find, save
/// and undo work on the real text. (Swapping the glyphs instead would lay the line out again each time the caret moved
/// onto it, and a wide character's bullet would rewrap it.)
final class CodeLayoutManager: NSLayoutManager {
    enum Drawing: Equatable {
        /// A bullet for each character: a hidden .env value.
        case bullet
        /// One list bullet for a Markdown item's `-`, `*` or `+`.
        case listBullet
        case checkbox(done: Bool)
        /// A line across the editor, for a thematic break.
        case rule
        case quoteBar
        /// Nothing: the characters keep their room.
        case blank
        /// The characters themselves, faint.
        case dim
    }

    struct DrawOver: Equatable {
        var range: NSRange
        var drawing: Drawing
    }

    /// What is drawn over the characters in a range, in order and apart. Asked each time glyphs are drawn.
    var drawOver: ((NSRange) -> [DrawOver])?
    /// Lines (character ranges) drawn on a tint across the editor: a Markdown fence's.
    var tintedLines: ((NSRange) -> [NSRange])?
    /// Runs of characters drawn on a tint behind their text, in order: a Markdown code span's.
    var tintedRuns: ((NSRange) -> [NSRange])?
    private static let bullet = "•" as NSString
    static let fenceTint = NSColor(white: 1, alpha: 0.035)
    static let codeTint = NSColor(white: 1, alpha: 0.07)
    static let markColor = NSColor(hex: 0x9DA0A8)
    static let ruleColor = NSColor(hex: 0x43454A)
    static let quoteColor = NSColor(hex: 0x4E5157)

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard let over = drawOver?(characters), !over.isEmpty else { return super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin) }
        var next = glyphsToShow.location
        for item in over {
            if item.range.location >= NSMaxRange(characters) { break }
            let overlap = NSIntersectionRange(item.range, characters)
            guard overlap.length > 0 else { continue }
            let glyphs = NSIntersectionRange(glyphRange(forCharacterRange: overlap, actualCharacterRange: nil), glyphsToShow)
            guard glyphs.length > 0, glyphs.location >= next else { continue }
            if glyphs.location > next { super.drawGlyphs(forGlyphRange: NSRange(location: next, length: glyphs.location - next), at: origin) }
            draw(item.drawing, glyphs, at: origin)
            next = NSMaxRange(glyphs)
        }
        if next < NSMaxRange(glyphsToShow) {
            super.drawGlyphs(forGlyphRange: NSRange(location: next, length: NSMaxRange(glyphsToShow) - next), at: origin)
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        if let tinted = tintedLines?(characters), !tinted.isEmpty, let width = textContainers.first?.textView?.bounds.width {
            Self.fenceTint.setFill()
            for line in tinted {
                let glyphs = NSIntersectionRange(glyphRange(forCharacterRange: line, actualCharacterRange: nil), glyphsToShow)
                guard glyphs.length > 0 else { continue }
                enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
                    NSRect(x: 0, y: fragment.minY + origin.y, width: width, height: fragment.height).fill(using: .sourceOver)
                }
            }
        }
        if let runs = tintedRuns?(characters), !runs.isEmpty, let container = textContainers.first {
            Self.codeTint.setFill()
            let none = NSRange(location: NSNotFound, length: 0)
            for run in runs {
                let glyphs = NSIntersectionRange(glyphRange(forCharacterRange: run, actualCharacterRange: nil), glyphsToShow)
                guard glyphs.length > 0 else { continue }
                // One rect a row, as a background colour's (a span that wraps is tinted on each of its rows).
                enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: none, in: container) { rect, _ in
                    rect.offsetBy(dx: origin.x, dy: origin.y).fill(using: .sourceOver)
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func draw(_ drawing: Drawing, _ glyphs: NSRange, at origin: NSPoint) {
        switch drawing {
        case .bullet: drawBullets(glyphs, at: origin)
        case .blank: break
        case .dim:
            guard let context = NSGraphicsContext.current?.cgContext else { return super.drawGlyphs(forGlyphRange: glyphs, at: origin) }
            context.saveGState()
            context.setAlpha(0.45)
            super.drawGlyphs(forGlyphRange: glyphs, at: origin)
            context.restoreGState()
        case .listBullet, .checkbox, .rule, .quoteBar:
            drawMark(drawing, glyphs, at: origin)
        }
    }

    /// A bullet in the place of each character, on its baseline, in the colour the character has.
    private func drawBullets(_ glyphs: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let first = min(characterIndexForGlyph(at: glyphs.location), storage.length - 1)
        let font: NSFont = storage.attribute(.font, at: first, effectiveRange: nil) as? NSFont ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        // The syntax colour, else the text's.
        let syntax = temporaryAttribute(.foregroundColor, atCharacterIndex: first, effectiveRange: nil) as? NSColor
        let color: NSColor = syntax ?? storage.attribute(.foregroundColor, at: first, effectiveRange: nil) as? NSColor ?? .textColor
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = Self.bullet.size(withAttributes: attributes).width
        enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, container, fragmentGlyphs, _ in
            let row = NSIntersectionRange(glyphs, fragmentGlyphs)
            guard row.length > 0 else { return }
            for glyph in row.location..<NSMaxRange(row) {
                // Line breaks and tabs keep their gap; the second half of a surrogate pair has no glyph.
                let property = self.propertyForGlyph(at: glyph)
                if property.contains(.null) || property.contains(.controlCharacter) || property.contains(.nonBaseCharacter) { continue }
                let cell = self.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                let baseline = fragment.minY + self.location(forGlyphAt: glyph).y
                let point = NSPoint(x: origin.x + cell.midX - width / 2, y: origin.y + baseline - font.ascender)
                Self.bullet.draw(at: point, withAttributes: attributes)
            }
        }
    }

    /// A Markdown mark in the place of its characters, in the first row they are on, centred on the text's x-height.
    private func drawMark(_ drawing: Drawing, _ glyphs: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0, let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { return }
        let first = min(characterIndexForGlyph(at: glyphs.location), storage.length - 1)
        let font = storage.attribute(.font, at: first, effectiveRange: nil) as? NSFont ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let fragment = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let cells = boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
        let baseline = fragment.minY + origin.y + location(forGlyphAt: glyphs.location).y
        let middle = baseline - font.xHeight / 2
        switch drawing {
        case .listBullet:
            let size = max(4, round(font.pointSize * 0.36))
            Self.markColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: cells.midX - size / 2, y: middle - size / 2, width: size, height: size)).fill()
        case .checkbox(let done):
            let side = round(min(font.pointSize * 0.95, cells.width))
            let box = NSRect(x: cells.midX - side / 2, y: middle - side / 2, width: side, height: side)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            if done {
                Theme.accent.setFill()
                path.fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: box.minX + side * 0.25, y: box.midY))
                tick.line(to: NSPoint(x: box.minX + side * 0.43, y: box.maxY - side * 0.27))
                tick.line(to: NSPoint(x: box.maxX - side * 0.22, y: box.minY + side * 0.27))
                tick.lineWidth = max(1.5, side * 0.12)
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                NSColor.white.setStroke()
                tick.stroke()
            } else {
                path.lineWidth = 1.2
                Self.markColor.setStroke()
                path.stroke()
            }
        case .rule:
            // To the right edge of what shows (with wrapping off, the text can be far wider).
            let right = (container.textView?.visibleRect.maxX ?? cells.maxX) - container.lineFragmentPadding
            Self.ruleColor.setFill()
            NSRect(x: cells.minX, y: round(fragment.midY + origin.y), width: max(0, right - cells.minX), height: 1).fill()
        case .quoteBar:
            Self.quoteColor.setFill()
            NSRect(x: cells.minX + 1, y: fragment.minY + origin.y, width: 3, height: fragment.height).fill()
        case .bullet, .blank, .dim:
            break
        }
    }
}

/// A .env file's values on screen, for screen shares: hidden in every .env file when Settings › Editor
/// says so, or in one file from the View menu. The caret's line shows its value once you click or type
/// in the file, so typing is never blind; open the file, or come back to it, and every value is hidden.
final class EnvValueMask {
    /// This file's own choice from the View menu; nil follows Settings.
    var choice: Bool?
    private var ranges: [NSRange] = []
    private var stale = true

    /// The text changed: the values are found again before they are next drawn.
    func textEdited() { stale = true }

    /// The values' ranges; the text is read only when it changed since the last time.
    func ranges(in text: @autoclosure () -> String) -> [NSRange] {
        if stale {
            ranges = EnvFile.valueRanges(in: text())
            stale = false
        }
        return ranges
    }
}

extension CodeEditorView {
    /// A .env, .env.*, *.env or .flaskenv file, by its name or the name it was opened by (a `.env`
    /// that links to a file elsewhere). A rename can change it.
    var isEnvFile: Bool { EnvFile.isEnvFile(named: document.name) || EnvFile.isEnvFile(named: document.openedName) }

    /// Whether this file's values are hidden now.
    var hidesEnvValues: Bool { isEnvFile && (envValues.choice ?? AppDelegate.shared?.hidesEnvValues == true) }

    /// View › Hide .env Values, on or off for this file. Hiding hides the caret's line too, until you
    /// click or type in it.
    func toggleEnvValues() {
        envValues.choice = !hidesEnvValues
        if hidesEnvValues { textView.caretPlacedByUser = false }
        textView.needsDisplay = true
    }

    /// Settings › Editor changed: every file follows it again.
    func applyEnvValuesSetting() {
        envValues.choice = nil
        textView.caretPlacedByUser = false
        textView.needsDisplay = true
    }

    /// What the layout manager draws as bullets: the values, when hidden, but not the caret's line
    /// while you work on it. Only that line shows: the rest of a value over several lines stays hidden.
    /// (Markdown Live Preview's marks come through the same hook: drawOver(in:).)
    func hiddenEnvValues() -> [NSRange] {
        guard hidesEnvValues else { return [] }
        let ranges = envValues.ranges(in: document.text)
        guard let shown = caretLineShown() else { return ranges }
        return EnvFile.ranges(ranges, showing: shown)
    }

    /// The caret's line, when its value shows: the editor has the keyboard (in the key window), nothing
    /// is selected, and you clicked or typed in it since it got the keyboard.
    private func caretLineShown() -> NSRange? {
        let selection = textView.selectedRange()
        guard textView.caretPlacedByUser, selection.length == 0, let window = textView.window else { return nil }
        guard window.isKeyWindow, window.firstResponder === textView else { return nil }
        return document.lines.range(ofLine: document.lines.line(at: min(selection.location, document.storage.length)))
    }

    /// For the self-test: a line with the characters the layout manager is given to hide as “•”, without
    /// its line break. (What it really draws, the self-test reads from the pixels.)
    func drawnText(line: Int) -> String {
        let range = document.lines.range(ofLine: line)
        var units = Array((document.text as NSString).substring(with: range).utf16)
        for hidden in hiddenEnvValues() {
            let overlap = NSIntersectionRange(hidden, range)
            guard overlap.length > 0 else { continue }
            for i in overlap.location..<NSMaxRange(overlap) where units[i - range.location] != 0x0A {
                units[i - range.location] = 0x2022
            }
        }
        if units.last == 0x0A { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
}

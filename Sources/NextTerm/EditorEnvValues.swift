import AppKit
import NextTermCore

/// The editor's layout manager. It lays text out exactly as NSLayoutManager does, and only draws some
/// characters as bullets instead of their glyphs: a .env file's values, while they are hidden. The
/// text, its glyphs and where they go stay the same, so soft wrap, line numbers, the blame column, the
/// change marks, the caret and selections are where they would be, and copy, find, save and undo work
/// on the real text. (Swapping the glyphs instead would lay the line out again each time the caret
/// moved onto it, and a wide character's bullet would rewrap it.)
final class CodeLayoutManager: NSLayoutManager {
    /// Character ranges drawn as bullets, in order. Asked each time glyphs are drawn.
    var hiddenRanges: (() -> [NSRange])?
    private static let bullet = "•" as NSString

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let hidden = hiddenRanges?(), !hidden.isEmpty else { return super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin) }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var next = glyphsToShow.location
        for range in hidden {
            if range.location >= NSMaxRange(characters) { break }
            let overlap = NSIntersectionRange(range, characters)
            guard overlap.length > 0 else { continue }
            let glyphs = NSIntersectionRange(glyphRange(forCharacterRange: overlap, actualCharacterRange: nil), glyphsToShow)
            guard glyphs.length > 0, glyphs.location >= next else { continue }
            if glyphs.location > next { super.drawGlyphs(forGlyphRange: NSRange(location: next, length: glyphs.location - next), at: origin) }
            drawBullets(glyphs, at: origin)
            next = NSMaxRange(glyphs)
        }
        if next < NSMaxRange(glyphsToShow) {
            super.drawGlyphs(forGlyphRange: NSRange(location: next, length: NSMaxRange(glyphsToShow) - next), at: origin)
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
    /// A .env, .env.*, *.env or .flaskenv file, by its name (a rename can change it).
    var isEnvFile: Bool { EnvFile.isEnvFile(named: document.name) }

    /// Whether this file's values are hidden now.
    var hidesEnvValues: Bool { isEnvFile && (envValues.choice ?? AppDelegate.shared?.hidesEnvValues == true) }

    /// View › Hide .env Values or Show .env Values, for this file. Hiding hides the caret's line too,
    /// until you click or type in it.
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

    /// For the self-test: a line as it is drawn, hidden characters as “•”, without its line break.
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

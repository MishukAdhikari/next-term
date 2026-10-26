import Foundation

/// What a grid cell draws: any value as one line of text, so no cell ever draws past its row. The SQLite
/// viewer, the data head view and the detail pane's row list all go through `line`, and nothing else
/// turns line breaks or control characters into marks.
public enum CellText {
    /// A line break of any kind: "\n", "\r", "\r\n" (one mark), U+000B, U+000C, U+0085, U+2028, U+2029.
    public static let lineBreak = " ⏎ "
    public static let tab = "⇥"
    public static let ellipsis = "…"
    /// A character that draws as nothing yet is there: a bidi embedding, override or isolate (which would
    /// reorder the text around it), a zero-width space or word joiner, a byte order mark, a soft hyphen.
    public static let invisible = "▯"

    /// `text` on one line: line breaks as " ⏎ ", a tab as "⇥", the other C0 controls as their Control
    /// Pictures (␀ to ␟), DEL as ␡, the C1 controls as U+FFFD, and the invisible characters that hide or
    /// reorder text as "▯" (ZWJ and ZWNJ, which emoji and many scripts need, and the bidi marks RTL text
    /// uses show as themselves). It stops after `limit` characters with "…", and ends in "…" when `cut`
    /// says the value was cut short on read. The work is bounded by `limit`, never by the length of
    /// `text`; a character (an emoji, a letter and its accents) is never split.
    public static func line(_ text: String, limit: Int = 300, cut: Bool = false) -> String {
        let limit = max(1, limit)
        var out = ""
        var count = 0
        var stopped = false
        // Each character of `text` gives at least one, so at most `limit` + 1 of them are looked at.
        for character in text {
            guard count < limit else {
                stopped = true
                break
            }
            guard let mark = mark(for: character) else {
                out.append(character)
                count += 1
                continue
            }
            let room = limit - count
            if mark.count > room {
                out += mark.prefix(room)
                stopped = true
                break
            }
            out += mark
            count += mark.count
        }
        if stopped || cut { out += ellipsis }
        return out
    }

    /// The mark a character shows as, or nil when it shows as itself. Grapheme breaking keeps every control,
    /// line break and invisible format character a character of its own ("\r\n" is one), so only single
    /// scalars need a look.
    static func mark(for character: Character) -> String? {
        let scalars = character.unicodeScalars
        if character == "\r\n" { return lineBreak }
        guard scalars.count == 1, let scalar = scalars.first else { return nil }
        return mark(for: scalar)
    }

    static func mark(for scalar: Unicode.Scalar) -> String? {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: return lineBreak
        case 0x09: return tab
        case 0x00...0x1F: return Unicode.Scalar(0x2400 + scalar.value).map { String($0) }
        case 0x7F: return "\u{2421}"
        case 0x80...0x9F: return "\u{FFFD}"
        default: return isInvisible(scalar) ? invisible : nil
        }
    }

    /// The bidi embeddings, overrides and isolates (U+202A–U+202E, U+2066–U+2069) and the invisible spacers
    /// (U+200B, U+2060, U+FEFF, U+00AD).
    public static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x200B, 0x2060, 0xFEFF, 0x00AD: return true
        default: return false
        }
    }

    /// `text` with each invisible character (`isInvisible`) as "▯", and how many there were; the text
    /// itself when it has none. For the detail pane, which shows a value whole and would otherwise draw them
    /// as nothing, and reorder the text around a bidi control.
    public static func revealingInvisibles(_ text: String) -> (text: String, count: Int) {
        guard text.unicodeScalars.contains(where: isInvisible) else { return (text, 0) }
        var out = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            if isInvisible(scalar) {
                out.append(contentsOf: invisible.unicodeScalars)
                count += 1
            } else {
                out.append(scalar)
            }
        }
        return (String(out), count)
    }
}

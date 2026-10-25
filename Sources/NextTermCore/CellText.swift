import Foundation

/// What a grid cell draws: any value as one line of text, so no cell ever draws past its row. The SQLite
/// viewer, the data head view and the detail pane's row list all go through `line`, and nothing else
/// turns line breaks or control characters into marks.
public enum CellText {
    /// A line break of any kind: "\n", "\r", "\r\n" (one mark), U+000B, U+000C, U+0085, U+2028, U+2029.
    public static let lineBreak = " ⏎ "
    public static let tab = "⇥"
    public static let ellipsis = "…"

    /// `text` on one line: line breaks as " ⏎ ", a tab as "⇥", the other C0 controls as their Control
    /// Pictures (␀ to ␟), DEL as ␡ and the C1 controls as U+FFFD. It stops after `limit` characters
    /// with "…", and ends in "…" when `cut` says the value was cut short on read. The work is bounded by
    /// `limit`, never by the length of `text`; a character (an emoji, a letter and its accents) is never
    /// split.
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

    /// The mark a character shows as, or nil when it shows as itself. Grapheme breaking keeps every control
    /// and line break a character of its own ("\r\n" is one), so only single scalars need a look.
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
        default: return nil
        }
    }
}

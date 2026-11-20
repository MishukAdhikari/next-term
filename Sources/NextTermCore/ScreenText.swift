import Foundation

/// A terminal row as text, the one way Next Term reads a screen: read_tab, the agent's status and its questions, the
/// screen an MCP tool returns. A cell nothing was ever written to (a cleared or erased cell, or one a cursor move
/// skipped over) holds character 0, and the terminal's own text gives it as U+0000; on screen it is a blank, so here
/// it is a space. The second cell of a wide character is left out where the row is read (it is no character of its
/// own), so every U+0000 left is such a blank.
public enum ScreenText {
    /// `character`, a cell's, as the screen shows it: a space for an empty cell.
    @inlinable
    public static func character(_ character: Character) -> Character {
        character == "\u{0}" ? " " : character
    }

    /// `text`, a row read from a terminal, with each empty cell (U+0000) a space.
    public static func line(_ text: String) -> String {
        guard text.unicodeScalars.contains("\u{0}") else { return text }
        var shown = String.UnicodeScalarView()
        for scalar in text.unicodeScalars { shown.append(scalar == "\u{0}" ? " " : scalar) }
        return String(shown)
    }

    /// Each of `rows` as `line` gives it.
    public static func lines(_ rows: [String]) -> [String] {
        guard rows.contains(where: { $0.unicodeScalars.contains("\u{0}") }) else { return rows }
        return rows.map(line)
    }

    /// `text` as `line` gives it, without blanks at its right.
    public static func trimmedLine(_ text: String) -> String {
        var shown = line(text)
        while let last = shown.last, last == " " { shown.removeLast() }
        return shown
    }

    /// Nothing on the row: only blanks, empty cells included.
    public static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0 == "\u{0}" || $0 == " " || $0 == "\t" }
    }
}

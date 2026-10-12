import Foundation

/// What an agent puts in its own terminal title (OSC 0/2), as a tab shows it.
public enum AgentTitle {
    /// The title without a spinner frame at its start: Claude Code turns braille dots (⠋⠙⠹…) or half circles (◐◓◑◒)
    /// there while it works. Its ✳ when it waits for you stays: it is a state, not a frame.
    public static func withoutSpinnerFrame(_ title: String) -> String {
        guard let first = title.unicodeScalars.first, isSpinnerFrame(first) else { return title }
        let rest = title.unicodeScalars.dropFirst().drop { $0 == " " || $0 == "\u{00A0}" }
        return String(String.UnicodeScalarView(rest))
    }

    static func isSpinnerFrame(_ scalar: Unicode.Scalar) -> Bool {
        (0x2801...0x28FF).contains(scalar.value) || ["◐", "◓", "◑", "◒"].contains(scalar)
    }
}

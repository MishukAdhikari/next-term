import Foundation

/// Text a restore feeds into a terminal that no program in it printed: a restored tab's note, the divider above it,
/// replayed scrollback (KTD9). Any of it can hold what a file, a folder name or a server put there, so only printable
/// text, newlines and tabs get through. Every C0 control (ESC, BEL and CR among them), DEL and C1 control goes, and with
/// them the start of every sequence a terminal answers or acts on: a status or attributes query, a clipboard write, a
/// title report, the end of a bracketed paste, Next Term's own integration channel.
///
/// What is left of a sequence (`[6n`) is plain text. The terminal's convertEol stays off, so the live terminal is
/// unchanged: `feedable` writes each newline as CR LF instead.
public enum TerminalText {
    /// `text` with only printable characters, newlines and tabs. A C1 control is one scalar however it came (UTF-8
    /// carries U+009B as C2 9B), so it goes too.
    public static func sanitize(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where isKept(scalar) { kept.append(scalar) }
        return String(kept)
    }

    /// Bytes read as UTF-8, sanitized. A byte that is not UTF-8, such as a lone 8-bit CSI (0x9B), reads as U+FFFD,
    /// which a terminal only shows.
    public static func sanitize<Bytes: Collection>(utf8 bytes: Bytes) -> String where Bytes.Element == UInt8 {
        sanitize(String(decoding: bytes, as: UTF8.self))
    }

    /// Sanitized, on one line: each newline and tab a space. What a note or a list line is.
    public static func oneLine(_ text: String) -> String {
        var line = String.UnicodeScalarView()
        for scalar in sanitize(text).unicodeScalars {
            line.append(scalar == "\n" || scalar == "\t" ? " " : scalar)
        }
        return String(line)
    }

    /// Sanitized and ready to feed: each newline written as CR LF.
    public static func feedable(_ text: String) -> String {
        var fed = String.UnicodeScalarView()
        for scalar in sanitize(text).unicodeScalars {
            if scalar == "\n" { fed.append("\r") }
            fed.append(scalar)
        }
        return String(fed)
    }

    /// Printable, a newline or a tab.
    static func isKept(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A: return true
        case 0x00...0x1F, 0x7F...0x9F: return false
        default: return true
        }
    }
}

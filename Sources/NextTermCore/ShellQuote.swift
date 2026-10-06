import Foundation

public enum ShellQuote {
    private static let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_+=:,./-")

    /// Quotes `text` to be typed into a POSIX shell (zsh, bash).
    ///
    /// The result is typed as keystrokes, so the line editor sees it before the shell parses any quotes:
    /// a raw control character in a file name (Ctrl-U, Enter) would act immediately. Such names are
    /// therefore written in ANSI-C quoting (`$'…\x0D…'`), and the output never contains a control character.
    public static func quote(_ text: String) -> String {
        if !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) { return text }
        guard text.unicodeScalars.contains(where: isControl) else {
            return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var out = "$'"
        for scalar in text.unicodeScalars {
            if isControl(scalar) {
                for byte in String(scalar).utf8 { out += String(format: "\\x%02X", byte) }
            } else if scalar == "\\" {
                out += "\\\\"
            } else if scalar == "'" {
                out += "\\'"
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "'"
    }

    /// C0 controls, DEL and C1 controls.
    public static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }
}

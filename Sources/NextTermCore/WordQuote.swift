import Foundation

/// A file or folder name as it must be typed so that the shell reads back exactly that name: in the open
/// quote the word is in, for zsh, bash or sh. Tab completion inserts names with it (Next Term's own
/// candidates; zsh quotes its own).
///
/// Unquoted, an allowlist: ShellQuote's safe characters stay, except a leading `=`; every other ASCII
/// character gets a backslash (`~` too: extendedglob makes it a pattern anywhere in a word). Inside `"`,
/// `"` `\` `$` and backticks get one, and a `!` goes outside the quote as `\!` (inside it, zsh keeps the
/// backslash once history expansion is off, and bash always does). Inside `'`, a `'` closes, is escaped and
/// reopens. A name with a control character, an invisible or direction-changing one, or bytes that aren't
/// UTF-8 is written as `$'…'` with `\xHH`, which plain sh doesn't have.
public enum WordQuote {
    public enum Shell: Sendable {
        case zsh
        case bash
        case sh
    }

    public enum Context: Equatable, Sendable {
        case unquoted
        case double
        case single
    }

    private static let safe: Set<UInt8> = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_+=:,./-".utf8)

    /// The name's bytes as typed in `context`; nil when `shell` can't take it (`$'…'` in sh).
    public static func quote(_ name: [UInt8], in context: Context, shell: Shell = .zsh) -> String? {
        if needsANSIC(name) {
            guard shell != .sh else { return nil }
            let ansi = ansiC(name)
            switch context {
            case .unquoted: return ansi
            case .double: return "\"" + ansi + "\""   // close, $'…', reopen
            case .single: return "'" + ansi + "'"
            }
        }
        let text = String(decoding: name, as: UTF8.self)
        switch context {
        case .unquoted:
            var out = ""
            for (index, scalar) in text.unicodeScalars.enumerated() {
                if scalar.isASCII {
                    let byte = UInt8(scalar.value)
                    let leading = index == 0 && (scalar == "=" || scalar == "~")
                    if safe.contains(byte) && !leading { out.unicodeScalars.append(scalar) } else { out += "\\" + String(scalar) }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
            return out
        case .double:
            var out = ""
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\"", "\\", "$", "`": out += "\\" + String(scalar)
                case "!": out += "\"\\!\""
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out
        case .single:
            return text.replacingOccurrences(of: "'", with: "'\\''")
        }
    }

    public static func quote(_ name: String, in context: Context, shell: Shell = .zsh) -> String? {
        quote(Array(name.utf8), in: context, shell: shell)
    }

    /// What follows the name: `/` after a folder (the quote stays open, to go on into it), a space after a
    /// file (an open quote closes first).
    public static func ending(folder: Bool, in context: Context) -> String {
        if folder { return "/" }
        switch context {
        case .unquoted: return " "
        case .double: return "\" "
        case .single: return "' "
        }
    }

    /// Control characters, invisible or direction-changing ones (U+200B–200D, U+202A–202E, U+2066–2069),
    /// or bytes that aren't UTF-8.
    static func needsANSIC(_ name: [UInt8]) -> Bool {
        guard let text = String(bytes: name, encoding: .utf8) else { return true }
        return text.unicodeScalars.contains { ShellQuote.isControl($0) || isHidden($0) }
    }

    public static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        (0x200B...0x200D).contains(scalar.value) || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }

    /// `$'…'`: printable characters as they are, `\` and `'` escaped, and everything else byte by byte.
    static func ansiC(_ name: [UInt8]) -> String {
        var out = "$'"
        var i = 0
        while i < name.count {
            let length = scalarLength(name, at: i)
            let bytes = Array(name[i..<(i + length)])
            if let scalar = String(bytes: bytes, encoding: .utf8)?.unicodeScalars.first, !ShellQuote.isControl(scalar), !isHidden(scalar) {
                switch scalar {
                case "\\": out += "\\\\"
                case "'": out += "\\'"
                default: out.unicodeScalars.append(scalar)
                }
            } else {
                for byte in bytes { out += String(format: "\\x%02X", byte) }
            }
            i += length
        }
        return out + "'"
    }

    /// The length of the UTF-8 sequence at `i`, or 1 for a byte that doesn't start a valid one.
    private static func scalarLength(_ bytes: [UInt8], at i: Int) -> Int {
        let lead = bytes[i]
        var length = 1
        if lead >> 5 == 0b110 {
            length = 2
        } else if lead >> 4 == 0b1110 {
            length = 3
        } else if lead >> 3 == 0b11110 {
            length = 4
        }
        guard length > 1, i + length <= bytes.count else { return 1 }
        let tail = bytes[(i + 1)..<(i + length)]
        guard tail.allSatisfy({ $0 & 0xC0 == 0x80 }), String(bytes: bytes[i..<(i + length)], encoding: .utf8) != nil else { return 1 }
        return length
    }
}

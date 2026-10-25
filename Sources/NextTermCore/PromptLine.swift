import Foundation

/// Whether an agent's prompt holds text, read from the bytes written into its tab (keys, pastes, and text anything
/// typed there). The agent draws its own input box, so the shell's idea of the line says nothing; this counts instead.
///
/// It is deliberately cautious: printable characters and pasted text count up, Backspace counts down, and only Return
/// outside a paste (and not after a backslash, which makes it a newline), Ctrl-C, Ctrl-U or `reset()` (the agent took
/// the line) empties it. Escape sequences such as arrow keys count for nothing, so a line moved around in still reads
/// as holding its text. Only keys and typed text come here, never the terminal's own answers, so no terminal string
/// (ESC P, ESC ]) is ever expected: ESC and one more key is Alt with that key, and a write that ends in ESC was the
/// Escape key alone, so the next write starts fresh. A tab whose line is in doubt is skipped, never typed into.
///
/// Feeding reads the bytes in place: no allocation, no copy, no decoding.
public struct PromptLine: Equatable, Sendable {
    /// Characters on the line, as far as the writes show (a multibyte character counts once).
    public private(set) var count = 0
    private var inPaste = false
    /// The last character typed was a backslash, so a Return now is a newline.
    private var afterBackslash = false
    private var escape = Escape.none
    /// The number read so far in a control sequence's parameters (200 and 201 mark a bracketed paste).
    private var parameter = 0

    private enum Escape: Equatable, Sendable {
        case none
        /// ESC seen; the next byte says what kind of sequence it starts.
        case started
        /// ESC [ : parameters until a final byte.
        case control
        /// ESC O : one more byte.
        case single
    }

    public init() {}

    /// The line holds something that is not the agent's.
    public var hasText: Bool { count > 0 }

    /// The agent consumed the line (it started working), or nothing is known to be on it.
    public mutating func reset() {
        count = 0
        inPaste = false
        afterBackslash = false
        escape = .none
        parameter = 0
    }

    public mutating func feed(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes { feed(byte) }
        // A key's sequence comes whole in one write: an ESC or ESC O left open was the key itself.
        if escape == .started || escape == .single { escape = .none }
    }

    private mutating func feed(_ byte: UInt8) {
        switch escape {
        case .none:
            plain(byte)
        case .started:
            started(byte)
        case .control:
            control(byte)
        case .single:
            escape = .none
        }
    }

    private mutating func plain(_ byte: UInt8) {
        if inPaste && byte != 0x1B {
            if byte < 0x80 || byte >= 0xC0 { count += 1 } // pasted, so even Return or Ctrl-U is text
            return
        }
        let backslashBefore = afterBackslash
        afterBackslash = false
        switch byte {
        case 0x1B:
            escape = .started
        case 0x0D:
            if !backslashBefore { count = 0 }
        case 0x03, 0x15:
            count = 0
        case 0x08, 0x7F:
            count = max(0, count - 1)
        case 0x00..<0x20:
            break
        case 0x80..<0xC0:
            break // a continuation byte: its character was counted at its first byte
        default:
            count += 1
            afterBackslash = byte == 0x5C
        }
    }

    private mutating func started(_ byte: UInt8) {
        parameter = 0
        switch byte {
        case 0x5B: escape = .control
        case 0x4F: escape = .single
        case 0x1B: escape = .started
        default: escape = .none // Alt with a key, or ESC before Return: moves or newlines, never text taken away
        }
    }

    private mutating func control(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39:
            parameter = min(parameter * 10 + Int(byte - 0x30), 100_000)
        case 0x20...0x3F:
            break
        case 0x40...0x7E:
            escape = .none
            guard byte == 0x7E else { return }
            if parameter == 200 { inPaste = true } else if parameter == 201 { inPaste = false }
        case 0x1B:
            escape = .started
        default:
            escape = .none
        }
    }
}

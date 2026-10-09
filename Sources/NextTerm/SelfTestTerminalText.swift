import AppKit
import NextTermCore
import SwiftTerm

/// The restore's sanitizer against a real terminal (KTD9), which Core's tests cannot link: a headless SwiftTerm
/// `Terminal` fed what a terminal answers or acts on sends its host a reply, and fed the same text through
/// `TerminalText`, as a restored tab's note or scrollback is, sends it nothing and writes no clipboard.
extension SelfTest {
    /// A headless terminal's host: it counts the bytes the terminal sends back, and its clipboard writes.
    private final class TerminalTextHost: TerminalDelegate {
        var sent: [UInt8] = []
        var clipboardWrites = 0

        func send(source: Terminal, data: ArraySlice<UInt8>) { sent += data }
        func clipboardCopy(source: Terminal, content: Data) { clipboardWrites += 1 }
        /// Trusted, so a clipboard write (OSC 52) would get through if the sanitizer let one by.
        func isProcessTrusted(source: Terminal) -> Bool { true }
    }

    /// Device attributes and status queries, a clipboard write and read, Next Term's own integration channel with a
    /// nonce, a settings query (DECRQSS), a title report, the end of a bracketed paste, and 8-bit C1 introducers.
    private static let hostileTerminalText: [String] = [
        "\u{1B}[c", "\u{1B}[>c", "\u{1B}[5n", "\u{1B}[6n",
        "\u{1B}]52;c;aGVsbG8=\u{07}", "\u{1B}]52;c;?\u{1B}\\",
        "\u{1B}]6973;6f1e2d3c4b5a;cmd;bHM=;bHM=\u{07}",
        "\u{1B}P$qm\u{1B}\\", "\u{1B}[21t", "\u{1B}[201~",
        "\u{9B}6n", "\u{9B}c", "\u{9D}52;c;aGVsbG8=\u{9C}",
    ]

    /// What a terminal fed `bytes` sends its host, and how often it writes the clipboard.
    private static func headlessReply(to bytes: [UInt8]) -> (sent: [UInt8], clipboardWrites: Int) {
        let host = TerminalTextHost()
        let terminal = Terminal(delegate: host)
        terminal.feed(byteArray: bytes)
        return (host.sent, host.clipboardWrites)
    }

    static func terminalTextChecks() {
        let raw = hostileTerminalText.joined(separator: "\n")
        let answered = headlessReply(to: Array(raw.utf8))
        check(!answered.sent.isEmpty, "terminal text: a headless terminal answers the hostile list as it is",
              "\(answered.sent.count) bytes")
        let fed = headlessReply(to: Array(TerminalText.feedable(raw).utf8))
        check(fed.sent.isEmpty && fed.clipboardWrites == 0, "terminal text: fed it sanitized, the terminal sends its host nothing",
              "\(fed.sent.count) bytes, \(fed.clipboardWrites) clipboard writes")
        // As raw bytes: a lone 8-bit CSI (not UTF-8) and C1 encoded as UTF-8.
        let bytes: [UInt8] = [0x9B, 0x36, 0x6E, 0xC2, 0x9B, 0x63, 0x1B, 0x5B, 0x63]
        let stray = headlessReply(to: Array(TerminalText.sanitize(utf8: bytes).utf8))
        check(stray.sent.isEmpty, "terminal text: stray 8-bit and C1 bytes, sanitized, get no answer", "\(stray.sent.count) bytes")
        // A restored tab's note about a folder named with escapes.
        var note = RestoreNote(outcome: .idle)
        note.movedFrom = "/Users/x/\u{1B}[6n\u{1B}]52;c;aGk=\u{07}gone"
        note.openedIn = "/Users/x"
        let noted = headlessReply(to: Array(TerminalText.feedable(note.text() ?? "").utf8))
        check(noted.sent.isEmpty && noted.clipboardWrites == 0, "terminal text: a note naming a hostile folder gets no answer",
              note.text() ?? "no note")
    }
}

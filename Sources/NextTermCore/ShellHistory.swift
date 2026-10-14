import Foundation

/// A line Next Term or an agent submits by itself (types, then presses Return for it) stays out of zsh's history: it never
/// comes back on ↑, in zsh-autosuggestions' suggestions, or in the history file. A line Next Term only puts on the line for
/// the user (Suggest a Command's Put on Line, a restored line held, Git's Open Terminal, a drop or a paste) stays in it:
/// the user's own Return makes it theirs.
///
/// The integration's history hook (ZshHistoryScript, `history.zsh` beside its `.zshenv`) binds a private key of its own in
/// every keymap at each new line, then says so with a mark (ShellIntegration):
///
///     ESC ] 6973 ; <nonce> ; hist ; <version> BEL                      zle-line-init: the key is bound
///
/// Just before Next Term presses Return for a line of its own, in the same write, the key names that line:
///
///     ESC [ 6974 ~  h  <6-digit length>  <the line, escaped as CompletionProtocol escapes a field>  CR
///
/// The hook keeps the name for the next line zsh adds to its history and drops it there, whatever that line was, and at
/// each new line and prompt. So it hides one line, only if it is that line to the byte (one the user typed on too, or a
/// paste widget changed, goes in as before), and never a line typed later. Only Next Term writes the key: text anything
/// types, pastes or drops into a tab loses its escape characters (NextTermView), and output never reaches the shell's
/// input. bash, fish, a server's shell and a zsh without the hook have no `hist` mark, so they get a plain Return, as before.
public enum ShellHistory {
    /// ESC [ 6974 ~: as safe as Tab completion's key (CompletionProtocol.prefix), and not that key, so each hook keeps
    /// its own: unbound in stock keymaps, and not the start of any reply a terminal sends.
    public static let prefix = "\u{1b}[6974~"
    /// The hook's version, in its `hist` mark.
    public static let version = 1
    /// The kind letter that names the line about to be submitted.
    static let nameKind = UInt8(ascii: "h")
    /// The longest payload the hook reads, as for Tab completion's frames: a longer line goes into the history as before.
    static let maxPayloadBytes = 65_536

    /// The line zsh's editor holds once Next Term has typed `typed` into it (NextTermView.typeText or typeIn): zsh's
    /// bracketed paste turns each carriage return into a newline.
    public static func heldLine(_ typed: String) -> String {
        typed.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// The private key naming `line` (as zsh holds it): the prefix, `h`, the payload's length and the payload. nil for a
    /// line too long to name.
    public static func naming(_ line: String) -> [UInt8]? {
        let payload = CompletionProtocol.escape(line)
        guard payload.count <= maxPayloadBytes else { return nil }
        let length = String(payload.count)
        let padded = String(repeating: "0", count: max(0, 6 - length.count)) + length
        return Array(prefix.utf8) + [nameKind] + Array(padded.utf8) + payload
    }

    /// What Next Term writes for its own Return after typing `typed`: the key naming the line, then the Return, when the
    /// tab's zsh can take the key now; else the Return alone.
    public static func submit(typed: String, armed: Bool) -> [UInt8] {
        let key = armed ? naming(heldLine(typed)) : nil
        return (key ?? []) + [0x0D]
    }

    /// Whether the tab's zsh can take history's key now: from the hook's `hist` mark until anything ends that line (a
    /// Return, ^C, ^D or ^Z, typed or sent), a command starts, or the shell is replaced. Unknown is never armed.
    public struct Readiness: Equatable, Sendable {
        public private(set) var armed = false
        /// A bracketed paste runs on: its Return is text, not a key.
        private var inPaste = false

        public init() {}

        /// The hook's `hist` mark: a new line, with the key bound.
        public mutating func marked(version: Int) {
            armed = version >= 1
        }

        /// Bytes on their way to the shell, from anyone: one that ends the line ends the key's turn too.
        public mutating func input(_ bytes: some Collection<UInt8>) {
            if InputScan.scan(bytes, inPaste: &inPaste).disarms { armed = false }
        }

        /// A command started, the shell was replaced, or the tab can't be read any more.
        public mutating func disarm() {
            armed = false
            inPaste = false
        }
    }
}

import Foundation

/// The ghost hook's private channel between a local zsh tab and Next Term (see ZshGhostScript): the line being edited,
/// as the user edits it, for suggestions while typing and for what MCP's read_tab reports as typed.
///
/// Shell to app: three more kinds on OSC 6973, behind the tab's nonce (ShellIntegration.parse). Text fields are
/// percent-encoded as Tab completion's are (CompletionProtocol), except that a field of printable ASCII may go as it is
/// but for `%` and `;`:
///
///     ghost ; version ; plugin ; enabled ; strategies          zle-line-init: the hook, and who owns the ghost in this shell
///     buf ; line ; generation ; cursor ; keymap ; context ; flags ; BUFFER ; POSTDISPLAY
///                                                              zle-line-pre-redraw: the line changed, and no key is pending
///     gfb ; generation ; line                                  the shell's own history, asked (empty: nothing)
///
/// The generation goes up at every change of BUFFER, CURSOR or POSTDISPLAY, reported or not, and at each new line, whose
/// number goes up too. The cursor is zsh's CURSOR, in characters. Flags: `l`, BUFFER was over `maxLineBytes` and is sent
/// empty; `L`, the same for POSTDISPLAY; `r`, a region is active; `i`, an incremental search is.
///
/// App to shell: the private key `prefix`, then a frame as CompletionProtocol.frame makes one (a kind letter, a 6-digit
/// id, a 6-digit length and the payload). Its own key, so each hook keeps its own.
public enum GhostProtocol {
    /// ESC [ 6975 ~: as safe as Tab completion's and history's keys (CompletionProtocol.prefix, ShellHistory.prefix), and
    /// neither of them: unbound in stock keymaps, and not the start of any reply a terminal sends.
    public static let prefix = "\u{1b}[6975~"
    /// The hook's version, in its `ghost` mark.
    public static let version = 1
    /// The longest BUFFER or POSTDISPLAY sent, in bytes: a longer one goes empty, flagged.
    public static let maxLineBytes = 2048
    /// How long the hook waits for anything it reads after the private key (seconds), as Tab completion's does.
    public static let frameWait = 0.5

    public static let markKinds: Set<Substring> = ["ghost", "buf", "gfb"]

    // MARK: shell to app

    public enum Message: Equatable, Sendable {
        case hook(Hook)
        case buffer(BufferReport)
        /// The shell's own history for a prefix (the cold start): its newest longer line, or nil for none.
        case fallback(gen: Int, line: String?)
    }

    /// The hook at a new line, and the zsh-autosuggestions it sees in this shell.
    public struct Hook: Equatable, Sendable {
        public var version: Int
        /// "zsh-autosuggestions" when that plugin is loaded, else "".
        public var plugin: String
        /// Its suggestions are on (it is loaded and not disabled).
        public var enabled: Bool
        /// ZSH_AUTOSUGGEST_STRATEGY's words ("atuin history"), whoever set it.
        public var strategies: [String]

        public init(version: Int = GhostProtocol.version, plugin: String = "", enabled: Bool = false, strategies: [String] = []) {
            self.version = version
            self.plugin = plugin
            self.enabled = enabled
            self.strategies = strategies
        }
    }

    /// The line being edited, as the shell has it after a redraw.
    public struct BufferReport: Equatable, Sendable {
        /// The line's number in this shell: a new one is a new line to edit.
        public var line: Int
        public var gen: Int
        /// zsh's CURSOR: characters from the start of BUFFER.
        public var cursor: Int
        public var keymap: String
        public var context: String
        /// BUFFER; nil when it was too long to send or not valid UTF-8.
        public var buffer: String?
        /// POSTDISPLAY (a plugin's ghost); nil when too long or not valid UTF-8.
        public var postdisplay: String?
        public var region: Bool
        public var isearch: Bool

        public init(line: Int, gen: Int, cursor: Int, keymap: String = "main", context: String = "start", buffer: String?,
                    postdisplay: String? = "", region: Bool = false, isearch: Bool = false) {
            self.line = line
            self.gen = gen
            self.cursor = cursor
            self.keymap = keymap
            self.context = context
            self.buffer = buffer
            self.postdisplay = postdisplay
            self.region = region
            self.isearch = isearch
        }

        /// The cursor is at the end of a line Next Term could read (zsh counts code points).
        public var atEnd: Bool { buffer.map { cursor == $0.unicodeScalars.count } ?? false }
    }

    /// Parses a ghost mark's value (after `kind;`). nil: malformed.
    public static func parse(kind: Substring, value: String) -> Message? {
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        switch kind {
        case "ghost":
            guard fields.count == 4, let version = CompletionProtocol.number(fields[0]), version >= 1,
                  fields[2] == "0" || fields[2] == "1" else { return nil }
            let plugin = CompletionProtocol.text(fields[1]).value
            let strategies = CompletionProtocol.text(fields[3]).value.split(separator: " ").map(String.init)
            return .hook(Hook(version: version, plugin: plugin, enabled: fields[2] == "1", strategies: strategies))
        case "buf":
            return parseBuffer(fields)
        case "gfb":
            guard fields.count == 2, let gen = CompletionProtocol.number(fields[0]) else { return nil }
            let line = CompletionProtocol.text(fields[1])
            return .fallback(gen: gen, line: line.valid && !line.value.isEmpty ? line.value : nil)
        default:
            return nil
        }
    }

    private static func parseBuffer(_ fields: [Substring]) -> Message? {
        guard fields.count == 8, let line = CompletionProtocol.number(fields[0]), let gen = CompletionProtocol.number(fields[1]),
              let cursor = CompletionProtocol.number(fields[2]) else { return nil }
        let flags = Set(fields[5])
        let buffer = CompletionProtocol.text(fields[6]), postdisplay = CompletionProtocol.text(fields[7])
        let report = BufferReport(line: line, gen: gen, cursor: cursor, keymap: CompletionProtocol.text(fields[3]).value,
                                  context: CompletionProtocol.text(fields[4]).value,
                                  buffer: flags.contains("l") || !buffer.valid ? nil : buffer.value,
                                  postdisplay: flags.contains("L") || !postdisplay.valid ? nil : postdisplay.value,
                                  region: flags.contains("r"), isearch: flags.contains("i"))
        return .buffer(report)
    }
}

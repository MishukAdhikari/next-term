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
/// The generation goes up at every change of BUFFER, CURSOR, POSTDISPLAY or KEYMAP, reported or not, and at each new line,
/// whose number goes up too. The cursor is zsh's CURSOR, in characters. Flags: `l`, BUFFER was over `maxLineBytes` and is sent
/// empty; `L`, the same for POSTDISPLAY; `r`, a region is active; `i`, an incremental search is.
///
/// The keymap is zsh's KEYMAP, with `main` named as the keymap it is (`emacs` or `viins`; `main` when that couldn't be
/// read).
///
/// App to shell: the private key `prefix`, then a frame as CompletionProtocol.frame makes one (a kind letter, a 6-digit
/// id, a 6-digit length and the payload). Its own key, so each hook keeps its own.
///
///     a  id: the generation   line seen ; new line ; the key's bytes      accept (→, End, ⌃E, ⌃F, ⌥→)
///     o  id: 0                t | g                                       who draws suggestions: Next Term (t) or the plugin (g)
///     f  id: 0                generation ; prefix                         the shell's own history, asked (answered as `gfb`)
///
/// An accept replaces the line only while it is the one Next Term saw, at that generation, with the cursor at its end,
/// and while the key only moves the cursor in that keymap (or does nothing): otherwise the key's own bytes go back to
/// zsh, which does what that key does. `o t` turns zsh-autosuggestions' suggestions off in that shell, and its rebinding
/// at each prompt; `o g` gives back what `t` turned off. Either way the hook then sends its `ghost` mark and the line.
/// `f` asks zsh's in-memory history for the newest line longer than the prefix that starts with it; nothing where it may
/// hold over `maxFallbackHistory` lines (HISTSIZE and HISTCMD both over it). The line doesn't change, so no `buf` follows.
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
    /// The longest payload the hook reads after its key.
    public static let maxPayload = 65_536
    /// zsh's in-memory history is asked only where it can't hold more lines than this (HISTSIZE or HISTCMD, read at no cost;
    /// counting the history costs as much as searching it): a search costs about 2 ms there.
    public static let maxFallbackHistory = 20_000

    // MARK: app to shell

    public enum Kind: UInt8, Sendable {
        case accept = 0x61 // a
        case owner = 0x6F // o
        case fallback = 0x66 // f
    }

    /// An accept: `seen` (the line the suggestion showed on, at generation `gen`) becomes `new`, the cursor at its end; or,
    /// where the shell's line or the key's binding says otherwise, `key` (the bytes that key sends) goes back to zsh. nil
    /// when the frame would be too long for the hook to read.
    public static func acceptFrame(gen: Int, seen: String, new: String, key: [UInt8]) -> [UInt8]? {
        frame(.accept, id: gen, fields: [seen, new, String(decoding: key, as: UTF8.self)])
    }

    /// Who draws suggestions in the shell: `takeOver`, Next Term (zsh-autosuggestions' off); otherwise the plugin again,
    /// where the hook turned it off.
    public static func ownerFrame(takeOver: Bool) -> [UInt8] {
        CompletionProtocol.frame(prefix: prefix, kind: Kind.owner.rawValue, id: 0, fields: [takeOver ? "t" : "g"])
    }

    /// The shell's own history, for the newest line that starts with `prefix` and is longer (the cold start), answered
    /// with generation `gen`. nil when the frame would be too long for the hook.
    public static func fallbackFrame(gen: Int, prefix: String) -> [UInt8]? {
        frame(.fallback, id: 0, fields: [String(gen), prefix])
    }

    static func frame(_ kind: Kind, id: Int, fields: [String]) -> [UInt8]? {
        let bytes = CompletionProtocol.frame(prefix: prefix, kind: kind.rawValue, id: id, fields: fields)
        let header = prefix.utf8.count + 1 + 2 * CompletionProtocol.idWidth
        return bytes.count - header > maxPayload ? nil : bytes
    }

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

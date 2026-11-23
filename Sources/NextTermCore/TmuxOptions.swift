import Foundation

/// The prefix key Next Term's tmux server takes on a host: tmux's own C-b, or one of the three others people move it to.
public enum TmuxPrefix: String, Codable, CaseIterable, Sendable {
    case ctrlB = "C-b"
    case ctrlA = "C-a"
    case ctrlSpace = "C-Space"
    case ctrlBracket = "C-]"

    /// As the popup shows it.
    public var title: String {
        switch self {
        case .ctrlB: return "⌃B (tmux’s own)"
        case .ctrlA: return "⌃A"
        case .ctrlSpace: return "⌃Space"
        case .ctrlBracket: return "⌃]"
        }
    }
}

/// The tmux settings a saved host may change (plan 010a U7): the prefix key and how many lines of history each pane
/// keeps. Written into Next Term's own tmux config on the host, which a tmux server reads as it starts; a server already
/// running takes them as a tab attaches while no other client is attached to it (`liveScript`).
public struct TmuxOptions: Equatable, Sendable {
    public static let defaultHistory = 50_000
    public static let historyRange: ClosedRange<Int> = 1_000...200_000

    public var prefix: TmuxPrefix
    public var history: Int

    public init(prefix: TmuxPrefix = .ctrlB, history: Int = TmuxOptions.defaultHistory) {
        self.prefix = prefix
        self.history = history
    }

    /// Why `history` cannot be used, or nil.
    public static func historyProblem(_ history: Int) -> String? {
        guard !historyRange.contains(history) else { return nil }
        return "tmux history must be between 1,000 and 200,000 lines."
    }

    /// True colour and synchronized output for the terminals Next Term reports itself as. One indexed element, never
    /// appended: reading the config again sets the same element instead of adding another copy. `-q`: a tmux older than
    /// 3.2, which has no terminal-features, says nothing.
    public static let featuresLine = "set -sq 'terminal-features[99]' 'xterm*:RGB:sync'"

    /// The lines in the config: the history, and with another prefix than C-b, that prefix with its double press sending
    /// it on to the pane, and C-b left alone.
    public var configLines: [String] {
        var lines: [String] = ["set -g history-limit \(history)"]
        if prefix != .ctrlB {
            lines += ["set -g prefix \(prefix.rawValue)", "unbind C-b", "bind \(prefix.rawValue) send-prefix"]
        }
        return lines
    }

    /// The same on a running server (`"$T" -L nextterm`, T being tmux's path), run as a tab attaches, only while no
    /// client is attached to it, so a session another Mac shows never changes under it. The server's own prefix is read
    /// first and its double-press binding removed, so going from C-a back to C-b leaves no C-a binding behind; C-b's
    /// own is bound again when C-b is the prefix. History applies to the panes made after.
    public var liveScript: String {
        let tmux = "\"$T\" -L nextterm"
        let prefixKey = RemoteShell.quote(prefix.rawValue)
        return [
            "if [ -n \"$T\" ] && \(tmux) has-session 2>/dev/null && [ -z \"$(\(tmux) list-clients 2>/dev/null)\" ]; then",
            "  nt_op=$(\(tmux) show -gv prefix 2>/dev/null)",
            "  [ -n \"$nt_op\" ] && \(tmux) unbind-key \"$nt_op\" 2>/dev/null",
            "  \(tmux) set -g prefix \(prefixKey) 2>/dev/null",
            "  \(tmux) bind-key \(prefixKey) send-prefix 2>/dev/null",
            "  \(tmux) set -g history-limit \(history) 2>/dev/null",
            "  \(tmux) \(Self.featuresLine) 2>/dev/null",
            "fi",
        ].joined(separator: "\n")
    }
}

/// What New Remote Tab says about the tmux options, and how it reads its history field.
public enum TmuxSettingsText {
    public static let note = "For Next Term’s tmux sessions on this host, as tabs from this Mac open them. A tmux server "
        + "already running there takes them when a tab attaches and no other is attached; history applies to new panes."

    /// The history field: empty is tmux's own default (nil), and so is the default typed out; digits read with their
    /// thousands separators left out; anything else is a number out of range, so the sheet says the range.
    public static func history(_ text: String) -> Int? {
        let separators: Set<Character> = [",", ".", "'", "\u{00A0}", "\u{202F}", "_"]
        let digits: String = text.filter { (character: Character) -> Bool in !character.isWhitespace && !separators.contains(character) }
        guard !digits.isEmpty else { return nil }
        guard let value = Int(digits), value >= 0 else { return -1 }
        return value == TmuxOptions.defaultHistory ? nil : value
    }
}

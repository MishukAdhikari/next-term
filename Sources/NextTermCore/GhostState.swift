import Foundation

/// The facts about a tab, besides its line, that a suggestion needs to show (the app fills them at each report): it is
/// on, the shell has the terminal and the screen, the view shows its last line with no marked text, the Tab list is
/// neither open nor on its way, the terminal has the keyboard in the key window, no agent drives the tab, and no plugin
/// draws its own suggestions there.
public struct GhostGates: Equatable, Sendable {
    /// Suggestions are on, and Private Mode is off.
    public var on: Bool
    /// A tab on this Mac, its shell alone in front with no command running, on the normal screen.
    public var shellAlone: Bool
    /// Scrolled to the bottom, with no marked text (an input method composing).
    public var viewReady: Bool
    /// The Tab list is neither open nor waiting for an answer.
    public var noTabList: Bool
    /// The window is key, and the terminal has the keyboard.
    public var focused: Bool
    /// No agent drives the tab over MCP.
    public var notDriven: Bool
    /// No plugin draws its own suggestions in this shell (GhostOwner).
    public var noPlugin: Bool

    public init(on: Bool = true, shellAlone: Bool = true, viewReady: Bool = true, noTabList: Bool = true, focused: Bool = true,
                notDriven: Bool = true, noPlugin: Bool = true) {
        self.on = on
        self.shellAlone = shellAlone
        self.viewReady = viewReady
        self.noTabList = noTabList
        self.focused = focused
        self.notDriven = notDriven
        self.noPlugin = noPlugin
    }

    public var open: Bool { on && shellAlone && viewReady && noTabList && focused && notDriven && noPlugin }
}

/// The keys that take a suggestion, and the bytes each sends without one, which Next Term writes itself into the accept
/// frame (the hook pushes them back when it doesn't accept): SwiftTerm's own, so a key the hook gives back does what it
/// always does.
public enum GhostKeys {
    public enum Key: Equatable, Sendable {
        case right, end, ctrlE, ctrlF, optionRight, escape
    }

    /// What `key` sends: → and End in the cursor keys' mode (`ESC [ C`, or `ESC O C` with application cursor keys), ⌃E
    /// and ⌃F their control bytes, Esc its own. ⌥→ sends `ESC [ 1 ; 3 C` with Option as Meta, as SwiftTerm 1.20 encodes
    /// it, and nothing without: there accepting a word is all it does.
    public static func bytes(_ key: Key, applicationCursor: Bool, optionAsMeta: Bool) -> [UInt8] {
        let introducer: [UInt8] = applicationCursor ? [0x1B, 0x4F] : [0x1B, 0x5B]
        switch key {
        case .right: return introducer + [0x43]
        case .end: return introducer + [0x46]
        case .ctrlE: return [0x05]
        case .ctrlF: return [0x06]
        case .optionRight: return optionAsMeta ? Array("\u{1b}[1;3C".utf8) : []
        case .escape: return [0x1B]
        }
    }
}

/// One tab's line, as far as suggestions go: what shows, and when to ask the record for one. The app feeds it the ghost
/// hook's reports (GhostProtocol.BufferReport) with the gates, and its answers; it says what to do (`Step`).
///
/// - A suggestion shows only on the first line of a command (context `start`) in emacs or vi insert mode, with the cursor at
///   the end, no region or incremental search, no plugin's ghost (POSTDISPLAY), a non-blank character typed, a key of
///   yours pressed on this line, and every gate open.
/// - A character typed that the suggestion goes on with trims it at once (`trimmed`), with no new ask. Any other change
///   hides it, and asks for the new line.
/// - A deletion at the end hides it until the line grows again. Esc hides it for the rest of the line.
/// - An answer for an older generation than the one asked for is dropped.
public struct GhostState: Sendable {
    public enum Step: Equatable, Sendable {
        /// Ask the record for the newest command starting with `prefix`, for generation `gen`.
        case ask(gen: Int, prefix: String)
        /// The suggestion showing goes on, trimmed by what was typed.
        case trimmed
        /// What showed is hidden.
        case hidden
        /// Nothing to do.
        case none
    }

    /// The keymaps a suggestion shows in.
    public static let keymaps: Set<String> = ["main", "emacs", "viins"]

    public private(set) var shown: GhostSuggestion?
    /// The last report, and the line number it is on.
    public private(set) var report: GhostProtocol.BufferReport?
    /// Esc hid suggestions for the rest of this line.
    public private(set) var lineHidden = false
    /// A deletion at the end hides them until the line grows.
    public private(set) var deletedSinceInsert = false
    /// A key of yours was pressed on this line.
    public private(set) var userKeyed = false
    /// The generation asked for, while its answer is due.
    public private(set) var asked: Int?

    public init() {}

    /// A report of the line, with the gates as they are now.
    public mutating func report(_ new: GhostProtocol.BufferReport, gates: GhostGates) -> Step {
        let previous = report?.line == new.line ? report : nil
        if previous == nil { newLine() }
        report = new
        asked = nil
        guard gates.open, userKeyed, !lineHidden, !new.region, !new.isearch, Self.keymaps.contains(new.keymap), new.context == "start",
              new.atEnd, new.postdisplay?.isEmpty ?? false, let buffer = new.buffer,
              buffer.unicodeScalars.contains(where: { $0 != " " && $0 != "\t" }) else { return hide() }
        if let before = previous?.buffer {
            if buffer.utf8.count < before.utf8.count, before.utf8.starts(with: buffer.utf8) { deletedSinceInsert = true }
            if buffer.utf8.count > before.utf8.count, buffer.utf8.starts(with: before.utf8) { deletedSinceInsert = false }
        }
        if deletedSinceInsert { return hide() }
        if let shown, shown.typed == buffer { return .none }
        if let through = shown?.typedThrough(buffer) {
            shown = through
            return .trimmed
        }
        shown = nil
        asked = new.gen
        return .ask(gen: new.gen, prefix: buffer)
    }

    /// The record's answer for generation `gen`: `command`, the first candidate that passed the checks, shows if that
    /// generation is still the last report's and it still starts with the line. True: it shows.
    public mutating func answer(gen: Int, command: String?) -> Bool {
        guard let asked, asked == gen, let report, report.gen == gen, let buffer = report.buffer else { return false }
        self.asked = nil
        guard let command, let suggestion = GhostSuggestion(typed: buffer, command: command) else { return false }
        shown = suggestion
        return true
    }

    // MARK: keys

    /// Whether `key` is taken while the suggestion shows, in the last report's keymap: ⌃E and ⌃F only in emacs keymaps
    /// (vi insert mode has its own use for them), the others in each keymap a suggestion shows in. Not while nothing
    /// shows.
    public func takes(_ key: GhostKeys.Key) -> Bool {
        guard shown != nil, let keymap = report?.keymap else { return false }
        switch key {
        case .ctrlE, .ctrlF: return keymap != "viins"
        case .right, .end, .optionRight, .escape: return Self.keymaps.contains(keymap)
        }
    }

    /// Esc is taken and never sent in emacs keymaps, as the Tab list takes it; vi insert mode needs it to leave insert
    /// mode, so there it hides the suggestion and goes on to zsh.
    public var escapeGoesOn: Bool { report?.keymap == "viins" }

    /// An accepting key (→, End, ⌃E, ⌃F: the whole command; ⌥→: its next word), with `bytes`, what that key sends: the
    /// frame for the hook (GhostProtocol.acceptFrame), or nil when it isn't taken. The overlay hides at once. After a
    /// word, the suggestion goes on, trimmed, once the shell reports the longer line; after the whole command, the shell's
    /// next report asks again.
    public mutating func accept(_ key: GhostKeys.Key, bytes: [UInt8]) -> [UInt8]? {
        guard key != .escape, takes(key), let shown, let report, report.buffer == shown.typed else { return nil }
        let word = key == .optionRight
        let new = word ? shown.acceptWord : shown.acceptAll
        guard let frame = GhostProtocol.acceptFrame(gen: report.gen, seen: shown.typed, new: new, key: bytes) else { return nil }
        if !word { self.shown = nil }
        asked = nil
        return frame
    }

    /// Esc: hidden for the rest of the line.
    public mutating func escape() {
        lineHidden = true
        shown = nil
        asked = nil
    }

    /// A key of yours was pressed in the tab: suggestions may show on this line.
    public mutating func userKey() {
        userKeyed = true
    }

    /// The line ended (Return, or a command started): nothing shows until the next.
    public mutating func lineEnded() {
        shown = nil
        asked = nil
    }

    /// Hidden by something the line doesn't say (a resize, a scroll, output that moved the caret): until the next report.
    @discardableResult
    public mutating func hide() -> Step {
        guard shown != nil else { return .none }
        shown = nil
        return .hidden
    }

    /// A new line: what Esc, a deletion and your keys said of the last one is over.
    private mutating func newLine() {
        lineHidden = false
        deletedSinceInsert = false
        userKeyed = false
        shown = nil
    }
}

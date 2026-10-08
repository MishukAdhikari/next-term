import Foundation

/// Where one tab's Tab key stands (CompletionSession owns it, with the timers and the writes).
///
///     Disarmed --arm--> Armed --real Tab--> Pending --answer, comp, line--> Open --accept, Esc, left--> Armed
///                                              \--native, timeout, done native--> SteppedBack --typing, arm--> Armed
///
/// Unknown always means Disarmed, and Disarmed sends a plain ^I. The latest `arm` mark says which path a Tab
/// takes: Next Term's own engine, or zsh's completion system. A server tab whose shell has no hook takes a third:
/// the word is read off its screen, and its keys are plain text, never the private key.
public struct CompletionState: Sendable {
    public enum Path: Equatable, Sendable {
        case engine
        case completionSystem
        /// A server's folders and files, for a word on its screen (no hook, so no marks and no private keys).
        case screen
    }

    public enum Phase: Equatable, Sendable {
        case disarmed
        case armed
        /// The private Tab key went out with `id`; the shell answers for it.
        case pending(id: Int, path: Path)
        /// A list for `id`, shown or about to be.
        case open(id: Int, path: Path)
        /// The shell's own Tab ran: plain Tabs until the line changes.
        case steppedBack
    }

    /// The engine's verdict on a `tab` report.
    public enum Verdict: Equatable, Sendable {
        case native
        case insert
        case open
    }

    public private(set) var phase: Phase = .disarmed
    /// The last `arm` mark.
    public private(set) var arm: CompletionProtocol.Arm?
    /// The user's and agents' writes wait, in order: from the private Tab key until the answer (Next Term's
    /// own engine) or 120 ms (zsh's path, which never gets an answer).
    public private(set) var holding = false
    /// The list is on screen: after the first `line` for its id, or the Loading row on zsh's path.
    public private(set) var shown = false
    private var lastID = 0

    public init() {}

    public var isArmed: Bool { phase == .armed }

    public var pendingID: Int? {
        if case let .pending(id, _) = phase { return id }
        return nil
    }

    public var openID: Int? {
        if case let .open(id, _) = phase { return id }
        return nil
    }

    /// The path of the Tab in flight or the list open.
    public var path: Path? {
        switch phase {
        case let .pending(_, path), let .open(_, path): return path
        default: return nil
        }
    }

    /// A new line or keymap: Armed when the shell can take the private key there, else Disarmed. Whatever was
    /// in flight is over.
    public mutating func armed(_ mark: CompletionProtocol.Arm) {
        arm = mark
        reset(to: mark.takesKey ? .armed : .disarmed)
    }

    /// A mark for the same line that only says zsh-autocomplete's state changed: kept, with nothing reset.
    public mutating func update(_ mark: CompletionProtocol.Arm) {
        arm = mark
    }

    /// A command started, the shell was replaced, or the tab can't be read any more.
    public mutating func disarm() {
        reset(to: .disarmed)
    }

    /// The shell was replaced: what its hook last said no longer holds.
    public mutating func forget() {
        arm = nil
        reset(to: .disarmed)
    }

    private mutating func reset(to next: Phase) {
        phase = next
        holding = false
        shown = false
    }

    /// A real Tab in an Armed tab: the id for the private key. nil when the tab isn't Armed (a plain ^I).
    public mutating func startTab() -> Int? {
        guard phase == .armed, let arm else { return nil }
        lastID = lastID % 999_999 + 1
        phase = .pending(id: lastID, path: arm.completionSystem ? .completionSystem : .engine)
        holding = true
        shown = false
        return lastID
    }

    /// A real Tab in a server tab whose shell has no hook: the id for its listing. nil while a Tab is in flight,
    /// a list is open, or the shell's own Tab just ran (a second Tab is the shell's too, as it lists).
    public mutating func startScreenTab() -> Int? {
        guard phase == .disarmed || phase == .armed else { return nil }
        lastID = lastID % 999_999 + 1
        phase = .pending(id: lastID, path: .screen)
        holding = true
        shown = false
        return lastID
    }

    /// Bytes going to the shell (the user's or anyone's), read by `InputScan`.
    public mutating func input(_ scan: InputScan) {
        if scan.disarms {
            reset(to: .disarmed)
        } else if scan.typesInWord, phase == .steppedBack {
            phase = .armed
        }
    }

    /// Next Term answered a `tab` report (its own engine).
    public mutating func answered(_ id: Int, _ verdict: Verdict) {
        guard pendingID == id else { return }
        holding = false
        let current = path ?? .engine
        switch verdict {
        case .native: phase = .steppedBack
        case .insert: phase = .armed
        case .open:
            phase = .open(id: id, path: current)
            // A server's list shows at once: there are no line reports to wait for.
            shown = current == .screen
        }
    }

    /// 120 ms since the private Tab key. Next Term's own engine: no answer yet, so "native" goes out (true).
    /// zsh's path: the held writes go out, and the Tab stays in flight.
    public mutating func holdExpired(_ id: Int) -> Bool {
        guard pendingID == id else { return false }
        holding = false
        guard path == .engine else { return false }
        phase = .steppedBack
        return true
    }

    /// 150 ms on zsh's path with nothing back: the list opens with a Loading row.
    public mutating func loadingDue(_ id: Int) {
        guard case .pending(id, .completionSystem) = phase else { return }
        phase = .open(id: id, path: .completionSystem)
        shown = true
    }

    /// zsh's whole list for `id` arrived.
    public mutating func listed(_ id: Int) {
        guard pendingID == id || openID == id, path == .completionSystem else { return }
        phase = .open(id: id, path: .completionSystem)
        holding = false
        shown = true
    }

    /// The shell finished the Tab itself (`done`): its own Tab ran, or one match went in.
    public mutating func done(_ id: Int, _ outcome: CompletionProtocol.Outcome) {
        guard pendingID == id || openID == id else { return }
        reset(to: outcome == .native ? .steppedBack : .armed)
    }

    /// A `line` report: the first for the open id shows the list; one saying the cursor left the word closes it.
    public mutating func line(_ report: CompletionProtocol.LineReport) {
        guard openID == report.id else { return }
        if report.left {
            reset(to: .armed)
        } else {
            shown = true
        }
    }

    /// Next Term can't show zsh's list (`n` went out): zsh runs its own Tab.
    public mutating func steppedBack(_ id: Int) {
        guard pendingID == id || openID == id else { return }
        reset(to: .steppedBack)
    }

    /// The list closed: a row chosen, Esc, or something that ends it (a resize, another window).
    public mutating func closed() {
        guard openID != nil else { return }
        reset(to: .armed)
    }
}

/// What a write to the shell means for Tab completion.
public struct InputScan: Equatable, Sendable {
    /// Return, Enter, ^J, ^M, ^C, ^D or ^Z outside a bracketed paste (also kitty-encoded): the line ends or
    /// changes hands.
    public var disarms = false
    /// A printable key or Backspace outside a paste: the word changes.
    public var typesInWord = false
    /// A bracketed paste starts.
    public var pasteStarts = false

    public init(disarms: Bool = false, typesInWord: Bool = false, pasteStarts: Bool = false) {
        self.disarms = disarms
        self.typesInWord = typesInWord
        self.pasteStarts = pasteStarts
    }

    /// Reads `bytes`; `inPaste` carries a bracketed paste from one write to the next.
    public static func scan(_ bytes: some Collection<UInt8>, inPaste: inout Bool) -> InputScan {
        var result = InputScan()
        let data = Array(bytes)
        var i = 0
        while i < data.count {
            let byte = data[i]
            if byte == 0x1B {
                let end = sequenceEnd(data, from: i)
                let sequence = data[i..<end]
                if sequence.elementsEqual(Array("\u{1b}[200~".utf8)) {
                    inPaste = true
                    result.pasteStarts = true
                } else if sequence.elementsEqual(Array("\u{1b}[201~".utf8)) {
                    inPaste = false
                } else if !inPaste, isKittyEnding(sequence) {
                    result.disarms = true
                }
                i = end
                continue
            }
            if !inPaste {
                switch byte {
                case 0x0D, 0x0A, 0x03, 0x04, 0x1A: result.disarms = true
                case 0x08, 0x7F, 0x20...0x7E, 0x80...0xFF: result.typesInWord = true
                default: break
                }
            }
            i += 1
        }
        return result
    }

    /// Where an escape sequence starting at `start` ends: a CSI's final byte, an SS3 key's, or the byte after ESC.
    private static func sequenceEnd(_ data: [UInt8], from start: Int) -> Int {
        var i = start + 1
        guard i < data.count else { return i }
        if data[i] == UInt8(ascii: "O") { return min(i + 2, data.count) }
        guard data[i] == UInt8(ascii: "[") else { return i + 1 }
        i += 1
        while i < data.count, !(0x40...0x7E).contains(data[i]) { i += 1 }
        return min(i + 1, data.count)
    }

    /// CSI 13 u (Return), and ^C, ^D, ^J, ^M, ^Z as the kitty keyboard protocol sends them (CSI 99;5 u …).
    private static func isKittyEnding(_ sequence: ArraySlice<UInt8>) -> Bool {
        guard sequence.last == UInt8(ascii: "u"), let text = String(bytes: sequence.dropFirst(2).dropLast(), encoding: .ascii) else { return false }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard let key = parts.first.flatMap({ Int($0.split(separator: ":").first ?? "") }) else { return false }
        if key == 13 { return true }
        let modifiers = parts.count > 1 ? Int(parts[1].split(separator: ":").first ?? "") ?? 1 : 1
        let control = (modifiers - 1) & 4 != 0
        return control && [99, 100, 106, 109, 122].contains(key)
    }
}

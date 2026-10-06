import Foundation

/// What a tab's status dot shows.
public enum TabState: String, Sendable {
    case idle, working, done, failed, attention
}

/// Something worth a system notification.
public struct TabNotice: Equatable, Sendable {
    public let state: TabState
    public let command: String
}

/// The per-tab status state machine. Pure logic, driven by events with explicit timestamps
/// (seconds), so it is fully unit-testable.
public struct TabStatus {
    /// Output this soon after a keystroke or resize is echo or redraw, not work.
    public static let echoWindow: TimeInterval = 0.2
    /// An agent silent for this long has stopped and is waiting for you.
    public static let quietAfter: TimeInterval = 2.5
    /// Only notify for work that took at least this long.
    public static let notifyAfter: TimeInterval = 5

    /// The user is looking at this tab (active tab of the key window).
    public private(set) var visible = false
    /// Shell integration reported in; process polling is then ignored.
    public private(set) var integrated = false
    public private(set) var running = false
    public private(set) var command = ""
    /// Program name of `command`, worked out once when it starts.
    public private(set) var program = ""
    public private(set) var kind: CommandKind = .command
    public private(set) var exitCode: Int32?
    /// done / failed / attention the user has not seen yet.
    public private(set) var unseen: TabState?

    private var startedAt: TimeInterval = 0
    private var lastInputAt: TimeInterval = -.infinity
    private var lastOutputAt: TimeInterval = -.infinity
    private var busy = false
    private var busySince: TimeInterval = 0
    private var pendingNotice: TabNotice?

    public init() {}

    public var state: TabState {
        if unseen == .attention { return .attention }
        if running && (kind == .command || busy) { return .working }
        return unseen ?? .idle
    }

    // MARK: events

    public mutating func commandStarted(_ commandLine: String, at now: TimeInterval) {
        if commandLine.split(separator: " ").first == "exec" {
            // `exec zsh`, `exec ssh …`: this shell, and its integration, is being replaced.
            // Hand over to process polling, which follows whatever runs next.
            integrated = false
            return
        }
        integrated = true
        start(commandLine, at: now)
    }

    public mutating func commandFinished(exitCode code: Int32?, at now: TimeInterval) {
        integrated = true
        guard running else { return } // a bare Enter at the prompt
        finish(exitCode: code, at: now)
    }

    /// Fallback for shells without integration: the pty's foreground process name, polled.
    public mutating func foregroundProcess(_ name: String, shell: String, at now: TimeInterval) {
        guard !integrated else { return }
        // Compare raw process names: "sudo" is a wrapper word to the classifier but a real process here.
        let process = Self.baseName(name)
        let isShell = process.isEmpty || process == Self.baseName(shell)
        if !isShell && !running {
            start(name, at: now)
        } else if !isShell && process != Self.baseName(command) {
            command = name
            program = CommandClassifier.programName(name)
            kind = CommandClassifier.kind(of: name)
        } else if isShell && running {
            finish(exitCode: nil, at: now)
        }
    }

    public mutating func input(at now: TimeInterval) { lastInputAt = now }
    public mutating func resized(at now: TimeInterval) { lastInputAt = now }

    public mutating func output(at now: TimeInterval) {
        if now - lastInputAt < Self.echoWindow { return }
        lastOutputAt = now
        if running && kind != .command && !busy {
            busy = true
            busySince = now
            if unseen == .done { unseen = nil }
        }
    }

    /// BEL, or an OSC 9 / OSC 777 notification from the program.
    public mutating func bell() {
        mark(.attention, duration: .infinity)
    }

    /// Call a few times a second.
    public mutating func tick(at now: TimeInterval) {
        guard busy, now - lastOutputAt >= Self.quietAfter else { return }
        busy = false
        if running && kind == .agent { mark(.done, duration: lastOutputAt - busySince) }
    }

    public mutating func setVisible(_ isVisible: Bool) {
        visible = isVisible
        if isVisible { unseen = nil }
    }

    public mutating func takeNotice() -> TabNotice? {
        defer { pendingNotice = nil }
        return pendingNotice
    }

    // MARK: internals

    /// "/bin/zsh" -> "zsh", "-zsh" (a login shell's argv[0]) -> "zsh".
    private static func baseName(_ path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return last.hasPrefix("-") ? String(last.dropFirst()) : last
    }

    private mutating func start(_ commandLine: String, at now: TimeInterval) {
        running = true
        command = commandLine
        program = CommandClassifier.programName(commandLine)
        kind = CommandClassifier.kind(of: commandLine)
        startedAt = now
        busy = false
        exitCode = nil
        if unseen == .done || unseen == .failed { unseen = nil }
    }

    private mutating func finish(exitCode code: Int32?, at now: TimeInterval) {
        let finishedKind = kind
        running = false
        busy = false
        exitCode = code
        // Leaving vim or ssh is not news.
        if finishedKind == .interactive { return }
        mark(code == nil || code == 0 ? .done : .failed, duration: now - startedAt)
    }

    /// Something happened the user should know about. Ignored while they are looking at the tab.
    private mutating func mark(_ newState: TabState, duration: TimeInterval) {
        guard !visible else { return }
        let wasAttention = unseen == .attention
        if !wasAttention || newState == .attention { unseen = newState }
        // Attention notifies once until seen: a program ringing the bell in a loop is one notice, not 500.
        let notify = newState == .attention ? !wasAttention : duration >= Self.notifyAfter
        if notify { pendingNotice = TabNotice(state: newState, command: command) }
    }
}

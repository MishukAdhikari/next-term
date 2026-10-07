import Foundation

/// What a tab's status dot shows.
public enum TabState: String, Sendable {
    case idle, working, done, failed, attention
}

/// Something worth a system notification.
public struct TabNotice: Equatable, Sendable {
    public let state: TabState
    public let command: String
    public let program: String
    public let kind: CommandKind
    /// The program is still running (an agent waiting for input), as opposed to finished.
    public let stillRunning: Bool
    /// An agent's question when it is blocked on a decision ("Do you want to make this edit to x?").
    public var question: String? = nil
    /// How long the work took, for a finished command or an agent that stopped; infinite for a bell.
    public var duration: TimeInterval = 0
    /// The attention came from the program itself (a bell, OSC 9 or OSC 777), not from Next Term.
    public var fromProgram = false

    public init(state: TabState, command: String, program: String, kind: CommandKind, stillRunning: Bool,
                question: String? = nil, duration: TimeInterval = 0, fromProgram: Bool = false) {
        self.state = state
        self.command = command
        self.program = program
        self.kind = kind
        self.stillRunning = stillRunning
        self.question = question
        self.duration = duration
        self.fromProgram = fromProgram
    }
}

/// The per-tab status state machine. Pure logic, driven by events with explicit timestamps
/// (seconds), so it is fully unit-testable.
public struct TabStatus {
    /// Output this soon after a keystroke or resize is echo or redraw, not work.
    public static let echoWindow: TimeInterval = 0.2
    /// An agent silent for this long has stopped and is waiting for you.
    public static let quietAfter: TimeInterval = 2.5
    /// Only notify for work that took at least this long: the shortest choice in Settings › Notifications,
    /// which can ask for longer (NotificationSettings).
    public static let notifyAfter: TimeInterval = 5
    /// An agent's screen must say it stopped for this long before its notice goes out: one frame without
    /// the working hint (drawn halfway between two chunks, or the hint cut short in a narrow pane) is not a stop.
    public static let stopSettles: TimeInterval = 1

    /// The user is looking at this tab (active tab of the key window).
    public private(set) var visible = false
    /// Shell integration reported in; process polling then only refines what it says.
    public private(set) var integrated = false
    public private(set) var running = false
    /// The command line as typed.
    public private(set) var command = ""
    /// `command` with its aliases expanded (`gl` is `git pull` with oh-my-zsh), from the shell
    /// integration; empty when nothing in it was expanded.
    public private(set) var expandedCommand = ""
    /// Program name of `command`, worked out once when it starts.
    public private(set) var program = ""
    public private(set) var kind: CommandKind = .command
    public private(set) var exitCode: Int32?
    /// done / failed / attention the user has not seen yet.
    public private(set) var unseen: TabState?
    /// The question an agent is waiting on you to answer, read from its screen.
    public private(set) var question: String?
    /// Counts the questions asked in this tab: a new question (even with the same words) gets a new
    /// number, so an answer meant for one never lands on the next (see MCPServer.questionID).
    public private(set) var questionSerial = 0
    /// The agent's own screen has shown its working or question hint during this run, so the screen is
    /// trusted over output timing (an idle agent may keep redrawing a status line).
    public private(set) var screenSynced = false
    /// Jobs the shell holds (suspended or in the background), reported by the zsh integration.
    public private(set) var jobs = 0
    public private(set) var jobSummary = ""
    /// Commands started so far (with or without integration): something ran, however briefly.
    public private(set) var commandsStarted = 0

    private var startedAt: TimeInterval = 0
    private var lastInputAt: TimeInterval = -.infinity
    private var lastOutputAt: TimeInterval = -.infinity
    private var busy = false
    private var busySince: TimeInterval = 0
    /// Kernel name of the polled foreground process, to notice when it changes.
    private var polledName = ""
    private var pendingNotice: TabNotice?
    /// The agent's screen said it stopped: when, since when it had worked, and the notice that waits for
    /// `stopSettles` (see tick()). Working again before then is the same turn.
    private var lastStop: (at: TimeInterval, since: TimeInterval, notice: TabNotice?)?

    public init() {}

    /// The status mark. Only AI agents show "working", in step with what the agent itself shows;
    /// other programs show nothing while they run, then done or failed.
    public var state: TabState {
        if unseen == .attention || question != nil { return .attention }
        if running && kind == .agent && busy { return .working }
        return unseen ?? .idle
    }

    // MARK: events from the shell integration

    /// `typed` is the line as entered; `expanded` has aliases expanded (zsh's preexec $3), which is how
    /// `claude-auto` (an alias for `claude …`) is recognised as an agent.
    public mutating func commandStarted(_ typed: String, expanded: String? = nil, at now: TimeInterval) {
        if typed.trimmingCharacters(in: .whitespaces).hasPrefix("exec ") {
            // `exec zsh`, `exec ssh …`: this shell, and its integration, is being replaced.
            // Process polling follows whatever runs next. (Execs hidden in functions or aliases,
            // like `omz reload`, are caught by the kernel instead: see shellReplaced().)
            shellReplaced()
            return
        }
        integrated = true
        start(typed, kind: max(CommandClassifier.kind(of: typed), expanded.map(CommandClassifier.kind(of:)) ?? .command), at: now)
        expandedCommand = expanded ?? ""
        let typedProgram = CommandClassifier.programName(typed)
        if typedProgram.isEmpty, let expanded { program = CommandClassifier.programName(expanded) }
    }

    public mutating func commandFinished(exitCode code: Int32?, at now: TimeInterval) {
        integrated = true
        guard running else { return } // a bare Enter at the prompt
        finish(exitCode: code, at: now)
    }

    public mutating func jobsChanged(count: Int, summary: String) {
        jobs = max(0, count)
        jobSummary = summary
    }

    /// The kernel saw the shell process exec something else: its integration is gone.
    public mutating func shellReplaced() {
        integrated = false
        running = false
        busy = false
        question = nil // whatever asked it is gone with the shell
        screenSynced = false
        lastStop = nil
        jobs = 0
        jobSummary = ""
        polledName = ""
    }

    /// The shell itself ended with a non-zero status; the tab stays open to show why.
    public mutating func shellExited(code: Int32?) {
        running = false
        busy = false
        lastStop = nil
        exitCode = code
        mark(.failed, duration: 0)
    }

    // MARK: events from polling the pty's foreground process (twice a second)

    /// `process` nil means the foreground could not be read (for example, a pipeline's first
    /// process already exited): keep the current state rather than guess "idle".
    public mutating func observe(_ process: ForegroundProcess?, at now: TimeInterval) {
        guard let process else { return }
        if integrated {
            // The integration knows when commands start and end. Polling only sees through what the
            // command line hides: a shell function such as `claude-auto-danger` that runs an agent.
            if running, kind == .command, !process.isShell, CommandClassifier.kind(of: process) == .agent {
                kind = .agent
                program = CommandClassifier.programName(of: process)
                busy = now - lastOutputAt < Self.quietAfter
                busySince = now
            }
            return
        }
        if process.isShell {
            if running { finish(exitCode: nil, at: now) }
            polledName = ""
            return
        }
        if !running || process.name != polledName {
            let wasRunning = running
            let started = startedAt
            start(process.commandLine, kind: CommandClassifier.kind(of: process), at: now)
            program = CommandClassifier.programName(of: process)
            if wasRunning { startedAt = started } // same job, different process in front
        }
        polledName = process.name
    }

    // MARK: a remote tab whose agents a host reports (herdr)

    /// The tab shows a program that hosts agents and reports their state itself (herdr on a server):
    /// treat it as one agent, so `observe(agentScreen:)` takes the states the host reports.
    public mutating func observeAgentHost(_ name: String, at now: TimeInterval) {
        if running && kind == .agent && program == name { return }
        start(name, kind: .agent, at: now)
        program = name
        screenSynced = true // the host's report is the truth; its UI redrawing is not work
    }

    // MARK: what an agent's screen shows

    /// Call a few times a second for a running agent with what its screen shows.
    public mutating func observe(agentScreen activity: AgentActivity, at now: TimeInterval) {
        guard running, kind == .agent else { return }
        settleStop(at: now)
        switch activity {
        case .working:
            screenSynced = true
            answered()
            if !busy {
                busy = true
                // Within a second of a stop: one frame without the hint, and the same turn goes on.
                busySince = lastStop?.since ?? now
                if unseen == .done { unseen = nil }
            }
            lastStop = nil
        case .asking(let asked):
            screenSynced = true
            if busy { busy = false }
            lastStop = nil // a decision, not a finish
            guard question != asked else { return }
            question = asked
            questionSerial += 1
            askedAt = now
            markQuestion(asked)
        case .idle:
            // Before the screen has shown its hints this run, the output timing decides (see tick()).
            guard screenSynced else { return }
            answered()
            if busy {
                busy = false
                lastStop = (now, busySince, marked(.done, duration: now - busySince))
            }
        }
    }

    private var askedAt: TimeInterval = 0
    /// The amber mark came from a question, so answering it clears the mark.
    private var markedForQuestion = false

    /// The question went away (answered, or the agent moved on).
    private mutating func answered() {
        guard question != nil else { return }
        question = nil
        if markedForQuestion && unseen == .attention { unseen = nil }
        markedForQuestion = false
    }

    /// A decision is needed: amber mark and a notification, even if the agent only just started.
    private mutating func markQuestion(_ asked: String) {
        guard !visible else { return }
        unseen = .attention
        markedForQuestion = true
        pendingNotice = TabNotice(state: .attention, command: command, program: program, kind: kind, stillRunning: true, question: asked)
    }

    // MARK: activity

    public mutating func input(at now: TimeInterval) { lastInputAt = now }
    public mutating func resized(at now: TimeInterval) { lastInputAt = now }

    public mutating func output(at now: TimeInterval) {
        if now - lastInputAt < Self.echoWindow { return }
        lastOutputAt = now
        if screenSynced { return } // the agent's screen says when it works
        if running && kind != .command && !busy {
            busy = true
            busySince = now
            if unseen == .done { unseen = nil }
        }
    }

    /// BEL, or an OSC 9 / OSC 777 notification from the program.
    public mutating func bell() {
        mark(.attention, duration: .infinity, fromProgram: true)
    }

    /// Next Term's own call to the tab, such as ssh asking for a password: attention like a bell, but not
    /// the program's, so the setting for programs' bells leaves it alone.
    public mutating func needsAttention() {
        mark(.attention, duration: .infinity)
    }

    /// Call a few times a second.
    public mutating func tick(at now: TimeInterval) {
        settleStop(at: now)
        guard busy, !screenSynced, now - lastOutputAt >= Self.quietAfter else { return }
        busy = false
        if running && kind == .agent { mark(.done, duration: lastOutputAt - busySince) }
    }

    /// The screen has said the agent stopped for `stopSettles`: the stop is real, and its notice goes out
    /// (unless you have looked at the tab since).
    private mutating func settleStop(at now: TimeInterval) {
        guard let stop = lastStop, now - stop.at >= Self.stopSettles else { return }
        lastStop = nil
        if let notice = stop.notice, !visible { pendingNotice = notice }
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

    private mutating func start(_ commandLine: String, kind newKind: CommandKind, at now: TimeInterval) {
        commandsStarted += 1
        running = true
        command = commandLine
        expandedCommand = ""
        program = CommandClassifier.programName(commandLine)
        kind = newKind
        startedAt = now
        busy = false
        lastStop = nil
        question = nil
        screenSynced = false
        exitCode = nil
        if unseen == .done || unseen == .failed { unseen = nil }
    }

    private mutating func finish(exitCode code: Int32?, at now: TimeInterval) {
        let finishedKind = kind
        running = false
        busy = false
        lastStop = nil // the agent exited: that is the news, not its last stop
        question = nil
        exitCode = code
        // Leaving vim or ssh is not news.
        if finishedKind == .interactive { return }
        mark(code == nil || code == 0 ? .done : .failed, duration: now - startedAt)
    }

    /// Something happened the user should know about. Ignored while they are looking at the tab.
    private mutating func mark(_ newState: TabState, duration: TimeInterval, fromProgram: Bool = false) {
        if let notice = marked(newState, duration: duration, fromProgram: fromProgram) { pendingNotice = notice }
    }

    /// Marks the tab, and returns the notice it is worth (nil: none), for the caller to post or hold.
    private mutating func marked(_ newState: TabState, duration: TimeInterval, fromProgram: Bool = false) -> TabNotice? {
        guard !visible else { return nil }
        let wasAttention = unseen == .attention
        if !wasAttention || newState == .attention { unseen = newState }
        // Attention notifies once until seen: a program ringing the bell in a loop is one notice, not 500.
        let notify = newState == .attention ? !wasAttention : duration >= Self.notifyAfter
        guard notify else { return nil }
        return TabNotice(state: newState, command: command, program: program, kind: kind, stillRunning: running,
                         duration: duration, fromProgram: fromProgram)
    }
}

import Darwin
import Foundation
import NextTermCore

/// What a driver uses of its session (plan 037 KTD2): the model it builds, the line to the agent, the facts the session
/// reports, and the ways a session changes or ends. `AgentSessionEngine` is the one implementation; a driver never knows who
/// shows the session (a terminal tab's `nxtrm agent`, or a chat tab). Main queue only.
protocol AgentSessionContext: AnyObject {
    var agent: ACPAgent { get }
    var program: String { get }
    /// The folder the agent runs in.
    var folder: String { get }
    /// The agent's environment; nil: the process's own (`nxtrm agent` in a tab).
    var environment: [String: String]? { get }
    var session: ACPSession { get set }
    /// The first prompt, sent once the session is ready (and cleared then).
    var firstPrompt: String? { get set }
    /// The conversation to go on with: Claude Code's session id, Codex's thread id.
    var resumeID: String? { get }
    /// A resume that can't go on ends the session (`resumeCannotGoOn`) instead of starting a new conversation.
    var resumeOnly: Bool { get }
    /// The session went on with `resumeID`'s conversation.
    var resumed: Bool { get set }
    var agentVersion: String? { get set }
    var model: String? { get set }
    var sessionID: String? { get set }
    /// What the input says instead of the prompt while the session waits on the Mac (Claude Code's folder trust).
    var waitingLine: String? { get set }
    /// A menu or a question is open, or an Allow always is asked on the Mac: the drift watch never counts it.
    var isWaitingOnUser: Bool { get }
    /// Next Term's MCP server for the agent, when it can be given one.
    var nextTermMCPServer: ACPWire.StdioServer? { get }
    var bridge: AgentSessionBridge { get }

    /// A line to the agent; one that has quit takes nothing.
    func sendToAgent(_ data: Data)
    /// The session changed: shown at once.
    func changed()
    /// A streamed chunk: shown soon, many at once.
    func changedSoon()
    /// A turn ended: what it showed stays as shown.
    func turnFinished()
    /// The state for the app and the tab, when it differs from the last report.
    func report()
    /// The session ends with `message` as its last note.
    func fatal(_ message: String)
    /// The agent needs the user to sign in (only its own terminal interface does that): the session ends with `message`.
    func needsSignIn(_ message: String)
    /// A resume with `resumeOnly` couldn't go on: the session ends, starting no new conversation. `why` is the agent's own
    /// words, when it said any.
    func resumeCannotGoOn(why: String)
    /// Output that isn't the agent's protocol, kept for the line that says why it quit.
    func keepWords(_ data: Data)
}

/// The app's side of a session (plan 037 KTD2): where its reports go, and who asks on the Mac for an Allow always and for
/// Claude Code's folder trust. `nxtrm agent` asks over Next Term's socket (`AgentSessionSocketBridge`); a chat tab asks
/// the app directly (`ChatAppBridge`). Answers come on the main queue.
protocol AgentSessionBridge: AnyObject {
    /// The app can be asked: reports reach it, and an Allow always or a folder can be asked about on the Mac.
    var isConnected: Bool { get }
    /// Next Term's MCP server can be given to the agent.
    var offersMCP: Bool { get }
    /// The session's state; `then` gets the app's answer (`previous_version` when this agent's version changed), or nil.
    func report(_ update: [String: Any], then: @escaping ([String: Any]?) -> Void)
    /// An Allow always, asked of the user on the Mac by click: true only when they approved.
    func confirmAlways(agent: String, action: String, option: String, then: @escaping (Bool) -> Void)
    /// A folder for Claude Code, trusted already or asked on the Mac by click: true when trusted, false when declined,
    /// nil when the app didn't answer.
    func trustFolder(agent: String, folder: String, then: @escaping (Bool?) -> Void)
}

/// Who shows a session (plan 037 KTD2): `AgentSessionTerminal` draws it as text in the tab `nxtrm agent` runs in, byte for
/// byte as before the split; a chat tab's host draws it natively. Main queue only.
protocol AgentSessionPresenter: AnyObject {
    /// The tab's title, once at the start.
    func writeTitle(_ title: String)
    /// Show the session now.
    func changed()
    /// Show the session soon: streamed chunks coalesce.
    func changedSoon()
    /// A turn ended.
    func turnFinished()
    /// The state OSC 7501 carries (`state=working:app=nxtrm-agent`, ...), when the tab hears the session's state that way.
    func stateReported(_ fields: String)
    /// The session ended; the process and the driver are done.
    func ended(code: Int32)
    /// Claude Code couldn't go on with a resumed session and `resumeOnly` is off: the session starts again without it.
    func startAfresh()
    /// The agent's process started, as `pid` (a chat tab's MCP identity, KTD8).
    func agentStarted(pid: pid_t)
}

extension AgentSessionPresenter {
    func agentStarted(pid: pid_t) {}
}

/// One agent session (plan 037 KTD2): the agent's process, the driver that speaks its protocol, the session model, the
/// Allow always rule, the reports, the drift watch's ends and the version note. The presenter shows it; the bridge is the
/// app. Main queue only.
final class AgentSessionEngine: AgentSessionContext {
    /// How a session ended, for the chat's end card.
    enum Ending: Equatable {
        /// The agent quit by itself, with its exit status and its last words.
        case quit(status: Int32, words: String)
        /// The session couldn't go on: the note says why (drift, a refused start, a declined trust).
        case fatal(String)
        /// The agent wants a sign-in, which only its terminal interface does.
        case signIn(String)
        /// A resume with `resumeOnly` couldn't go on.
        case resumeFailed(String)
        /// The user (or the tab's close) ended it.
        case closed
    }

    let agent: ACPAgent
    let program: String
    let folder: String
    let environment: [String: String]?
    var firstPrompt: String?
    var resumeID: String?
    var resumeOnly = false
    var resumed = false
    let bridge: AgentSessionBridge
    weak var presenter: AgentSessionPresenter?

    /// How long a session's handshake may take before it ends with the drift note (plan 035 U7). The self-test's
    /// stand-ins shorten it, in a debug build only.
    static let startupTimeout: TimeInterval = {
        #if DEBUG
        if let given = ProcessInfo.processInfo.environment["NEXTTERM_SELFTEST_STARTUP_TIMEOUT"].flatMap(TimeInterval.init), given > 0 {
            return given
        }
        #endif
        return ProtocolDriftWatch.startupTimeout
    }()

    /// What the session reports to the app (plan 035 U7): the CLI's version, the model, and the session's id, which the
    /// tab's saved state keeps so an update brings the session back.
    var agentVersion: String?
    var model: String?
    var sessionID: String?

    private let process: AgentSessionProcess
    private var buffer = Data()
    /// The agent's last words on stderr, shown if it quits.
    private var errorTail = ""

    var session = ACPSession()
    var waitingLine: String?

    /// How the session ended; nil while it runs.
    private(set) var ending: Ending?
    var isEnded: Bool { ending != nil }
    /// Turns ended so far, as reported.
    private(set) var turnsEnded = 0
    private var lastReport = ""
    /// The version change was told: once a session.
    private var toldVersion = false

    private lazy var driver: AgentSessionDriver = {
        switch agent.protocolKind {
        case .acp: return ACPDriver(context: self)
        case .claudeStream: return ClaudeDriver(context: self)
        case .codexAppServer: return CodexDriver(context: self)
        }
    }()

    init(agent: ACPAgent, program: String, folder: String, firstPrompt: String?, launch: AgentSessionProcess.Mode,
         bridge: AgentSessionBridge) {
        self.agent = agent
        self.program = program
        self.folder = folder
        self.firstPrompt = firstPrompt
        self.bridge = bridge
        process = AgentSessionProcess(launch)
        if case .ownGroup(let environment) = launch { self.environment = environment } else { environment = nil }
    }

    /// The agent's process id while it runs (a chat tab's MCP identity, plan 037 KTD8).
    var agentPid: pid_t? { process.isRunning ? process.pid : nil }

    func start() {
        presenter?.writeTitle(agent.name)
        session.note("Starting \(agent.name) (\(driver.startWords))\u{2026}")
        changed()
        reportStart()
        driver.prepare { [weak self] in self?.spawn() }
    }

    private func spawn() {
        guard !isEnded else { return }
        process.onOutput = { [weak self] data in self?.received(data) }
        process.onErrors = { [weak self] data in
            guard let self else { return }
            self.errorTail = String((self.errorTail + String(decoding: data, as: UTF8.self)).suffix(2000))
        }
        process.onExit = { [weak self] status in self?.agentQuit(status) }
        do {
            try process.run(program, driver.arguments, in: folder)
        } catch {
            session.note("Couldn\u{2019}t start \(agent.name): \(error.localizedDescription)")
            return finish(1)
        }
        if process.pid > 0 { presenter?.agentStarted(pid: process.pid) }
        driver.started()
    }

    /// Next Term's MCP server for the agent, in a Next Term tab (R26, plan 035 R11): the command the other tabs'
    /// agents are given, under the name a user-scope entry has, so it replaces that entry rather than doubling it.
    var nextTermMCPServer: ACPWire.StdioServer? {
        guard bridge.offersMCP, let me = Bundle.main.executablePath else { return nil }
        return .init(name: MCPRegistrar.serverName, command: me, arguments: ["--cli", "mcp"])
    }

    // MARK: the protocol

    private func received(_ data: Data) {
        guard !data.isEmpty, !isEnded else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            driver.received(line: Data(line))
            if isEnded { return }
        }
        // A line that never ends isn't kept past 16 MB.
        if buffer.count > 16 << 20 { buffer.removeAll() }
    }

    func sendToAgent(_ data: Data) {
        process.write(data)
    }

    /// The session takes prompts: its handshake is done, no turn runs, and it hasn't ended.
    var isReady: Bool { !isEnded && driver.isReady }

    /// A prompt typed and sent.
    func send(_ text: String) {
        guard !isEnded else { return }
        driver.send(text)
    }

    /// The terminal-only command `text` is (`/login`, `/mcp`, ...), which a chat doesn't send; nil for any other prompt.
    func terminalOnlyCommand(_ text: String) -> String? {
        agent.terminalOnly(text)
    }

    /// ⌃C, Esc or ⌘.: the turn stops, an open request answered cancel or deny.
    func cancelTurn() {
        guard !isEnded else { return }
        driver.cancelTurn()
    }

    /// Moves the open menu's highlight (up is -1).
    func moveHighlight(_ step: Int) {
        session.moveHighlight(step)
        changed()
    }

    /// An Allow always waiting for the user's OK on the Mac: the menu takes no other answer meanwhile.
    private(set) var confirming = false

    var isWaitingOnUser: Bool { session.pending != nil || confirming }

    /// Option `index` of the open menu, picked by a key, a click, a notification's button or `answer_agent`.
    func choose(_ index: Int) {
        guard !isEnded, !confirming, let option = session.option(at: index) else { return }
        guard option.kind == "allow_always" else { return answer(index) }
        // A standing permission is the one answer that outlives the question: asked of the user on the Mac first, as the
        // tab's keys can't tell them from an agent steering the session (R16).
        guard bridge.isConnected, let permission = session.pending else {
            session.note("\u{201C}\(option.name)\u{201D} needs your OK in Next Term, which this session can\u{2019}t reach; pick another option.")
            return changed()
        }
        confirming = true
        session.note("Waiting for your OK on the Mac for \u{201C}\(option.name)\u{201D}\u{2026}")
        changed()
        bridge.confirmAlways(agent: agent.name, action: permission.action, option: option.name) { [weak self] approved in
            guard let self else { return }
            self.confirming = false
            // Still the same request: the turn wasn't stopped meanwhile.
            guard !self.isEnded, self.session.pending?.requestID == permission.requestID else { return self.changed() }
            if approved {
                self.answer(index)
            } else {
                self.session.note("\u{201C}\(option.name)\u{201D} was declined on the Mac; the request is still open.")
                self.changed()
            }
        }
    }

    private func answer(_ index: Int) {
        driver.answer(index)
        report()
        changed()
    }

    // MARK: showing

    func changed() { presenter?.changed() }

    func changedSoon() { presenter?.changedSoon() }

    func turnFinished() { presenter?.turnFinished() }

    // MARK: the app

    /// The state as the app keeps it: working, attention, done or idle.
    var reportedState: String {
        session.pending != nil ? "attention" : (session.working ? "working" : (session.lastStop == nil ? "idle" : "done"))
    }

    /// The state for the app (stop reason, last message), then OSC 7501 for the tab: working, blocked on a permission
    /// (with the question's words), or done. In order, so wait_for_tab never finds a turn done before its last message.
    func report() {
        var fields = "app=nxtrm-agent"
        if let permission = session.pending {
            // Cut by characters, never inside one: words that don't decode would drop the whole report.
            var asked = ACPTranscript.question(permission)
            while asked.utf8.count > 1500 { asked.removeLast() }
            let words = Data(asked.utf8).base64EncodedString()
            fields = "state=blocked:kind=permission:msg=" + words + ":" + fields
        } else if session.working {
            fields = "state=working:" + fields
        } else {
            fields = (session.lastStop == nil ? "state=idle:" : "state=done:") + fields
        }
        // A new version, model or session id is reported too, though the tab's state stays the same.
        let key = [fields, agentVersion ?? "", model ?? "", sessionID ?? ""].joined(separator: "\n")
        guard key != lastReport else { return }
        let stateChanged = !lastReport.hasPrefix(fields + "\n")
        lastReport = key
        guard bridge.isConnected else { presenter?.stateReported(fields); return }
        let state = reportedState
        if state == "done", stateChanged { turnsEnded += 1 }
        var update: [String: Any] = ["op": "report", "agent": agent.name, "state": state, "turns": turnsEnded,
                                     "last_message": session.lastMessage]
        if let stop = session.lastStop { update["stop_reason"] = stop.rawValue }
        update["agent_id"] = agent.id
        update["folder"] = folder
        if let agentVersion { update["agent_version"] = agentVersion }
        if let model { update["model"] = model }
        if let sessionID { update["session_id"] = sessionID }
        bridge.report(update) { [weak self] answer in
            guard let self else { return }
            if stateChanged { self.presenter?.stateReported(fields) }
            // The app keeps the last version each agent ran: one line when this session's differs.
            if let old = answer?["previous_version"] as? String, let new = self.agentVersion, !self.toldVersion {
                self.toldVersion = true
                self.session.note(AgentSessionVersion.updatedLine(agent: self.agent.name, from: ACPSession.oneLine(old, limit: 40), to: new))
                self.changed()
            }
        }
    }

    /// The first report, before anything runs: the app forgets what an earlier session in this tab reported (its session
    /// id above all, which an update would otherwise resume). The tab's state isn't touched: no OSC 7501 yet.
    private func reportStart() {
        guard bridge.isConnected else { return }
        let update: [String: Any] = ["op": "report", "agent": agent.name, "state": "idle", "turns": 0, "last_message": "",
                                     "agent_id": agent.id, "folder": folder]
        bridge.report(update) { _ in }
    }

    // MARK: ends

    func fatal(_ message: String) {
        end(.fatal(message), notes: [message])
    }

    func needsSignIn(_ message: String) {
        end(.signIn(message), notes: [message])
    }

    func resumeCannotGoOn(why: String) {
        let id = resumeID ?? ""
        let noun = agent.protocolKind == .codexAppServer ? "thread" : "session"
        let words = why.isEmpty ? "" : " (" + why + ")"
        let first = "\(agent.name) couldn\u{2019}t go on with \(noun) \(id)\(words), so no new one was started."
        end(.resumeFailed(why), notes: [first, "Open it in Terminal to go on with it there."])
    }

    private func end(_ why: Ending, notes: [String]) {
        guard !isEnded else { return }
        for note in notes { session.note(note) }
        changed()
        finish(1, why: why)
    }

    /// The words of output that isn't the agent's protocol, escape sequences out, at the end of `errorTail`.
    func keepWords(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]|\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        errorTail = String((errorTail + text + "\n").suffix(2000))
    }

    private func agentQuit(_ status: Int32) {
        guard !isEnded else { return }
        keepWords(buffer) // a last line with no newline
        buffer.removeAll()
        let tail = errorTail.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " / ")
        let words = ACPSession.oneLine(tail, limit: 300)
        if !driver.isReady, agent.protocolKind == .claudeStream, let id = resumeID {
            if resumeOnly { return resumeCannotGoOn(why: words) }
            // Claude Code couldn't go on with the session (it is gone, or from another folder): a new one, said so, as
            // Codex's thread falls back, rather than a sign-in hint that isn't the reason.
            session.note(ClaudeStream.resumeFailedLine(sessionID: id, words: words))
            waitingLine = "" // the next run draws its own input line here
            changed()
            driver.quitting()
            process.stop()
            ending = .closed
            presenter?.startAfresh()
            return
        }
        session.note("\(agent.name) quit (exit \(status))" + (tail.isEmpty ? "." : ": " + words))
        if !driver.isReady {
            // It quit before a session started: signed out, or a version without ACP.
            session.note("Run \(agent.program) in a tab to sign in or update it, then start the session again.")
        }
        changed()
        finish(status == 0 ? 0 : 1, why: .quit(status: status, words: words))
    }

    /// Next Term quits: the session ends without telling its presenter, and the agent's group, its input closed, is
    /// handed back for `AgentSessionProcess.endGroups` to end with the others. Nil for `nxtrm agent`'s, or one ended.
    func finishForQuit() -> pid_t? {
        guard !isEnded else { return nil }
        ending = .closed
        driver.quitting()
        return process.stopNow()
    }

    /// The session ends: an open request answered cancel or deny, the agent's process (and, for a chat, its whole group)
    /// ended, and the presenter told. Once.
    func finish(_ code: Int32, why: Ending = .closed) {
        guard !isEnded else { return }
        ending = why
        driver.quitting()
        process.stop()
        presenter?.ended(code: code)
    }
}

/// The agent's process (plan 037 KTD7): `nxtrm agent` starts it in its own tab's process group with the tab's
/// environment, as before the split; a chat tab starts it in a process group of its own with the login shell's
/// environment, so closing the tab ends the agent and everything it started. Callbacks come on the main queue.
final class AgentSessionProcess {
    enum Mode {
        /// The process's own environment and group (`nxtrm agent`).
        case inherit
        /// A process group of its own, with this environment (a chat tab).
        case ownGroup(environment: [String: String])
    }

    let mode: Mode
    var onOutput: ((Data) -> Void)?
    var onErrors: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    init(_ mode: Mode) {
        self.mode = mode
    }

    // `.inherit`: Foundation's Process, as `nxtrm agent` has always started it.
    private let process = Process()
    private let toAgent = Pipe()
    private let fromAgent = Pipe()
    private let agentErrors = Pipe()

    // `.ownGroup`: posix_spawn, and the descriptors' ends kept here.
    private(set) var pid: pid_t = 0
    private var input: Int32 = -1
    /// What the input's pipe couldn't take yet, in order, and the source that writes it once the pipe has room.
    private var unsent = AgentInputQueue()
    private var writeSource: DispatchSourceWrite?
    private var sources: [DispatchSourceRead] = []
    private var exitSource: DispatchSourceProcess?
    private var exitStatus: Int32?
    private var outputClosed = false
    private var exitTold = false
    private var stopping = false

    var isRunning: Bool {
        switch mode {
        case .inherit: return process.isRunning
        case .ownGroup: return pid > 0 && exitStatus == nil
        }
    }

    func run(_ program: String, _ arguments: [String], in folder: String) throws {
        switch mode {
        case .inherit: try runInherited(program, arguments, in: folder)
        case .ownGroup(let environment): try runOwnGroup(program, arguments, in: folder, environment: environment)
        }
    }

    private func runInherited(_ program: String, _ arguments: [String], in folder: String) throws {
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.standardInput = toAgent
        process.standardOutput = fromAgent
        process.standardError = agentErrors
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { self?.onExit?(status) }
        }
        fromAgent.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.onOutput?(data) }
        }
        agentErrors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.onErrors?(data) }
        }
        signal(SIGPIPE, SIG_IGN)
        try process.run()
    }

    struct SpawnError: LocalizedError {
        let code: Int32
        var errorDescription: String? { String(cString: strerror(code)) }
    }

    private func runOwnGroup(_ program: String, _ arguments: [String], in folder: String, environment: [String: String]) throws {
        var stdin: [Int32] = [-1, -1], stdout: [Int32] = [-1, -1], stderr: [Int32] = [-1, -1]
        guard pipe(&stdin) == 0 else { throw SpawnError(code: errno) }
        guard pipe(&stdout) == 0 else {
            stdin.forEach { close($0) }
            throw SpawnError(code: errno)
        }
        guard pipe(&stderr) == 0 else {
            (stdin + stdout).forEach { close($0) }
            throw SpawnError(code: errno)
        }
        // The app's own ends: never inherited by anything else it starts, and a write to an agent that quit is no SIGPIPE.
        // The input never blocks: what a full pipe can't take waits in `unsent`, so the main thread never waits on it.
        for fd in [stdin[1], stdout[0], stderr[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(stdin[1], F_SETNOSIGPIPE, 1)
        _ = fcntl(stdin[1], F_SETFL, fcntl(stdin[1], F_GETFL) | O_NONBLOCK)
        let spawned = Self.spawn(program, arguments, environment: environment, folder: folder,
                                 stdin: stdin[0], stdout: stdout[1], stderr: stderr[1])
        // The child's ends are the child's alone now.
        [stdin[0], stdout[1], stderr[1]].forEach { close($0) }
        guard case .success(let child) = spawned else {
            [stdin[1], stdout[0], stderr[0]].forEach { close($0) }
            if case .failure(let error) = spawned { throw error }
            return
        }
        pid = child
        input = stdin[1]
        read(stdout[0]) { [weak self] data in
            guard let self else { return }
            if let data { self.onOutput?(data) } else {
                self.outputClosed = true
                self.tellExitWhenDone()
            }
        }
        read(stderr[0]) { [weak self] data in
            if let data { self?.onErrors?(data) }
        }
        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        exit.setEventHandler { [weak self] in self?.reap() }
        exit.resume()
        exitSource = exit
        // It may have ended before the source was watching.
        reap()
    }

    /// Reads `fd` until its end, on a queue of its own, handing each piece (then nil, at the end) to `then` on the main
    /// queue. The descriptor closes at the end.
    private func read(_ fd: Int32, then: @escaping (Data?) -> Void) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "nextterm.agent-process.read"))
        source.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                let data = Data(bytes[0..<count])
                DispatchQueue.main.async { then(data) }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.setCancelHandler {
            close(fd)
            DispatchQueue.main.async { then(nil) }
        }
        source.resume()
        sources.append(source)
    }

    /// The leader's exit, read once: its status as Foundation gives it (the exit code, or the signal that ended it).
    private func reap() {
        guard pid > 0, exitStatus == nil else { return }
        var status: Int32 = 0
        let found = waitpid(pid, &status, WNOHANG)
        if found == pid {
            exitStatus = status & 0x7F == 0 ? (status >> 8) & 0xFF : status & 0x7F
        } else if found < 0, errno == ECHILD {
            exitStatus = -1 // reaped by the group's end already
        } else {
            return
        }
        exitSource?.cancel()
        exitSource = nil
        tellExitWhenDone()
        // A grandchild can keep the output open after the agent quit: its end isn't waited for past a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.exitTold else { return }
            self.outputClosed = true
            self.tellExitWhenDone()
        }
    }

    /// The exit goes out after the agent's last output, so a quit's note follows everything it printed.
    private func tellExitWhenDone() {
        guard let status = exitStatus, outputClosed, !exitTold else { return }
        exitTold = true
        onExit?(status)
    }

    /// A line to the agent; one that has quit takes nothing (its pipe's end is gone, and that is no crash). A chat's
    /// line never blocks: what the pipe can't take now goes once it has room, after anything still waiting.
    func write(_ data: Data) {
        switch mode {
        case .inherit:
            try? toAgent.fileHandleForWriting.write(contentsOf: data)
        case .ownGroup:
            guard input >= 0 else { return }
            unsent.append(data)
            if writeSource == nil { writeUnsent() }
        }
    }

    /// Writes what waits, as much as the pipe takes; a full pipe leaves the rest to a write source, which calls back
    /// here once it has room. Main queue.
    private func writeUnsent() {
        guard input >= 0 else { return }
        let fd = input
        switch unsent.drain({ raw in
            let written = Darwin.write(fd, raw.baseAddress, raw.count)
            return AgentInputQueue.Written(count: written, error: written < 0 ? errno : 0)
        }) {
        case .wouldBlock:
            guard writeSource == nil else { return }
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self, weak source] in
                guard let self else { source?.cancel(); return } // nobody to write for: a writable pipe would fire on
                self.writeUnsent()
            }
            writeSource = source
            source.resume()
        case .drained, .failed:
            writeSource?.cancel()
            writeSource = nil
        }
    }

    /// Ends the agent. `nxtrm agent`'s: SIGTERM to the agent, as before. A chat's: its input closes, then SIGTERM to its
    /// whole group 3 seconds on, then SIGKILL 2 seconds after that, whatever is still running (KTD7). Once.
    func stop() {
        switch mode {
        case .inherit:
            if process.isRunning { process.terminate() }
        case .ownGroup:
            guard pid > 0, !stopping else { return }
            stopping = true
            closeInput()
            let group = pid
            DispatchQueue.global(qos: .utility).async { Self.endGroups([group]) }
        }
    }

    /// The input closes, and what still waits for it is dropped. A write source watching it closes it once cancelled.
    private func closeInput() {
        guard input >= 0 else { return }
        let fd = input
        input = -1
        unsent.drop()
        if let source = writeSource {
            writeSource = nil
            source.setCancelHandler { close(fd) }
            source.cancel()
        } else {
            close(fd)
        }
    }

    /// The process group's end, for Next Term's own quit: the same order as `stop`, waited for here.
    func stopNow() -> pid_t? {
        guard case .ownGroup = mode, pid > 0, !stopping else { return nil }
        stopping = true
        closeInput()
        return pid
    }

    /// The grace a group's agent gets after its input closes, then after SIGTERM (KTD7).
    static let inputGrace: TimeInterval = 3
    static let termGrace: TimeInterval = 2

    /// Ends each group led by `groups` (their inputs closed already): waits up to `inputGrace` for each to empty, sends
    /// SIGTERM to those that haven't, waits up to `termGrace`, then sends SIGKILL. Leaders are reaped meanwhile. Blocks.
    static func endGroups(_ groups: [pid_t]) {
        func alive(_ group: pid_t) -> Bool {
            var status: Int32 = 0
            _ = waitpid(group, &status, WNOHANG) // a leader that quit is reaped, so its zombie doesn't keep the group
            return killpg(group, 0) == 0
        }
        func waitEmpty(_ groups: [pid_t], for seconds: TimeInterval) -> [pid_t] {
            let deadline = Date().addingTimeInterval(seconds)
            var left = groups.filter(alive)
            while !left.isEmpty, Date() < deadline {
                usleep(100_000)
                left = left.filter(alive)
            }
            return left
        }
        var left = waitEmpty(groups, for: inputGrace)
        left.forEach { killpg($0, SIGTERM) }
        left = waitEmpty(left, for: termGrace)
        left.forEach { killpg($0, SIGKILL) }
        _ = waitEmpty(left, for: 0.5)
    }

    /// posix_spawn into a new process group, in `folder`, with only the three descriptors given, no signal blocked and
    /// SIGPIPE as a fresh program has it (as CommandSuggestionRunner starts an agent).
    private static func spawn(_ program: String, _ arguments: [String], environment: [String: String], folder: String,
                              stdin: Int32, stdout: Int32, stderr: Int32) -> Result<pid_t, SpawnError> {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGINT, SIGTERM, SIGHUP] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        posix_spawn_file_actions_addchdir_np(&actions, folder)
        let argv: [UnsafeMutablePointer<CChar>?] = ([program] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, program, &actions, &attributes, argv, envp)
        return status == 0 ? .success(pid) : .failure(SpawnError(code: status))
    }
}

import Foundation
import NextTermCore

/// Claude Code as a session (plan 035 U4): one `claude -p` process with stream-json in and out and its control channel
/// on stdio, one user message per prompt (R3). `ClaudeStream` reads and writes the lines; this driver keeps what the
/// runner's model needs. Before the spawn it asks the app to trust the folder (R8, U5), since `claude -p` loads a
/// folder's hooks and MCP servers with no dialog of its own.
///
/// It runs the user's own `claude` with the tab's environment unchanged, and never reads, logs or forwards a token (R2).
final class ClaudeDriver: AgentSessionDriver {
    private unowned let runner: AgentSessionRunner
    private var stream = ClaudeStream()
    /// The `initialize` control request's id: the session is ready at its answer (KTD3).
    private var initializeID: String?
    private var interruptID: String?
    private var ready = false
    /// The model `system/init` named, for the ready line when it comes first.
    private var model: String?
    /// The open `can_use_tool` request the menu shows.
    private var permission: ClaudeStream.Permission?
    /// The open AskUserQuestion call, and the answers picked so far, one per question in order (R6).
    private var question: ClaudeStream.Question?
    private var answers: [String] = []
    /// A turn that hears only lines of types Next Term doesn't know for a minute is drift (plan 035 U7), as for Codex.
    private var watch = ProtocolDriftWatch()
    private var timer: DispatchSourceTimer?

    init(runner: AgentSessionRunner) {
        self.runner = runner
    }

    var arguments: [String] {
        var words = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                     "--include-partial-messages", "--permission-prompt-tool", "stdio"]
        // A session restored after an update goes on (plan 035 U7).
        if let id = runner.resumeID { words += ["--resume", id] }
        // Beside the user's own servers, which load as usual (R11).
        if let server = runner.nextTermMCPServer, let config = Self.mcpConfig(server) {
            words += ["--mcp-config", config]
        }
        return words
    }

    var startWords: String { "claude -p, stream-json" }

    var isReady: Bool { ready }

    /// `--mcp-config`'s inline JSON: one stdio server.
    static func mcpConfig(_ server: ACPWire.StdioServer) -> String? {
        let entry: [String: Any] = ["type": "stdio", "command": server.command, "args": server.arguments]
        let config: [String: Any] = ["mcpServers": [server.name: entry]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: The version, then folder trust (R8)

    /// How long `claude --version` may take.
    static let versionTimeout: TimeInterval = 3

    func prepare(then go: @escaping () -> Void) {
        let program = runner.program
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let version = Self.version(of: program)
            DispatchQueue.main.async {
                guard let self else { return }
                self.runner.agentVersion = version
                self.trust(then: go)
            }
        }
    }

    /// The first line of `claude --version`, read once before the spawn, its version alone; nil when it says none in
    /// `versionTimeout`. Nothing else is run or read.
    static func version(of program: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + versionTimeout) == .timedOut {
            process.terminate()
            return nil
        }
        // A version line is short: what is read past 4 KB is never wanted.
        let data: Data? = try? output.fileHandleForReading.read(upToCount: 4096)
        return data.flatMap { AgentSessionVersion.parse(String(decoding: $0, as: UTF8.self)) }
    }

    private func trust(then go: @escaping () -> Void) {
        let folder = AgentSessionTrust.canonical(FileManager.default.currentDirectoryPath)
        guard runner.appSocket != nil else {
            // Outside a Next Term tab nothing can ask on the Mac: only a folder trusted there before runs.
            if AgentSessionTrust.isTrusted(folder, in: AgentSessionTrust.list(in: .standard)) { return go() }
            return runner.fatal(AgentSessionTrust.outsideNote)
        }
        // The app asks, by click only, and keeps the answer: nothing typed here grants it.
        runner.waitingLine = AgentSessionTrust.waitingLine
        runner.draw()
        let fields: [String: Any] = ["op": "trust_folder", "agent": runner.agent.name, "folder": folder]
        runner.callApp(fields, timeout: 16 * 60) { [weak self] answer in
            guard let self else { return }
            self.runner.waitingLine = nil
            guard answer?["trusted"] as? Bool == true else {
                let why = answer == nil ? "Next Term didn\u{2019}t answer" : "it wasn\u{2019}t trusted on the Mac"
                return self.runner.fatal("Claude Code didn\u{2019}t start in \(folder): \(why). Nothing ran.")
            }
            self.runner.draw()
            go()
        }
    }

    // MARK: The stream

    func started() {
        let (id, line) = stream.initializeRequest()
        initializeID = id
        runner.sendToAgent(line)
        // No answer to initialize, or a turn of only unknown lines: Claude Code's stream changed (plan 035 U7).
        let wait = AgentSessionRunner.startupTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.initializeID == id else { return }
            self.drift("no answer to initialize in \(Int(wait)) seconds")
        }
        timer = driftTimer { [weak self] in self?.checkDrift() }
    }

    private func checkDrift() {
        guard runner.session.working, watch.isDrifting(at: Date(), waitingOnUser: runner.isWaitingOnUser) else { return }
        drift("only lines of unknown types for \(Int(ProtocolDriftWatch.quiet)) seconds")
    }

    private func drift(_ detail: String) {
        runner.fatal(ClaudeStream.driftNote(version: runner.agentVersion, detail: detail))
    }

    func received(line: Data) {
        let event = stream.decode(line)
        if event == .ignore, line.first(where: { $0 != 0x20 && $0 != 0x09 }) != UInt8(ascii: "{") {
            // Not stream-json: Claude's own words (an error before it speaks JSON), kept for the line that says why it
            // quit, and nothing the stream knows.
            runner.keepWords(line)
            if !line.isEmpty { watch.observe(claude: .unknownLine(""), at: Date()) }
            return
        }
        watch.observe(claude: event, at: Date())
        if event == .ignore { return }
        handle(event)
    }

    private func handle(_ event: ClaudeStream.Event) {
        switch event {
        case .initialized(let info):
            model = info.model
            runner.model = info.model ?? runner.model
            if let id = info.sessionID, AgentSessionVersion.isSessionID(id) { runner.sessionID = id }
            if ready { runner.report() }
            if !info.commands.isEmpty {
                let commands: [ACPWire.Value] = info.commands.map { .object(["name": .string($0)]) }
                let update: [String: ACPWire.Value] = [
                    "sessionUpdate": .string("available_commands_update"), "availableCommands": .array(commands),
                ]
                runner.session.apply(update: .object(["update": .object(update)]))
            }
        case .controlResponse(let id, _, let error):
            if id == initializeID {
                initializeID = nil
                if let error { return drift("initialize answered with an error: " + ACPSession.oneLine(error, limit: 200)) }
                becomeReady()
            } else if id == interruptID {
                interruptID = nil
                if let error {
                    runner.session.note("Claude Code couldn\u{2019}t stop the turn: " + ACPSession.oneLine(error, limit: 200))
                    runner.draw()
                }
            }
        case .updates(let updates):
            for update in updates { runner.session.apply(update: update) }
            runner.scheduleDraw()
        case .permission(let request):
            closeOpenRequest()
            permission = request
            if runner.session.requested(permission: .string(request.requestID), params: request.params) == nil {
                permission = nil
                runner.sendToAgent(ClaudeStream.response(to: request, optionID: nil))
                runner.session.note("Claude Code asked permission with no options; it was denied.")
            }
            runner.report()
            runner.draw()
        case .question(let asked):
            closeOpenRequest()
            guard !asked.items.isEmpty else {
                runner.sendToAgent(ClaudeStream.deny(requestID: asked.requestID, message: "The question had no options to pick."))
                runner.session.note("Claude Code asked a question with no options; it was declined.")
                return runner.draw()
            }
            question = asked
            answers = []
            openQuestion(0)
        case .turnEnded(let end):
            permission = nil
            question = nil
            answers = []
            if let usage = end.usage { runner.session.apply(update: usage) }
            guard runner.session.working else { return runner.draw() }
            if let failure = end.failure { runner.session.turnFailed(failure) } else { runner.session.turnEnded(end.stopReason) }
            runner.draw()
            runner.freeze()
            runner.report()
        case .cancelRequest(let id):
            // Claude withdrew its request: the menu closes, unanswered.
            let open = permission?.requestID == id || question?.requestID == id
            guard open else { return }
            permission = nil
            question = nil
            answers = []
            _ = runner.session.cancelPending()
            runner.report()
            runner.draw()
        case .unknownControl(let id, let subtype):
            let what = subtype.isEmpty ? "a request" : subtype
            runner.sendToAgent(ClaudeStream.controlError(requestID: id, message: "Next Term's session doesn't handle " + what))
            runner.session.note("Claude Code asked for \(what), which this session doesn\u{2019}t handle; it was declined.")
            runner.draw()
        case .authFailure:
            runner.fatal(ClaudeStream.signInLine + ".")
        case .unknownLine, .ignore:
            // Counted by the drift watch.
            break
        }
    }

    private func becomeReady() {
        guard !ready else { return }
        ready = true
        // A resumed session goes on with the id it was given until system/init names one, so an update meanwhile brings
        // back this conversation, not none.
        if runner.sessionID == nil, let id = runner.resumeID { runner.sessionID = id }
        // Ready with --resume: Claude Code went on with it (one that can't quits first).
        if runner.resumeID != nil { runner.resumed = true }
        let version = runner.agentVersion.map { " " + $0 } ?? ""
        let named = model.map { " (\($0))" } ?? ""
        let resumed = runner.resumeID.map { ", going on with session " + $0 } ?? ""
        runner.session.note("Claude Code\(version)\(named) is ready\(resumed).")
        runner.report()
        runner.draw()
        if let first = runner.firstPrompt {
            runner.firstPrompt = nil
            send(first)
        }
    }

    /// Question `index` of the open AskUserQuestion call as the menu, with no "allow" lead.
    private func openQuestion(_ index: Int) {
        guard let question else { return }
        runner.session.requested(permission: .string(question.requestID), params: question.params(at: index), question: true)
        runner.report()
        runner.draw()
    }

    /// A new request replaces one still open: the old one is denied, never left waiting or allowed.
    private func closeOpenRequest() {
        guard runner.session.pending != nil else { return }
        denyOpen(message: "Claude Code asked something else in Next Term.")
    }

    /// The open permission or question denied, its menu closed as cancelled.
    private func denyOpen(message: String) {
        _ = runner.session.cancelPending()
        if let permission { runner.sendToAgent(ClaudeStream.response(to: permission, optionID: nil)) }
        if let question { runner.sendToAgent(ClaudeStream.deny(requestID: question.requestID, message: message)) }
        permission = nil
        question = nil
        answers = []
    }

    // MARK: The user's actions

    func send(_ text: String) {
        guard ready, !runner.session.working else { return }
        runner.session.prompted(text)
        watch.turnStarted(at: Date())
        runner.report()
        runner.draw()
        runner.sendToAgent(stream.userMessage(text))
    }

    func cancelTurn() {
        guard ready, runner.session.working else { return }
        if runner.session.pending != nil { denyOpen(message: "The user stopped this in Next Term.") }
        // Always the control request: a SIGINT would end the whole `claude -p` process (KTD3).
        let (id, line) = stream.interruptRequest()
        interruptID = id
        runner.sendToAgent(line)
        runner.draw()
    }

    func answer(_ index: Int) {
        if let asked = question {
            guard let (_, label) = runner.session.choose(index) else { return }
            answers.append(label)
            if answers.count < asked.items.count { return openQuestion(answers.count) }
            // Every question answered: one control response carries them all (R6).
            runner.sendToAgent(ClaudeStream.answer(asked, with: answers))
            question = nil
            answers = []
            return
        }
        guard let request = permission, let (_, option) = runner.session.choose(index) else { return }
        permission = nil
        runner.sendToAgent(ClaudeStream.response(to: request, optionID: option))
    }

    func quitting() {
        timer?.cancel()
        if runner.session.pending != nil { denyOpen(message: "The user closed the session in Next Term.") }
    }
}

/// Codex as a session (plan 035 U4): one `codex app-server` and one thread, one turn per prompt (R3), over JSON-RPC.
/// `CodexAppServer` reads and writes the lines; this driver follows its order (initialize, initialized, account/read,
/// thread/start with `approvalPolicy: on-request` and Next Term's MCP server, then turn/start per prompt), answers every
/// request it doesn't take with "method not found" (R9), and ends the session with the drift note when a turn hears
/// only notifications it doesn't know for a minute.
///
/// It runs the user's own `codex` with the tab's environment unchanged, and never reads, logs or forwards a token (R2).
final class CodexDriver: AgentSessionDriver {
    private unowned let runner: AgentSessionRunner
    private var codex = CodexAppServer()
    private var watch = CodexAppServer.DriftWatch()
    private var timer: DispatchSourceTimer?
    private var ready = false
    /// A stop was asked for before the turn had an id: sent once `turn/started` gives it.
    private var stopWanted = false
    /// The open approval the menu shows.
    private var permission: CodexAppServer.Permission?
    /// `thread/resume` was asked (plan 035 U7): its failure starts a fresh thread instead.
    private var resuming = false

    init(runner: AgentSessionRunner) {
        self.runner = runner
    }

    var arguments: [String] { ["app-server"] }

    var startWords: String { "codex app-server" }

    var isReady: Bool { ready }

    func prepare(then go: @escaping () -> Void) {
        // Codex's own sandbox applies, and the thread asks before acting (KTD5): no folder question.
        go()
    }

    func started() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        runner.sendToAgent(codex.initializeRequest(version: version).line)
        // No thread from initialize to thread/start: Codex's app-server changed, or hangs (plan 035 U7), as for Claude Code.
        let wait = AgentSessionRunner.startupTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, !self.ready else { return }
            let detail = "no session from initialize to thread/start in \(Int(wait)) seconds"
            self.runner.fatal(CodexAppServer.driftNote(userAgent: self.codex.userAgent, detail: detail))
        }
        timer = driftTimer { [weak self] in self?.checkDrift() }
    }

    private func checkDrift() {
        guard runner.session.working, watch.isDrifting(at: Date(), waitingOnUser: runner.isWaitingOnUser) else { return }
        let detail = "only unknown notifications for \(Int(CodexAppServer.DriftWatch.quiet)) seconds"
        runner.fatal(CodexAppServer.driftNote(userAgent: codex.userAgent, detail: detail))
    }

    func received(line: Data) {
        let event = codex.decode(line)
        watch.observe(event, at: Date())
        if event == .ignore {
            // Not JSON-RPC: Codex's own words, kept for the line that says why it quit.
            if line.first(where: { $0 != 0x20 && $0 != 0x09 }) != UInt8(ascii: "{") { runner.keepWords(line) }
            return
        }
        handle(event)
    }

    private func handle(_ event: CodexAppServer.Event) {
        switch event {
        case .initialized(let userAgent):
            runner.agentVersion = AgentSessionVersion.fromUserAgent(userAgent)
            runner.sendToAgent(CodexAppServer.initializedNotification())
            // A missing login is told before the first turn; the server answers in order, so before thread/start.
            runner.sendToAgent(codex.accountReadRequest().line)
            let cwd = FileManager.default.currentDirectoryPath
            if let id = runner.resumeID {
                // A session restored after an update goes on with its thread (plan 035 U7).
                resuming = true
                runner.sendToAgent(codex.threadResumeRequest(threadID: id, cwd: cwd, mcpServer: runner.nextTermMCPServer).line)
            } else {
                runner.sendToAgent(codex.threadStartRequest(cwd: cwd, mcpServer: runner.nextTermMCPServer).line)
            }
        case .resumeFailed(let why):
            resuming = false
            // A switch's resume (--resume-only) never turns into a new thread: the session ends, offering the terminal.
            if runner.resumeOnly { return runner.resumeCannotGoOn(why: ACPSession.oneLine(why, limit: 200)) }
            // Codex can't go on with the thread: a fresh one, said so.
            let id = runner.resumeID ?? ""
            runner.session.note("Codex couldn\u{2019}t go on with thread \(id) (" + ACPSession.oneLine(why, limit: 200) + "); this is a new thread.")
            runner.draw()
            let cwd = FileManager.default.currentDirectoryPath
            runner.sendToAgent(codex.threadStartRequest(cwd: cwd, mcpServer: runner.nextTermMCPServer).line)
        case .threadStarted(let thread):
            guard !ready else { return }
            ready = true
            if AgentSessionVersion.isSessionID(thread) { runner.sessionID = thread }
            runner.model = codex.model
            let version = runner.agentVersion.map { " " + $0 } ?? ""
            let named = codex.model.map { " (\($0))" } ?? ""
            let resumed = resuming ? ", going on with thread " + thread : ""
            if resuming { runner.resumed = true }
            resuming = false
            runner.session.note("Codex\(version)\(named) is ready\(resumed).")
            runner.report()
            runner.draw()
            if let first = runner.firstPrompt {
                runner.firstPrompt = nil
                send(first)
            }
        case .turnStarted(let turn):
            guard stopWanted, let thread = codex.threadID else { return }
            stopWanted = false
            runner.sendToAgent(codex.interruptRequest(threadID: thread, turnID: turn).line)
        case .updates(let updates):
            for update in updates { runner.session.apply(update: update) }
            runner.scheduleDraw()
        case .permission(let request):
            // A second approval while one is open: the first is declined, which keeps the turn going (cancel would end it).
            if runner.session.pending != nil { cancelOpen(superseded: true) }
            permission = request
            if runner.session.requested(permission: request.requestID, params: request.params) == nil {
                permission = nil
                runner.sendToAgent(CodexAppServer.response(to: request, optionID: nil))
                runner.session.note("Codex asked approval with no options; it was cancelled.")
            }
            runner.report()
            runner.draw()
        case .unsupportedRequest(let id, let method):
            runner.sendToAgent(CodexAppServer.unsupportedAnswer(id: id, method: method))
            runner.session.note(CodexAppServer.unsupportedNote(method))
            runner.draw()
        case .resolved(let id):
            // Settled elsewhere: the menu closes, with nothing sent.
            guard let open = permission, open.requestID == id else { return }
            permission = nil
            _ = runner.session.cancelPending()
            runner.report()
            runner.draw()
        case .turnEnded(let end):
            permission = nil
            stopWanted = false
            guard runner.session.working else { return runner.draw() }
            if let failure = end.failure { runner.session.turnFailed(failure) } else { runner.session.turnEnded(end.stopReason) }
            runner.draw()
            runner.freeze()
            runner.report()
        case .authFailure:
            runner.fatal(CodexAppServer.signInLine + ".")
        case .drift(let note):
            runner.fatal(note)
        case .requestFailed(let method, let message):
            let words = ACPSession.oneLine(message, limit: 200)
            guard ready else { return runner.fatal("Codex couldn\u{2019}t start a session (\(method)): \(words).") }
            let lead = method == "turn/interrupt" ? "Codex couldn\u{2019}t stop the turn: " : "Codex answered \(method) with an error: "
            runner.session.note(lead + words)
            runner.draw()
        case .unknownNotification, .ignore:
            break
        }
    }

    /// The open approval cancelled (which stops the turn), or declined when a newer one replaced it, its menu closed:
    /// never accepted by default.
    private func cancelOpen(superseded: Bool = false) {
        _ = runner.session.cancelPending()
        if let permission {
            let line = superseded ? CodexAppServer.supersededResponse(to: permission) : CodexAppServer.response(to: permission, optionID: nil)
            runner.sendToAgent(line)
        }
        permission = nil
    }

    // MARK: The user's actions

    func send(_ text: String) {
        guard ready, let thread = codex.threadID, !runner.session.working else { return }
        runner.session.prompted(text)
        watch.turnStarted(at: Date())
        runner.report()
        runner.draw()
        runner.sendToAgent(codex.turnStartRequest(threadID: thread, text: text).line)
    }

    func cancelTurn() {
        guard ready, runner.session.working else { return }
        if runner.session.pending != nil { cancelOpen() }
        if let thread = codex.threadID, let turn = codex.turnID {
            runner.sendToAgent(codex.interruptRequest(threadID: thread, turnID: turn).line)
        } else {
            stopWanted = true
        }
        runner.draw()
    }

    func answer(_ index: Int) {
        guard let request = permission, let (_, option) = runner.session.choose(index) else { return }
        permission = nil
        runner.sendToAgent(CodexAppServer.response(to: request, optionID: option))
    }

    func quitting() {
        timer?.cancel()
        if runner.session.pending != nil { cancelOpen() }
    }
}

/// The drift watch's check, every 5 seconds on the main queue, until the driver's `quitting()` cancels it.
private func driftTimer(_ check: @escaping () -> Void) -> DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 5, repeating: 5)
    timer.setEventHandler(handler: check)
    timer.resume()
    return timer
}

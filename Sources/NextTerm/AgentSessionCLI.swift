import Darwin
import Foundation
import NextTermCore

/// `nxtrm agent NAME [--prompt TEXT]`: an agent session in the tab it runs in (plan 030). It starts the agent in ACP
/// mode, draws the session as text (ACPTranscript) with an input line, and says what the agent does over OSC 7501, so
/// the tab's marks, its notification and `wait_for_tab` follow the agent's own turns rather than its screen. A
/// permission request is drawn as a numbered menu that the tab's keys, the notification's buttons and `answer_agent`
/// answer. The agent uses its own tools; it is given Next Term's MCP server when it runs in a Next Term tab.
enum AgentSessionCLI {
    static let usage = """
        nxtrm agent NAME [--prompt TEXT]
          Runs an agent that speaks the Agent Client Protocol in this tab, as an agent session: its turns, tool calls,
          plan and permission requests drawn as text, and its state followed exactly by Next Term.
          NAME is one of: \(ACPAgent.known.map(\.id).joined(separator: ", ")).
          --prompt TEXT   the first prompt, sent at once.
        Type a prompt and Return to send it; ⌃C or Esc stops a turn; ⌃D on an empty line ends the session.
        """

    static func run(_ arguments: [String]) -> Never {
        var name: String?
        var prompt: String?
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "-h", "--help", "help":
                print(usage)
                exit(0)
            case "--prompt", "-p":
                guard let text = rest.popFirst() else { fail("--prompt needs its text") }
                prompt = text
            default:
                guard name == nil, !argument.hasPrefix("-") else { fail("unknown argument \(argument)") }
                name = argument
            }
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let installed = ACPAgent.installed(path: path) { FileManager.default.isExecutableFile(atPath: $0) }
        guard let name else {
            print(usage)
            print("Installed here: " + ACPAgent.listed(installed) + ".")
            exit(installed.isEmpty ? 1 : 0)
        }
        guard let agent = ACPAgent.named(name) else {
            fail("\(name) isn't an agent Next Term runs over ACP. Installed here: \(ACPAgent.listed(installed)).")
        }
        guard let program = locate(agent.program, path: path) else {
            fail("\(agent.name) (\(agent.program)) isn't on the PATH. Installed here: \(ACPAgent.listed(installed)).")
        }
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { fail("nxtrm agent runs in a terminal tab") }
        let runner = AgentSessionRunner(agent: agent, program: program, firstPrompt: prompt)
        runner.start()
        dispatchMain()
    }

    static func locate(_ program: String, path: String) -> String? {
        for folder in path.split(separator: ":") where !folder.isEmpty {
            let candidate = (String(folder) as NSString).appendingPathComponent(program)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("nxtrm agent: \(message)\n".utf8))
        exit(2)
    }
}

/// What a session speaks to its agent (plan 035 KTD1): ACP, Claude Code's stream-json or Codex's app-server. The runner
/// keeps the process, the drawing, the keys, OSC 7501, the app socket and the Allow always question on the Mac, one copy
/// for every agent; a driver turns the agent's lines into the session model (`runner.session`) and the user's actions into
/// the agent's lines. Everything runs on the main queue.
protocol AgentSessionDriver: AnyObject {
    /// The program's arguments.
    var arguments: [String] { get }
    /// The command the opening note shows.
    var startWords: String { get }
    /// A session is up: prompts can go.
    var isReady: Bool { get }
    /// Before the spawn: `go` starts the agent, or the driver ends the session (Claude's folder trust, R8).
    func prepare(then go: @escaping () -> Void)
    /// Just after the spawn: the handshake.
    func started()
    /// One line of the agent's stdout, its newline gone.
    func received(line: Data)
    /// A prompt typed and sent.
    func send(_ text: String)
    /// ⌃C or Esc: the turn stops, an open request answered cancel or deny.
    func cancelTurn()
    /// Option `index` of the open menu is picked (an Allow always already approved on the Mac).
    func answer(_ index: Int)
    /// The session ends (the tab closes): an open request is answered cancel or deny, never allowed.
    func quitting()
}

/// One session: the agent's process, the drawing and the keys, with the protocol behind its driver. Everything runs on
/// the main queue.
final class AgentSessionRunner {
    let agent: ACPAgent
    let program: String
    var firstPrompt: String?

    private let process = Process()
    private let toAgent = Pipe()
    private let fromAgent = Pipe()
    private let agentErrors = Pipe()
    private var buffer = Data()
    /// The agent's last words on stderr, shown if it quits.
    private var errorTail = ""

    var session = ACPSession()
    /// What the input line says instead of the prompt while the session waits on the Mac (Claude's folder trust); keys
    /// other than \u{2303}C and \u{2303}D do nothing meanwhile.
    var waitingLine: String?
    /// The prompt being typed, as bytes: a character typed or pasted in UTF-8 can come in pieces.
    private var typedBytes: [UInt8] = []
    private var typed: String {
        get { String(decoding: typedBytes, as: UTF8.self) }
        set { typedBytes = Array(newValue.utf8) }
    }

    // Drawing: the lines of the current turn already printed for good, and how many lines the live part takes.
    private var liveFrom = 0
    private var committed = 0
    private var liveCount = 0
    private var drawScheduled = false

    private var savedTerminal = termios()
    private var input: DispatchSourceRead?
    private var resize: DispatchSourceSignal?
    private var keys = Data()
    private var pasting = false
    private var lastReport = ""

    private lazy var driver: AgentSessionDriver = {
        switch agent.protocolKind {
        case .acp: return ACPDriver(runner: self)
        case .claudeStream: return ClaudeDriver(runner: self)
        case .codexAppServer: return CodexDriver(runner: self)
        }
    }()

    init(agent: ACPAgent, program: String, firstPrompt: String?) {
        self.agent = agent
        self.program = program
        self.firstPrompt = firstPrompt
    }

    func start() {
        rawTerminal()
        write("\u{1b}]2;\(agent.name)\u{07}") // the tab's title
        session.note("Starting \(agent.name) (\(driver.startWords))\u{2026}")
        draw()
        driver.prepare { [weak self] in self?.spawn() }
    }

    private func spawn() {
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = driver.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.standardInput = toAgent
        process.standardOutput = fromAgent
        process.standardError = agentErrors
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { self?.agentQuit(status) }
        }
        fromAgent.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.received(data) }
        }
        agentErrors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self else { return }
                self.errorTail = String((self.errorTail + String(decoding: data, as: UTF8.self)).suffix(2000))
            }
        }
        signal(SIGPIPE, SIG_IGN)
        do {
            try process.run()
        } catch {
            session.note("Couldn\u{2019}t start \(agent.name): \(error.localizedDescription)")
            finish(1)
        }
        driver.started()
    }

    /// Next Term's MCP server for the agent, in a Next Term tab (R26, plan 035 R11): the command the other tabs'
    /// agents are given, under the name a user-scope entry has, so it replaces that entry rather than doubling it.
    var nextTermMCPServer: ACPWire.StdioServer? {
        guard appSocket != nil, let me = Bundle.main.executablePath else { return nil }
        return .init(name: MCPRegistrar.serverName, command: me, arguments: ["--cli", "mcp"])
    }

    // MARK: the protocol

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            driver.received(line: Data(line))
        }
        // A line that never ends isn't kept past 16 MB.
        if buffer.count > 16 << 20 { buffer.removeAll() }
    }

    /// A line to the agent; one that has quit takes nothing (its pipe's end is gone, and that is no crash).
    func sendToAgent(_ data: Data) {
        try? toAgent.fileHandleForWriting.write(contentsOf: data)
    }

    private func send(_ text: String) {
        driver.send(text)
    }

    private func cancelTurn() {
        driver.cancelTurn()
    }

    /// An Allow always waiting for the user's OK on the Mac: the menu takes no other answer meanwhile.
    private var confirming = false

    private func choose(_ index: Int) {
        guard !confirming, let option = session.option(at: index) else { return }
        guard option.kind == "allow_always" else { return answer(index) }
        // A standing permission is the one answer that outlives the question: asked of the user on the Mac first, as the
        // tab's keys can't tell them from an agent steering the session (R16).
        guard appSocket != nil, let permission = session.pending else {
            session.note("\u{201C}\(option.name)\u{201D} needs your OK in Next Term, which this session can\u{2019}t reach; pick another option.")
            return draw()
        }
        confirming = true
        session.note("Waiting for your OK on the Mac for \u{201C}\(option.name)\u{201D}\u{2026}")
        draw()
        let fields: [String: Any] = ["op": "confirm_always", "agent": agent.name, "action": permission.action, "option": option.name]
        callApp(fields, timeout: 16 * 60) { [weak self] answer in
            guard let self else { return }
            self.confirming = false
            // Still the same request: the turn wasn't stopped meanwhile.
            guard self.session.pending?.requestID == permission.requestID else { return self.draw() }
            if answer?["approved"] as? Bool == true {
                self.answer(index)
            } else {
                self.session.note("\u{201C}\(option.name)\u{201D} was declined on the Mac; the request is still open.")
                self.draw()
            }
        }
    }

    private func answer(_ index: Int) {
        driver.answer(index)
        report()
        draw()
    }

    // MARK: the app

    /// Next Term's socket, when the session runs in one of its tabs.
    let appSocket = ProcessInfo.processInfo.environment["NEXTTERM_MCP_SOCKET"]
    /// One request to the app at a time, in order: a report is in before the tab hears the state it reports.
    private let appQueue = DispatchQueue(label: "nxtrm-agent.app")
    private var turnsEnded = 0

    /// A request to the app (AgentSessionSocket), answered on the main queue: its fields, or nil when it couldn't be
    /// asked or didn't answer in `timeout` seconds.
    func callApp(_ fields: [String: Any], timeout: Int, then: @escaping ([String: Any]?) -> Void) {
        guard let path = appSocket else { return then(nil) }
        appQueue.async {
            let answer = Self.ask(path: path, fields: fields, timeout: timeout)
            DispatchQueue.main.async { then(answer) }
        }
    }

    private static func ask(path: String, fields: [String: Any], timeout: Int) -> [String: Any]? {
        let fd = MCPSocket.connect(path: path)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let request: [String: Any] = ["tool": AgentSessionSocket.tool, "arguments": fields]
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        data.append(0x0A)
        let sent = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        guard sent else { return nil }
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !line.contains(0x0A) {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            line.append(contentsOf: buffer[0..<count])
        }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let text = object["text"] as? String,
              let fields = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        return fields
    }

    /// The state for the app (stop reason, last message), then OSC 7501 for the tab: working, blocked on a permission
    /// (with the question's words), or done. In order, so wait_for_tab never finds a turn done before its last message.
    func report() {
        var fields = "app=nxtrm-agent"
        if let permission = session.pending {
            let words = Data(ACPTranscript.question(permission).utf8.prefix(1500)).base64EncodedString()
            fields = "state=blocked:kind=permission:msg=" + words + ":" + fields
        } else if session.working {
            fields = "state=working:" + fields
        } else {
            fields = (session.lastStop == nil ? "state=idle:" : "state=done:") + fields
        }
        guard fields != lastReport else { return }
        lastReport = fields
        let osc = "\u{1b}]7501;" + fields + "\u{1b}\\"
        guard appSocket != nil else { return write(osc) }
        let state = session.pending != nil ? "attention" : (session.working ? "working" : (session.lastStop == nil ? "idle" : "done"))
        if state == "done" { turnsEnded += 1 }
        var update: [String: Any] = ["op": "report", "agent": agent.name, "state": state, "turns": turnsEnded,
                                     "last_message": session.lastMessage]
        if let stop = session.lastStop { update["stop_reason"] = stop.rawValue }
        callApp(update, timeout: 2) { [weak self] _ in self?.write(osc) }
    }

    func fatal(_ message: String) {
        session.note(message)
        draw()
        finish(1)
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
        keepWords(buffer) // a last line with no newline
        buffer.removeAll()
        let tail = errorTail.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " / ")
        session.note("\(agent.name) quit (exit \(status))" + (tail.isEmpty ? "." : ": " + ACPSession.oneLine(tail, limit: 300)))
        if !driver.isReady {
            // It quit before a session started: signed out, or a version without ACP.
            session.note("Run \(agent.program) in a tab to sign in or update it, then start the session again.")
        }
        draw()
        finish(status == 0 ? 0 : 1)
    }

    func finish(_ code: Int32) -> Never {
        driver.quitting()
        if process.isRunning { process.terminate() }
        write("\u{1b}]7501;state=clear\u{1b}\\")
        write("\r\n")
        restoreTerminal()
        exit(code)
    }

    // MARK: drawing

    private var width: Int {
        var size = winsize()
        return ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) - 1 : 79
    }

    private var rows: Int {
        var size = winsize()
        return ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_row > 0 ? Int(size.ws_row) : 24
    }

    /// Streaming chunks draw at most 30 times a second.
    func scheduleDraw() {
        guard !drawScheduled else { return }
        drawScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self] in
            self?.drawScheduled = false
            self?.draw()
        }
    }

    /// Redraws the live part: the current turn's lines not printed for good yet, and the input line. Lines past the
    /// screen's height are printed for good, as a terminal scrolls.
    func draw() {
        let width = self.width
        var out = "\r"
        if liveCount > 1 { out += "\u{1b}[\(liveCount - 1)A" }
        out += "\u{1b}[J"
        var lines = ACPTranscript.lines(session, from: liveFrom, width: width)
        lines.removeFirst(min(committed, lines.count))
        let room = max(rows - 2, 3)
        if lines.count > room {
            let head = lines.count - room
            for line in lines.prefix(head) { out += line.ansi + "\r\n" }
            committed += head
            lines.removeFirst(head)
        }
        for line in lines { out += line.ansi + "\r\n" }
        if let waitingLine {
            let fitted = waitingLine.count > width ? String(waitingLine.prefix(max(width - 1, 1))) + "\u{2026}" : waitingLine
            out += ACPTranscript.Line(fitted, .dim).ansi
        } else {
            out += ACPTranscript.inputLine(session, typed: typed, width: width).ansi
        }
        liveCount = lines.count + 1
        write(out)
    }

    /// The finished turn stays as printed: the live part is the input line alone again.
    func freeze() {
        liveFrom = session.items.count
        committed = 0
        liveCount = 1
    }

    // MARK: the terminal

    private func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private func rawTerminal() {
        tcgetattr(STDIN_FILENO, &savedTerminal)
        var raw = savedTerminal
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(ICRNL | IXON)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        write("\u{1b}[?2004h") // bracketed paste: send_to_tab's text arrives whole, newlines and all
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            guard count > 0 else {
                self?.finish(0)
                return
            }
            self?.keysArrived(Data(bytes.prefix(count)))
        }
        source.resume()
        input = source
        signal(SIGWINCH, SIG_IGN)
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        winch.setEventHandler { [weak self] in self?.draw() }
        winch.resume()
        resize = winch
        for stop in [SIGTERM, SIGHUP, SIGINT] {
            signal(stop, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: stop, queue: .main)
            source.setEventHandler { [weak self] in self?.finish(0) }
            source.resume()
            stopSources.append(source)
        }
    }

    private var stopSources: [DispatchSourceSignal] = []

    private func restoreTerminal() {
        write("\u{1b}[?2004l")
        tcsetattr(STDIN_FILENO, TCSANOW, &savedTerminal)
    }

    // MARK: keys

    private func keysArrived(_ data: Data) {
        if waitingLine != nil {
            // Nothing typed answers the Mac's question (R8): ⌃C or ⌃D ends the session, the rest is dropped.
            if data.contains(0x03) || data.contains(0x04) { finish(0) }
            return
        }
        keys.append(data)
        while !keys.isEmpty {
            if pasting {
                if let end = keys.range(of: Data("\u{1b}[201~".utf8)) {
                    typedBytes += keys[keys.startIndex..<end.lowerBound]
                    keys.removeSubrange(keys.startIndex..<end.upperBound)
                    pasting = false
                    draw()
                    continue
                }
                typedBytes += keys
                keys.removeAll()
                draw()
                return
            }
            let byte = keys[keys.startIndex]
            if byte == 0x1B {
                let sequence = keys.prefix(6)
                if sequence.starts(with: Data("\u{1b}[200~".utf8)) {
                    keys.removeFirst(6)
                    pasting = true
                    continue
                }
                if sequence.starts(with: Data("\u{1b}[A".utf8)) || sequence.starts(with: Data("\u{1b}OA".utf8)) {
                    keys.removeFirst(3)
                    session.moveHighlight(-1)
                    draw()
                    continue
                }
                if sequence.starts(with: Data("\u{1b}[B".utf8)) || sequence.starts(with: Data("\u{1b}OB".utf8)) {
                    keys.removeFirst(3)
                    session.moveHighlight(1)
                    draw()
                    continue
                }
                if keys.count >= 2, keys[keys.startIndex + 1] == UInt8(ascii: "[") || keys[keys.startIndex + 1] == UInt8(ascii: "O") {
                    // Another sequence (left, right, a function key): passed over whole.
                    var end = keys.startIndex + 2
                    while end < keys.endIndex, !(0x40...0x7E).contains(keys[end]) { end += 1 }
                    keys.removeSubrange(keys.startIndex...min(end, keys.endIndex - 1))
                    continue
                }
                keys.removeFirst() // Esc alone stops the turn
                cancelTurn()
                continue
            }
            keys.removeFirst()
            key(byte)
        }
    }

    private func key(_ byte: UInt8) {
        switch byte {
        case 0x03: // ⌃C
            if session.working { cancelTurn() } else if !typed.isEmpty { typed = ""; draw() } else { finish(0) }
        case 0x04: // ⌃D
            if typed.isEmpty, !session.working { finish(0) }
        case 0x0D, 0x0A:
            if let permission = session.pending { return choose(permission.highlighted) }
            guard !session.working else { return }
            let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            typed = ""
            if text.isEmpty { return draw() }
            send(text)
        case 0x7F, 0x08:
            if !typed.isEmpty { typed.removeLast() }
            draw()
        case UInt8(ascii: "1")...UInt8(ascii: "9") where session.pending != nil:
            choose(Int(byte - UInt8(ascii: "1")))
        default:
            guard byte >= 0x20, session.pending == nil else { return }
            typedBytes.append(byte)
            draw()
        }
    }
}

/// The Agent Client Protocol (plan 030): `initialize`, `session/new` with Next Term's MCP server, a `session/prompt` per
/// turn, `session/cancel`, and `session/request_permission` as the menu.
final class ACPDriver: AgentSessionDriver {
    private unowned let runner: AgentSessionRunner
    private var nextID = 1
    private var waiting: [Int: (ACPWire.Value?, String?) -> Void] = [:]
    private var sessionID: String?

    init(runner: AgentSessionRunner) {
        self.runner = runner
    }

    private var agent: ACPAgent { runner.agent }

    var arguments: [String] { agent.arguments }

    var startWords: String { ([agent.program] + agent.arguments).joined(separator: " ") }

    var isReady: Bool { sessionID != nil }

    func prepare(then go: @escaping () -> Void) {
        go()
    }

    func started() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        ask("initialize", ACPWire.initializeParams(version: version)) { [weak self] result, error in
            guard let self else { return }
            guard let result, error == nil else { return self.runner.fatal("The agent didn\u{2019}t start ACP: \(error ?? "no answer").") }
            guard result["protocolVersion"]?.int == ACPWire.protocolVersion else {
                return self.runner.fatal("\(self.agent.name) speaks ACP version \(result["protocolVersion"]?.int.map(String.init) ?? "?"); Next Term speaks version 1.")
            }
            self.newSession()
        }
    }

    private func newSession() {
        // In a Next Term tab, the agent gets Next Term's MCP server, as agents in other tabs do (R26).
        let servers: [ACPWire.StdioServer] = runner.nextTermMCPServer.map { [$0] } ?? []
        let cwd = FileManager.default.currentDirectoryPath
        ask("session/new", ACPWire.newSessionParams(cwd: cwd, servers: servers)) { [weak self] result, error in
            guard let self else { return }
            guard let id = result?["sessionId"]?.string else {
                let words = error ?? "no session"
                let auth = words.lowercased().contains("auth")
                return self.runner.fatal(auth ? "\(self.agent.name) needs you to sign in: run \(self.agent.program) in a tab once, then start the session again." : "The agent couldn\u{2019}t start a session: \(words).")
            }
            self.sessionID = id
            self.runner.session.note("\(self.agent.name) is ready.")
            self.runner.report()
            self.runner.draw()
            if let first = self.runner.firstPrompt {
                self.runner.firstPrompt = nil
                self.send(first)
            }
        }
    }

    private func ask(_ method: String, _ params: ACPWire.Value, then: @escaping (ACPWire.Value?, String?) -> Void) {
        let id = nextID
        nextID += 1
        waiting[id] = then
        runner.sendToAgent(ACPWire.request(id: id, method: method, params: params))
    }

    func received(line: Data) {
        guard let message = ACPWire.decode(line) else {
            // Not ACP: an agent that doesn't speak it here prints its own words (a sign-in screen); kept for the
            // line that says why it quit.
            runner.keepWords(line)
            return
        }
        handle(message)
    }

    private func handle(_ message: ACPWire.Incoming) {
        switch message {
        case .response(let id, let result, let error):
            guard let key = id.int, let then = waiting.removeValue(forKey: key) else { return }
            then(result, error)
        case .notification(let method, let params):
            if method == "session/update" {
                runner.session.apply(update: params)
                runner.scheduleDraw()
            }
        case .request(let id, let method, let params):
            if method == "session/request_permission" {
                if runner.session.pending != nil, let earlier = runner.session.cancelPending() {
                    reply(earlier, ACPWire.permissionOutcome(optionID: nil))
                }
                if runner.session.requested(permission: id, params: params) == nil {
                    // No option to give: cancelled, never allowed by default (R17).
                    reply(id, ACPWire.permissionOutcome(optionID: nil))
                    runner.session.note("The agent asked permission with no options; it was cancelled.")
                }
                runner.report()
                runner.draw()
            } else {
                runner.sendToAgent(ACPWire.error(id: id, code: -32601, message: "Next Term doesn\u{2019}t offer \(method)"))
            }
        }
    }

    private func reply(_ id: ACPWire.Value, _ result: ACPWire.Value) {
        runner.sendToAgent(ACPWire.result(id: id, result))
    }

    func send(_ text: String) {
        guard let sessionID, !runner.session.working else { return }
        runner.session.prompted(text)
        runner.report()
        runner.draw()
        ask("session/prompt", ACPWire.promptParams(session: sessionID, text: text)) { [weak self] result, error in
            guard let self else { return }
            if let error { self.runner.session.turnFailed(error) } else { self.runner.session.turnEnded(result?["stopReason"]?.string) }
            self.runner.draw()
            self.runner.freeze()
            self.runner.report()
        }
    }

    func cancelTurn() {
        guard let sessionID, runner.session.working else { return }
        if let pending = runner.session.cancelPending() { reply(pending, ACPWire.permissionOutcome(optionID: nil)) }
        runner.sendToAgent(ACPWire.notification(method: "session/cancel", params: .object(["sessionId": .string(sessionID)])))
        runner.draw()
    }

    func answer(_ index: Int) {
        guard let (id, option) = runner.session.choose(index) else { return }
        reply(id, ACPWire.permissionOutcome(optionID: option))
    }

    func quitting() {
        // As before the seam: the agent's process ends with the session, which ends its request with it.
    }
}

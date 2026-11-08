import Darwin
import Foundation
import NextTermCore

/// `nxtrm agent NAME [--prompt TEXT] [--resume ID]`: an agent session in the tab it runs in (plans 030, 035). It starts
/// the agent in ACP mode, or Claude Code or Codex over its own protocol (AgentSessionDrivers), draws the session as text
/// (ACPTranscript) with an input line, and says what the agent does over OSC 7501, so the tab's marks, its notification
/// and `wait_for_tab` follow the agent's own turns rather than its screen. A permission request is drawn as a numbered
/// menu that the tab's keys, the notification's buttons and `answer_agent` answer. The agent uses its own tools; it is given Next Term's MCP server when it runs in a Next Term tab.
enum AgentSessionCLI {
    static let usage = """
        nxtrm agent NAME [--prompt TEXT] [--resume ID]
          Runs an agent in this tab as an agent session: Claude Code (claude -p over stream-json), Codex (codex
          app-server), or an agent that speaks the Agent Client Protocol. Its turns, tool calls, plan and permission
          requests are drawn as text, and Next Term follows its state exactly. It runs the agent installed here, signed
          in as you signed it in.
          NAME is one of: \(ACPAgent.known.map(\.id).joined(separator: ", ")).
          --prompt TEXT   the first prompt, sent at once.
          --resume ID     Claude Code and Codex: go on with session ID (what a restore after an update runs).
        Type a prompt and Return to send it; ⌃C or Esc stops a turn; ⌃D on an empty line ends the session.
        Claude Code asks on the Mac before its first session in a folder, as it runs that folder's hooks and MCP servers.
        What stays in the agent's own terminal tab: Claude Code's /usage, /rewind and /login and its plugin and MCP
        panels; Codex's own screens, such as /status and /approvals.
        """

    static func run(_ arguments: [String]) -> Never {
        var name: String?
        var prompt: String?
        var resume: String?
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "-h", "--help", "help":
                print(usage)
                exit(0)
            case "--prompt", "-p":
                guard let text = rest.popFirst() else { fail("--prompt needs its text") }
                prompt = text
            case "--resume":
                guard let id = rest.popFirst(), AgentSessionVersion.isSessionID(id) else {
                    fail("--resume needs a session id: letters, digits, -, _ and . only, starting with a letter or digit")
                }
                resume = id
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
            fail("\(name) isn't an agent Next Term runs as a session (claude, codex, or an ACP agent). Installed here: \(ACPAgent.listed(installed)).")
        }
        guard let program = locate(agent.program, path: path) else {
            fail("\(agent.name) (\(agent.program)) isn't on the PATH. Installed here: \(ACPAgent.listed(installed)).")
        }
        if resume != nil, !agent.resumesSessions { fail("\(agent.name) sessions don\u{2019}t resume; only Claude Code\u{2019}s and Codex\u{2019}s do") }
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { fail("nxtrm agent runs in a terminal tab") }
        let terminal = AgentSessionTerminal(agent: agent, program: program, firstPrompt: prompt, resumeID: resume)
        terminal.freshArguments = without(resume: arguments)
        terminal.start()
        dispatchMain()
    }

    /// `arguments` without `--resume` and its id: what a session starts again with when its resume can't go on.
    static func without(resume arguments: [String]) -> [String] {
        var kept: [String] = []
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--resume": _ = rest.popFirst()
            case "--prompt", "-p":
                kept.append(argument)
                if let text = rest.popFirst() { kept.append(text) }
            default: kept.append(argument)
            }
        }
        return kept
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

/// What a session speaks to its agent (plan 035 KTD1): ACP, Claude Code's stream-json or Codex's app-server. The session
/// (`AgentSessionEngine`) keeps the process, the reports and the Allow always question on the Mac, one copy for every agent; a
/// driver turns the agent's lines into the session model (`context.session`) and the user's actions into the agent's
/// lines. Everything runs on the main queue.
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

/// `nxtrm agent`'s presenter (plan 037 KTD2): the session drawn as text in the tab it runs in, with an input line, its
/// keys in raw mode, and its state over OSC 7501, exactly as before the session engine was split out. Everything runs on
/// the main queue.
final class AgentSessionTerminal: AgentSessionPresenter {
    let engine: AgentSessionEngine
    /// `nxtrm agent`'s arguments without `--resume`: a Claude Code session whose resume can't go on starts again with them.
    var freshArguments: [String] = []

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

    init(agent: ACPAgent, program: String, firstPrompt: String?, resumeID: String?) {
        let folder = FileManager.default.currentDirectoryPath
        engine = AgentSessionEngine(agent: agent, program: program, folder: folder, firstPrompt: firstPrompt, launch: .inherit,
                              bridge: AgentSessionSocketBridge())
        engine.resumeID = resumeID
        engine.presenter = self
    }

    private var session: ACPSession { engine.session }

    func start() {
        rawTerminal()
        engine.start()
    }

    // MARK: the presenter

    func writeTitle(_ title: String) {
        write("\u{1b}]2;\(title)\u{07}") // the tab's title
    }

    func changed() { draw() }

    func changedSoon() { scheduleDraw() }

    func turnFinished() { freeze() }

    func stateReported(_ fields: String) {
        write("\u{1b}]7501;" + fields + "\u{1b}\\")
    }

    func ended(code: Int32) {
        write("\u{1b}]7501;state=clear\u{1b}\\")
        write("\r\n")
        restoreTerminal()
        exit(code)
    }

    /// The same `nxtrm agent`, run again in this process without `--resume`: every part of the session starts fresh, and
    /// the tab sees the same program go on. The folder is trusted by now, so it isn't asked again.
    func startAfresh() {
        restoreTerminal()
        guard let me = Bundle.main.executablePath else { return ended(code: 1) }
        for stop in [SIGTERM, SIGHUP, SIGINT, SIGWINCH, SIGPIPE] { signal(stop, SIG_DFL) }
        let words = [me, "--cli", "agent"] + freshArguments
        var argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) }
        argv.append(nil)
        execv(me, &argv)
        // It couldn't run again: the session ends as it would have.
        engine.session.note("Couldn\u{2019}t start \(engine.agent.name) again: " + String(cString: strerror(errno)))
        ended(code: 1)
    }

    /// Ends the session from the tab (⌃C or ⌃D on an empty line, its stdin's end, a signal).
    private func finish(_ code: Int32) {
        engine.finish(code)
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
        if let waitingLine = engine.waitingLine {
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
        if engine.waitingLine != nil {
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
                    engine.moveHighlight(-1)
                    continue
                }
                if sequence.starts(with: Data("\u{1b}[B".utf8)) || sequence.starts(with: Data("\u{1b}OB".utf8)) {
                    keys.removeFirst(3)
                    engine.moveHighlight(1)
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
                engine.cancelTurn()
                continue
            }
            keys.removeFirst()
            key(byte)
        }
    }

    private func key(_ byte: UInt8) {
        switch byte {
        case 0x03: // ⌃C
            if session.working { engine.cancelTurn() } else if !typed.isEmpty { typed = ""; draw() } else { finish(0) }
        case 0x04: // ⌃D
            if typed.isEmpty, !session.working { finish(0) }
        case 0x0D, 0x0A:
            if let permission = session.pending { return engine.choose(permission.highlighted) }
            guard !session.working else { return }
            let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            typed = ""
            if text.isEmpty { return draw() }
            engine.send(text)
        case 0x7F, 0x08:
            if !typed.isEmpty { typed.removeLast() }
            draw()
        case UInt8(ascii: "1")...UInt8(ascii: "9") where session.pending != nil:
            engine.choose(Int(byte - UInt8(ascii: "1")))
        default:
            guard byte >= 0x20, session.pending == nil else { return }
            typedBytes.append(byte)
            draw()
        }
    }
}

/// `nxtrm agent`'s way to the app: requests on Next Term's socket (`AgentSessionSocket`), when the session runs in one of
/// its tabs, one at a time and in order, so a report is in before the tab hears the state it reports.
final class AgentSessionSocketBridge: AgentSessionBridge {
    /// Next Term's socket, when the session runs in one of its tabs.
    let appSocket = ProcessInfo.processInfo.environment["NEXTTERM_MCP_SOCKET"]
    private let appQueue = DispatchQueue(label: "nxtrm-agent.app")

    var isConnected: Bool { appSocket != nil }

    var offersMCP: Bool { appSocket != nil }

    func report(_ update: [String: Any], then: @escaping ([String: Any]?) -> Void) {
        callApp(update, timeout: 2, then: then)
    }

    func confirmAlways(agent: String, action: String, option: String, then: @escaping (Bool) -> Void) {
        let fields: [String: Any] = ["op": "confirm_always", "agent": agent, "action": action, "option": option]
        callApp(fields, timeout: 16 * 60) { answer in then(answer?["approved"] as? Bool == true) }
    }

    func trustFolder(agent: String, folder: String, then: @escaping (Bool?) -> Void) {
        let fields: [String: Any] = ["op": "trust_folder", "agent": agent, "folder": folder]
        callApp(fields, timeout: 16 * 60) { answer in then(answer.map { $0["trusted"] as? Bool == true }) }
    }

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
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
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
}

/// The Agent Client Protocol (plan 030): `initialize`, `session/new` with Next Term's MCP server, a `session/prompt` per
/// turn, `session/cancel`, and `session/request_permission` as the menu.
final class ACPDriver: AgentSessionDriver {
    private unowned let context: AgentSessionContext
    private var nextID = 1
    private var waiting: [Int: (ACPWire.Value?, String?) -> Void] = [:]
    private var sessionID: String?

    init(context: AgentSessionContext) {
        self.context = context
    }

    private var agent: ACPAgent { context.agent }

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
            guard let result, error == nil else { return self.context.fatal("The agent didn\u{2019}t start ACP: \(error ?? "no answer").") }
            guard result["protocolVersion"]?.int == ACPWire.protocolVersion else {
                return self.context.fatal("\(self.agent.name) speaks ACP version \(result["protocolVersion"]?.int.map(String.init) ?? "?"); Next Term speaks version 1.")
            }
            self.newSession()
        }
    }

    private func newSession() {
        // In a Next Term tab, the agent gets Next Term's MCP server, as agents in other tabs do (R26).
        let servers: [ACPWire.StdioServer] = context.nextTermMCPServer.map { [$0] } ?? []
        let cwd = context.folder
        ask("session/new", ACPWire.newSessionParams(cwd: cwd, servers: servers)) { [weak self] result, error in
            guard let self else { return }
            guard let id = result?["sessionId"]?.string else {
                let words = error ?? "no session"
                let auth = words.lowercased().contains("auth")
                if auth {
                    return self.context.needsSignIn("\(self.agent.name) needs you to sign in: run \(self.agent.program) in a tab once, then start the session again.")
                }
                return self.context.fatal("The agent couldn\u{2019}t start a session: \(words).")
            }
            self.sessionID = id
            self.context.session.note("\(self.agent.name) is ready.")
            self.context.report()
            self.context.changed()
            if let first = self.context.firstPrompt {
                self.context.firstPrompt = nil
                self.send(first)
            }
        }
    }

    private func ask(_ method: String, _ params: ACPWire.Value, then: @escaping (ACPWire.Value?, String?) -> Void) {
        let id = nextID
        nextID += 1
        waiting[id] = then
        context.sendToAgent(ACPWire.request(id: id, method: method, params: params))
    }

    func received(line: Data) {
        guard let message = ACPWire.decode(line) else {
            // Not ACP: an agent that doesn't speak it here prints its own words (a sign-in screen); kept for the
            // line that says why it quit.
            context.keepWords(line)
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
                context.session.apply(update: params)
                context.changedSoon()
            }
        case .request(let id, let method, let params):
            if method == "session/request_permission" {
                if context.session.pending != nil, let earlier = context.session.cancelPending() {
                    reply(earlier, ACPWire.permissionOutcome(optionID: nil))
                }
                if context.session.requested(permission: id, params: params) == nil {
                    // No option to give: cancelled, never allowed by default (R17).
                    reply(id, ACPWire.permissionOutcome(optionID: nil))
                    context.session.note("The agent asked permission with no options; it was cancelled.")
                }
                context.report()
                context.changed()
            } else {
                context.sendToAgent(ACPWire.error(id: id, code: -32601, message: "Next Term doesn\u{2019}t offer \(method)"))
            }
        }
    }

    private func reply(_ id: ACPWire.Value, _ result: ACPWire.Value) {
        context.sendToAgent(ACPWire.result(id: id, result))
    }

    func send(_ text: String) {
        guard let sessionID, !context.session.working else { return }
        context.session.prompted(text)
        context.report()
        context.changed()
        ask("session/prompt", ACPWire.promptParams(session: sessionID, text: text)) { [weak self] result, error in
            guard let self else { return }
            if let error { self.context.session.turnFailed(error) } else { self.context.session.turnEnded(result?["stopReason"]?.string) }
            self.context.changed()
            self.context.turnFinished()
            self.context.report()
        }
    }

    func cancelTurn() {
        guard let sessionID, context.session.working else { return }
        if let pending = context.session.cancelPending() { reply(pending, ACPWire.permissionOutcome(optionID: nil)) }
        context.sendToAgent(ACPWire.notification(method: "session/cancel", params: .object(["sessionId": .string(sessionID)])))
        context.changed()
    }

    func answer(_ index: Int) {
        guard let (id, option) = context.session.choose(index) else { return }
        reply(id, ACPWire.permissionOutcome(optionID: option))
    }

    func quitting() {
        // As before the seam: the agent's process ends with the session, which ends its request with it.
    }
}

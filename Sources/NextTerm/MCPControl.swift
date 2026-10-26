import AppKit
import Darwin
import NextTermCore

/// The app's end of Next Term's MCP server: `nxtrm mcp` (started by an agent) connects to this Unix
/// socket for each tool call, sends one line of JSON and reads one back. The tools themselves run here,
/// on the main thread, against the real windows and tabs.
///
/// Security: the socket is 0600 in the user's own Application Support folder, and every connection is
/// checked to come from this user (getpeereid). That is the same reach as the user's own shell: anyone
/// who can connect can already run commands. Nothing listens on the network.
final class MCPControlServer: @unchecked Sendable {
    static let shared = MCPControlServer()

    /// The socket: the default for the user's agents; the self-test uses its own.
    private(set) var path = MCPServer.socketPath()
    private var listenSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "nextterm.mcp")
    private let calls = MCPCalls()

    var isRunning: Bool { listenSocket >= 0 }

    func start(path: String? = nil) {
        guard !isRunning else { return }
        if let path { self.path = path }
        let folder = (self.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Another Next Term already answers here (a second copy of the app): leave it be.
        if Self.answers(self.path) { NSLog("Next Term: another Next Term serves \(self.path)"); return }
        unlinkIfSocket(self.path)
        // Owner only from the moment it exists, and never handed to a tab's shell (MCPSocket): a copy there would keep
        // it listening after a quit or an update's drain closed this one.
        let fd = MCPSocket.listen(path: self.path)
        guard fd >= 0 else {
            NSLog("Next Term: MCP socket failed: \(String(cString: strerror(errno)))")
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenSocket = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.resume()
        acceptSource = source
    }

    func stop() {
        guard isRunning else { return }
        acceptSource?.cancel()
        acceptSource = nil
        close(listenSocket)
        listenSocket = -1
        unlinkIfSocket(path)
    }

    private func unlinkIfSocket(_ path: String) {
        var info = stat()
        if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK { unlink(path) }
    }

    /// Whether something accepts connections on the socket.
    static func answers(_ path: String) -> Bool {
        let fd = connectSocket(path)
        if fd >= 0 { close(fd) }
        return fd >= 0
    }

    static func connectSocket(_ path: String) -> Int32 { MCPSocket.connect(path: path) }

    private func acceptAll() {
        while true {
            let client = MCPSocket.accept(listenSocket) // close-on-exec: a new_tab request's connection is open while its shell starts
            guard client >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            var pid: pid_t = 0
            var size = socklen_t(MemoryLayout<pid_t>.size)
            let peer = getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 ? pid : nil
            let token = PeerCode.auditToken(of: client) // Secrets' wrapper is checked by its code (SecretSocket)
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            DispatchQueue.global(qos: .userInitiated).async { self.serve(client, peer: peer, token: token) }
        }
    }

    /// The longest request read (the self-test lowers it).
    static var requestLimit = MCPServer.maxRequestBytes

    /// One request line in, one answer line out. The quit's drain can answer it at any point (`calls`).
    private func serve(_ fd: Int32, peer: pid_t?, token: audit_token_t? = nil) {
        let call = calls.begin(fd)
        defer { calls.end(call) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var ended = false
        // Only what just came is looked at for the line's end: a write's request can be tens of megabytes.
        while !ended, line.count <= Self.requestLimit {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            ended = buffer[0..<count].contains(0x0A)
            line.append(contentsOf: buffer[0..<count])
        }
        let request = ended ? Self.request(in: line) : nil
        // `nxtrm secret run`'s request, answered on this connection alone; never an MCP tool. The quit's drain leaves it be,
        // and one the quit answered first gets nothing written: the wrapper reads the closed connection. A wrapper the quit
        // found before its line came is no MCP caller either: no MCP answer goes to it. Its connection closes as the call
        // ends, as every other one does.
        // `nxtrm secret import`'s header answers itself the same way; its keys come after, raw, never through this reader.
        let selfAnswering = request?.tool == SecretSocket.tool || request?.tool == SecretPipeSocket.tool
        let route = calls.route(call, read: request, selfAnswering: selfAnswering) {
            SecretSocket.isWrapper(pid: peer)
        }
        switch route {
        case .answerItself:
            if request?.tool == SecretPipeSocket.tool {
                return SecretPipeSocket.handle(fd: fd, arguments: request?.arguments ?? [:], peer: peer, auditToken: token)
            }
            return SecretSocket.handle(fd: fd, arguments: request?.arguments ?? [:], peer: peer, auditToken: token)
        case .nothing: return
        case .drained(let answer): return send(answer, on: fd)
        case .serve: break
        }
        if !ended, line.count > Self.requestLimit { return refuseTooLarge(fd, buffer: &buffer) }
        guard let request else { return }
        let tool = request.tool, arguments = request.arguments, herdr = request.caller
        if call.asked(request) {
            DispatchQueue.main.async {
                guard call.starts() else { return } // the quit answered it first
                MCPControl.call(tool, arguments, caller: peer, herdrCaller: herdr) { result in call.finish(result) }
            }
            call.answered.wait()
        }
        send(call.answer ?? MCPServer.CallResult(text: "No answer", isError: true), on: fd)
    }

    /// The tool, arguments and caller of a whole request line, or nil.
    private static func request(in line: Data) -> MCPCalls.Request? {
        guard let end = line.firstIndex(of: 0x0A),
              let object = (try? JSONSerialization.jsonObject(with: line[..<end])) as? [String: Any] else { return nil }
        return MCPCalls.Request.parse(object)
    }

    /// As Next Term quits (KTD17): it takes no new connection, answers every call it is serving with `answer`, calls posted
    /// to the main thread that never ran included, and waits up to `wait` for those answers to be written. An update's quit
    /// leaves the socket file, so `nxtrm mcp` is refused there and reads that as a restart; any other quit removes it.
    func drain(keepingSocket: Bool, wait: TimeInterval = 1, answer: @escaping (MCPCalls.Request?, Bool) -> MCPServer.CallResult) {
        guard isRunning else { return }
        acceptSource?.cancel()
        acceptSource = nil
        close(listenSocket)
        listenSocket = -1
        if !keepingSocket { unlinkIfSocket(path) }
        calls.drain(wait: wait, answer: answer)
    }

    /// A request over the limit: the rest of it is read and dropped, so the caller has finished sending
    /// and reads why, instead of a closed connection.
    private func refuseTooLarge(_ fd: Int32, buffer: inout [UInt8]) {
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 || buffer[0..<count].contains(0x0A) { break }
        }
        let limit = ByteCountFormatter.string(fromByteCount: Int64(Self.requestLimit), countStyle: .decimal)
        let text = "The request is too large: Next Term reads up to \(limit) per call (files are written up to 5 MB). Nothing was done."
        send(MCPServer.CallResult(text: text, isError: true), on: fd)
    }

    /// Writes the answer line; the connection closes as its call ends. Stored keys' values are masked in it one last
    /// time, whatever tool made it (RemoteMCP, MCPWriteControl, SkillsMCP included), in its JSON's strings too, where
    /// a value's quotes and line breaks are escaped.
    private func send(_ answer: MCPServer.CallResult, on fd: Int32) {
        let masked = MCPServer.CallResult(text: SecretMask.current.mask(answer: answer.text), isError: answer.isError)
        let data = MCPServer.encodeAnswer(masked)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }
}

/// The tools, on the main thread.
enum MCPControl {
    typealias Reply = (MCPServer.CallResult) -> Void

    /// Input given to a tab through MCP, so wait_for_tab waits for the work it starts, however quick.
    private struct Sent {
        let at: TimeInterval
        let commands: Int
        var sawWork = false
    }
    private static var lastSent: [UUID: Sent] = [:]
    /// Text send_to_tab typed with no Return, as typed, and the tab's write count just after it: a press_keys Return or
    /// more text that comes next, with nothing written meanwhile, carries on that line (TerminalTab.submitOwnLine).
    private static var unsubmitted: [UUID: (typed: String, writes: Int)] = [:]

    /// Tabs an agent drives over MCP: opened with new_tab, or given input with send_to_tab, press_keys or
    /// answer_agent, until you type in one yourself. That agent waits for their work (wait_for_tab), so while
    /// you are in Next Term their agents finishing is its news, not yours (NotificationSettings.shouldNotify).
    static var driven: Set<UUID> = []

    static func isDriven(_ tab: TerminalTab) -> Bool { driven.contains(tab.id) }

    /// You pressed a key in the tab, or pasted into it: what happens there is yours again.
    static func typedByUser(_ tab: TerminalTab) {
        driven.remove(tab.id)
        HerdrMCP.userTyped(in: tab) // its herdr agents too
        MCPRestoredTabs.typedByUser(tab) // a restored tab's details count your commands from here (U13)
    }

    /// The tab closed.
    static func forget(_ tab: TerminalTab) {
        driven.remove(tab.id)
        lastSent[tab.id] = nil
        unsubmitted[tab.id] = nil
    }

    static func isBusy(_ tab: TerminalTab) -> Bool {
        !tab.exited && (tab.status.state == .working || (tab.status.running && tab.status.kind != .agent))
    }

    /// Input went in: watch for the work it starts (a command can start and end between two looks).
    static func sent(to tab: TerminalTab) {
        SecretRequests.tabGotInput(tab.id) // its run_with_secrets grants end
        driven.insert(tab.id)
        lastSent[tab.id] = Sent(at: TerminalTab.now, commands: tab.status.commandsStarted)
        func look(_ count: Int) {
            guard var sent = lastSent[tab.id], !sent.sawWork else { return }
            if isBusy(tab) || tab.status.commandsStarted > sent.commands {
                sent.sawWork = true
                lastSent[tab.id] = sent
                return
            }
            if count < 50 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { look(count + 1) } }
        }
        look(0)
    }

    /// Input sent in the last 5 s that has not visibly started anything yet (agents show work within a second or two).
    static func isStarting(_ tab: TerminalTab) -> Bool {
        guard let sent = lastSent[tab.id], !sent.sawWork, TerminalTab.now - sent.at < 5 else { return false }
        return !(isBusy(tab) || tab.status.commandsStarted > sent.commands)
    }

    private static var app: AppDelegate { AppDelegate.shared }
    private static var allTabs: [TerminalTab] { app.controllers.flatMap(\.tabs) }

    /// A tab's text an agent reads (title, command, screen, question, choices, served URL, selected text), with stored
    /// keys' exact values masked. Pattern masking is not added here: it would change what agents read today. The
    /// self-test turns this off to check the last pass in `send`.
    static var fieldMasks = true
    static func field(_ text: String) -> String { fieldMasks ? SecretMask.current.mask(text) : text }
    /// A tab's last `count` rows, masked over whole lines: a key a wrap split above the window is masked in the part the
    /// window shows (`TerminalTab.screenTail(_:masked:)`). A plugin's ghost at a zsh prompt (zsh-autosuggestions'), once its
    /// cells are found where zsh drew it, is left out: it isn't typed (`typedInput`).
    static func fieldTail(_ tab: TerminalTab, _ count: Int = AgentScreen.scannedLines) -> [String] {
        let ghost = tab.typedInput(mask: field)?.ghost ?? []
        return fieldMasks ? tab.screenTail(count, masked: SecretMask.current, excludingGhost: ghost) : tab.screenTail(count, excludingGhost: ghost)
    }

    /// Runs `body` once the hook's report of a tab's line is current (nothing was written to the shell after it), or there
    /// is none to wait for, or 200 ms on: a line an agent just typed is read as the shell has it.
    static func whenLineReported(_ tab: TerminalTab, until deadline: TimeInterval, _ body: @escaping () -> Void) {
        if !tab.awaitsLineReport || TerminalTab.now >= deadline { return body() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { whenLineReported(tab, until: deadline, body) }
    }

    /// The screen and `input` for read_tab and wait_for_tab: the line being typed at a zsh prompt, and a plugin's ghost,
    /// which is left out of the screen.
    private static func screenFields(_ tab: TerminalTab, lines: Int) -> [String: Any] {
        let typed = tab.typedInput(mask: field)
        let ghost = typed?.ghost ?? []
        let rows = fieldMasks ? tab.screenTail(lines, masked: SecretMask.current, excludingGhost: ghost) : tab.screenTail(lines, excludingGhost: ghost)
        var info: [String: Any] = ["screen": rows.joined(separator: "\n")]
        if let input = typed?.input { info["input"] = input }
        return info
    }
    /// The menu under the tab's question, for an agent to read: matched on the screen as the question was read from it,
    /// its choices from `fieldTail`'s rows (`AgentScreen.menu(asking:screenLines:shown:)`).
    static func fieldMenu(_ tab: TerminalTab, question: String) -> AgentMenu? {
        // OpenCode marks its selected button only by its background: its menu is read from its rows with their colours,
        // and its options' words from the same rows masked over whole lines, as every other tab's choices are.
        if tab.isOpencodeScreen {
            let count: Int = tab.agentScreenLines
            return AgentScreen.menu(asking: question, screenRows: tab.liveRows(count), shown: fieldTail(tab, count))
        }
        return AgentScreen.menu(asking: question, screenLines: tab.screenTail(), shown: fieldTail(tab))
    }
    /// A tab's restored details (MCPRestoredTabs), masked: their note can quote a command line or a resume's screen, saved
    /// before a key in it was stored.
    static func restoredFields(_ tab: TerminalTab) -> [String: Any] {
        let fields = MCPRestoredTabs.fields(tab)
        return fieldMasks ? SecretMask.current.mask(fields: fields) : fields
    }

    static func fail(_ text: String) -> MCPServer.CallResult { MCPServer.CallResult(text: text, isError: true) }
    static func ok(_ value: Any) -> MCPServer.CallResult { MCPServer.CallResult(text: MCPServer.json(value)) }

    /// Runs a tool. `approval`, `requester` and `connection` are for the write tools that MCPWriteControl
    /// runs, and for install_skill and remove_skill: who approves their change, who asks as the approval
    /// window names it, and which remote connection (its grant id) a Decline and Stop Asking stops. The
    /// local socket passes none, so a local agent's change always waits for Approve on the Mac; the remote
    /// door passes its connection's policy, name and grant id (see MCPApproval).
    /// `herdrCaller`: what the bridge said of the agent that called, its herdr pane (MCPCalls.Request.caller).
    static func call(_ tool: String, _ arguments: [String: Any], caller pid: pid_t?, herdrCaller: [String: String] = [:],
                     approval: MCPApproval = .askOnMac, requester: String? = nil, connection: String? = nil, reply: @escaping Reply) {
        let caller = pid.flatMap { ClaudeIDEServer.tab(for: $0, among: allTabs) }
        // Safe mode runs only tools that read; an update's wait refuses new work elsewhere (U13).
        if let refusal = MCPRestoredTabs.refusal(tool, arguments) { return reply(fail(refusal)) }
        // One of herdr's agents: its id stands where a tab's does, its tab's refusals first (HerdrMCP).
        if let raw = arguments["tab_id"] as? String, let target = HerdrTarget.parse(raw) {
            if let refusal = MCPRestoredTabs.refusal(tool, ["tab_id": target.tabID]) { return reply(fail(refusal)) }
            if HerdrMCP.route(tool, target, arguments, caller: caller, herdrCaller: herdrCaller, reply: reply) { return }
        }
        switch tool {
        case "list_tabs": reply(listTabs(project: arguments["project"] as? String, caller: caller, herdrCaller: herdrCaller))
        case "list_projects": reply(listProjects())
        case "read_tab":
            guard let tab = findTab(arguments["tab_id"]) else { return reply(fail("No tab with that id; list_tabs shows them.")) }
            readTab(tab, lines: arguments["lines"] as? Int ?? 80, reply: reply)
        case "wait_for_tab":
            guard let tab = findTab(arguments["tab_id"]) else { return reply(fail("No tab with that id; list_tabs shows them.")) }
            let seconds = min(300, max(1, arguments["timeout_seconds"] as? Int ?? 50))
            waitFor(tab, until: TerminalTab.now + Double(seconds), sawWork: false, reply: reply)
        case "get_editor_selection": reply(editorSelection(caller: caller))
        case "get_open_files": reply(openFiles())
        case "open_project": reply(openProject(arguments["path"] as? String ?? ""))
        case "new_tab": newTab(arguments, caller: caller, reply: reply)
        case "send_to_tab": sendToTab(arguments, caller: caller, reply: reply)
        case "press_keys": pressKeys(arguments, caller: caller, reply: reply)
        case "answer_agent": answerAgent(arguments, caller: caller, reply: reply)
        case "read_file", "find_in_files", "git_status", "get_diff": projectTool(tool, arguments, caller: caller, reply: reply)
        case "show_tab": reply(withTab(arguments) { tab in showTab(tab) })
        case "close_tab": closeTab(arguments, caller: caller, reply: reply)
        case "open_in_editor": reply(openInEditor(arguments))
        case "list_hosts", "add_host", "remove_host", "check_host", "new_remote_tab", "host_sessions", "host_changes":
            RemoteMCP.call(tool, arguments, caller: caller, reply: reply)
        case "list_shortcuts": MainActor.assumeIsolated { reply(ShortcutsMCP.listShortcuts(arguments)) }
        case "show_settings": MainActor.assumeIsolated { reply(ShortcutsMCP.showSettings(arguments)) }
        case "list_skills", "get_skill", "install_skill", "remove_skill":
            MainActor.assumeIsolated {
                SkillsMCP.call(tool, arguments, caller: caller, callerPID: pid, approval: approval, connection: connection,
                               requester: requester, reply: reply)
            }
        case "list_secrets", "request_secret", "store_secret", "run_with_secrets", "import_secrets":
            MainActor.assumeIsolated {
                SecretsMCP.call(tool, arguments, caller: caller, pid: pid, approval: approval, requester: requester, connection: connection,
                                reply: reply)
            }
        case "add_task":
            MainActor.assumeIsolated {
                TasksMCP.addTask(arguments, caller: caller, approval: approval, requester: requester, connection: connection, reply: reply)
            }
        case _ where MCPServer.isImportTool(tool):
            MainActor.assumeIsolated {
                MCPImportControl.call(tool, arguments, caller: caller, approval: approval, requester: requester, connection: connection, reply: reply)
            }
        case _ where MCPServer.isControlTool(tool):
            MainActor.assumeIsolated {
                MCPWriteControl.call(tool, arguments, caller: caller, approval: approval, requester: requester, connection: connection, reply: reply)
            }
        default: reply(fail("Unknown tool \(tool)"))
        }
    }

    // MARK: looking

    private static func findTab(_ id: Any?) -> TerminalTab? {
        guard let id = (id as? String)?.lowercased() else { return nil }
        return allTabs.first { $0.id.uuidString.lowercased() == id }
    }

    /// The tab with this id (as list_tabs gives it), or nil.
    static func tab(withID id: String) -> TerminalTab? { findTab(id) }

    static func controller(of tab: TerminalTab) -> TerminalWindowController? {
        app.controllers.first { $0.tabs.contains { $0 === tab } }
    }

    private static func withTab(_ arguments: [String: Any], _ body: (TerminalTab) -> MCPServer.CallResult) -> MCPServer.CallResult {
        guard let tab = findTab(arguments["tab_id"]) else { return fail("No tab with that id; list_tabs shows them.") }
        return body(tab)
    }

    /// What the tab is doing, in one word: the dot's state, or "running" for a plain command.
    private static func state(_ tab: TerminalTab) -> String {
        if tab.exited { return "exited" }
        if tab.disconnected { return "disconnected" }
        if tab.remote != nil && !tab.remoteConnected { return "connecting" }
        let state = tab.status.state
        if state == .idle && tab.status.running && tab.status.kind != .agent { return "running" }
        return state.rawValue
    }

    static func describe(_ tab: TerminalTab, in controller: TerminalWindowController, caller: TerminalTab?,
                         herdrCaller: [String: String] = [:]) -> [String: Any] {
        var info: [String: Any] = [
            "id": tab.id.uuidString.lowercased(),
            "title": field(tab.title),
            "directory": tab.directory,
            "state": state(tab),
            "front": controller.activeTab === tab,
        ]
        // Panes split together in one tab of the tab bar share its number.
        if let index = controller.groups.firstIndex(where: { $0.contains(tab) }) {
            info["tab_bar_position"] = index + 1
            if controller.groups[index].isSplit { info["split"] = true }
        }
        if tab.status.running {
            info["program"] = tab.status.program
            info["agent"] = tab.status.kind == .agent
            info["command"] = String(field(tab.status.command).prefix(300))
        }
        info.merge(questionInfo(tab)) { $1 }
        info.merge(restoredFields(tab)) { $1 } // what a restart did to it (U13)
        if let code = tab.status.exitCode, tab.status.state == .failed { info["exit_code"] = Int(code) }
        if tab === caller { info["you"] = true }
        if let openedBy = tab.openedBy {
            info["opened_by"] = openedBy.uuidString.lowercased()
            if tab === caller { info["note"] = "Another agent started this tab: open no tabs unless the user asks you to, here." }
        }
        // A dev server's local address, without the query, where a login token goes (Jupyter's `?token=`).
        if let url = tab.servedURL { info["served_url"] = field(ServedURL.shared(url)) }
        info.merge(AgentPlaces.shared.fields(of: tab, in: controller)) { $1 } // where its agent works, against the window
        if let remote = tab.remote {
            if tab.loginPrompt { info["login_prompt"] = true } // ssh asks the user something in that tab
            if let refusal = RemoteConnection.refusal(remote.host) { info["host_problem"] = refusal }
            info["host"] = remote.host.name
            info["host_id"] = remote.host.id
            // A tab whose tmux or herdr was missing on the host is a plain shell that nothing keeps: off, not as opened.
            info["keep"] = remote.keep.shown(fellBack: tab.fellBack).rawValue
            if tab.fellBack { info["fell_back"] = true }
            if tab.fellBack, remote.keep == .herdr {
                let why = tab.fellBackReason ?? "herdr wasn’t found on the host"
                info["herdr_missing_reason"] = "\(why). Next Term never installs it: \(RemoteShell.herdrInstallPage)"
            }
            if remote.keep == .tmux, tab.isKept { info["session"] = remote.session }
            if remote.keep == .herdr, let session = remote.herdrSession { info["herdr_session"] = session }
            // herdr doesn't answer (or needs a restart, or is on the host now): its agents' states are unknown.
            if remote.keep == .herdr, let note = tab.herdrWatch.note { info["herdr_note"] = note }
        }
        // herdr's agents, each with an id of its own (HerdrMCP), on a server or in a tab on this Mac.
        if tab.followsHerdr {
            var agents = tab.herdrTracker.agents.map { HerdrMCP.entry($0, in: tab, caller: herdrCaller) }
            // And those on the machines saved in a herdr here, under the tab that reads them.
            if let watch = LocalHerdrWatch.shared.machines(of: tab), watch.tab === tab {
                for machine in watch.machines {
                    agents += machine.tracker.agents.map { HerdrMCP.entry($0, in: tab, machine: machine) }
                }
            }
            if !agents.isEmpty { info["herdr_agents"] = agents }
        }
        return info
    }

    private static func listTabs(project: String?, caller: TerminalTab?, herdrCaller: [String: String]) -> MCPServer.CallResult {
        let wanted = project.map { canonicalPath(($0 as NSString).expandingTildeInPath) }
        let key = NSApp.keyWindow
        let windows: [[String: Any]] = app.controllers.compactMap { controller in
            if let wanted, controller.project != wanted { return nil }
            var window: [String: Any] = [
                "tabs": controller.tabs.map { describe($0, in: controller, caller: caller, herdrCaller: herdrCaller) },
                "front": controller.window === key,
            ]
            if let project = controller.project {
                window["project"] = project
                window["name"] = (project as NSString).lastPathComponent
            }
            return window
        }
        if windows.isEmpty, let wanted { return fail("No window has the project \(wanted) open; open_project opens it.") }
        return ok(["windows": windows])
    }

    private static func listProjects() -> MCPServer.CallResult {
        let open = app.controllers.compactMap(\.project)
        let recent = app.recentProjects.filter { !open.contains($0) }
        return ok(["open": open, "recent": recent])
    }

    /// At a zsh prompt it waits for the hook's report of a line just written to (200 ms at most), so `input` and the screen
    /// say what the shell has.
    private static func readTab(_ tab: TerminalTab, lines: Int, reply: @escaping Reply) {
        whenLineReported(tab, until: TerminalTab.now + 0.2) {
            var info: [String: Any] = ["id": tab.id.uuidString.lowercased(), "state": state(tab)]
            info.merge(questionInfo(tab)) { $1 }
            info.merge(restoredFields(tab)) { $1 }
            info.merge(screenFields(tab, lines: min(2000, max(1, lines)))) { $1 }
            reply(ok(info))
        }
    }

    /// Done when the agent stops working (or the command ends). Input sent just before counts: the
    /// wait first gives the agent a few seconds to start on it.
    private static func waitFor(_ tab: TerminalTab, until deadline: TimeInterval, sawWork: Bool, reply: @escaping Reply) {
        let now = TerminalTab.now
        let busy = isBusy(tab)
        let saw = sawWork || busy
        let starting = !saw && isStarting(tab)
        if tab.exited || (!busy && !starting) || now >= deadline || controller(of: tab) == nil {
            return whenLineReported(tab, until: TerminalTab.now + 0.2) {
                var info: [String: Any] = ["id": tab.id.uuidString.lowercased(), "state": state(tab), "timed_out": busy || starting]
                info.merge(questionInfo(tab)) { $1 }
                info.merge(restoredFields(tab)) { $1 }
                info.merge(screenFields(tab, lines: 40)) { $1 }
                reply(ok(info))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitFor(tab, until: deadline, sawWork: saw, reply: reply) }
    }

    private static func editorSelection(caller: TerminalTab?) -> MCPServer.CallResult {
        let controller = caller.flatMap(controller(of:)) ?? (NSApp.keyWindow?.windowController as? TerminalWindowController)
            ?? app.controllers.last
        guard let editor = controller?.editorArea.activeEditor else { return ok(["file": NSNull()]) }
        let document = editor.document
        let range = editor.textView.selectedRange()
        let text = document.text as NSString
        func position(_ offset: Int) -> [String: Int] {
            let line = document.lines.line(at: offset)
            return ["line": line + 1, "column": offset - document.lines.range(ofLine: line).location + 1]
        }
        var info: [String: Any] = [
            "file": document.path,
            "language": document.language ?? "text",
            "unsaved": document.isDirty,
            "start": position(range.location),
            "end": position(NSMaxRange(range)),
        ]
        // Files that tend to hold secrets (.env, keys, credentials) never share their text, as read_file
        // and the editor links have it.
        let secret = MCPProjects.secretReason(document.path) ?? MCPProjects.secretReason(document.openedName)
        if secret != nil || document.holdsSecrets {
            if range.length > 0 { info["withheld"] = "The selection is in a file that usually holds secrets, so its text isn't shared." }
        } else if range.length > 0 {
            let selected = field(text.substring(with: range))
            info["text"] = selected.count > 200_000 ? String(selected.prefix(200_000)) + "\n… (cut at 200,000 characters)" : selected
        }
        return ok(info)
    }

    private static func openFiles() -> MCPServer.CallResult {
        let windows: [[String: Any]] = app.controllers.map { controller in
            let active = controller.editorArea.activeEditor?.document
            let preview = (controller.editorArea.previewPane as? CodeEditorView)?.document
            var window: [String: Any] = ["files": controller.editorArea.documents.map { document -> [String: Any] in
                var file: [String: Any] = ["path": document.path, "unsaved": document.isDirty, "front": document === active]
                if document === preview { file["preview"] = true } // the next file clicked in the sidebar replaces it
                return file
            }]
            if let project = controller.project { window["project"] = project }
            return window
        }
        return ok(["windows": windows])
    }

    // MARK: doing

    private static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func absolute(_ value: Any?) -> String? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        return path.hasPrefix("/") ? canonicalPath(path) : nil
    }

    private static func openProject(_ raw: String) -> MCPServer.CallResult {
        guard let path = absolute(raw), isFolder(path) else { return fail("Not a folder (give an absolute path): \(raw)") }
        let controller = app.openFolder(path, newWindow: false, forAgent: true)
        let shown = controller.presentForAgent(nil, explicit: true)
        var answer: [String: Any] = ["project": path, "tabs": controller.tabs.map { describe($0, in: controller, caller: nil) }]
        if let note = shown.note { answer["note"] = note }
        return ok(answer)
    }

    private static func newTab(_ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        guard let directory = absolute(arguments["directory"]), isFolder(directory) else {
            return reply(fail("Not a folder (give an absolute path): \(arguments["directory"] as? String ?? "")"))
        }
        let tab: TerminalTab
        let controller: TerminalWindowController
        if let besideID = arguments["split_beside"] {
            // A pane next to another tab, so the user can watch both.
            guard let beside = findTab(besideID), let owner = self.controller(of: beside) else {
                return reply(fail("No tab with that split_beside id; list_tabs shows them."))
            }
            let down = (arguments["direction"] as? String) == "down"
            guard let pane = owner.split(vertical: !down, from: beside, directory: directory, focus: false, byAgent: true) else {
                return reply(fail("Could not split that tab."))
            }
            controller = owner
            tab = pane
        } else {
            // The window of the project that holds the folder; else the folder's project, opened.
            let (owner, opened) = window(for: directory)
            controller = owner
            // Never a restored tab: it may hold a put-back line (KTD10). Never the tab of the window the user is in.
            if opened, controller.tabs.count == 1, let first = controller.tabs.first, first.remote == nil, first.isUntouched,
               canonicalPath(first.directory) == directory, !controller.hasUsersKeyboard {
                tab = first
                first.view.awaitsChoice = true
                if controller.window?.firstResponder === first.view { controller.window?.makeFirstResponder(nil) }
            } else {
                tab = controller.addTab(directory: directory, select: false, byAgent: true)
            }
        }
        // Its window comes forward (Settings › Editor › When an agent opens a tab); the tab waits for the user's click.
        // A pane beside another tab: its window, as the tab beside it is already there.
        let arrived = controller.presentForAgent(arguments["split_beside"] == nil ? tab : nil)
        driven.insert(tab.id)
        // An agent's worker: it opens no tabs of its own unless the user asks it to. A hand-off carries on the user's own
        // conversation (next-term-worktrees), so it is nobody's worker.
        if arguments["hand_off"] as? Bool != true { tab.openedBy = caller?.id }
        if let title = arguments["title"] as? String, !title.isEmpty { tab.userTitle = String(title.prefix(100)) }
        controller.refresh()
        let answer = {
            var info: [String: Any] = ["id": tab.id.uuidString.lowercased(), "directory": tab.directory,
                                       "project": (controller.project as Any?) ?? NSNull(), "selected": arrived.selected]
            if let note = arrived.note { info["note"] = note }
            reply(ok(info))
        }
        guard let command = arguments["command"] as? String, !command.trimmingCharacters(in: .whitespaces).isEmpty else { return answer() }
        guard !command.contains("\n") else { return reply(fail("The command must be one line.")) }
        let line = MCPServer.commandLine(command, prompt: arguments["prompt"] as? String)
        // Type it once the shell is at its first prompt (its integration reports in), or after 3 s.
        whenReady(tab, until: TerminalTab.now + 3) {
            type(line, into: tab, submit: true)
            answer()
        }
    }

    /// The window a new tab in `directory` opens in (new_tab's rule, which run_with_secrets shares): the window of the
    /// project that holds the folder, the deepest one; else the folder's project, opened (`opened` is then true); in a
    /// folder that is never a project (the home folder: ProjectRoot.project), the window with no project that has a tab
    /// there already, else a new one.
    static func window(for directory: String) -> (controller: TerminalWindowController, opened: Bool) {
        // A window that closed stays in `controllers` for a run-loop turn: never one to open a tab in.
        let owners = app.controllers.filter { !$0.hasClosed && ($0.project.map { directory == $0 || directory.hasPrefix($0 + "/") } ?? false) }
        if let owner = owners.max(by: { ($0.project?.count ?? 0) < ($1.project?.count ?? 0) }) {
            // A linked worktree inside the owner's folder (.claude/worktrees/x) gets its own window, as Open Worktree gives it.
            guard let worktree = owner.project.flatMap({ MCPServer.ownWorktree(of: directory, inside: $0) }) else { return (owner, false) }
            return (app.openFolder(worktree, newWindow: false, forAgent: true), true)
        }
        guard let project = ProjectRoot.project(from: directory) else {
            // A folder that is never a project (the home folder): the window with no project that has a tab there already
            // (one an earlier call opened) takes the tab, as a project's window does; else a new one.
            let folder: String = canonicalPath(directory)
            let plain: TerminalWindowController? = app.controllers.first { (controller: TerminalWindowController) -> Bool in
                guard !controller.hasClosed, controller.project == nil else { return false }
                return controller.tabs.contains { (tab: TerminalTab) -> Bool in tab.remote == nil && canonicalPath(tab.directory) == folder }
            }
            if let plain { return (plain, false) }
            return (app.openWindow(directory: directory, forAgent: true), true)
        }
        return (app.openFolder(project, newWindow: false, forAgent: true), true)
    }

    static func whenReady(_ tab: TerminalTab, until deadline: TimeInterval, _ body: @escaping () -> Void) {
        if tab.status.integrated || tab.remoteReady || TerminalTab.now >= deadline || tab.exited { return body() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { whenReady(tab, until: deadline, body) }
    }

    /// Types text as a paste (literal, never run early), then presses Return after a moment: agents
    /// take a paste in as a block and only treat a separate Return as "send". That Return is Next Term's own, so a zsh
    /// with the history hook keeps the line out of its history (TerminalTab.submitOwnLine).
    static func type(_ text: String, into tab: TerminalTab, submit: Bool) {
        guard canType(tab) else { return }
        // Text an earlier send_to_tab left with no Return, nothing written since, is the start of this line.
        let earlier = unsubmitted.removeValue(forKey: tab.id).flatMap { $0.writes == tab.view.inputWrites ? $0.typed : nil }
        let typed = (earlier ?? "") + tab.view.typeText(text)
        guard submit else {
            unsubmitted[tab.id] = (typed: typed, writes: tab.view.inputWrites)
            return
        }
        sent(to: tab)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard canType(tab) else { return } // the connection may have dropped in between
            tab.submitOwnLine(typed)
        }
    }

    /// Whether MCP may type into the tab right now. Checked before every key: a remote tab whose
    /// connection drops mid-sequence would otherwise take a Return as "reconnect", and the keys after it
    /// would go to ssh's new login (a password prompt).
    static func canType(_ tab: TerminalTab) -> Bool {
        !tab.exited && !tab.disconnected && tab.view.acceptsInput && (tab.remote == nil || tab.remoteConnected)
    }

    static func target(_ arguments: [String: Any], caller: TerminalTab?) -> Result<TerminalTab, MCPError> {
        guard let tab = findTab(arguments["tab_id"]) else { return .failure(MCPError("No tab with that id; list_tabs shows them.")) }
        if tab === caller { return .failure(MCPError("That is your own tab; type into another one.")) }
        if tab.disconnected { return .failure(MCPError("That tab lost its connection to its host; it reconnects by itself (tmux, herdr) or when someone presses Return in it.")) }
        // Until the host runs the tab's script, what is on screen is ssh asking the user (a password, a
        // host key): never answer that for them.
        if tab.remote != nil && !tab.remoteConnected {
            return .failure(MCPError("That remote tab is still connecting: ssh may be asking the user for a password or to confirm the host key. Wait, and try again once read_tab shows the host's prompt."))
        }
        if tab.exited || !tab.view.acceptsInput { return .failure(MCPError("That tab's shell has ended.")) }
        if let why = MCPInputLine.refusal(tab) { return .failure(MCPError(why)) }
        return .success(tab)
    }

    struct MCPError: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    private static func sendToTab(_ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        let tab: TerminalTab
        switch target(arguments, caller: caller) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let found): tab = found
        }
        let text = arguments["text"] as? String ?? ""
        let submit = arguments["submit"] as? Bool ?? true
        guard !text.isEmpty || submit else { return reply(fail("Nothing to type.")) }
        // By scalars: "\r\n" is one Character, and a lone "\r" is a Return too.
        let breaksLine: Bool = text.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
        if breaksLine && !tab.view.getTerminal().bracketedPasteMode {
            return reply(fail("The program in that tab takes one line at a time (no bracketed paste); send lines one by one."))
        }
        type(text, into: tab, submit: submit)
        if !submit {
            // An agent's text with no Return is its input too (type leaves it unmarked, as Next Term's own line for a
            // password manager's CLI is the user's): whatever later runs it, the tab stays driven until you type in it
            // yourself, its run_with_secrets grants end, and the command it starts is the agent's.
            SecretRequests.tabGotInput(tab.id)
            driven.insert(tab.id)
        }
        reply(ok(["id": tab.id.uuidString.lowercased(), "typed": text.count, "submitted": submit]))
    }

    private static func pressKeys(_ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        let tab: TerminalTab
        switch target(arguments, caller: caller) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let found): tab = found
        }
        let names = arguments["keys"] as? [String] ?? []
        guard !names.isEmpty, names.count <= 20 else { return reply(fail("Give 1 to 20 keys.")) }
        var sequences: [String] = []
        for name in names {
            guard let bytes = MCPServer.keyBytes(name) else { return reply(fail("Unknown key “\(name)”.")) }
            sequences.append(bytes)
        }
        // A gap between keys, so Escape then a key is not read as Alt+key.
        func press(_ index: Int) {
            guard index < sequences.count else {
                return reply(ok(["id": tab.id.uuidString.lowercased(), "pressed": names]))
            }
            guard canType(tab) else {
                return reply(fail("Stopped after \(index) of \(sequences.count) keys: the tab \(tab.disconnected ? "lost its connection" : "can no longer take input")."))
            }
            let next = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { press(index + 1) } }
            // A Return right after send_to_tab's text, with nothing written since, submits that line: the next key waits
            // for it, which can wait a moment for the shell's new line (TerminalTab.submitOwnLine).
            let pending = unsubmitted.removeValue(forKey: tab.id)
            if sequences[index] == "\r", let pending, pending.writes == tab.view.inputWrites {
                return tab.submitOwnLine(pending.typed) {
                    // The Return waited for the shell's new line: a tab that ended meanwhile never got it.
                    guard canType(tab) else {
                        return reply(fail("Stopped after \(index) of \(sequences.count) keys: the tab \(tab.disconnected ? "lost its connection" : "can no longer take input")."))
                    }
                    next()
                }
            }
            tab.view.send(txt: sequences[index])
            next()
        }
        sent(to: tab)
        press(0)
    }

    // MARK: answering

    /// The id of the question the tab's agent asks now (nil: none).
    static func questionID(_ tab: TerminalTab) -> String? {
        tab.status.question.map { AgentScreen.questionID(tab: tab.id.uuidString, serial: tab.status.questionSerial, question: $0) }
    }

    /// The question, its choices as the screen lists them, and the id answer_agent takes back.
    static func questionInfo(_ tab: TerminalTab) -> [String: Any] {
        guard let question = tab.status.question, let id = questionID(tab) else { return [:] }
        var info: [String: Any] = ["question": field(question), "question_id": id]
        if let menu = fieldMenu(tab, question: question) { info["choices"] = menu.choices.map(field) }
        return info
    }

    /// Picks one of the choices of the question on screen, if it is still the one the caller saw:
    /// the arrows to it, a look that the cursor landed there and the question is unchanged, then Return.
    /// A key that answers by itself (a digit, or Esc for the choice Esc picks) is sent once the question is seen unchanged.
    private static func answerAgent(_ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        let tab: TerminalTab
        switch target(arguments, caller: caller) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let found): tab = found
        }
        guard let given = arguments["question_id"] as? String, !given.isEmpty else {
            return reply(fail("Give question_id: the one that came with the question from list_tabs, read_tab or wait_for_tab."))
        }
        let choice = arguments["choice"], answer = arguments["answer"]
        if choice != nil && answer != nil { return reply(fail("Give choice or answer, not both.")) }
        if let choice, MCPServer.isBoolean(choice) || !(choice is Int) { return reply(fail("choice must be a whole number.")) }
        if let answer, !(answer is String) { return reply(fail("answer must be text.")) }
        tab.pollAgentScreen() // what the screen shows now, not at the last look
        guard let question = tab.status.question, let current = questionID(tab) else {
            return reply(fail("That tab is not asking anything now (state: \(state(tab))); nothing was typed. read_tab shows its screen."))
        }
        guard given == current else {
            return reply(fail("That question is gone; nothing was typed. The tab now asks “\(field(question))” (question_id \(current)): answer that one only if you mean to."))
        }
        guard let menu = fieldMenu(tab, question: question) else {
            if let why = tab.menuRefusal() { return reply(fail(field(why))) }
            return reply(fail("The choices for “\(field(question))” cannot be read on that screen; nothing was typed. read_tab shows it, and press_keys can answer."))
        }
        let index: Int
        switch menu.index(choice: choice as? Int, answer: answer as? String) {
        case .failure(let error): return reply(fail(error.text + " Nothing was typed."))
        case .success(let found): index = found
        }
        guard let keys = menu.keys(toPick: index) else { return reply(fail(field(menu.refusal(toPick: index)))) }
        let alone = keys.count == 1 && keys[0] != "enter"
        let last = keys[keys.count - 1]
        let id = tab.id.uuidString.lowercased()
        let label = field(menu.choices[index])
        // The question this answer is for: OpenCode 2.x's arrows onto "Always allow" change its words (and so its id),
        // the request the same (AgentScreen.selectionMoved).
        var expected = current
        // Still the same question, and (in a list, or a row of buttons) the cursor on the choice; for an Esc that first
        // shrank a fullscreen prompt, the prompt shown shrunk, so the next Esc picks.
        func ready() -> Bool {
            tab.pollAgentScreen()
            guard canType(tab), let now = questionID(tab) else { return false }
            if now != expected, menu.style == .row, !alone, let asked = tab.status.question,
               AgentScreen.selectionMoved(from: question, to: asked) { expected = now }
            guard now == expected else { return false }
            guard menu.style == .list || menu.style == .row, !alone else { return true }
            if last == "escape" { return tab.agentMenu()?.keys(toPick: index) == ["escape"] }
            return tab.agentMenu()?.highlighted == index
        }
        func confirm(_ tries: Int) {
            if ready(), let bytes = MCPServer.keyBytes(last) {
                sent(to: tab)
                tab.view.send(txt: bytes)
                return settle(0)
            }
            // A y/n prompt that took the letter by itself has its answer already.
            if menu.style == .yesNo, questionID(tab) != expected { return settle(15) }
            if tries < 10, canType(tab), questionID(tab) == expected {
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { confirm(tries + 1) }
            }
            if last == "escape" {
                let why = questionID(tab) == expected ? "the prompt still shows fullscreen" : "the question changed meanwhile"
                return reply(fail("Esc was pressed once, which only shrinks the fullscreen prompt, and not again: \(why). read_tab shows the screen."))
            }
            let why = questionID(tab) == expected ? "the cursor did not reach “\(label)”" : "the question changed meanwhile"
            reply(fail("Return was not pressed: \(why). read_tab shows the screen."))
        }
        // The agent takes the answer and moves on: report where it went (a new question, or work).
        func settle(_ tries: Int) {
            tab.pollAgentScreen()
            if tries < 15, questionID(tab) == expected {
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settle(tries + 1) }
            }
            var info: [String: Any] = ["id": id, "answered": label, "choice": index + 1, "state_after": state(tab)]
            if let after = questionID(tab) {
                if after == expected {
                    info["note"] = "The question is still on screen; read_tab shows what the agent did with the answer."
                } else {
                    info["question_after"] = tab.status.question.map(field)
                    info["question_id_after"] = after
                }
            }
            reply(ok(info))
        }
        // Gaps between keys, as press_keys has.
        func press(_ position: Int) {
            guard position < keys.count - 1 else {
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { confirm(0) }
            }
            guard canType(tab), let bytes = MCPServer.keyBytes(keys[position]) else {
                return reply(fail("Stopped before answering: the tab can no longer take input."))
            }
            tab.view.send(txt: bytes)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { press(position + 1) }
        }
        // The key alone answers: no Return after it, which would land on whatever the agent shows next.
        func answerAlone() {
            guard ready(), let bytes = MCPServer.keyBytes(keys[0]) else {
                return reply(fail("Nothing was typed: the question changed meanwhile, or the tab can no longer take input. read_tab shows the screen."))
            }
            sent(to: tab)
            tab.view.send(txt: bytes)
            settle(0)
        }
        if alone { answerAlone() } else { press(0) }
    }

    // MARK: project files and git

    private static let git = GitRunner.locateGit()

    /// read_file, find_in_files, git_status and get_diff: they read the disk and run git, so they run
    /// off the main thread, within the projects open now.
    private static func projectTool(_ tool: String, _ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        let preferred = caller.flatMap(controller(of:))?.project
        let projects = MCPProjects(open: app.controllers.compactMap(\.project), preferred: preferred)
        let git = Self.git
        DispatchQueue.global(qos: .userInitiated).async {
            switch tool {
            case "read_file": reply(MCPProjectTools.readFile(arguments, in: projects))
            case "find_in_files": reply(MCPProjectTools.findInFiles(arguments, in: projects, git: git))
            case "git_status": reply(MCPProjectTools.gitStatus(arguments, in: projects, git: git))
            default: reply(MCPProjectTools.getDiff(arguments, in: projects, git: git))
            }
        }
    }

    /// Shows a tab as one an agent opened does (AgentArrival): selected and its window forward, never with the keyboard,
    /// never over the tab the user is working in, nor over another app.
    private static func showTab(_ tab: TerminalTab) -> MCPServer.CallResult {
        guard let controller = controller(of: tab) else { return fail("That tab is gone.") }
        let shown = controller.presentForAgent(tab, explicit: true)
        var answer: [String: Any] = ["id": tab.id.uuidString.lowercased(), "shown": shown.selected, "keyboard": false]
        if let note = shown.note { answer["note"] = note }
        return ok(answer)
    }

    private static func closeTab(_ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        guard let tab = findTab(arguments["tab_id"]), let controller = controller(of: tab) else {
            return reply(fail("No tab with that id; list_tabs shows them."))
        }
        if tab === caller { return reply(fail("That is your own tab.")) }
        // Closing would lose text someone else put on its line, force or not.
        if let why = MCPInputLine.refusal(tab) { return reply(fail(why)) }
        let force = arguments["force"] as? Bool ?? false
        let id = tab.id.uuidString.lowercased()
        // The window's last tab, with files unsaved in its editor (or a database value): closing it closes the
        // window, so the user is asked first, and the answer says so without waiting for theirs.
        func close(_ info: [String: Any]) -> MCPServer.CallResult {
            let asks = controller.asksToSave(closing: tab)
            controller.remove(tab)
            guard asks else {
                lastSent.removeValue(forKey: tab.id)
                return ok(info)
            }
            var answer: [String: Any] = ["id": id, "closed": false, "asking_user": "It is the last tab in its window and the editor there has unsaved files (or a database value not saved yet), so closing it closes the window: Next Term asks the user first. The tab closes if they let it (Save, Don't Save or Close Anyway); list_tabs shows whether it did."]
            // Done already, whatever the user answers: force ended the tmux session, and what ran in it.
            if let ended = info["session_ended"] {
                answer["session_ended"] = ended
                answer["note"] = "The tmux session has ended already, whatever the user answers."
            }
            return ok(answer)
        }
        // A tab kept on its host: closing only detaches, and what runs there goes on.
        if let remote = tab.remote, tab.isKept {
            if remote.keep == .herdr {
                return reply(close(["id": id, "closed": true, "detached": true, "host": remote.host.name,
                                    "note": "herdr keeps its agents running on the host; stop them in herdr. A new herdr tab shows them again."]))
            }
            guard force else {
                let program = tab.status.running ? tab.status.program : nil
                var info: [String: Any] = ["id": id, "closed": true, "detached": true, "host": remote.host.name, "session": remote.session]
                if let program { info["still_running"] = program }
                info["note"] = "The tmux session keeps running on the host: reattach with new_remote_tab (session), or end it with close_tab force."
                return reply(close(info))
            }
            // force: end the tmux session first; the tab closes only once it has ended.
            RemoteConnection.endSession(remote.host, session: remote.session) { problem in
                if let problem {
                    return reply(fail("Could not end tmux session \(remote.session) on \(remote.host.name), so the tab stays open: \(problem)"))
                }
                reply(close(["id": id, "closed": true, "session_ended": remote.session]))
            }
            return
        }
        if let warning = tab.closeWarning, !force {
            return reply(fail("The tab is running \(warning); pass force: true to stop it and close the tab."))
        }
        reply(close(["id": id, "closed": true]))
    }

    private static func openInEditor(_ arguments: [String: Any]) -> MCPServer.CallResult {
        guard let path = absolute(arguments["path"]), isRegularFile(path) else {
            return fail("Not a file (give an absolute path): \(arguments["path"] as? String ?? "")")
        }
        let line = (arguments["line"] as? Int).map { max(1, $0) }
        let column = max(1, arguments["column"] as? Int ?? 1)
        app.openFile(path, line: line, column: column, newWindow: false, forAgent: true)
        return ok(["path": path, "opened": true])
    }
}

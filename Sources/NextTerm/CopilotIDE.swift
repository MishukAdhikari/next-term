import AppKit
import Network
import NextTermCore
import Security

/// GitHub Copilot CLI's IDE link, so `copilot` in a Next Term tab sees the editor the way it sees VS Code:
/// the selected lines go with your next prompt (the file the caret is in when nothing is selected), ⌥⌘K
/// puts `@file:10-20` straight into its prompt, and its proposed edits open as a diff to accept or reject,
/// as Claude's do.
///
/// How it connects (Copilot CLI 1.0.x, the protocol of VS Code's own Copilot extension): a lock file
/// `~/.copilot/ide/<uuid>.lock` names a Unix socket and the header to send; the CLI connects when it starts
/// in one of the lock's folders (the open projects and every tab's folder, kept current, but never your
/// home folder or /), and speaks MCP over Streamable HTTP on that socket. Copilot has nothing like
/// CLAUDE_CODE_SSE_PORT, so in a folder that VS Code also has open it may connect there instead (`/ide` in
/// Copilot switches), and one started in another terminal may connect here: it then sees the window that
/// has its folder open, and nothing when none does.
///
/// Security: no network port. The socket is in a new folder each launch that only you can enter (0700),
/// and every request must carry a fresh 256-bit nonce, compared in constant time; requests with `Origin`
/// (a browser) are refused. The lock is 0600 in a 0700 folder, is removed on quit, and does not call any
/// folder trusted, so Copilot still asks its own trust question. Nothing a client sends writes files: this
/// end reports the selection, and shows proposed edits for you to accept or reject (the CLI writes the file
/// itself, after an accept).
final class CopilotIDEServer: @unchecked Sendable { // mutable state lives on `queue`
    typealias SessionID = String

    static let shared = CopilotIDEServer()

    /// A connected CLI: its process (its X-Copilot-PID header) and its event stream once open.
    private struct Session {
        var pid: pid_t?
        var stream: NWConnection?
        /// The last selection it was sent, for get_selection; not current once the editor moved to a file
        /// that is not shared.
        var selection: [String: Any]?
        var current = false
    }

    /// One HTTP connection: what it sent that is not answered yet, and whether it waits (on a proposal you
    /// have not decided, or as an event stream).
    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        var busy = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    /// An open_diff waiting for your decision.
    private struct Pending {
        let session: SessionID
        let client: ObjectIdentifier
        let id: Any
        let path: String
        let tabName: String
    }

    let nonce: String
    private let queue = DispatchQueue(label: "nextterm.copilot-ide")
    private var listener: NWListener?
    /// The socket, in a folder of its own.
    private var socketPath: String?
    private var lockFolder: URL?
    private var lock: URL?
    private let lockName = UUID().uuidString.lowercased() + ".lock"
    private let launched = Int(Date().timeIntervalSince1970 * 1000)
    private var workspaces: [String] = []
    private var clients: [ObjectIdentifier: Client] = [:]
    private var sessions: [SessionID: Session] = [:]
    /// Proposals by tag (each open_diff has its own, so a closed tab never answers a newer one).
    private var pending: [String: Pending] = [:]
    private var proposals = 0
    private var heartbeat: DispatchSourceTimer?

    /// Called on the main queue when a CLI's event stream opens (with its pid, when it said).
    var onClientReady: ((SessionID, pid_t?) -> Void)?
    var onClientGone: ((SessionID) -> Void)?
    /// open_diff: show the proposed text for a file; answer with `resolveDiff`.
    var onOpenDiff: ((SessionID, _ path: String, _ proposed: String, _ tag: String) -> Void)?
    /// close_diff, or the CLI went away: close these proposals.
    var onCloseDiffs: ((_ tags: [String]) -> Void)?

    private init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        nonce = bytes.map { String(format: "%02x", $0) }.joined()
    }

    var isRunning: Bool { queue.sync { socketPath != nil } }

    // MARK: lifecycle

    /// Starts listening (waits up to a second, so a `copilot` started right away finds it). `lockFolder`:
    /// where the lock goes instead of Copilot's own folder (the self-test's).
    func start(workspaces: [String], lockFolder: URL? = nil) {
        guard listener == nil else { return }
        let folder = lockFolder ?? CopilotIDE.lockFolder()
        Self.removeStaleLocks(in: folder)
        // A new folder only you can enter (mkdtemp makes it 0700), so only you can reach the socket.
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("nextterm-copilot-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { return }
        let socketFolder = String(cString: template)
        let path = socketFolder + "/mcp.sock"
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        guard path.utf8.count < 104, let listener = try? NWListener(using: parameters) else {
            rmdir(socketFolder)
            return
        }
        self.lockFolder = folder
        self.workspaces = workspaces
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [unowned self] state in
            switch state {
            case .ready:
                socketPath = path
                writeLock()
                ready.signal()
            case .failed(let error):
                NSLog("Next Term: Copilot IDE link stopped: \(error)")
                stopOnQueue()
                rmdir(socketFolder)
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [unowned self] connection in accept(connection) }
        self.listener = listener
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 1)
        // Event streams get a comment every 30 s, so a CLI that went away is noticed.
        queue.sync {
            guard self.listener != nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 30, repeating: 30)
            timer.setEventHandler { [weak self] in self?.keepStreamsAlive() }
            timer.resume()
            heartbeat = timer
        }
    }

    func stop() {
        queue.sync { stopOnQueue() }
    }

    private func stopOnQueue() {
        heartbeat?.cancel()
        heartbeat = nil
        listener?.cancel()
        listener = nil
        clients.values.forEach { $0.connection.cancel() }
        clients = [:]
        sessions = [:]
        pending = [:]
        if let socketPath {
            unlink(socketPath)
            rmdir((socketPath as NSString).deletingLastPathComponent)
        }
        socketPath = nil
        if let lock { try? FileManager.default.removeItem(at: lock) }
        lock = nil
    }

    /// The folders `copilot` connects from. The lock is rewritten only when they change.
    func updateWorkspaces(_ folders: [String]) {
        queue.async {
            guard self.socketPath != nil, folders != self.workspaces else { return }
            self.workspaces = folders
            self.writeLock()
        }
    }

    // MARK: lock file

    private func writeLock() {
        guard let socketPath, let lockFolder else { return }
        // Copilot keeps its files in ~/.copilot: only when it is installed (never create that folder).
        guard FileManager.default.fileExists(atPath: lockFolder.deletingLastPathComponent().path) else { return }
        try? FileManager.default.createDirectory(at: lockFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let body = CopilotIDE.lock(socketPath: socketPath, nonce: nonce, pid: getpid(), workspaces: workspaces, timestamp: launched)
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes, .prettyPrinted]) else { return }
        let target = lockFolder.appendingPathComponent(lockName)
        if lock == target, Self.rewrite(target.path, with: data) { return }
        let temporary = lockFolder.appendingPathComponent(".\(lockName).\(getpid()).tmp") // must not end in .lock
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, target.path) == 0 else {
            unlink(temporary.path)
            return
        }
        lock = target
    }

    /// A connected `copilot` watches its lock (node's fs.watch) and drops the link when it sees a "rename":
    /// the file replaced, or a write that neither grows it nor changes its attributes. So an existing lock is
    /// rewritten in place, emptied first and then written from the start, which it sees as a "change" only.
    /// A read in between finds it empty or short, and the CLI reads a lock again when it cannot parse it.
    private static func rewrite(_ path: String, with data: Data) -> Bool {
        guard let handle = FileHandle(forWritingAtPath: path) else { return false }
        defer { try? handle.close() }
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    /// Our own locks left by a Next Term that did not quit cleanly. Other editors' locks are never touched.
    static func removeStaleLocks(in folder: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasSuffix(".lock") {
            let url = folder.appendingPathComponent(name)
            guard isRegularFile(url.path), let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["ideName"] as? String == "Next Term", let pid = json["pid"] as? Int else { continue }
            if kill(pid_t(pid), 0) != 0 && errno == ESRCH { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        let id = ObjectIdentifier(connection)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.closed(id)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    /// Always one read waiting, so a client that goes away is noticed even while its request waits.
    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { client.buffer.append(data) }
            if client.buffer.count > IDEHTTP.maximumBody + (64 << 10) { return client.connection.cancel() }
            if !client.busy { self.answerRequests(of: client) }
            if error != nil || (isComplete && client.busy) { return client.connection.cancel() }
            if isComplete {
                // Finished sending: close once the answers are out.
                return client.connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                              completion: .contentProcessed { _ in client.connection.cancel() })
            }
            self.receive(client)
        }
    }

    private func answerRequests(of client: Client) {
        while !client.busy {
            switch IDEHTTP.parse(client.buffer) {
            case .incomplete:
                return
            case .invalid:
                client.buffer = Data()
                return refuse(400, client)
            case let .request(request, rest):
                client.buffer = rest
                respond(to: request, from: client)
            }
        }
    }

    private func closed(_ id: ObjectIdentifier) {
        guard clients.removeValue(forKey: id) != nil else { return }
        // Its proposals: nobody waits for them any more.
        let tags = pending.filter { $0.value.client == id }.map(\.key)
        tags.forEach { pending.removeValue(forKey: $0) }
        if !tags.isEmpty { DispatchQueue.main.async { self.onCloseDiffs?(tags) } }
        // An event stream that ends: that CLI is gone.
        if let session = sessions.first(where: { $0.value.stream.map(ObjectIdentifier.init) == id })?.key { end(session) }
    }

    private func end(_ session: SessionID) {
        guard let ended = sessions.removeValue(forKey: session) else { return }
        ended.stream?.cancel()
        let tags = pending.filter { $0.value.session == session }.map(\.key)
        for tag in tags { resolveOnQueue(tag, accepted: false, trigger: "client_disconnected") }
        DispatchQueue.main.async {
            if !tags.isEmpty { self.onCloseDiffs?(tags) }
            self.onClientGone?(session)
        }
    }

    // MARK: HTTP

    private func respond(to request: IDEHTTP.Request, from client: Client) {
        // A browser page (it always sends Origin) or no nonce: refused. A browser cannot reach a Unix
        // socket at all; this is the same rule as the other links.
        guard request.header("origin") == nil else { return refuse(403, client) }
        guard CopilotIDE.isAuthorized(request.header("authorization"), nonce: nonce) else { return refuse(401, client) }
        let path = request.path.split(separator: "?").first.map(String.init) ?? ""
        guard path == "/mcp" || path == "/" else { return refuse(404, client) }
        switch request.method {
        case "POST": post(request, from: client)
        case "GET": openStream(request, from: client)
        case "DELETE":
            if let session = request.header("mcp-session-id") { end(session) }
            answer(200, client)
        default: refuse(405, client)
        }
    }

    private func post(_ request: IDEHTTP.Request, from client: Client) {
        guard let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else { return refuse(400, client) }
        guard let method = message["method"] as? String else { return answer(202, client) } // an answer to us: none asked
        var session = request.header("mcp-session-id")
        if method == "initialize" {
            let id = UUID().uuidString.lowercased()
            sessions[id] = Session(pid: request.header("x-copilot-pid").flatMap { pid_t($0) })
            session = id
        }
        guard let session else { return answer(400, client) }
        guard sessions[session] != nil else { return answer(404, client) } // the CLI starts a new session
        guard let id = message["id"] else { return answer(202, client) } // a notification
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = MCPServer.supportedVersions.contains(asked) ? asked : MCPServer.supportedVersions[0]
            reply(client, id, session: session, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "next-term", "title": "Next Term", "version": Self.appVersion],
            ])
        case "ping":
            reply(client, id, session: session, result: [:])
        case "tools/list":
            reply(client, id, session: session, result: ["tools": CopilotIDE.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            call(name, params["arguments"] as? [String: Any] ?? [:], id: id, session: session, client: client)
        default:
            reply(client, id, session: session, error: ["code": -32601, "message": "Method not found: \(method)"])
        }
    }

    /// GET: the event stream, for selection_changed and the @-mentions of ⌥⌘K.
    private func openStream(_ request: IDEHTTP.Request, from client: Client) {
        guard let session = request.header("mcp-session-id") else { return answer(400, client) }
        guard let previous = sessions[session] else { return answer(404, client) }
        client.busy = true
        sessions[session]?.stream = client.connection
        previous.stream?.cancel() // one stream per session (no longer its stream, so the session stays)
        write(IDEHTTP.streamHead(headers: [("Mcp-Session-Id", session)]), on: client.connection)
        DispatchQueue.main.async { self.onClientReady?(session, previous.pid) }
    }

    private func call(_ name: String, _ arguments: [String: Any], id: Any, session: SessionID, client: Client) {
        func done(_ result: [String: Any]) { reply(client, id, session: session, result: result) }
        switch name {
        case "open_diff":
            guard let diff = CopilotIDE.diffRequest(arguments) else { return done(CopilotIDE.errorResult("Invalid arguments")) }
            proposals += 1
            let tag = "copilot:\(proposals)"
            // No answer now: it goes when you decide (there is no time limit). The connection waits with it.
            client.busy = true
            pending[tag] = Pending(session: session, client: ObjectIdentifier(client.connection), id: id, path: diff.path, tabName: diff.tabName)
            DispatchQueue.main.async { self.onOpenDiff?(session, diff.path, diff.proposed, tag) }
        case "close_diff":
            // You answered in the terminal: the CLI closes its proposal.
            let tabName = arguments["tab_name"] as? String ?? ""
            let tags = pending.filter { $0.value.session == session && $0.value.tabName == tabName }.map(\.key)
            for tag in tags { resolveOnQueue(tag, accepted: false, trigger: "closed_via_tool") }
            if !tags.isEmpty { DispatchQueue.main.async { self.onCloseDiffs?(tags) } }
            done(CopilotIDE.closeDiffResult(tabName: tabName, wasOpen: !tags.isEmpty))
        case "get_selection":
            guard var selection = sessions[session]?.selection else { return done(CopilotIDE.textResult(NSNull())) }
            selection["current"] = sessions[session]?.current ?? false
            done(CopilotIDE.textResult(selection))
        case "get_diagnostics":
            done(CopilotIDE.textResult([Any]()))
        case "get_vscode_info":
            done(CopilotIDE.textResult(["appName": "Next Term", "version": Self.appVersion]))
        case "update_session_name":
            done(CopilotIDE.textResult(["success": true]))
        default:
            done(CopilotIDE.errorResult("Not available in Next Term: \(name)"))
        }
    }

    /// You accepted (the CLI writes its proposed text) or rejected a proposal.
    func resolveDiff(_ tag: String, accepted: Bool) {
        queue.async { self.resolveOnQueue(tag, accepted: accepted, trigger: nil) }
    }

    private func resolveOnQueue(_ tag: String, accepted: Bool, trigger: String?) {
        guard let waiting = pending.removeValue(forKey: tag), let client = clients[waiting.client] else { return }
        let result = CopilotIDE.diffResult(accepted: accepted, tabName: waiting.tabName, path: waiting.path, trigger: trigger)
        reply(client, waiting.id, session: waiting.session, result: result)
        client.busy = false
        answerRequests(of: client)
    }

    // MARK: sending

    /// The `copilot` processes connected now, with their pids (for the self-test and tab mapping).
    var connected: [(id: SessionID, pid: pid_t?, streaming: Bool)] {
        queue.sync { sessions.map { ($0.key, $0.value.pid, $0.value.stream != nil) } }
    }

    /// `selection_changed`, `add_selection` or `add_file_reference` to these sessions (nil: all).
    func notify(_ method: String, _ params: [String: Any], to targets: Set<SessionID>? = nil) {
        queue.async {
            guard let event = IDEHTTP.event(["jsonrpc": "2.0", "method": method, "params": params]) else { return }
            for (id, session) in self.sessions where targets?.contains(id) ?? true {
                guard let stream = session.stream else { continue }
                if method == "selection_changed" {
                    self.sessions[id]?.selection = params
                    self.sessions[id]?.current = true
                }
                self.write(IDEHTTP.chunk(event), on: stream)
            }
        }
    }

    /// The editor moved to something it does not share: get_selection says the last one is not current.
    func markStale(_ targets: Set<SessionID>) {
        queue.async { for id in targets { self.sessions[id]?.current = false } }
    }

    private func keepStreamsAlive() {
        for session in sessions.values {
            if let stream = session.stream { write(IDEHTTP.chunk(Data(": keepalive\n\n".utf8)), on: stream) }
        }
    }

    private func reply(_ client: Client, _ id: Any, session: SessionID, result: [String: Any]? = nil, error: [String: Any]? = nil) {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let result { message["result"] = result } else { message["error"] = error ?? [:] }
        let body = (try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes)) ?? Data()
        let headers = [("Content-Type", "application/json"), ("Mcp-Session-Id", session)]
        write(IDEHTTP.response(status: 200, headers: headers, body: body), on: client.connection)
    }

    /// An answer with no body; the connection stays open for the next request.
    private func answer(_ status: Int, _ client: Client) {
        write(IDEHTTP.response(status: status), on: client.connection)
    }

    /// Refused: say why, then close (once the answer has gone out).
    private func refuse(_ status: Int, _ client: Client) {
        client.busy = true
        let connection = client.connection
        connection.send(content: IDEHTTP.response(status: status, close: true), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func write(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// Which tab each connected `copilot` runs in, the folder of one started in another terminal, and the
/// folders last written to its lock (main thread).
enum CopilotLink {
    static var tabs: [CopilotIDEServer.SessionID: Weak<TerminalTab>] = [:]
    static var folders: [CopilotIDEServer.SessionID: String] = [:]
    static var folderKey: [String] = []
}

// MARK: the app's side

extension AppDelegate {
    /// GitHub Copilot CLI in a tab sees the editor's selection, and its proposed edits open as diffs.
    var shareWithCopilot: Bool {
        get { UserDefaults.standard.object(forKey: "shareWithCopilot") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "shareWithCopilot")
            if newValue {
                startCopilotLink()
            } else {
                CopilotIDEServer.shared.stop()
                CopilotLink.tabs = [:]
                CopilotLink.folders = [:]
            }
        }
    }

    func startCopilotLink() {
        let server = CopilotIDEServer.shared
        server.onClientReady = { [weak self] session, pid in
            guard let self else { return }
            if let pid, let tab = ClaudeIDEServer.tab(for: pid, among: self.controllers.flatMap(\.tabs)) {
                CopilotLink.tabs[session] = Weak(tab)
            } else if let pid, let folder = ProcessInspector.currentDirectory(of: pid) {
                // Started in another terminal: the folder it runs in decides which window it sees.
                CopilotLink.folders[session] = canonicalPath(folder)
            }
            // It starts with whatever the editor shows now.
            self.copilotWindow(for: session)?.shareSelectionWithCopilot(only: [session])
        }
        server.onClientGone = { session in
            CopilotLink.tabs.removeValue(forKey: session)
            CopilotLink.folders.removeValue(forKey: session)
        }
        // Copilot's proposed edits: shown as a diff in the window of the tab it runs in.
        server.onOpenDiff = { [weak self] session, path, proposed, tag in
            guard let self else { return }
            let controller = self.copilotWindow(for: session)
                ?? (NSApp.keyWindow?.windowController as? TerminalWindowController) ?? self.controllers.last
            guard let controller else { return CopilotIDEServer.shared.resolveDiff(tag, accepted: false) }
            let original = Self.textOnDisk(path)
            let proposal = DiffPane.Proposal(original: original, proposed: proposed, author: "Copilot", tag: tag, client: nil)
            controller.editorArea.openProposal(for: canonicalPath(path), proposal: proposal) { accepted, _ in
                CopilotIDEServer.shared.resolveDiff(tag, accepted: accepted)
            }
        }
        server.onCloseDiffs = { [weak self] tags in
            for controller in self?.controllers ?? [] {
                for pane in controller.editorArea.proposals where tags.contains(pane.proposal?.tag ?? "") {
                    controller.editorArea.close(pane)
                }
            }
        }
        CopilotLink.folderKey = copilotFolderKey
        server.start(workspaces: copilotFolders, lockFolder: SelfTest.isRequested ? SelfTest.copilotLockFolder : nil)
    }

    /// A file's text as saved ("" for a new file).
    private static func textOnDisk(_ path: String) -> String {
        guard isRegularFile(path), let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let (text, _) = TextFile.decode(data) else { return "" }
        return text
    }

    /// The folders `copilot` connects from, as it compares them with the folder it starts in: every
    /// window's (TerminalWindowController.copilotFolders).
    var copilotFolders: [String] {
        var seen = Set<String>()
        return controllers.flatMap(\.copilotFolders).filter { seen.insert($0).inserted }
    }

    /// What copilotFolders depends on, cheap to compare at every tab change.
    private var copilotFolderKey: [String] {
        var key = controllers.compactMap { $0.project ?? $0.sidebar.root?.path }
        for controller in controllers { key += controller.tabs.filter { $0.remote == nil }.map(\.directory) }
        return key
    }

    /// A tab changed folder, or a project opened or closed: keep Copilot's lock current.
    func updateCopilotFolders() {
        guard shareWithCopilot, copilotFolderKey != CopilotLink.folderKey else { return }
        CopilotLink.folderKey = copilotFolderKey
        CopilotIDEServer.shared.updateWorkspaces(copilotFolders)
    }

    /// The `copilot` sessions that see `controller` (copilotWindow).
    func copilotSessions(in controller: TerminalWindowController) -> Set<CopilotIDEServer.SessionID> {
        var result = Set<CopilotIDEServer.SessionID>()
        for session in CopilotIDEServer.shared.connected where session.streaming && copilotWindow(for: session.id) === controller {
            result.insert(session.id)
        }
        return result
    }

    /// The window a `copilot` sees: the one with its tab. One started in another terminal sees a window that
    /// has its folder open (the key window if several do), and no window at all when none does: it may have
    /// found Next Term from a folder that is open nowhere here, and is then sent nothing.
    func copilotWindow(for session: CopilotIDEServer.SessionID) -> TerminalWindowController? {
        if let tab = CopilotLink.tabs[session]?.value { return controllers.first { $0.tabs.contains { $0 === tab } } }
        guard let folder = CopilotLink.folders[session] else { return nil }
        let holding = controllers.filter { $0.holdsForCopilot(folder) }
        return holding.first { $0.window === NSApp.keyWindow } ?? holding.first
    }

    func copilotSession(for tab: TerminalTab) -> CopilotIDEServer.SessionID? {
        CopilotLink.tabs.first { $0.value.value === tab }?.key
    }
}

extension TerminalWindowController {
    /// The folders this window lists for `copilot` to connect from: the project, the sidebar's root, and each
    /// local tab's folder and its root. Your home folder and / are left out: Copilot connects by itself to an
    /// editor listing the folder it starts in, so every `copilot` started there in any terminal would come
    /// to Next Term.
    var copilotFolders: [String] {
        var folders: [String] = []
        if let project { folders.append(project) }
        if let root = sidebar.root?.path { folders.append(root) }
        for tab in tabs where tab.remote == nil {
            folders.append(ProjectRoot.find(from: tab.directory))
            folders.append(tab.directory)
        }
        let home = canonicalPath(FileManager.default.homeDirectoryForCurrentUser.path)
        return folders.map(canonicalPath).filter { $0 != home && $0 != "/" }
    }

    /// `folder` is one of this window's Copilot folders, or inside one.
    func holdsForCopilot(_ folder: String) -> Bool {
        copilotFolders.contains { folder == $0 || folder.hasPrefix($0 + "/") }
    }

    /// Tells the `copilot` sessions in this window's tabs what the editor shows: the selected lines, or the
    /// file the caret is in. A file that holds secrets, or none, is not sent: Copilot keeps the last one, and
    /// get_selection says it is no longer current.
    func shareSelectionWithCopilot(only sessions: Set<CopilotIDEServer.SessionID>? = nil) {
        guard AppDelegate.shared.shareWithCopilot else { return }
        let recipients = sessions ?? AppDelegate.shared.copilotSessions(in: self)
        guard !recipients.isEmpty else { return }
        if let selection = CopilotIDE.selection(fromClaude: currentSelectionForClaude()) {
            CopilotIDEServer.shared.notify("selection_changed", selection, to: recipients)
        } else {
            CopilotIDEServer.shared.markStale(recipients)
        }
    }

    /// ⌥⌘K into a connected `copilot`: the CLI puts `@file:10-20` into its prompt itself, as from VS Code.
    /// False when Copilot is not connected in that tab, or an item has more to say than a file and its
    /// lines (a folder, a note such as "deleted", unsaved code): that is typed instead.
    func sendToCopilot(_ items: [ContextItem], in tab: TerminalTab) -> Bool {
        guard let session = AppDelegate.shared.copilotSession(for: tab),
              items.allSatisfy({ !$0.isFolder && $0.code == nil && $0.note == nil }) else { return false }
        let references = items.compactMap { CopilotIDE.fileReference(path: canonicalPath($0.path), lines: $0.lines) }
        guard references.count == items.count else { return false }
        for reference in references { CopilotIDEServer.shared.notify(reference.method, reference.params, to: [session]) }
        return true
    }
}

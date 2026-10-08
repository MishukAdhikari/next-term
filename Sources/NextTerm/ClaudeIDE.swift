import AppKit
import Network
import NextTermCore
import Security

/// Claude Code's IDE link, so `claude` in a Next Term tab sees the editor the way it sees VS Code or a
/// JetBrains IDE: the selection travels with every prompt ("⧉ 10 lines selected"), and ⌥⌘K puts
/// `@file#L10-20` straight into its prompt.
///
/// How it connects (Claude Code 2.1.x): a WebSocket server on 127.0.0.1 speaking MCP JSON-RPC
/// (subprotocol "mcp"), announced by a lock file `~/.claude/ide/<port>.lock` holding a secret token
/// that the CLI sends back in `X-Claude-Code-Ide-Authorization`. Tabs get `CLAUDE_CODE_SSE_PORT`, which
/// makes `claude` connect to this server and no other. One server per app run serves every tab.
///
/// Security: loopback only; a fresh 256-bit token each launch, compared in constant time; any request
/// carrying `Origin` (a browser) is refused; the lock is 0600 in a 0700 folder and removed on quit.
/// Nothing a client sends can write files: this end reports the selection, and shows proposed edits
/// for the user to accept or reject (the CLI writes the file itself, after an accept).
///
/// opencode speaks this protocol too, but from a Next Term tab it connects without the token. Such a
/// connection is kept only when the process holding it is opencode running in one of this app's tabs
/// (IDEPeer), and then it only receives: the selection and @-mentions, no tools.
final class ClaudeIDEServer: @unchecked Sendable { // mutable state lives on `queue`
    typealias ClientID = ObjectIdentifier

    static let shared = ClaudeIDEServer()

    private struct Session {
        let connection: NWConnection
        var claudePid: pid_t?
        var ready = false
        var client = ""
        /// Came in without the token, and passed the peer check (opencode in a tab).
        var tokenless = false
        /// opencode, which never sends ide_connected (with or without the token).
        var opencode = false
    }

    let token: String
    private let queue = DispatchQueue(label: "nextterm.claude-ide")
    private var listener: NWListener?
    private var acceptedNonces = Set<String>()
    /// Handshakes without the token, waiting for the peer check.
    private var peerNonces = Set<String>()
    private var sessions: [ClientID: Session] = [:]
    /// The port once listening (read from any thread).
    private(set) var port: UInt16?
    private var lock: URL?
    /// Called on the main queue when a `claude` process is connected and listening (with its pid).
    var onClientReady: ((ClientID, pid_t?) -> Void)?
    var onClientGone: ((ClientID) -> Void)?
    /// openDiff: show the proposed text for a file; answer with `resolveDiff`.
    var onOpenDiff: ((ClientID, _ path: String, _ proposed: String, _ tabName: String) -> Void)?
    /// close_tab / closeAllDiffTabs: close these proposal tabs (undecided ones count as rejected).
    var onCloseDiffs: ((ClientID, _ tabNames: [String]) -> Void)?
    /// The shells of this app's local tabs (asked on the main queue), for the peer check.
    var tabShells: (() -> [pid_t])?
    /// tab_name -> the waiting openDiff call.
    private var pendingDiffs: [String: (client: ClientID, id: Any)] = [:]
    /// Proposal tabs each client has open.
    private var openDiffs: [ClientID: Set<String>] = [:]

    private init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    var isRunning: Bool { port != nil }

    // MARK: lifecycle

    /// Starts listening (waits up to a second for the port, so the first tab can already use it).
    func start(workspaces: [String]) {
        guard listener == nil else { return }
        Self.removeStaleLocks()
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 8 << 20
        websocket.setClientRequestHandler(queue) { [unowned self] protocols, headers in
            func header(_ name: String) -> [String] {
                headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
            }
            let auth = header("X-Claude-Code-Ide-Authorization")
            let offered = protocols.map { $0.trimmingCharacters(in: .whitespaces) }
            // Browsers always send Origin (CVE-2025-52882).
            guard header("Origin").isEmpty else { return .init(status: .reject, subprotocol: nil) }
            // opencode asks for no subprotocol, with the token or without it.
            let subprotocol = offered.contains("mcp") ? "mcp" : nil
            // A rejected handshake still reaches .ready: only connections bearing a nonce issued here count.
            let nonce = UUID().uuidString
            // No token at all, as opencode in a tab connects: kept only if the peer check passes (.ready).
            if auth.isEmpty {
                peerNonces.insert(nonce)
                return .init(status: .accept, subprotocol: subprotocol, additionalHeaders: [("X-Next-Term-Nonce", nonce)])
            }
            guard auth.count == 1, Self.constantTimeEqual(auth[0], token) else {
                return .init(status: .reject, subprotocol: nil)
            }
            acceptedNonces.insert(nonce)
            return .init(status: .accept, subprotocol: subprotocol, additionalHeaders: [("X-Next-Term-Nonce", nonce)])
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) // never "localhost": that binds all
        guard let listener = try? NWListener(using: parameters) else { return }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [unowned self] state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    self.port = port
                    self.writeLock(workspaces: workspaces)
                }
                ready.signal()
            case .failed(let error):
                NSLog("Next Term: Claude IDE link stopped: \(error)")
                self.stopOnQueue()
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [unowned self] connection in accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
        _ = ready.wait(timeout: .now() + 1)
    }

    func stop() {
        queue.sync { stopOnQueue() }
    }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        sessions.values.forEach { $0.connection.cancel() }
        sessions = [:]
        port = nil
        if let lock { try? FileManager.default.removeItem(at: lock) }
        lock = nil
    }

    /// The project folders, so a `claude` started in another terminal inside one of them can find us too.
    func updateWorkspaces(_ workspaces: [String]) {
        queue.async { if self.port != nil { self.writeLock(workspaces: workspaces) } }
    }

    // MARK: lock file

    static var lockFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/ide", isDirectory: true)
    }

    private func writeLock(workspaces: [String]) {
        guard let port else { return }
        let folder = Self.lockFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let body: [String: Any] = ["pid": Int(getpid()), "workspaceFolders": workspaces, "ideName": "Next Term",
                                   "transport": "ws", "runningInWindows": false, "authToken": token]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes]) else { return }
        let target = folder.appendingPathComponent("\(port).lock")
        let temporary = folder.appendingPathComponent(".\(port).\(getpid()).tmp") // must not end in .lock
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, target.path) == 0 else {
            unlink(temporary.path)
            return
        }
        lock = target
    }

    /// Our own locks left by a Next Term that did not quit cleanly. Other editors' locks are never touched.
    static func removeStaleLocks() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: lockFolder.path) else { return }
        for name in names where name.hasSuffix(".lock") {
            let url = lockFolder.appendingPathComponent(name)
            guard isRegularFile(url.path), let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["ideName"] as? String == "Next Term", let pid = json["pid"] as? Int else { continue }
            if kill(pid_t(pid), 0) != 0 && errno == ESRCH { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: environment for tabs

    /// Sets a tab's environment up for the link (other editors' leftovers are already gone: TerminalEnvironment).
    func prepare(_ env: inout [String: String]) {
        guard let port else { return }
        env["CLAUDE_CODE_SSE_PORT"] = String(port)
        env["ENABLE_IDE_INTEGRATION"] = "true"
        // A configured proxy would otherwise carry ws://127.0.0.1 off the machine.
        for key in ["NO_PROXY", "no_proxy"] {
            let existing = env[key].map { $0.isEmpty ? "" : $0 + "," } ?? ""
            env[key] = existing + "localhost,127.0.0.1,::1"
        }
    }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        let id = ClientID(connection)
        connection.stateUpdateHandler = { [unowned self] state in
            switch state {
            case .ready:
                let metadata = connection.metadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                let nonce = metadata?.additionalServerHeaders?.first { $0.0 == "X-Next-Term-Nonce" }?.1 ?? ""
                if peerNonces.remove(nonce) != nil { return checkPeer(connection) }
                guard acceptedNonces.remove(nonce) != nil else {
                    connection.cancel()
                    return
                }
                sessions[id] = Session(connection: connection)
                receive(connection)
            case .failed, .cancelled:
                if sessions.removeValue(forKey: id) != nil {
                    pendingDiffs = pendingDiffs.filter { $0.value.client != id }
                    let names = Array(openDiffs.removeValue(forKey: id) ?? [])
                    DispatchQueue.main.async {
                        self.onCloseDiffs?(id, names)
                        self.onClientGone?(id)
                    }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// A client without the token: kept only if the process holding its socket is opencode, running in one
    /// of this app's tabs (found by the socket's ports among the tabs' processes). Anything else is closed
    /// before a single message is read.
    private func checkPeer(_ connection: NWConnection) {
        guard let port, case let .hostPort(_, remote) = connection.endpoint else { return connection.cancel() }
        DispatchQueue.main.async {
            let shells = self.tabShells?() ?? []
            DispatchQueue.global(qos: .userInitiated).async {
                let pid = IDEPeer.opencode(clientPort: remote.rawValue, serverPort: port, under: shells)
                self.queue.async {
                    guard let pid, case .ready = connection.state else { return connection.cancel() }
                    self.sessions[ObjectIdentifier(connection)] = Session(connection: connection, claudePid: pid, tokenless: true)
                    self.receive(connection)
                }
            }
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return connection.cancel() }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close { return connection.cancel() }
            if metadata?.opcode == .text, let data { self.handle(data, from: connection) }
            self.receive(connection)
        }
    }

    private func handle(_ data: Data, from connection: NWConnection) {
        let client = ClientID(connection)
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        let tokenless = sessions[client]?.tokenless ?? false
        guard let id = message["id"] else {
            // Notifications get no reply.
            if method == "notifications/initialized", sessions[client]?.ready == false, tokenless || sessions[client]?.opencode == true {
                // opencode listens once it has said so. From a tab its pid is the one the peer check found;
                // started elsewhere (with the token) it has none, and follows the window in front.
                sessions[client]?.ready = true
                let pid = sessions[client]?.claudePid
                DispatchQueue.main.async { self.onClientReady?(client, pid) }
            }
            if method == "ide_connected", !tokenless {
                let pid = (params["pid"] as? NSNumber).map { pid_t($0.int32Value) }
                sessions[client]?.claudePid = pid
                // Claude listens a moment after saying it is connected; earlier notifications are lost.
                queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.sessions[client] != nil else { return }
                    self.sessions[client]?.ready = true
                    DispatchQueue.main.async { self.onClientReady?(client, pid) }
                }
            }
            return
        }
        switch method {
        case "initialize":
            let known = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            let asked = params["protocolVersion"] as? String ?? ""
            sessions[client]?.client = ((params["clientInfo"] as? [String: Any])?["version"] as? String).map { "claude-code " + $0 } ?? ""
            sessions[client]?.opencode = (params["clientInfo"] as? [String: Any])?["name"] as? String == "opencode"
            reply(connection, id, result: [
                "protocolVersion": known.contains(asked) ? asked : "2025-06-18",
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": ["name": "next-term", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
            ])
        case "ping":
            reply(connection, id, result: [:])
        case "tools/list":
            reply(connection, id, result: ["tools": tokenless ? [[String: Any]]() : Self.tools])
        case "tools/call":
            // Without the token a client only receives.
            if tokenless {
                return reply(connection, id, result: ["content": [["type": "text", "text": "Not available without the token"]], "isError": true])
            }
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            callTool(name, arguments, id: id, client: client, connection: connection)
        default:
            reply(connection, id, error: ["code": -32601, "message": "Method not found: \(method)"])
        }
    }

    // MARK: proposed edits

    static let tools: [[String: Any]] = [
        ["name": "openDiff", "description": "Show a proposed change to a file and wait for the user to accept or reject it",
         "inputSchema": ["type": "object", "required": ["old_file_path", "new_file_path", "new_file_contents", "tab_name"],
                         "properties": ["old_file_path": ["type": "string"], "new_file_path": ["type": "string"],
                                        "new_file_contents": ["type": "string"], "tab_name": ["type": "string"]]]],
        ["name": "close_tab", "description": "Close a proposed-change tab",
         "inputSchema": ["type": "object", "required": ["tab_name"], "properties": ["tab_name": ["type": "string"]]]],
        ["name": "closeAllDiffTabs", "description": "Close every proposed-change tab",
         "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ]

    private func callTool(_ name: String, _ arguments: [String: Any], id: Any, client: ClientID, connection: NWConnection) {
        switch name {
        case "openDiff":
            guard let path = arguments["new_file_path"] as? String ?? arguments["old_file_path"] as? String, path.hasPrefix("/"),
                  let proposed = arguments["new_file_contents"] as? String, let tab = arguments["tab_name"] as? String else {
                return reply(connection, id, error: ["code": -32602, "message": "Invalid params"])
            }
            // No reply now: it goes when the user decides (there is no time limit).
            pendingDiffs[tab] = (client, id)
            openDiffs[client, default: []].insert(tab)
            DispatchQueue.main.async { self.onOpenDiff?(client, path, proposed, tab) }
        case "close_tab":
            let tab = arguments["tab_name"] as? String ?? ""
            openDiffs[client]?.remove(tab)
            DispatchQueue.main.async { self.onCloseDiffs?(client, [tab]) }
            resolveOnQueue(tab, accepted: false, text: nil) // decided in the terminal: the CLI ignores this answer
            reply(connection, id, result: ["content": [["type": "text", "text": "TAB_CLOSED"]]])
        case "closeAllDiffTabs":
            let tabs = Array(openDiffs.removeValue(forKey: client) ?? [])
            DispatchQueue.main.async { self.onCloseDiffs?(client, tabs) }
            for tab in tabs { resolveOnQueue(tab, accepted: false, text: nil) }
            reply(connection, id, result: ["content": [["type": "text", "text": "CLOSED_\(tabs.count)_DIFF_TABS"]]])
        default:
            reply(connection, id, result: ["content": [["type": "text", "text": "Not available in Next Term: \(name)"]], "isError": true])
        }
    }

    /// The user accepted (the proposed text) or rejected a proposal.
    func resolveDiff(_ tabName: String, accepted: Bool, text: String?) {
        queue.async { self.resolveOnQueue(tabName, accepted: accepted, text: text) }
    }

    private func resolveOnQueue(_ tabName: String, accepted: Bool, text: String?) {
        guard let pending = pendingDiffs.removeValue(forKey: tabName), let session = sessions[pending.client] else { return }
        // FILE_SAVED must be followed by the text: the CLI reads the second item without checking.
        let content: [[String: Any]] = accepted
            ? [["type": "text", "text": "FILE_SAVED"], ["type": "text", "text": text ?? ""]]
            : [["type": "text", "text": "DIFF_REJECTED"]]
        reply(session.connection, pending.id, result: ["content": content])
    }

    // MARK: sending

    /// The `claude` processes connected now, with their pids (for the self-test and tab mapping).
    var clients: [(id: ClientID, pid: pid_t?, ready: Bool)] {
        queue.sync { sessions.map { ($0.key, $0.value.claudePid, $0.value.ready) } }
    }

    /// `selection_changed` / `at_mentioned` to these clients (nil: all ready clients).
    func notify(_ method: String, _ params: [String: Any], to clients: Set<ClientID>? = nil) {
        queue.async {
            for (id, session) in self.sessions where session.ready && (clients?.contains(id) ?? true) {
                self.send(["jsonrpc": "2.0", "method": method, "params": params], on: session.connection)
            }
        }
    }

    private func reply(_ connection: NWConnection, _ id: Any, result: [String: Any]? = nil, error: [String: Any]? = nil) {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let result { message["result"] = result } else { message["error"] = error ?? [:] }
        send(message, on: connection)
    }

    private func send(_ object: [String: Any], on connection: NWConnection) {
        guard let body = try? JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes) else { return }
        let context = NWConnection.ContentContext(identifier: "mcp", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: body, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: payloads

    /// What Claude gets for the editor's selection (lines 0-based, as in LSP). A caret alone says which
    /// file is open. Files that tend to hold secrets (.env) are never shared.
    static func selectionParams(path: String?, text: String, start: (line: Int, character: Int), end: (line: Int, character: Int)) -> [String: Any] {
        guard let path, !isSensitive(path) else {
            return ["selection": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 0], "isEmpty": true]]
        }
        return [
            "text": text,
            "filePath": path,
            "fileUrl": URL(fileURLWithPath: path).absoluteString,
            "selection": ["start": ["line": start.line, "character": start.character],
                          "end": ["line": end.line, "character": end.character], "isEmpty": text.isEmpty],
        ]
    }

    /// .env files (and *.env, .flaskenv), keys and credentials files; the list is IDELink's.
    static func isSensitive(_ path: String) -> Bool { IDELink.isSensitive(path) }

    /// Which tab a `claude` process runs in: walk its parents up to a tab's shell.
    static func tab(for pid: pid_t, among tabs: [TerminalTab]) -> TerminalTab? {
        var current = pid
        for _ in 0..<12 {
            if let tab = tabs.first(where: { $0.view.process.shellPid == current }) { return tab }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            let parent = info.kp_eproc.e_ppid
            if parent <= 1 { return nil }
            current = parent
        }
        return nil
    }
}

/// A weak reference, for maps that must not keep tabs alive.
struct Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

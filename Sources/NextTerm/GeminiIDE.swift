import AppKit
import Network
import NextTermCore
import Security

/// The IDE companion link of Gemini CLI and Qwen Code (the same protocol): `gemini` or `qwen` in a tab
/// knows which files are open in the editor, which one is active, where the caret is and what is
/// selected, with every prompt. They connect by themselves: Next Term keeps their IDE mode on (see
/// AgentIDESettings) while its own Settings switch is on.
///
/// MCP over Streamable HTTP at http://127.0.0.1:<port>/mcp with `Authorization: Bearer <token>`;
/// context goes out as `ide/contextUpdate` on the GET event stream. Discovery: a file in
/// `$TMPDIR/gemini/ide/` (Gemini) and `~/.qwen/ide/<port>.lock` (Qwen, when installed), naming Next Term in
/// `ideInfo` (that is what lets a non-VS Code editor in). Same rules as the Claude link: loopback only,
/// a fresh token per launch, requests with `Origin` refused, `Host` checked; nothing a client sends
/// writes files.
final class GeminiIDEServer: @unchecked Sendable { // mutable state lives on `queue`
    static let shared = GeminiIDEServer()

    let token: String
    private let queue = DispatchQueue(label: "nextterm.gemini-ide")
    private var listener: NWListener?
    private(set) var port: UInt16?
    private var files: [URL] = []
    /// Open event streams (GET /mcp), one per connected CLI.
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    private var sessions = Set<String>()
    /// The latest context, sent to each stream when it opens and whenever it changes.
    private var context: [String: Any] = ["openFiles": [[String: Any]]()]

    var isRunning: Bool { port != nil }
    var connectedCount: Int { queue.sync { streams.count } }

    private init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: lifecycle

    func start(workspaces: [String]) {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [unowned self] state in
            switch state {
            case .ready:
                port = listener.port?.rawValue
                writeDiscovery(workspaces: workspaces)
                ready.signal()
            case .failed:
                stopOnQueue()
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [unowned self] connection in
            connection.start(queue: queue)
            read(connection, buffer: Data())
        }
        listener.start(queue: queue)
        self.listener = listener
        _ = ready.wait(timeout: .now() + 1)
        let keepAlive = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.heartbeat() }
        RunLoop.main.add(keepAlive, forMode: .common)
    }

    func stop() { queue.sync { stopOnQueue() } }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        streams.values.forEach { $0.cancel() }
        streams = [:]
        port = nil
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        files = []
    }

    func updateWorkspaces(_ workspaces: [String]) {
        queue.async { if self.port != nil { self.writeDiscovery(workspaces: workspaces) } }
    }

    // MARK: discovery

    static var geminiFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gemini/ide", isDirectory: true)
    }

    static var qwenFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".qwen/ide", isDirectory: true)
    }

    private func writeDiscovery(workspaces: [String]) {
        guard let port else { return }
        let pid = Int(getpid())
        let ideInfo = ["name": "nextterm", "displayName": "Next Term"]
        let workspacePath = workspaces.joined(separator: ":")
        var written: [URL] = []
        let gemini = Self.geminiFolder.appendingPathComponent("gemini-ide-server-\(pid)-\(port).json")
        if Self.write(["port": Int(port), "workspacePath": workspacePath, "authToken": token, "ideInfo": ideInfo], to: gemini) {
            written.append(gemini)
        }
        // Qwen keeps its files in ~/.qwen: only when Qwen Code is installed (never create its folder).
        if FileManager.default.fileExists(atPath: Self.qwenFolder.deletingLastPathComponent().path) {
            let qwen = Self.qwenFolder.appendingPathComponent("\(port).lock")
            if Self.write(["port": Int(port), "workspacePath": workspacePath, "ppid": pid, "authToken": token,
                           "ideName": "Next Term", "ideInfo": ideInfo], to: qwen) {
                written.append(qwen)
            }
        }
        files = written
    }

    private static func write(_ body: [String: Any], to url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes]) else { return false }
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }

    // MARK: environment for tabs

    func prepare(_ env: inout [String: String], workspace: String) {
        guard let port else { return }
        env["GEMINI_CLI_IDE_PID"] = String(getpid())
        env["GEMINI_CLI_IDE_SERVER_PORT"] = String(port)
        env["GEMINI_CLI_IDE_AUTH_TOKEN"] = token
        env["GEMINI_CLI_IDE_WORKSPACE_PATH"] = workspace
        env["QWEN_CODE_IDE_SERVER_PORT"] = String(port)
        env["QWEN_CODE_IDE_WORKSPACE_PATH"] = workspace
    }

    // MARK: context

    /// The editor's state, as the CLIs want it: up to 10 recent files, the active one first with its
    /// caret and selection (1-based, selection at most 16 KB).
    func setContext(openFiles: [[String: Any]]) {
        queue.async {
            self.context = ["openFiles": openFiles]
            for stream in self.streams.values { self.push(["jsonrpc": "2.0", "method": "ide/contextUpdate", "params": ["workspaceState": self.context]], on: stream) }
        }
    }

    private func heartbeat() {
        queue.async { for stream in self.streams.values { self.write(Data(": keepalive\n\n".utf8), on: stream) } }
    }

    // MARK: HTTP

    private struct Request {
        var method = "", path = "", headers: [String: String] = [:], body = Data()
        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    /// Reads one HTTP/1.1 request at a time (keep-alive: then the next).
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 16 << 20 { return connection.cancel() }
            while let (request, rest) = Self.parse(buffer) {
                buffer = rest
                if !self.respond(to: request, on: connection) { return } // the connection became an event stream
            }
            if error != nil || isComplete { return connection.cancel() }
            self.read(connection, buffer: buffer)
        }
    }

    private static func parse(_ buffer: Data) -> (Request, Data)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var request = Request(method: String(first[0]), path: String(first[1]))
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            request.headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(request.header("content-length") ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return nil }
        request.body = buffer[bodyStart..<(bodyStart + length)]
        return (request, Data(buffer[(bodyStart + length)...]))
    }

    /// Answers a request. False when the connection is now an open event stream (no more requests on it).
    private func respond(to request: Request, on connection: NWConnection) -> Bool {
        guard let port else { return send(status: 503, on: connection) }
        // A browser page (Origin), a rebinding attack (Host), or no token: refused, as the companion does.
        guard request.header("origin") == nil else { return send(status: 403, on: connection) }
        guard let host = request.header("host"), host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return send(status: 403, on: connection)
        }
        guard let auth = request.header("authorization"), auth.hasPrefix("Bearer "),
              ClaudeIDEServer.constantTimeEqual(String(auth.dropFirst(7)), token) else { return send(status: 401, on: connection) }
        guard request.path.split(separator: "?").first == "/mcp" else { return send(status: 404, on: connection) }
        switch request.method {
        case "GET":
            // The event stream: context now, and whenever it changes.
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
            write(Data(head.utf8), on: connection)
            streams[ObjectIdentifier(connection)] = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.queue.async { self?.streams.removeValue(forKey: ObjectIdentifier(connection)) } }
                if case .failed = state { self?.queue.async { self?.streams.removeValue(forKey: ObjectIdentifier(connection)) } }
            }
            push(["jsonrpc": "2.0", "method": "ide/contextUpdate", "params": ["workspaceState": context]], on: connection)
            return false
        case "DELETE":
            if let session = request.header("mcp-session-id") { sessions.remove(session) }
            return send(status: 200, on: connection)
        case "POST":
            return handleRPC(request, on: connection)
        default:
            return send(status: 405, on: connection)
        }
    }

    private func handleRPC(_ request: Request, on connection: NWConnection) -> Bool {
        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let method = message["method"] as? String else { return send(status: 400, on: connection) }
        guard let id = message["id"] else { return send(status: 202, on: connection) } // a notification
        var headers: [String: String] = [:]
        var result: [String: Any]?
        var error: [String: Any]?
        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any] ?? [:]
            let known = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            let asked = params["protocolVersion"] as? String ?? ""
            let session = UUID().uuidString
            sessions.insert(session)
            headers["Mcp-Session-Id"] = session
            result = ["protocolVersion": known.contains(asked) ? asked : "2025-06-18",
                      "capabilities": ["tools": ["listChanged": false]],
                      "serverInfo": ["name": "next-term", "version": "1"]]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": [[String: Any]]()] // no diff tools yet: the CLIs then use their own prompt
        case "tools/call":
            result = ["content": [["type": "text", "text": "Not available in Next Term"]], "isError": true]
        default:
            error = ["code": -32601, "message": "Method not found: \(method)"]
        }
        var body: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let result { body["result"] = result } else { body["error"] = error ?? [:] }
        let data = (try? JSONSerialization.data(withJSONObject: body, options: .withoutEscapingSlashes)) ?? Data()
        headers["Content-Type"] = "application/json"
        return send(status: 200, headers: headers, body: data, on: connection)
    }

    @discardableResult
    private func send(status: Int, headers: [String: String] = [:], body: Data = Data(), on connection: NWConnection) -> Bool {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 503: "Service Unavailable"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        if status >= 400 {
            // Refused: say why, then close (only once the answer has gone out).
            head += "Connection: close\r\n"
            connection.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            return false
        }
        write(Data((head + "\r\n").utf8) + body, on: connection)
        return true
    }

    private func push(_ message: [String: Any], on connection: NWConnection) {
        guard let json = try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes),
              let line = String(data: json, encoding: .utf8) else { return }
        write(Data("event: message\ndata: \(line)\n\n".utf8), on: connection)
    }

    private func write(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

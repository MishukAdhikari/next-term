import AppKit
import Network
import NextTermCore

/// The IDE links beyond Claude Code's own client: GitHub Copilot CLI's (a stand-in CLI over the lock's Unix
/// socket) and opencode's (a stand-in run from a tab under opencode's name, with no token).
extension SelfTest {
    // MARK: Copilot CLI link

    static func copilotLinkChecks(_ c: TerminalWindowController, proj: URL, agentTab: TerminalTab) async {
        let server = CopilotIDEServer.shared
        guard server.isRunning else { return check(false, "the Copilot CLI link is listening") }
        // Found the way the CLI finds it: the one lock file in its folder.
        func lockJSON() -> [String: Any]? {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: copilotLockFolder.path))?.filter { $0.hasSuffix(".lock") } ?? []
            guard names.count == 1 else { return nil }
            let url = copilotLockFolder.appendingPathComponent(names[0])
            return (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        let tabFolder = canonicalPath(agentTab.directory)
        _ = await wait(3) { (lockJSON()?["workspaceFolders"] as? [String])?.contains(tabFolder) == true }
        guard let lock = lockJSON(), let socket = lock["socketPath"] as? String,
              let authorization = (lock["headers"] as? [String: String])?["Authorization"] else {
            return check(false, "Copilot CLI finds Next Term (its lock file)")
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: copilotLockFolder.path)) ?? []
        let lockPath = copilotLockFolder.appendingPathComponent(names.first { $0.hasSuffix(".lock") } ?? "").path
        let lockMode = (try? FileManager.default.attributesOfItem(atPath: lockPath))?[.posixPermissions] as? Int
        let socketFolder = (socket as NSString).deletingLastPathComponent
        let socketFolderMode = (try? FileManager.default.attributesOfItem(atPath: socketFolder))?[.posixPermissions] as? Int
        check(lockMode == 0o600 && lock["ideName"] as? String == "Next Term" && lock["scheme"] as? String == "unix"
              && authorization == "Nonce " + server.nonce, "Copilot CLI finds Next Term (lock file, private to you)")
        check(socketFolderMode == 0o700, "Copilot link: the socket is in a folder only you can enter", "\(String(describing: socketFolderMode))")
        check(lock["isTrusted"] as? Bool == false, "Copilot link: no folder is called trusted, so Copilot still asks its own question")
        check((lock["workspaceFolders"] as? [String])?.contains(tabFolder) == true,
              "copilot started in a tab's folder connects there (the folder is in the lock)")

        // Strangers are refused: no nonce, a wrong one, or a web page.
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"copilot-cli","version":"1.0.93"}}}"#
        let strangers: [(label: String, authorization: String?, extra: String, status: Int)] = [
            ("no nonce", nil, "", 401),
            ("a wrong nonce", "Nonce " + String(repeating: "0", count: 64), "", 401),
            ("a web page", authorization, "Origin: https://evil.example\r\n", 403),
        ]
        for stranger in strangers {
            let client = CopilotTestClient(socket: socket)
            client.send(CopilotTestClient.request(body: initialize, authorization: stranger.authorization, extra: stranger.extra))
            _ = await wait(2) { !client.responses.isEmpty }
            check(client.responses.first?.status == stranger.status && client.responses.first?.body.isEmpty == true,
                  "Copilot link: \(stranger.label) is refused (\(stranger.status))", String(client.text.prefix(40)))
            client.close()
        }

        // The CLI: the handshake, its body chunked as node sends it, with its pid; then the event stream.
        let cli = CopilotTestClient(socket: socket)
        defer { cli.close() }
        cli.send(CopilotTestClient.request(body: initialize, authorization: authorization, pid: agentTab.view.process.shellPid))
        _ = await wait(3) { cli.responses.count == 1 }
        let session = cli.responses.first?.headers["mcp-session-id"] ?? ""
        let version = (cli.json(0)?["result"] as? [String: Any])?["protocolVersion"] as? String
        check(!session.isEmpty && version == "2025-11-25", "Copilot CLI's handshake is answered, with a session", cli.text)
        func post(_ body: String) { cli.send(CopilotTestClient.request(body: body, authorization: authorization, session: session)) }
        post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        _ = await wait(2) { cli.responses.count == 2 }
        check(cli.responses.last?.status == 202, "its notifications are taken (202)")
        post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        _ = await wait(2) { cli.responses.count == 3 }
        let tools = ((cli.json(2)?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        check(tools.contains("open_diff") && tools.contains("close_diff") && tools.contains("get_selection"), "it gets the editor's tools", tools.joined(separator: ", "))
        let stream = CopilotTestClient(socket: socket)
        defer { stream.close() }
        stream.send(CopilotTestClient.request("GET", authorization: authorization, session: session))
        check(await wait(3) { stream.text.contains("Content-Type: text/event-stream") }, "its event stream opens")
        check(await wait(3) { AppDelegate.shared.copilotSession(for: agentTab) == session }, "the connected copilot is matched to the tab it runs in")

        // The editor's selection follows Copilot: lines 2–3 of main.php, 0-based, as Claude gets them.
        c.openFile(proj.appendingPathComponent("src/main.php"))
        if let editor = c.editorArea.activeEditor {
            let lines = editor.document.lines
            c.window?.makeFirstResponder(editor.textView)
            editor.textView.setSelectedRange(NSRange(location: lines.starts[1], length: lines.starts[3] - lines.starts[1]))
            let shared = await wait(3) {
                let selection = stream.last("selection_changed")?["selection"] as? [String: Any]
                let start = selection?["start"] as? [String: Any], end = selection?["end"] as? [String: Any]
                return start?["line"] as? Int == 1 && end?["line"] as? Int == 3
            }
            check(shared && stream.last("selection_changed")?["filePath"] as? String == editor.document.path,
                  "selecting lines in the editor tells Copilot CLI", "\(stream.last("selection_changed") ?? [:])")
            // get_selection, which Copilot's model can call: the same lines, current.
            post(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_selection","arguments":{}}}"#)
            _ = await wait(2) { cli.responses.count == 4 }
            let asked = cli.toolJSON(3)
            check(asked?["filePath"] as? String == editor.document.path && asked?["current"] as? Bool == true,
                  "get_selection answers with the same lines", "\(asked ?? [:])")
            // ⌥⌘K with Copilot connected: an @-mention it puts in its own prompt, nothing typed.
            let sent = c.sendToCopilot([ContextItem(path: editor.document.path, lines: 2...3)], in: agentTab)
            let mentioned = await wait(3) {
                let selection = stream.last("add_selection")?["selection"] as? [String: Any]
                return (selection?["start"] as? [String: Any])?["line"] as? Int == 1 && (selection?["end"] as? [String: Any])?["line"] as? Int == 2
            }
            check(sent && mentioned, "⌥⌘K sends the lines straight into Copilot's prompt (add_selection)", "\(stream.last("add_selection") ?? [:])")
            check(!c.sendToCopilot([ContextItem(path: proj.appendingPathComponent("src").path, isFolder: true)], in: agentTab),
                  "a folder is typed instead (a mention is a file and its lines)")
        }

        await copilotProposalChecks(c, proj: proj, socket: socket, authorization: authorization, session: session, cli: cli)

        // A .env file is never shared: no selection goes out, and get_selection says the last one is not current.
        let env = proj.appendingPathComponent(".env")
        try? "SECRET=1\n".write(to: env, atomically: true, encoding: .utf8)
        c.openFile(env)
        if let editor = c.editorArea.activeEditor, editor.document.name == ".env" {
            editor.textView.setSelectedRange(NSRange(location: 0, length: 6))
            await pause(0.6)
            check(!stream.events.contains { (($0["params"] as? [String: Any])?["filePath"] as? String)?.hasSuffix("/.env") == true },
                  "a selection in .env is never shared with Copilot")
            let before = cli.responses.count
            post(#"{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"get_selection","arguments":{}}}"#)
            _ = await wait(2) { cli.responses.count > before }
            check(cli.toolJSON(20)?["current"] as? Bool == false, "and get_selection says the file it knows is no longer the current one")
            c.editorArea.closeActive()
        }
        try? FileManager.default.removeItem(at: env)

        // The CLI leaves: its session ends and the tab forgets it.
        cli.send(CopilotTestClient.request("DELETE", authorization: authorization, session: session))
        check(await wait(3) { !server.connected.contains { $0.id == session } && AppDelegate.shared.copilotSession(for: agentTab) == nil },
              "when copilot leaves, its session ends")
    }

    /// Copilot's proposed edits: a diff to accept or reject, answered when you decide; Next Term never writes.
    private static func copilotProposalChecks(_ c: TerminalWindowController, proj: URL, socket: String, authorization: String,
                                              session: String, cli: CopilotTestClient) async {
        let target = proj.appendingPathComponent("src/main.php")
        let before = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        let proposed = before.replacingOccurrences(of: "Hello", with: "Hi")
        func copilotPane() -> DiffPane? { c.editorArea.proposals.first { $0.proposal?.author == "Copilot" } }
        /// open_diff on a connection of its own, as the CLI makes it: the answer waits for you.
        func openDiff(_ id: Int, _ tab: String) -> CopilotTestClient {
            let caller = CopilotTestClient(socket: socket)
            let call: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": [
                "name": "open_diff", "arguments": ["original_file_path": target.path, "new_file_contents": proposed, "tab_name": tab]]]
            let body = (try? JSONSerialization.data(withJSONObject: call)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            caller.send(CopilotTestClient.request(body: body, authorization: authorization, session: session))
            return caller
        }

        let first = openDiff(10, "[Copilot CLI] - main.php (a1b2c3)")
        if await wait(4, { copilotPane() != nil }), let pane = copilotPane() {
            check(await wait(4) { pane.hunkCount >= 1 } && pane.sideTexts.1.contains("Hi") && pane.title.hasSuffix("✻ Copilot"),
                  "Copilot's proposed edit opens as a diff to review", pane.title)
            check(first.responses.isEmpty, "and Copilot waits for your decision")
            pane.decide(true)
            c.editorArea.close(pane)
            check(await wait(3) { first.toolJSON(0)?["result"] as? String == "SAVED" }, "Accept tells Copilot to write it (SAVED)", first.text)
            check(((try? String(contentsOf: target, encoding: .utf8)) ?? "") == before, "Next Term itself never writes Copilot's file")
        } else {
            check(false, "Copilot's proposed edit opens as a diff to review")
        }
        first.close()

        // Closing the tab rejects.
        let second = openDiff(11, "second")
        if await wait(4, { copilotPane() != nil }), let pane = copilotPane() { c.editorArea.close(pane) }
        check(await wait(3) { second.toolJSON(0)?["result"] as? String == "REJECTED" }, "closing or rejecting it says REJECTED", second.text)
        second.close()

        // Answered in the terminal: the CLI closes the proposal (close_diff), and the waiting call says REJECTED.
        let third = openDiff(12, "third")
        _ = await wait(4) { copilotPane() != nil }
        let count = cli.responses.count
        cli.send(CopilotTestClient.request(body: #"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"close_diff","arguments":{"tab_name":"third"}}}"#,
                                           authorization: authorization, session: session))
        check(await wait(3) { copilotPane() == nil }, "when you answer in the terminal, Copilot closes the diff tab")
        _ = await wait(2) { cli.responses.count > count }
        check(cli.toolJSON(count)?["already_closed"] as? Bool == false && third.toolJSON(0)?["trigger"] as? String == "closed_via_tool",
              "and its waiting call is answered", third.text)
        third.close()

        // A copilot that goes away takes its proposal with it.
        let fourth = openDiff(14, "fourth")
        _ = await wait(4) { copilotPane() != nil }
        fourth.close()
        check(await wait(3) { copilotPane() == nil }, "a proposal closes when its copilot goes away")
    }

    // MARK: opencode, without the token

    /// opencode reads Claude's lock files but connects without the token from a Next Term tab. Its stand-in
    /// is this app's own binary under opencode's name, run in a tab; the same binary under another name is refused.
    static func opencodeLinkChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let port = ClaudeIDEServer.shared.port, let executable = Bundle.main.executablePath else {
            return check(false, "the Claude Code link is listening for opencode")
        }
        let dir = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-opencode-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["opencode", "impostor"] {
            let target = dir.appendingPathComponent(name).path
            // A clone shares the binary's blocks: no disk used.
            if clonefile(executable, target, 0) != 0 { try? FileManager.default.copyItem(atPath: executable, toPath: target) }
        }
        guard FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("impostor").path) else {
            return check(false, "the opencode stand-in is in place")
        }
        c.openFile(proj.appendingPathComponent("src/main.php"))
        guard let editor = c.editorArea.activeEditor else { return check(false, "an editor is open for opencode to see") }
        editor.textView.setSelectedRange(NSRange(location: 0, length: editor.document.lines.starts[min(1, editor.document.lines.count - 1)]))
        let tab = c.addTab(directory: dir.path)
        _ = await wait(20) { tab.status.integrated }
        func messages(_ name: String) -> [[String: Any]] {
            let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }

        tab.view.send(txt: "\u{15}./opencode --cli --self-test-ide-client \(port) opencode.jsonl\r")
        let seen = await wait(15) { messages("opencode.jsonl").contains { $0["method"] as? String == "selection_changed" } }
        let selection = messages("opencode.jsonl").last { $0["method"] as? String == "selection_changed" }?["params"] as? [String: Any]
        check(seen && selection?["filePath"] as? String == editor.document.path,
              "opencode in a tab connects without the token and sees the editor's selection", tab.screenTail(4).joined(separator: " | "))
        check(AppDelegate.shared.claudeClient(for: tab) != nil, "and it is matched to its tab (for ⌥⌘K)")
        let tool = messages("opencode.jsonl").first { $0["id"] as? Int == 2 }?["result"] as? [String: Any]
        check(tool?["isError"] as? Bool == true && c.editorArea.proposals.isEmpty, "without the token it gets no tools (no proposals)")
        _ = await wait(10) { !tab.status.running }

        // The very same client under another name, in the same tab: refused before a message.
        tab.view.send(txt: "\u{15}./impostor --cli --self-test-ide-client \(port) impostor.jsonl\r")
        _ = await wait(3) { tab.status.running }
        _ = await wait(12) { !tab.status.running }
        let ran = FileManager.default.fileExists(atPath: dir.appendingPathComponent("impostor.jsonl").path)
        check(ran && messages("impostor.jsonl").isEmpty, "any other client without the token gets nothing, even from a tab",
              "\(messages("impostor.jsonl").count) messages")
        c.requestClose(tab)
    }

    /// opencode's editor client, as the self-test's stand-in (`<copy named opencode> --cli
    /// --self-test-ide-client <port> <file>`, run in a tab): connects the way opencode does from a Next Term
    /// tab (no token, no subprotocol), asks for a tool it must not get, and writes every message it gets to
    /// <file>, one per line, for 6 seconds.
    nonisolated static func runIDEStandIn(port: String, output: String) -> Never {
        guard let port = UInt16(port) else { exit(2) }
        let client = ClaudeTestClient(port: port, token: nil, subprotocol: false)
        client.send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-11-25", "capabilities": [String: Any](), "clientInfo": ["name": "opencode", "version": "0.0.0"]]])
        func save() {
            let lines = client.received.compactMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) }
            try? Data(lines.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        var initialized = false
        let end = Date().addingTimeInterval(6)
        while Date() < end && !client.closed {
            usleep(200_000)
            if !initialized, client.received.contains(where: { $0["id"] as? Int == 1 }) {
                initialized = true
                client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
                client.send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "openDiff", "arguments": [
                    "old_file_path": "/tmp/x", "new_file_path": "/tmp/x", "new_file_contents": "x", "tab_name": "x"]]])
            }
            save()
        }
        save()
        client.close()
        exit(0)
    }
}

/// A stand-in for the `copilot` CLI's side of the link, for the self-test: HTTP over the lock's Unix socket,
/// bodies chunked as node sends them, and everything that comes back kept.
final class CopilotTestClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "selftest.copilot-client")
    private var buffer = Data()

    init(socket: String) {
        connection = NWConnection(to: .unix(path: socket), using: .tcp)
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if done || error != nil { return }
            self.receive()
        }
    }

    func send(_ text: String) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    func close() { connection.cancel() }

    var text: String { queue.sync { String(decoding: buffer, as: UTF8.self) } }

    /// A request as the CLI sends it: the lock's header, the session, its pid, a POST's body chunked.
    static func request(_ method: String = "POST", body: String = "", authorization: String?, session: String? = nil,
                        pid: pid_t? = nil, extra: String = "") -> String {
        var head = "\(method) /mcp HTTP/1.1\r\nHost: localhost\r\nAccept: application/json, text/event-stream\r\n"
        if let authorization { head += "Authorization: \(authorization)\r\n" }
        if let session { head += "Mcp-Session-Id: \(session)\r\n" }
        if let pid { head += "X-Copilot-PID: \(pid)\r\nX-Copilot-Parent-PID: \(getpid())\r\n" }
        head += extra
        guard method == "POST" else { return head + "\r\n" }
        let size = String(Data(body.utf8).count, radix: 16)
        return head + "Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n" + size + "\r\n" + body + "\r\n0\r\n\r\n"
    }

    /// The answers so far, in order (an event stream ends the list: its body has no end).
    var responses: [(status: Int, headers: [String: String], body: Data)] {
        let data = queue.sync { buffer }
        var result: [(status: Int, headers: [String: String], body: Data)] = []
        var position = 0
        let headEnd = Data("\r\n\r\n".utf8)
        while let end = data.range(of: headEnd, in: position..<data.count) {
            let head = String(decoding: data[position..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let status = head.first.flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Int($0) } ?? 0
            var headers: [String: String] = [:]
            for line in head.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            if headers["transfer-encoding"] != nil {
                result.append((status, headers, Data()))
                break
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard data.count - end.upperBound >= length else { break }
            result.append((status, headers, Data(data[end.upperBound..<(end.upperBound + length)])))
            position = end.upperBound + length
        }
        return result
    }

    /// The JSON-RPC message in answer `index`.
    func json(_ index: Int) -> [String: Any]? {
        let all = responses
        guard all.indices.contains(index) else { return nil }
        return (try? JSONSerialization.jsonObject(with: all[index].body)) as? [String: Any]
    }

    /// A tool's answer in answer `index`: the JSON its text holds.
    func toolJSON(_ index: Int) -> [String: Any]? {
        let content = (json(index)?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// The messages that came on the event stream.
    var events: [[String: Any]] {
        text.components(separatedBy: "\n").filter { $0.hasPrefix("data: ") }.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8))) as? [String: Any]
        }
    }

    func last(_ method: String) -> [String: Any]? {
        events.last { $0["method"] as? String == method }?["params"] as? [String: Any]
    }
}

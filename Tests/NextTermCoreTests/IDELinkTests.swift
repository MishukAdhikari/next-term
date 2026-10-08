import Darwin
import Foundation
import Testing
@testable import NextTermCore

@Suite struct IDEHTTPTests {
    func whole(_ parsed: IDEHTTP.Parsed) -> (IDEHTTP.Request, Data)? {
        if case let .request(request, rest) = parsed { return (request, rest) }
        return nil
    }

    @Test func readsABodyWithALength() throws {
        let text = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nAuthorization: Nonce abc\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
        let (request, rest) = try #require(whole(IDEHTTP.parse(Data(text.utf8))))
        #expect(request.method == "POST" && request.path == "/mcp")
        #expect(request.header("authorization") == "Nonce abc" && request.header("AUTHORIZATION") == "Nonce abc")
        #expect(String(data: request.body, encoding: .utf8) == "{\"a\":1}")
        #expect(rest.isEmpty)
    }

    /// How the Copilot CLI sends every request: node's http client chunks a body given no length.
    @Test func readsAChunkedBody() throws {
        let text = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\nMcp-Session-Id: s1\r\n\r\n"
            + "4\r\n{\"a\"\r\n3;name=x\r\n:1}\r\n0\r\n\r\n"
        let (request, rest) = try #require(whole(IDEHTTP.parse(Data(text.utf8))))
        #expect(String(data: request.body, encoding: .utf8) == "{\"a\":1}")
        #expect(request.header("mcp-session-id") == "s1")
        #expect(rest.isEmpty)
        // Trailers after the last chunk are skipped.
        let trailed = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n0\r\nX-Trailer: 1\r\n\r\n"
        #expect(try #require(whole(IDEHTTP.parse(Data(trailed.utf8)))).0.body == Data("hi".utf8))
    }

    @Test func waitsForTheWholeRequest() {
        let whole = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
        let bytes = Array(whole.utf8)
        for cut in [10, 40, 50, 53, bytes.count - 1] {
            #expect(IDEHTTP.parse(Data(bytes[0..<cut])) == .incomplete, "cut at \(cut)")
        }
        let length = "POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345"
        #expect(IDEHTTP.parse(Data(length.utf8)) == .incomplete)
    }

    @Test func keepsTheNextRequest() throws {
        let two = "GET /mcp HTTP/1.1\r\nHost: localhost\r\n\r\nDELETE /mcp HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        let (first, rest) = try #require(whole(IDEHTTP.parse(Data(two.utf8))))
        #expect(first.method == "GET" && first.body.isEmpty)
        let (second, end) = try #require(whole(IDEHTTP.parse(rest)))
        #expect(second.method == "DELETE" && end.isEmpty)
        // A slice of a larger buffer (indices not from 0) reads the same.
        let sliced = Data(("xx" + two).utf8).dropFirst(2)
        #expect(try #require(whole(IDEHTTP.parse(sliced))).0.method == "GET")
    }

    @Test func refusesWhatIsNotHTTPOrTooLarge() {
        #expect(IDEHTTP.parse(Data("hello there\r\n\r\n".utf8)) == .invalid)
        #expect(IDEHTTP.parse(Data("POST /mcp HTTP/1.1\r\nno colon\r\n\r\n".utf8)) == .invalid)
        #expect(IDEHTTP.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)) == .invalid)
        #expect(IDEHTTP.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n".utf8)) == .invalid)
        // A chunk that does not end where its size says.
        #expect(IDEHTTP.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhello\r\n0\r\n\r\n".utf8)) == .invalid)
        #expect(IDEHTTP.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 100\r\n\r\n".utf8), maximumBody: 10) == .invalid)
        let chunks = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n8\r\n12345678\r\n8\r\n12345678\r\n0\r\n\r\n"
        #expect(IDEHTTP.parse(Data(chunks.utf8), maximumBody: 10) == .invalid)
        // A chunk size that would overflow when added to what has come so far.
        let huge = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nA\r\n7fffffffffffffff\r\n"
        #expect(IDEHTTP.parse(Data(huge.utf8)) == .invalid)
        // A head that never ends.
        #expect(IDEHTTP.parse(Data(repeating: 0x41, count: 70_000)) == .invalid)
    }

    @Test func aRepeatedHeaderKeepsBothValues() throws {
        let text = "GET /mcp HTTP/1.1\r\nAuthorization: Nonce a\r\nAuthorization: Nonce b\r\n\r\n"
        let (request, _) = try #require(whole(IDEHTTP.parse(Data(text.utf8))))
        #expect(request.header("authorization") == "Nonce a, Nonce b")
        #expect(!CopilotIDE.isAuthorized(request.header("authorization"), nonce: "a"))
    }

    @Test func writesAnswersAndEvents() throws {
        let answer = String(decoding: IDEHTTP.response(status: 202), as: UTF8.self)
        #expect(answer == "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n")
        let refused = String(decoding: IDEHTTP.response(status: 401, close: true), as: UTF8.self)
        #expect(refused.hasPrefix("HTTP/1.1 401 Unauthorized\r\n") && refused.contains("Connection: close\r\n"))
        let head = String(decoding: IDEHTTP.streamHead(headers: [("Mcp-Session-Id", "s")]), as: UTF8.self)
        #expect(head.contains("Content-Type: text/event-stream\r\n") && head.contains("Transfer-Encoding: chunked\r\n") && head.hasSuffix("Mcp-Session-Id: s\r\n\r\n"))
        let event = try #require(IDEHTTP.event(["jsonrpc": "2.0", "method": "selection_changed", "params": ["filePath": "/a/b"]]))
        let text = String(decoding: event, as: UTF8.self)
        #expect(text.hasPrefix("event: message\ndata: {") && text.hasSuffix("}\n\n") && text.contains("\"/a/b\""))
        #expect(text.components(separatedBy: "\n").count == 4) // the JSON stays on one line
        #expect(String(decoding: IDEHTTP.chunk(Data("hello world, sixteen".utf8)), as: UTF8.self) == "14\r\nhello world, sixteen\r\n")
    }
}

@Suite struct CopilotIDETests {
    @Test func theLockNamesTheSocketAndIsNotTrusted() {
        let lock = CopilotIDE.lock(socketPath: "/tmp/x/mcp.sock", nonce: "n1", pid: 42, workspaces: ["/p"], timestamp: 7)
        #expect(lock["socketPath"] as? String == "/tmp/x/mcp.sock" && lock["scheme"] as? String == "unix")
        #expect((lock["headers"] as? [String: String])?["Authorization"] == "Nonce n1")
        #expect(lock["pid"] as? Int == 42 && lock["timestamp"] as? Int == 7 && lock["ideName"] as? String == "Next Term")
        #expect(lock["workspaceFolders"] as? [String] == ["/p"])
        // Copilot would skip its own folder-trust question for a trusted folder: never claimed.
        #expect(lock["isTrusted"] as? Bool == false)
        #expect(JSONSerialization.isValidJSONObject(lock))
    }

    @Test func theLockFolderFollowsCopilotHome() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(CopilotIDE.lockFolder(environment: [:], home: home).path == "/Users/someone/.copilot/ide")
        #expect(CopilotIDE.lockFolder(environment: ["COPILOT_HOME": "/opt/cop"], home: home).path == "/opt/cop/ide")
        #expect(CopilotIDE.lockFolder(environment: ["COPILOT_HOME": "relative"], home: home).path == "/Users/someone/.copilot/ide")
    }

    @Test func onlyThisLaunchsNonceGetsIn() {
        #expect(CopilotIDE.isAuthorized("Nonce secret", nonce: "secret"))
        #expect(!CopilotIDE.isAuthorized("Nonce Secret", nonce: "secret"))
        #expect(!CopilotIDE.isAuthorized("Bearer secret", nonce: "secret"))
        #expect(!CopilotIDE.isAuthorized("Nonce secret ", nonce: "secret"))
        #expect(!CopilotIDE.isAuthorized(nil, nonce: "secret"))
        #expect(!CopilotIDE.isAuthorized("", nonce: ""))
    }

    @Test func theToolsAreTheOnesTheCLICalls() {
        let names = CopilotIDE.tools.compactMap { $0["name"] as? String }
        #expect(Set(names) == ["get_vscode_info", "get_selection", "get_diagnostics", "open_diff", "close_diff", "update_session_name"])
        #expect(CopilotIDE.tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
        #expect(JSONSerialization.isValidJSONObject(CopilotIDE.tools))
    }

    func json(_ result: [String: Any]) -> [String: Any]? {
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    @Test func diffsAreAskedAndAnsweredAsTheCLIReadsThem() throws {
        let request = try #require(CopilotIDE.diffRequest(["original_file_path": "/p/a.swift", "new_file_contents": "new\n",
                                                           "tab_name": "[Copilot CLI] - a.swift (1a2b3c)"]))
        #expect(request == CopilotIDE.DiffRequest(path: "/p/a.swift", proposed: "new\n", tabName: "[Copilot CLI] - a.swift (1a2b3c)"))
        #expect(CopilotIDE.diffRequest(["original_file_path": "a.swift", "new_file_contents": "", "tab_name": "t"]) == nil)
        #expect(CopilotIDE.diffRequest(["original_file_path": "/a", "tab_name": "t"]) == nil)
        // The CLI checks success (bool), result (SAVED/REJECTED), trigger and message (strings).
        let saved = try #require(json(CopilotIDE.diffResult(accepted: true, tabName: "t", path: "/p/a.swift")))
        #expect(saved["success"] as? Bool == true && saved["result"] as? String == "SAVED" && saved["trigger"] is String)
        #expect(saved["message"] as? String == "User accepted changes for /p/a.swift" && saved["tab_name"] as? String == "t")
        let rejected = try #require(json(CopilotIDE.diffResult(accepted: false, tabName: "t", path: "/p", trigger: "closed_via_tool")))
        #expect(rejected["result"] as? String == "REJECTED" && rejected["trigger"] as? String == "closed_via_tool")
        let closed = try #require(json(CopilotIDE.closeDiffResult(tabName: "t", wasOpen: false)))
        #expect(closed["success"] as? Bool == true && closed["already_closed"] as? Bool == true && closed["message"] is String)
        #expect(CopilotIDE.textResult(NSNull())["content"].flatMap { ($0 as? [[String: Any]])?.first?["text"] as? String } == "null")
        #expect(CopilotIDE.errorResult("no")["isError"] as? Bool == true)
    }

    @Test func theSelectionIsClaudesShapeAndNeverASecret() throws {
        let claude: [String: Any] = ["text": "two\n", "filePath": "/p/main.php", "fileUrl": "file:///p/main.php",
                                     "selection": ["start": ["line": 1, "character": 0], "end": ["line": 2, "character": 0], "isEmpty": false]]
        let shared = try #require(CopilotIDE.selection(fromClaude: claude))
        #expect(shared["filePath"] as? String == "/p/main.php" && shared["text"] as? String == "two\n")
        #expect((shared["selection"] as? [String: Any])?["isEmpty"] as? Bool == false)
        // No file in front (Claude's clearing message): nothing for Copilot.
        #expect(CopilotIDE.selection(fromClaude: ["selection": ["isEmpty": true]]) == nil)
        for secret in ["/p/.env", "/p/.env.local", "/p/server.key", "/p/cert.pem", "/home/.ssh/id_ed25519", "/p/.npmrc"] {
            var params = claude
            params["filePath"] = secret
            #expect(CopilotIDE.selection(fromClaude: params) == nil, "\(secret)")
        }
        var example = claude
        example["filePath"] = "/p/.env.example"
        #expect(CopilotIDE.selection(fromClaude: example) != nil)
    }

    @Test func sendToAgentBecomesAnAtMention() throws {
        let lines = try #require(CopilotIDE.fileReference(path: "/p/app/User.php", lines: 10...20))
        #expect(lines.method == "add_selection")
        let selection = try #require(lines.params["selection"] as? [String: Any])
        #expect((selection["start"] as? [String: Any])?["line"] as? Int == 9 && (selection["end"] as? [String: Any])?["line"] as? Int == 19)
        #expect(lines.params["filePath"] as? String == "/p/app/User.php" && lines.params["fileUrl"] as? String == "file:///p/app/User.php")
        #expect(lines.params["selectedText"] is NSNull) // present and null, as the CLI's schema wants
        let file = try #require(CopilotIDE.fileReference(path: "/p/a b.swift", lines: nil))
        #expect(file.method == "add_file_reference" && file.params["selection"] is NSNull)
        #expect(file.params["fileUrl"] as? String == "file:///p/a%20b.swift")
        #expect(CopilotIDE.fileReference(path: "relative.swift", lines: nil) == nil)
    }
}

@Suite struct IDEPeerTests {
    /// A made-up process table: who is whose child, which sockets each holds, and its executable.
    struct Table {
        var children: [pid_t: [pid_t]] = [:]
        var sockets: [pid_t: [(local: UInt16, remote: UInt16)]] = [:]
        var paths: [pid_t: String] = [:]

        var processes: IDEPeer.Processes {
            let children = self.children, sockets = self.sockets, paths = self.paths
            return IDEPeer.Processes(children: { children[$0] ?? [] }, sockets: { sockets[$0] ?? [] }, path: { paths[$0] })
        }
    }

    /// Tab shell 100 runs node (200), which runs opencode (300); its socket goes from port 50000 to 4000.
    func table() -> Table {
        var table = Table()
        table.children = [100: [200], 200: [300], 300: [301]]
        table.paths = [100: "/bin/zsh", 200: "/opt/homebrew/bin/node", 300: "/Users/me/.npm/opencode-darwin-arm64/bin/opencode",
                       301: "/usr/bin/git"]
        table.sockets = [300: [(local: 50000, remote: 4000), (local: 50001, remote: 443)]]
        return table
    }

    @Test func opencodeInATabIsFoundByItsSocket() {
        let table = table()
        #expect(IDEPeer.opencode(clientPort: 50000, serverPort: 4000, under: [100], processes: table.processes) == 300)
        // Another connection, or the same ports the other way round (the server's end), is not it.
        #expect(IDEPeer.opencode(clientPort: 50001, serverPort: 4000, under: [100], processes: table.processes) == nil)
        #expect(IDEPeer.opencode(clientPort: 4000, serverPort: 50000, under: [100], processes: table.processes) == nil)
    }

    @Test func onlyOpencodeAndOnlyInTheTabs() {
        var table = table()
        // Not under any of the tabs' shells (another terminal, or Next Term itself): refused.
        #expect(IDEPeer.opencode(clientPort: 50000, serverPort: 4000, under: [999], processes: table.processes) == nil)
        #expect(IDEPeer.opencode(clientPort: 50000, serverPort: 4000, under: [], processes: table.processes) == nil)
        // In a tab, but something else holds the socket: refused.
        table.paths[300] = "/tmp/evil"
        #expect(IDEPeer.holders(clientPort: 50000, serverPort: 4000, under: [100], processes: table.processes) == [300])
        #expect(IDEPeer.opencode(clientPort: 50000, serverPort: 4000, under: [100], processes: table.processes) == nil)
        table.paths[300] = "/tmp/opencode-helper"
        #expect(IDEPeer.opencode(clientPort: 50000, serverPort: 4000, under: [100], processes: table.processes) == nil)
        // The tab's own process holding it: refused while it is the shell, taken once it is opencode
        // (`exec opencode` in the tab).
        table.paths[300] = "/x/opencode"
        table.sockets = [100: [(local: 50000, remote: 4000)]]
        #expect(IDEPeer.holders(clientPort: 50000, serverPort: 4000, under: [100], processes: table.processes) == [100])
        #expect(IDEPeer.opencode(clientPort: 50000, serverPort: 4000, under: [100], processes: table.processes) == nil)
        table.paths[100] = "/opt/homebrew/bin/opencode"
        #expect(IDEPeer.opencode(clientPort: 50000, serverPort: 4000, under: [100], processes: table.processes) == 100)
        #expect(IDEPeer.isOpencode(path: "/opt/homebrew/Cellar/opencode/1.18.34/bin/opencode"))
        #expect(!IDEPeer.isOpencode(path: "/usr/local/bin/opencode.sh") && !IDEPeer.isOpencode(path: "/bin/node"))
        #expect(!IDEPeer.isOpencode(path: "/tmp/opencode-helper") && !IDEPeer.isOpencode(path: "/tmp/opencode.exe.sh"))
    }

    /// `npm i -g opencode-ai` (and bun's) links the binary as bin/opencode.exe, and that is the path the kernel gives.
    @Test func opencodeInstalledWithNpmIsOpencode() {
        var table = table()
        table.paths[300] = "/opt/homebrew/lib/node_modules/opencode-ai/bin/opencode.exe"
        #expect(IDEPeer.isOpencode(path: "/opt/homebrew/lib/node_modules/opencode-ai/bin/opencode.exe"))
        #expect(IDEPeer.opencode(clientPort: 50000, serverPort: 4000, under: [100], processes: table.processes) == 300)
    }

    @Test func aLoopInTheTableEnds() {
        var table = table()
        table.children[301] = [100, 300] // pids get reused; the walk must still end
        #expect(IDEPeer.opencode(clientPort: 50000, serverPort: 4000, under: [100], processes: table.processes) == 300)
    }

    /// The kernel's own view: this test process connects to itself over loopback and is found by the ports
    /// of its client socket (as a child of nothing it is looked up directly).
    @Test func theKernelSaysWhoHoldsASocket() throws {
        let server = socket(AF_INET, SOCK_STREAM, 0)
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(server); close(client) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, length) } }
        try #require(bound == 0 && listen(server, 1) == 0)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &length) } }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) } }
        try #require(connected == 0)
        var local = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(client, $0, &length) } }
        let serverPort = UInt16(bigEndian: address.sin_port), clientPort = UInt16(bigEndian: local.sin_port)
        let me = getpid()
        let sockets = IDEPeer.tcpSockets(me)
        #expect(sockets.contains { $0.local == clientPort && $0.remote == serverPort })
        // Looked up as the only child of a made-up shell (a pid no process has), with the kernel's sockets and paths.
        let shell = pid_t.max
        let processes = IDEPeer.Processes(children: { $0 == shell ? [me] : [] }, sockets: { IDEPeer.tcpSockets($0) },
                                          path: { IDEPeer.executablePath($0) })
        #expect(IDEPeer.holders(clientPort: clientPort, serverPort: serverPort, under: [shell], processes: processes) == [me])
        // Or as the tab's own process.
        #expect(IDEPeer.holders(clientPort: clientPort, serverPort: serverPort, under: [me], processes: processes) == [me])
        // This test runner is not opencode.
        #expect(IDEPeer.opencode(clientPort: clientPort, serverPort: serverPort, under: [shell], processes: processes) == nil)
        #expect(IDEPeer.executablePath(me)?.hasPrefix("/") == true)
    }
}
